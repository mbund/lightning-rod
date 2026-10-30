const vanilla_content = @import("vanilla_content.zig");
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
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 4, .demand_sections = 0, .cache_tiles = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        terrain.setSource(chunks.Source.init(&source, Source.read));
        const physics = try ItemPhysics.init(allocator, .{ .blocks = gameplay_definitions.blocks, .chunks = terrain });
        const merging = try ItemMerging.init(allocator);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const tick = try tick_module.ItemTick.init(allocator, .{}, .{ .dropped = dropped, .physics = physics, .merging = merging, .pickup = undefined, .players = &players, .entities = bodies, .inventories = ownership, .items = items, .worlds = dimensions });
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
