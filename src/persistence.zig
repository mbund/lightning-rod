const std = @import("std");
const preallocated = @import("preallocated");

pub const Status = enum(u8) { ready, pending, missing, too_small, backpressured, failed };
pub const Operation = enum(u8) { put, delete };
pub const Request = u32;
pub const no_request = std.math.maxInt(Request);

pub const Configuration = struct {
    maximum_keys: usize,
    maximum_checkpoint_records: usize,
    maximum_requests: usize,
    maximum_namespace_bytes: usize,
    maximum_key_bytes: usize,
    maximum_value_bytes: usize,

    pub fn validate(self: Configuration) !void {
        if (self.maximum_keys == 0 or self.maximum_checkpoint_records == 0 or self.maximum_requests == 0)
            return error.InvalidCapacity;
        if (self.maximum_keys > std.math.maxInt(u16) or self.maximum_requests > std.math.maxInt(u16))
            return error.InvalidCapacity;
        if (self.maximum_namespace_bytes == 0 or self.maximum_key_bytes == 0 or self.maximum_value_bytes == 0)
            return error.InvalidCapacity;
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
pub const Location = struct {
    pack: u32 = 0,
    offset: u64,
    length: u32,
};
const LocationBase = struct { pack: u32 = 0, offset: usize = 0 };
pub const LiveRecord = struct {
    namespace: []const u8,
    key: []const u8,
    location: Location,
};
pub const ReadTask = struct { request: Request, location: Location, destination: []u8 };
pub const CheckpointRecord = struct {
    namespace: []const u8,
    key: []const u8,
    operation: union(Operation) { put: []const u8, delete: void },
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
        read: *const fn (*anyopaque, []const u8, []const u8, []u8) Request,
        poll_read: *const fn (*anyopaque, Request) ReadResult,
        stage: *const fn (*anyopaque, CheckpointRecord) Status,
        begin_checkpoint: *const fn (*anyopaque) Status,
        checkpoint_progress: *const fn (*anyopaque) Status,
        poisoned: *const fn (*anyopaque) bool,
    };
    pub inline fn read(self: Interface, ns: []const u8, key: []const u8, destination: []u8) Request {
        return self.vtable.read(self.context, ns, key, destination);
    }
    pub inline fn pollRead(self: Interface, request: Request) ReadResult {
        return self.vtable.poll_read(self.context, request);
    }
    pub inline fn stage(self: Interface, record: CheckpointRecord) Status {
        return self.vtable.stage(self.context, record);
    }
    pub inline fn beginCheckpoint(self: Interface) Status {
        return self.vtable.begin_checkpoint(self.context);
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
    pub inline fn read(self: Namespace, key: []const u8, destination: []u8) Request {
        return self.persistence.read(self.value, key, destination);
    }
    pub inline fn stagePut(self: Namespace, key: []const u8, value: []const u8) Status {
        return self.persistence.stage(.{ .namespace = self.value, .key = key, .operation = .{ .put = value } });
    }
    pub inline fn stageDelete(self: Namespace, key: []const u8) Status {
        return self.persistence.stage(.{ .namespace = self.value, .key = key, .operation = .delete });
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

    pub fn beginCheckpoint(self: PluginAccess) Status {
        return self.access.interface.beginCheckpoint();
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
    configuration: Configuration,
    slots: []Slot,
    changes: []Change,
    requests: []ReadRequest,
    test_storage: []u8 = &.{},
    test_storage_len: usize = 0,
    encoded: []u8 = &.{},
    encoded_len: usize = 0,
    commit_offset: u64 = 0,
    commit_pack: u32 = 0,
    staged_count: usize = 0,
    generation: u64 = 0,
    live_count: usize = 0,
    commit: CommitState = .idle,
    poisoned_storage: bool = false,
    checkpoint_gate_context: ?*anyopaque = null,
    checkpoint_gate: ?*const fn (*anyopaque) bool = null,
    read_gate_context: ?*anyopaque = null,
    read_gate: ?*const fn (*anyopaque) bool = null,

    pub fn initForTest(allocator: std.mem.Allocator, configuration: Configuration, storage_capacity: usize) !*Store {
        if (storage_capacity < try maximumCheckpointBytes(configuration)) return error.InvalidCapacity;
        const self = try init(allocator, configuration);
        self.test_storage = try preallocated.alloc(u8, allocator, storage_capacity);
        return self;
    }

    pub fn initIndex(allocator: std.mem.Allocator, configuration: Configuration) !*Store {
        return init(allocator, configuration);
    }

    pub fn indexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return layoutBytes(configuration, 0);
    }

    pub fn maximumIndexBytes(configuration: Configuration) !usize {
        try configuration.validate();
        return maximumLayoutBytes(configuration);
    }

    pub fn testReservation(configuration: Configuration, storage_capacity: usize) !Reservation {
        if (storage_capacity < try maximumCheckpointBytes(configuration)) return error.InvalidCapacity;
        try configuration.validate();
        return .{
            .index_bytes = try maximumLayoutBytes(configuration),
            .test_storage_bytes = storage_capacity,
        };
    }

    fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Store {
        try configuration.validate();
        const self = try preallocated.create(Store, allocator);
        const slot_count = try slotCount(configuration);
        self.* = .{
            .configuration = configuration,
            .slots = try preallocated.alloc(Slot, allocator, slot_count),
            .changes = try preallocated.alloc(Change, allocator, configuration.maximum_checkpoint_records),
            .requests = try preallocated.alloc(ReadRequest, allocator, configuration.maximum_requests),
            .encoded = try preallocated.alloc(u8, allocator, try maximumCheckpointBytes(configuration)),
        };
        @memset(self.slots, .{});
        @memset(self.changes, .{});
        @memset(self.requests, .{});
        try assignSlotBuffers(allocator, self.slots, configuration);
        try assignChangeBuffers(allocator, self.changes, configuration);
        return self;
    }

    pub fn interface(self: *Store) Interface {
        return .{ .context = self, .vtable = &vtable };
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
        std.mem.swap([]Slot, &self.slots, &compacted.slots);
        self.generation = compacted.generation;
        self.live_count = compacted.live_count;
        compacted.clearIndex();
    }
    pub fn poisoned(self: *const Store) bool {
        return self.poisoned_storage;
    }

    pub fn startupLocation(self: *const Store, namespace: []const u8, key: []const u8) ?Location {
        if (!self.validKey(namespace, key)) return null;
        const index = self.lookup(namespace, key) orelse return null;
        return self.slots[index].location;
    }

    pub fn epochSwitchReady(self: *const Store) bool {
        if (self.commit != .idle and self.commit != .staged) return false;
        for (self.requests) |request| if (request.state != .free) return false;
        return true;
    }
    pub fn nextLive(self: *const Store, cursor: *usize) ?LiveRecord {
        while (cursor.* < self.slots.len) : (cursor.* += 1) {
            const slot = &self.slots[cursor.*];
            if (slot.state != .live) continue;
            cursor.* += 1;
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
        if (self.poisoned_storage or !self.validKey(namespace, key)) return no_request;
        if (self.read_gate) |gate| {
            if (!gate(self.read_gate_context.?)) return no_request;
        }
        const slot = self.lookup(namespace, key) orelse return self.finishedMissingRequest(destination);
        const index = self.freeRequest() orelse return no_request;
        const read_state = &self.requests[index];
        read_state.state = .pending;
        read_state.location = self.slots[slot].location;
        read_state.destination = destination;
        read_state.result = .{ .status = .pending };
        return token(index, read_state.generation);
    }

    pub fn pollRead(self: *Store, request_token: Request) ReadResult {
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
        if (self.poisoned_storage) return .failed;
        if (self.commit == .encoded or self.commit == .durable) return .backpressured;
        if (!self.validKey(record.namespace, record.key) or self.staged_count == self.changes.len) return .backpressured;
        const change = &self.changes[self.staged_count];
        const value = switch (record.operation) {
            .put => |bytes| bytes,
            .delete => &.{},
        };
        if (value.len > change.value.len) return .failed;
        change.operation = record.operation;
        copyKey(change.namespace, change.key, &change.namespace_len, &change.key_len, record.namespace, record.key);
        change.value_len = @intCast(value.len);
        @memcpy(change.value[0..value.len], value);
        self.staged_count += 1;
        self.commit = .staged;
        return .ready;
    }

    pub fn beginCheckpoint(self: *Store) Status {
        if (self.poisoned_storage) return .failed;
        if (self.checkpoint_gate) |gate| {
            if (!gate(self.checkpoint_gate_context.?)) return .backpressured;
        }
        switch (self.commit) {
            .idle => return .ready,
            .encoded, .durable => return .backpressured,
            .failed => return .failed,
            .staged => {},
        }
        self.preflight() catch {
            self.markFailed();
            return .failed;
        };
        self.encoded_len = encode(self, self.encoded) catch {
            self.markFailed();
            return .failed;
        };
        self.commit = .encoded;
        return .pending;
    }

    pub fn checkpointBytes(self: *const Store) []const u8 {
        if (self.commit != .encoded) return &.{};
        return self.encoded[0..self.encoded_len];
    }

    pub fn checkpointProgress(self: *const Store) Status {
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
        return count;
    }

    pub fn takeReadTasks(self: *Store, output: []ReadTask) usize {
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
        const length: usize = read_state.location.length;
        if (source.len < length) {
            read_state.result = .{ .status = .failed };
            read_state.state = .done;
            return;
        }
        if (read_state.destination.len < length) {
            read_state.result = .{ .status = .too_small, .bytes = length };
            read_state.state = .done;
            return;
        }
        const destination = read_state.destination[0..length];
        const input = source[0..length];
        if (@intFromPtr(destination.ptr) != @intFromPtr(input.ptr)) @memcpy(destination, input);
        read_state.result = .{ .status = .ready, .bytes = length };
        read_state.state = .done;
    }

    pub fn recover(self: *Store, bytes: []const u8) !usize {
        self.beginRecovery();
        var cursor: usize = 0;
        while (cursor < bytes.len) {
            const consumed = self.recoverOne(bytes[cursor..], cursor) catch break;
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
        const base: usize = @intCast(self.commit_offset);
        var reader = Reader{ .bytes = self.encoded[0..self.encoded_len], .cursor = header_bytes };
        for (0..self.staged_count) |change_index| {
            const change = &self.changes[change_index];
            const location = try reader.skipRecord(.{ .pack = self.commit_pack, .offset = base });
            try self.apply(change.operation, change.namespace[0..change.namespace_len], change.key[0..change.key_len], location);
        }
        self.generation += 1;
        self.staged_count = 0;
        self.commit = .idle;
    }

    fn preflight(self: *Store) !void {
        var projected = self.live_count;
        for (self.changes[0..self.staged_count], 0..) |*change, index| {
            const was_live = self.projectedLive(index, change.namespace[0..change.namespace_len], change.key[0..change.key_len]);
            switch (change.operation) {
                .put => {
                    if (!was_live) projected += 1;
                },
                .delete => {
                    if (was_live) projected -= 1;
                },
            }
            if (projected > self.configuration.maximum_keys) return error.KeyCapacity;
            if (change.operation == .put and self.lookupOrVacancy(change.namespace[0..change.namespace_len], change.key[0..change.key_len]) == null) return error.KeyCapacity;
        }
    }

    fn apply(self: *Store, operation: Operation, namespace: []const u8, key: []const u8, location: Location) !void {
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
        var reader = Reader{ .bytes = parsed.bytes, .cursor = parsed.records_start };
        for (0..parsed.count) |_| {
            const record = try reader.record(parsed.base);
            try self.apply(record.operation, record.namespace, record.key, record.location);
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
        self.staged_count = parsed.count;
        self.preflight() catch |err| {
            self.staged_count = 0;
            return err;
        };
        self.staged_count = 0;
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
    fn freeRequest(self: *Store) ?usize {
        for (self.requests, 0..) |read_state, index| if (read_state.state == .free) return index;
        return null;
    }
    fn finishedMissingRequest(self: *Store, destination: []u8) Request {
        const index = self.freeRequest() orelse return no_request;
        const read_state = &self.requests[index];
        read_state.state = .done;
        read_state.destination = destination;
        read_state.result = .{ .status = .missing };
        return token(index, read_state.generation);
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
    }

    fn projectedLive(self: *const Store, before: usize, namespace: []const u8, key: []const u8) bool {
        var index = before;
        while (index != 0) {
            index -= 1;
            const change = &self.changes[index];
            if (change.namespace_len == namespace.len and change.key_len == key.len and std.mem.eql(u8, change.namespace[0..change.namespace_len], namespace) and std.mem.eql(u8, change.key[0..change.key_len], key)) return change.operation == .put;
        }
        return self.lookup(namespace, key) != null;
    }
};

fn layoutBytes(configuration: Configuration, base: usize) !usize {
    const slot_count = try slotCount(configuration);
    var cursor = base;
    try reserve(&cursor, @alignOf(Store), @sizeOf(Store));
    try reserveMany(&cursor, @alignOf(Slot), @sizeOf(Slot), slot_count);
    try reserveMany(&cursor, @alignOf(Change), @sizeOf(Change), configuration.maximum_checkpoint_records);
    try reserveMany(&cursor, @alignOf(ReadRequest), @sizeOf(ReadRequest), configuration.maximum_requests);
    try reserve(&cursor, @alignOf(u8), try maximumCheckpointBytes(configuration));
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_namespace_bytes, slot_count);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_key_bytes, slot_count);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_namespace_bytes, configuration.maximum_checkpoint_records);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_key_bytes, configuration.maximum_checkpoint_records);
    try reserveMany(&cursor, @alignOf(u8), configuration.maximum_value_bytes, configuration.maximum_checkpoint_records);
    return cursor - base;
}

fn maximumLayoutBytes(configuration: Configuration) !usize {
    const alignment = @max(@alignOf(Store), @max(@alignOf(Slot), @max(@alignOf(Change), @alignOf(ReadRequest))));
    var required: usize = 0;
    for (0..alignment) |base| required = @max(required, try layoutBytes(configuration, base));
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

fn maximumCheckpointBytesUnchecked(configuration: Configuration) !usize {
    var record_size = try std.math.add(usize, record_bytes, configuration.maximum_namespace_bytes);
    record_size = try std.math.add(usize, record_size, configuration.maximum_key_bytes);
    record_size = try std.math.add(usize, record_size, configuration.maximum_value_bytes);
    const records = try std.math.mul(usize, configuration.maximum_checkpoint_records, record_size);
    return try std.math.add(usize, header_bytes + commit_bytes, records);
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
    const values = try preallocated.alloc(u8, a, try std.math.mul(usize, changes.len, c.maximum_value_bytes));
    for (changes, 0..) |*change, i| change.* = .{ .namespace = ns[i * c.maximum_namespace_bytes ..][0..c.maximum_namespace_bytes], .key = keys[i * c.maximum_key_bytes ..][0..c.maximum_key_bytes], .value = values[i * c.maximum_value_bytes ..][0..c.maximum_value_bytes] };
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

const magic: u32 = 0x4c525732;
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
    fn skipRecord(self: *Reader, base: LocationBase) !Location {
        return (try self.record(base)).location;
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
    for (0..count) |_| {
        const begin = r.cursor;
        _ = try r.record(.{});
        digest ^= checksum(bytes[begin..r.cursor]);
    }
    if (try r.byte() != commit_tag or try r.int(u64) != generation or try r.int(u32) != count or try r.int(u64) != digest) return error.InvalidJournal;
    return .{ .bytes = bytes, .generation = generation, .count = count, .records_start = records_start, .end = r.cursor, .base = .{} };
}
fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x4c525f77616c, bytes);
}

fn ifaceRead(ctx: *anyopaque, ns: []const u8, key: []const u8, dst: []u8) Request {
    return @as(*Store, @ptrCast(@alignCast(ctx))).read(ns, key, dst);
}
fn ifacePoll(ctx: *anyopaque, request: Request) ReadResult {
    return @as(*Store, @ptrCast(@alignCast(ctx))).pollRead(request);
}
fn ifaceStage(ctx: *anyopaque, record: CheckpointRecord) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).stage(record);
}
fn ifaceBegin(ctx: *anyopaque) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).beginCheckpoint();
}
fn ifaceCheckpointProgress(ctx: *anyopaque) Status {
    return @as(*Store, @ptrCast(@alignCast(ctx))).checkpointProgress();
}
fn ifacePoison(ctx: *anyopaque) bool {
    return @as(*Store, @ptrCast(@alignCast(ctx))).poisoned();
}
const vtable: Interface.VTable = .{
    .read = ifaceRead,
    .poll_read = ifacePoll,
    .stage = ifaceStage,
    .begin_checkpoint = ifaceBegin,
    .checkpoint_progress = ifaceCheckpointProgress,
    .poisoned = ifacePoison,
};

test "cold values are not reserved for every key and tokens reject stale slots" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const c: Configuration = .{ .maximum_keys = 8, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64 };
    const store = try Store.initForTest(fba.allocator(), c, 4096);
    try std.testing.expect(store.slots.len * c.maximum_value_bytes > store.changes.len * c.maximum_value_bytes);
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "value" } });
    _ = store.beginCheckpoint();
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
    const c: Configuration = .{ .maximum_keys = 1, .maximum_checkpoint_records = 2, .maximum_requests = 2, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64 };
    const store = try Store.initForTest(fba.allocator(), c, checkpoint_bytes.len);
    _ = store.stage(.{ .namespace = "n", .key = "gone", .operation = .delete });
    _ = store.beginCheckpoint();
    store.submit();
    _ = store.complete(2);
    _ = store.stage(.{ .namespace = "n", .key = "live", .operation = .{ .put = "yes" } });
    _ = store.beginCheckpoint();
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

test "smaller reopened index rejects a whole committed generation" {
    var source_memory: [1 << 16]u8 = undefined;
    var source_fba = std.heap.FixedBufferAllocator.init(&source_memory);
    const wide: Configuration = .{ .maximum_keys = 2, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64 };
    const source = try Store.initForTest(source_fba.allocator(), wide, 4096);
    _ = source.stage(.{ .namespace = "n", .key = "one", .operation = .{ .put = "1" } });
    _ = source.stage(.{ .namespace = "n", .key = "two", .operation = .{ .put = "2" } });
    _ = source.beginCheckpoint();
    source.submit();
    _ = source.complete(3);
    var small_memory: [1 << 15]u8 = undefined;
    var small_fba = std.heap.FixedBufferAllocator.init(&small_memory);
    const narrow = try Store.initIndex(small_fba.allocator(), .{ .maximum_keys = 1, .maximum_checkpoint_records = 2, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64 });
    try std.testing.expectEqual(@as(usize, 0), try narrow.recover(source.test_storage[0..source.test_storage_len]));
    var output: [8]u8 = undefined;
    const request = narrow.read("n", "one", &output);
    try std.testing.expectEqual(Status.missing, narrow.pollRead(request).status);
}

test "truncated checkpoint suffix recovers exactly the preceding checkpoint" {
    var memory: [1 << 16]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    const c: Configuration = .{ .maximum_keys = 2, .maximum_checkpoint_records = 1, .maximum_requests = 1, .maximum_namespace_bytes = 8, .maximum_key_bytes = 8, .maximum_value_bytes = 64 };
    const store = try Store.initForTest(fba.allocator(), c, 4096);
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "old" } });
    _ = store.beginCheckpoint();
    store.submit();
    _ = store.complete(2);
    const committed = store.test_storage_len;
    _ = store.stage(.{ .namespace = "n", .key = "k", .operation = .{ .put = "new" } });
    _ = store.beginCheckpoint();
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
    };
    const source = try Store.initForTest(allocator.allocator(), configuration, 4096);
    _ = source.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = "old-left" } });
    _ = source.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = "old-right" } });
    _ = source.beginCheckpoint();
    source.submit();
    _ = source.complete(4);
    const earlier = source.test_storage_len;
    _ = source.stage(.{ .namespace = "n", .key = "left", .operation = .{ .put = "new-left" } });
    _ = source.stage(.{ .namespace = "n", .key = "right", .operation = .{ .put = "new-right" } });
    _ = source.beginCheckpoint();
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
        fn read(_: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) LoadError!LoadResult {
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
    };
    const reserved = comptime Store.maximumIndexBytes(configuration) catch unreachable;
    var storage: [reserved]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    _ = try Store.initIndex(fixed.allocator(), configuration);
    try std.testing.expect(fixed.end_index <= reserved);
}

test "test storage capacity admits one complete maximum checkpoint" {
    const configuration: Configuration = .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 8,
        .maximum_key_bytes = 8,
        .maximum_value_bytes = 64,
    };
    var memory: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    try std.testing.expectError(error.InvalidCapacity, Store.initForTest(fixed.allocator(), configuration, 1));
}
