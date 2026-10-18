const std = @import("std");
const builtin = @import("builtin");
const metrics = @import("metrics");
const format = @import("format.zig");
const backend = @import("io.zig");
const wal_index = @import("index.zig");

const assert = std.debug.assert;
pub const Error = format.Error;
pub const Page = format.Page;
pub const PageId = format.PageId;
pub const SpaceId = format.SpaceId;
pub const CommitId = format.CommitId;
pub const page_size = format.page_size;
pub const batch_size = backend.maximum_batch;
pub const Read = struct { id: PageId, destination: []u8, offset: u16 = 0 };
pub const Write = struct { id: PageId, source: *const Page };
pub const Maintenance = enum { idle, progressed, waiting };

pub const Space = struct {
    store: *Store,
    id: SpaceId,
    store_is_new: bool,

    pub fn getRoot(self: Space) Error!?PageId {
        try self.store.check();
        const root = self.store.metadata.spaces[@intFromEnum(self.id) - 1].root;
        return if (root == 0) null else @enumFromInt(root);
    }
    pub fn setRoot(self: Space, root: ?PageId) Error!void {
        try self.store.check();
        if (root) |id| {
            var block: format.Block = undefined;
            try self.store.readBlock(@intFromEnum(id), @intFromEnum(self.id), &block);
        }
        self.store.metadata.spaces[@intFromEnum(self.id) - 1].root = if (root) |id| @intFromEnum(id) else 0;
    }
    pub fn allocatePages(self: Space, ids: []PageId) Error!void {
        try self.store.allocatePages(self.id, ids);
    }
    pub fn freePages(self: Space, ids: []const PageId) Error!void {
        try self.store.freePages(self.id, ids);
    }
    pub fn readPages(self: Space, reads: []const Read) Error!void {
        try self.store.readPages(self.id, reads);
    }
    /// Source buffers may be reused on return. The owner requests durability separately.
    pub fn writePages(self: Space, writes: []const Write) Error!void {
        try self.store.writePages(self.id, writes);
    }
    pub fn fail(self: Space) void {
        self.store.failed = true;
    }
};

pub const Transaction = struct {
    store: *Store,
    pub fn openSpace(self: Transaction, name: []const u8) Error!Space {
        return self.store.openSpace(name);
    }
    pub fn progress(self: Transaction) Error!void {
        try self.store.progress();
    }
    pub fn fail(self: Transaction) void {
        self.store.failed = true;
    }
};

/// A single owner submits page batches. Spaces borrow the store's stable address.
pub const Store = struct {
    pub const Options = struct {
        path: []const u8,
        metrics: ?*metrics.Registry = null,
        submission: backend.Mode = if (builtin.os.tag == .linux) .uring else .standard,
        maximum_wal_pages: u32 = 65536,
        maximum_pages: u64 = 1 << 32,
        checkpoint_bytes: u64 = 64 * 1024 * 1024,
    };
    const CachedPage = struct { id: u64 = 0, touched: u64 = 0, block: format.Block = undefined };
    const Buffers = struct {
        frames: [batch_size]format.Frame,
        blocks: [batch_size]format.Block,
        free_pages: [batch_size]Page,
    };
    const CheckpointPage = struct { id: u64, offset: u64 };
    const Phase = enum { idle, copying, database_sync, replacement_sync, replacement_copy, directory_sync };
    const Sync = enum { none, wal };
    const CommitMetrics = struct {
        total: metrics.Timer = .{},
        cpu: metrics.Timer = .{},
        initialize: metrics.Timer = .{},
        checksum: metrics.Timer = .{},
        marker: metrics.Timer = .{},
        publish: metrics.Timer = .{},
        rewritten_frames: metrics.Counter = .{},

        fn init(registry: ?*metrics.Registry) !CommitMetrics {
            const owner = registry orelse return .{};
            return .{
                .total = try owner.timer(.{ .name = "storage.commit", .description = "Publish a complete WAL transaction" }),
                .cpu = try owner.timer(.{ .name = "storage.commit.cpu", .description = "Commit work on the owning thread", .clock = .thread_cpu }),
                .initialize = try owner.timer(.{ .name = "storage.commit.initialize", .description = "Write allocated pages without an application image" }),
                .checksum = try owner.timer(.{ .name = "storage.commit.checksum", .description = "Checksum the final ordered frame hashes" }),
                .marker = try owner.timer(.{ .name = "storage.commit.marker", .description = "Encode and submit the commit frame" }),
                .publish = try owner.timer(.{ .name = "storage.commit.publish", .description = "Publish committed page locations and metadata" }),
                .rewritten_frames = try owner.counter(.{ .name = "storage.wal_rewritten_frames", .description = "Existing uncommitted frames replaced by application writes" }),
            };
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    filesystem: backend.Io,
    checkpoint_io: backend.Io,
    directory: std.Io.Dir,
    database: std.Io.File,
    wal: std.Io.File,
    replacement: ?std.Io.File = null,
    replacement_end: u64 = format.header_size,
    replacement_at: usize = 0,
    name: []u8,
    wal_name: []u8,
    temporary_name: []u8,
    limits: struct { maximum_wal_pages: u32, maximum_pages: u64, checkpoint_bytes: u64 },
    metadata: format.Metadata,
    saved: format.Metadata,
    locations: wal_index.Index,
    checksums: [][8]u8,
    replacement_checksums: [][8]u8,
    dirty: []u64,
    dirty_count: usize = 0,
    checkpoint_pages: []CheckpointPage,
    cache: []CachedPage,
    buffers: *Buffers,
    cache_clock: u64 = 0,
    cache_hits: metrics.Counter = .{},
    checkpoint_count: usize = 0,
    checkpoint_at: usize = 0,
    checkpoint_metadata: format.Metadata = undefined,
    phase: Phase = .idle,
    syncing: Sync = .none,
    syncing_sequence: u64 = 0,
    syncing_tick: u64 = 0,
    requested_sequence: u64 = 0,
    durable_sequence: u64 = 0,
    durable_tick: u64 = 0,
    end: u64 = format.header_size,
    committed_end: u64 = format.header_size,
    commit_hash: u64 = 0,
    failed: bool = false,
    wal_bytes: metrics.Counter = .{},
    read_bytes: metrics.Counter = .{},
    read_batches: metrics.Counter = .{},
    read_pages: metrics.Counter = .{},
    checkpoint_bytes: metrics.Counter = .{},
    commits: metrics.Counter = .{},
    sync_wait: metrics.Timer = .{},
    sync_wait_cpu: metrics.Timer = .{},
    commit_metrics: CommitMetrics = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Store {
        if (options.path.len == 0 or options.maximum_wal_pages < batch_size or options.maximum_wal_pages > 1 << 24 or options.maximum_pages < 2 or options.maximum_pages > @as(u64, std.math.maxInt(i64)) / format.block_size or options.checkpoint_bytes < format.header_size) return error.InvalidArgument;
        const directory_timer = try initializationTimer(options.metrics, "directory", "Open the database directory and publish new ancestors");
        const paths_timer = try initializationTimer(options.metrics, "paths", "Allocate database and WAL filenames");
        const database_timer = try initializationTimer(options.metrics, "database", "Open and lock the database file");
        const header_timer = try initializationTimer(options.metrics, "header", "Read and validate the database header or establish a new database");
        const wal_timer = try initializationTimer(options.metrics, "wal", "Open the WAL or establish a new WAL");
        const buffers_timer = try initializationTimer(options.metrics, "buffers", "Allocate page buffers, cache, dirty IDs, and maintenance tasks");
        const dirty_timer = try initializationTimer(options.metrics, "buffers.dirty", "Allocate dirty page IDs");
        const tasks_timer = try initializationTimer(options.metrics, "buffers.maintenance", "Allocate bounded maintenance tasks");
        const cache_timer = try initializationTimer(options.metrics, "buffers.cache", "Allocate and initialize the page read cache");
        const io_buffers_timer = try initializationTimer(options.metrics, "buffers.io", "Allocate reusable page I/O buffers");
        const wal_ring_timer = try initializationTimer(options.metrics, "wal_ring", "Initialize WAL I/O submission");
        const checkpoint_ring_timer = try initializationTimer(options.metrics, "maintenance_ring", "Initialize maintenance I/O submission");
        const index_timer = try initializationTimer(options.metrics, "index_allocate", "Allocate the bounded WAL page index");
        const index_cpu = if (options.metrics) |registry| try registry.timer(.{ .name = "storage.initialize.index_allocate.cpu", .description = "WAL index allocation on the owning thread", .clock = .thread_cpu }) else metrics.Timer{};
        const recovery_timer = try initializationTimer(options.metrics, "recovery", "Validate committed WAL frames and rebuild the page index");
        const sync_wait = if (options.metrics) |registry| try registry.timer(.{ .namespace = "storage", .name = "durability_wait", .description = "Wait for requested commit durability" }) else metrics.Timer{};
        const sync_wait_cpu = if (options.metrics) |registry| try registry.timer(.{ .namespace = "storage", .name = "durability_wait.cpu", .description = "Commit durability wait on the owning thread", .clock = .thread_cpu }) else metrics.Timer{};
        const cpu_timer = if (options.metrics) |registry| try registry.timer(.{ .namespace = "storage.initialize", .name = "cpu", .description = "Storage initialization on the owning thread", .clock = .thread_cpu }) else metrics.Timer{};
        const cpu_started = cpu_timer.start();
        defer cpu_started.end();
        const directory_started = directory_timer.start();
        const parent = std.fs.path.dirname(options.path) orelse ".";
        const created = try std.Io.Dir.cwd().createDirPathStatus(io, parent, .default_dir);
        const directory = try std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true });
        errdefer directory.close(io);
        if (created == .created) {
            var ancestor: ?[]const u8 = parent;
            while (ancestor) |path| {
                const folder = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
                defer folder.close(io);
                try syncDirectory(io, folder);
                ancestor = std.fs.path.dirname(path);
                if (ancestor == null and !std.fs.path.isAbsolute(path) and !std.mem.eql(u8, path, ".")) ancestor = ".";
            }
        }
        directory_started.end();
        const paths_started = paths_timer.start();
        const name = try allocator.dupe(u8, std.fs.path.basename(options.path));
        errdefer allocator.free(name);
        const wal_name = try std.fmt.allocPrint(allocator, "{s}.wal", .{name});
        errdefer allocator.free(wal_name);
        const temporary_name = try std.fmt.allocPrint(allocator, "{s}.wal.next", .{name});
        errdefer allocator.free(temporary_name);
        paths_started.end();
        const database_started = database_timer.start();
        const database = try directory.createFile(io, name, .{ .read = true, .truncate = false });
        errdefer database.close(io);
        if (builtin.os.tag == .linux) {
            const result = std.os.linux.flock(database.handle, std.posix.LOCK.EX | std.posix.LOCK.NB);
            if (std.os.linux.errno(result) != .SUCCESS) return error.DatabaseLocked;
        }
        database_started.end();
        const header_started = header_timer.start();
        var metadata: format.Metadata = undefined;
        const new = (try database.stat(io)).size == 0;
        var valid_database = true;
        if (new) {
            var identity: [16]u8 = undefined;
            io.random(&identity);
            metadata = .{ .identity = identity };
            var block: format.Block = undefined;
            const page = metadata.encode();
            format.seal(&block, 0, 0, 0, &page);
            try database.writePositionalAll(io, &block, 0);
            try database.sync(io);
            try syncDirectory(io, directory);
        } else {
            var block: format.Block = undefined;
            if (try database.readPositionalAll(io, &block, 0) != block.len) return error.Corrupt;
            format.validate(&block, 0, 0) catch {
                valid_database = false;
            };
            metadata = format.Metadata.decode(block[32..]) catch blk: {
                valid_database = false;
                break :blk .{ .identity = @splat(0) };
            };
        }
        header_started.end();
        const wal_started = wal_timer.start();
        const wal = directory.openFile(io, wal_name, .{ .mode = .read_write }) catch |err| blk: {
            if (err != error.FileNotFound or (!new and (!valid_database or metadata.sequence != 0))) return err;
            const file = try directory.createFile(io, wal_name, .{ .read = true, .exclusive = true });
            errdefer file.close(io);
            const header = format.walHeader(metadata.identity, 0);
            try file.writePositionalAll(io, &header, 0);
            try file.sync(io);
            try syncDirectory(io, directory);
            break :blk file;
        };
        errdefer wal.close(io);
        wal_started.end();
        const buffers_started = buffers_timer.start();
        const dirty_started = dirty_timer.start();
        const dirty = try allocator.alloc(u64, options.maximum_wal_pages);
        errdefer allocator.free(dirty);
        dirty_started.end();
        const tasks_started = tasks_timer.start();
        const checkpoint_pages = try allocator.alloc(CheckpointPage, options.maximum_wal_pages);
        errdefer allocator.free(checkpoint_pages);
        tasks_started.end();
        const cache_started = cache_timer.start();
        const cache = try allocator.alloc(CachedPage, 64);
        errdefer allocator.free(cache);
        for (cache) |*entry| {
            entry.id = 0;
            entry.touched = 0;
        }
        cache_started.end();
        const io_buffers_started = io_buffers_timer.start();
        const buffers = try allocator.create(Buffers);
        errdefer allocator.destroy(buffers);
        io_buffers_started.end();
        buffers_started.end();
        const wal_ring_started = wal_ring_timer.start();
        var filesystem = try backend.Io.init(io, options.submission);
        errdefer filesystem.deinit();
        wal_ring_started.end();
        const checkpoint_ring_started = checkpoint_ring_timer.start();
        var checkpoint_io = try backend.Io.init(io, options.submission);
        errdefer checkpoint_io.deinit();
        checkpoint_ring_started.end();
        const index_started = index_timer.start();
        const index_cpu_started = index_cpu.start();
        var locations = try wal_index.Index.init(allocator, options.maximum_wal_pages);
        errdefer locations.deinit(allocator);
        const checksums = try allocator.alloc([8]u8, options.maximum_wal_pages);
        errdefer allocator.free(checksums);
        const replacement_checksums = try allocator.alloc([8]u8, options.maximum_wal_pages);
        errdefer allocator.free(replacement_checksums);
        index_cpu_started.end();
        index_started.end();
        var self: Store = .{ .allocator = allocator, .io = io, .filesystem = filesystem, .checkpoint_io = checkpoint_io, .directory = directory, .database = database, .wal = wal, .name = name, .wal_name = wal_name, .temporary_name = temporary_name, .limits = .{ .maximum_wal_pages = options.maximum_wal_pages, .maximum_pages = options.maximum_pages, .checkpoint_bytes = options.checkpoint_bytes }, .metadata = metadata, .saved = metadata, .locations = locations, .checksums = checksums, .replacement_checksums = replacement_checksums, .dirty = dirty, .checkpoint_pages = checkpoint_pages, .cache = cache, .buffers = buffers, .sync_wait = sync_wait, .sync_wait_cpu = sync_wait_cpu };
        self.commit_metrics = try CommitMetrics.init(options.metrics);
        const recovery_started = recovery_timer.start();
        try self.recover(valid_database, options.metrics);
        recovery_started.end();
        if (options.metrics) |registry| {
            self.wal_bytes = try registry.counter(.{ .namespace = "storage", .name = "wal_bytes", .description = "Page images and transaction markers submitted to the WAL", .unit = .bytes });
            self.cache_hits = try registry.counter(.{ .namespace = "storage", .name = "page_cache_hits", .description = "Page reads served from validated memory" });
            self.read_bytes = try registry.counter(.{ .namespace = "storage", .name = "read_bytes", .description = "Page bytes read", .unit = .bytes });
            self.read_batches = try registry.counter(.{ .namespace = "storage", .name = "read_batches", .description = "Application page read batches submitted" });
            self.read_pages = try registry.counter(.{ .namespace = "storage", .name = "read_pages", .description = "Application pages fetched through batched reads" });
            self.checkpoint_bytes = try registry.counter(.{ .namespace = "storage", .name = "checkpoint_bytes", .description = "Committed page bytes copied into the database", .unit = .bytes });
            self.commits = try registry.counter(.{ .namespace = "storage", .name = "commits", .description = "Complete simulation saves published" });
            const index_pages = try registry.gauge(.{ .namespace = "storage", .name = "restored_index_pages", .description = "Page locations restored during storage initialization" });
            index_pages.set(self.locations.count());
        }
        return self;
    }

    fn initializationTimer(registry: ?*metrics.Registry, comptime name: []const u8, description: []const u8) metrics.Registry.Error!metrics.Timer {
        return if (registry) |owner| owner.timer(.{ .namespace = "storage.initialize", .name = name, .description = description }) else .{};
    }

    fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
        const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
        try file.sync(io);
    }

    fn recover(self: *Store, valid_database: bool, registry: ?*metrics.Registry) !void {
        const read_timer = try initializationTimer(registry, "recovery.read", "Read sequential WAL frame batches");
        const validate_timer = try initializationTimer(registry, "recovery.validate", "Validate frames and commits including index publication");
        const index_timer = try initializationTimer(registry, "recovery.index", "Publish validated transaction descriptors into the page index");
        const sync_timer = try initializationTimer(registry, "recovery.sync", "Establish the recovered WAL prefix durably");
        const RecoveredPage = struct { id: u64, offset: u64, owner: u32 };
        const pending = try self.allocator.alloc(RecoveredPage, self.limits.maximum_wal_pages);
        defer self.allocator.free(pending);
        var pending_count: usize = 0;
        var pending_overflow = false;
        var header: [format.header_size]u8 = undefined;
        if (try self.wal.readPositionalAll(self.io, &header, 0) != header.len or !std.mem.eql(u8, header[0..8], "LRWAL002") or format.get(u64, &header, 56) != format.checksum(header[0..56])) return error.Corrupt;
        const identity = header[8..24].*;
        const base = format.get(u64, &header, 24);
        if (valid_database and (!std.mem.eql(u8, &identity, &self.metadata.identity) or base > self.metadata.sequence)) return error.Corrupt;
        var sequence = base;
        var previous: u64 = 0;
        var digest = format.transaction(previous);
        var offset: u64 = header.len;
        var end: u64 = offset;
        var committed_hash: u64 = 0;
        var recovered: ?format.Metadata = null;
        const size = (try self.wal.stat(self.io)).size;
        const frames = &self.buffers.frames;
        scan: while (offset + @sizeOf(format.Frame) <= size) {
            const count: usize = @intCast(@min(batch_size, (size - offset) / @sizeOf(format.Frame)));
            const bytes = std.mem.sliceAsBytes(frames[0..count]);
            const read_started = read_timer.start();
            if (try self.wal.readPositionalAll(self.io, bytes, offset) != bytes.len) return error.Corrupt;
            read_started.end();
            const validate_started = validate_timer.start();
            defer validate_started.end();
            for (frames[0..count]) |*frame| {
                if (!format.validateFrame(frame, offset)) break :scan;
                const block: *format.Block = frame[32..];
                const id = format.get(u64, block, 8);
                // The frame checksum already covers the complete embedded block.
                if (!std.mem.eql(u8, block[0..4], "LRPG")) break :scan;
                if (sequence == std.math.maxInt(u64) or format.get(u64, block, 16) != sequence + 1) return error.Corrupt;
                if (id >= self.limits.maximum_pages) return error.NoSpace;
                offset += frame.len;
                if (std.mem.eql(u8, frame[0..8], "LRCOMMIT")) {
                    if (id != 0 or format.get(u32, block, 4) != 0 or format.get(u64, frame, 24) != digest.final()) break :scan;
                    const meta = try format.Metadata.decode(block[32..]);
                    if (meta.sequence != sequence + 1 or !std.mem.eql(u8, &meta.identity, &identity)) return error.Corrupt;
                    if (meta.pages > self.limits.maximum_pages) return error.NoSpace;
                    if (recovered) |last| {
                        if (meta.tick < last.tick) break :scan;
                        if (meta.pages < last.pages) return error.Corrupt;
                    }
                    if (pending_overflow) return error.NoSpace;
                    const index_started = index_timer.start();
                    defer index_started.end();
                    for (pending[0..pending_count]) |page| {
                        if (page.id >= meta.pages) return error.Corrupt;
                        if (!self.locations.contains(page.id) and self.locations.count() == self.limits.maximum_wal_pages) return error.NoSpace;
                        self.locations.putAssumeCapacity(page.id, .{ .current = page.offset, .committed = page.offset, .owner = page.owner });
                    }
                    if (!self.locations.contains(0) and self.locations.count() == self.limits.maximum_wal_pages) return error.NoSpace;
                    self.locations.putAssumeCapacity(0, .{ .current = offset - frame.len, .committed = offset - frame.len, .owner = 0 });
                    pending_count = 0;
                    pending_overflow = false;
                    recovered = meta;
                    sequence += 1;
                    end = offset;
                    previous = format.get(u64, frame, 16);
                    committed_hash = previous;
                    digest = format.transaction(previous);
                } else {
                    if (id == 0) break :scan;
                    digest.update(frame[16..24]);
                    if (pending_count < pending.len) {
                        pending[pending_count] = .{ .id = id, .offset = offset - frame.len, .owner = format.get(u32, block, 4) };
                        pending_count += 1;
                    } else pending_overflow = true;
                }
            }
        }
        if (recovered) |meta| {
            if (valid_database and meta.sequence < self.metadata.sequence) return error.Corrupt;
            self.metadata = meta;
        } else if (!valid_database or base != self.metadata.sequence) return error.Corrupt;
        if (self.metadata.pages > self.limits.maximum_pages) return error.NoSpace;
        self.saved = self.metadata;
        self.durable_sequence = self.saved.sequence;
        self.durable_tick = self.saved.tick;
        self.end = end;
        self.committed_end = end;
        self.commit_hash = committed_hash;
        // Establish the recovered prefix before overwriting an incomplete transaction.
        const sync_started = sync_timer.start();
        defer sync_started.end();
        if (size != end) try self.wal.setLength(self.io, end);
        try self.wal.sync(self.io);
    }

    pub fn hasWrites(self: *const Store) bool {
        return self.dirty_count != 0 or !std.meta.eql(self.metadata, self.saved);
    }
    pub fn lastCommit(self: *const Store) CommitId {
        return @enumFromInt(self.saved.sequence);
    }
    pub fn transaction(self: *Store) Transaction {
        return .{ .store = self };
    }
    pub fn lastTick(self: *const Store) u64 {
        return self.saved.tick;
    }
    pub fn durableTick(self: *const Store) u64 {
        return self.durable_tick;
    }
    pub fn memoryBytes(self: *const Store) usize {
        return @sizeOf(Buffers) + self.cache.len * @sizeOf(CachedPage) + self.dirty.len * @sizeOf(u64) + self.checkpoint_pages.len * @sizeOf(CheckpointPage) + self.locations.memoryBytes() + (self.checksums.len + self.replacement_checksums.len) * @sizeOf([8]u8);
    }
    fn check(self: *Store) Error!void {
        if (self.failed) return error.FailedTransaction;
    }

    pub fn openSpace(self: *Store, name: []const u8) Error!Space {
        try self.check();
        if (name.len == 0 or name.len > format.maximum_name) return error.InvalidArgument;
        var empty: ?usize = null;
        for (self.metadata.spaces, 0..) |space, index| {
            if (space.length == name.len and std.mem.eql(u8, space.name[0..space.length], name)) return .{ .store = self, .id = @enumFromInt(index + 1), .store_is_new = self.saved.sequence == 0 };
            if (empty == null and space.length == 0) empty = index;
        }
        const index = empty orelse return error.NoSpace;
        self.metadata.spaces[index].length = @intCast(name.len);
        @memcpy(self.metadata.spaces[index].name[0..name.len], name);
        return .{ .store = self, .id = @enumFromInt(index + 1), .store_is_new = self.saved.sequence == 0 };
    }

    fn cached(self: *Store, id: u64) ?*const format.Block {
        for (self.cache) |*entry| {
            if (entry.touched == 0 or entry.id != id) continue;
            self.cache_clock +|= 1;
            entry.touched = self.cache_clock;
            self.cache_hits.add(1);
            return &entry.block;
        }
        return null;
    }
    fn remember(self: *Store, id: u64, block: *const format.Block) void {
        var victim: usize = 0;
        for (self.cache, 0..) |*entry, index| {
            if (entry.touched != 0 and entry.id == id) {
                victim = index;
                break;
            }
            if (entry.touched < self.cache[victim].touched) victim = index;
        }
        self.cache_clock +|= 1;
        self.cache[victim] = .{ .id = id, .touched = self.cache_clock, .block = block.* };
    }

    fn readBlock(self: *Store, id: u64, owner: ?u32, output: *format.Block) Error!void {
        if (id >= self.metadata.pages) return error.InvalidArgument;
        const location = self.locations.get(id);
        if (location) |entry| if (entry.current == 0) {
            const zero: Page = @splat(0);
            format.seal(output, id, entry.owner, self.saved.sequence + 1, &zero);
            try format.validate(output, id, owner);
            return;
        };
        if (self.cached(id)) |block| {
            if (owner) |expected| if (format.get(u32, block, 4) != expected) return error.Corrupt;
            output.* = block.*;
            return;
        }
        try self.filesystem.read(&.{.{ .file = if (location != null) self.wal else self.database, .offset = if (location) |at| at.current + 32 else id * format.block_size, .bytes = output }});
        try format.validate(output, id, owner);
        self.remember(id, output);
        self.read_bytes.add(output.len);
    }

    fn readPages(self: *Store, space: SpaceId, reads: []const Read) Error!void {
        try self.check();
        errdefer self.failed = true;
        const blocks = &self.buffers.blocks;
        var requests: [batch_size]backend.Io.Read = undefined;
        var start: usize = 0;
        while (start < reads.len) {
            const count = @min(batch_size, reads.len - start);
            var reading: usize = 0;
            var verified: [batch_size]bool = @splat(false);
            for (reads[start..][0..count], blocks[0..count], verified[0..count]) |read, *block, *valid| {
                const id = @intFromEnum(read.id);
                if (id == 0 or id >= self.metadata.pages or read.offset > page_size or read.destination.len > page_size - read.offset) return error.InvalidArgument;
                const location = self.locations.get(id);
                if (location) |entry| if (entry.current == 0) {
                    const zero: Page = @splat(0);
                    format.seal(block, id, entry.owner, self.saved.sequence + 1, &zero);
                    continue;
                };
                if (self.cached(id)) |cached_block| {
                    block.* = cached_block.*;
                    valid.* = true;
                    continue;
                }
                requests[reading] = .{ .file = if (location != null) self.wal else self.database, .offset = if (location) |at| at.current + 32 else id * format.block_size, .bytes = block };
                reading += 1;
            }
            try self.filesystem.read(requests[0..reading]);
            if (reading != 0) self.read_batches.add(1);
            self.read_pages.add(reading);
            for (reads[start..][0..count], blocks[0..count], verified[0..count]) |read, *block, valid| {
                if (!valid) {
                    try format.validate(block, @intFromEnum(read.id), @intFromEnum(space));
                    self.remember(@intFromEnum(read.id), block);
                } else if (format.get(u32, block, 4) != @intFromEnum(space)) return error.Corrupt;
                @memcpy(read.destination, block[32 + @as(usize, read.offset) ..][0..read.destination.len]);
            }
            self.read_bytes.add(reading * format.block_size);
            start += count;
        }
    }

    fn append(self: *Store, ids: []const u64, owners: []const u32, pages: []const *const Page, digest: ?u64) Error!void {
        assert(ids.len == owners.len and ids.len == pages.len and ids.len <= batch_size);
        const committing = digest != null;
        assert(!committing or (ids.len == 1 and ids[0] == 0));
        try self.check();
        errdefer self.failed = true;
        var added: usize = 0;
        for (ids, 0..) |id, at| {
            if (self.locations.contains(id)) continue;
            var duplicate = false;
            for (ids[0..at]) |previous| {
                if (previous == id) duplicate = true;
            }
            if (!duplicate) added += 1;
        }
        if (self.locations.count() + added > self.limits.maximum_wal_pages) return error.NoSpace;
        const frames = &self.buffers.frames;
        var indices: [batch_size]usize = undefined;
        var offsets: [batch_size]u64 = undefined;
        var count: usize = 0;
        var end = self.end;
        for (ids, owners, pages, 0..) |id, owner, page, index| {
            if (std.mem.indexOfScalar(u64, ids[index + 1 ..], id) != null) continue;
            const existing = if (self.locations.get(id)) |location| location.uncommitted else 0;
            const offset = if (existing != 0 and !committing) existing else end;
            assert(offset >= self.committed_end);
            if (offset == end) end += @sizeOf(format.Frame);
            const block = &self.buffers.blocks[0];
            format.seal(block, id, owner, self.saved.sequence + 1, page);
            _ = format.frame(&frames[count], block, offset, digest);
            indices[count] = index;
            offsets[count] = offset;
            count += 1;
        }
        var requests: [batch_size]backend.Io.Write = undefined;
        var request_count: usize = 0;
        for (offsets[0..count], 0..) |offset, index| {
            if (request_count != 0 and requests[request_count - 1].offset + requests[request_count - 1].bytes.len == offset) {
                const previous = &requests[request_count - 1];
                previous.bytes = previous.bytes.ptr[0 .. previous.bytes.len + @sizeOf(format.Frame)];
            } else {
                requests[request_count] = .{ .file = self.wal, .offset = offset, .bytes = &frames[index] };
                request_count += 1;
            }
        }
        try self.filesystem.writeBatch(requests[0..request_count]);
        for (indices[0..count], offsets[0..count], 0..) |index, offset, frame_index| {
            if (offset < self.end) self.commit_metrics.rewritten_frames.add(1);
            if (!committing) {
                const slot: usize = @intCast((offset - self.committed_end) / @sizeOf(format.Frame));
                assert(slot < self.checksums.len);
                self.checksums[slot] = frames[frame_index][16..24].*;
            }
            const id = ids[index];
            const result = self.locations.getOrPutAssumeCapacity(id);
            if (!result.found_existing) result.value_ptr.* = .{ .current = 0, .owner = owners[index] };
            const location = result.value_ptr;
            location.current = offset;
            location.uncommitted = offset;
            location.replacement_dirty = true;
            location.owner = owners[index];
            self.remember(id, frames[frame_index][32..]);
            if (!location.dirty) {
                self.dirty[self.dirty_count] = id;
                self.dirty_count += 1;
                location.dirty = true;
            }
        }
        self.end = end;
        if (committing) self.commit_hash = format.get(u64, &frames[0], 16);
        self.wal_bytes.add(count * @sizeOf(format.Frame));
    }

    fn writePages(self: *Store, space: SpaceId, writes: []const Write) Error!void {
        try self.check();
        errdefer self.failed = true;
        var ids: [batch_size]u64 = undefined;
        const owners: [batch_size]u32 = @splat(@intFromEnum(space));
        var pages: [batch_size]*const Page = undefined;
        var start: usize = 0;
        while (start < writes.len) {
            const count = @min(batch_size, writes.len - start);
            for (writes[start..][0..count], ids[0..count], pages[0..count]) |write, *id, *page| {
                id.* = @intFromEnum(write.id);
                if (id.* == 0 or id.* >= self.metadata.pages) return error.InvalidArgument;
                if (self.locations.get(id.*)) |entry| {
                    if (entry.owner != @intFromEnum(space)) return error.InvalidArgument;
                } else {
                    var old: format.Block = undefined;
                    try self.readBlock(id.*, @intFromEnum(space), &old);
                }
                page.* = write.source;
            }
            try self.append(ids[0..count], owners[0..count], pages[0..count], null);
            start += count;
        }
    }

    fn allocatePages(self: *Store, space: SpaceId, ids: []PageId) Error!void {
        try self.check();
        errdefer self.failed = true;
        for (ids) |*id| {
            var number: u64 = undefined;
            if (self.metadata.free != 0) {
                var block: format.Block = undefined;
                number = self.metadata.free;
                try self.readBlock(number, format.free_owner, &block);
                self.metadata.free = format.get(u64, block[32..], 0);
                if (self.metadata.free >= self.metadata.pages or self.metadata.free == number) return error.Corrupt;
            } else {
                if (self.metadata.pages == self.limits.maximum_pages) return error.NoSpace;
                number = self.metadata.pages;
                self.metadata.pages += 1;
            }
            if (!self.locations.contains(number) and self.locations.count() == self.limits.maximum_wal_pages) return error.NoSpace;
            const result = self.locations.getOrPutAssumeCapacity(number);
            if (!result.found_existing) result.value_ptr.* = .{ .current = 0, .owner = @intFromEnum(space) };
            const location = result.value_ptr;
            location.current = 0;
            location.replacement_dirty = true;
            location.owner = @intFromEnum(space);
            for (self.cache) |*entry| if (entry.id == number) {
                entry.touched = 0;
            };
            if (!location.dirty) {
                self.dirty[self.dirty_count] = number;
                self.dirty_count += 1;
                location.dirty = true;
            }
            id.* = @enumFromInt(number);
        }
    }

    fn freePages(self: *Store, space: SpaceId, ids: []const PageId) Error!void {
        try self.check();
        if (ids.len == 0) return;
        errdefer self.failed = true;
        const pages = &self.buffers.free_pages;
        var pointers: [batch_size]*const Page = undefined;
        var numbers: [batch_size]u64 = undefined;
        const owners: [batch_size]u32 = @splat(format.free_owner);
        var start: usize = 0;
        while (start < ids.len) {
            const count = @min(batch_size, ids.len - start);
            for (ids[start..][0..count], pages[0..count], pointers[0..count], numbers[0..count], 0..) |id, *page, *pointer, *number, index| {
                const old = &self.buffers.blocks[0];
                number.* = @intFromEnum(id);
                if (number.* == 0) return error.InvalidArgument;
                try self.readBlock(number.*, @intFromEnum(space), old);
                for (numbers[0..index]) |previous| if (previous == number.*) return error.InvalidArgument;
                @memset(page, 0);
                format.put(u64, page, 0, self.metadata.free);
                self.metadata.free = number.*;
                pointer.* = page;
            }
            try self.append(numbers[0..count], owners[0..count], pointers[0..count], null);
            start += count;
        }
    }

    pub fn commit(self: *Store, tick: u64) Error!CommitId {
        const committing = self.commit_metrics.total.start();
        defer committing.end();
        const committing_cpu = self.commit_metrics.cpu.start();
        defer committing_cpu.end();
        try self.check();
        if (tick < self.saved.tick or self.saved.sequence == std.math.maxInt(u64)) return error.InvalidArgument;
        errdefer self.failed = true;
        const zero: Page = @splat(0);
        var numbers: [batch_size]u64 = undefined;
        var owners: [batch_size]u32 = undefined;
        const pages: [batch_size]*const Page = @splat(&zero);
        var count: usize = 0;
        const initializing = self.commit_metrics.initialize.start();
        for (self.dirty[0..self.dirty_count], 0..) |id, at| {
            const location = self.locations.get(id).?;
            if (location.current == 0) {
                numbers[count] = id;
                owners[count] = location.owner;
                count += 1;
            }
            if (count == batch_size or at + 1 == self.dirty_count) {
                if (count != 0) try self.append(numbers[0..count], owners[0..count], pages[0..count], null);
                count = 0;
            }
        }
        initializing.end();
        const checksumming = self.commit_metrics.checksum.start();
        var digest = format.transaction(self.commit_hash);
        const frame_count: usize = @intCast((self.end - self.committed_end) / @sizeOf(format.Frame));
        assert(frame_count <= self.checksums.len);
        digest.update(std.mem.sliceAsBytes(self.checksums[0..frame_count]));
        const checksum = digest.final();
        checksumming.end();
        const marking = self.commit_metrics.marker.start();
        self.metadata.sequence = self.saved.sequence + 1;
        self.metadata.tick = tick;
        const page = self.metadata.encode();
        try self.append(&.{0}, &.{0}, &.{&page}, checksum);
        marking.end();
        const publishing = self.commit_metrics.publish.start();
        for (self.dirty[0..self.dirty_count]) |id| {
            const location = self.locations.getPtr(id).?;
            location.committed = location.current;
            location.uncommitted = 0;
            location.dirty = false;
        }
        self.dirty_count = 0;
        self.saved = self.metadata;
        self.committed_end = self.end;
        self.commits.add(1);
        publishing.end();
        return @enumFromInt(self.saved.sequence);
    }

    /// A failed transaction may still make an earlier complete commit durable.
    pub fn submitSync(self: *Store, through: CommitId) Error!void {
        const sequence = @intFromEnum(through);
        if (sequence > self.saved.sequence) return error.InvalidArgument;
        self.requested_sequence = @max(self.requested_sequence, sequence);
        try self.progress();
    }

    pub fn progress(self: *Store) Error!void {
        errdefer self.failed = true;
        try self.filesystem.poll();
        if (self.phase == .directory_sync) {
            try self.checkpoint_io.poll();
            if (self.checkpoint_io.sync_complete) {
                self.checkpoint_io.sync_complete = false;
                self.phase = .idle;
            }
        }
        if (self.syncing == .wal and self.filesystem.sync_complete and self.phase != .directory_sync) {
            self.durable_sequence = self.syncing_sequence;
            self.durable_tick = self.syncing_tick;
            self.syncing = .none;
            self.filesystem.sync_complete = false;
        }
        if (self.syncing == .none and self.requested_sequence > self.durable_sequence) {
            self.syncing_sequence = self.saved.sequence;
            self.syncing_tick = self.saved.tick;
            try self.filesystem.startSync(self.wal);
            self.syncing = .wal;
            if (!self.filesystem.pending) try self.progress();
        }
    }

    pub fn waitDurable(self: *Store, through: CommitId) Error!void {
        try self.flushUntilInternal(through, null);
    }
    pub fn waitDurableUntil(self: *Store, through: CommitId, deadline: std.Io.Clock.Timestamp) Error!void {
        try self.flushUntilInternal(through, deadline);
    }

    fn flushUntilInternal(self: *Store, through: CommitId, deadline: ?std.Io.Clock.Timestamp) Error!void {
        const waiting = self.sync_wait.start();
        defer waiting.end();
        const cpu_started = self.sync_wait_cpu.start();
        defer cpu_started.end();
        try self.submitSync(through);
        while (self.durable_sequence < @intFromEnum(through)) {
            if (self.phase == .directory_sync) try self.checkpoint_io.wait(deadline) else try self.filesystem.wait(deadline);
            try self.progress();
        }
    }

    pub fn maintain(self: *Store, page_budget: usize) Error!Maintenance {
        try self.check();
        errdefer self.failed = true;
        try self.progress();
        try self.checkpoint_io.poll();
        switch (self.phase) {
            .idle => {
                if (page_budget == 0 or self.end < self.limits.checkpoint_bytes) return .idle;
                if (self.durable_sequence < self.saved.sequence or self.checkpoint_io.pending) return .waiting;
                self.checkpoint_metadata = self.saved;
                self.checkpoint_count = 0;
                self.checkpoint_at = 0;
                var iterator = self.locations.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.committed == 0 or entry.value_ptr.committed == entry.value_ptr.materialized) continue;
                    self.checkpoint_pages[self.checkpoint_count] = .{ .id = entry.key_ptr.*, .offset = entry.value_ptr.committed };
                    self.checkpoint_count += 1;
                }
                if (self.checkpoint_count == 0) return .idle;
                std.mem.sort(CheckpointPage, self.checkpoint_pages[0..self.checkpoint_count], {}, struct {
                    fn less(_: void, a: CheckpointPage, b: CheckpointPage) bool {
                        return a.id < b.id;
                    }
                }.less);
                self.phase = .copying;
            },
            .copying => {},
            .database_sync => {
                if (!self.checkpoint_io.sync_complete) return .waiting;
                for (self.checkpoint_pages[0..self.checkpoint_count]) |page| self.locations.getPtr(page.id).?.materialized = page.offset;
                self.checkpoint_io.sync_complete = false;
                self.phase = .idle;
                if (self.saved.sequence != self.checkpoint_metadata.sequence) return .progressed;
                var iterator = self.locations.valueIterator();
                while (iterator.next()) |location| location.replacement = 0;
                const file = self.directory.createFile(self.io, self.temporary_name, .{ .read = true, .truncate = true }) catch return error.IoFailure;
                self.replacement = file;
                self.replacement_end = format.header_size;
                self.replacement_at = 0;
                const header = format.walHeader(self.saved.identity, self.saved.sequence);
                try self.checkpoint_io.write(file, &header, 0);
                try self.checkpoint_io.startSync(file);
                self.phase = .replacement_sync;
                return .progressed;
            },
            .replacement_sync => {
                if (!self.checkpoint_io.sync_complete) return .waiting;
                self.checkpoint_io.sync_complete = false;
                if (self.saved.sequence != self.checkpoint_metadata.sequence) {
                    self.replacement.?.close(self.io);
                    self.replacement = null;
                    self.phase = .idle;
                    return .progressed;
                }
                self.phase = .replacement_copy;
                return .progressed;
            },
            .replacement_copy => {
                if (self.saved.sequence != self.checkpoint_metadata.sequence) {
                    self.replacement.?.close(self.io);
                    self.replacement = null;
                    self.phase = .idle;
                    return .progressed;
                }
                var count: usize = 0;
                var ids: [batch_size]u64 = undefined;
                var reads: [batch_size]backend.Io.Read = undefined;
                const blocks = &self.buffers.blocks;
                while (self.replacement_at < self.dirty_count and count < @min(page_budget, batch_size)) {
                    const id = self.dirty[self.replacement_at];
                    self.replacement_at += 1;
                    const location = self.locations.get(id).?;
                    if (location.current == 0 or (location.replacement != 0 and !location.replacement_dirty)) continue;
                    ids[count] = id;
                    reads[count] = .{ .file = self.wal, .offset = location.current + 32, .bytes = &blocks[count] };
                    count += 1;
                }
                if (count != 0) {
                    try self.checkpoint_io.read(reads[0..count]);
                    const frames = &self.buffers.frames;
                    var writes: [batch_size]backend.Io.Write = undefined;
                    for (ids[0..count], blocks[0..count], frames[0..count], writes[0..count]) |id, *block, *frame, *write| {
                        try format.validate(block, id, self.locations.get(id).?.owner);
                        if (format.get(u64, block, 16) != self.saved.sequence + 1) return error.Corrupt;
                        const existing = self.locations.get(id).?.replacement;
                        const offset = if (existing != 0) existing else self.replacement_end;
                        if (existing == 0) {
                            self.replacement_end += @sizeOf(format.Frame);
                        }
                        _ = format.frame(frame, block, offset, null);
                        write.* = .{ .file = self.replacement.?, .offset = offset, .bytes = frame };
                    }
                    try self.checkpoint_io.writeBatch(writes[0..count]);
                    for (writes[0..count], frames[0..count]) |write, *frame| {
                        const slot: usize = @intCast((write.offset - format.header_size) / @sizeOf(format.Frame));
                        assert(slot < self.replacement_checksums.len);
                        self.replacement_checksums[slot] = frame[16..24].*;
                    }
                    for (ids[0..count], writes[0..count]) |id, write| {
                        const location = self.locations.getPtr(id).?;
                        location.replacement = write.offset;
                        location.replacement_dirty = false;
                    }
                    self.wal_bytes.add(count * @sizeOf(format.Frame));
                    self.read_bytes.add(count * format.block_size);
                }
                if (self.replacement_at != self.dirty_count) return .progressed;
                for (self.dirty[0..self.dirty_count], 0..) |id, index| {
                    const location = self.locations.get(id).?;
                    if (location.current != 0 and (location.replacement == 0 or location.replacement_dirty)) {
                        self.replacement_at = index;
                        return .progressed;
                    }
                }
                // The durable database covers the committed prefix. Only the unfinished
                // transaction moves to the new WAL and it needs no durability barrier.
                self.directory.rename(self.temporary_name, self.directory, self.wal_name, self.io) catch return error.IoFailure;
                self.wal.close(self.io);
                self.wal = self.replacement.?;
                self.replacement = null;
                var discarded: usize = 0;
                var iterator = self.locations.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.dirty) continue;
                    self.checkpoint_pages[discarded].id = entry.key_ptr.*;
                    discarded += 1;
                }
                for (self.checkpoint_pages[0..discarded]) |page| _ = self.locations.remove(page.id);
                var values = self.locations.valueIterator();
                while (values.next()) |location| {
                    location.current = if (location.current == 0) 0 else location.replacement;
                    // An allocated zero page can still own a copied frame slot.
                    location.uncommitted = location.replacement;
                    location.committed = 0;
                    location.materialized = 0;
                    location.replacement = 0;
                    location.replacement_dirty = false;
                }
                self.end = self.replacement_end;
                self.committed_end = format.header_size;
                self.commit_hash = 0;
                std.mem.swap([][8]u8, &self.checksums, &self.replacement_checksums);
                const directory_file: std.Io.File = .{ .handle = self.directory.handle, .flags = .{ .nonblocking = false } };
                try self.checkpoint_io.startSync(directory_file);
                self.phase = .directory_sync;
                return .progressed;
            },
            .directory_sync => {
                if (!self.checkpoint_io.sync_complete) return .waiting;
                self.checkpoint_io.sync_complete = false;
                self.phase = .idle;
                return .progressed;
            },
        }
        const count = @min(page_budget, batch_size, self.checkpoint_count - self.checkpoint_at);
        if (count != 0) {
            const blocks = &self.buffers.blocks;
            var reads: [batch_size]backend.Io.Read = undefined;
            const pages = self.checkpoint_pages[self.checkpoint_at..][0..count];
            for (pages, blocks[0..count], reads[0..count]) |page, *block, *read| read.* = .{ .file = self.wal, .offset = page.offset + 32, .bytes = block };
            // Cached pages may contain newer uncommitted writes.
            try self.checkpoint_io.read(reads[0..count]);
            var writes: [batch_size]backend.Io.Write = undefined;
            for (pages, blocks[0..count], writes[0..count]) |page, *block, *write| {
                try format.validate(block, page.id, null);
                write.* = .{ .file = self.database, .bytes = block, .offset = page.id * format.block_size };
            }
            try self.checkpoint_io.writeBatch(writes[0..count]);
            self.checkpoint_at += count;
            self.checkpoint_bytes.add(@as(usize, count) * format.block_size);
        }
        if (self.checkpoint_at == self.checkpoint_count and !self.checkpoint_io.pending) {
            try self.checkpoint_io.startSync(self.database);
            self.phase = .database_sync;
        }
        return if (count == 0) .waiting else .progressed;
    }

    pub fn deinit(self: *Store) void {
        self.filesystem.deinit();
        self.checkpoint_io.deinit();
        if (self.replacement) |file| file.close(self.io);
        self.wal.close(self.io);
        self.database.close(self.io);
        self.directory.close(self.io);
        self.locations.deinit(self.allocator);
        self.allocator.free(self.checksums);
        self.allocator.free(self.replacement_checksums);
        self.allocator.free(self.cache);
        self.allocator.destroy(self.buffers);
        self.allocator.free(self.dirty);
        self.allocator.free(self.checkpoint_pages);
        self.allocator.free(self.name);
        self.allocator.free(self.wal_name);
        self.allocator.free(self.temporary_name);
        self.* = undefined;
    }
};
