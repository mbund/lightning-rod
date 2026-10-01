const std = @import("std");
const metrics = @import("metrics");
const index_page = @import("index_page.zig");
const storage = @import("storage");
const index = @import("index.zig");
const Buffer = @import("append_buffer.zig");

const Metrics = metrics.Metrics;

const ReadTrace = Metrics(enum { batch, key_sort, lookup, offset_sort, dispatch, wait });

const WorkerTrace = Metrics(enum { batch, read, checksum, copy });

/// Single-owner append buffers, with one immutable checkpoint syncing through
/// std.Io. Only a complete checkpoint's durable superblock publishes its root.
pub const Store = struct {
    allocator: std.mem.Allocator,
    pages: std.Io.File,
    values: std.Io.File,
    super: [2]std.Io.File,
    paths: [4][]u8,
    page_buffer: Buffer,
    value_buffer: Buffer,
    read_buffers: []align(64) u8,
    max_value_bytes: u32,
    root: index.Root = .{},
    generation: u64 = 0,
    lease: u64 = 0,
    last_tick: u64 = 0,
    durable_tick: u64 = 0,
    syncing: ?std.Io.Future(storage.Error!void) = null,
    checkpoint: Checkpoint = undefined,
    sync_wait_ns: u64 = 0,
    value_sync_ns: u64 = 0,
    page_sync_ns: u64 = 0,
    root_sync_ns: u64 = 0,
    pages_end: u64 = 0,
    values_end: u64 = 0,
    checkpoint_pages_end: u64 = 0,
    checkpoint_values_end: u64 = 0,
    failed: bool = false,
    active: bool = false,
    workspace: index.Workspace = .{},
    pending: [128]Mutation = undefined,
    pending_count: usize = 0,
    transaction: Transaction = undefined,
    index_ns: u64 = 0,
    page_write_ns: u64 = 0,
    value_write_ns: u64 = 0,
    value_reads: u64 = 0,
    read_wait_ns: u64 = 0,
    read_batches: u64 = 0,
    metrics: ReadTrace = undefined,
    worker_metrics: WorkerTrace = undefined,

    const ReadBatch = struct {
        io: std.Io,
        file: std.Io.File,
        records: []const storage.Get,
        lengths: []?usize,
        order: [32]u8,
        locations: [32]index.Location,
        count: usize,
        calls: u64 = 0,
        metrics: WorkerTrace,
        buffer: []u8,

        fn run(self: *ReadBatch) storage.Error!void {
            var batch = self.metrics.begin(.batch);
            defer batch.end();
            batch.add(.records, self.count);
            const buffer = self.buffer;
            var at: usize = 0;

            while (at < self.count) {
                const first = self.locations[self.order[at]];
                var end = first.offset + value_header_bytes + first.length;
                var stop = at + 1;

                while (stop < self.count) : (stop += 1) {
                    const next = self.locations[self.order[stop]];
                    if (next.offset != end or end + value_header_bytes + next.length - first.offset > buffer.len) break;
                    end += value_header_bytes + next.length;
                }

                var headers: [32][value_header_bytes]u8 = undefined;
                var vectors: [64][]u8 = undefined;

                for (self.order[at..stop], 0..) |slot, i| {
                    vectors[2 * i] = &headers[i];
                    vectors[2 * i + 1] = self.records[slot].destination[0..self.locations[slot].length];
                }

                const buffered = stop - at > 1 and end - first.offset <= buffer.len;
                const extent: usize = @intCast(end - first.offset);

                if (buffered) vectors[0] = buffer[0..extent];
                var remaining = vectors[0..if (buffered) @as(usize, 1) else 2 * (stop - at)];
                var offset = first.offset;

                while (offset < end) {
                    const n = blk: {
                        var read = batch.begin(.read);
                        defer read.end();
                        const n = self.file.readPositional(self.io, remaining, offset) catch return error.IoFailure;
                        read.add(.bytes, n);
                        break :blk n;
                    };
                    self.calls += 1;
                    if (n == 0 or n > end - offset) return error.Corrupt;
                    offset += n;
                    var consumed = n;

                    while (remaining.len != 0 and consumed >= remaining[0].len) {
                        consumed -= remaining[0].len;
                        remaining = remaining[1..];
                    }

                    if (remaining.len != 0) remaining[0] = remaining[0][consumed..];
                }

                std.debug.assert(offset == end);
                {
                    const checksum = batch.begin(.checksum);
                    defer checksum.end();

                    for (self.order[at..stop], 0..) |slot, i| {
                        const length = self.locations[slot].length;
                        const relative: usize = @intCast(self.locations[slot].offset - first.offset);
                        const header = if (buffered) buffer[relative..][0..value_header_bytes] else &headers[i];
                        const value = if (buffered) buffer[relative + value_header_bytes ..][0..length] else self.records[slot].destination[0..length];
                        if (std.mem.readInt(u32, header[0..4], .little) != length or
                            std.mem.readInt(u64, header[4..12], .little) != sum(value)) return error.Corrupt;
                        self.lengths[slot] = length;
                    }
                }

                if (buffered) {
                    var copy = batch.begin(.copy);
                    defer copy.end();

                    for (self.order[at..stop]) |slot| {
                        const location = self.locations[slot];
                        const relative: usize = @intCast(location.offset - first.offset + value_header_bytes);
                        // One bounded extent read replaces many small scatter reads.
                        @memcpy(self.records[slot].destination[0..location.length], buffer[relative..][0..location.length]);
                        copy.add(.bytes, location.length);
                    }
                }

                at = stop;
            }
        }
    };

    pub const Options = struct {
        path: []const u8,
        max_value_bytes: u32,
        buffer_bytes: usize = 256 * 1024,
        metrics: metrics.Options = .{},
    };

    const Super = extern struct {
        magic: u64,
        generation: u64,
        tick: u64,
        root_page: u64,
        count: u64,
        pages_end: u64,
        values_end: u64,
        checksum: u64,
    };

    const ValueHeader = extern struct {
        length: u32,
        checksum: u64,
    };

    const super_magic: u64 = 0x4c5253544f524532;
    const super_bytes = 64;
    const value_header_bytes = 12;

    const Transaction = struct {
        store: *Store,
        io: std.Io,
        tick: u64,
        root: index.Root,
        lease: u64,
        pages_end: u64,
        values_end: u64,
        open: bool,
    };

    const Checkpoint = struct {
        io: std.Io,
        values: std.Io.File,
        pages: std.Io.File,
        super: std.Io.File,
        root: Super,
        values_changed: bool,
        pages_changed: bool,
        done: std.atomic.Value(bool) = .init(false),
        value_ns: u64 = 0,
        page_ns: u64 = 0,
        root_ns: u64 = 0,

        fn run(self: *Checkpoint) storage.Error!void {
            defer self.done.store(true, .release);
            const started = std.Io.Clock.now(.awake, self.io).nanoseconds;
            if (self.values_changed) self.values.sync(self.io) catch return error.IoFailure;

            const values_done = std.Io.Clock.now(.awake, self.io).nanoseconds;
            self.value_ns = @intCast(values_done - started);
            if (self.pages_changed) self.pages.sync(self.io) catch return error.IoFailure;

            const pages_done = std.Io.Clock.now(.awake, self.io).nanoseconds;
            self.page_ns = @intCast(pages_done - values_done);
            var bytes: [super_bytes]u8 = undefined;
            encodeSuper(&bytes, self.root);
            self.root.checksum = sum(&bytes);
            encodeSuper(&bytes, self.root);
            try write(self.super, self.io, &bytes, 0);
            self.super.sync(self.io) catch return error.IoFailure;
            self.root_ns = @intCast(std.Io.Clock.now(.awake, self.io).nanoseconds - pages_done);
        }
    };

    const Mutation = struct {
        bytes: [index.max_key_bytes]u8,
        namespace_len: u16,
        key_len: u16,
        operation: index.Operation,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) storage.Error!Store {
        if (options.path.len == 0) return error.InvalidArgument;
        if (options.max_value_bytes == 0) return error.InvalidArgument;
        if (options.buffer_bytes < index.page_size or options.buffer_bytes % index.page_size != 0) return error.InvalidArgument;

        const page_bytes = allocator.alloc(u8, options.buffer_bytes) catch return error.NoSpace;
        errdefer allocator.free(page_bytes);
        const value_bytes = allocator.alloc(u8, options.buffer_bytes) catch return error.NoSpace;
        errdefer allocator.free(value_bytes);
        const read_bytes = allocator.alignedAlloc(u8, .@"64", 2 * 64 * 1024) catch return error.NoSpace;
        errdefer allocator.free(read_bytes);
        var paths: [4][]u8 = @splat(&.{});
        var path_count: usize = 0;
        errdefer for (paths[0..path_count]) |path| allocator.free(path);
        const suffixes = [_][]const u8{ ".pages", ".values", ".super0", ".super1" };

        for (suffixes, 0..) |suffix, i| {
            const length = std.math.add(usize, options.path.len, suffix.len) catch return error.InvalidArgument;
            paths[i] = allocator.alloc(u8, length) catch return error.NoSpace;
            path_count += 1;
            @memcpy(paths[i][0..options.path.len], options.path);
            @memcpy(paths[i][options.path.len..], suffix);
        }

        var files: [4]std.Io.File = undefined;
        const order = [_]usize{ 2, 0, 1, 3 };
        var opened: usize = 0;
        errdefer for (order[0..opened]) |i| files[i].close(io);

        for (order) |i| {
            files[i] = std.Io.Dir.cwd().createFile(io, paths[i], .{
                .read = true,
                .truncate = false,
                .lock = if (i == 2) .exclusive else .none,
                .lock_nonblocking = true,
            }) catch |err| return if (err == error.WouldBlock) error.Busy else error.IoFailure;
            opened += 1;
        }

        var result: Store = .{
            .allocator = allocator,
            .pages = files[0],
            .values = files[1],
            .super = .{ files[2], files[3] },
            .paths = paths,
            .page_buffer = .{ .bytes = page_bytes },
            .value_buffer = .{ .bytes = value_bytes },
            .read_buffers = read_bytes,
            .max_value_bytes = options.max_value_bytes,
        };
        result.metrics = ReadTrace.init(io, options.metrics);
        result.worker_metrics = WorkerTrace.init(io, options.metrics);
        try result.recover(io);
        try result.installEmptySuperblock(io);
        return result;
    }

    pub fn deinit(self: *Store, io: std.Io) void {
        if (self.syncing != null or (!self.failed and self.durable_tick < self.last_tick))
            flush(self, io) catch |err| std.log.err("event=storage_close_failed reason={s}", .{@errorName(err)});
        self.metrics.log("storage_reads");
        self.worker_metrics.log("storage_read_workers");
        self.pages.close(io);
        self.values.close(io);
        self.super[0].close(io);
        self.super[1].close(io);

        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.page_buffer.bytes);
        self.allocator.free(self.value_buffer.bytes);
        self.allocator.free(self.read_buffers);
        self.* = undefined;
    }

    pub fn memoryBytes(self: *const Store) usize {
        return @sizeOf(Store) + self.page_buffer.bytes.len + self.value_buffer.bytes.len + self.read_buffers.len +
            self.paths[0].len + self.paths[1].len + self.paths[2].len + self.paths[3].len;
    }

    pub fn interface(self: *Store) storage.Storage {
        return .{ .context = self, .vtable = &.{ .begin = begin, .last_tick = lastTickOpaque, .durable_tick = durableTick, .flush = flush } };
    }

    fn lastTickOpaque(raw: *const anyopaque) u64 {
        const self: *const Store = @ptrCast(@alignCast(raw));
        return self.last_tick;
    }

    fn durableTick(raw: *const anyopaque) u64 {
        const self: *const Store = @ptrCast(@alignCast(raw));
        return self.durable_tick;
    }

    fn flush(raw: *anyopaque, io: std.Io) storage.Error!void {
        const self: *Store = @ptrCast(@alignCast(raw));
        try self.finishCheckpoint(io);

        if (self.durable_tick < self.last_tick) {
            try self.startCheckpoint(io, self.last_tick, self.root, self.pages_end, self.values_end);
            try self.finishCheckpoint(io);
        }

        std.debug.assert(self.durable_tick == self.last_tick);
    }

    fn finishCheckpoint(self: *Store, io: std.Io) storage.Error!void {
        if (self.syncing) |*future| {
            const started = std.Io.Clock.now(.awake, io).nanoseconds;
            const result = future.await(self.checkpoint.io);
            self.sync_wait_ns += @intCast(std.Io.Clock.now(.awake, io).nanoseconds - started);
            self.syncing = null;
            result catch return self.fail();
            std.debug.assert(self.checkpoint.done.load(.acquire));
            self.value_sync_ns += self.checkpoint.value_ns;
            self.page_sync_ns += self.checkpoint.page_ns;
            self.root_sync_ns += self.checkpoint.root_ns;
            self.durable_tick = self.checkpoint.root.tick;
            std.debug.assert(self.durable_tick <= self.last_tick);
        }

        if (self.failed) return error.IoFailure;
    }

    fn begin(raw: *anyopaque, io: std.Io, tick: u64) storage.Error!storage.Transaction {
        const self: *Store = @ptrCast(@alignCast(raw));

        if (self.syncing != null and self.checkpoint.done.load(.acquire)) try self.finishCheckpoint(io);
        if (self.failed) return error.Closed;
        if (self.active) return error.Busy;
        if (tick <= self.last_tick or self.lease == std.math.maxInt(u64) or self.generation == std.math.maxInt(u64)) return error.InvalidArgument;
        self.active = true;
        self.lease += 1;
        self.workspace.reset();
        self.pending_count = 0;
        self.page_buffer.reset(self.pages_end);
        self.value_buffer.reset(self.values_end);
        self.transaction = .{
            .store = self,
            .io = io,
            .tick = tick,
            .root = self.root,
            .lease = self.lease,
            .pages_end = self.pages_end,
            .values_end = self.values_end,
            .open = true,
        };
        return .{ .context = &self.transaction, .lease = self.lease, .vtable = &.{ .namespace = namespace, .preflush = preflush, .submit = submit, .abort = abort } };
    }

    fn namespace(raw: *anyopaque, lease: u64, bytes: []const u8) storage.Error!storage.Namespace {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        if (!tx.open or tx.lease != lease) return error.Closed;
        if (bytes.len >= index.max_key_bytes) return error.BufferTooSmall;
        return .{
            .context = tx.store,
            .bytes = bytes,
            .vtable = &.{ .fail = poison, .get = getCurrent, .put_batch = putBatchCurrent, .get_batch = getBatchCurrent, .scan = scanCurrent },
        };
    }

    fn poison(raw: *anyopaque) void {
        const self: *Store = @ptrCast(@alignCast(raw));
        std.debug.assert(self.active);
        self.failed = true;
    }

    fn current(raw: *anyopaque) storage.Error!*Transaction {
        const self: *Store = @ptrCast(@alignCast(raw));
        if (!self.active or self.failed) return error.Closed;
        if (!self.transaction.open) return error.Closed;
        return &self.transaction;
    }

    fn treeIo(tx: *Transaction) index.Io {
        return .{ .context = tx, .read_fn = pageRead, .write_fn = pageWrite };
    }

    fn pageRead(raw: *anyopaque, id: index.PageId, out: *[index.page_size]u8) index.ReadError!index.Origin {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        if (id == 0 or id > tx.pages_end / index.page_size) return error.IoFailure;
        tx.store.page_buffer.read(tx.store.pages, tx.io, out, (id - 1) * index.page_size) catch return error.IoFailure;
        return if ((id - 1) * index.page_size >= tx.store.page_buffer.offset) .staged else .disk;
    }

    fn pageWrite(raw: *anyopaque, previous: index.PageId, bytes: *const [index.page_size]u8) index.AppendError!index.PageId {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        const started = std.Io.Clock.now(.awake, tx.io).nanoseconds;
        defer tx.store.page_write_ns +|= @intCast(std.Io.Clock.now(.awake, tx.io).nanoseconds - started);
        const buffer = &tx.store.page_buffer;
        if (previous != 0) {
            const at = (previous - 1) * index.page_size;
            std.debug.assert(at < tx.pages_end);
            if (at >= buffer.offset) {
                std.debug.assert(at >= tx.store.pages_end);
                const start: usize = @intCast(at - buffer.offset);
                std.debug.assert(start + bytes.len <= buffer.used);
                @memcpy(buffer.bytes[start..][0..bytes.len], bytes);
                return previous;
            }
        }

        const offset = tx.pages_end;
        const end = std.math.add(u64, offset, index.page_size) catch return error.IoFailure;
        std.debug.assert(offset % index.page_size == 0);
        if (buffer.used == buffer.bytes.len) flushPages(tx) catch return error.IoFailure;
        buffer.append(tx.store.pages, tx.io, bytes) catch {
            tx.store.failed = true;
            return error.IoFailure;
        };
        tx.pages_end = end;
        std.debug.assert(tx.pages_end == buffer.offset + buffer.used);
        return offset / index.page_size + 1;
    }

    fn putBatchCurrent(raw: *anyopaque, ns: []const u8, records: []const storage.Write) storage.Error!void {
        const tx = try current(raw);
        if (ns.len >= index.max_key_bytes) return error.BufferTooSmall;

        for (records) |record| {
            if (record.key.len == 0) return error.InvalidArgument;
            if (record.key.len > index.max_key_bytes - ns.len) return error.BufferTooSmall;
            if (record.value) |value| if (value.len > tx.store.max_value_bytes) return error.BufferTooSmall;
        }

        errdefer tx.store.failed = true;

        for (records) |r| {
            var slot = pendingFind(tx.store, ns, r.key);

            if (slot == null and tx.store.pending_count == tx.store.pending.len) try flushIndex(tx);

            if (slot == null) {
                slot = tx.store.pending_count;
                const item = &tx.store.pending[slot.?];
                @memcpy(item.bytes[0..ns.len], ns);
                @memcpy(item.bytes[ns.len..][0..r.key.len], r.key);
                item.namespace_len = @intCast(ns.len);
                item.key_len = @intCast(r.key.len);
                item.operation = .delete;
                tx.store.pending_count += 1;
            }

            const op: index.Operation = if (r.value) |value| blk: {
                if (value.len > tx.store.max_value_bytes) return error.BufferTooSmall;

                const buffer = &tx.store.value_buffer;
                var header_bytes: [value_header_bytes]u8 = undefined;
                encodeValueHeader(&header_bytes, .{ .length = @intCast(value.len), .checksum = sum(value) });
                if (tx.store.pending[slot.?].operation == .put) {
                    var old = tx.store.pending[slot.?].operation.put;
                    if (old.offset >= buffer.offset and value.len <= old.length) {
                        const start: usize = @intCast(old.offset - buffer.offset);
                        std.debug.assert(start + value_header_bytes + old.length <= buffer.used);
                        @memcpy(buffer.bytes[start..][0..value_header_bytes], &header_bytes);
                        @memcpy(buffer.bytes[start + value_header_bytes ..][0..value.len], value);
                        old.length = @intCast(value.len);
                        break :blk .{ .put = old };
                    }
                }

                const offset = tx.values_end;
                const end = std.math.add(u64, offset, value.len + value_header_bytes) catch return error.NoSpace;
                const started = std.Io.Clock.now(.awake, tx.io).nanoseconds;
                tx.store.value_buffer.append(tx.store.values, tx.io, &header_bytes) catch return tx.store.fail();
                tx.store.value_buffer.append(tx.store.values, tx.io, value) catch return tx.store.fail();
                tx.store.value_write_ns +|= @intCast(std.Io.Clock.now(.awake, tx.io).nanoseconds - started);
                tx.values_end = end;
                std.debug.assert(end == tx.store.value_buffer.offset + tx.store.value_buffer.used);
                break :blk .{ .put = .{ .pack = 0, .offset = offset, .length = @intCast(value.len) } };
            } else .delete;
            tx.store.pending[slot.?].operation = op;
        }
    }

    fn pendingFind(self: *const Store, ns: []const u8, key: []const u8) ?usize {
        for (self.pending[0..self.pending_count], 0..) |*item, i| {
            if (item.namespace_len == ns.len and item.key_len == key.len and
                std.mem.eql(u8, item.bytes[0..ns.len], ns) and
                std.mem.eql(u8, item.bytes[ns.len..][0..key.len], key)) return i;
        }

        return null;
    }

    fn mutationLess(self: *const Store, a: u8, b: u8) bool {
        const x = &self.pending[a];
        const y = &self.pending[b];
        const order = std.mem.order(u8, x.bytes[0..x.namespace_len], y.bytes[0..y.namespace_len]);
        return if (order != .eq) order == .lt else std.mem.order(u8, x.bytes[x.namespace_len..][0..x.key_len], y.bytes[y.namespace_len..][0..y.key_len]) == .lt;
    }

    fn flushIndex(tx: *Transaction) storage.Error!void {
        const self = tx.store;
        var order: [128]u8 = undefined;

        for (order[0..self.pending_count], 0..) |*slot, i| slot.* = @intCast(i);
        std.mem.sort(u8, order[0..self.pending_count], @as(*const Store, self), mutationLess);
        var mutations: [128]index.Mutation = undefined;

        for (order[0..self.pending_count], mutations[0..self.pending_count]) |slot, *mutation| {
            const item = &self.pending[slot];
            mutation.* = .{
                .namespace = item.bytes[0..item.namespace_len],
                .key = item.bytes[item.namespace_len..][0..item.key_len],
                .operation = item.operation,
            };
        }

        const started = std.Io.Clock.now(.awake, tx.io).nanoseconds;
        var consumed: usize = 0;

        while (consumed < self.pending_count) {
            const applied = index.apply(treeIo(tx), tx.root, &self.workspace, mutations[consumed..self.pending_count]) catch return self.fail();
            std.debug.assert(applied.consumed > 0 and applied.consumed <= self.pending_count - consumed);
            tx.root = applied.root;
            consumed += applied.consumed;
        }

        self.index_ns +|= @intCast(std.Io.Clock.now(.awake, tx.io).nanoseconds - started);
        self.pending_count = 0;
    }

    fn flushPages(tx: *Transaction) storage.Error!void {
        const buffer = &tx.store.page_buffer;
        std.debug.assert(buffer.used % index.page_size == 0);
        var offset: usize = 0;

        while (offset < buffer.used) : (offset += index.page_size)
            index_page.seal(buffer.bytes[offset..][0..index.page_size]);
        buffer.flush(tx.store.pages, tx.io) catch return tx.store.fail();
    }

    fn getCurrent(raw: *anyopaque, ns: []const u8, key: []const u8, out: []u8) storage.Error!?usize {
        var lengths: [1]?usize = undefined;
        try getBatchCurrent(raw, ns, &.{.{ .key = key, .destination = out }}, &lengths);
        return lengths[0];
    }

    fn getBatchCurrent(raw: *anyopaque, ns: []const u8, records: []const storage.Get, lengths: []?usize) storage.Error!void {
        if (records.len != lengths.len) return error.InvalidArgument;

        const tx = try current(raw);
        var scope = tx.store.metrics.begin(.batch);
        defer scope.end();
        scope.add(.records, records.len);
        if (ns.len >= index.max_key_bytes) return error.BufferTooSmall;

        for (records) |record| {
            if (record.key.len == 0) return error.InvalidArgument;
            if (record.key.len > index.max_key_bytes - ns.len) return error.BufferTooSmall;
        }

        var reads: [2]ReadBatch = undefined;
        var futures: [2]?std.Io.Future(storage.Error!void) = @splat(null);
        defer for (&futures) |*future| {
            if (future.*) |*pending| pending.await(tx.io) catch {};
        };
        var base: usize = 0;

        while (base < records.len) {
            const selected = base / 32 % reads.len;

            if (futures[selected]) |*pending| {
                const started = std.Io.Clock.now(.awake, tx.io).nanoseconds;
                const waiting = scope.begin(.wait);
                const result = pending.await(tx.io);
                waiting.end();
                tx.store.read_wait_ns += @intCast(std.Io.Clock.now(.awake, tx.io).nanoseconds - started);
                futures[selected] = null;
                try result;
                tx.store.value_reads += reads[selected].calls;
                tx.store.worker_metrics.merge(&reads[selected].metrics.records);
            }

            const batch = records[base..][0..@min(32, records.len - base)];
            const job = &reads[selected];
            job.* = .{
                .io = tx.io,
                .file = tx.store.values,
                .records = batch,
                .lengths = lengths[base..][0..batch.len],
                .order = undefined,
                .locations = undefined,
                .count = 0,
                .buffer = tx.store.read_buffers[selected * 64 * 1024 ..][0 .. 64 * 1024],
                .metrics = WorkerTrace.init(tx.io, .{ .enabled = tx.store.metrics.recorder.enabled, .cpu = tx.store.metrics.recorder.cpu }),
            };
            const order = &job.order;
            const locations = &job.locations;
            var count: usize = 0;
            const key_sort = scope.begin(.key_sort);

            for (order[0..batch.len], 0..) |*slot, i| slot.* = @intCast(i);
            std.mem.sort(u8, order[0..batch.len], batch, struct {
                fn less(items: []const storage.Get, a: u8, b: u8) bool {
                    return std.mem.order(u8, items[a].key, items[b].key) == .lt;
                }
            }.less);
            key_sort.end();
            {
                const lookup = scope.begin(.lookup);
                defer lookup.end();
                var cursor = index.Cursor.init(treeIo(tx), tx.root, &tx.store.workspace);

                for (0..batch.len) |i| {
                    const slot = order[i];
                    const record = batch[slot];
                    lengths[base + slot] = null;
                    const location = if (pendingFind(tx.store, ns, record.key)) |pending| switch (tx.store.pending[pending].operation) {
                        .put => |location| location,
                        .delete => null,
                    } else cursor.lookupSorted(ns, record.key) catch return error.Corrupt;
                    const loc = location orelse continue;
                    if (loc.length > record.destination.len) return error.BufferTooSmall;

                    const end = std.math.add(u64, loc.offset, value_header_bytes + @as(u64, loc.length)) catch return error.Corrupt;
                    if (loc.pack != 0 or end > tx.values_end) return error.Corrupt;
                    if (end > tx.store.value_buffer.offset) {
                        try readValue(tx, loc, record.destination);
                        lengths[base + slot] = loc.length;
                        continue;
                    }

                    locations[slot] = loc;
                    order[count] = slot;
                    count += 1;
                }
            }
            const offset_sort = scope.begin(.offset_sort);
            std.mem.sort(u8, order[0..count], locations, struct {
                fn less(items: *const [32]index.Location, a: u8, b: u8) bool {
                    return items[a].offset < items[b].offset;
                }
            }.less);
            offset_sort.end();
            job.count = count;
            tx.store.read_batches += 1;

            if (records.len <= 32) {
                try job.run();
                tx.store.value_reads += job.calls;
                tx.store.worker_metrics.merge(&job.metrics.records);
            } else if (count != 0) {
                const dispatch = scope.begin(.dispatch);
                futures[selected] = tx.io.async(ReadBatch.run, .{job});
                dispatch.end();
            }

            base += batch.len;
        }

        for (&futures, &reads) |*future, *job| if (future.*) |*pending| {
            const started = std.Io.Clock.now(.awake, tx.io).nanoseconds;
            const waiting = scope.begin(.wait);
            const result = pending.await(tx.io);
            waiting.end();
            tx.store.read_wait_ns += @intCast(std.Io.Clock.now(.awake, tx.io).nanoseconds - started);
            future.* = null;
            try result;
            tx.store.value_reads += job.calls;
            tx.store.worker_metrics.merge(&job.metrics.records);
        };
    }

    fn scanCurrent(raw: *anyopaque, ns: []const u8, cursor: *storage.ScanCursor, entries: []storage.ScanEntry) storage.Error!storage.ScanResult {
        const tx = try current(raw);
        if (!tx.open) return error.Closed;
        try flushIndex(tx);
        if (cursor.after_len > cursor.after.len) return error.InvalidArgument;

        var tree = index.Cursor.init(treeIo(tx), tx.root, &tx.store.workspace);
        var item = index.Cursor.seek(&tree, ns, cursor.after[0..cursor.after_len]) catch return error.Corrupt;
        if (item) |first| {
            if (std.mem.eql(u8, first.namespace, ns)) {
                if (std.mem.eql(u8, first.key, cursor.after[0..cursor.after_len])) item = tree.next() catch return error.Corrupt;
            }
        }

        var count: usize = 0;

        while (item) |entry| : (item = tree.next() catch return error.Corrupt) {
            if (!std.mem.eql(u8, entry.namespace, ns)) break;
            if (count == entries.len) return .{ .count = count, .more = true };

            if (entry.key.len > entries[count].key.len or entry.key.len > cursor.after.len or entry.location.length > entries[count].value.len)
                return error.BufferTooSmall;
            @memcpy(entries[count].key[0..entry.key.len], entry.key);
            try readValue(tx, entry.location, entries[count].value);
            entries[count].key_len = entry.key.len;
            entries[count].value_len = entry.location.length;
            @memcpy(cursor.after[0..entry.key.len], entry.key);
            cursor.after_len = entry.key.len;
            count += 1;
        }

        return .{ .count = count, .more = false };
    }

    fn preflush(raw: *anyopaque, lease: u64) storage.Error!void {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        if (tx.lease != lease) return error.Closed;
        if (!tx.open or tx.store.failed) return error.Closed;
        if (tx.store.pending_count < 64 and
            tx.store.value_buffer.used < tx.store.value_buffer.bytes.len / 2 and
            tx.store.page_buffer.used < tx.store.page_buffer.bytes.len / 2) return;
        try flushPending(tx);
    }

    fn flushPending(tx: *Transaction) storage.Error!void {
        try flushIndex(tx);
        tx.store.value_buffer.flush(tx.store.values, tx.io) catch return tx.store.fail();
        try flushPages(tx);
    }

    fn submit(raw: *anyopaque, lease: u64) storage.Error!void {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        if (tx.lease != lease) return error.Closed;
        if (!tx.open or tx.store.failed) return error.Closed;
        try flushPending(tx);
        if (tx.store.syncing != null and tx.store.checkpoint.done.load(.acquire))
            try tx.store.finishCheckpoint(tx.io);

        if (tx.store.syncing == null) {
            try tx.store.startCheckpoint(tx.io, tx.tick, tx.root, tx.pages_end, tx.values_end);
        } else {
            tx.store.root = tx.root;
            tx.store.pages_end = tx.pages_end;
            tx.store.values_end = tx.values_end;
            tx.store.last_tick = tx.tick;
        }

        tx.open = false;
        tx.store.active = false;
    }

    fn startCheckpoint(self: *Store, io: std.Io, tick: u64, root: index.Root, pages_end: u64, values_end: u64) storage.Error!void {
        std.debug.assert(self.syncing == null and tick >= self.last_tick);
        if (self.generation == std.math.maxInt(u64)) return error.NoSpace;

        const s: Super = .{
            .magic = super_magic,
            .generation = self.generation + 1,
            .tick = tick,
            .root_page = root.page,
            .count = root.count,
            .pages_end = pages_end,
            .values_end = values_end,
            .checksum = 0,
        };
        self.checkpoint = .{
            .io = io,
            .values = self.values,
            .pages = self.pages,
            .super = self.super[@intCast(s.generation & 1)],
            .root = s,
            .values_changed = values_end != self.checkpoint_values_end,
            .pages_changed = pages_end != self.checkpoint_pages_end,
        };
        self.root = root;
        self.generation = s.generation;
        self.last_tick = tick;
        self.pages_end = pages_end;
        self.values_end = values_end;
        self.checkpoint_pages_end = pages_end;
        self.checkpoint_values_end = values_end;
        self.syncing = io.async(Checkpoint.run, .{&self.checkpoint});
    }

    fn abort(raw: *anyopaque, lease: u64) void {
        const tx: *Transaction = @ptrCast(@alignCast(raw));
        if (tx.lease != lease) return;
        tx.open = false;
        tx.store.active = false;
    }

    fn recover(self: *Store, io: std.Io) storage.Error!void {
        var selected: ?Super = null;
        var any_superblock = false;

        for (self.super) |f| {
            const stat = f.stat(io) catch return error.IoFailure;
            if (stat.size == 0) continue;
            any_superblock = true;
            if (stat.size != super_bytes) continue;

            var raw: [super_bytes]u8 = undefined;
            const count = f.readPositionalAll(io, &raw, 0) catch return error.IoFailure;
            if (count != super_bytes) return error.Corrupt;

            const s = decodeSuper(&raw) catch |err| switch (err) {
                error.UnsupportedFormat => return err,
                error.Corrupt => continue,
            };
            if (!valid(s)) continue;

            if (selected) |prior| {
                if (s.generation > prior.generation) selected = s;
            } else {
                selected = s;
            }
        }

        if (selected == null and any_superblock) return error.Corrupt;
        if (selected) |s| {
            if (s.pages_end % index.page_size != 0 or s.root_page > s.pages_end / index.page_size) return error.Corrupt;

            const page_size = (self.pages.stat(io) catch return error.IoFailure).size;
            const value_size = (self.values.stat(io) catch return error.IoFailure).size;
            if (page_size < s.pages_end) return error.Corrupt;
            if (value_size < s.values_end) return error.Corrupt;
            self.generation = s.generation;
            self.last_tick = s.tick;
            self.durable_tick = s.tick;
            self.root = .{ .page = s.root_page, .count = s.count };
            self.pages_end = s.pages_end;
            self.values_end = s.values_end;
            self.checkpoint_pages_end = s.pages_end;
            self.checkpoint_values_end = s.values_end;
            self.pages.setLength(io, s.pages_end) catch return error.IoFailure;
            self.values.setLength(io, s.values_end) catch return error.IoFailure;
        }

        if (self.generation == 0) {
            const page_size = (self.pages.stat(io) catch return error.IoFailure).size;
            const value_size = (self.values.stat(io) catch return error.IoFailure).size;
            if (page_size != 0 or value_size != 0) return error.Corrupt;
        }
    }

    fn installEmptySuperblock(self: *Store, io: std.Io) storage.Error!void {
        if (self.generation != 0) return;

        const pages = (self.pages.stat(io) catch return error.IoFailure).size;
        const values = (self.values.stat(io) catch return error.IoFailure).size;
        if (pages != 0 or values != 0) return error.Corrupt;

        const existing = (self.super[0].stat(io) catch return error.IoFailure).size;
        if (existing != 0) return;

        var s: Super = .{
            .magic = super_magic,
            .generation = 0,
            .tick = 0,
            .root_page = 0,
            .count = 0,
            .pages_end = 0,
            .values_end = 0,
            .checksum = 0,
        };
        var unchecked: [super_bytes]u8 = undefined;
        encodeSuper(&unchecked, s);
        s.checksum = sum(&unchecked);
        var bytes: [super_bytes]u8 = undefined;
        encodeSuper(&bytes, s);
        write(self.super[0], io, &bytes, 0) catch return self.fail();
        self.super[0].sync(io) catch return self.fail();
        try syncParent(io, self.paths[2]);
    }

    fn syncParent(io: std.Io, path: []const u8) storage.Error!void {
        const parent = std.fs.path.dirname(path) orelse ".";
        const file = std.Io.Dir.cwd().openFile(io, parent, .{ .allow_directory = true }) catch return error.IoFailure;
        defer file.close(io);
        file.sync(io) catch return error.IoFailure;
    }

    fn valid(s: Super) bool {
        return s.magic == super_magic;
    }

    fn encodeSuper(bytes: *[super_bytes]u8, s: Super) void {
        @memset(bytes, 0);
        std.mem.writeInt(u64, bytes[0..8], s.magic, .little);
        std.mem.writeInt(u64, bytes[8..16], s.generation, .little);
        std.mem.writeInt(u64, bytes[16..24], s.tick, .little);
        std.mem.writeInt(u64, bytes[24..32], s.root_page, .little);
        std.mem.writeInt(u64, bytes[32..40], s.count, .little);
        std.mem.writeInt(u64, bytes[40..48], s.pages_end, .little);
        std.mem.writeInt(u64, bytes[48..56], s.values_end, .little);
        std.mem.writeInt(u64, bytes[56..64], s.checksum, .little);
    }

    fn decodeSuper(bytes: *const [super_bytes]u8) error{ Corrupt, UnsupportedFormat }!Super {
        const magic = std.mem.readInt(u64, bytes[0..8], .little);
        if (magic != super_magic and magic & ~@as(u64, 255) == super_magic & ~@as(u64, 255)) return error.UnsupportedFormat;

        const checksum = std.mem.readInt(u64, bytes[56..64], .little);
        var copy = bytes.*;
        @memset(copy[56..64], 0);
        if (checksum != sum(&copy)) return error.Corrupt;

        const s: Super = .{
            .magic = std.mem.readInt(u64, bytes[0..8], .little),
            .generation = std.mem.readInt(u64, bytes[8..16], .little),
            .tick = std.mem.readInt(u64, bytes[16..24], .little),
            .root_page = std.mem.readInt(u64, bytes[24..32], .little),
            .count = std.mem.readInt(u64, bytes[32..40], .little),
            .pages_end = std.mem.readInt(u64, bytes[40..48], .little),
            .values_end = std.mem.readInt(u64, bytes[48..56], .little),
            .checksum = checksum,
        };
        if (!valid(s)) return error.Corrupt;
        return s;
    }

    fn encodeValueHeader(bytes: *[value_header_bytes]u8, header: ValueHeader) void {
        std.mem.writeInt(u32, bytes[0..4], header.length, .little);
        std.mem.writeInt(u64, bytes[4..12], header.checksum, .little);
    }

    fn sum(bytes: []const u8) u64 {
        return std.hash.XxHash64.hash(0, bytes);
    }

    fn readValue(tx: *Transaction, location: index.Location, output: []u8) storage.Error!void {
        if (location.length > output.len) return error.BufferTooSmall;

        var raw: [value_header_bytes]u8 = undefined;
        try tx.store.value_buffer.read(tx.store.values, tx.io, &raw, location.offset);
        const header: ValueHeader = .{
            .length = std.mem.readInt(u32, raw[0..4], .little),
            .checksum = std.mem.readInt(u64, raw[4..12], .little),
        };
        if (header.length != location.length) return error.Corrupt;
        try tx.store.value_buffer.read(tx.store.values, tx.io, output[0..location.length], location.offset + value_header_bytes);
        if (header.checksum != sum(output[0..location.length])) return error.Corrupt;
    }

    fn write(f: std.Io.File, io: std.Io, bytes: []const u8, at: u64) storage.Error!void {
        f.writePositionalAll(io, bytes, at) catch return error.IoFailure;
    }

    fn fail(self: *Store) storage.Error {
        self.failed = true;
        return error.IoFailure;
    }
};

test "batched private pages preserve committed data across abort and reopen" {
    try std.testing.expectEqual(@as(u64, 0xef46db3751d8e999), Store.sum(""));
    var old_header: [Store.super_bytes]u8 = @splat(0);
    std.mem.writeInt(u64, old_header[0..8], 0x4c5253544f524531, .little);
    try std.testing.expectError(error.UnsupportedFormat, Store.decodeSuper(&old_header));
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/world", .{directory.sub_path});
    const options: Store.Options = .{ .path = path, .max_value_bytes = 8192 };
    var first = try Store.init(std.testing.allocator, io, options);
    {
        defer first.deinit(io);
        var tx = try first.interface().begin(io, 1);
        errdefer tx.abort();
        const records = try tx.namespace("chunks");

        for (0..6000) |i| {
            var key: [4]u8 = undefined;
            std.mem.writeInt(u32, &key, @intCast((i * 7919) % 6000), .big);
            try records.put(&key, &key);
            var value: [4]u8 = undefined;
            try std.testing.expectEqual(@as(?usize, 4), try records.get(&key, &value));
            try std.testing.expectEqualSlices(u8, &key, &value);
        }

        const before = first.transaction.values_end;

        for (0..1000) |_| try records.put("repeated", "value");
        try std.testing.expectEqual(before + Store.value_header_bytes + 5, first.transaction.values_end);
        try records.put("repeated", null);
        const linear = try tx.namespace("linear");

        for (0..32) |i| {
            const key: [1]u8 = .{@intCast(i)};
            const value: [32]u8 = @splat(@intCast(i));
            try linear.put(&key, value[0..i]);
        }

        try tx.submit();
        try std.testing.expectEqual(@as(u64, 1), first.interface().lastTick());
        try std.testing.expect(first.pages_end < 2 * 1024 * 1024);
        try std.testing.expect(first.page_buffer.writes < 16);
        try std.testing.expect(first.value_buffer.writes < 16);
        var abandoned = try first.interface().begin(io, 2);
        defer abandoned.abort();
        const replacements = try abandoned.namespace("chunks");
        const oversized: [8192]u8 = @splat(0xaa);

        for (0..6000) |i| {
            var key: [4]u8 = undefined;
            std.mem.writeInt(u32, &key, @intCast(i), .big);
            try replacements.put(&key, &oversized);

            if (i % 127 == 0) try replacements.put(&key, null);
        }

        try abandoned.preflush();

        try first.interface().flush(io);
        try std.testing.expectEqual(@as(u64, 1), first.interface().durableTick());
    }
    var second = try Store.init(std.testing.allocator, io, options);
    defer second.deinit(io);
    try std.testing.expectEqual(@as(u64, 1), second.interface().durableTick());
    var tx = try second.interface().begin(io, 2);
    defer tx.abort();
    const records = try tx.namespace("chunks");
    const linear = try tx.namespace("linear");
    var keys: [32][1]u8 = undefined;
    var values: [32][32]u8 = undefined;
    var reads: [32]storage.Get = undefined;
    var lengths: [32]?usize = undefined;

    for (&keys, &values, &reads, 0..) |*key, *value, *request, i| {
        key.* = .{@intCast(31 - i)};
        request.* = .{ .key = key, .destination = value };
    }

    const before_reads = second.value_reads;
    try linear.getBatch(&reads, &lengths);
    try std.testing.expect(second.value_reads - before_reads <= 8);

    for (values, lengths, 0..) |value, length, i| {
        try std.testing.expectEqual(@as(?usize, 31 - i), length);

        for (value[0..length.?]) |byte| try std.testing.expectEqual(@as(u8, @intCast(31 - i)), byte);
    }

    var batch_keys: [192][4]u8 = undefined;
    var batch_values: [192][4]u8 = undefined;
    var batch_reads: [192]storage.Get = undefined;
    var batch_lengths: [192]?usize = undefined;

    for (&batch_keys, &batch_values, &batch_reads, 0..) |*key, *value, *request, i| {
        std.mem.writeInt(u32, key, @intCast(i * 29), .big);
        request.* = .{ .key = key, .destination = value };
    }

    try records.getBatch(&batch_reads, &batch_lengths);

    for (batch_keys, batch_values, batch_lengths) |key, value, length| {
        try std.testing.expectEqual(@as(?usize, 4), length);
        try std.testing.expectEqualSlices(u8, &key, &value);
    }

    for (0..6000) |i| {
        var key: [4]u8 = undefined;
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        try std.testing.expectEqual(@as(?usize, 4), try records.get(&key, &value));
        try std.testing.expectEqualSlices(u8, &key, &value);
    }

    try records.put("after-abort", "committed");

    for (0..2000) |i| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i * 3), .big);
        try records.put(&key, null);
    }

    try tx.submit();
    try second.interface().flush(io);
    var verification = try second.interface().begin(io, 3);
    defer verification.abort();
    const remaining = try verification.namespace("chunks");

    for (0..6000) |i| {
        var key: [4]u8 = undefined;
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i), .big);
        const length = try remaining.get(&key, &value);
        try std.testing.expectEqual(if (i % 3 == 0) @as(?usize, null) else @as(?usize, 4), length);

        if (length != null) try std.testing.expectEqualSlices(u8, &key, &value);
    }

    const corrupt_at = (try index.lookup(Store.treeIo(&second.transaction), second.transaction.root, &second.workspace, "linear", &.{1})).?;
    try Store.write(second.values, io, &.{255}, corrupt_at.offset + Store.value_header_bytes);
    var pair_values: [2][32]u8 = undefined;
    const pair: [2]storage.Get = .{ .{ .key = &.{1}, .destination = &pair_values[0] }, .{ .key = &.{2}, .destination = &pair_values[1] } };
    var pair_lengths: [2]?usize = undefined;
    const checked = try verification.namespace("linear");
    try std.testing.expectError(error.Corrupt, checked.getBatch(&pair, &pair_lengths));
    try Store.write(second.values, io, &.{1}, corrupt_at.offset + Store.value_header_bytes);
    try checked.getBatch(&pair, &pair_lengths);
    verification.abort();
    var failing = io.vtable.*;
    failing.fileSync = struct {
        fn sync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    }.sync;
    const faulty_io: std.Io = .{ .userdata = io.userdata, .vtable = &failing };
    const failed = try second.interface().begin(faulty_io, 4);
    try (try failed.namespace("chunks")).put("unacknowledged", "value");
    try failed.submit();
    try std.testing.expectError(error.IoFailure, second.interface().flush(io));
    try std.testing.expectEqual(@as(u64, 2), second.interface().durableTick());
    try std.testing.expectError(error.Closed, second.interface().begin(io, 5));
}
