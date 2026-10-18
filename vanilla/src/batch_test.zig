const storage = @import("storage");
const metrics = @import("metrics");
const std = @import("std");
const entities = @import("entities");
const inventories = @import("inventories");
const worlds = @import("worlds");
const game_data = @import("game_data");
const Items = @import("items.zig").Items;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Players = @import("players.zig").Players;

test "spatial refresh retains configuring players and follows movement and disconnect" {
    var records: [3]Players.Player = @splat(.{});
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    records[0] = .{ .handle = .{ .index = 0, .generation = 1 }, .stage = .ready };
    records[1] = .{ .handle = .{ .index = 1, .generation = 1 }, .stage = .ready, .position = .{ .x = -32, .y = 65, .z = 0 } };
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 1), players.nearby(0, records[0].position, 0));
    records[1].position = records[0].position;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 3), players.nearby(0, records[0].position, 0));
    records[1].position.z += 16;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 1), players.nearby(0, records[0].position, 0));
    records[1].world = 1;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 2), players.nearby(1, records[1].position, 0));
    records[1].stage = .awaiting_teleport;
    records[0].handle = null;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 2), players.nearby(1, records[1].position, 32));
    records[1].configuring = true;
    records[1].stage = .login;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 2), players.nearby(1, records[1].position, 0));
    records[1].configuring = false;
    records[1].stage = .ready;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 2), players.nearby(1, records[1].position, 0));
    records[1].handle = null;
    players.refreshSpatial();
    try std.testing.expectEqual(@as(u256, 0), players.nearby(1, records[1].position, 32));
}

test "prepared definitions survive cache reuse and revalidate changed bytes" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
    defer metric_registry.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/items", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path});
    defer store.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const ownership = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_items = 2, .max_item_bytes = 1024 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("inventory") });
    const items = try Items.init(arena.allocator(), .{}, .{ .inventories = ownership, .registry_identity = undefined });
    const bread: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
    const stone: inventories.Stack = .{ .item = try items.define("minecraft:stone"), .count = 1 };
    const apple: inventories.Stack = .{ .item = try items.define("minecraft:apple"), .count = 1 };
    for ([_]inventories.Stack{ bread, stone, apple, bread }, [_][]const u8{ "minecraft:bread", "minecraft:stone", "minecraft:apple", "minecraft:bread" }) |stack, name| {
        const prepared = try items.acquire(stack);
        try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId(name).?)), prepared.view.kind);
        prepared.release();
    }
    var prepared: [2]Items.Prepared = undefined;
    try items.acquireMany(&.{ bread, bread }, &prepared);
    try std.testing.expectEqual(prepared[0].lease.index, prepared[1].lease.index);
    for (prepared) |held| held.release();
    const changed = try ownership.acquireItem(bread.item);
    const length = changed.read().?.len;
    changed.edit()[0] ^= 1;
    changed.commit(length);
    changed.release();
    try std.testing.expectError(error.Corrupt, items.acquire(bread));
    for (ownership.items.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
}

test "pinned item batches observe earlier mutations and retirement" {
    for ([_]usize{ 4, 8 }) |cache_records| {
        var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
        defer metric_registry.deinit();
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/entities", .{directory.sub_path});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path});
        defer store.deinit();
        const transaction = store.transaction();
        defer transaction.fail();
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_items = 2, .cache_slots = 8, .max_item_bytes = 1024 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("inventory") });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = cache_records / 2 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("bodies") });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try transaction.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = cache_records, .maximum = 4 }, .{
            .metrics = &metric_registry,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try transaction.openSpace("metadata"),
        });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const first = try dropped.create(world, .{ 0, 65, 0 }, @splat(0), stack);
        const second = try dropped.create(world, .{ 1, 65, 0 }, @splat(0), stack);
        var iterator = dropped.iterate(&.{ first, second });
        defer iterator.deinit();
        const batch = (try iterator.next()).?;
        try std.testing.expectEqual(cache_records / 4, batch.len);
        {
            var extra: [1]ItemEntities.Record = undefined;
            if (batch.len == 1) try dropped.acquireMany(&.{second}, &extra);
            defer if (batch.len == 1) extra[0].release();
            const partner = if (batch.len == 1) extra[0] else batch[1];
            var metadata = try dropped.get(second);
            metadata.age = 77;
            try dropped.put(second, metadata);
            try std.testing.expectEqual(@as(i32, 77), (try partner.read()).age);
            var body = (try partner.body.read()).?;
            body.position[0] = 2;
            try dropped.move(partner, (try partner.body.read()).?, body);
            try std.testing.expectEqual(@as(f64, 2), (try partner.body.read()).?.position[0]);
            const slot = ItemEntities.slot(body);
            const held = try ownership.get(slot);
            try std.testing.expect(try ownership.set(slot, held.revision, null));
            try dropped.retire(second, body, &metadata);
            try std.testing.expect(!(try partner.read()).alive);
            try std.testing.expect(try partner.body.read() == null);
        }
        iterator.deinit();
        for (dropped.cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
        for (bodies.cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
    }
}
