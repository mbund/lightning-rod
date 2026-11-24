const vanilla_content = @import("vanilla_definitions").defaults;
const Domains = @import("domains").domains.Domains;
const EntityColumns = @import("domains").entity_columns.EntityColumns;
const game_data = @import("game_data");
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
pub fn benchmark() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    for ([_]u16{ 1, 64 }) |stack_count| for ([_]usize{ 64, 256, 1024 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/merge-audit", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 256, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const gameplay_definitions = try vanilla_content.prepare(allocator);
        const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });

        const names = [_][]const u8{ "minecraft:bread", "minecraft:stone", "minecraft:dirt", "minecraft:apple", "minecraft:cobblestone", "minecraft:sand", "minecraft:gravel", "minecraft:oak_log", "minecraft:oak_planks", "minecraft:iron_ingot", "minecraft:gold_ingot", "minecraft:coal", "minecraft:redstone", "minecraft:diamond", "minecraft:emerald", "minecraft:stick" };
        var stacks: [names.len]inventories.Stack = undefined;
        for (names, &stacks) |name, *stack| stack.* = .{ .item = try items.define(name), .count = stack_count };

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
        var ids: [1024]entities.Id = undefined;
        for (ids[0..count], 0..) |*id, index| id.* = try dropped.create(world, .{ 2 + @as(f64, @floatFromInt(index % 32)) * 2, 65, 2 + @as(f64, @floatFromInt(index / 32)) * 2 }, @splat(0), stacks[index % stacks.len]);

        for (ids[0..count]) |id| {
            var metadata = try dropped.get(id);
            metadata.ticks = 39;
            metadata.pickup_delay = 0;
            metadata.on_ground = true;
            try dropped.put(id, metadata);
        }
        try ownership.checkpoint(try store.openSpace("inventory"));
        try bodies.checkpoint(try store.openSpace("bodies"));
        try dropped.checkpoint(try store.openSpace("metadata"));
        _ = try store.commit(1);
        const Source = struct {
            fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
                for (batch.requests) |*request| {
                    if (request.section.y == 4) {
                        request.output[0] = 1;
                        for (0..4096) |at| std.mem.writeInt(u16, request.output[1 + at * 2 ..][0..2], if (at < 256) game_data.registry.block_stone_default_state else 0, .little);
                        request.result = 8193;
                    } else request.result = chunks.uniform(if (request.section.y < 4) game_data.registry.block_stone_default_state else 0, request.output);
                }
            }
        };
        var source: Source = .{};
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 256, .cache_groups = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        terrain.setSource(chunks.Source.init(&source, Source.read));
        const physics = try ItemPhysics.init(allocator, .{ .blocks = gameplay_definitions.blocks, .chunks = terrain });
        const merging = try ItemMerging.init(allocator);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .position = .{ .x = 32, .y = 65, .z = 32 } }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        const domains = try Domains.init(allocator, .{}, .{ .players = &players });
        _ = try EntityColumns.init(allocator, .{}, .{ .domains = domains, .entities = bodies });
        const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions, .dimensions = gameplay_definitions.dimensions, .client = gameplay_definitions.client });

        try players.rebuildIndexes();

        failing.fail_index = failing.alloc_index;
        for (0..3) |pass| {
            for (ids[0..count]) |id| {
                var metadata = try dropped.get(id);
                metadata.ticks = 39;
                try dropped.put(id, metadata);
            }
            const definitions = ownership.items.metrics.reads.value();
            const acquired = ownership.items.metrics.acquired.value();
            const slots = ownership.cache.metrics.acquired.value();
            const reads = ownership.cache.metrics.reads.value();
            {
                domains.tick();
                try tick.deps.entities.tickAll();
            }
            try std.testing.expectEqual(slots, ownership.cache.metrics.acquired.value());
            try std.testing.expectEqual(reads, ownership.cache.metrics.reads.value());
            try std.testing.expectEqual(@as(u64, 0), tick.merged);
            try std.testing.expectEqual(definitions, ownership.items.metrics.reads.value());
            try std.testing.expectEqual(acquired, ownership.items.metrics.acquired.value());
            try output.interface.print("ITEM_LIMIT items={d} stack_count={d} pass={d} distinct=16 cache_definitions=8 definition_reads={d} definition_acquisitions={d} source_slot_acquisitions=0 merges=0\n", .{ count, stack_count, pass, ownership.items.metrics.reads.value() - definitions, ownership.items.metrics.acquired.value() - acquired });
        }

        failing.fail_index = std.math.maxInt(usize);
        // A restart: every entity's memory afresh, items coming back from the store.
        const restored_bodies = try entities.Entities.init(allocator, io, .{}, bodies.deps);
        // The columns ticking now; the player stands still, so they stay.
        var ticking = domains.tickingColumns();
        try restored_bodies.places.resyncTicking(&ticking);
        var restored_deps = dropped.deps;
        restored_deps.entities = restored_bodies;
        const restored = try ItemEntities.init(allocator, io, .{}, restored_deps);
        tick.deps.dropped = restored;
        tick.deps.entities = restored_bodies;
        try restored_bodies.addTicker(tick.ticker());
        failing.fail_index = failing.alloc_index;
        const restored_reads = ownership.items.metrics.reads.value();
        const restored_acquisitions = ownership.items.metrics.acquired.value();
        {
            domains.tick();
            try tick.deps.entities.tickAll();
        }
        // Restored, the stack limits merging asks of are read again: once a kind at most.
        try std.testing.expect(ownership.items.metrics.reads.value() <= restored_reads + stacks.len);
        try std.testing.expect(ownership.items.metrics.acquired.value() <= restored_acquisitions + stacks.len);
        const body = (try restored.read(ids[0])).?.body;
        const inventory_slot = ItemEntities.slot(body);
        try std.testing.expectEqual(stack_count == 64, (try restored.fullStack(body)));
        const previous = try ownership.get(inventory_slot);
        const replacement: inventories.Stack = .{ .item = try items.define("minecraft:ender_pearl"), .count = 1 };
        try std.testing.expect(try ownership.set(inventory_slot, previous.revision, replacement));
        try std.testing.expect(!(try restored.fullStack(body)));
        try std.testing.expectEqual(@as(u16, 16), try restored.stackLimit(replacement));
        // A stack is read when asked of, so a full one is found full as soon as it is.
        const full: inventories.Stack = .{ .item = replacement.item, .count = 16 };
        try std.testing.expect(try ownership.set(inventory_slot, previous.revision + 1, full));
        try std.testing.expect(try restored.fullStack(body));
    };
    try output.interface.flush();
}
