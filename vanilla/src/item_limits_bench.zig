const game_data = @import("game_data");
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const metrics = @import("metrics");
const entities = @import("entities");
const worlds = @import("worlds");
const chunks = @import("chunks");
const Items = @import("items.zig").Items;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Players = @import("players.zig").Players;
const ItemPhysics = @import("item_physics.zig").ItemPhysics;
const ItemMerging = @import("item_merging.zig").ItemMerging;
const tick_module = @import("item_tick.zig");
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
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });

        const names = [_][]const u8{ "minecraft:bread", "minecraft:stone", "minecraft:dirt", "minecraft:apple", "minecraft:cobblestone", "minecraft:sand", "minecraft:gravel", "minecraft:oak_log", "minecraft:oak_planks", "minecraft:iron_ingot", "minecraft:gold_ingot", "minecraft:coal", "minecraft:redstone", "minecraft:diamond", "minecraft:emerald", "minecraft:stick" };
        var stacks: [names.len]inventories.Stack = undefined;
        for (names, &stacks) |name, *stack| stack.* = .{ .item = try items.define(name), .count = stack_count };

        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 1024 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 1024, .maximum = 1024 }, .{
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
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 0, .cache_tiles = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        terrain.setSource(chunks.Source.init(&source, Source.read));
        const physics = try ItemPhysics.init(allocator, .{ .chunks = terrain });
        const merging = try ItemMerging.init(allocator);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .position = .{ .x = 32, .y = 65, .z = 32 } }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        const tick = try tick_module.ItemTick.init(allocator, .{ .merge_candidates = count * 128 }, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions });

        players.rebuildIndexes();

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
            try tick.tick();
            try std.testing.expectEqual(slots, ownership.cache.metrics.acquired.value());
            try std.testing.expectEqual(reads, ownership.cache.metrics.reads.value());
            try std.testing.expectEqual(@as(u64, 0), tick.merged);
            try std.testing.expectEqual(definitions, ownership.items.metrics.reads.value());
            try std.testing.expectEqual(acquired, ownership.items.metrics.acquired.value());
            try output.interface.print("ITEM_LIMIT items={d} stack_count={d} pass={d} distinct=16 cache_definitions=8 definition_reads={d} definition_acquisitions={d} source_slot_acquisitions=0 merges=0\n", .{ count, stack_count, pass, ownership.items.metrics.reads.value() - definitions, ownership.items.metrics.acquired.value() - acquired });
        }

        failing.fail_index = std.math.maxInt(usize);
        const restored = try ItemEntities.init(allocator, io, .{ .cache_records = 1024, .maximum = 1024 }, dropped.deps);
        tick.deps.dropped = restored;
        tick.query = try ItemEntities.Query.init(allocator, restored, &players);
        failing.fail_index = failing.alloc_index;
        const restored_reads = ownership.items.metrics.reads.value();
        const restored_acquisitions = ownership.items.metrics.acquired.value();
        try tick.tick();
        try std.testing.expectEqual(restored_reads, ownership.items.metrics.reads.value());
        try std.testing.expectEqual(restored_acquisitions, ownership.items.metrics.acquired.value());
        var held: [1]ItemEntities.Record = undefined;
        try restored.acquireMany(ids[0..1], &held);
        defer held[0].release();
        const body = (try held[0].body.read()).?;
        const inventory_slot = ItemEntities.slot(body);
        try std.testing.expectEqual(stack_count == 64, restored.fullStack(held[0]));
        const previous = try ownership.get(inventory_slot);
        const replacement: inventories.Stack = .{ .item = try items.define("minecraft:ender_pearl"), .count = 1 };
        try std.testing.expect(try ownership.set(inventory_slot, previous.revision, replacement));
        try std.testing.expect(!restored.fullStack(held[0]));
        const before = ownership.items.metrics.acquired.value();
        try std.testing.expectEqual(@as(u16, 16), try restored.stackLimit(held[0], replacement));
        try std.testing.expectEqual(before + 1, ownership.items.metrics.acquired.value());
        var limits: [16]u16 = undefined;
        try items.stackLimits(&stacks, &limits);
        const evicted = ownership.items.metrics.acquired.value();
        try std.testing.expectEqual(@as(u16, 16), try restored.stackLimit(held[0], replacement));
        try std.testing.expectEqual(evicted, ownership.items.metrics.acquired.value());
        _ = try restored.mergeLimit(held[0], replacement);
        try std.testing.expect(!restored.fullStack(held[0]));
        const full: inventories.Stack = .{ .item = replacement.item, .count = 16 };
        try std.testing.expect(try ownership.set(inventory_slot, previous.revision + 1, full));
        try std.testing.expect(!restored.fullStack(held[0]));
        _ = try restored.mergeLimit(held[0], full);
        try std.testing.expect(restored.fullStack(held[0]));
    };
    try output.interface.flush();
}
