const vanilla_content = @import("vanilla_definitions").defaults;
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const metrics = @import("metrics");
const entities = @import("entities");
const worlds = @import("worlds");
const chunks = @import("chunks");
const Items = @import("vanilla_items").items.Items;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Players = @import("players").players.Players;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const ItemMerging = @import("vanilla_item_entities").item_merging.ItemMerging;
const tick_module = @import("vanilla_inventory").item_tick;
test "resident merge candidates filter metadata and conserve item ownership with bounded caches" {
    const io = std.testing.io;
    const Case = struct { height: f64, section: i32 };
    for ([_]Case{ .{ .height = 70, .section = 4 }, .{ .height = 64.01, .section = 3 } }) |case| for ([_]usize{ 16, 64 }) |count| for ([_]bool{ false, true }) |merge| for ([_]bool{ false, true }) |small_cache| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/merge-audit", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const gameplay_definitions = try vanilla_content.prepare(allocator);
        const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = if (small_cache) 4 else 128 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = if (small_cache) 8 else 256, .maximum = 64 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        var ids: [64]entities.Id = undefined;
        for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 8, case.height, 8 }, @splat(0), stack);

        for (ids[0..count]) |id| {
            var metadata = try dropped.get(id);
            metadata.ticks = 39;
            metadata.pickup_delay = 0;
            metadata.owner = if (merge) 1000 else 1000 + id;
            try dropped.put(id, metadata);
        }
        try ownership.checkpoint(try store.openSpace("inventory"));
        try bodies.checkpoint(try store.openSpace("bodies"));
        try dropped.checkpoint(try store.openSpace("metadata"));
        _ = try store.commit(1);
        const Source = struct {
            fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
                for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
            }
        };
        var source: Source = .{};
        const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 16, .cache_sections = 24, .cache_groups = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        terrain.setSource(chunks.Source.init(&source, Source.read));
        const physics = try ItemPhysics.init(allocator, .{ .blocks = gameplay_definitions.blocks, .chunks = terrain });
        const merging = try ItemMerging.init(allocator);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .client = gameplay_definitions.client });
        // Merge queries must work with record scans unavailable.
        dropped.cache.scan_entries = &.{};
        const slots = ownership.cache.metrics.acquired.value();
        const body_reads = bodies.cache.metrics.acquired.value();
        try tick.tick();
        const slot_acquisitions = ownership.cache.metrics.acquired.value() - slots;
        const body_acquisitions = bodies.cache.metrics.acquired.value() - body_reads;
        if (!merge) {
            try std.testing.expectEqual(@as(u64, 0), slot_acquisitions);
            try std.testing.expectEqual(count, body_acquisitions);
        }
        try std.testing.expectEqual(@as(u64, if (merge) count - 1 else 0), tick.merged);
        var query = try ItemEntities.Query.init(allocator, dropped, &players);
        const active = query.read(8);
        try std.testing.expectEqual(@as(usize, if (merge) 1 else count), active.len);
        var total: u32 = 0;
        for (active) |id| {
            const body = (try bodies.get(id)).?;
            total += (try ownership.get(ItemEntities.slot(body))).stack.?.count;
        }
        try std.testing.expectEqual(@as(u32, @intCast(count)), total);
        var after: entities.Id = 0;
        var batch_ids: [3]entities.Id = undefined;
        var found: usize = 0;
        while (true) {
            const batch = dropped.inSection(.{ .world = world, .x = 0, .y = case.section, .z = 0 }, &after, &batch_ids);
            if (batch.len == 0) break;
            for (batch) |id| {
                try std.testing.expectEqual(active[found], id);
                found += 1;
            }
        }
        try std.testing.expectEqual(active.len, found);
        if (!merge and count == 16 and !small_cache) {
            after = 0;
            const first_batch = dropped.inSection(.{ .world = world, .x = 0, .y = case.section, .z = 0 }, &after, &batch_ids);
            try std.testing.expectEqualSlices(entities.Id, ids[0..3], first_batch);
            {
                var held: [1]ItemEntities.Record = undefined;
                try dropped.acquireMany(ids[0..1], &held);
                defer held[0].release();
                const body = (try held[0].body.read()).?;
                const slot = ItemEntities.slot(body);
                const contents = try ownership.get(slot);
                try std.testing.expect(try ownership.set(slot, contents.revision, null));
                var metadata = try held[0].read();
                try dropped.retire(ids[0], body, &metadata);
            }
            {
                var held: [1]ItemEntities.Record = undefined;
                try dropped.acquireMany(ids[4..5], &held);
                defer held[0].release();
                const body = (try held[0].body.read()).?;
                var moved = body;
                moved.position[0] = -0.5;
                try dropped.move(held[0], body, moved);
            }
            const resumed = dropped.inSection(.{ .world = world, .x = 0, .y = case.section, .z = 0 }, &after, &batch_ids);
            try std.testing.expectEqualSlices(entities.Id, &.{ ids[3], ids[5], ids[6] }, resumed);
            after = 0;
            const moved = dropped.inSection(.{ .world = world, .x = -1, .y = case.section, .z = 0 }, &after, &batch_ids);
            try std.testing.expectEqualSlices(entities.Id, ids[4..5], moved);
        }
    };
}

test "items burn in lava and fire unless they resist it, and blocks hold, lift and put them out" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/item-hazards", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    const workspaces = try records.Workspaces.init(allocator, io, .{});
    const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 1024 }, .{ .metrics = &registry, .storage = try store.openSpace("inventory"), .record_workspaces = workspaces });
    const gameplay_definitions = try vanilla_content.prepare(allocator);
    const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
    const bread: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
    const netherite: inventories.Stack = .{ .item = try items.define("minecraft:netherite_ingot"), .count = 1 };
    const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 128 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 64 }, .{ .metrics = &registry, .record_workspaces = workspaces, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .storage = try store.openSpace("metadata") });
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
        }
    };
    var source: Source = .{};
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 16, .cache_sections = 32, .cache_groups = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const state = struct {
        fn of(name: []const u8) u16 {
            return @intCast(@import("game_data").registry.blockStateId(name).?);
        }
    }.of;
    // A stone floor at y 63 under every spot.
    for (0..32) |x| try terrain.setBlock(world, .{ .x = @intCast(x), .y = 63, .z = 8 }, state("minecraft:stone"));
    const Spot = enum { lava, lava_resisted, fire, fire_resisted, water, cobweb, bubbles };
    const spots = [_]struct { x: i32, block: []const u8, stack: inventories.Stack }{
        .{ .x = 2, .block = "minecraft:lava[level=0]", .stack = bread },
        .{ .x = 6, .block = "minecraft:lava[level=0]", .stack = netherite },
        .{ .x = 10, .block = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]", .stack = bread },
        .{ .x = 14, .block = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]", .stack = netherite },
        .{ .x = 18, .block = "minecraft:water[level=0]", .stack = bread },
        .{ .x = 22, .block = "minecraft:cobweb", .stack = bread },
        .{ .x = 26, .block = "minecraft:bubble_column[drag=false]", .stack = bread },
    };
    var ids: [spots.len]entities.Id = undefined;
    for (spots, &ids) |spot, *id| {
        try terrain.setBlock(world, .{ .x = spot.x, .y = 64, .z = 8 }, state(spot.block));
        id.* = try dropped.create(world, .{ @as(f64, @floatFromInt(spot.x)) + 0.5, 64, 8.5 }, @splat(0), spot.stack);
    }
    // Water above the bubble column, as columns stand in water.
    try terrain.setBlock(world, .{ .x = 26, .y = 65, .z = 8 }, state("minecraft:water[level=0]"));
    {
        var burning = try dropped.get(ids[@intFromEnum(Spot.water)]);
        burning.fire_ticks = 100;
        try dropped.put(ids[@intFromEnum(Spot.water)], burning);
    }
    const physics = try ItemPhysics.init(allocator, .{ .blocks = gameplay_definitions.blocks, .chunks = terrain });
    const merging = try ItemMerging.init(allocator);
    // Near enough that items tick, too far to hear them, as no connection takes sounds here.
    var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .position = .{ .x = 16, .y = 64, .z = 72 } }};
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .client = gameplay_definitions.client });

    try tick.tick();
    const metadata = struct {
        fn of(from: *ItemEntities, id: entities.Id) !ItemEntities.Metadata {
            return from.get(id);
        }
    }.of;
    // Lava lights an item for fifteen seconds and takes four of its five health a tick.
    const lava = try metadata(dropped, ids[@intFromEnum(Spot.lava)]);
    try std.testing.expect(lava.alive);
    try std.testing.expectEqual(@as(i16, 1), lava.health);
    try std.testing.expectEqual(@as(i32, 300), lava.fire_ticks);
    // Fire lights it for eight and takes one.
    const fire = try metadata(dropped, ids[@intFromEnum(Spot.fire)]);
    try std.testing.expectEqual(@as(i16, 4), fire.health);
    try std.testing.expectEqual(@as(i32, 160), fire.fire_ticks);
    // Netherite resists fire, and is neither hurt nor lit.
    for ([_]Spot{ .lava_resisted, .fire_resisted }) |spot| {
        const resisted = try metadata(dropped, ids[@intFromEnum(spot)]);
        try std.testing.expectEqual(@as(i16, 5), resisted.health);
        try std.testing.expectEqual(@as(i32, 0), resisted.fire_ticks);
    }
    // A burning item hurts itself on the second, then water puts it out.
    const water = try metadata(dropped, ids[@intFromEnum(Spot.water)]);
    try std.testing.expectEqual(@as(i16, 4), water.health);
    try std.testing.expectEqual(@as(i32, 0), water.fire_ticks);
    // A cobweb holds the item back on its next move.
    try std.testing.expectEqual(ItemEntities.Stuck.cobweb, (try metadata(dropped, ids[@intFromEnum(Spot.cobweb)])).stuck);
    // A bubble column lifts it.
    const lifted = (try bodies.get(ids[@intFromEnum(Spot.bubbles)])).?;
    try std.testing.expect(lifted.velocity[1] > 0);

    try tick.tick();
    try std.testing.expect(!(try metadata(dropped, ids[@intFromEnum(Spot.lava)])).alive);
    // Fire hurts each tick the item moves, which on the ground is every fourth.
    for (0..40) |_| try tick.tick();
    try std.testing.expect(!(try metadata(dropped, ids[@intFromEnum(Spot.fire)])).alive);
    for ([_]Spot{ .lava_resisted, .fire_resisted }) |spot| {
        const resisted = try metadata(dropped, ids[@intFromEnum(spot)]);
        try std.testing.expect(resisted.alive);
        try std.testing.expectEqual(@as(i16, 5), resisted.health);
    }
}
