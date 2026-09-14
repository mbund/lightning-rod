const std = @import("std");
const worlds = @import("worlds");
const rod = @import("lightning_rod");
const entities = @import("entities");
const inventories = @import("inventories");
const records = @import("records");
const registry = @import("protocols").registry;
const Items = @import("items.zig").Items;

const assert = std.debug.assert;

pub const ItemEntities = struct {
    pub const id = "minecraft:item_entities";

    pub const Configuration = struct { cache_records: usize = 256 };

    pub const Dependencies = struct {
        entities: *entities.Entities,
        inventories: *inventories.Inventories,
        items: *Items,
        worlds: *worlds.Worlds,
        storage: rod.storage.Namespace,
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

    deps: Dependencies,
    cache: records.Cache,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration, deps: Dependencies) !*ItemEntities {
        if (config.cache_records < 4) return error.InvalidConfiguration;

        const self = try allocator.create(ItemEntities);
        self.* = .{
            .deps = deps,
            .cache = try records.Cache.init(allocator, io, deps.storage, .{
                .slots = config.cache_records,
                .key_bytes = 25,
                .value_bytes = 54,
                .scan_batch = 16,
            }),
        };
        return self;
    }

    pub fn create(self: *ItemEntities, world: u32, position: [3]f64, velocity: [3]f64, stack: inventories.Stack) !entities.Id {
        if (self.deps.worlds.get(world) == null) return error.UnknownWorld;
        if (stack.count == 0 or stack.count > try self.deps.items.stackLimit(stack)) return error.InvalidStack;
        if (self.deps.entities.next_id > std.math.maxInt(i32) - 256) return error.IdExhausted;

        const uuid = @as(u128, 0x4c524954454d40008000000000000000) | self.deps.entities.next_id;
        const body: entities.State = .{
            .uuid = uuid,
            .kind = registry.entity_item_type_id,
            .world = world,
            .position = position,
            .velocity = velocity,
        };
        errdefer self.deps.storage.fail();
        const entity = try self.deps.entities.create(body);
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

    pub fn move(self: *ItemEntities, entity: entities.Id, before: entities.State, after: entities.State) !void {
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

        try self.deps.entities.put(entity, after);
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
    }

    pub fn scan(self: *ItemEntities, cursor: *Cursor) ![]const Row {
        var entries: [16]rod.storage.ScanEntry = undefined;

        for (&entries, &cursor.keys, &cursor.values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };

        var position: rod.storage.ScanCursor = .{ .after = &cursor.after, .after_len = cursor.after_len };
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

    pub fn checkpoint(self: *ItemEntities, _: rod.storage.Namespace) !void {
        try self.cache.flush();
    }

    pub fn slot(body: entities.State) inventories.Slot {
        assert(body.kind == registry.entity_item_type_id);
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
