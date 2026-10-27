const storage = @import("storage");
const persistent_records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const entities = @import("entities");
const inventories = @import("inventories");
const worlds = @import("worlds");
const game_data = @import("game_data");
const Items = @import("items.zig").Items;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Players = @import("players.zig").Players;
const chunks = @import("chunks");
const ItemPhysics = @import("item_physics.zig").ItemPhysics;

fn itemPhysicsProbe(output: *std.Io.Writer) !void {
    const Source = struct {
        generated: usize = 0,
        state: u16 = game_data.registry.block_air_default_state,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.generated += 1;
                request.result = chunks.uniform(if (request.section.y == 4) self.state else game_data.registry.block_air_default_state, request.output);
            }
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/physics", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 8, .demand_sections = 0, .cache_tiles = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try persistent_records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = 4, .z = 0 };
    const warm = try terrain.acquire(section);
    warm.release();
    var physics: ItemPhysics = .{ .deps = .{ .chunks = terrain } };
    const body: entities.State = .{ .uuid = 1, .kind = 1, .world = 0, .position = .{ 8, 70, 8 }, .velocity = .{ 0.1, 0, 0.1 } };
    try output.writeAll("moving items | section acquisitions | storage reads | generated sections\n");
    for ([_]usize{ 1, 64, 1024 }) |count| {
        const before = terrain.cache.metrics.acquired.value();
        const reads = terrain.cache.metrics.reads.value();
        const generated = source.generated;
        var neighborhood = physics.readWindow();
        defer neighborhood.deinit();
        for (0..count) |index| {
            const result = try physics.advance(&neighborhood, @intCast(index + 1), 1, body, false);
            try std.testing.expectApproxEqAbs(@as(f64, 8.1), result.body.position[0], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 69.96), result.body.position[1], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 8.1), result.body.position[2], 0.000001);
        }
        try std.testing.expectEqual(@as(u64, 1), terrain.cache.metrics.acquired.value() - before);
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        try std.testing.expectEqual(generated, source.generated);
        try output.print("{d:12} | {d:20} | {d:13} | {d}\n", .{ count, terrain.cache.metrics.acquired.value() - before, terrain.cache.metrics.reads.value() - reads, source.generated - generated });
    }
    try terrain.setBlock(0, .{ .x = 8, .y = 69, .z = 8 }, game_data.registry.block_stone_default_state);
    try terrain.setBlock(0, .{ .x = 9, .y = 70, .z = 8 }, game_data.registry.block_stone_default_state);
    var neighborhood = physics.readWindow();
    defer neighborhood.deinit();
    var moving = body;
    moving.velocity[0] = 1;
    const collision = try physics.advance(&neighborhood, 1, 1, moving, false);
    try std.testing.expect(collision.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 8.875), collision.body.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 70), collision.body.position[1], 0.000001);
    try std.testing.expectEqual(@as(f64, 0), collision.body.velocity[0]);
    moving.position = .{ -8, 70, -8 };
    moving.velocity = .{ -0.1, 0, -0.1 };
    const negative = try physics.advance(&neighborhood, 1, 1, moving, false);
    try std.testing.expectApproxEqAbs(@as(f64, -8.1), negative.body.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, -8.1), negative.body.position[2], 0.000001);
    moving.position = .{ 15.8, 70, 8 };
    moving.velocity = .{ 0.4, 0, 0 };
    const crossing = try physics.advance(&neighborhood, 1, 1, moving, false);
    try std.testing.expectApproxEqAbs(@as(f64, 16.2), crossing.body.position[0], 0.000001);
    neighborhood.deinit();
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);

    for ([_]u16{ game_data.registry.block_air_default_state, game_data.registry.block_water_default_state, game_data.registry.block_stone_default_state, std.math.maxInt(u16) }, 0..) |state, index| {
        source.state = state;
        const uniform_section: chunks.Section = .{ .world = 0, .x = @intCast(4 + index * 2), .y = 4, .z = 0 };
        const dense_section: chunks.Section = .{ .world = 0, .x = uniform_section.x + 1, .y = 4, .z = 0 };
        try terrain.setBlocks(dense_section, &.{.{ .index = 0, .state = if (state == 0) game_data.registry.block_stone_default_state else 0 }});
        var edits: [4096]chunks.BlockEdit = undefined;
        for (&edits, 0..) |*edit, at| edit.* = .{ .index = @intCast(at), .state = state };
        try terrain.setBlocks(dense_section, &edits);
        const uniform = try terrain.acquire(uniform_section);
        const dense = try terrain.acquire(dense_section);
        try std.testing.expect(uniform.view() == .uniform and dense.view() == .dense);
        uniform.release();
        dense.release();

        var uniform_window = physics.readWindow();
        defer uniform_window.deinit();
        var dense_window = physics.readWindow();
        defer dense_window.deinit();
        var falling = body;
        falling.position = .{ @as(f64, @floatFromInt(uniform_section.x * 16)) + 8, 80.01, 8 };
        falling.velocity[1] = -0.1;
        var translated = falling;
        translated.position[0] += 16;
        if (state == std.math.maxInt(u16)) {
            try std.testing.expectError(error.Corrupt, physics.advance(&uniform_window, 1, 1, falling, false));
            try std.testing.expectError(error.Corrupt, physics.advance(&dense_window, 1, 1, translated, false));
            continue;
        }
        const compact = try physics.advance(&uniform_window, 1, 1, falling, false);
        const expanded = try physics.advance(&dense_window, 1, 1, translated, false);
        for (compact.body.position, expanded.body.position, 0..) |first, second, axis| try std.testing.expectApproxEqAbs(first, second - @as(f64, if (axis == 0) 16 else 0), 0.000000001);
        try std.testing.expectEqualSlices(f64, &compact.body.velocity, &expanded.body.velocity);
        try std.testing.expectEqual(compact.crossed_block, expanded.crossed_block);
        try std.testing.expectEqual(compact.on_ground, expanded.on_ground);
        try std.testing.expectEqual(state == game_data.registry.block_stone_default_state, compact.on_ground);
    }
}

pub fn benchmarkItemPhysics() !void {
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try itemPhysicsProbe(&output.interface);
    try output.interface.flush();
}

test "item physics reuses its neighborhood across axes and preserves collision resolution" {
    var buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&buffer);
    try itemPhysicsProbe(&output.writer);
}

test "spatial refresh retains configuring players and follows movement and disconnect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var records: [3]Players.Player = @splat(.{});
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    records[0] = .{ .handle = .{ .index = 0, .generation = 1 }, .stage = .ready };
    records[1] = .{ .handle = .{ .index = 1, .generation = 1 }, .stage = .ready, .position = .{ .x = -32, .y = 65, .z = 0 } };
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 1), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].position = records[0].position;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 3), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].position.z += 16;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 1), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].world = 1;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].stage = .awaiting_teleport;
    records[0].handle = null;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 32)));
    records[1].configuring = true;
    records[1].stage = .login;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].configuring = false;
    records[1].stage = .ready;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].handle = null;
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 0), nearbyMask(players.nearby(1, records[1].position, 32)));
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
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const ownership = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_items = 2, .max_item_bytes = 1024 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("inventory"), .record_workspaces = try persistent_records.Workspaces.init(arena.allocator(), io, .{}) });
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
    const tool: inventories.Stack = .{ .item = try items.define("minecraft:iron_pickaxe"), .count = 1 };
    const definitions = ownership.items.metrics.acquired.value();
    var limits: [6]u16 = undefined;
    try items.stackLimits(&.{ apple, tool, bread, tool, stone, bread }, &limits);
    try std.testing.expectEqualSlices(u16, &.{ 64, 1, 64, 1, 64, 64 }, &limits);
    try std.testing.expectEqual(@as(u64, 4), ownership.items.metrics.acquired.value() - definitions);
    const changed = try ownership.acquireItem(bread.item);
    const length = changed.read().?.len;
    changed.edit()[0] ^= 1;
    changed.commit(length);
    changed.release();
    try std.testing.expectError(error.Corrupt, items.acquire(bread));
    var invalid_limits: [3]u16 = undefined;
    try std.testing.expectError(error.Corrupt, items.stackLimits(&.{ stone, bread, apple }, &invalid_limits));
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
        const workspaces = try persistent_records.Workspaces.init(allocator, io, .{});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        const transaction = store.transaction();
        defer transaction.fail();
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_items = 2, .cache_slots = 8, .max_item_bytes = 1024 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("inventory"), .record_workspaces = workspaces });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = cache_records / 2 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try transaction.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = cache_records, .maximum = 4 }, .{
            .metrics = &metric_registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try transaction.openSpace("metadata"),
        });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const first = try dropped.create(world, .{ 0, 65, 0 }, @splat(0), stack);
        const second = try dropped.create(world, .{ 1, 65, 0 }, @splat(0), stack);
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .stage = .ready, .world = world, .position = .{ .x = 0, .y = 65, .z = 0 } }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        var query = try ItemEntities.Query.init(allocator, dropped, &players);
        var other_query = try ItemEntities.Query.init(allocator, dropped, &players);
        const selected = query.read(0);
        try std.testing.expectEqualSlices(entities.Id, &.{ first, second }, selected);
        _ = other_query.read(2);
        const rebuilds = query.rebuilds.value();
        player_records[0].position.x = 0.25;
        for (0..64) |_| {
            try std.testing.expectEqualSlices(entities.Id, &.{ first, second }, query.read(0));
            _ = other_query.read(2);
        }
        try std.testing.expectEqual(rebuilds, query.rebuilds.value());
        try std.testing.expectEqualSlices(entities.Id, &.{ first, second }, selected);
        player_records[0].world = world + 1;
        try std.testing.expectEqual(@as(usize, 0), query.read(0).len);
        player_records[0].world = world;
        const connected = player_records[0].handle;
        player_records[0].handle = null;
        try std.testing.expectEqual(@as(usize, 0), query.read(0).len);
        player_records[0].handle = connected;
        try std.testing.expectEqualSlices(entities.Id, &.{ first, second }, query.read(0));
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
            const unchanged = query.rebuilds.value();
            try dropped.put(second, metadata);
            _ = query.read(0);
            try std.testing.expectEqual(unchanged, query.rebuilds.value());
            try std.testing.expectEqual(@as(i32, 77), (try partner.read()).age);
            var body = (try partner.body.read()).?;
            body.position[0] = 32;
            try dropped.move(partner, (try partner.body.read()).?, body);
            try std.testing.expectEqual(@as(f64, 32), (try partner.body.read()).?.position[0]);
            const first_view = query.read(0);
            try std.testing.expectEqualSlices(entities.Id, &.{first}, first_view);
            player_records[0].position.x = 32;
            try std.testing.expectEqualSlices(entities.Id, &.{second}, other_query.read(0));
            try std.testing.expectEqualSlices(entities.Id, &.{first}, first_view);
            try std.testing.expectEqualSlices(entities.Id, &.{second}, query.read(0));
            const slot = ItemEntities.slot(body);
            const held = try ownership.get(slot);
            try std.testing.expect(try ownership.set(slot, held.revision, null));
            try dropped.retire(second, body, &metadata);
            try std.testing.expect(!(try partner.read()).alive);
            try std.testing.expect(try partner.body.read() == null);
        }
        iterator.deinit();
        const replacement = try dropped.create(world, .{ 32, 65, 0 }, @splat(0), stack);
        try std.testing.expectEqualSlices(entities.Id, &.{replacement}, query.read(0));
        player_records[0].position.x = 0;
        try std.testing.expectEqualSlices(entities.Id, &.{ first, replacement }, query.read(2));
        for (dropped.cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
        for (bodies.cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
    }
}

pub fn benchmarkItemQueries() !void {
    const io = std.testing.io;
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("items | query reads | spatial rebuilds | unchanged rebuilds\n");
    for ([_]usize{ 1024, 8192 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/queries", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
        defer registry.deinit();
        const workspaces = try persistent_records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.allocate(allocator, io, .{ .cache_slots = 2, .cache_items = 1, .max_item_bytes = 64 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.allocate(allocator, io, .{ .cache_records = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
        const dropped = try ItemEntities.allocate(allocator, io, .{ .cache_records = 4, .maximum = count }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        const expected = try allocator.alloc(entities.Id, count);
        const nearby = try allocator.alloc(entities.Id, count);
        var nearby_count: usize = 0;
        var random = std.Random.DefaultPrng.init(20261025);
        for (dropped.residents, expected, 0..) |*resident, *id, index| {
            resident.* = .{ .id = index + 1, .world = 0, .x = random.random().intRangeAtMost(i32, -8, 8), .z = random.random().intRangeAtMost(i32, -8, 8), .y = 4, .alive = true };
            dropped.spatial.insert(@intCast(index));
            dropped.ids.putAssumeCapacityNoClobber(resident.id, @intCast(index));
            id.* = resident.id;
            if (@abs(resident.x) <= 1 and @abs(resident.z) <= 1) {
                nearby[nearby_count] = resident.id;
                nearby_count += 1;
            }
        }
        dropped.free_count = 0;
        var rows = [_]Players.Player{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = 0, .position = .{ .x = 8, .y = 65, .z = 8 } }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &rows, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        var simulation = try ItemEntities.Query.init(allocator, dropped, &players);
        var pickup = try ItemEntities.Query.init(allocator, dropped, &players);
        failing.fail_index = failing.alloc_index;
        const initial = simulation.rebuilds.value();
        for (0..20) |_| {
            try std.testing.expectEqualSlices(entities.Id, expected, simulation.read(8));
            try std.testing.expectEqualSlices(entities.Id, nearby[0..nearby_count], pickup.read(1));
        }
        const rebuilt = simulation.rebuilds.value() - initial;
        try std.testing.expectEqual(@as(u64, 2), rebuilt);
        const warm = simulation.rebuilds.value();
        for (0..20) |_| {
            _ = simulation.read(8);
            _ = pickup.read(1);
        }
        const unchanged = simulation.rebuilds.value() - warm;
        try std.testing.expectEqual(@as(u64, 0), unchanged);
        try output.interface.print("{d:5} | {d:11} | {d:16} | {d}\n", .{ count, 40, rebuilt, unchanged });
    }
    try output.interface.flush();
}

pub fn benchmarkItemPhysicsWindow() !void {
    const Source = struct {
        generated: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.generated += 1;
                if (request.section.y == 4) {
                    request.output[0] = 1;
                    for (0..4096) |at| std.mem.writeInt(u16, request.output[1 + at * 2 ..][0..2], if (at < 256) game_data.registry.block_stone_default_state else 0, .little);
                    request.result = 8193;
                } else request.result = chunks.uniform(if (request.section.y < 4) game_data.registry.block_stone_default_state else 0, request.output);
            }
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/physics", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 8, .demand_sections = 0, .cache_tiles = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try persistent_records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    var physics: ItemPhysics = .{ .deps = .{ .chunks = terrain } };
    const body: entities.State = .{ .uuid = 1, .kind = 1, .world = 0, .position = .{ 15.875, 65, 8 }, .velocity = .{ 0.1, 0, 0.1 } };
    {
        var window = physics.readWindow();
        defer window.deinit();
        _ = try physics.advance(&window, 1, 1, body, true);
    }
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("moving items | section acquisitions | acquisition batches | storage reads\n");
    for ([_]usize{ 1, 64, 1024 }) |count| {
        const before = terrain.cache.metrics.acquired.value();
        const batches = terrain.cache.metrics.acquisition.read().?.count;
        const reads = terrain.cache.metrics.reads.value();
        const generated = source.generated;
        var window = physics.readWindow();
        for (0..count) |at| {
            const result = try physics.advance(&window, @intCast(at + 1), 1, body, true);
            try std.testing.expect(result.on_ground);
            try std.testing.expectApproxEqAbs(@as(f64, 15.975), result.body.position[0], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 65), result.body.position[1], 0.000001);
        }
        window.deinit();
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        try std.testing.expectEqual(generated, source.generated);
        const acquired = terrain.cache.metrics.acquired.value() - before;
        const calls = terrain.cache.metrics.acquisition.read().?.count - batches;
        try std.testing.expectEqual(@as(u64, 4), acquired);
        try std.testing.expectEqual(@as(u64, 1), calls);
        try output.interface.print("{d:12} | {d:20} | {d:19} | 0\n", .{ count, acquired, calls });
    }
    try output.interface.flush();
}

fn nearbyMask(query: Players.Nearby) usize {
    var iterator = query;
    var mask: usize = 0;
    while (iterator.next()) |index| mask |= @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(index));
    return mask;
}
