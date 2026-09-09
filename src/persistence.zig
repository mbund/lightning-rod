const std = @import("std");
const preallocated = @import("preallocated");
const disk_index = @import("persistence_index.zig");
pub const Scope = @import("persistence_scope.zig").Scope;

pub const Status = enum(u8) { ready, pending, missing, too_small, backpressured, failed };
pub const DrainError = error{ Unavailable, Canceled };
pub const Operation = enum(u8) { put, delete };
pub const Request = u32;
pub const no_request = std.math.maxInt(Request);

pub const Configuration = struct {
    /// Capacity for the in-memory index backend. Disk-index backends do not
    /// retain keys in RAM and therefore use the default single-key value.
    maximum_keys: usize = 1,
    maximum_checkpoint_records: usize,
    maximum_requests: usize,
    maximum_namespace_bytes: usize,
    maximum_key_bytes: usize,
    maximum_value_bytes: usize,
    maximum_checkpoint_bytes: usize,

    pub fn validate(self: Configuration) !void {
        if (self.maximum_keys == 0 or self.maximum_checkpoint_records == 0 or self.maximum_requests == 0)
            return error.InvalidCapacity;
        if (self.maximum_requests > std.math.maxInt(u16) or self.maximum_checkpoint_records > std.math.maxInt(u32))
            return error.InvalidCapacity;
        if (self.maximum_namespace_bytes == 0 or self.maximum_key_bytes == 0 or self.maximum_value_bytes == 0)
            return error.InvalidCapacity;
        if (self.maximum_namespace_bytes > std.math.maxInt(u16) or self.maximum_key_bytes > std.math.maxInt(u16) or
            self.maximum_value_bytes > std.math.maxInt(u32)) return error.InvalidCapacity;
        _ = try slotCount(self);
        const one_record = std.math.add(usize, header_bytes + commit_bytes + record_bytes, self.maximum_namespace_bytes) catch return error.InvalidCapacity;
        const one_key = std.math.add(usize, one_record, self.maximum_key_bytes) catch return error.InvalidCapacity;
        const one_value = std.math.add(usize, one_key, self.maximum_value_bytes) catch return error.InvalidCapacity;
        if (self.maximum_checkpoint_bytes < one_value) return error.InvalidCapacity;
    }
};

pub const Reservation = struct {
    index_bytes: usize,
    test_storage_bytes: usize,

    pub fn totalBytes(self: Reservation) usize {
        return self.index_bytes + self.test_storage_bytes;
    }
};

pub const ReadResult = struct { status: Status, bytes: usize = 0 };
/// On fatal storage failure, submitted destinations stay borrowed until backend
/// IO is drained or cancelled; a failed poll is not a cancellation acknowledgement.
pub const Read = struct { namespace: []const u8 = &.{}, key: []const u8, destination: []u8 };
pub const ReadBatch = struct { namespace: ?[]const u8 = null, records: []const Read };
pub const WriteReservation = enum(u64) { _ };
pub const ReserveError = error{ Backpressured, InvalidKey, ValueTooLarge, IndexCapacityExceeded, StorageFailed };
pub const ScanRecord = struct { key: []const u8, value_bytes: usize };
pub const ScanResult = struct { count: usize, more: bool };
pub const ScanError = error{ InvalidNamespace, EmptyBatch, StorageFailed };
pub const Location = struct {
    pack: u32 = 0,
    offset: u64,
    length: u32,
};
/// The newest value visible to a synchronous reader.  Staged bytes are owned
/// by the Store and remain borrowed until its next mutation.
pub const CurrentValue = union(enum) {
    failed,
    missing,
    staged: []const u8,
    persisted: Location,
};
const LocationBase = struct { pack: u32 = 0, offset: usize = 0 };
pub const LiveRecord = struct {
    namespace: []const u8,
    key: []const u8,
    location: Location,
};
/// Fixed-size continuation over an immutable disk-index root.
pub const LiveCursor = struct {
    slot: usize = 0,
    disk_root: disk_index.Root = .{},
    disk_started: bool = false,
    last: [disk_index.max_key_bytes]u8 = undefined,
    namespace_len: usize = 0,
    key_len: usize = 0,
};
pub const LiveError = error{ Poisoned, Corrupt, StorageFailed };
pub const ReadTask = struct { request: Request, location: Location, destination: []u8 };
pub const CheckpointRecord = struct {
    namespace: []const u8 = &.{},
    key: []const u8,
    operation: union(Operation) { put: []const u8, delete: void },
};

pub const WriteBatch = struct {
    namespace: ?[]const u8 = null,
    records: []const CheckpointRecord,
};

pub const LoadResult = union(enum) { missing, value: usize };
pub const LoadError = error{ InvalidKey, DestinationTooSmall, ReadFailed, Corrupt };

pub const Loader = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, []const u8, []const u8, []u8) LoadError!LoadResult,

    pub fn read(self: Loader, namespace: []const u8, key: []const u8, destination: []u8) LoadError!LoadResult {
        if (namespace.len == 0 or key.len == 0) return error.InvalidKey;
        return self.read_fn(self.context, namespace, key, destination);
    }
};

pub const Interface = struct {
    context: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        length: *const fn (*const anyopaque, []const u8, []const u8) ?usize,
        read_batch: *const fn (*anyopaque, ReadBatch, []Request) Status,
        poll_read: *const fn (*anyopaque, Request) ReadResult,
        scan: *const fn (*const anyopaque, []const u8, []const u8, []ScanRecord) ScanError!ScanResult,
        reserve: *const fn (*anyopaque, WriteBatch) ReserveError!WriteReservation,
        publish: *const fn (*anyopaque, WriteReservation) void,
        cancel: *const fn (*anyopaque, WriteReservation) void,
        flush: *const fn (*anyopaque) Status,
        drain: *const fn (*anyopaque, std.Io) DrainError!void,
        request_checkpoint: *const fn (*anyopaque) Status,
        checkpoint_progress: *const fn (*anyopaque) Status,
        poisoned: *const fn (*anyopaque) bool,
    };
    pub inline fn length(self: Interface, ns: []const u8, key: []const u8) ?usize {
        return self.vtable.length(self.context, ns, key);
    }
    pub inline fn read(self: Interface, ns: []const u8, key: []const u8, destination: []u8) Request {
        var requests: [1]Request = undefined;
        if (self.readBatch(&.{.{ .namespace = ns, .key = key, .destination = destination }}, &requests) != .ready) return no_request;
        return requests[0];
    }
    pub inline fn readBatch(self: Interface, reads: []const Read, requests: []Request) Status {
        std.debug.assert(reads.len == requests.len);
        return self.vtable.read_batch(self.context, .{ .records = reads }, requests);
    }
    pub inline fn pollRead(self: Interface, request: Request) ReadResult {
        return self.vtable.poll_read(self.context, request);
    }
    /// Keys are borrowed until the next scan or storage mutation. Copy the final key to
    /// retain an exclusive cursor across mutations; a scan is not a snapshot.
    pub inline fn scan(self: Interface, namespace_bytes: []const u8, after: []const u8, output: []ScanRecord) ScanError!ScanResult {
        return self.vtable.scan(self.context, namespace_bytes, after, output);
    }
    pub inline fn stage(self: Interface, record: CheckpointRecord) Status {
        return self.stageBatch(&.{record});
    }
    pub inline fn stageBatch(self: Interface, records: []const CheckpointRecord) Status {
        const reservation = self.reserve(records) catch |err| return switch (err) {
            error.Backpressured, error.InvalidKey => .backpressured,
            error.ValueTooLarge, error.IndexCapacityExceeded, error.StorageFailed => .failed,
        };
        self.publish(reservation);
        return .ready;
    }
    pub inline fn reserve(self: Interface, records: []const CheckpointRecord) ReserveError!WriteReservation {
        return self.vtable.reserve(self.context, .{ .records = records });
    }
    pub inline fn publish(self: Interface, reservation: WriteReservation) void {
        self.vtable.publish(self.context, reservation);
    }
    pub inline fn cancel(self: Interface, reservation: WriteReservation) void {
        self.vtable.cancel(self.context, reservation);
    }
    pub inline fn flush(self: Interface) Status {
        return self.vtable.flush(self.context);
    }
    /// Flush accepted writes and wait without requesting a checkpoint or re-entering gameplay.
    pub inline fn drain(self: Interface, io: std.Io) DrainError!void {
        return self.vtable.drain(self.context, io);
    }
    pub inline fn requestCheckpoint(self: Interface) Status {
        return self.vtable.request_checkpoint(self.context);
    }
    pub inline fn checkpointProgress(self: Interface) Status {
        return self.vtable.checkpoint_progress(self.context);
    }
    pub inline fn poisoned(self: Interface) bool {
        return self.vtable.poisoned(self.context);
    }
    pub inline fn namespace(self: Interface, value: []const u8) Namespace {
        return .{ .persistence = self, .value = value };
    }
};

pub const Namespace = struct {
    persistence: Interface,
    value: []const u8,
    pub inline fn scan(self: Namespace, after: []const u8, output: []ScanRecord) ScanError!ScanResult {
        return self.persistence.scan(self.value, after, output);
    }
    pub inline fn length(self: Namespace, key: []const u8) ?usize {
        return self.persistence.length(self.value, key);
    }
    pub inline fn read(self: Namespace, key: []const u8, destination: []u8) Request {
        return self.persistence.read(self.value, key, destination);
    }
    pub inline fn readBatch(self: Namespace, reads: []const Read, requests: []Request) Status {
        std.debug.assert(reads.len == requests.len);
        return self.persistence.vtable.read_batch(self.persistence.context, .{ .namespace = self.value, .records = reads }, requests);
    }
    pub inline fn pollRead(self: Namespace, request: Request) ReadResult {
        return self.persistence.pollRead(request);
    }
    pub inline fn stagePut(self: Namespace, key: []const u8, value: []const u8) Status {
        return self.persistence.stage(.{ .namespace = self.value, .key = key, .operation = .{ .put = value } });
    }
    pub inline fn stageDelete(self: Namespace, key: []const u8) Status {
        return self.persistence.stage(.{ .namespace = self.value, .key = key, .operation = .delete });
    }
    pub inline fn reserve(self: Namespace, records: []const CheckpointRecord) ReserveError!WriteReservation {
        return self.persistence.vtable.reserve(self.persistence.context, .{ .namespace = self.value, .records = records });
    }
    pub inline fn publish(self: Namespace, reservation: WriteReservation) void {
        self.persistence.publish(reservation);
    }
    pub inline fn cancel(self: Namespace, reservation: WriteReservation) void {
        self.persistence.cancel(reservation);
    }
};

pub const Access = struct {
    pub const Configuration = struct {
        interface: Interface,
        loader: ?Loader = null,
        maximum_checkpoint_records: usize,
    };

    interface: Interface,
    loader: ?Loader,
    maximum_checkpoint_records: usize,

    pub fn init(configuration: Access.Configuration) Access {
        std.debug.assert(configuration.maximum_checkpoint_records != 0);
        return .{
            .interface = configuration.interface,
            .loader = configuration.loader,
            .maximum_checkpoint_records = configuration.maximum_checkpoint_records,
        };
    }

    pub fn namespace(self: *const Access, value: []const u8) Namespace {
        std.debug.assert(value.len != 0);
        return self.interface.namespace(value);
    }

    pub fn load(self: *const Access, namespace_bytes: []const u8, key: []const u8, destination: []u8) LoadError!LoadResult {
        if (self.interface.poisoned()) return error.ReadFailed;
        const loader = self.loader orelse return error.ReadFailed;
        return loader.read(namespace_bytes, key, destination);
    }

    pub fn plugin(self: *const Access, namespace_bytes: []const u8) PluginAccess {
        std.debug.assert(namespace_bytes.len != 0);
        return .{ .access = self, .namespace_bytes = namespace_bytes };
    }

    pub fn checkpointCapacity(self: *const Access) usize {
        return self.maximum_checkpoint_records;
    }
};

pub const PluginAccess = struct {
    access: *const Access,
    namespace_bytes: []const u8,

    pub fn load(self: PluginAccess, key: []const u8, destination: []u8) LoadError!LoadResult {
        return self.access.load(self.namespace_bytes, key, destination);
    }

    pub fn runtime(self: PluginAccess) Namespace {
        return self.access.namespace(self.namespace_bytes);
    }

    pub fn pollRead(self: PluginAccess, request: Request) ReadResult {
        return self.access.interface.pollRead(request);
    }

    pub fn checkpointProgress(self: PluginAccess) Status {
        return self.access.interface.checkpointProgress();
    }

    pub fn checkpointCapacity(self: PluginAccess) usize {
        return self.access.checkpointCapacity();
    }

    pub fn flush(self: PluginAccess) Status {
        return self.access.interface.flush();
    }
};

const SlotState = enum(u8) { empty, live, tombstone };
const Slot = struct {
    state: SlotState = .empty,
    hash: u64 = 0,
    namespace_len: u16 = 0,
    key_len: u16 = 0,
    location: Location = .{ .offset = 0, .length = 0 },
    namespace: []u8 = &.{},
    key: []u8 = &.{},
};
const Change = struct {
    operation: Operation = .delete,
    latest: bool = false,
    namespace_len: u16 = 0,
    key_len: u16 = 0,
    value_len: u32 = 0,
    namespace: []u8 = &.{},
    key: []u8 = &.{},
    value: []u8 = &.{},
};
const RequestState = enum(u8) { free, pending, submitted, done };
const ReadRequest = struct {
    state: RequestState = .free,
    generation: u16 = 1,
    location: Location = .{ .offset = 0, .length = 0 },
    destination: []u8 = &.{},
    result: ReadResult = .{ .status = .pending },
};
const CommitState = enum(u8) { idle, staged, encoded, durable, failed };

pub const Store = struct {
    pub const Purpose = enum { live, recovery, compaction };
    configuration: Configuration,
    slots: []Slot,
    disk: ?struct {
        io: disk_index.Io,
        root: disk_index.Root = .{},
        prepared: ?disk_index.Root = null,
        workspace: *disk_index.Workspace,
        scan_keys: []u8,
    } = null,
    changes: []Change,
    change_order: []u32,
    requests: []ReadRequest,
    test_storage: []u8 = &.{},
    test_storage_len: usize = 0,
    encoded: []u8 = &.{},
    encoded_len: usize = 0,
    staged_values: []u8 = &.{},
    staged_value_len: usize = 0,
    staged_key_bytes: usize = 0,
    commit_offset: u64 = 0,
    commit_pack: u32 = 0,
    staged_count: usize = 0,
    reservation: ?struct { count: usize, value_bytes: usize, key_bytes: usize } = null,
    reservation_generation: u64 = 1,
    generation: u64 = 0,
    live_count: usize = 0,
    commit: CommitState = .idle,
    checkpoint_requested: bool = false,
    drain_context: ?*anyopaque = null,
    drain_fn: ?*const fn (*anyopaque, std.Io) DrainError!void = null,
    poisoned_storage: bool = false,
    checkpoint_gate_context: ?*anyopaque = null,
    checkpoint_gate: ?*const fn (*anyopaque) bool = null,
    read_gate_context: ?*anyopaque = null,
    read_gate: ?*const fn (*anyopaque) bool = null,

    pub fn initForTest(allocator: std.mem.Allocator, configuration: Configuration, storage_capacity: usize) !*Store {
        if (storage_capacity < try maximumCheckpointBytes(configuration)) return error.InvalidCapacity;
        const self = try init(allocator, configuration, .live, null);
        self.test_storage = try preallocated.alloc(u8, allocator, storage_capacity);
        return self;
    }

    pub fn initIndex(allocator: std.mem.Allocator, configuration: Configuration) !*Store {
        return init(allocator, configuration, .live, null);
    }

    pub fn initRecoveryIndex(allocator: std.mem.Allocator, configuration: Configuration) !*Store {
        return init(allocator, configuration, .recovery, null);
    }

    pub fn initCompactionIndex(allocator: std.mem.Allocator, configuration: Configuration) !*Store {
        return init(allocator, configuration, .compaction, null);
    }

    pub fn initDiskIndex(allocator: std.mem.Allocator, configuration: Configuration, purpose: Purpose, io: disk_index.Io) !*Store {
        if (configuration.maximum_namespace_bytes + configuration.maximum_key_bytes > disk_index.max_key_bytes)
            return error.InvalidCapacity;
        return init(allocator, configuration, purpose, io);
    }

    pub fn rebindEmptyDiskIndex(self: *Store, io: disk_index.Io) !void {
        if (self.poisoned_storage or self.commit != .idle or self.reservation != null or self.checkpoint_requested)
            return error.IndexBusy;
        for (self.requests) |request| if (request.state != .free) return error.IndexBusy;
        const index = if (self.disk) |*value| value else return error.IndexUnavailable;
        index.io = io;
        index.root = .{};
        index.prepared = null;
        index.workspace.reset();
        self.live_count = 0;
        self.generation = 0;
    }

    pub fn openDiskIndex(self: *Store, root: disk_index.Root, generation: u64) !void {
        if (self.commit != .idle or self.reservation != null) return error.IndexBusy;
        const index = if (self.disk) |*value| value else return error.IndexUnavailable;
        if ((root.page == 0) != (root.count == 0) or root.count > std.math.maxInt(usize)) return error.InvalidIndex;
        index.root = root;
        index.prepared = null;
        index.workspace.reset();
        self.live_count = @intCast(root.count);
        self.generation = generation;
    }

    /// Build and seal these index pages before the backend publishes their root with the data pack.
    pub fn prepareDiskIndex(self: *Store, pack: u32, offset: u64) !disk_index.Root {
        const index = if (self.disk) |*value| value else return error.IndexUnavailable;
        if (self.poisoned_storage or self.commit != .encoded or index.prepared != null) return error.IndexBusy;
        if (pack == std.math.maxInt(u32) or offset > std.math.maxInt(usize)) return error.InvalidIndex;
        errdefer self.markFailed();
        var next = index.root;
        var reader = Reader{ .bytes = self.encoded[0..self.encoded_len], .cursor = header_bytes };
        for (0..self.staged_count) |_| {
            const record = try reader.record(.{ .pack = pack, .offset = @intCast(offset) });
            next = try disk_index.apply(index.io, next, index.workspace, record.namespace, record.key, switch (record.operation) {
                .put => .{ .put = .{ .pack = record.location.pack, .offset = record.location.offset, .length = record.location.length } },
                .delete => .delete,
            });
        }
        index.prepared = next;
        self.commit_pack = pack;
        self.commit_offset = offset;
        return next;
    }

    pub fn indexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return layoutBytes(configuration, 0, .live);
    }

    pub fn maximumIndexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return maximumLayoutBytes(configuration, .live);
    }

    pub fn maximumDiskIndexBytes(configuration: Configuration, purpose: Purpose) !usize {
        try configuration.validate();
        const alignment = @max(@alignOf(Store), @max(@alignOf(Change), @alignOf(disk_index.Workspace)));
        var required: usize = 0;
        for (0..alignment) |base| required = @max(required, try layoutBytesForIndex(configuration, base, purpose, true));
        return required;
    }

    pub fn maximumRecoveryIndexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return maximumLayoutBytes(configuration, .recovery);
    }

    pub fn maximumCompactionIndexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return maximumLayoutBytes(configuration, .compaction);
    }

    pub fn testReservation(configuration: Configuration, storage_capacity: usize) !Reservation {
        if (storage_capacity < try maximumCheckpointBytes(configuration)) return error.InvalidCapacity;
        try configuration.validate();
        return .{
            .index_bytes = try maximumLayoutBytes(configuration, .live),
            .test_storage_bytes = storage_capacity,
        };
    }

    fn init(allocator: std.mem.Allocator, configuration: Configuration, purpose: Purpose, index_io: ?disk_index.Io) !*Store {
        try configuration.validate();
        const self = try preallocated.create(Store, allocator);
        const slot_count = try slotCount(configuration);
        self.* = .{
            .configuration = configuration,
            .slots = if (index_io == null) try preallocated.alloc(Slot, allocator, slot_count) else &.{},
            .changes = try preallocated.alloc(Change, allocator, configuration.maximum_checkpoint_records),
            .change_order = try preallocated.alloc(u32, allocator, configuration.maximum_checkpoint_records),
            .requests = if (purpose == .live) try preallocated.alloc(ReadRequest, allocator, configuration.maximum_requests) else &.{},
            .encoded = if (purpose != .recovery) try preallocated.alloc(u8, allocator, try maximumCheckpointBytes(configuration)) else &.{},
            .staged_values = if (purpose != .recovery) try preallocated.alloc(u8, allocator, configuration.maximum_checkpoint_bytes) else &.{},
        };
        @memset(self.slots, .{});
        @memset(self.changes, .{});
        @memset(self.requests, .{});
        try assignSlotBuffers(allocator, self.slots, configuration);
        try assignChangeBuffers(allocator, self.changes, configuration);
        if (index_io) |io| {
            const workspace = try preallocated.create(disk_index.Workspace, allocator);
            workspace.* = .{};
            self.disk = .{
                .io = io,
                .workspace = workspace,
                .scan_keys = try preallocated.alloc(u8, allocator, try std.math.mul(usize, configuration.maximum_checkpoint_records, configuration.maximum_key_bytes)),
            };
        }
        return self;
    }

    pub fn interface(self: *Store) Interface {
        return .{ .context = self, .vtable = &vtable };
    }
    pub fn bindDrain(self: *Store, context: *anyopaque, drain_fn: *const fn (*anyopaque, std.Io) DrainError!void) !void {
        if (self.drain_fn != null) return error.DrainAlreadyBound;
        self.drain_context = context;
        self.drain_fn = drain_fn;
    }

    pub fn drain(self: *Store, io: std.Io) DrainError!void {
        if (self.poisoned_storage or self.reservation != null) return error.Unavailable;
        if (self.drain_fn) |drain_fn| return drain_fn(self.drain_context.?, io);
        if (self.commit == .idle and !self.checkpoint_requested) return;
        if (self.test_storage.len == 0) return error.Unavailable;
        switch (self.flush()) {
            .ready, .pending, .backpressured => {},
            else => return error.Unavailable,
        }
        self.submit();
        _ = self.complete(self.requests.len + 1);
        if (self.checkpointProgress() != .ready) return error.Unavailable;
    }
    pub fn bindCheckpointGate(self: *Store, context: *anyopaque, gate: *const fn (*anyopaque) bool) !void {
        if (self.checkpoint_gate != null) return error.CheckpointGateBound;
        self.checkpoint_gate_context = context;
        self.checkpoint_gate = gate;
    }
    pub fn bindReadGate(self: *Store, context: *anyopaque, gate: *const fn (*anyopaque) bool) !void {
        if (self.read_gate != null) return error.ReadGateBound;
        self.read_gate_context = context;
        self.read_gate = gate;
    }

    pub fn installCompactedIndex(self: *Store, compacted: *Store) !void {
        if (!self.epochSwitchReady()) return error.EpochSwitchBusy;
        if (!compacted.epochSwitchReady() or compacted.staged_count != 0) return error.CompactedIndexBusy;
        if ((self.disk == null) != (compacted.disk == null)) return error.IndexTypeMismatch;
        if (self.disk != null) std.mem.swap(@TypeOf(self.disk), &self.disk, &compacted.disk) else std.mem.swap([]Slot, &self.slots, &compacted.slots);
        self.generation = compacted.generation;
        self.live_count = compacted.live_count;
        compacted.clearIndex();
    }
    pub fn poisoned(self: *const Store) bool {
        return self.poisoned_storage;
    }

    pub fn startupLocation(self: *Store, namespace: []const u8, key: []const u8) ?Location {
        if (self.poisoned_storage) return null;
        if (!self.validKey(namespace, key)) return null;
        if (self.disk) |*index| {
            const value = disk_index.lookup(index.io, index.root, index.workspace, namespace, key) catch {
                self.markFailed();
                return null;
            } orelse return null;
            return .{ .pack = value.pack, .offset = value.offset, .length = value.length };
        }
        const index = self.lookup(namespace, key) orelse return null;
        return self.slots[index].location;
    }

    pub fn currentValue(self: *Store, namespace: []const u8, key: []const u8) CurrentValue {
        if (self.poisoned_storage) return .failed;
        if (!self.validKey(namespace, key)) return .missing;
        if (self.stagedChange(namespace, key)) |change| {
            return switch (change.operation) {
                .put => .{ .staged = change.value },
                .delete => .missing,
            };
        }
        const location = self.startupLocation(namespace, key) orelse return if (self.poisoned_storage) .failed else .missing;
        return .{ .persisted = location };
    }

    pub fn valueLength(self: *Store, namespace: []const u8, key: []const u8) ?usize {
        if (self.poisoned_storage) return null;
        if (self.stagedChange(namespace, key)) |change|
            return if (change.operation == .put) change.value_len else null;
        return (self.startupLocation(namespace, key) orelse return null).length;
    }

    pub fn scan(self: *Store, namespace: []const u8, after: []const u8, output: []ScanRecord) ScanError!ScanResult {
        if (self.poisoned_storage) return error.StorageFailed;
        if (namespace.len == 0 or namespace.len > self.configuration.maximum_namespace_bytes) return error.InvalidNamespace;
        if (output.len == 0) return error.EmptyBatch;
        const capacity = if (self.disk == null) output.len else @min(output.len, self.configuration.maximum_checkpoint_records);
        var batch = ScanBuffer{ .records = output[0..capacity] };
        if (self.disk) |*index| {
            var cursor = disk_index.Cursor.init(index.io, index.root, index.workspace);
            var item = cursor.seek(namespace, after) catch {
                self.markFailed();
                return error.StorageFailed;
            };
            var copied: usize = 0;
            while (item) |record| {
                if (!std.mem.eql(u8, namespace, record.namespace)) break;
                if (std.mem.lessThan(u8, after, record.key) and self.stagedChange(namespace, record.key) == null) {
                    if (copied == capacity) {
                        batch.total += 1;
                        break;
                    }
                    if (record.key.len > self.configuration.maximum_key_bytes) {
                        self.markFailed();
                        return error.StorageFailed;
                    }
                    const key = index.scan_keys[copied * self.configuration.maximum_key_bytes ..][0..record.key.len];
                    @memcpy(key, record.key);
                    batch.include(.{ .key = key, .value_bytes = record.location.length });
                    copied += 1;
                }
                item = cursor.next() catch {
                    self.markFailed();
                    return error.StorageFailed;
                };
            }
        } else for (self.slots) |*slot| {
            if (slot.state != .live or !std.mem.eql(u8, namespace, slot.namespace[0..slot.namespace_len])) continue;
            const key = slot.key[0..slot.key_len];
            if (!std.mem.lessThan(u8, after, key)) continue;
            if (self.stagedChange(namespace, key) != null) continue;
            batch.include(.{ .key = key, .value_bytes = slot.location.length });
        }
        for (self.changes[0..self.staged_count]) |*change| {
            if (change.operation == .delete or !std.mem.eql(u8, namespace, change.namespace[0..change.namespace_len])) continue;
            const key = change.key[0..change.key_len];
            if (!std.mem.lessThan(u8, after, key)) continue;
            if (self.stagedChange(namespace, key).? != change) continue;
            batch.include(.{ .key = key, .value_bytes = change.value_len });
        }
        std.mem.sortUnstable(ScanRecord, output[0..batch.count], {}, ScanBuffer.less);
        return .{ .count = batch.count, .more = batch.total > batch.count };
    }

    pub fn epochSwitchReady(self: *const Store) bool {
        if (self.reservation != null or self.checkpoint_requested) return false;
        if (self.commit != .idle and self.commit != .staged) return false;
        for (self.requests) |request| if (request.state == .pending or request.state == .submitted) return false;
        return true;
    }
    /// Records are borrowed until the next operation on this Store.
    pub fn nextLive(self: *Store, cursor: *LiveCursor) LiveError!?LiveRecord {
        if (self.poisoned_storage) return error.Poisoned;
        if (self.disk) |*index| {
            const first = !cursor.disk_started;
            if (first) {
                cursor.disk_root = index.root;
                cursor.disk_started = true;
            }
            if (cursor.disk_root.page == 0 and cursor.disk_root.count == 0) return null;
            var index_cursor = disk_index.Cursor.init(index.io, cursor.disk_root, index.workspace);
            var item: ?disk_index.Entry = undefined;
            if (first) {
                item = index_cursor.seek("", "") catch |err| {
                    self.markFailed();
                    return mapLiveIndexError(err);
                };
            } else {
                const found = index_cursor.seek(cursor.last[0..cursor.namespace_len], cursor.last[cursor.namespace_len .. cursor.namespace_len + cursor.key_len]) catch |err| {
                    self.markFailed();
                    return mapLiveIndexError(err);
                } orelse {
                    self.markFailed();
                    return error.Corrupt;
                };
                if (!std.mem.eql(u8, found.namespace, cursor.last[0..cursor.namespace_len]) or
                    !std.mem.eql(u8, found.key, cursor.last[cursor.namespace_len .. cursor.namespace_len + cursor.key_len]))
                {
                    self.markFailed();
                    return error.Corrupt;
                }
                item = index_cursor.next() catch |err| {
                    self.markFailed();
                    return mapLiveIndexError(err);
                };
            }
            const record = item orelse return null;
            const combined = std.math.add(usize, record.namespace.len, record.key.len) catch {
                self.markFailed();
                return error.Corrupt;
            };
            if (combined > cursor.last.len) {
                self.markFailed();
                return error.Corrupt;
            }
            @memcpy(cursor.last[0..record.namespace.len], record.namespace);
            @memcpy(cursor.last[record.namespace.len..combined], record.key);
            cursor.namespace_len = record.namespace.len;
            cursor.key_len = record.key.len;
            return .{
                .namespace = record.namespace,
                .key = record.key,
                .location = .{ .pack = record.location.pack, .offset = record.location.offset, .length = record.location.length },
            };
        }
        while (cursor.slot < self.slots.len) : (cursor.slot += 1) {
            const slot = &self.slots[cursor.slot];
            if (slot.state != .live) continue;
            cursor.slot += 1;
            return .{
                .namespace = slot.namespace[0..slot.namespace_len],
                .key = slot.key[0..slot.key_len],
                .location = slot.location,
            };
        }
        return null;
    }
    pub fn liveRecords(self: *const Store) usize {
        return self.live_count;
    }
    pub fn stagedRecords(self: *const Store) usize {
        return self.staged_count;
    }
    pub fn checkpointRecordCapacity(self: *const Store) usize {
        return self.changes.len;
    }
    pub fn markFailed(self: *Store) void {
        self.poisoned_storage = true;
        self.commit = .failed;
    }

    pub fn read(self: *Store, namespace: []const u8, key: []const u8, destination: []u8) Request {
        return self.interface().read(namespace, key, destination);
    }

    pub fn readBatch(self: *Store, reads: []const Read, requests: []Request) Status {
        return self.readRecords(.{ .records = reads }, requests);
    }

    fn readRecords(self: *Store, batch: ReadBatch, requests: []Request) Status {
        const reads = batch.records;
        std.debug.assert(reads.len == requests.len);
        if (self.poisoned_storage) return .failed;
        for (reads) |read_record| {
            if (batch.namespace != null and read_record.namespace.len != 0) return .failed;
            if (!self.validKey(batch.namespace orelse read_record.namespace, read_record.key)) return .failed;
        }
        if (self.read_gate) |gate| {
            if (!gate(self.read_gate_context.?)) return .backpressured;
        }
        var available: usize = 0;
        for (self.requests) |read_state| {
            if (available == reads.len) break;
            if (read_state.state == .free) available += 1;
        }
        if (reads.len > available) return .backpressured;
        var index: usize = 0;
        for (reads, requests) |read_record, *request| {
            const namespace_bytes = batch.namespace orelse read_record.namespace;
            while (self.requests[index].state != .free) : (index += 1) {}
            const read_state = &self.requests[index];
            request.* = token(index, read_state.generation);
            index += 1;
            read_state.state = .done;
            read_state.destination = read_record.destination;
            read_state.result = .{ .status = .missing };
            if (self.stagedChange(namespace_bytes, read_record.key)) |change| {
                if (change.operation == .delete) continue;
                if (read_record.destination.len < change.value_len) {
                    read_state.result = .{ .status = .too_small, .bytes = change.value_len };
                } else {
                    @memcpy(read_record.destination[0..change.value_len], change.value);
                    read_state.result = .{ .status = .ready, .bytes = change.value_len };
                }
                continue;
            }
            read_state.location = self.startupLocation(namespace_bytes, read_record.key) orelse {
                if (self.poisoned_storage) return .failed;
                continue;
            };
            if (read_record.destination.len < read_state.location.length) {
                read_state.result = .{ .status = .too_small, .bytes = read_state.location.length };
                continue;
            }
            read_state.state = .pending;
            read_state.result = .{ .status = .pending };
        }
        return .ready;
    }

    pub fn pollRead(self: *Store, request_token: Request) ReadResult {
        if (self.poisoned_storage) return .{ .status = .failed };
        const read_state = self.lookupRequest(request_token) orelse return .{ .status = .failed };
        const result = read_state.result;
        if (read_state.state == .done) {
            read_state.state = .free;
            read_state.generation +%= 1;
            if (read_state.generation == 0) read_state.generation = 1;
        }
        return result;
    }

    pub fn stage(self: *Store, record: CheckpointRecord) Status {
        return self.stageBatch(&.{record});
    }

    pub fn stageBatch(self: *Store, records: []const CheckpointRecord) Status {
        return self.interface().stageBatch(records);
    }

    pub fn reserve(self: *Store, records: []const CheckpointRecord) ReserveError!WriteReservation {
        return self.reserveBatch(.{ .records = records });
    }

    pub fn reserveBatch(self: *Store, batch: WriteBatch) ReserveError!WriteReservation {
        const records = batch.records;
        if (self.poisoned_storage) return error.StorageFailed;
        if (self.checkpoint_requested) return error.Backpressured;
        if (self.reservation != null or self.commit == .encoded or self.commit == .durable) return error.Backpressured;
        if (records.len > self.changes.len - self.staged_count) return error.Backpressured;
        var value_end = self.staged_value_len;
        var key_bytes = self.staged_key_bytes;
        const record_count = self.staged_count + records.len;
        var encoded_bytes: usize = header_bytes + commit_bytes;
        const records_bytes = std.math.mul(usize, record_count, record_bytes) catch return error.Backpressured;
        encoded_bytes = std.math.add(usize, encoded_bytes, records_bytes) catch return error.Backpressured;
        for (records) |record| {
            if (batch.namespace != null and record.namespace.len != 0) return error.InvalidKey;
            const namespace_bytes = batch.namespace orelse record.namespace;
            if (!self.validKey(namespace_bytes, record.key)) return error.InvalidKey;
            const value_length = switch (record.operation) {
                .put => |bytes| bytes.len,
                .delete => 0,
            };
            if (value_length > self.configuration.maximum_value_bytes) return error.ValueTooLarge;
            value_end = std.math.add(usize, value_end, value_length) catch return error.Backpressured;
            key_bytes = std.math.add(usize, key_bytes, namespace_bytes.len) catch return error.Backpressured;
            key_bytes = std.math.add(usize, key_bytes, record.key.len) catch return error.Backpressured;
        }
        if (value_end > self.staged_values.len) return error.Backpressured;
        encoded_bytes = std.math.add(usize, encoded_bytes, key_bytes) catch return error.Backpressured;
        encoded_bytes = std.math.add(usize, encoded_bytes, value_end) catch return error.Backpressured;
        if (encoded_bytes > self.configuration.maximum_checkpoint_bytes) return error.Backpressured;
        var cursor = self.staged_value_len;
        for (records, self.staged_count..) |record, index| {
            const change = &self.changes[index];
            const value = switch (record.operation) {
                .put => |bytes| bytes,
                .delete => &.{},
            };
            change.operation = record.operation;
            copyKey(change.namespace, change.key, &change.namespace_len, &change.key_len, batch.namespace orelse record.namespace, record.key);
            change.value_len = @intCast(value.len);
            change.value = self.staged_values[cursor..][0..value.len];
            @memcpy(change.value, value);
            cursor += value.len;
        }
        if (self.disk == null and record_count > self.configuration.maximum_keys - self.live_count)
            self.preflight(record_count) catch return error.IndexCapacityExceeded;
        self.reservation = .{ .count = record_count, .value_bytes = value_end, .key_bytes = key_bytes };
        return @enumFromInt(self.reservation_generation);
    }

    pub fn publish(self: *Store, token_value: WriteReservation) void {
        std.debug.assert(@intFromEnum(token_value) == self.reservation_generation);
        const reserved = self.reservation.?;
        self.staged_count = reserved.count;
        self.staged_value_len = reserved.value_bytes;
        self.staged_key_bytes = reserved.key_bytes;
        if (self.staged_count != 0 and !self.poisoned_storage) self.commit = .staged;
        self.cancel(token_value);
    }

    pub fn cancel(self: *Store, token_value: WriteReservation) void {
        std.debug.assert(@intFromEnum(token_value) == self.reservation_generation);
        std.debug.assert(self.reservation != null);
        self.reservation = null;
        self.reservation_generation += 1;
    }

    pub fn flush(self: *Store) Status {
        if (self.poisoned_storage) return .failed;
        if (self.reservation != null) return .backpressured;
        if (self.checkpoint_gate) |gate| {
            if (!gate(self.checkpoint_gate_context.?)) return .backpressured;
        }
        switch (self.commit) {
            .idle => return .ready,
            .encoded, .durable => return .backpressured,
            .failed => return .failed,
            .staged => {},
        }
        self.preflight(self.staged_count) catch {
            self.markFailed();
            return .failed;
        };
        for (0..self.staged_count) |start| {
            if (self.change_order[start] == start) continue;
            const saved = self.changes[start];
            var current = start;
            while (true) {
                const next = self.change_order[current];
                self.change_order[current] = @intCast(current);
                if (next == start) {
                    self.changes[current] = saved;
                    break;
                }
                self.changes[current] = self.changes[next];
                current = next;
            }
        }
        var retained: usize = 0;
        for (0..self.staged_count) |index| {
            if (!self.changes[index].latest) continue;
            std.mem.swap(Change, &self.changes[retained], &self.changes[index]);
            retained += 1;
        }
        self.staged_count = retained;
        self.encoded_len = encode(self, self.encoded) catch {
            self.markFailed();
            return .failed;
        };
        self.commit = .encoded;
        return .pending;
    }

    pub fn requestCheckpoint(self: *Store) Status {
        if (self.checkpoint_requested) return .backpressured;
        switch (self.flush()) {
            .ready, .pending => {},
            else => |status| return status,
        }
        self.checkpoint_requested = true;
        return .pending;
    }

    pub fn finishCheckpoint(self: *Store) void {
        std.debug.assert(self.checkpoint_requested);
        std.debug.assert(self.commit == .idle);
        self.checkpoint_requested = false;
    }

    pub fn checkpointBytes(self: *const Store) []const u8 {
        if (self.commit != .encoded) return &.{};
        return self.encoded[0..self.encoded_len];
    }

    pub fn checkpointProgress(self: *const Store) Status {
        if (self.checkpoint_requested and !self.poisoned_storage) return .pending;
        return switch (self.commit) {
            .idle => .ready,
            .staged, .encoded, .durable => .pending,
            .failed => .failed,
        };
    }
    pub fn markDurableAt(self: *Store, offset: u64) void {
        self.markDurableInPack(0, offset);
    }

    pub fn markDurableInPack(self: *Store, pack: u32, offset: u64) void {
        if (self.commit != .encoded) return;
        if (pack == std.math.maxInt(u32)) {
            self.markFailed();
            return;
        }
        if (self.disk) |index| {
            if (index.prepared == null or self.commit_pack != pack or self.commit_offset != offset) {
                self.markFailed();
                return;
            }
        }
        self.commit_offset = offset;
        self.commit_pack = pack;
        self.commit = .durable;
    }

    pub fn submit(self: *Store) void {
        if (self.commit != .encoded or self.test_storage.len == 0) return;
        if (self.encoded_len > self.test_storage.len - self.test_storage_len) {
            self.markFailed();
            return;
        }
        const offset = self.test_storage_len;
        @memcpy(self.test_storage[offset..][0..self.encoded_len], self.encoded[0..self.encoded_len]);
        self.test_storage_len += self.encoded_len;
        self.markDurableAt(offset);
    }

    pub fn complete(self: *Store, limit: usize) usize {
        var count: usize = 0;
        for (self.requests, 0..) |*read_state, index| {
            if (count == limit) break;
            if (read_state.state != .pending) continue;
            if (self.test_storage.len == 0) continue;
            const offset: usize = @intCast(read_state.location.offset);
            if (offset > self.test_storage_len) {
                self.markFailed();
                break;
            }
            self.completeRead(token(index, read_state.generation), self.test_storage[offset..self.test_storage_len]) catch self.markFailed();
            count += 1;
        }
        if (count < limit and self.commit == .durable) {
            self.applyChanges() catch self.markFailed();
            count += 1;
        }
        if (self.test_storage.len != 0 and self.checkpoint_requested and self.commit == .idle)
            self.finishCheckpoint();
        return count;
    }

    pub fn takeReadTasks(self: *Store, output: []ReadTask) usize {
        if (self.poisoned_storage) return 0;
        var count: usize = 0;
        for (self.requests, 0..) |*read_state, index| {
            if (count == output.len) break;
            if (read_state.state != .pending) continue;
            read_state.state = .submitted;
            output[count] = .{ .request = token(index, read_state.generation), .location = read_state.location, .destination = read_state.destination };
            count += 1;
        }
        return count;
    }

    pub fn completeRead(self: *Store, request_token: Request, source: []const u8) !void {
        const read_state = self.lookupRequest(request_token) orelse return error.StaleRequest;
        if (read_state.state != .pending and read_state.state != .submitted) return error.StaleRequest;
        if (self.poisoned_storage) {
            read_state.result = .{ .status = .failed };
            read_state.state = .done;
            return error.StorageFailed;
        }
        const length: usize = read_state.location.length;
        if (source.len < length) {
            read_state.result = .{ .status = .failed };
            read_state.state = .done;
            self.markFailed();
            return error.ShortRead;
        }
        std.debug.assert(read_state.destination.len >= length);
        const destination = read_state.destination[0..length];
        const input = source[0..length];
        if (@intFromPtr(destination.ptr) != @intFromPtr(input.ptr)) @memcpy(destination, input);
        read_state.result = .{ .status = .ready, .bytes = length };
        read_state.state = .done;
    }

    pub fn recover(self: *Store, bytes: []const u8) !usize {
        if (self.poisoned_storage) return error.StorageFailed;
        self.beginRecovery();
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            const consumed = self.recoverOne(bytes[cursor..], cursor) catch |err| switch (err) {
                error.Truncated => break,
                else => return err,
            };
            cursor += consumed;
        }
        return cursor;
    }

    pub fn beginRecovery(self: *Store) void {
        self.clearIndex();
    }

    pub fn recoverOne(self: *Store, bytes: []const u8, file_offset: usize) !usize {
        return self.recoverOneInPack(bytes, 0, file_offset);
    }

    pub fn recoverOneInPack(self: *Store, bytes: []const u8, pack: u32, file_offset: usize) !usize {
        if (self.poisoned_storage) return error.StorageFailed;
        errdefer |err| if (err != error.Truncated) self.markFailed();
        if (pack == std.math.maxInt(u32)) return error.InvalidJournal;
        var parsed = try parse(bytes, 0);
        if (self.generation != 0 and parsed.generation != self.generation + 1)
            return error.InvalidJournal;
        parsed.base = .{ .pack = pack, .offset = file_offset };
        try self.preflightParsed(parsed);
        try self.applyParsed(parsed);
        return parsed.end;
    }

    fn applyChanges(self: *Store) !void {
        if (self.disk) |*index| {
            index.root = index.prepared orelse return error.IndexUnavailable;
            index.prepared = null;
            self.live_count = @intCast(index.root.count);
            self.generation += 1;
        } else try self.applyParsed(.{
            .bytes = self.encoded[0..self.encoded_len],
            .generation = self.generation + 1,
            .count = @intCast(self.staged_count),
            .records_start = header_bytes,
            .end = self.encoded_len,
            .base = .{ .pack = self.commit_pack, .offset = @intCast(self.commit_offset) },
        });
        self.staged_count = 0;
        self.staged_value_len = 0;
        self.staged_key_bytes = 0;
        self.commit = .idle;
    }

    fn preflight(self: *Store, count: usize) !void {
        for (self.changes[0..count], self.change_order[0..count], 0..) |*change, *index, position| {
            change.latest = false;
            index.* = @intCast(position);
        }
        const order = self.change_order[0..count];
        std.mem.sortUnstable(u32, order, self, lessChange);
        var projected = self.live_count;
        for (order, 0..) |index, position| {
            if (position + 1 < order.len and self.changeKeyOrder(index, order[position + 1]) == .eq) continue;
            const change = &self.changes[index];
            change.latest = true;
            const was_live = self.startupLocation(change.namespace[0..change.namespace_len], change.key[0..change.key_len]) != null;
            if (self.poisoned_storage) return error.StorageFailed;
            switch (change.operation) {
                .put => {
                    if (!was_live) projected += 1;
                },
                .delete => {
                    if (was_live) projected -= 1;
                },
            }
        }
        if (self.disk == null and projected > self.configuration.maximum_keys) return error.KeyCapacity;
    }

    fn apply(self: *Store, operation: Operation, namespace: []const u8, key: []const u8, location: Location) !void {
        if (self.disk) |*index| {
            index.root = try disk_index.apply(index.io, index.root, index.workspace, namespace, key, switch (operation) {
                .put => .{ .put = .{ .pack = location.pack, .offset = location.offset, .length = location.length } },
                .delete => .delete,
            });
            self.live_count = @intCast(index.root.count);
            return;
        }
        const result = self.lookupOrVacancy(namespace, key) orelse return error.KeyCapacity;
        const slot = &self.slots[result.index];
        if (operation == .delete) {
            if (result.found) {
                slot.state = .tombstone;
                self.live_count -= 1;
            }
            return;
        }
        if (!result.found) {
            slot.state = .live;
            slot.hash = hash(namespace, key);
            copyKey(slot.namespace, slot.key, &slot.namespace_len, &slot.key_len, namespace, key);
            self.live_count += 1;
        }
        slot.location = location;
    }

    fn applyParsed(self: *Store, parsed: Parsed) !void {
        for ([_]Operation{ .delete, .put }) |operation| {
            var reader = Reader{ .bytes = parsed.bytes, .cursor = parsed.records_start };
            for (0..parsed.count) |index| {
                const record = try reader.record(parsed.base);
                if (record.operation != operation or !self.changes[index].latest) continue;
                try self.apply(record.operation, record.namespace, record.key, record.location);
            }
        }
        self.generation = parsed.generation;
    }

    fn preflightParsed(self: *Store, parsed: Parsed) !void {
        if (parsed.count > self.changes.len) return error.KeyCapacity;
        var reader = Reader{ .bytes = parsed.bytes, .cursor = parsed.records_start };
        for (0..parsed.count) |index| {
            const record = try reader.record(parsed.base);
            if (!self.validKey(record.namespace, record.key) or record.location.length > self.configuration.maximum_value_bytes) return error.InvalidJournal;
            const change = &self.changes[index];
            change.operation = record.operation;
            copyKey(change.namespace, change.key, &change.namespace_len, &change.key_len, record.namespace, record.key);
        }
        try self.preflight(parsed.count);
    }

    fn lookup(self: *const Store, namespace: []const u8, key: []const u8) ?usize {
        const start = @as(usize, @truncate(hash(namespace, key))) & (self.slots.len - 1);
        for (0..self.slots.len) |step| {
            const index = (start + step) & (self.slots.len - 1);
            const slot = &self.slots[index];
            if (slot.state == .empty) return null;
            if (slot.state == .live and equal(slot, namespace, key)) return index;
        }
        return null;
    }
    const Vacancy = struct { index: usize, found: bool };
    fn lookupOrVacancy(self: *const Store, namespace: []const u8, key: []const u8) ?Vacancy {
        const start = @as(usize, @truncate(hash(namespace, key))) & (self.slots.len - 1);
        var first_tombstone: ?usize = null;
        for (0..self.slots.len) |step| {
            const index = (start + step) & (self.slots.len - 1);
            const slot = &self.slots[index];
            switch (slot.state) {
                .empty => return .{ .index = first_tombstone orelse index, .found = false },
                .tombstone => {
                    if (first_tombstone == null) first_tombstone = index;
                },
                .live => if (equal(slot, namespace, key)) return .{ .index = index, .found = true },
            }
        }
        return if (first_tombstone) |index| .{ .index = index, .found = false } else null;
    }
    fn lookupRequest(self: *Store, request_token: Request) ?*ReadRequest {
        const index: u16 = @truncate(request_token);
        const generation: u16 = @truncate(request_token >> 16);
        if (index >= self.requests.len) return null;
        const read_state = &self.requests[index];
        return if (read_state.generation == generation and read_state.state != .free) read_state else null;
    }
    fn validKey(self: *const Store, namespace: []const u8, key: []const u8) bool {
        return namespace.len != 0 and key.len != 0 and
            namespace.len <= self.configuration.maximum_namespace_bytes and
            key.len <= self.configuration.maximum_key_bytes;
    }
    fn clearIndex(self: *Store) void {
        for (self.slots) |*slot| slot.state = .empty;
        self.generation = 0;
        self.live_count = 0;
        if (self.disk) |*index| {
            index.root = .{};
            index.prepared = null;
        }
    }

    fn changeKeyOrder(self: *const Store, a: u32, b: u32) std.math.Order {
        const lhs = &self.changes[a];
        const rhs = &self.changes[b];
        const namespace = std.mem.order(u8, lhs.namespace[0..lhs.namespace_len], rhs.namespace[0..rhs.namespace_len]);
        return if (namespace != .eq) namespace else std.mem.order(u8, lhs.key[0..lhs.key_len], rhs.key[0..rhs.key_len]);
    }

    fn lessChange(self: *const Store, a: u32, b: u32) bool {
        const order = self.changeKeyOrder(a, b);
        return order == .lt or (order == .eq and a < b);
    }

    fn stagedChange(self: *const Store, namespace: []const u8, key: []const u8) ?*const Change {
        var index = self.staged_count;
        while (index != 0) {
            index -= 1;
            const change = &self.changes[index];
            if (change.namespace_len == namespace.len and change.key_len == key.len and
                std.mem.eql(u8, change.namespace[0..change.namespace_len], namespace) and
                std.mem.eql(u8, change.key[0..change.key_len], key)) return change;
        }
        return null;
    }
};

fn mapLiveIndexError(err: disk_index.Error) LiveError {
    return switch (err) {
        error.Corrupt, error.DepthExceeded => error.Corrupt,
        else => error.StorageFailed,
    };
}

fn layoutBytes(configuration: Configuration, base: usize, purpose: Store.Purpose) !usize {
    return layoutBytesForIndex(configuration, base, purpose, false);
}

fn layoutBytesForIndex(configuration: Configuration, base: usize, purpose: Store.Purpose, disk: bool) !usize {
    const slot_count = if (disk) 0 else try slotCount(configuration);
    var cursor = base;
    try reserve(&cursor, @alignOf(Store), @sizeOf(Store));
    try reserveMany(&cursor, @alignOf(Slot), @sizeOf(Slot), slot_count);
    try reserveMany(&cursor, @alignOf(Change), @sizeOf(Change), configuration.maximum_checkpoint_records);
    try reserveMany(&cursor, @alignOf(u32), @sizeOf(u32), configuration.maximum_checkpoint_records);
    if (purpose == .live) try reserveMany(&cursor, @alignOf(ReadRequest), @sizeOf(ReadRequest), configuration.maximum_requests);
    if (purpose != .recovery) try reserve(&cursor, @alignOf(u8), try maximumCheckpointBytes(configuration));
    if (purpose != .recovery) try reserve(&cursor, @alignOf(u8), configuration.maximum_checkpoint_bytes);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_namespace_bytes, slot_count);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_key_bytes, slot_count);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_namespace_bytes, configuration.maximum_checkpoint_records);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_key_bytes, configuration.maximum_checkpoint_records);
    if (disk) {
        try reserve(&cursor, @alignOf(disk_index.Workspace), @sizeOf(disk_index.Workspace));
        try reserveMany(&cursor, @alignOf(u8), configuration.maximum_key_bytes, configuration.maximum_checkpoint_records);
    }
    return cursor - base;
}

fn maximumLayoutBytes(configuration: Configuration, purpose: Store.Purpose) !usize {
    const alignment = @max(@alignOf(Store), @max(@alignOf(Slot), @max(@alignOf(Change), @alignOf(ReadRequest))));
    var required: usize = 0;
    for (0..alignment) |base| required = @max(required, try layoutBytes(configuration, base, purpose));
    return required;
}

fn reserve(cursor: *usize, alignment: usize, bytes: usize) !void {
    const remainder = cursor.* % alignment;
    if (remainder != 0) cursor.* = try std.math.add(usize, cursor.*, alignment - remainder);
    cursor.* = try std.math.add(usize, cursor.*, bytes);
}

fn reserveMany(cursor: *usize, alignment: usize, item_bytes: usize, count: usize) !void {
    return reserve(cursor, alignment, try std.math.mul(usize, item_bytes, count));
}

pub fn maximumCheckpointBytes(configuration: Configuration) !usize {
    try configuration.validate();
    return maximumCheckpointBytesUnchecked(configuration);
}

pub fn guaranteedCheckpointRecords(configuration: Configuration) !usize {
    try configuration.validate();
    const record_size = record_bytes + configuration.maximum_namespace_bytes +
        configuration.maximum_key_bytes + configuration.maximum_value_bytes;
    const payload_bytes = configuration.maximum_checkpoint_bytes - header_bytes - commit_bytes;
    return @min(configuration.maximum_checkpoint_records, payload_bytes / record_size);
}

fn maximumCheckpointBytesUnchecked(configuration: Configuration) !usize {
    return configuration.maximum_checkpoint_bytes;
}

fn slotCount(configuration: Configuration) !usize {
    const doubled = std.math.mul(usize, configuration.maximum_keys, 2) catch return error.InvalidCapacity;
    return std.math.ceilPowerOfTwo(usize, doubled) catch error.InvalidCapacity;
}
fn assignSlotBuffers(a: std.mem.Allocator, slots: []Slot, c: Configuration) !void {
    const ns = try preallocated.alloc(u8, a, try std.math.mul(usize, slots.len, c.maximum_namespace_bytes));
    const keys = try preallocated.alloc(u8, a, try std.math.mul(usize, slots.len, c.maximum_key_bytes));
    for (slots, 0..) |*slot, i| slot.* = .{ .namespace = ns[i * c.maximum_namespace_bytes ..][0..c.maximum_namespace_bytes], .key = keys[i * c.maximum_key_bytes ..][0..c.maximum_key_bytes] };
}
fn assignChangeBuffers(a: std.mem.Allocator, changes: []Change, c: Configuration) !void {
    const ns = try preallocated.alloc(u8, a, try std.math.mul(usize, changes.len, c.maximum_namespace_bytes));
    const keys = try preallocated.alloc(u8, a, try std.math.mul(usize, changes.len, c.maximum_key_bytes));
    const values = ns[0..0];
    for (changes, 0..) |*change, i| change.* = .{
        .namespace = ns[i * c.maximum_namespace_bytes ..][0..c.maximum_namespace_bytes],
        .key = keys[i * c.maximum_key_bytes ..][0..c.maximum_key_bytes],
        .value = values,
    };
}
fn copyKey(ns_out: []u8, key_out: []u8, ns_len: *u16, key_len: *u16, ns: []const u8, key: []const u8) void {
    @memcpy(ns_out[0..ns.len], ns);
    @memcpy(key_out[0..key.len], key);
    ns_len.* = @intCast(ns.len);
    key_len.* = @intCast(key.len);
}
fn equal(slot: *const Slot, ns: []const u8, key: []const u8) bool {
    return slot.namespace_len == ns.len and slot.key_len == key.len and std.mem.eql(u8, slot.namespace[0..slot.namespace_len], ns) and std.mem.eql(u8, slot.key[0..slot.key_len], key);
}
fn hash(ns: []const u8, key: []const u8) u64 {
    var state = std.hash.Wyhash.init(0x4c525f7065727369);
    var lengths: [2 * @sizeOf(u64)]u8 = undefined;
    std.mem.writeInt(u64, lengths[0..8], @intCast(ns.len), .little);
    std.mem.writeInt(u64, lengths[8..16], @intCast(key.len), .little);
    state.update(&lengths);
    state.update(ns);
    state.update(key);
    return state.final();
}
fn token(index: usize, generation: u16) Request {
    return (@as(u32, generation) << 16) | @as(u16, @intCast(index));
}

test "namespace and key hashing is length delimited" {
    try std.testing.expect(hash("a", "\x00b") != hash("a\x00", "b"));
}

test "checkpoint sealing excludes later writes until the backend acknowledges the root" {
    var memory: [32 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initIndex(allocator.allocator(), .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 128,
    });
    const record: CheckpointRecord = .{ .namespace = "n", .key = "k", .operation = .{ .put = "before" } };
    try std.testing.expectEqual(Status.ready, store.stage(record));
    try std.testing.expectEqual(Status.pending, store.requestCheckpoint());
    try std.testing.expectError(error.Backpressured, store.reserve(&.{record}));
    store.markDurableInPack(1, 0);
    _ = store.complete(1);
    try std.testing.expectEqual(Status.pending, store.checkpointProgress());
    try std.testing.expect(!store.epochSwitchReady());
    try std.testing.expectError(error.Backpressured, store.reserve(&.{record}));
    store.finishCheckpoint();
    try std.testing.expectEqual(Status.ready, store.checkpointProgress());
    const reservation = try store.reserve(&.{record});
    store.cancel(reservation);
    try std.testing.expectEqual(Status.pending, store.requestCheckpoint());
    store.markFailed();
    try std.testing.expectEqual(Status.failed, store.checkpointProgress());
}

const magic: u32 = 0x4c525733;
const header_bytes = 16;
const record_bytes = 10;
const commit_bytes = 21;
const record_tag: u8 = 0xa5;
const commit_tag: u8 = 0x5a;
const Writer = struct {
    bytes: []u8,
    cursor: usize = 0,
    digest: u64 = 0,
    fn byte(self: *Writer, x: u8) !void {
        if (self.cursor == self.bytes.len) return error.JournalCapacity;
        self.bytes[self.cursor] = x;
        self.cursor += 1;
    }
    fn int(self: *Writer, comptime T: type, x: T) !void {
        const n = @sizeOf(T);
        if (self.cursor + n > self.bytes.len) return error.JournalCapacity;
        std.mem.writeInt(T, self.bytes[self.cursor..][0..n], x, .little);
        self.cursor += n;
    }
    fn bytesOf(self: *Writer, x: []const u8) !void {
        if (self.cursor + x.len > self.bytes.len) return error.JournalCapacity;
        @memcpy(self.bytes[self.cursor..][0..x.len], x);
        self.cursor += x.len;
    }
};
fn encode(store: *Store, output: []u8) !usize {
    var w: Writer = .{ .bytes = output };
    try w.int(u32, magic);
    try w.int(u64, store.generation + 1);
    try w.int(u32, @intCast(store.staged_count));
    w.digest = checksum(output[0..w.cursor]);
    for (store.changes[0..store.staged_count]) |*change| {
        const begin = w.cursor;
        try w.byte(record_tag);
        try w.byte(@intFromEnum(change.operation));
        try w.int(u16, change.namespace_len);
        try w.int(u16, change.key_len);
        try w.int(u32, change.value_len);
        try w.bytesOf(change.namespace[0..change.namespace_len]);
        try w.bytesOf(change.key[0..change.key_len]);
        if (change.operation == .put) try w.bytesOf(change.value[0..change.value_len]);
        w.digest ^= checksum(output[begin..w.cursor]);
    }
    try w.byte(commit_tag);
    try w.int(u64, store.generation + 1);
    try w.int(u32, @intCast(store.staged_count));
    try w.int(u64, w.digest);
    return w.cursor;
}
const Record = struct { operation: Operation, namespace: []const u8, key: []const u8, location: Location };
const Reader = struct {
    bytes: []const u8,
    cursor: usize,
    fn byte(self: *Reader) !u8 {
        if (self.cursor == self.bytes.len) return error.Truncated;
        const x = self.bytes[self.cursor];
        self.cursor += 1;
        return x;
    }
    fn int(self: *Reader, comptime T: type) !T {
        const n = @sizeOf(T);
        if (self.cursor + n > self.bytes.len) return error.Truncated;
        const x = std.mem.readInt(T, self.bytes[self.cursor..][0..n], .little);
        self.cursor += n;
        return x;
    }
    fn record(self: *Reader, base: LocationBase) !Record {
        if (try self.byte() != record_tag) return error.InvalidJournal;
        const operation_raw = try self.byte();
        if (operation_raw > @intFromEnum(Operation.delete)) return error.InvalidJournal;
        const operation: Operation = @enumFromInt(operation_raw);
        const ns_len = try self.int(u16);
        const key_len = try self.int(u16);
        const value_len = try self.int(u32);
        if (ns_len > self.bytes.len - self.cursor) return error.Truncated;
        const ns = self.bytes[self.cursor..][0..ns_len];
        self.cursor += ns_len;
        if (key_len > self.bytes.len - self.cursor) return error.Truncated;
        const key = self.bytes[self.cursor..][0..key_len];
        self.cursor += key_len;
        const offset: u64 = @intCast(base.offset + self.cursor);
        if (self.cursor + value_len > self.bytes.len) return error.Truncated;
        self.cursor += value_len;
        return .{ .operation = operation, .namespace = ns, .key = key, .location = .{ .pack = base.pack, .offset = offset, .length = value_len } };
    }
};
const Parsed = struct {
    bytes: []const u8,
    generation: u64,
    count: u32,
    records_start: usize,
    end: usize,
    base: LocationBase,
};
fn parse(bytes: []const u8, start: usize) !Parsed {
    var r: Reader = .{ .bytes = bytes, .cursor = start };
    if (try r.int(u32) != magic) return error.InvalidJournal;
    const generation = try r.int(u64);
    const count = try r.int(u32);
    const records_start = r.cursor;
    var digest = checksum(bytes[start..r.cursor]);
    var previous: ?Record = null;
    for (0..count) |_| {
        const begin = r.cursor;
        const record = try r.record(.{});
        if (previous) |last| {
            const namespace_order = std.mem.order(u8, last.namespace, record.namespace);
            if (namespace_order == .gt or
                (namespace_order == .eq and std.mem.order(u8, last.key, record.key) != .lt))
                return error.InvalidJournal;
        }
        previous = record;
        digest ^= checksum(bytes[begin..r.cursor]);
    }
    if (try r.byte() != commit_tag or try r.int(u64) != generation or try r.int(u32) != count or try r.int(u64) != digest) return error.InvalidJournal;
    return .{ .bytes = bytes, .generation = generation, .count = count, .records_start = records_start, .end = r.cursor, .base = .{} };
}
fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x4c525f77616c, bytes);
}

const ScanBuffer = struct {
    records: []ScanRecord,
    count: usize = 0,
    total: usize = 0,

    fn less(_: void, a: ScanRecord, b: ScanRecord) bool {
        return std.mem.lessThan(u8, a.key, b.key);
    }

    fn include(self: *ScanBuffer, record: ScanRecord) void {
        self.total += 1;
        if (self.count < self.records.len) {
            var index = self.count;
            self.count += 1;
            while (index != 0) {
                const parent = (index - 1) / 2;
                if (!less({}, self.records[parent], record)) break;
                self.records[index] = self.records[parent];
                index = parent;
            }
            self.records[index] = record;
        } else if (less({}, record, self.records[0])) {
            var index: usize = 0;
            while (index * 2 + 1 < self.count) {
                var child = index * 2 + 1;
                if (child + 1 < self.count and less({}, self.records[child], self.records[child + 1])) child += 1;
                if (!less({}, record, self.records[child])) break;
                self.records[index] = self.records[child];
                index = child;
            }
            self.records[index] = record;
        }
    }
};

fn ifaceScan(ctx: *const anyopaque, namespace: []const u8, after: []const u8, output: []ScanRecord) ScanError!ScanResult {
    return @as(*Store, @ptrCast(@alignCast(@constCast(ctx)))).scan(namespace, after, output);
}
fn ifaceReadBatch(ctx: *anyopaque, batch: ReadBatch, requests: []Request) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).readRecords(batch, requests);
}
fn ifaceLength(ctx: *const anyopaque, ns: []const u8, key: []const u8) ?usize {
    return @as(*Store, @ptrCast(@alignCast(@constCast(ctx)))).valueLength(ns, key);
}
fn ifacePoll(ctx: *anyopaque, request: Request) ReadResult {
    return @as(*Store, @ptrCast(@alignCast(ctx))).pollRead(request);
}
fn ifaceReserve(ctx: *anyopaque, batch: WriteBatch) ReserveError!WriteReservation {
    return @as(*Store, @ptrCast(@alignCast(ctx))).reserveBatch(batch);
}
fn ifacePublish(ctx: *anyopaque, reservation: WriteReservation) void {
    @as(*Store, @ptrCast(@alignCast(ctx))).publish(reservation);
}
fn ifaceCancel(ctx: *anyopaque, reservation: WriteReservation) void {
    @as(*Store, @ptrCast(@alignCast(ctx))).cancel(reservation);
}
fn ifaceFlush(ctx: *anyopaque) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).flush();
}
fn ifaceDrain(ctx: *anyopaque, io: std.Io) DrainError!void {
    return @as(*Store, @ptrCast(@alignCast(ctx))).drain(io);
}
fn ifaceRequestCheckpoint(ctx: *anyopaque) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).requestCheckpoint();
}
fn ifaceCheckpointProgress(ctx: *anyopaque) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).checkpointProgress();
}
fn ifacePoison(ctx: *anyopaque) bool {
    return @as(*Store, @ptrCast(@alignCast(ctx))).poisoned();
}
const vtable: Interface.VTable = .{
    .length = ifaceLength,
    .read_batch = ifaceReadBatch,
    .poll_read = ifacePoll,
    .scan = ifaceScan,
    .reserve = ifaceReserve,
    .publish = ifacePublish,
    .cancel = ifaceCancel,
    .flush = ifaceFlush,
    .drain = ifaceDrain,
    .request_checkpoint = ifaceRequestCheckpoint,
    .checkpoint_progress = ifaceCheckpointProgress,
    .poisoned = ifacePoison,
};

test "random transactions match an independent model before and after recovery" {
    const configuration: Configuration = .{
        .maximum_keys = 16,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 16,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 512,
    };
    var memory: [128 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), configuration, 64 * 1024);
    var recovery_memory: [32 * 1024]u8 = undefined;
    var model = [_]?u64{null} ** 16;
    var random = std.Random.DefaultPrng.init(0x6c725f73746f7265);
    for (0..128) |_| {
        var records: [8]CheckpointRecord = undefined;
        var keys: [8][1]u8 = undefined;
        var values: [8][8]u8 = undefined;
        var next = model;
        const count = random.random().uintLessThan(usize, records.len) + 1;
        for (records[0..count], 0..) |*record, index| {
            const key = random.random().uintLessThan(usize, model.len);
            keys[index][0] = @intCast(key % 8);
            const value = random.random().int(u64);
            std.mem.writeInt(u64, &values[index], value, .little);
            const deleting = random.random().boolean();
            record.* = .{
                .namespace = if (key < 8) "a" else "b",
                .key = &keys[index],
                .operation = if (deleting) .delete else .{ .put = &values[index] },
            };
            next[key] = if (deleting) null else value;
        }
        const reservation = try store.reserve(records[0..count]);
        try expectStorageModel(store, &model, store.test_storage[0..store.test_storage_len]);
        if (random.random().uintLessThan(u8, 4) == 0) {
            store.cancel(reservation);
            continue;
        }
        store.publish(reservation);
        model = next;
        try expectStorageModel(store, &model, store.test_storage[0..store.test_storage_len]);
        try std.testing.expectEqual(Status.pending, store.flush());
        const parsed = try parse(store.checkpointBytes(), 0);
        var reader = Reader{ .bytes = parsed.bytes, .cursor = parsed.records_start };
        var previous: ?Record = null;
        for (0..parsed.count) |_| {
            const record = try reader.record(.{ .pack = 0, .offset = 0 });
            if (previous) |last| {
                const namespace_order = std.mem.order(u8, last.namespace, record.namespace);
                try std.testing.expect(namespace_order == .lt or
                    (namespace_order == .eq and std.mem.order(u8, last.key, record.key) == .lt));
            }
            previous = record;
        }
        if (parsed.count > 1) {
            var boundaries = Reader{ .bytes = parsed.bytes, .cursor = parsed.records_start };
            _ = try boundaries.record(.{});
            const middle = boundaries.cursor;
            _ = try boundaries.record(.{});
            const end = boundaries.cursor;
            var reordered: [512]u8 = undefined;
            const bytes = store.checkpointBytes();
            @memcpy(reordered[0..bytes.len], bytes);
            @memcpy(reordered[parsed.records_start..][0 .. end - middle], bytes[middle..end]);
            @memcpy(reordered[parsed.records_start + end - middle ..][0 .. middle - parsed.records_start], bytes[parsed.records_start..middle]);
            try std.testing.expectError(error.InvalidJournal, parse(reordered[0..bytes.len], 0));
        }
        store.submit();
        _ = store.complete(1);
        const history = store.test_storage[0..store.test_storage_len];
        try expectStorageModel(store, &model, history);
        var recovery_allocator = std.heap.FixedBufferAllocator.init(&recovery_memory);
        const recovered = try Store.initIndex(recovery_allocator.allocator(), configuration);
        try std.testing.expectEqual(history.len, try recovered.recover(history));
        try expectStorageModel(recovered, &model, history);
    }
}

fn expectStorageModel(store: *Store, model: *const [16]?u64, history: []const u8) !void {
    var keys: [16][1]u8 = undefined;
    var destinations: [16][8]u8 = undefined;
    var reads: [16]Read = undefined;
    var requests: [16]Request = undefined;
    for (&reads, 0..) |*read, index| {
        keys[index][0] = @intCast(index % 8);
        read.* = .{ .namespace = if (index < 8) "a" else "b", .key = &keys[index], .destination = &destinations[index] };
    }
    try std.testing.expectEqual(Status.ready, store.readBatch(&reads, &requests));
    var tasks: [16]ReadTask = undefined;
    for (tasks[0..store.takeReadTasks(&tasks)]) |task|
        try store.completeRead(task.request, history[task.location.offset..][0..task.location.length]);
    for (model, requests, 0..) |expected, request, index| {
        const result = store.pollRead(request);
        if (expected) |value| {
            try std.testing.expectEqual(Status.ready, result.status);
            try std.testing.expectEqual(@as(usize, 8), result.bytes);
            try std.testing.expectEqual(value, std.mem.readInt(u64, &destinations[index], .little));
        } else try std.testing.expectEqual(Status.missing, result.status);
    }
    for ([_][]const u8{ "a", "b" }, 0..) |namespace, group| {
        var output: [8]ScanRecord = undefined;
        const scan_result = try store.scan(namespace, "", &output);
        var count: usize = 0;
        for (model[group * 8 ..][0..8], 0..) |expected, key| {
            if (expected == null) continue;
            try std.testing.expect(count < scan_result.count);
            try std.testing.expectEqualSlices(u8, &.{@intCast(key)}, output[count].key);
            try std.testing.expectEqual(@as(usize, 8), output[count].value_bytes);
            count += 1;
        }
        try std.testing.expectEqual(count, scan_result.count);
        try std.testing.expect(!scan_result.more);
    }
}

test "full index accepts atomic replacement and recovery applies only final key states" {
    const configuration: Configuration = .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 16,
        .maximum_checkpoint_bytes = 512,
    };
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), configuration, 4096);
    try std.testing.expectEqual(Status.ready, store.stage(.{ .namespace = "n", .key = "old", .operation = .{ .put = "old" } }));
    try std.testing.expectEqual(Status.pending, store.flush());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(Status.ready, store.stageBatch(&.{
        .{ .namespace = "n", .key = "new", .operation = .{ .put = "new" } },
        .{ .namespace = "n", .key = "old", .operation = .delete },
        .{ .namespace = "n", .key = "ghost", .operation = .{ .put = "unused" } },
        .{ .namespace = "n", .key = "ghost", .operation = .delete },
    }));
    try std.testing.expectEqual(Status.pending, store.flush());
    try std.testing.expectEqual(@as(u32, 3), (try parse(store.checkpointBytes(), 0)).count);
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(@as(usize, 1), store.liveRecords());
    try std.testing.expectEqual(null, store.valueLength("n", "old"));
    try std.testing.expectEqual(null, store.valueLength("n", "ghost"));
    try std.testing.expectEqual(@as(?usize, 3), store.valueLength("n", "new"));
    try std.testing.expectEqual(Status.failed, store.stage(.{ .namespace = "n", .key = "extra", .operation = .{ .put = "no" } }));
    try std.testing.expectEqual(@as(usize, 0), store.stagedRecords());
    const reopened = try Store.initIndex(fba.allocator(), configuration);
    try std.testing.expectEqual(store.test_storage_len, try reopened.recover(store.test_storage[0..store.test_storage_len]));
    try std.testing.expectEqual(@as(usize, 1), reopened.liveRecords());
    try std.testing.expectEqual(null, reopened.valueLength("n", "old"));
    try std.testing.expectEqual(null, reopened.valueLength("n", "ghost"));
    var value: [16]u8 = undefined;
    const request = reopened.read("n", "new", &value);
    var tasks: [1]ReadTask = undefined;
    try std.testing.expectEqual(@as(usize, 1), reopened.takeReadTasks(&tasks));
    const location = tasks[0].location;
    try reopened.completeRead(request, store.test_storage[location.offset..][0..location.length]);
    try std.testing.expectEqualStrings("new", value[0..reopened.pollRead(request).bytes]);
}

test "ordered scans merge published changes and paginate binary keys without duplicates" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), .{
        .maximum_keys = 8,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 1024,
    }, 4096);
    const api = store.interface();
    try std.testing.expectEqual(Status.ready, api.stageBatch(&.{
        .{ .namespace = "n", .key = "c", .operation = .{ .put = "1" } },
        .{ .namespace = "n", .key = "a", .operation = .{ .put = "1" } },
        .{ .namespace = "n", .key = "\xff", .operation = .{ .put = "1" } },
        .{ .namespace = "n", .key = "\x00", .operation = .{ .put = "1" } },
        .{ .namespace = "n/x", .key = "b", .operation = .{ .put = "1" } },
    }));
    try std.testing.expectEqual(Status.pending, api.flush());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(Status.ready, api.stageBatch(&.{
        .{ .namespace = "n", .key = "a", .operation = .delete },
        .{ .namespace = "n", .key = "b", .operation = .{ .put = "1" } },
        .{ .namespace = "n", .key = "a", .operation = .{ .put = "new" } },
        .{ .namespace = "n", .key = "c", .operation = .delete },
        .{ .namespace = "n", .key = "aa", .operation = .{ .put = "1" } },
    }));
    const hidden = try api.reserve(&.{.{ .namespace = "n", .key = "d", .operation = .{ .put = "1" } }});
    const expected = [_][]const u8{ "\x00", "a", "aa", "b", "\xff" };
    var output: [7]ScanRecord = undefined;
    for (1..output.len + 1) |batch_size| {
        var cursor: [8]u8 = undefined;
        var cursor_len: usize = 0;
        var seen: usize = 0;
        while (true) {
            const batch = try api.namespace("n").scan(cursor[0..cursor_len], output[0..batch_size]);
            try std.testing.expectEqual(@min(batch_size, expected.len - seen), batch.count);
            for (output[0..batch.count]) |entry| {
                try std.testing.expectEqualStrings(expected[seen], entry.key);
                try std.testing.expectEqual(@as(usize, if (seen == 1) 3 else 1), entry.value_bytes);
                seen += 1;
            }
            try std.testing.expectEqual(seen != expected.len, batch.more);
            if (!batch.more) break;
            const last = output[batch.count - 1].key;
            @memcpy(cursor[0..last.len], last);
            cursor_len = last.len;
        }
        try std.testing.expectEqual(expected.len, seen);
    }
    api.cancel(hidden);
    const absent = try api.scan("absent", "", &output);
    try std.testing.expectEqual(@as(usize, 0), absent.count);
    try std.testing.expect(!absent.more);
    try std.testing.expectError(error.EmptyBatch, api.scan("n", "", &.{}));
    try std.testing.expectError(error.InvalidNamespace, api.scan("", "", &output));
    store.markFailed();
    try std.testing.expectError(error.StorageFailed, api.scan("n", "", &output));
}

test "reserved writes remain invisible until publication and cancellation releases capacity" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 4,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 512,
    }, 4096);
    const api = store.interface();
    try std.testing.expectEqual(Status.ready, api.stageBatch(&.{
        .{ .namespace = "economy", .key = "alice", .operation = .{ .put = "100" } },
        .{ .namespace = "economy", .key = "bob", .operation = .{ .put = "000" } },
    }));
    try std.testing.expectEqual(Status.pending, api.flush());
    store.submit();
    _ = store.complete(1);
    var debit = [_]u8{ '0', '7', '5' };
    const balances = api.namespace("economy");
    const transfer = [_]CheckpointRecord{
        .{ .key = "alice", .operation = .{ .put = &debit } },
        .{ .key = "bob", .operation = .{ .put = "025" } },
    };
    try std.testing.expectError(error.InvalidKey, balances.reserve(&.{
        transfer[0],
        .{ .namespace = "other", .key = "bob", .operation = .{ .put = "025" } },
    }));
    try std.testing.expectEqual(@as(usize, 0), store.stagedRecords());
    try std.testing.expect(store.reservation == null);
    const canceled = try balances.reserve(&transfer);
    debit[0] = '9';
    try std.testing.expectError(error.Backpressured, balances.reserve(&transfer));
    try std.testing.expectEqual(Status.backpressured, api.flush());
    try std.testing.expect(!store.epochSwitchReady());
    var buffer: [8]u8 = undefined;
    const old = api.read("economy", "alice", &buffer);
    _ = store.complete(1);
    try std.testing.expectEqualStrings("100", buffer[0..api.pollRead(old).bytes]);
    balances.cancel(canceled);
    try std.testing.expectEqual(@as(usize, 0), store.stagedRecords());
    try std.testing.expect(store.epochSwitchReady());
    try std.testing.expectError(error.IndexCapacityExceeded, api.reserve(&.{
        .{ .namespace = "economy", .key = "third", .operation = .{ .put = "000" } },
    }));
    debit[0] = '0';
    const accepted = try balances.reserve(&transfer);
    try std.testing.expect(accepted != canceled);
    debit[0] = '9';
    balances.publish(accepted);
    const updated = api.read("economy", "alice", &buffer);
    try std.testing.expectEqualStrings("075", buffer[0..api.pollRead(updated).bytes]);
    const credited = api.read("economy", "bob", &buffer);
    try std.testing.expectEqualStrings("025", buffer[0..api.pollRead(credited).bytes]);
    try std.testing.expectEqual(Status.pending, api.flush());
    store.submit();
    _ = store.complete(1);
    const durable = api.read("economy", "alice", &buffer);
    _ = store.complete(1);
    try std.testing.expectEqualStrings("075", buffer[0..api.pollRead(durable).bytes]);
}

test "batch reads reserve together and omit IO for missing or undersized destinations" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 3,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 256,
    }, 4096);
    const api = store.interface();
    try std.testing.expectEqual(Status.ready, api.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "value" } }));
    try std.testing.expectEqual(Status.pending, api.flush());
    store.submit();
    _ = store.complete(1);
    var destination = [_]u8{0xa5} ** 8;
    var small: [1]u8 = .{0xa5};
    var absent: [1]u8 = .{0xa5};
    const namespace = api.namespace("n");
    const reads = [_]Read{
        .{ .key = "k", .destination = &destination },
        .{ .key = "k", .destination = &small },
        .{ .key = "missing", .destination = &absent },
    };
    var requests = [_]Request{no_request} ** 3;
    try std.testing.expectEqual(Status.failed, namespace.readBatch(&.{
        reads[0], reads[1], .{ .namespace = "other", .key = "missing", .destination = &absent },
    }, &requests));
    for (requests) |request| try std.testing.expectEqual(no_request, request);
    const occupied = api.read("n", "missing", &absent);
    try std.testing.expectEqual(Status.backpressured, namespace.readBatch(&reads, &requests));
    for (requests) |request| try std.testing.expectEqual(no_request, request);
    try std.testing.expectEqual(@as(u8, 0xa5), destination[0]);
    try std.testing.expectEqual(Status.missing, api.pollRead(occupied).status);
    try std.testing.expectEqual(Status.ready, namespace.readBatch(&reads, &requests));
    var tasks: [3]ReadTask = undefined;
    try std.testing.expectEqual(@as(usize, 1), store.takeReadTasks(&tasks));
    try std.testing.expectEqual(destination[0..].ptr, tasks[0].destination.ptr);
    try std.testing.expectEqual(Status.pending, api.pollRead(requests[0]).status);
    const too_small = api.pollRead(requests[1]);
    try std.testing.expectEqual(Status.too_small, too_small.status);
    try std.testing.expectEqual(@as(usize, 5), too_small.bytes);
    try std.testing.expectEqual(Status.missing, api.pollRead(requests[2]).status);
    try std.testing.expectEqual(@as(u8, 0xa5), small[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), absent[0]);
    try store.completeRead(tasks[0].request, "value");
    const result = namespace.pollRead(requests[0]);
    try std.testing.expectEqual(Status.ready, result.status);
    try std.testing.expectEqualStrings("value", destination[0..result.bytes]);
    for (requests) |request| try std.testing.expectEqual(Status.failed, api.pollRead(request).status);
    const failed_request = api.read("n", "k", &destination);
    var late_destination: [8]u8 = @splat(0xa5);
    const late_request = api.read("n", "k", &late_destination);
    try std.testing.expectEqual(@as(usize, 2), store.takeReadTasks(&tasks));
    const unsubmitted_request = api.read("n", "k", &absent);
    try std.testing.expectError(error.ShortRead, store.completeRead(failed_request, "val"));
    try std.testing.expectEqual(Status.failed, api.pollRead(failed_request).status);
    try std.testing.expectEqual(Status.failed, api.pollRead(late_request).status);
    try std.testing.expectEqual(Status.failed, api.pollRead(unsubmitted_request).status);
    try std.testing.expectEqual(@as(usize, 0), store.takeReadTasks(&tasks));
    try std.testing.expectError(error.StorageFailed, store.completeRead(late_request, "value"));
    try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0xa5))), &late_destination);
    try std.testing.expect(api.poisoned());
    try std.testing.expectEqual(Status.failed, api.flush());
    try std.testing.expectEqual(Status.failed, namespace.readBatch(&reads, &requests));
}

test "batch admission never publishes a prefix on capacity or invalid value" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initForTest(fba.allocator(), .{
        .maximum_keys = 8,
        .maximum_checkpoint_records = 3,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 192,
    }, 4096);
    const api = store.interface();
    try std.testing.expectEqual(Status.ready, api.stage(.{ .namespace = "n", .key = "old", .operation = .{ .put = "kept" } }));
    const old_bytes = store.staged_value_len;
    const large = [_]u8{42} ** 65;
    var records = [_]CheckpointRecord{
        .{ .namespace = "n", .key = "first", .operation = .{ .put = "new" } },
        .{ .namespace = "n", .key = "second", .operation = .{ .put = &large } },
    };
    try std.testing.expectEqual(Status.failed, api.stageBatch(&records));
    try std.testing.expectEqual(@as(usize, 1), store.stagedRecords());
    try std.testing.expectEqual(old_bytes, store.staged_value_len);
    try std.testing.expectEqual(null, api.length("n", "first"));
    records[0].operation = .{ .put = large[0..64] };
    records[1].operation = .{ .put = large[0..64] };
    try std.testing.expectEqual(Status.backpressured, api.stageBatch(&records));
    try std.testing.expectEqual(@as(usize, 1), store.stagedRecords());
    try std.testing.expectEqual(old_bytes, store.staged_value_len);
    records[0].operation = .{ .put = "one" };
    records[1].operation = .{ .put = "two" };
    try std.testing.expectEqual(Status.ready, api.stageBatch(&records));
    try std.testing.expectEqual(Status.backpressured, api.stageBatch(&records));
    try std.testing.expectEqual(@as(usize, 3), store.stagedRecords());
    try std.testing.expectEqual(Status.pending, api.flush());
    store.submit();
    _ = store.complete(2);
    var destination: [8]u8 = undefined;
    for ([_][]const u8{ "old", "first", "second" }, [_][]const u8{ "kept", "one", "two" }) |key, expected| {
        const request = api.read("n", key, &destination);
        _ = store.complete(1);
        const result = api.pollRead(request);
        try std.testing.expectEqual(Status.ready, result.status);
        try std.testing.expectEqualStrings(expected, destination[0..result.bytes]);
    }
}

test "cold values are not reserved for every key and tokens reject stale slots" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const c: Configuration = .{ .maximum_keys = 8, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64, .maximum_checkpoint_bytes = 256 };
    const store = try Store.initForTest(fba.allocator(), c, 4096);
    try std.testing.expect(store.slots.len * c.maximum_value_bytes > store.changes.len * c.maximum_value_bytes);
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "value" } });
    _ = store.flush();
    store.submit();
    _ = store.complete(2);
    var destination: [16]u8 = undefined;
    const first = store.read("n", "k", &destination);
    _ = store.complete(1);
    const result = store.pollRead(first);
    try std.testing.expectEqual(Status.ready, result.status);
    try std.testing.expectEqualStrings("value", destination[0..result.bytes]);
    try std.testing.expectEqual(Status.failed, store.pollRead(first).status);
}

test "delete absent does not consume capacity and complete recovery is atomic" {
    var checkpoint_bytes: [4096]u8 = undefined;
    var memory: [1 << 15]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const c: Configuration = .{ .maximum_keys = 1, .maximum_checkpoint_records = 2, .maximum_requests = 2, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64, .maximum_checkpoint_bytes = 256 };
    const store = try Store.initForTest(fba.allocator(), c, checkpoint_bytes.len);
    _ = store.stage(.{ .namespace = "n", .key = "gone", .operation = .delete });
    _ = store.flush();
    store.submit();
    _ = store.complete(2);
    _ = store.stage(.{ .namespace = "n", .key = "live", .operation = .{ .put = "yes" } });
    _ = store.flush();
    store.submit();
    _ = store.complete(2);
    @memcpy(checkpoint_bytes[0..store.test_storage_len], store.test_storage[0..store.test_storage_len]);
    var reopen_memory: [1 << 15]u8 = undefined;
    var reopen_fba = std.heap.FixedBufferAllocator.init(&reopen_memory);
    const reopened = try Store.initIndex(reopen_fba.allocator(), c);
    const recovered = try reopened.recover(checkpoint_bytes[0..store.test_storage_len]);
    try std.testing.expectEqual(store.test_storage_len, recovered);
    var output: [8]u8 = undefined;
    const request = reopened.read("n", "live", &output);
    var task: [1]ReadTask = undefined;
    try std.testing.expectEqual(@as(usize, 1), reopened.takeReadTasks(&task));
    try reopened.completeRead(task[0].request, checkpoint_bytes[task[0].location.offset..][0..task[0].location.length]);
    try std.testing.expectEqualStrings("yes", output[0..reopened.pollRead(request).bytes]);
}

test "recovery fails closed on insufficient index capacity or a corrupt committed generation" {
    var source_memory: [1 << 16]u8 = undefined;
    var source_fba = std.heap.FixedBufferAllocator.init(&source_memory);
    const wide: Configuration = .{ .maximum_keys = 2, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64, .maximum_checkpoint_bytes = 256 };
    const source = try Store.initForTest(source_fba.allocator(), wide, 4096);
    _ = source.stage(.{ .namespace = "n", .key = "one", .operation = .{ .put = "1" } });
    _ = source.stage(.{ .namespace = "n", .key = "two", .operation = .{ .put = "2" } });
    _ = source.flush();
    source.submit();
    _ = source.complete(3);
    var small_memory: [1 << 15]u8 = undefined;
    var small_fba = std.heap.FixedBufferAllocator.init(&small_memory);
    const narrow = try Store.initIndex(small_fba.allocator(), .{ .maximum_keys = 1, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64, .maximum_checkpoint_bytes = 256 });
    try std.testing.expectError(error.KeyCapacity, narrow.recover(source.test_storage[0..source.test_storage_len]));
    try std.testing.expectEqual(@as(usize, 0), narrow.liveRecords());
    var output: [8]u8 = undefined;
    const request = narrow.read("n", "one", &output);
    try std.testing.expectEqual(Status.failed, narrow.pollRead(request).status);
    try std.testing.expectError(error.StorageFailed, narrow.recover(source.test_storage[0..source.test_storage_len]));
    var corrupt_memory: [1 << 15]u8 = undefined;
    var corrupt_fba = std.heap.FixedBufferAllocator.init(&corrupt_memory);
    const corrupt = try Store.initIndex(corrupt_fba.allocator(), wide);
    source.test_storage[source.test_storage_len - 1] ^= 1;
    try std.testing.expectError(error.InvalidJournal, corrupt.recover(source.test_storage[0..source.test_storage_len]));
    try std.testing.expectEqual(@as(usize, 0), corrupt.liveRecords());
    try std.testing.expect(corrupt.poisoned());
    try std.testing.expectEqual(Status.failed, corrupt.pollRead(corrupt.read("n", "one", &output)).status);
}

test "truncated checkpoint suffix recovers exactly the preceding checkpoint" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const c: Configuration = .{ .maximum_keys = 2, .maximum_checkpoint_records = 1, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64, .maximum_checkpoint_bytes = 256 };
    const store = try Store.initForTest(fba.allocator(), c, 4096);
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "old" } });
    _ = store.flush();
    store.submit();
    _ = store.complete(2);
    const committed = store.test_storage_len;
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "new" } });
    _ = store.flush();
    store.submit();
    var reopened_memory: [1 << 16]u8 = undefined;
    var reopened_fba = std.heap.FixedBufferAllocator.init(&reopened_memory);
    const reopened = try Store.initIndex(reopened_fba.allocator(), c);
    try std.testing.expectEqual(committed, try reopened.recover(store.test_storage[0 .. committed + 3]));
    var output: [8]u8 = undefined;
    const request = reopened.read("n", "k", &output);
    var task: [1]ReadTask = undefined;
    const count = reopened.takeReadTasks(&task);
    try std.testing.expectEqual(@as(usize, 1), count);
    try reopened.completeRead(task[0].request, store.test_storage[task[0].location.offset..][0..task[0].location.length]);
    const result = reopened.pollRead(request);
    try std.testing.expectEqualStrings("old", output[0..result.bytes]);
}

test "every interrupted checkpoint recovers one complete generation, never a mixture" {
    var memory: [1 << 17]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    const configuration: Configuration = .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 2,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 256,
    };
    const source = try Store.initForTest(allocator.allocator(), configuration, 4096);
    _ = source.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = "old-left" } });
    _ = source.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = "old-right" } });
    _ = source.flush();
    source.submit();
    _ = source.complete(4);
    const earlier = source.test_storage_len;
    _ = source.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = "new-left" } });
    _ = source.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = "new-right" } });
    _ = source.flush();
    source.submit();
    const complete = source.test_storage_len;

    for (earlier..complete + 1) |prefix| {
        var reopen_memory: [1 << 17]u8 = undefined;
        var reopen_allocator = std.heap.FixedBufferAllocator.init(&reopen_memory);
        const reopened = try Store.initIndex(reopen_allocator.allocator(), configuration);
        const recovered = try reopened.recover(source.test_storage[0..prefix]);
        const expected_new = prefix == complete;
        try std.testing.expectEqual(if (expected_new) complete else earlier, recovered);

        var left: [64]u8 = undefined;
        var right: [64]u8 = undefined;
        const left_request = reopened.read("n", "left", &left);
        const right_request = reopened.read("n", "right", &right);
        var tasks: [2]ReadTask = undefined;
        try std.testing.expectEqual(@as(usize, 2), reopened.takeReadTasks(&tasks));
        for (tasks) |task| {
            const start: usize = @intCast(task.location.offset);
            const end = start + task.location.length;
            try reopened.completeRead(task.request, source.test_storage[start..end]);
        }
        const left_result = reopened.pollRead(left_request);
        const right_result = reopened.pollRead(right_request);
        const left_expected = if (expected_new) "new-left" else "old-left";
        const right_expected = if (expected_new) "new-right" else "old-right";
        try std.testing.expectEqualStrings(left_expected, left[0..left_result.bytes]);
        try std.testing.expectEqualStrings(right_expected, right[0..right_result.bytes]);
    }
}

test "startup loader is explicitly separate from runtime requests" {
    const Stub = struct {
        fn read(raw: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) LoadError!LoadResult {
            const calls: *u8 = @ptrCast(@alignCast(raw));
            calls.* += 1;
            if (!std.mem.eql(u8, namespace, "plugin") or !std.mem.eql(u8, key, "state")) return .missing;
            if (destination.len < 2) return error.DestinationTooSmall;
            @memcpy(destination[0..2], "ok");
            return .{ .value = 2 };
        }
    };
    var context: u8 = 0;
    const loader = Loader{ .context = &context, .read_fn = Stub.read };
    var output: [2]u8 = undefined;
    const result = try loader.read("plugin", "state", &output);
    try std.testing.expectEqualStrings("ok", output[0..result.value]);
    try std.testing.expectError(error.InvalidKey, loader.read("", "state", &output));
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initIndex(fixed.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 4,
        .maximum_checkpoint_bytes = 128,
    });
    const access = Access.init(.{ .interface = store.interface(), .loader = loader, .maximum_checkpoint_records = 1 });
    const scoped = access.plugin("plugin");
    try std.testing.expectEqual(LoadResult{ .value = 2 }, try scoped.load("state", &output));
    const calls_before_failure = context;
    store.markFailed();
    try std.testing.expectError(error.ReadFailed, scoped.load("absent", &output));
    try std.testing.expectError(error.ReadFailed, scoped.load("state", &output));
    try std.testing.expectEqual(calls_before_failure, context);
}

test "runtime byte keys reject empty namespace and key" {
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try Store.initIndex(fixed.allocator(), .{
        .maximum_keys = 2,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 128,
    });
    try std.testing.expectEqual(no_request, store.read("", "key", &.{}));
    try std.testing.expectEqual(no_request, store.read("namespace", "", &.{}));
    try std.testing.expectEqual(Status.backpressured, store.stage(.{
        .namespace = "",
        .key = "key",
        .operation = .{ .put = "value" },
    }));
}

test "index reservation bounds every Store allocation" {
    const configuration: Configuration = .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 2,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 256,
    };
    const reserved = comptime Store.maximumIndexBytes(configuration) catch unreachable;
    var storage: [reserved]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    _ = try Store.initIndex(fixed.allocator(), configuration);
    try std.testing.expect(fixed.end_index <= reserved);
    var larger = configuration;
    larger.maximum_keys = 65_536;
    try larger.validate();
    try std.testing.expectEqual(@as(usize, 131_072), try slotCount(larger));
    try std.testing.expect(try Store.maximumIndexBytes(larger) > reserved);

    const fields = .{ "maximum_namespace_bytes", "maximum_key_bytes", "maximum_requests" };
    inline for (fields) |field| {
        var invalid = configuration;
        @field(invalid, field) = 65_536;
        invalid.maximum_checkpoint_bytes = 1024 * 1024;
        const before = fixed.end_index;
        try std.testing.expectError(error.InvalidCapacity, Store.initIndex(fixed.allocator(), invalid));
        try std.testing.expectEqual(before, fixed.end_index);
    }
    if (comptime @bitSizeOf(usize) > 32) {
        inline for (.{ "maximum_value_bytes", "maximum_checkpoint_records" }) |field| {
            var invalid = configuration;
            @field(invalid, field) = @as(usize, std.math.maxInt(u32)) + 1;
            invalid.maximum_checkpoint_bytes = @as(usize, std.math.maxInt(u32)) + 4096;
            try std.testing.expectError(error.InvalidCapacity, invalid.validate());
        }
    }
    larger.maximum_keys = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidCapacity, larger.validate());
}

test "bounded batches publish and read more than u16 keys without runtime allocation" {
    const configuration: Configuration = .{
        .maximum_keys = 65_536,
        .maximum_checkpoint_records = 256,
        .maximum_requests = 3,
        .maximum_namespace_bytes = 1,
        .maximum_key_bytes = 4,
        .maximum_value_bytes = 4,
        .maximum_checkpoint_bytes = 8192,
    };
    const capacity = try Store.testReservation(configuration, 2 * 1024 * 1024);
    const memory = try std.testing.allocator.alloc(u8, capacity.totalBytes());
    defer std.testing.allocator.free(memory);
    var fixed = std.heap.FixedBufferAllocator.init(memory);
    const store = try Store.initForTest(fixed.allocator(), configuration, capacity.test_storage_bytes);
    const allocated = fixed.end_index;
    var keys: [256][4]u8 = undefined;
    var writes: [256]CheckpointRecord = undefined;
    for (0..256) |batch| {
        for (&keys, &writes, 0..) |*key, *write, index| {
            std.mem.writeInt(u32, key, @intCast(batch * keys.len + index), .little);
            write.* = .{ .namespace = "n", .key = key, .operation = .{ .put = key } };
        }
        const reserved = try store.reserve(&writes);
        store.publish(reserved);
        try std.testing.expectEqual(Status.pending, store.flush());
        store.submit();
        try std.testing.expectEqual(@as(usize, 1), store.complete(1));
        try std.testing.expect(!store.poisoned());
    }
    try std.testing.expectEqual(configuration.maximum_keys, store.live_count);
    try std.testing.expectEqual(store.test_storage_len, try store.recover(store.test_storage[0..store.test_storage_len]));
    try std.testing.expectEqual(configuration.maximum_keys, store.live_count);
    const samples = [_]u32{ 0, 32_767, 65_535 };
    var destinations: [samples.len][4]u8 = undefined;
    var reads: [samples.len]Read = undefined;
    var requests: [samples.len]Request = undefined;
    for (samples, &reads, &destinations, 0..) |value, *read, *destination, index| {
        std.mem.writeInt(u32, &keys[index], value, .little);
        read.* = .{ .namespace = "n", .key = &keys[index], .destination = destination };
    }
    try std.testing.expectEqual(Status.ready, store.readBatch(&reads, &requests));
    try std.testing.expectEqual(samples.len, store.complete(samples.len));
    for (requests, &destinations, samples) |request, *destination, value| {
        try std.testing.expectEqual(Status.ready, store.pollRead(request).status);
        try std.testing.expectEqual(value, std.mem.readInt(u32, destination, .little));
    }
    try std.testing.expectEqual(allocated, fixed.end_index);
}

test "test storage capacity admits one complete maximum checkpoint" {
    const configuration: Configuration = .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
        .maximum_checkpoint_bytes = 256,
    };
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    try std.testing.expectError(error.InvalidCapacity, Store.initForTest(fixed.allocator(), configuration, 1));
}
