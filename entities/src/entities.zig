const metrics = @import("metrics");
const std = @import("std");
const storage = @import("storage");
const records = @import("records");

const assert = std.debug.assert;

pub const Id = u64;

pub const State = struct {
    uuid: u128,
    kind: u32,
    world: u32,
    position: [3]f64,
    velocity: [3]f64 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    flags: u8 = 0,
};

pub const Entities = struct {
    pub const id = "lightning_rod:entities";

    pub const Configuration = struct {
        cache_records: usize = 256,
    };

    pub const Dependencies = struct {
        record_workspaces: *records.Workspaces,
        metrics: *metrics.Registry,
        storage: storage.Space,
    };

    deps: Dependencies,
    cache: records.Cache,
    next_id: Id,
    checkpointed_id: Id,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Entities {
        const self = try allocate(allocator, io, configuration, deps);
        const table_resources = deps.record_workspaces.resources;
        var sequence: [8]u8 = undefined;
        const length = try records.Table.init(deps.storage, table_resources).get(&.{0}, &sequence);
        if (length != null and length.? != sequence.len)
            return error.Corrupt;

        const next_id = if (length != null) std.mem.readInt(Id, &sequence, .little) else 1;
        if (next_id == 0)
            return error.Corrupt;

        self.next_id = next_id;
        self.checkpointed_id = next_id;
        return self;
    }

    pub fn allocate(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Entities {
        const table_resources = deps.record_workspaces.resources;
        const self = try allocator.create(Entities);
        self.* = .{
            .deps = deps,
            .cache = try records.Cache.init(allocator, io, records.Table.init(deps.storage, table_resources), .{
                .metrics = deps.metrics,
                .metrics_namespace = "entities.cache",
                .slots = configuration.cache_records,
                .key_bytes = 9,
                .value_bytes = encoded_bytes,
                .scan_batch = 16,
            }),
            .next_id = 1,
            .checkpointed_id = 1,
        };
        return self;
    }

    /// Reserves a contiguous ID range without creating persistent entity records.
    pub fn reserveIds(self: *Entities, count: usize) !Id {
        if (count > std.math.maxInt(Id) - self.next_id) return error.IdExhausted;
        const first = self.next_id;
        self.next_id += count;
        return first;
    }

    pub fn create(self: *Entities, state: State) !Id {
        var output: [1]Id = undefined;
        try self.createMany(&.{state}, &output);
        return output[0];
    }

    pub fn createMany(self: *Entities, states: []const State, output: []Id) !void {
        if (states.len != output.len or states.len > 128 or states.len > self.cache.entries.len) return error.WorkingSetTooLarge;
        if (states.len > std.math.maxInt(Id) - self.next_id) return error.IdExhausted;
        for (states) |state| if (!valid(state)) return error.InvalidEntity;
        var keys: [128][9]u8 = undefined;
        var slices: [128][]const u8 = undefined;
        var leases: [128]records.Cache.Lease = undefined;
        for (states, 0..) |_, index| {
            keys[index] = encodeKey(self.next_id + index);
            slices[index] = &keys[index];
        }
        try self.cache.acquireMany(slices[0..states.len], leases[0..states.len]);
        defer for (leases[0..states.len]) |lease| lease.release();
        for (leases[0..states.len]) |lease| if (lease.read() != null) return error.Corrupt;
        for (states, output, leases[0..states.len], 0..) |state, *entity, lease, index| {
            encode(state, lease.edit());
            lease.commit(encoded_bytes);
            entity.* = self.next_id + index;
            assert(entity.* != 0);
        }
        self.next_id += states.len;
    }

    pub const Lease = struct {
        record: records.Cache.Lease,

        pub fn read(self: Lease) !?State {
            return if (self.record.read()) |bytes| try decode(bytes) else null;
        }

        pub fn write(self: Lease, state: State) !void {
            if (!valid(state)) return error.InvalidEntity;
            if (self.record.read() == null) return error.UnknownEntity;
            encode(state, self.record.edit());
            self.record.commit(encoded_bytes);
        }

        pub fn release(self: Lease) void {
            self.record.release();
        }
    };

    pub fn acquireMany(self: *Entities, ids: []const Id, output: []Lease) !void {
        return self.acquireBatch(128, ids, output);
    }

    fn acquireBatch(self: *Entities, comptime capacity: usize, ids: []const Id, output: []Lease) !void {
        if (ids.len != output.len or ids.len > capacity) return error.WorkingSetTooLarge;
        var keys: [capacity][9]u8 = undefined;
        var slices: [capacity][]const u8 = undefined;
        var leases: [capacity]records.Cache.Lease = undefined;
        for (ids, 0..) |entity, i| {
            if (entity == 0) return error.InvalidEntity;
            keys[i] = encodeKey(entity);
            slices[i] = &keys[i];
        }
        try self.cache.acquireMany(slices[0..ids.len], leases[0..ids.len]);
        for (output, leases[0..ids.len]) |*lease, record| lease.* = .{ .record = record };
    }

    pub fn get(self: *Entities, entity: Id) !?State {
        var leases: [1]Lease = undefined;
        try self.acquireBatch(1, &.{entity}, &leases);
        defer leases[0].release();
        return leases[0].read();
    }

    pub fn put(self: *Entities, entity: Id, state: State) !void {
        var leases: [1]Lease = undefined;
        try self.acquireBatch(1, &.{entity}, &leases);
        defer leases[0].release();
        try leases[0].write(state);
    }

    pub fn remove(self: *Entities, entity: Id) !void {
        var leases: [1]Lease = undefined;
        try self.acquireBatch(1, &.{entity}, &leases);
        defer leases[0].release();
        if (leases[0].record.read() == null) return error.UnknownEntity;
        leases[0].record.remove();
    }

    /// Ordered by stable entity ID. Storage may be read synchronously in bounded batches. The
    /// returned values belong to this cursor.
    pub fn scan(self: *Entities, cursor: *Cursor) ![]const Row {
        var entries: [16]records.BorrowedEntry = undefined;

        var position: records.ScanCursor = .{
            .after = &cursor.after,
            .after_len = cursor.after_len,
        };
        const batch = try self.cache.scanBorrowed(&position, &entries);
        cursor.after_len = position.after_len;
        cursor.more = batch.more;
        var count: usize = 0;

        for (entries[0..batch.count]) |entry| {
            if (entry.key.len == 1 and entry.key[0] == 0)
                continue;

            if (entry.key.len != 9 or entry.key[0] != 1)
                return error.Corrupt;

            cursor.rows[count] = .{
                .id = std.mem.readInt(Id, entry.key[1..9], .big),
                .state = try decode(entry.value),
            };
            count += 1;
        }

        return cursor.rows[0..count];
    }

    pub fn checkpoint(self: *Entities, space: storage.Space) !void {
        const table_resources = self.deps.record_workspaces.resources;
        try self.cache.flush();
        if (self.next_id == self.checkpointed_id)
            return;

        var sequence: [8]u8 = undefined;
        std.mem.writeInt(Id, &sequence, self.next_id, .little);
        try records.Table.init(space, table_resources).put(&.{0}, &sequence);
        self.checkpointed_id = self.next_id;
    }
};

pub const Row = struct {
    id: Id,
    state: State,
};

pub const Cursor = struct {
    after: [9]u8 = undefined,
    after_len: usize = 0,
    more: bool = true,
    rows: [16]Row = undefined,
};

const encoded_bytes = 81;

fn encodeKey(entity: Id) [9]u8 {
    assert(entity != 0);
    var key: [9]u8 = undefined;
    key[0] = 1;
    std.mem.writeInt(Id, key[1..9], entity, .big);
    return key;
}

fn valid(state: State) bool {
    var finite = std.math.isFinite(state.yaw) and std.math.isFinite(state.pitch);

    for (state.position ++ state.velocity) |value|
        finite = finite and std.math.isFinite(value);

    return finite;
}

fn encode(state: State, bytes: []u8) void {
    assert(bytes.len == encoded_bytes);
    assert(valid(state));
    std.mem.writeInt(u128, bytes[0..16], state.uuid, .little);
    std.mem.writeInt(u32, bytes[16..20], state.kind, .little);
    std.mem.writeInt(u32, bytes[20..24], state.world, .little);

    for (state.position ++ state.velocity, 0..) |value, i|
        std.mem.writeInt(u64, bytes[24 + i * 8 ..][0..8], @bitCast(value), .little);

    std.mem.writeInt(u32, bytes[72..76], @bitCast(state.yaw), .little);
    std.mem.writeInt(u32, bytes[76..80], @bitCast(state.pitch), .little);
    bytes[80] = state.flags;
}

fn decode(bytes: []const u8) !State {
    if (bytes.len != encoded_bytes)
        return error.Corrupt;

    var state: State = .{
        .uuid = std.mem.readInt(u128, bytes[0..16], .little),
        .kind = std.mem.readInt(u32, bytes[16..20], .little),
        .world = std.mem.readInt(u32, bytes[20..24], .little),
        .position = undefined,
        .velocity = undefined,
        .yaw = @bitCast(std.mem.readInt(u32, bytes[72..76], .little)),
        .pitch = @bitCast(std.mem.readInt(u32, bytes[76..80], .little)),
        .flags = bytes[80],
    };

    for (&state.position, 0..) |*value, i|
        value.* = @bitCast(std.mem.readInt(u64, bytes[24 + i * 8 ..][0..8], .little));

    for (&state.velocity, 0..) |*value, i|
        value.* = @bitCast(std.mem.readInt(u64, bytes[48 + i * 8 ..][0..8], .little));

    if (!valid(state))
        return error.Corrupt;

    return state;
}
