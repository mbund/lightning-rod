const metrics = @import("metrics");
const std = @import("std");
const worlds = @import("worlds");
const lightning_rod = @import("lightning_rod");
const entities = @import("entities");
const inventories = @import("inventories");
const records = @import("records");
const registry = @import("game_data").registry;
const Items = @import("items.zig").Items;

const assert = std.debug.assert;

pub const ItemEntities = struct {
    pub const id = "minecraft:item_entities";

    pub const Configuration = struct {
        cache_records: usize = 256,
        /// Includes retired entities waiting for clients to accept their removal.
        maximum: usize = 1024,
    };

    pub const Dependencies = struct {
        metrics: *metrics.Registry,
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        storage: lightning_rod.storage.Space,
    };

    pub const Metadata = struct {
        ticks: u32 = 0,
        age: i32 = 0,
        pickup_delay: u16 = 10,
        health: i16 = 5,
        on_ground: bool = false,
        owner: ?u128 = null,
        revision: u64 = 1,
        alive: bool = true,
        collector: i32 = 0,
        collected: u16 = 0,
        collection: u64 = 0,
    };

    pub const Row = struct {
        id: entities.Id,
        metadata: Metadata,
    };

    pub const Cursor = struct {
        after: [25]u8 = undefined,
        after_len: usize = 0,
        more: bool = true,
        keys: [16][25]u8 = undefined,
        values: [16][54]u8 = undefined,
        rows: [16]Row = undefined,
    };

    pub const Resident = struct {
        id: entities.Id = 0,
        world: u32 = 0,
        x: i32 = 0,
        z: i32 = 0,
        y: i32 = 0,
        alive: bool = false,
    };

    deps: Dependencies,
    cache: records.Cache,
    residents: []Resident,
    ids: std.AutoHashMapUnmanaged(entities.Id, u32) = .empty,
    spatial: []u32,
    spatial_count: usize = 0,
    free: []u32,
    free_count: usize,
    candidates: []entities.Id,
    marked: []bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        if (deps.entities.cache.entries.len < 2 or config.cache_records < 4 or config.maximum == 0 or config.maximum > 65536) return error.InvalidConfiguration;

        const self = try allocator.create(ItemEntities);
        self.* = .{
            .deps = deps,
            .residents = try allocator.alloc(Resident, config.maximum),
            .spatial = try allocator.alloc(u32, config.maximum),
            .free = try allocator.alloc(u32, config.maximum),
            .free_count = config.maximum,
            .candidates = try allocator.alloc(entities.Id, config.maximum),
            .marked = try allocator.alloc(bool, config.maximum),
            .cache = try records.Cache.init(allocator, io, records.Table.init(deps.storage), .{
                .metrics = deps.metrics,
                .metrics_namespace = "items.cache",
                .slots = config.cache_records,
                .key_bytes = 25,
                .value_bytes = 54,
                .scan_batch = 16,
            }),
        };
        @memset(self.residents, .{});
        for (self.free, 0..) |*free_slot, i| free_slot.* = @intCast(config.maximum - i - 1);
        try self.ids.ensureTotalCapacity(allocator, @intCast(config.maximum));
        var cursor: Cursor = .{};
        while (cursor.more) for (try self.scan(&cursor)) |row| {
            const body = if (row.metadata.alive) (try deps.entities.get(row.id)) orelse return error.Corrupt else null;
            try self.track(row.id, body);
        };
        return self;
    }

    pub fn canCreate(self: *const ItemEntities, count: usize) bool {
        assert(self.free_count <= self.residents.len);
        return count <= self.free_count;
    }

    pub fn create(self: *ItemEntities, world: u32, position: [3]f64, velocity: [3]f64, stack: inventories.Stack) !entities.Id {
        if (self.free_count == 0) return error.ItemEntityCapacity;
        if (self.deps.worlds.get(world) == null) return error.UnknownWorld;
        if (stack.count == 0 or stack.count > try self.deps.items.stackLimit(stack)) return error.InvalidStack;
        if (self.deps.entities.next_id > std.math.maxInt(i32) - 256) return error.IdExhausted;

        const uuid = @as(u128, 0x4c524954454d40008000000000000000) | self.deps.entities.next_id;
        const body: entities.State = .{
            .uuid = uuid,
            .kind = comptime registry.entityId("minecraft:item").?,
            .world = world,
            .position = position,
            .velocity = velocity,
        };
        errdefer self.deps.storage.fail();
        const entity = try self.deps.entities.create(body);
        try self.track(entity, body);
        const stored = try self.deps.inventories.set(slot(body), 0, stack);
        assert(stored);
        try self.put(entity, .{});
        const key = spatialKey(entity, body);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        lease.edit()[0] = 1;
        lease.commit(1);
        return entity;
    }

    pub const Record = struct {
        id: entities.Id,
        metadata: records.Cache.Lease,
        body: entities.Entities.Lease,

        pub fn read(self: Record) !Metadata {
            return decode(self.metadata.read() orelse return error.UnknownItemEntity);
        }

        pub fn write(self: Record, metadata: Metadata) void {
            encode(metadata, self.metadata.edit());
            self.metadata.commit(54);
        }

        pub fn release(self: Record) void {
            self.body.release();
            self.metadata.release();
        }
    };

    pub fn acquireMany(self: *ItemEntities, ids: []const entities.Id, output: []Record) !void {
        if (ids.len != output.len or ids.len > 16) return error.WorkingSetTooLarge;
        var keys: [16][9]u8 = undefined;
        var slices: [16][]const u8 = undefined;
        var metadata: [16]records.Cache.Lease = undefined;
        var bodies: [16]entities.Entities.Lease = undefined;
        for (ids, 0..) |entity, i| {
            keys[i] = keyFor(entity);
            slices[i] = &keys[i];
        }
        try self.cache.acquireMany(slices[0..ids.len], metadata[0..ids.len]);
        errdefer for (metadata[0..ids.len]) |lease| lease.release();
        try self.deps.entities.acquireMany(ids, bodies[0..ids.len]);
        for (ids, output, metadata[0..ids.len], bodies[0..ids.len]) |entity, *record, meta, body|
            record.* = .{ .id = entity, .metadata = meta, .body = body };
    }

    pub const Iterator = struct {
        owner: *ItemEntities,
        ids: []const entities.Id,
        records: [16]Record = undefined,
        next_id: usize = 0,
        live: usize = 0,
        start: usize = 0,

        pub fn next(self: *Iterator) !?[]Record {
            self.deinit();
            if (self.next_id == self.ids.len) return null;
            // Leave room for merge partners and spatial records while the batch is pinned.
            const count = @min(self.records.len, self.owner.cache.entries.len / 4, self.owner.deps.entities.cache.entries.len / 2, self.ids.len - self.next_id);
            assert(count > 0);
            var ids: [16]entities.Id = undefined;
            for (ids[0..count], 0..) |*entity, i| entity.* = self.ids[(self.start + self.next_id + i) % self.ids.len];
            try self.owner.acquireMany(ids[0..count], self.records[0..count]);
            self.live = count;
            self.next_id += count;
            return self.records[0..count];
        }

        pub fn deinit(self: *Iterator) void {
            for (self.records[0..self.live]) |record| record.release();
            self.live = 0;
        }
    };

    pub fn iterate(self: *ItemEntities, ids: []const entities.Id) Iterator {
        return .{ .owner = self, .ids = ids };
    }

    pub fn get(self: *ItemEntities, entity: entities.Id) !Metadata {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        return decode(lease.read() orelse return error.UnknownItemEntity);
    }

    pub fn put(self: *ItemEntities, entity: entities.Id, metadata: Metadata) !void {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        encode(metadata, lease.edit());
        lease.commit(54);
    }

    pub fn move(self: *ItemEntities, record: Record, before: entities.State, after: entities.State) !void {
        const entity = record.id;
        if (self.deps.worlds.get(after.world) == null) return error.UnknownWorld;

        const old_key = spatialKey(entity, before);
        const new_key = spatialKey(entity, after);
        errdefer self.deps.storage.fail();

        if (!std.mem.eql(u8, &old_key, &new_key)) {
            var leases: [2]records.Cache.Lease = undefined;
            try self.cache.acquireMany(&.{ &old_key, &new_key }, &leases);
            defer for (leases) |lease| lease.release();
            assert(leases[0].read() != null);
            leases[0].remove();
            leases[1].edit()[0] = 1;
            leases[1].commit(1);
        }

        try record.body.write(after);
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        if (!std.mem.eql(u8, &old_key, &new_key)) {
            self.removeSpatial(slot_index);
            self.residents[slot_index] = resident(entity, after);
            self.insertSpatial(slot_index);
        }
    }

    pub fn retire(self: *ItemEntities, entity: entities.Id, body: entities.State, metadata: *Metadata) !void {
        assert(metadata.alive);
        errdefer self.deps.storage.fail();
        const key = spatialKey(entity, body);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        assert(lease.read() != null);
        lease.remove();
        try self.deps.inventories.retire(slot(body));
        try self.deps.entities.remove(entity);
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        self.removeSpatial(slot_index);
        self.residents[slot_index].alive = false;
        metadata.alive = false;
        metadata.revision += 1;
        try self.put(entity, metadata.*);
    }

    pub fn forget(self: *ItemEntities, entity: entities.Id) !void {
        const key = keyFor(entity);
        const lease = try self.cache.acquire(&key);
        defer lease.release();
        assert(!(try decode(lease.read().?)).alive);
        lease.remove();
        const slot_index = self.ids.get(entity) orelse return error.UnknownItemEntity;
        assert(!self.residents[slot_index].alive);
        const removed = self.ids.remove(entity);
        assert(removed);
        self.residents[slot_index] = .{};
        self.free[self.free_count] = slot_index;
        self.free_count += 1;
    }

    /// Borrowed until the next nearby query. Overlapping player regions are deduplicated.
    /// Selection reads only the resident spatial index. Inactive items cause no storage reads.
    pub fn nearby(self: *ItemEntities, players: anytype, radius: i32) []const entities.Id {
        @memset(self.marked, false);
        var count: usize = 0;
        for (players.records) |player| {
            if (!player.inWorld()) continue;
            const x: i32 = @intFromFloat(@floor(player.position.x / 16));
            const z: i32 = @intFromFloat(@floor(player.position.z / 16));
            var at = self.lowerSpatial(.{ .world = player.world, .x = x - radius, .z = std.math.minInt(i32), .y = std.math.minInt(i32) });
            while (at < self.spatial_count) : (at += 1) {
                const slot_index = self.spatial[at];
                const entry = self.residents[slot_index];
                if (entry.world != player.world or entry.x > x + radius) break;
                if (@abs(@as(i64, entry.z) - z) > radius or self.marked[slot_index]) continue;
                self.marked[slot_index] = true;
                self.candidates[count] = entry.id;
                count += 1;
            }
        }
        // Stable entity order makes scheduling independent of player query order.
        std.mem.sort(entities.Id, self.candidates[0..count], {}, std.sort.asc(entities.Id));
        return self.candidates[0..count];
    }

    fn track(self: *ItemEntities, entity: entities.Id, body: ?entities.State) !void {
        if (self.free_count == 0) return error.ItemEntityCapacity;
        self.free_count -= 1;
        const slot_index = self.free[self.free_count];
        self.residents[slot_index] = if (body) |value| resident(entity, value) else .{ .id = entity };
        self.ids.putAssumeCapacityNoClobber(entity, slot_index);
        if (body != null) self.insertSpatial(slot_index);
    }

    fn resident(entity: entities.Id, body: entities.State) Resident {
        return .{ .id = entity, .world = body.world, .x = @intFromFloat(@floor(body.position[0] / 16)), .z = @intFromFloat(@floor(body.position[2] / 16)), .y = @intFromFloat(@floor(body.position[1] / 16)), .alive = true };
    }

    fn less(a: Resident, b: Resident) bool {
        inline for (.{ "world", "x", "z", "y", "id" }) |field| {
            if (@field(a, field) != @field(b, field)) return @field(a, field) < @field(b, field);
        }
        return false;
    }

    fn lowerSpatial(self: *ItemEntities, value: Resident) usize {
        var low: usize = 0;
        var high = self.spatial_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (less(self.residents[self.spatial[middle]], value)) low = middle + 1 else high = middle;
        }
        return low;
    }

    fn insertSpatial(self: *ItemEntities, slot_index: u32) void {
        assert(self.spatial_count < self.spatial.len);
        const at = self.lowerSpatial(self.residents[slot_index]);
        std.mem.copyBackwards(u32, self.spatial[at + 1 .. self.spatial_count + 1], self.spatial[at..self.spatial_count]);
        self.spatial[at] = slot_index;
        self.spatial_count += 1;
    }

    fn removeSpatial(self: *ItemEntities, slot_index: u32) void {
        const at = self.lowerSpatial(self.residents[slot_index]);
        assert(at < self.spatial_count and self.spatial[at] == slot_index);
        std.mem.copyForwards(u32, self.spatial[at .. self.spatial_count - 1], self.spatial[at + 1 .. self.spatial_count]);
        self.spatial_count -= 1;
    }

    pub fn scan(self: *ItemEntities, cursor: *Cursor) ![]const Row {
        var entries: [16]records.ScanEntry = undefined;

        for (&entries, &cursor.keys, &cursor.values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };

        var position: records.ScanCursor = .{ .after = &cursor.after, .after_len = cursor.after_len };
        const batch = try self.cache.scan(&position, &entries);
        cursor.after_len = position.after_len;
        cursor.more = batch.more;
        var count: usize = 0;

        for (entries[0..batch.count]) |entry| {
            if (entry.key_len == 25 and entry.key[0] == 1) {
                cursor.more = false;
                break;
            }

            if (entry.key_len != 9 or entry.key[0] != 0) return error.Corrupt;
            cursor.rows[count] = .{ .id = std.mem.readInt(u64, entry.key[1..9], .big), .metadata = try decode(entry.value[0..entry.value_len]) };
            count += 1;
        }

        return cursor.rows[0..count];
    }

    pub fn checkpoint(self: *ItemEntities, _: lightning_rod.storage.Space) !void {
        try self.cache.flush();
    }

    pub fn slot(body: entities.State) inventories.Slot {
        assert(body.kind == comptime registry.entityId("minecraft:item").?);
        return .{ .owner = body.uuid, .index = 0 };
    }

    pub fn networkId(entity: entities.Id) i32 {
        assert(entity > 0 and entity <= std.math.maxInt(i32) - 256);
        return @intCast(entity + 256);
    }

    pub fn spatialKey(entity: entities.Id, body: entities.State) [25]u8 {
        var key: [25]u8 = undefined;
        key[0] = 1;
        std.mem.writeInt(u32, key[1..5], body.world, .big);

        for ([_]f64{ body.position[0], body.position[2], body.position[1] }, 0..) |coordinate, i| {
            const section: i32 = @intFromFloat(@floor(coordinate / 16));
            std.mem.writeInt(u32, key[5 + i * 4 ..][0..4], @as(u32, @bitCast(section)) ^ 0x80000000, .big);
        }

        std.mem.writeInt(u64, key[17..25], entity, .big);
        return key;
    }
};

fn keyFor(entity: entities.Id) [9]u8 {
    assert(entity > 0);
    var key: [9]u8 = undefined;
    key[0] = 0;
    std.mem.writeInt(u64, key[1..9], entity, .big);
    return key;
}

fn encode(value: ItemEntities.Metadata, output: []u8) void {
    assert(output.len == 54);
    assert(value.pickup_delay <= 32767);
    var writer = std.Io.Writer.fixed(output);
    writer.writeByte(1) catch unreachable;
    writer.writeInt(u32, value.ticks, .little) catch unreachable;
    writer.writeInt(i32, value.age, .little) catch unreachable;
    writer.writeInt(u16, value.pickup_delay, .little) catch unreachable;
    writer.writeInt(i16, value.health, .little) catch unreachable;
    writer.writeByte(@intFromBool(value.on_ground)) catch unreachable;
    writer.writeByte(@intFromBool(value.owner != null)) catch unreachable;
    writer.writeInt(u128, value.owner orelse 0, .little) catch unreachable;
    writer.writeInt(u64, value.revision, .little) catch unreachable;
    writer.writeByte(@intFromBool(value.alive)) catch unreachable;
    writer.writeInt(i32, value.collector, .little) catch unreachable;
    writer.writeInt(u16, value.collected, .little) catch unreachable;
    writer.writeInt(u64, value.collection, .little) catch unreachable;
    assert(writer.end == output.len);
}

fn decode(bytes: []const u8) !ItemEntities.Metadata {
    if (bytes.len != 54 or bytes[0] != 1 or bytes[13] > 1 or bytes[14] > 1 or bytes[39] > 1) return error.Corrupt;

    const value: ItemEntities.Metadata = .{
        .ticks = std.mem.readInt(u32, bytes[1..5], .little),
        .age = std.mem.readInt(i32, bytes[5..9], .little),
        .pickup_delay = std.mem.readInt(u16, bytes[9..11], .little),
        .health = std.mem.readInt(i16, bytes[11..13], .little),
        .on_ground = bytes[13] == 1,
        .owner = if (bytes[14] == 0) null else std.mem.readInt(u128, bytes[15..31], .little),
        .revision = std.mem.readInt(u64, bytes[31..39], .little),
        .alive = bytes[39] == 1,
        .collector = std.mem.readInt(i32, bytes[40..44], .little),
        .collected = std.mem.readInt(u16, bytes[44..46], .little),
        .collection = std.mem.readInt(u64, bytes[46..54], .little),
    };
    if (value.pickup_delay > 32767 or value.revision == 0) return error.Corrupt;
    return value;
}
