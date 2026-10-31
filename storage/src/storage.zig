const std = @import("std");
const builtin = @import("builtin");
const metrics = @import("metrics");
const format = @import("format.zig");
const backend = @import("io.zig");
const wal_index = @import("index.zig");
pub const system = @import("system");
pub const Maintenance = @import("maintenance.zig").Maintenance;

const assert = std.debug.assert;
pub const Error = format.Error;
pub const Page = format.Page;
pub const PageId = format.PageId;
pub const SpaceId = format.SpaceId;
pub const CommitId = format.CommitId;
pub const page_size = format.page_size;
pub const batch_size = backend.maximum_batch;
pub const Read = struct { id: PageId, destination: []u8, offset: u16 = 0 };
pub const Write = struct { id: PageId, source: []const u8 };
pub const MaintenanceBudget = struct { index_entries: usize, pages: usize };
pub const MaintenanceResult = enum { idle, progressed, pending };

/// Immutable bytes remain pinned until release, including across writes to the same page.
/// Copying reads retain independent scratch capacity when every cache entry is pinned.
pub const PageLease = struct {
    resources: *Resources,
    index: usize,
    generation: u64,
    frame: *const format.Frame,

    pub const Version = struct { resources: *Resources, index: usize, generation: u64, checksum: u64 };

    /// Derived page metadata expires when the version changes. It never owns the page bytes.
    pub fn version(self: PageLease) Version {
        _ = self.bytes();
        return .{ .resources = self.resources, .index = self.index, .generation = self.generation, .checksum = std.mem.readInt(u64, self.frame[16..24], .little) };
    }

    pub fn bytes(self: PageLease) *const Page {
        const entry = &self.resources.cache[self.index];
        assert(entry.pins.load(.monotonic) != 0 and entry.generation == self.generation and entry.frame == self.frame);
        assert(entry.loaded);
        return self.frame[64..];
    }

    pub fn release(self: PageLease) void {
        releaseMany(&.{self});
    }

    pub fn releaseMany(leases: []const PageLease) void {
        if (leases.len == 0) return;
        const resources = leases[0].resources;
        const protection = resources.acquire(resources.io);
        defer protection.end();
        for (leases) |lease| {
            assert(lease.resources == resources);
            const entry = &resources.cache[lease.index];
            assert(entry.pins.load(.monotonic) != 0 and entry.generation == lease.generation and entry.frame == lease.frame);
            resources.setPins(lease.index, entry.pins.load(.monotonic) - 1);
        }
    }
};

pub const Space = struct {
    store: *Store,
    id: SpaceId,
    store_is_new: bool,
    root: ?struct { space: SpaceId, page: PageId, offset: u16 } = null,

    pub fn getRoot(self: Space) Error!?PageId {
        if (self.root) |reference| {
            var bytes: [8]u8 = undefined;
            const source: Space = .{ .store = self.store, .id = reference.space, .store_is_new = self.store_is_new };
            try source.readPages(&.{.{ .id = reference.page, .offset = reference.offset, .destination = &bytes }});
            const root = std.mem.readInt(u64, &bytes, .little);
            return if (root == 0) null else @fromBackingInt(@intCast(root));
        }
        const operation = self.store.enter(.read);
        defer operation.end();
        try self.store.check();
        const root = self.store.metadata.spaces[@backingInt(self.id) - 1].root;
        return if (root == 0) null else @fromBackingInt(@intCast(root));
    }
    pub fn setRoot(self: Space, root: ?PageId) Error!void {
        const operation = self.store.enter(.pages);
        defer operation.end();
        const lease = self.store.resources.acquireBuffers(self.store.cache_token);
        defer lease.end();
        try self.store.check();
        if (root) |id| {
            var block: format.Block = undefined;
            try self.store.readBlock(@backingInt(id), @backingInt(self.id), &block);
        }
        const value = if (root) |id| @backingInt(id) else 0;
        if (self.root) |reference| {
            var block: format.Block = undefined;
            try self.store.readBlock(@backingInt(reference.page), @backingInt(reference.space), &block);
            const page: *Page = block[32..];
            format.put(u64, page, reference.offset, value);
            try self.store.writePages(reference.space, &.{.{ .id = reference.page, .source = page }});
        } else self.store.metadata.spaces[@backingInt(self.id) - 1].root = value;
    }
    pub fn allocatePages(self: Space, ids: []PageId) Error!void {
        const operation = self.store.enter(.pages);
        defer operation.end();
        const lease = self.store.resources.acquireBuffers(self.store.cache_token);
        defer lease.end();
        try self.store.allocatePages(self.id, ids);
    }
    pub fn freePages(self: Space, ids: []const PageId) Error!void {
        const operation = self.store.enter(.pages);
        defer operation.end();
        const lease = self.store.resources.acquireBuffers(self.store.cache_token);
        defer lease.end();
        try self.store.freePages(self.id, ids);
    }
    /// Each window captures its page images together. Only reads of physical overwrites wait for that writer.
    pub fn readPages(self: Space, reads: []const Read) Error!void {
        try self.store.readConcurrent(self.id, reads, null);
    }

    pub fn borrowCapacity(self: Space) usize {
        return @min(batch_size, self.store.cache.len);
    }

    /// CachePinned leaves output untouched. Copying reads remain available.
    pub fn borrowPages(self: Space, ids: []const PageId, output: []PageLease) Error!void {
        if (ids.len != output.len or ids.len > batch_size) return error.InvalidArgument;
        var reads: [batch_size]Read = undefined;
        for (ids, reads[0..ids.len]) |id, *read| read.* = .{ .id = id, .destination = &.{} };
        try self.store.readConcurrent(self.id, reads[0..ids.len], output);
    }

    /// Source buffers may be reused on return. The owner requests durability separately.
    pub fn writePages(self: Space, writes: []const Write) Error!void {
        const operation = self.store.enter(.pages);
        defer operation.end();
        const lease = self.store.resources.acquireBuffers(self.store.cache_token);
        defer lease.end();
        try self.store.writePages(self.id, writes);
    }
    pub fn fail(self: Space) void {
        self.store.fail();
    }
};

pub const Transaction = struct {
    store: *Store,
    scope: ?*Scope = null,
    pub fn openSpace(self: Transaction, name: []const u8) Error!Space {
        var space = try self.store.openSpace(name);
        if (self.scope) |scope| {
            assert(scope.space.store == self.store);
            space.root = .{ .space = scope.space.id, .page = scope.page, .offset = @intCast(Scope.roots_offset + (@as(usize, @backingInt(space.id)) - 1) * 8) };
            space.store_is_new = scope.fresh;
        }
        return space;
    }
    pub fn progress(self: Transaction) Error!void {
        try self.store.progress();
    }
    pub fn fail(self: Transaction) void {
        self.store.fail();
    }
};

/// Independent roots share one WAL and become committed together at the owner's barrier.
pub const Scope = struct {
    const magic = "LRSCOPE1";
    const roots_offset = 16;

    space: Space,
    page: PageId,
    tick: u64,
    fresh: bool,

    pub fn create(space: Space) Error!Scope {
        var ids: [1]PageId = undefined;
        try space.allocatePages(&ids);
        var page: Page = @splat(0);
        @memcpy(page[0..magic.len], magic);
        try space.writePages(&.{.{ .id = ids[0], .source = &page }});
        return .{ .space = space, .page = ids[0], .tick = 0, .fresh = true };
    }

    pub fn open(space: Space, id: PageId) Error!Scope {
        var page: Page = undefined;
        try space.readPages(&.{.{ .id = id, .destination = &page }});
        if (!std.mem.eql(u8, page[0..magic.len], magic)) return error.Corrupt;
        for (page[roots_offset + format.maximum_spaces * 8 ..]) |byte| if (byte != 0) return error.Corrupt;
        return .{ .space = space, .page = id, .tick = format.get(u64, &page, 8), .fresh = false };
    }

    pub fn transaction(self: *Scope) Transaction {
        return .{ .store = self.space.store, .scope = self };
    }

    pub fn setTick(self: *Scope, tick: u64) Error!void {
        if (tick < self.tick) return error.InvalidArgument;
        var page: Page = undefined;
        try self.space.readPages(&.{.{ .id = self.page, .destination = &page }});
        if (!std.mem.eql(u8, page[0..magic.len], magic)) return error.Corrupt;
        format.put(u64, &page, 8, tick);
        try self.space.writePages(&.{.{ .id = self.page, .source = &page }});
        self.tick = tick;
        self.fresh = false;
    }
};

pub const Resources = struct {
    const CacheKey = struct { token: u64, id: u64 };
    pub const Configuration = struct { cache_pages: usize = 64, readers: usize = 2, io_mode: backend.Mode = .uring };
    const Reader = struct {
        filesystem: backend.Io,
        controlled: backend.Io,
        blocks: [batch_size]format.Block = undefined,
        used: bool = false,
    };
    const Lease = struct {
        resources: *Resources,

        fn end(self: Lease) void {
            self.resources.mutex.unlock(self.resources.io);
            self.resources.notifyMaintenance();
        }
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    buffers: *Store.Buffers,
    maintenance: *Store.MaintenanceBuffers,
    cache: []Store.CachedPage,
    cache_index: std.AutoHashMapUnmanaged(CacheKey, usize) = .empty,
    oldest: ?usize = null,
    newest: ?usize = null,
    readers: []Reader,
    readers_available: std.Io.Condition = .init,
    io_mode: backend.Mode,
    frames: []align(64) format.Frame,
    buffers_mutex: std.Io.Mutex = .init,
    buffer_owner: u64 = 0,
    maintenance_available: std.Io.Condition = .init,
    maintenance_owner: std.atomic.Value(u64) = .init(0),
    background: std.atomic.Value(?*Maintenance) = .init(null),
    next_token: u64 = 1,
    stores: usize = 0,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) !*Resources {
        if (config.cache_pages == 0 or config.readers == 0 or config.readers > 64) return error.InvalidArgument;
        const self = try allocator.create(Resources);
        errdefer allocator.destroy(self);
        const buffers = try allocator.create(Store.Buffers);
        errdefer allocator.destroy(buffers);
        const maintenance = try allocator.create(Store.MaintenanceBuffers);
        errdefer allocator.destroy(maintenance);
        const cache = try allocator.alloc(Store.CachedPage, config.cache_pages);
        errdefer allocator.free(cache);
        var cache_index: std.AutoHashMapUnmanaged(CacheKey, usize) = .empty;
        errdefer cache_index.deinit(allocator);
        try cache_index.ensureTotalCapacity(allocator, std.math.cast(u32, config.cache_pages) orelse return error.InvalidArgument);
        const frames = try allocator.alignedAlloc(format.Frame, .@"64", config.cache_pages + batch_size);
        errdefer allocator.free(frames);
        for (cache, frames[0..cache.len], 0..) |*entry, *frame, index| entry.* = .{
            .frame = frame,
            .previous = if (index == 0) null else index - 1,
            .next = if (index + 1 == cache.len) null else index + 1,
            .available = true,
        };
        for (&buffers.frames, frames[cache.len..]) |*destination, *frame| destination.* = frame;
        const readers = try allocator.alloc(Reader, config.readers);
        errdefer allocator.free(readers);
        var initialized: usize = 0;
        errdefer for (readers[0..initialized]) |*reader| {
            reader.filesystem.deinit();
            reader.controlled.deinit();
        };
        for (readers) |*reader| {
            reader.filesystem = try backend.Io.init(io, config.io_mode);
            errdefer reader.filesystem.deinit();
            reader.controlled = try backend.Io.init(io, .standard);
            reader.used = false;
            initialized += 1;
        }
        self.* = .{ .allocator = allocator, .io = io, .buffers = buffers, .maintenance = maintenance, .cache = cache, .cache_index = cache_index, .oldest = 0, .newest = cache.len - 1, .frames = frames, .readers = readers, .io_mode = config.io_mode };
        return self;
    }

    pub fn deinit(self: *Resources) void {
        assert(self.background.load(.acquire) == null);
        assert(self.stores == 0 and self.maintenance_owner.load(.acquire) == 0 and self.buffer_owner == 0);
        for (self.cache) |entry| assert(entry.pins.load(.monotonic) == 0);
        const allocator = self.allocator;
        for (self.readers) |*reader| {
            assert(!reader.used);
            reader.filesystem.deinit();
            reader.controlled.deinit();
        }
        allocator.free(self.readers);
        allocator.free(self.frames);
        self.cache_index.deinit(allocator);
        allocator.free(self.cache);
        allocator.destroy(self.maintenance);
        allocator.destroy(self.buffers);
        allocator.destroy(self);
    }

    pub fn memoryBytes(self: *const Resources) usize {
        return self.readers.len * @sizeOf(Reader) + @sizeOf(Resources) + @sizeOf(Store.Buffers) + @sizeOf(Store.MaintenanceBuffers) + self.cache.len * @sizeOf(Store.CachedPage) + self.frames.len * @sizeOf(format.Frame) + self.cache_index.capacity() * (@sizeOf(CacheKey) + @sizeOf(usize) + @sizeOf(u8));
    }

    fn removeAvailable(self: *Resources, index: usize) void {
        const entry = &self.cache[index];
        if (!entry.available) return;
        assert(if (entry.previous) |previous| self.cache[previous].next == index else self.oldest == index);
        assert(if (entry.next) |next| self.cache[next].previous == index else self.newest == index);
        if (entry.previous) |previous| self.cache[previous].next = entry.next else self.oldest = entry.next;
        if (entry.next) |next| self.cache[next].previous = entry.previous else self.newest = entry.previous;
        entry.previous = null;
        entry.next = null;
        entry.available = false;
    }

    fn makeAvailable(self: *Resources, index: usize) void {
        const entry = &self.cache[index];
        if (entry.pins.load(.monotonic) != 0 or entry.reading) return;
        self.removeAvailable(index);
        entry.previous = self.newest;
        if (self.newest) |tail| self.cache[tail].next = index else self.oldest = index;
        self.newest = index;
        entry.available = true;
    }

    fn setPins(self: *Resources, index: usize, pins: usize) void {
        const previous = self.cache[index].pins.load(.monotonic);
        assert((pins > previous and pins - previous == 1) or (previous > pins and previous - pins == 1));
        self.cache[index].pins.store(pins, .monotonic);
        if (pins != 0) self.removeAvailable(index) else self.makeAvailable(index);
    }

    fn setReading(self: *Resources, index: usize, reading: bool) void {
        self.cache[index].reading = reading;
        if (reading) self.removeAvailable(index) else self.makeAvailable(index);
    }

    fn invalidate(self: *Resources, index: usize) void {
        const entry = &self.cache[index];
        const key: CacheKey = .{ .token = entry.token, .id = entry.id };
        if (self.cache_index.get(key)) |mapped| {
            if (mapped == index) {
                const removed = self.cache_index.remove(key);
                assert(removed);
            }
        }
    }

    fn acquireReader(self: *Resources) *Reader {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            for (self.readers) |*reader| if (!reader.used) {
                reader.used = true;
                assert(!reader.filesystem.pending and !reader.controlled.pending);
                reader.filesystem.failed = false;
                reader.controlled.failed = false;
                return reader;
            };
            self.readers_available.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn notifyMaintenance(self: *Resources) void {
        if (self.background.load(.acquire)) |worker| {
            if (worker.blocked.load(.acquire)) worker.notify();
        }
    }

    fn releaseReader(self: *Resources, reader: *Reader) void {
        self.mutex.lockUncancelable(self.io);
        defer {
            self.mutex.unlock(self.io);
            self.notifyMaintenance();
        }
        assert(reader.used);
        reader.used = false;
        self.readers_available.broadcast(self.io);
    }

    fn acquireBuffers(self: *Resources, token: u64) Lease {
        self.mutex.lockUncancelable(self.io);
        assert(token != 0 and self.buffer_owner == token);
        return .{ .resources = self };
    }

    fn acquire(self: *Resources, _: std.Io) Lease {
        self.mutex.lockUncancelable(self.io);
        return .{ .resources = self };
    }
};

/// A single owner submits page batches. Spaces borrow the store's stable address.
pub const Store = struct {
    pub const service_name = "lightning_rod:persistence";
    pub const Options = struct {
        path: []const u8,
        io_mode: backend.Mode = .uring,
        metrics: ?*metrics.Registry = null,
        resources: ?*Resources = null,
        readers: usize = 2,
        maximum_wal_pages: u32 = 65536,
        maximum_pages: u64 = 1 << 32,
        checkpoint_bytes: u64 = 64 * 1024 * 1024,
        /// Deferred recovery leaves complete commits unacknowledged until an explicit durability wait.
        recovery: enum { durable, deferred } = .durable,
    };
    const CachedPage = struct {
        token: u64 = 0,
        id: u64 = 0,
        reading: bool = false,
        loaded: bool = false,
        // Updates hold the resource mutex. Lease validation reads without taking it.
        pins: std.atomic.Value(usize) = .init(0),
        generation: u64 = 0,
        frame: *format.Frame,
        previous: ?usize = null,
        next: ?usize = null,
        available: bool = false,

        fn block(self: *CachedPage) *format.Block {
            return self.frame[32..];
        }
    };
    const Buffers = struct {
        frames: [batch_size]*format.Frame,
        free_pages: [format.FreePages.encoded_size]u8,
    };
    const MaintenanceBuffers = struct {
        frames: [batch_size]format.Frame,
        blocks: [batch_size]format.Block,
        pages: [batch_size]CheckpointPage,
        owners: [batch_size]u32,
        offsets: [batch_size]u64,
        count: usize = 0,
        mutation: u64 = 0,
    };
    const CheckpointPage = struct { id: u64, offset: u64 };
    const RecoveredPage = struct { id: u64, offset: u64, owner: u32 };
    const Phase = enum { idle, collecting, copying, copy_read, copy_write, database_sync, materializing, replacement_reset, replacement_open, replacement_header, replacement_sync, replacement_copy, replacement_read, replacement_write, replacement_verify, replacement_rename, replacement_close, directory_sync, reclaiming, discard_replacement };
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
    resources: *Resources,
    owns_resources: bool,
    cache_token: u64,
    mutex: std.Io.Mutex = .init,
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    writer: std.Thread.Id = 0,
    writer_available: std.Io.Condition = .init,
    page_written: std.Io.Condition = .init,
    writing_pages: []const u64 = &.{},
    io: std.Io,
    filesystem: backend.Io,
    io_mode: backend.Mode,
    inflight_reads: usize = 0,
    retired_reads: usize = 0,
    reads_released: std.Io.Event = .unset,
    maintenance_io: system.FileBatch,
    maintenance_at: usize = 0,
    wal_epoch: u64 = 0,
    verify_mutation: u64 = 0,
    rotation_pending: bool = false,
    retired_wal: ?std.Io.File = null,
    replacement_header: [format.header_size]u8 = undefined,
    directory: std.Io.Dir,
    database: std.Io.File,
    wal: std.Io.File,
    replacement: ?std.Io.File = null,
    replacement_end: u64 = format.header_size,
    replacement_at: usize = 0,
    name: []u8,
    wal_name: [:0]u8,
    temporary_name: [:0]u8,
    limits: struct { maximum_wal_pages: u32, maximum_pages: u64, checkpoint_bytes: u64 },
    metadata: format.Metadata,
    saved: format.Metadata,
    locations: wal_index.Index,
    checksums: [][8]u8,
    replacement_checksums: [][8]u8,
    dirty: []u64,
    dirty_count: usize = 0,
    checkpoint_pages: []CheckpointPage,
    workspace: []align(@alignOf(RecoveredPage)) u8,
    cache: []CachedPage,
    buffers: *Buffers,
    maintenance_buffers: *MaintenanceBuffers,
    mutation: u64 = 0,
    cache_hits: metrics.Counter = .{},
    checkpointed_sequence: u64 = 0,
    checkpoint_count: usize = 0,
    checkpoint_limit: usize = 0,
    checkpoint_at: usize = 0,
    checkpoint_metadata: format.Metadata = undefined,
    phase: Phase = .idle,
    syncing: Sync = .none,
    syncing_sequence: u64 = 0,
    syncing_tick: u64 = 0,
    requested_sequence: u64 = 0,
    durable_sequence: u64 = 0,
    durable_tick: u64 = 0,
    published_tick: std.atomic.Value(u64) = .init(0),
    published_commit: std.atomic.Value(u64) = .init(0),
    published_durable: std.atomic.Value(u64) = .init(0),
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
        var self: Store = undefined;
        try self.initialize(allocator, io, options);
        self.bindIo(io);
        return self;
    }

    fn initialize(self: *Store, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
        if (options.path.len == 0 or options.maximum_wal_pages < batch_size or options.maximum_wal_pages > 1 << 24 or options.maximum_pages < 2 or options.maximum_pages > @as(u64, std.math.maxInt(i64)) / format.block_size or options.checkpoint_bytes < format.header_size) return error.InvalidArgument;
        const directory_timer = try initializationTimer(options.metrics, "directory", "Open the database directory and publish new ancestors");
        const paths_timer = try initializationTimer(options.metrics, "paths", "Allocate database and WAL filenames");
        const database_timer = try initializationTimer(options.metrics, "database", "Open and lock the database file");
        const header_timer = try initializationTimer(options.metrics, "header", "Read and validate the database header or establish a new database");
        const wal_timer = try initializationTimer(options.metrics, "wal", "Open the WAL or establish a new WAL");
        const buffers_timer = try initializationTimer(options.metrics, "buffers", "Allocate page buffers, cache, dirty IDs, and maintenance tasks");
        const dirty_timer = try initializationTimer(options.metrics, "buffers.dirty", "Allocate dirty page IDs");
        const tasks_timer = try initializationTimer(options.metrics, "buffers.maintenance", "Allocate bounded maintenance tasks");
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
        const wal_name = try std.mem.concatWithSentinel(allocator, u8, &.{ name, ".wal" }, 0);
        errdefer allocator.free(wal_name);
        const temporary_name = try std.mem.concatWithSentinel(allocator, u8, &.{ name, ".wal.next" }, 0);
        errdefer allocator.free(temporary_name);
        paths_started.end();
        const database_started = database_timer.start();
        const database = try directory.createFile(io, name, .{ .read = true, .truncate = false });
        errdefer closeDatabase(io, database);
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
            try io.randomSecure(&identity);
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
        const checkpoint_length = @sizeOf(CheckpointPage) * options.maximum_wal_pages;
        const checksum_length = @sizeOf([8]u8) * options.maximum_wal_pages;
        const workspace_length = @max(@sizeOf(RecoveredPage) * options.maximum_wal_pages, checkpoint_length + 2 * checksum_length);
        const workspace = try allocator.alignedAlloc(u8, .of(RecoveredPage), workspace_length);
        errdefer allocator.free(workspace);
        const checkpoint_pages = std.mem.bytesAsSlice(CheckpointPage, workspace[0..checkpoint_length]);
        tasks_started.end();
        const resources = options.resources orelse try Resources.init(allocator, io, .{ .readers = options.readers, .io_mode = options.io_mode });
        errdefer if (options.resources == null) resources.deinit();
        if (options.io_mode == .uring and resources.io_mode != .uring) return error.InvalidArgument;
        const lease = resources.acquire(io);
        defer lease.end();
        if (resources.next_token == std.math.maxInt(u64)) return error.NoSpace;
        const cache_token = resources.next_token;
        resources.next_token += 1;
        buffers_started.end();
        var filesystem = try backend.Io.init(io, options.io_mode);
        errdefer filesystem.deinit();
        var maintenance_io = try system.FileBatch.init(io, options.io_mode);
        errdefer maintenance_io.deinit();
        const index_started = index_timer.start();
        const index_cpu_started = index_cpu.start();
        var locations = try wal_index.Index.init(allocator, options.maximum_wal_pages);
        errdefer locations.deinit(allocator);
        const checksums = std.mem.bytesAsSlice([8]u8, workspace[checkpoint_length..][0..checksum_length]);
        const replacement_checksums = std.mem.bytesAsSlice([8]u8, workspace[checkpoint_length + checksum_length ..][0..checksum_length]);
        index_cpu_started.end();
        index_started.end();
        self.* = .{ .allocator = allocator, .resources = resources, .owns_resources = options.resources == null, .cache_token = cache_token, .io = io, .filesystem = filesystem, .io_mode = options.io_mode, .maintenance_io = maintenance_io, .directory = directory, .database = database, .wal = wal, .name = name, .wal_name = wal_name, .temporary_name = temporary_name, .limits = .{ .maximum_wal_pages = options.maximum_wal_pages, .maximum_pages = options.maximum_pages, .checkpoint_bytes = options.checkpoint_bytes }, .metadata = metadata, .saved = metadata, .locations = locations, .checksums = checksums, .replacement_checksums = replacement_checksums, .dirty = dirty, .checkpoint_pages = checkpoint_pages, .workspace = workspace, .cache = resources.cache, .buffers = resources.buffers, .maintenance_buffers = resources.maintenance, .sync_wait = sync_wait, .sync_wait_cpu = sync_wait_cpu };
        self.commit_metrics = try CommitMetrics.init(options.metrics);
        const recovery_started = recovery_timer.start();
        while (resources.maintenance_owner.load(.acquire) != 0) resources.maintenance_available.waitUncancelable(io, &resources.mutex);
        resources.maintenance_owner.store(cache_token, .release);
        defer self.releaseMaintenanceBuffers();
        try self.recover(valid_database, options.metrics, options.recovery == .durable);
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
        self.published_tick.store(self.saved.tick, .release);
        self.published_commit.store(self.saved.sequence, .release);
        self.published_durable.store(self.durable_tick, .release);
        resources.stores += 1;
    }

    fn initializationTimer(registry: ?*metrics.Registry, comptime name: []const u8, description: []const u8) metrics.Registry.Error!metrics.Timer {
        return if (registry) |owner| owner.timer(.{ .namespace = "storage.initialize", .name = name, .description = description }) else .{};
    }

    fn syncDirectory(io: std.Io, directory: std.Io.Dir) !void {
        const file: std.Io.File = .{ .handle = directory.handle, .flags = .{ .nonblocking = false } };
        try file.sync(io);
    }

    fn closeDatabase(io: std.Io, file: std.Io.File) void {
        if (builtin.os.tag == .linux) {
            // io_uring can retain the open file description after the ring closes.
            const result = std.os.linux.flock(file.handle, std.posix.LOCK.UN);
            assert(std.os.linux.errno(result) == .SUCCESS);
        }
        file.close(io);
    }

    fn recover(self: *Store, valid_database: bool, registry: ?*metrics.Registry, durable: bool) !void {
        const read_timer = try initializationTimer(registry, "recovery.read", "Read sequential WAL frame batches");
        const validate_timer = try initializationTimer(registry, "recovery.validate", "Validate frames and commits including index publication");
        const index_timer = try initializationTimer(registry, "recovery.index", "Publish validated transaction descriptors into the page index");
        const sync_timer = try initializationTimer(registry, "recovery.sync", "Establish the recovered WAL prefix durably");
        // Recovery finishes before maintenance pages and transaction checksums become live.
        const pending = std.mem.bytesAsSlice(RecoveredPage, self.workspace[0 .. @sizeOf(RecoveredPage) * self.limits.maximum_wal_pages]);
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
        const frames = &self.maintenance_buffers.frames;
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
        self.published_tick.store(self.saved.tick, .release);
        self.published_commit.store(self.saved.sequence, .release);
        self.end = end;
        self.committed_end = end;
        self.commit_hash = committed_hash;
        // Establish the recovered prefix before overwriting an incomplete transaction.
        const sync_started = sync_timer.start();
        defer sync_started.end();
        if (size != end) try self.wal.setLength(self.io, end);
        if (durable or size != end) {
            try self.wal.sync(self.io);
            self.durable_sequence = self.saved.sequence;
            self.durable_tick = self.saved.tick;
        }
    }

    pub const MaintenanceStatus = struct { checkpointed: CommitId, pending: bool };

    pub fn maintenanceStatus(self: *Store) MaintenanceStatus {
        const operation = self.enter(.read);
        defer operation.end();
        return .{ .checkpointed = @fromBackingInt(@intCast(self.checkpointed_sequence)), .pending = self.phase != .idle or self.maintenance_io.active };
    }

    pub fn hasWrites(self: *Store) bool {
        const operation = self.enter(.read);
        defer operation.end();
        return self.dirty_count != 0 or !std.meta.eql(self.metadata, self.saved);
    }
    pub fn lastCommit(self: *const Store) CommitId {
        return @fromBackingInt(@intCast(self.published_commit.load(.acquire)));
    }
    pub fn transaction(self: *Store) Transaction {
        return .{ .store = self };
    }
    pub fn lastTick(self: *const Store) u64 {
        return self.published_tick.load(.acquire);
    }
    pub fn durableTick(self: *const Store) u64 {
        return self.published_durable.load(.acquire);
    }
    pub fn memoryBytes(self: *const Store) usize {
        return (if (self.owns_resources) self.resources.memoryBytes() else 0) + self.dirty.len * @sizeOf(u64) + self.workspace.len + self.locations.memoryBytes();
    }

    pub fn bindIo(self: *Store, io: std.Io) void {
        assert(!self.filesystem.pending and !self.maintenance_io.active and self.inflight_reads == 0);
        self.io = io;
        self.filesystem.io = io;
        self.maintenance_io.io = io;
    }

    fn fail(self: *Store) void {
        const operation = self.enter(.metadata);
        defer operation.end();
        self.failed = true;
    }

    const OperationKind = enum { read, metadata, pages };
    const Operation = struct {
        store: *Store,
        kind: OperationKind,
        owns: bool,

        fn end(self: Operation) void {
            if (!self.owns) return;
            const store = self.store;
            const thread = std.Thread.getCurrentId();
            assert(store.owner.load(.monotonic) == thread);
            if (self.kind == .pages) {
                store.resources.mutex.lockUncancelable(store.resources.io);
                assert(store.resources.buffer_owner == store.cache_token);
                store.resources.buffer_owner = 0;
                store.resources.mutex.unlock(store.resources.io);
            }
            if (self.kind != .read) {
                assert(store.writer == thread and store.writing_pages.len == 0);
                store.writer = 0;
                store.writer_available.broadcast(store.io);
            }
            store.owner.store(0, .release);
            store.mutex.unlock(store.io);
            if (self.kind == .pages) store.resources.buffers_mutex.unlock(store.io);
            store.resources.notifyMaintenance();
        }
    };

    fn enter(self: *Store, comptime kind: OperationKind) Operation {
        const thread = std.Thread.getCurrentId();
        if (self.owner.load(.acquire) == thread) {
            assert(kind == .read or self.writer == thread);
            return .{ .store = self, .kind = kind, .owns = false };
        }
        if (kind == .pages) self.resources.buffers_mutex.lockUncancelable(self.io);
        self.mutex.lockUncancelable(self.io);
        if (kind != .read) while (self.writer != 0) self.writer_available.waitUncancelable(self.io, &self.mutex);
        self.owner.store(thread, .release);
        if (kind != .read) self.writer = thread;
        if (kind == .pages) {
            self.resources.mutex.lockUncancelable(self.resources.io);
            assert(self.resources.buffer_owner == 0);
            self.resources.buffer_owner = self.cache_token;
            self.resources.mutex.unlock(self.resources.io);
        }
        return .{ .store = self, .kind = kind, .owns = true };
    }

    fn tryEnter(self: *Store) ?Operation {
        const thread = std.Thread.getCurrentId();
        if (self.owner.load(.acquire) == thread) {
            assert(self.writer == thread);
            return .{ .store = self, .kind = .metadata, .owns = false };
        }
        if (!self.mutex.tryLock()) return null;
        if (self.writer != 0) {
            self.mutex.unlock(self.io);
            return null;
        }
        self.owner.store(thread, .release);
        self.writer = thread;
        return .{ .store = self, .kind = .metadata, .owns = true };
    }

    fn waitRead(self: *Store, requests: []const backend.Io.Read) Error!void {
        assert(self.writer == std.Thread.getCurrentId() and self.resources.buffer_owner == self.cache_token);
        self.resources.mutex.unlock(self.resources.io);
        self.owner.store(0, .release);
        self.mutex.unlock(self.io);
        const result = self.filesystem.read(requests);
        self.mutex.lockUncancelable(self.io);
        self.owner.store(std.Thread.getCurrentId(), .release);
        self.resources.mutex.lockUncancelable(self.resources.io);
        try result;
    }

    fn waitWrite(self: *Store, pages: []const u64, requests: []const backend.Io.Write) Error!void {
        assert(self.writer == std.Thread.getCurrentId() and self.resources.buffer_owner == self.cache_token and self.writing_pages.len == 0);
        self.writing_pages = pages;
        self.resources.mutex.unlock(self.resources.io);
        self.owner.store(0, .release);
        self.mutex.unlock(self.io);
        const result = self.filesystem.writeBatch(requests);
        self.mutex.lockUncancelable(self.io);
        self.owner.store(std.Thread.getCurrentId(), .release);
        self.resources.mutex.lockUncancelable(self.resources.io);
        self.writing_pages = &.{};
        if (pages.len != 0) self.page_written.broadcast(self.io);
        try result;
    }

    fn check(self: *Store) Error!void {
        if (self.failed) return error.FailedTransaction;
    }

    pub fn openSpace(self: *Store, name: []const u8) Error!Space {
        const operation = self.enter(.metadata);
        defer operation.end();
        try self.check();
        if (name.len == 0 or name.len > format.maximum_name) return error.InvalidArgument;
        var empty: ?usize = null;
        for (self.metadata.spaces, 0..) |space, index| {
            if (space.length == name.len and std.mem.eql(u8, space.name[0..space.length], name)) return .{ .store = self, .id = @fromBackingInt(@intCast(index + 1)), .store_is_new = self.saved.sequence == 0 };
            if (empty == null and space.length == 0) empty = index;
        }
        const index = empty orelse return error.NoSpace;
        self.metadata.spaces[index].length = @intCast(name.len);
        @memcpy(self.metadata.spaces[index].name[0..name.len], name);
        return .{ .store = self, .id = @fromBackingInt(@intCast(index + 1)), .store_is_new = self.saved.sequence == 0 };
    }

    fn locationPtr(self: *Store, id: u64) ?*wal_index.Location {
        const location = self.locations.getPtr(id) orelse return null;
        if (location.epoch != self.wal_epoch) {
            assert(location.epoch + 1 == self.wal_epoch);
            const current = if (location.dirty and location.current != 0) location.replacement else 0;
            location.* = .{ .epoch = self.wal_epoch, .current = current, .uncommitted = if (location.dirty) location.replacement else 0, .owner = location.owner, .dirty = location.dirty };
        }
        return location;
    }

    fn getLocation(self: *Store, id: u64) ?wal_index.Location {
        const value = self.locationPtr(id) orelse return null;
        return if (!value.dirty and value.current == 0) null else value.*;
    }

    fn cached(self: *Store, id: u64) ?usize {
        const index = self.resources.cache_index.get(.{ .token = self.cache_token, .id = id }) orelse return null;
        const entry = &self.cache[index];
        assert(entry.loaded and entry.id == id and entry.token == self.cache_token);
        assert(format.get(u64, entry.block(), 8) == id);
        self.resources.makeAvailable(index);
        self.cache_hits.add(1);
        return index;
    }

    fn cacheSlot(self: *Store, id: u64) ?usize {
        const existing = self.resources.cache_index.get(.{ .token = self.cache_token, .id = id });
        const index = if (existing != null and self.cache[existing.?].available) existing.? else self.resources.oldest orelse return null;
        const entry = &self.cache[index];
        assert(entry.available and entry.pins.load(.monotonic) == 0 and !entry.reading);
        self.resources.removeAvailable(index);
        self.resources.invalidate(index);
        entry.generation += 1;
        entry.token = self.cache_token;
        entry.id = id;
        entry.loaded = false;
        assert(entry.id == id and entry.token == self.cache_token);
        return index;
    }

    fn publishCache(self: *Store, slot: usize) void {
        const entry = &self.cache[slot];
        assert(!entry.loaded);
        assert(entry.pins.load(.monotonic) == 0 and entry.token == self.cache_token);
        assert(format.get(u64, entry.block(), 8) == entry.id);
        entry.loaded = true;
        const result = self.resources.cache_index.getOrPutAssumeCapacity(.{ .token = entry.token, .id = entry.id });
        // Concurrent reads may publish the same version into distinct leased frames.
        if (result.found_existing) assert(result.value_ptr.* != slot);
        result.value_ptr.* = slot;
        self.resources.makeAvailable(slot);
    }

    fn loadBlock(self: *Store, id: u64, owner: ?u32, block: *format.Block) Error!void {
        const location = self.getLocation(id);
        if (location != null and location.?.current == 0) {
            @memset(block[32..], 0);
            format.seal(block, id, location.?.owner, self.saved.sequence + 1, block[32..]);
        } else {
            try self.waitRead(&.{.{ .file = if (location != null) self.wal else self.database, .offset = if (location) |at| at.current + 32 else id * format.block_size, .bytes = block }});
            self.read_batches.add(1);
            self.read_pages.add(1);
            try format.validate(block, id, owner);
            self.read_bytes.add(block.len);
        }
        if (owner) |expected| if (format.get(u32, block, 4) != expected) return error.Corrupt;
    }

    fn readBlock(self: *Store, id: u64, owner: ?u32, output: *format.Block) Error!void {
        if (id >= self.metadata.pages) return error.InvalidArgument;
        if (self.cached(id)) |slot| {
            const block = self.cache[slot].block();
            if (owner) |expected| if (format.get(u32, block, 4) != expected) return error.Corrupt;
            output.* = block.*;
            return;
        }
        const slot = self.cacheSlot(id) orelse return self.loadBlock(id, owner, output);
        assert(self.cache[slot].pins.load(.monotonic) == 0 and !self.cache[slot].reading);
        assert(self.cache[slot].id == id);
        const block = self.cache[slot].block();
        self.resources.setReading(slot, true);
        defer self.resources.setReading(slot, false);
        try self.loadBlock(id, owner, block);
        self.publishCache(slot);
        assert(self.cache[slot].loaded);
        output.* = block.*;
    }

    fn readCached(self: *Store, space: SpaceId, reads: []const Read, borrowed: ?[]PageLease) Error!bool {
        assert(reads.len <= batch_size);
        const operation = self.enter(.read);
        defer operation.end();
        const protection = self.resources.acquire(self.io);
        defer protection.end();
        try self.check();
        errdefer self.failed = true;
        var slots: [batch_size]usize = undefined;
        for (reads, slots[0..reads.len]) |read, *slot| {
            const id = @backingInt(read.id);
            if (id == 0 or id >= self.metadata.pages or read.offset > page_size or read.destination.len > page_size - read.offset) return error.InvalidArgument;
            slot.* = self.resources.cache_index.get(.{ .token = self.cache_token, .id = id }) orelse return false;
            assert(self.cache[slot.*].loaded and self.cache[slot.*].id == id and self.cache[slot.*].token == self.cache_token);
            if (format.get(u32, self.cache[slot.*].block(), 4) != @backingInt(space)) return error.Corrupt;
        }
        for (reads, slots[0..reads.len], 0..) |read, slot, index| {
            const entry = &self.cache[slot];
            assert(entry.loaded and entry.id == @backingInt(read.id));
            assert(format.get(u64, entry.block(), 8) == entry.id);
            self.resources.makeAvailable(slot);
            if (borrowed) |output| {
                self.resources.setPins(slot, entry.pins.load(.monotonic) + 1);
                output[index] = .{ .resources = self.resources, .index = slot, .generation = entry.generation, .frame = entry.frame };
            } else @memcpy(read.destination, entry.block()[32 + @as(usize, read.offset) ..][0..read.destination.len]);
        }
        self.cache_hits.add(reads.len);
        return true;
    }

    /// Capture a batch under the metadata locks, then wait using an exclusively leased I/O context.
    fn readConcurrent(self: *Store, space: SpaceId, reads: []const Read, borrowed: ?[]PageLease) Error!void {
        if (borrowed) |output| {
            if (output.len != reads.len or reads.len > batch_size) return error.InvalidArgument;
            if (reads.len > self.cache.len) return error.CachePinned;
        }
        var begin: usize = 0;
        while (begin < reads.len) {
            const count = @min(batch_size, reads.len - begin);
            const window_leases = if (borrowed) |leases| leases[begin..][0..count] else null;
            if (try self.readCached(space, reads[begin..][0..count], window_leases)) {
                begin += count;
                continue;
            }
            const reader = self.resources.acquireReader();
            var owns_reader = true;
            defer if (owns_reader) self.resources.releaseReader(reader);
            const operation = self.enter(.read);
            assert(operation.owns);
            defer operation.end();
            while (true) {
                var pending = false;
                for (reads[begin..][0..count]) |read| pending = pending or std.mem.indexOfScalar(u64, self.writing_pages, @backingInt(read.id)) != null;
                if (!pending) break;
                self.owner.store(0, .release);
                self.page_written.waitUncancelable(self.io, &self.mutex);
                assert(self.owner.load(.monotonic) == 0);
                self.owner.store(std.Thread.getCurrentId(), .release);
            }
            const protection = self.resources.acquire(self.io);
            defer protection.end();
            try self.check();
            var cache_pinned = false;
            errdefer if (!cache_pinned) {
                self.failed = true;
            };
            var requests: [batch_size]backend.Io.Read = undefined;
            var blocks: [batch_size]*format.Block = undefined;
            var verified: [batch_size]bool = @splat(false);
            var mapping: [batch_size]?usize = undefined;
            var slots: [batch_size]struct { index: usize, loading: bool } = undefined;
            var held: usize = 0;
            defer for (slots[0..held]) |slot| {
                const entry = &self.cache[slot.index];
                assert(entry.pins.load(.monotonic) > 0);
                self.resources.setPins(slot.index, entry.pins.load(.monotonic) - 1);
                if (slot.loading) self.resources.setReading(slot.index, false);
            };
            var reading: usize = 0;
            const epoch = self.wal_epoch;
            const mutation = self.mutation;
            for (reads[begin..][0..count], 0..) |read, index| {
                const id = @backingInt(read.id);
                if (id == 0 or id >= self.metadata.pages or read.offset > page_size or read.destination.len > page_size - read.offset) return error.InvalidArgument;
                const duplicate = for (reads[begin..][0..index], 0..) |previous, prior| {
                    if (previous.id == read.id) break prior;
                } else null;
                if (duplicate) |prior| {
                    blocks[index] = blocks[prior];
                    mapping[index] = mapping[prior];
                    verified[index] = verified[prior];
                    continue;
                }
                const cached_slot = self.cached(id);
                const slot = cached_slot orelse self.cacheSlot(id);
                mapping[index] = slot;
                if (slot) |at| {
                    const entry = &self.cache[at];
                    assert(entry.loaded or (!entry.reading and entry.pins.load(.monotonic) == 0));
                    slots[held] = .{ .index = at, .loading = cached_slot == null };
                    held += 1;
                    self.resources.setPins(at, entry.pins.load(.monotonic) + 1);
                    blocks[index] = entry.block();
                    if (cached_slot != null) {
                        verified[index] = true;
                        continue;
                    }
                    self.resources.setReading(at, true);
                } else {
                    if (borrowed != null) {
                        cache_pinned = true;
                        return error.CachePinned;
                    }
                    blocks[index] = &reader.blocks[index];
                }
                const block = blocks[index];
                const location = self.getLocation(id);
                if (location) |value| if (value.current == 0) {
                    @memset(block[32..], 0);
                    format.seal(block, id, value.owner, self.saved.sequence + 1, block[32..]);
                    continue;
                };
                requests[reading] = .{ .file = if (location != null) self.wal else self.database, .offset = if (location) |value| value.current + 32 else id * format.block_size, .bytes = block };
                reading += 1;
            }
            if (reading != 0) {
                self.inflight_reads += 1;
                const filesystem = if (self.io_mode == .uring) &reader.filesystem else &reader.controlled;
                filesystem.io = self.io;
                self.resources.mutex.unlock(self.resources.io);
                self.owner.store(0, .release);
                self.mutex.unlock(self.io);
                const result = filesystem.read(requests[0..reading]);
                self.mutex.lockUncancelable(self.io);
                assert(self.owner.load(.monotonic) == 0);
                self.owner.store(std.Thread.getCurrentId(), .release);
                self.resources.mutex.lockUncancelable(self.resources.io);
                assert(self.inflight_reads > 0);
                self.inflight_reads -= 1;
                if (epoch != self.wal_epoch) {
                    assert(epoch + 1 == self.wal_epoch and self.retired_reads > 0);
                    self.retired_reads -= 1;
                    if (self.retired_reads == 0) self.reads_released.set(self.io);
                }
                try result;
                self.read_batches.add(1);
                self.read_pages.add(reading);
                self.read_bytes.add(reading * format.block_size);
            }
            for (reads[begin..][0..count], blocks[0..count], verified[0..count]) |read, block, valid| {
                if (!valid) try format.validate(block, @backingInt(read.id), @backingInt(space));
                if (format.get(u32, block, 4) != @backingInt(space)) return error.Corrupt;
            }
            for (slots[0..held]) |slot| {
                const entry = &self.cache[slot.index];
                if (!entry.loaded) {
                    if (epoch == self.wal_epoch and mutation == self.mutation) {
                        // Publishing changes cache identity. The temporary pin still owns the same bytes.
                        assert(entry.pins.load(.monotonic) == 1);
                        self.resources.setPins(slot.index, 0);
                        self.publishCache(slot.index);
                        self.resources.setPins(slot.index, 1);
                    } else entry.loaded = true;
                }
                if (slot.loading) self.resources.setReading(slot.index, false);
            }
            for (reads[begin..][0..count], blocks[0..count], mapping[0..count], 0..) |read, block, slot, index| {
                if (borrowed) |output| {
                    const at = slot.?;
                    const entry = &self.cache[at];
                    self.resources.setPins(at, entry.pins.load(.monotonic) + 1);
                    output[index] = .{ .resources = self.resources, .index = at, .generation = entry.generation, .frame = entry.frame };
                } else @memcpy(read.destination, block[32 + @as(usize, read.offset) ..][0..read.destination.len]);
            }
            reader.used = false;
            owns_reader = false;
            self.resources.readers_available.broadcast(self.resources.io);
            begin += count;
        }
    }

    fn readPages(self: *Store, space: SpaceId, reads: []const Read) Error!void {
        try self.check();
        errdefer self.failed = true;
        var requests: [batch_size]backend.Io.Read = undefined;
        var slots: [batch_size]usize = undefined;
        var held: usize = 0;
        defer {
            for (slots[0..held]) |slot| self.resources.setReading(slot, false);
        }
        var verified: [batch_size]bool = undefined;
        var blocks: [batch_size]*format.Block = undefined;
        var start: usize = 0;
        while (start < reads.len) {
            const count = @min(batch_size, reads.len - start);
            var reading: usize = 0;
            for (reads[start..][0..count], blocks[0..count], verified[0..count], 0..) |read, *destination, *valid, index| {
                const id = @backingInt(read.id);
                if (id == 0 or id >= self.metadata.pages or read.offset > page_size or read.destination.len > page_size - read.offset) return error.InvalidArgument;
                if (self.cached(id)) |hit| {
                    assert(self.cache[hit].loaded);
                    slots[held] = hit;
                    self.resources.setReading(hit, true);
                    held += 1;
                    destination.* = self.cache[hit].block();
                    valid.* = true;
                    continue;
                }
                const duplicate = for (reads[start..][0..index], 0..) |previous, prior| {
                    if (previous.id == read.id) break prior;
                } else null;
                if (duplicate) |prior| {
                    destination.* = blocks[prior];
                    valid.* = verified[prior];
                    continue;
                }
                const slot = self.cacheSlot(id);
                if (slot) |cached_slot| {
                    assert(self.cache[cached_slot].pins.load(.monotonic) == 0 and !self.cache[cached_slot].reading);
                    assert(self.cache[cached_slot].id == id);
                    self.resources.setReading(cached_slot, true);
                    slots[held] = cached_slot;
                    held += 1;
                    destination.* = self.cache[cached_slot].block();
                } else destination.* = self.buffers.frames[index][32..];
                valid.* = false;
                const block = destination.*;
                const location = self.getLocation(id);
                if (location) |entry| if (entry.current == 0) {
                    @memset(block[32..], 0);
                    format.seal(block, id, entry.owner, self.saved.sequence + 1, block[32..]);
                    continue;
                };
                requests[reading] = .{ .file = if (location != null) self.wal else self.database, .offset = if (location) |at| at.current + 32 else id * format.block_size, .bytes = block };
                reading += 1;
            }
            assert(reading <= count and count <= batch_size);
            assert(held <= count);
            if (reading != 0) try self.waitRead(requests[0..reading]);
            if (reading != 0) self.read_batches.add(1);
            self.read_pages.add(reading);
            for (reads[start..][0..count], blocks[0..count], verified[0..count]) |read, block, valid| {
                if (!valid) try format.validate(block, @backingInt(read.id), @backingInt(space));
                if (format.get(u32, block, 4) != @backingInt(space)) return error.Corrupt;
                @memcpy(read.destination, block[32 + @as(usize, read.offset) ..][0..read.destination.len]);
            }
            self.read_bytes.add(reading * format.block_size);
            for (slots[0..held]) |slot| {
                if (!self.cache[slot].loaded) self.publishCache(slot);
                assert(self.cache[slot].loaded);
                self.resources.setReading(slot, false);
            }
            held = 0;
            start += count;
        }
    }

    fn append(self: *Store, ids: []const u64, owners: []const u32, pages: []const []const u8, digest: ?u64) Error!void {
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
        var overwrites: [batch_size]u64 = undefined;
        var overwrite_count: usize = 0;
        var count: usize = 0;
        var end = self.end;
        for (ids, owners, pages, 0..) |id, owner, page, index| {
            if (std.mem.indexOfScalar(u64, ids[index + 1 ..], id) != null) continue;
            const existing = if (self.getLocation(id)) |location| location.uncommitted else 0;
            const offset = if (existing != 0 and !committing and self.inflight_reads == 0) existing else end;
            assert(offset >= self.committed_end);
            if (offset < self.end) {
                overwrites[overwrite_count] = id;
                overwrite_count += 1;
            }
            if (offset == end) end += @sizeOf(format.Frame);
            const block: *format.Block = frames[count][32..];
            format.seal(block, id, owner, self.saved.sequence + 1, page);
            _ = format.frame(frames[count], block, offset, digest);
            indices[count] = index;
            offsets[count] = offset;
            count += 1;
        }
        var requests: [batch_size]backend.Io.Write = undefined;
        var request_count: usize = 0;
        for (offsets[0..count], 0..) |offset, index| {
            if (request_count != 0 and requests[request_count - 1].offset + requests[request_count - 1].bytes.len == offset and
                @intFromPtr(requests[request_count - 1].bytes.ptr) + requests[request_count - 1].bytes.len == @intFromPtr(frames[index]))
            {
                const previous = &requests[request_count - 1];
                previous.bytes = previous.bytes.ptr[0 .. previous.bytes.len + @sizeOf(format.Frame)];
            } else {
                requests[request_count] = .{ .file = self.wal, .offset = offset, .bytes = frames[index] };
                request_count += 1;
            }
        }
        try self.waitWrite(overwrites[0..overwrite_count], requests[0..request_count]);
        const completed_hash = if (committing) format.get(u64, frames[0], 16) else 0;
        for (indices[0..count], offsets[0..count], 0..) |index, offset, frame_index| {
            if (offset < self.end) self.commit_metrics.rewritten_frames.add(1);
            if (!committing) {
                const slot: usize = @intCast((offset - self.committed_end) / @sizeOf(format.Frame));
                assert(slot < self.checksums.len);
                self.checksums[slot] = frames[frame_index][16..24].*;
            }
            const id = ids[index];
            const result = self.locations.getOrPutAssumeCapacity(id);
            if (!result.found_existing) result.value_ptr.* = .{ .epoch = self.wal_epoch, .current = 0, .owner = owners[index] };
            const location = self.locationPtr(id).?;
            location.current = offset;
            location.uncommitted = offset;
            location.replacement_dirty = true;
            location.owner = owners[index];
            if (self.resources.cache_index.get(.{ .token = self.cache_token, .id = id })) |slot| {
                if (self.cache[slot].pins.load(.monotonic) != 0) self.resources.invalidate(slot);
            }
            if (self.cacheSlot(id)) |cached_slot| {
                assert(self.cache[cached_slot].pins.load(.monotonic) == 0 and !self.cache[cached_slot].reading);
                assert(self.cache[cached_slot].id == id);
                std.mem.swap(*format.Frame, &self.cache[cached_slot].frame, &frames[frame_index]);
                self.publishCache(cached_slot);
                assert(self.cache[cached_slot].loaded);
            }
            if (!location.dirty) {
                self.dirty[self.dirty_count] = id;
                self.dirty_count += 1;
                location.dirty = true;
            }
        }
        self.end = end;
        self.mutation += 1;
        if (committing) self.commit_hash = completed_hash;
        self.wal_bytes.add(count * @sizeOf(format.Frame));
    }

    fn writePages(self: *Store, space: SpaceId, writes: []const Write) Error!void {
        try self.check();
        errdefer self.failed = true;
        var ids: [batch_size]u64 = undefined;
        const owners: [batch_size]u32 = @splat(@backingInt(space));
        var pages: [batch_size][]const u8 = undefined;
        var checks: [batch_size]Read = undefined;
        var start: usize = 0;
        while (start < writes.len) {
            const count = @min(batch_size, writes.len - start);
            var checking: usize = 0;
            for (writes[start..][0..count], ids[0..count], pages[0..count]) |write, *id, *page| {
                id.* = @backingInt(write.id);
                if (id.* == 0 or id.* >= self.metadata.pages) return error.InvalidArgument;
                if (write.source.len > page_size) return error.InvalidArgument;
                if (self.locations.get(id.*)) |entry| {
                    if (entry.owner != @backingInt(space)) return error.InvalidArgument;
                } else {
                    checks[checking] = .{ .id = write.id, .destination = &.{} };
                    checking += 1;
                }
                page.* = write.source;
            }
            try self.readPages(space, checks[0..checking]);
            try self.append(ids[0..count], owners[0..count], pages[0..count], null);
            start += count;
        }
    }

    fn allocatePages(self: *Store, space: SpaceId, ids: []PageId) Error!void {
        try self.check();
        errdefer self.failed = true;
        var at: usize = 0;
        while (at < ids.len) {
            var count: usize = 0;
            if (self.metadata.free != 0) {
                const head = self.metadata.free;
                var block: format.Block = undefined;
                try self.readBlock(head, format.free_owner, &block);
                const group = try format.FreePages.decode(block[32..], head, self.metadata.free_count, self.metadata.pages);
                count = @min(ids.len - at, self.metadata.free_count);
                assert(count <= self.metadata.free_pages);
                self.metadata.free_pages -= count;
                for (ids[at..][0..count]) |*id| {
                    self.metadata.free_count -= 1;
                    id.* = @fromBackingInt(@intCast(if (self.metadata.free_count == 0) head else group.ids[self.metadata.free_count - 1]));
                }
                if (self.metadata.free_count == 0) {
                    self.metadata.free = group.next;
                    self.metadata.free_count = group.next_count;
                }
            } else {
                count = @min(ids.len - at, self.limits.maximum_pages - self.metadata.pages);
                if (count == 0) return error.NoSpace;
                for (ids[at..][0..count], 0..) |*id, index| id.* = @fromBackingInt(@intCast(self.metadata.pages + index));
                self.metadata.pages += count;
            }
            for (ids[at..][0..count]) |id| {
                const number = @backingInt(id);
                if (!self.locations.contains(number) and self.locations.count() == self.limits.maximum_wal_pages) return error.NoSpace;
                const result = self.locations.getOrPutAssumeCapacity(number);
                if (!result.found_existing) result.value_ptr.* = .{ .epoch = self.wal_epoch, .current = 0, .owner = @backingInt(space) };
                const location = self.locationPtr(number).?;
                location.current = 0;
                location.replacement_dirty = true;
                location.owner = @backingInt(space);
                if (self.resources.cache_index.get(.{ .token = self.cache_token, .id = number })) |slot| self.resources.invalidate(slot);
                if (!location.dirty) {
                    self.dirty[self.dirty_count] = number;
                    self.dirty_count += 1;
                    location.dirty = true;
                }
            }
            at += count;
        }
        self.mutation += 1;
    }

    fn freePages(self: *Store, space: SpaceId, ids: []const PageId) Error!void {
        try self.check();
        if (ids.len == 0) return;
        errdefer self.failed = true;
        var pointers: [batch_size][]const u8 = undefined;
        var numbers: [batch_size]u64 = undefined;
        const owners: [batch_size]u32 = @splat(format.free_owner);
        var reads: [batch_size]Read = undefined;
        var start: usize = 0;
        while (start < ids.len) {
            const count = @min(batch_size, ids.len - start);
            for (ids[start..][0..count], reads[0..count], 0..) |id, *read, index| {
                if (@backingInt(id) == 0) return error.InvalidArgument;
                for (ids[start..][0..index]) |previous| if (previous == id) return error.InvalidArgument;
                read.* = .{ .id = id, .destination = &.{} };
            }
            try self.readPages(space, reads[0..count]);
            var group: format.FreePages = .{ .next = self.metadata.free, .next_count = self.metadata.free_count, .count = @intCast(count) };
            for (ids[start..][0..count], pointers[0..count], numbers[0..count], 0..) |id, *pointer, *number, index| {
                number.* = @backingInt(id);
                if (index < count - 1) group.ids[index] = number.*;
                pointer.* = &.{};
            }
            group.encode(&self.buffers.free_pages);
            pointers[count - 1] = &self.buffers.free_pages;
            try self.append(numbers[0..count], owners[0..count], pointers[0..count], null);
            self.metadata.free = numbers[count - 1];
            self.metadata.free_count = @intCast(count);
            self.metadata.free_pages += count;
            assert(self.metadata.free_pages < self.metadata.pages);
            start += count;
        }
    }

    pub fn commit(self: *Store, tick: u64) Error!CommitId {
        const operation = self.enter(.pages);
        defer operation.end();
        const lease = self.resources.acquireBuffers(self.cache_token);
        defer lease.end();
        const committing = self.commit_metrics.total.start();
        defer committing.end();
        const committing_cpu = self.commit_metrics.cpu.start();
        defer committing_cpu.end();
        try self.check();
        if (tick < self.saved.tick or self.saved.sequence == std.math.maxInt(u64)) return error.InvalidArgument;
        errdefer self.failed = true;
        var numbers: [batch_size]u64 = undefined;
        var owners: [batch_size]u32 = undefined;
        const pages: [batch_size][]const u8 = @splat(&.{});
        var count: usize = 0;
        const initializing = self.commit_metrics.initialize.start();
        for (self.dirty[0..self.dirty_count], 0..) |id, at| {
            const location = self.getLocation(id).?;
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
            const location = self.locationPtr(id).?;
            if (self.phase == .collecting) {
                const position = self.locations.position(id);
                if (position >= self.maintenance_at and position < self.checkpoint_limit and location.checkpoint == null)
                    location.checkpoint = location.committed;
            }
            location.committed = location.current;
            location.uncommitted = 0;
            location.dirty = false;
        }
        self.dirty_count = 0;
        self.saved = self.metadata;
        self.published_tick.store(self.saved.tick, .release);
        self.published_commit.store(self.saved.sequence, .release);
        self.committed_end = self.end;
        self.commits.add(1);
        publishing.end();
        if (self.resources.background.load(.acquire)) |worker| worker.notify();
        return @fromBackingInt(@intCast(self.saved.sequence));
    }

    /// A failed transaction may still make an earlier complete commit durable.
    pub fn submitSync(self: *Store, through: CommitId) Error!void {
        const operation = self.enter(.metadata);
        defer operation.end();
        const sequence = @backingInt(through);
        if (sequence > self.saved.sequence) return error.InvalidArgument;
        self.requested_sequence = @max(self.requested_sequence, sequence);
        try self.progress();
    }

    /// Contended writers and incomplete I/O are left for a later poll.
    pub fn progress(self: *Store) Error!void {
        const operation = self.tryEnter() orelse return;
        defer operation.end();
        errdefer self.failed = true;
        try self.filesystem.poll();
        if (self.syncing == .wal and self.filesystem.sync_complete and !self.rotation_pending) {
            self.durable_sequence = self.syncing_sequence;
            self.durable_tick = self.syncing_tick;
            self.published_durable.store(self.durable_tick, .release);
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
        const operation = self.enter(.metadata);
        defer operation.end();
        const waiting = self.sync_wait.start();
        defer waiting.end();
        const cpu_started = self.sync_wait_cpu.start();
        defer cpu_started.end();
        const thread = std.Thread.getCurrentId();
        if (self.maintenance_io.active) {
            self.owner.store(0, .release);
            self.mutex.unlock(self.io);
            const result = self.maintenance_io.wait(deadline);
            self.mutex.lockUncancelable(self.io);
            self.owner.store(thread, .release);
            try result;
        }
        try self.submitSync(through);
        while (self.rotation_pending or self.durable_sequence < @backingInt(through)) {
            while (self.retired_reads != 0) {
                self.reads_released.reset();
                self.owner.store(0, .release);
                self.mutex.unlock(self.io);
                const result = self.reads_released.waitTimeout(self.io, if (deadline) |until| .{ .deadline = until } else .none);
                self.mutex.lockUncancelable(self.io);
                self.owner.store(thread, .release);
                result catch |err| return switch (err) {
                    error.Timeout => error.Timeout,
                    error.Canceled => error.IoFailure,
                };
            }
            if (self.rotation_pending) {
                _ = try self.pollMaintenance(.{ .index_entries = batch_size, .pages = batch_size });
                if (self.maintenance_io.active) {
                    self.owner.store(0, .release);
                    self.mutex.unlock(self.io);
                    const result = self.maintenance_io.wait(deadline);
                    self.mutex.lockUncancelable(self.io);
                    self.owner.store(thread, .release);
                    try result;
                }
            } else {
                self.owner.store(0, .release);
                self.mutex.unlock(self.io);
                const result = self.filesystem.wait(deadline);
                self.mutex.lockUncancelable(self.io);
                self.owner.store(thread, .release);
                try result;
            }
            try self.progress();
        }
    }

    fn reserveMaintenanceBuffers(self: *Store) bool {
        const owner = &self.resources.maintenance_owner;
        if (owner.load(.acquire) == self.cache_token) return true;
        return owner.cmpxchgStrong(0, self.cache_token, .acq_rel, .acquire) == null;
    }

    fn releaseMaintenanceBuffers(self: *Store) void {
        const owner = &self.resources.maintenance_owner;
        if (owner.load(.acquire) == self.cache_token) {
            owner.store(0, .release);
            self.resources.maintenance_available.broadcast(self.resources.io);
        }
    }

    /// Never wait for an I/O completion or a contended lock. Every index visit consumes budget.
    pub fn pollMaintenance(self: *Store, budget: MaintenanceBudget) Error!MaintenanceResult {
        const guard = self.tryEnter() orelse return .pending;
        defer guard.end();
        try self.check();
        errdefer self.failed = true;
        if (self.maintenance_io.active and !try self.maintenance_io.poll()) return .pending;
        try self.progress();
        if (!self.resources.mutex.tryLock()) return .pending;
        defer self.resources.mutex.unlock(self.resources.io);
        const buffers = self.maintenance_buffers;
        switch (self.phase) {
            .idle => {
                if (budget.pages == 0 or budget.index_entries == 0 or self.end == format.header_size or self.saved.sequence == self.checkpointed_sequence or self.end < self.limits.checkpoint_bytes) return .idle;
                if (self.durable_sequence < self.saved.sequence) return .pending;
                self.checkpoint_metadata = self.saved;
                self.checkpoint_count = 0;
                self.checkpoint_limit = self.locations.count();
                self.checkpoint_at = 0;
                self.maintenance_at = 0;
                self.phase = .collecting;
            },
            .collecting => {
                assert(self.maintenance_at <= self.checkpoint_limit and self.checkpoint_limit <= self.locations.count());
                var iterator = self.locations.iterator();
                iterator.at = self.maintenance_at;
                const end = @min(self.checkpoint_limit, iterator.at +| budget.index_entries);
                while (iterator.at < end) {
                    const entry = iterator.next().?;
                    const committed = entry.value_ptr.checkpoint orelse entry.value_ptr.committed;
                    entry.value_ptr.checkpoint = null;
                    if (committed == 0 or committed == entry.value_ptr.materialized) continue;
                    self.checkpoint_pages[self.checkpoint_count] = .{ .id = entry.key_ptr.*, .offset = committed };
                    self.checkpoint_count += 1;
                }
                self.maintenance_at = iterator.at;
                if (iterator.at == self.checkpoint_limit) {
                    self.phase = if (self.checkpoint_count == 0) .idle else .copying;
                    if (self.phase == .idle) return .idle;
                }
            },
            .copying => {
                const count = @min(budget.pages, batch_size, self.checkpoint_count - self.checkpoint_at);
                if (count == 0) return .pending;
                if (!self.reserveMaintenanceBuffers()) return .pending;
                buffers.count = count;
                @memcpy(buffers.pages[0..count], self.checkpoint_pages[self.checkpoint_at..][0..count]);
                var operations: [batch_size]system.FileBatch.Operation = undefined;
                for (buffers.pages[0..count], buffers.blocks[0..count], operations[0..count]) |page, *block, *operation|
                    operation.* = .{ .read = .{ .file = self.wal, .offset = page.offset + 32, .bytes = block } };
                try self.maintenance_io.submit(operations[0..count]);
                self.phase = .copy_read;
            },
            .copy_read => {
                if (self.inflight_reads != 0) return .pending;
                assert(self.resources.maintenance_owner.load(.acquire) == self.cache_token);
                var operations: [batch_size]system.FileBatch.Operation = undefined;
                for (buffers.pages[0..buffers.count], buffers.blocks[0..buffers.count], operations[0..buffers.count]) |page, *block, *operation| {
                    try format.validate(block, page.id, null);
                    operation.* = .{ .write = .{ .file = self.database, .offset = page.id * format.block_size, .bytes = block } };
                }
                try self.maintenance_io.submit(operations[0..buffers.count]);
                self.phase = .copy_write;
            },
            .copy_write => {
                self.checkpoint_at += buffers.count;
                self.checkpoint_bytes.add(buffers.count * format.block_size);
                self.releaseMaintenanceBuffers();
                self.phase = .copying;
                if (self.checkpoint_at == self.checkpoint_count) {
                    try self.maintenance_io.submit(&.{.{ .sync = self.database }});
                    self.phase = .database_sync;
                }
            },
            .database_sync => {
                self.maintenance_at = 0;
                self.phase = .materializing;
            },
            .materializing => {
                const end = @min(self.checkpoint_count, self.maintenance_at +| budget.index_entries);
                for (self.checkpoint_pages[self.maintenance_at..end]) |page| self.locationPtr(page.id).?.materialized = page.offset;
                self.maintenance_at = end;
                if (end != self.checkpoint_count) return .progressed;
                self.checkpointed_sequence = self.checkpoint_metadata.sequence;
                self.maintenance_at = 0;
                self.phase = if (self.saved.sequence == self.checkpoint_metadata.sequence) .replacement_reset else .idle;
            },
            .replacement_reset => {
                if (self.saved.sequence != self.checkpoint_metadata.sequence) {
                    self.phase = .idle;
                    return .progressed;
                }
                var iterator = self.locations.iterator();
                iterator.at = self.maintenance_at;
                const end = @min(self.locations.count(), iterator.at +| budget.index_entries);
                while (iterator.at < end) iterator.next().?.value_ptr.replacement = 0;
                self.maintenance_at = iterator.at;
                if (end != self.locations.count()) return .progressed;
                try self.maintenance_io.submit(&.{.{ .open = .{ .directory = self.directory, .path = self.temporary_name } }});
                self.phase = .replacement_open;
            },
            .replacement_open => {
                self.replacement = self.maintenance_io.opened.?;
                self.replacement_end = format.header_size;
                self.replacement_at = 0;
                self.replacement_header = format.walHeader(self.saved.identity, self.checkpoint_metadata.sequence);
                try self.maintenance_io.submit(&.{.{ .write = .{ .file = self.replacement.?, .offset = 0, .bytes = &self.replacement_header } }});
                self.phase = .replacement_header;
            },
            .replacement_header => {
                try self.maintenance_io.submit(&.{.{ .sync = self.replacement.? }});
                self.phase = .replacement_sync;
            },
            .replacement_sync => {
                self.phase = .replacement_copy;
            },
            .replacement_copy => {
                if (self.saved.sequence != self.checkpoint_metadata.sequence) {
                    try self.maintenance_io.submit(&.{.{ .close = self.replacement.? }});
                    self.replacement = null;
                    self.phase = .discard_replacement;
                    return .progressed;
                }
                if (!self.reserveMaintenanceBuffers()) return .pending;
                buffers.count = 0;
                buffers.mutation = self.mutation;
                var operations: [batch_size]system.FileBatch.Operation = undefined;
                const end = @min(self.dirty_count, self.replacement_at +| budget.index_entries);
                while (self.replacement_at < end and buffers.count < @min(budget.pages, batch_size)) {
                    const id = self.dirty[self.replacement_at];
                    self.replacement_at += 1;
                    const location = self.getLocation(id).?;
                    if (location.current == 0 or (location.replacement != 0 and !location.replacement_dirty)) continue;
                    const at = buffers.count;
                    buffers.pages[at] = .{ .id = id, .offset = location.current };
                    buffers.owners[at] = location.owner;
                    operations[at] = .{ .read = .{ .file = self.wal, .offset = location.current + 32, .bytes = &buffers.blocks[at] } };
                    buffers.count += 1;
                }
                if (buffers.count != 0) {
                    try self.maintenance_io.submit(operations[0..buffers.count]);
                    self.phase = .replacement_read;
                } else {
                    self.releaseMaintenanceBuffers();
                    if (self.replacement_at == self.dirty_count) {
                        self.maintenance_at = 0;
                        self.verify_mutation = self.mutation;
                        self.phase = .replacement_verify;
                    }
                }
            },
            .replacement_read => {
                if (self.mutation != buffers.mutation or self.saved.sequence != self.checkpoint_metadata.sequence) {
                    self.releaseMaintenanceBuffers();
                    self.replacement_at = 0;
                    self.phase = .replacement_copy;
                    return .progressed;
                }
                var operations: [batch_size]system.FileBatch.Operation = undefined;
                for (buffers.pages[0..buffers.count], buffers.owners[0..buffers.count], buffers.blocks[0..buffers.count], buffers.frames[0..buffers.count], buffers.offsets[0..buffers.count], operations[0..buffers.count]) |page, owner, *block, *frame, *offset, *operation| {
                    try format.validate(block, page.id, owner);
                    if (format.get(u64, block, 16) != self.saved.sequence + 1) return error.Corrupt;
                    const existing = self.getLocation(page.id).?.replacement;
                    offset.* = if (existing != 0) existing else self.replacement_end;
                    if (existing == 0) self.replacement_end += @sizeOf(format.Frame);
                    _ = format.frame(frame, block, offset.*, null);
                    operation.* = .{ .write = .{ .file = self.replacement.?, .offset = offset.*, .bytes = frame } };
                }
                try self.maintenance_io.submit(operations[0..buffers.count]);
                self.phase = .replacement_write;
            },
            .replacement_write => {
                for (buffers.pages[0..buffers.count], buffers.offsets[0..buffers.count], buffers.frames[0..buffers.count]) |page, offset, *frame| {
                    const slot: usize = @intCast((offset - format.header_size) / @sizeOf(format.Frame));
                    assert(slot < self.replacement_checksums.len);
                    self.replacement_checksums[slot] = frame[16..24].*;
                    const location = self.locationPtr(page.id).?;
                    location.replacement = offset;
                    location.replacement_dirty = self.mutation != buffers.mutation;
                }
                self.wal_bytes.add(buffers.count * @sizeOf(format.Frame));
                self.read_bytes.add(buffers.count * format.block_size);
                self.releaseMaintenanceBuffers();
                self.phase = .replacement_copy;
            },
            .replacement_verify => {
                if (self.saved.sequence != self.checkpoint_metadata.sequence) {
                    self.phase = .replacement_copy;
                    return .progressed;
                }
                if (self.verify_mutation != self.mutation) {
                    self.maintenance_at = 0;
                    self.verify_mutation = self.mutation;
                }
                const end = @min(self.dirty_count, self.maintenance_at +| budget.index_entries);
                for (self.dirty[self.maintenance_at..end], self.maintenance_at..) |id, index| {
                    const location = self.getLocation(id).?;
                    if (location.current != 0 and (location.replacement == 0 or location.replacement_dirty)) {
                        self.replacement_at = index;
                        self.phase = .replacement_copy;
                        return .progressed;
                    }
                }
                self.maintenance_at = end;
                if (end != self.dirty_count) return .progressed;
                // New writes switch to the replacement immediately. Durability remains gated on rename and directory sync.
                try self.maintenance_io.submit(&.{.{ .rename = .{ .directory = self.directory, .from = self.temporary_name, .to = self.wal_name } }});
                assert(self.retired_reads == 0);
                self.retired_reads = self.inflight_reads;
                self.retired_wal = self.wal;
                self.wal = self.replacement.?;
                self.replacement = null;
                self.wal_epoch += 1;
                self.end = self.replacement_end;
                self.committed_end = format.header_size;
                self.commit_hash = 0;
                std.mem.swap([][8]u8, &self.checksums, &self.replacement_checksums);
                self.rotation_pending = true;
                self.phase = .replacement_rename;
            },
            .replacement_rename => {
                if (self.retired_reads != 0) return .pending;
                try self.maintenance_io.submit(&.{.{ .close = self.retired_wal.? }});
                self.retired_wal = null;
                self.phase = .replacement_close;
            },
            .replacement_close => {
                const directory: std.Io.File = .{ .handle = self.directory.handle, .flags = .{ .nonblocking = false } };
                try self.maintenance_io.submit(&.{.{ .sync = directory }});
                self.phase = .directory_sync;
            },
            .directory_sync => {
                self.rotation_pending = false;
                self.maintenance_at = 0;
                self.phase = .reclaiming;
            },
            .reclaiming => {
                var visited: usize = 0;
                while (self.maintenance_at < self.locations.count() and visited < budget.index_entries) : (visited += 1) {
                    var iterator = self.locations.iterator();
                    iterator.at = self.maintenance_at;
                    const id = iterator.next().?.key_ptr.*;
                    const location = self.locationPtr(id).?;
                    if (location.current == 0 and !location.dirty) {
                        const removed = self.locations.remove(id);
                        assert(removed);
                    } else self.maintenance_at += 1;
                }
                if (self.maintenance_at == self.locations.count()) self.phase = .idle;
            },
            .discard_replacement => {
                self.phase = .idle;
            },
        }
        return .progressed;
    }

    pub fn deinit(self: *Store) void {
        if (self.resources.background.load(.acquire)) |worker| assert(worker.store != self);
        assert(self.inflight_reads == 0 and self.retired_reads == 0 and self.writer == 0 and self.owner.load(.acquire) == 0);
        {
            const cache = self.resources.acquire(self.io);
            defer cache.end();
            for (self.cache) |entry| if (entry.token == self.cache_token) assert(entry.pins.load(.monotonic) == 0);
        }
        self.filesystem.deinit();
        self.maintenance_io.deinit();
        if (self.phase == .replacement_open) if (self.maintenance_io.opened) |file| file.close(self.io);
        if (self.retired_wal) |file| file.close(self.io);
        if (self.replacement) |file| file.close(self.io);
        self.wal.close(self.io);
        closeDatabase(self.io, self.database);
        self.directory.close(self.io);
        self.locations.deinit(self.allocator);
        self.allocator.free(self.workspace);
        self.allocator.free(self.dirty);
        self.allocator.free(self.name);
        self.allocator.free(self.wal_name);
        self.allocator.free(self.temporary_name);
        const resources = self.resources;
        const owns_resources = self.owns_resources;
        {
            const lease = resources.acquire(self.io);
            defer lease.end();
            self.releaseMaintenanceBuffers();
            assert(resources.stores > 0);
            resources.stores -= 1;
        }
        self.* = undefined;
        if (owns_resources) resources.deinit();
    }
};
