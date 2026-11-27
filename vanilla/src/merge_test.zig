const vanilla_content = @import("vanilla_definitions").defaults;
const Domains = @import("domains").domains.Domains;
const EntityColumns = @import("domains").entity_columns.EntityColumns;
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const metrics = @import("metrics");
const entities = @import("entities");
const worlds = @import("worlds");
const test_levels = @import("test_levels.zig");
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
        const bodies = try entities.Entities.init(allocator, io, .{}, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{}, .{
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
        const physics = try test_levels.itemPhysics(allocator, gameplay_definitions.blocks, terrain, dimensions);
        const merging = try ItemMerging.init(allocator);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        try players.rebuildIndexes();
        const domains = try Domains.init(allocator, .{}, .{ .players = &players });
        _ = try EntityColumns.init(allocator, .{}, .{ .domains = domains, .entities = bodies });
        const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .client = gameplay_definitions.client });
        const slots = ownership.cache.metrics.acquired.value();
        {
            domains.tick();
            try tick.deps.entities.tickAll();
        }
        // Items apart read no stacks to merge.
        const slot_acquisitions = ownership.cache.metrics.acquired.value() - slots;
        if (!merge) try std.testing.expectEqual(@as(u64, 0), slot_acquisitions);
        try std.testing.expectEqual(@as(u64, if (merge) count - 1 else 0), tick.merged);
        var alive: [64]entities.Id = undefined;
        const active = alive[0..try aliveItems(dropped, &alive)];
        try std.testing.expectEqual(@as(usize, if (merge) 1 else count), active.len);
        var total: u32 = 0;
        for (active) |id| {
            const body = (try bodies.getById(id)).?;
            total += (try ownership.get(ItemEntities.slot(body))).stack.?.count;
        }
        try std.testing.expectEqual(@as(u32, @intCast(count)), total);
        // The section's items, as they entered it, through a buffer of 3.
        var found: [64]entities.Id = undefined;
        const found_count = try gatherSection(dropped, world, 0, case.section, &found);
        try std.testing.expectEqualSlices(entities.Id, active, found[0..found_count]);
        if (!merge and count == 16 and !small_cache) {
            {
                const view = (try dropped.read(ids[0])).?;
                const slot = ItemEntities.slot(view.body);
                const contents = try ownership.get(slot);
                try std.testing.expect(try ownership.set(slot, contents.revision, null));
                var metadata = view.metadata;
                try dropped.retire(ids[0], view.body, &metadata);
            }
            {
                const body = (try dropped.read(ids[4])).?.body;
                var moved = body;
                moved.position[0] = -0.5;
                try dropped.move(ids[4], body, moved);
            }
            // Retired, it is gone from its section; moved, it is in its new column's.
            const remaining = try gatherSection(dropped, world, 0, case.section, &found);
            try std.testing.expectEqualSlices(entities.Id, ids[1..4], found[0..3]);
            try std.testing.expectEqualSlices(entities.Id, ids[5..16], found[3..remaining]);
            const moved = try gatherSection(dropped, world, -1, case.section, &found);
            try std.testing.expectEqualSlices(entities.Id, ids[4..5], found[0..moved]);
        }
    };
}

/// The items not gone, by id.
fn aliveItems(dropped: *ItemEntities, output: []entities.Id) !usize {
    var rows = dropped.rows();
    var count: usize = 0;
    while ((try rows.next())) |row| {
        if (!row.metadata.alive) continue;
        output[count] = row.id;
        count += 1;
    }
    std.sort.pdq(entities.Id, output[0..count], {}, std.sort.asc(entities.Id));
    return count;
}

fn gatherSection(dropped: *ItemEntities, world: u32, x: i32, section: i32, output: []entities.Id) !usize {
    var buffer: [3]entities.space.Entry = undefined;
    var ordered = dropped.places.space.ordered(.{ .world = world, .x = x, .z = 0 }, section, section, ItemEntities.kinds, &buffer);
    var count: usize = 0;
    while (true) {
        const batch = try ordered.next();
        if (batch.len == 0) return count;
        for (batch) |entry| {
            output[count] = entry.id;
            count += 1;
        }
    }
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
    const bodies = try entities.Entities.init(allocator, io, .{}, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    const dropped = try ItemEntities.init(allocator, io, .{}, .{ .metrics = &registry, .record_workspaces = workspaces, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .storage = try store.openSpace("metadata") });
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
    const Spot = enum { lava, lava_resisted, fire, fire_resisted, water, cobweb, bubbles, inside };
    const spots = [_]struct { x: i32, block: []const u8, stack: inventories.Stack }{
        .{ .x = 2, .block = "minecraft:lava[level=0]", .stack = bread },
        .{ .x = 6, .block = "minecraft:lava[level=0]", .stack = netherite },
        .{ .x = 10, .block = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]", .stack = bread },
        .{ .x = 14, .block = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]", .stack = netherite },
        .{ .x = 18, .block = "minecraft:water[level=0]", .stack = bread },
        .{ .x = 22, .block = "minecraft:cobweb", .stack = bread },
        .{ .x = 26, .block = "minecraft:bubble_column[drag=false]", .stack = bread },
        .{ .x = 30, .block = "minecraft:stone", .stack = bread },
    };
    var ids: [spots.len]entities.Id = undefined;
    for (spots, &ids) |spot, *id| {
        try terrain.setBlock(world, .{ .x = spot.x, .y = 64, .z = 8 }, state(spot.block));
        id.* = try dropped.create(world, .{ @as(f64, @floatFromInt(spot.x)) + 0.5, 64, 8.5 }, @splat(0), spot.stack);
    }
    // Water above the bubble column, as columns stand in water.
    try terrain.setBlock(world, .{ .x = 26, .y = 65, .z = 8 }, state("minecraft:water[level=0]"));
    {
        var burning = try dropped.get(ids[@backingInt(Spot.water)]);
        burning.fire_ticks = 100;
        try dropped.put(ids[@backingInt(Spot.water)], burning);
    }
    const physics = try test_levels.itemPhysics(allocator, gameplay_definitions.blocks, terrain, dimensions);
    const merging = try ItemMerging.init(allocator);
    // Near enough that items tick, too far to hear them, as no connection takes sounds here.
    var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .position = .{ .x = 16, .y = 64, .z = 72 } }};
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    try players.rebuildIndexes();
    const domains = try Domains.init(allocator, .{}, .{ .players = &players });
    _ = try EntityColumns.init(allocator, .{}, .{ .domains = domains, .entities = bodies });
    const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .client = gameplay_definitions.client });

    {
        domains.tick();
        try tick.deps.entities.tickAll();
    }
    const metadata = struct {
        fn of(from: *ItemEntities, id: entities.Id) !ItemEntities.Metadata {
            return from.get(id);
        }
    }.of;
    // Lava lights an item for fifteen seconds and takes four of its five health a tick.
    const lava = try metadata(dropped, ids[@backingInt(Spot.lava)]);
    try std.testing.expect(lava.alive);
    try std.testing.expectEqual(@as(i16, 1), lava.health);
    try std.testing.expectEqual(@as(i32, 300), lava.fire_ticks);
    // Fire lights it for eight and takes one.
    const fire = try metadata(dropped, ids[@backingInt(Spot.fire)]);
    try std.testing.expectEqual(@as(i16, 4), fire.health);
    try std.testing.expectEqual(@as(i32, 160), fire.fire_ticks);
    // Netherite resists fire, and is neither hurt nor lit.
    for ([_]Spot{ .lava_resisted, .fire_resisted }) |spot| {
        const resisted = try metadata(dropped, ids[@backingInt(spot)]);
        try std.testing.expectEqual(@as(i16, 5), resisted.health);
        try std.testing.expectEqual(@as(i32, 0), resisted.fire_ticks);
    }
    // A burning item hurts itself on the second, then water puts it out.
    const water = try metadata(dropped, ids[@backingInt(Spot.water)]);
    try std.testing.expectEqual(@as(i16, 4), water.health);
    try std.testing.expectEqual(@as(i32, 0), water.fire_ticks);
    // A cobweb holds the item back on its next move.
    try std.testing.expectEqual(ItemEntities.Stuck.cobweb, (try metadata(dropped, ids[@backingInt(Spot.cobweb)])).stuck);
    // A bubble column lifts it.
    const lifted = (try bodies.getById(ids[@backingInt(Spot.bubbles)])).?;
    try std.testing.expect(lifted.velocity[1] > 0);
    // Inside stone, it is pushed out the nearest open side, north of four alike, at 0.1 to
    // 0.3 a tick less the air's slowing, and moves through the stone to get there.
    const pushed = (try bodies.getById(ids[@backingInt(Spot.inside)])).?;
    try std.testing.expect(pushed.velocity[2] < -0.1 * 0.98 and pushed.velocity[2] > -0.3);
    try std.testing.expect(pushed.position[2] < 8.5);
    try std.testing.expectEqual(@as(f64, 30.5), pushed.position[0]);

    {
        domains.tick();
        try tick.deps.entities.tickAll();
    }
    try std.testing.expect(!(try metadata(dropped, ids[@backingInt(Spot.lava)])).alive);
    // Fire hurts each tick the item moves, which on the ground is every fourth.
    for (0..40) |_| {
        domains.tick();
        try tick.deps.entities.tickAll();
    }
    try std.testing.expect(!(try metadata(dropped, ids[@backingInt(Spot.fire)])).alive);
    for ([_]Spot{ .lava_resisted, .fire_resisted }) |spot| {
        const resisted = try metadata(dropped, ids[@backingInt(spot)]);
        try std.testing.expect(resisted.alive);
        try std.testing.expectEqual(@as(i16, 5), resisted.health);
    }
}
