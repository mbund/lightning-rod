const vanilla_content = @import("vanilla_definitions").defaults;
const storage = @import("storage");
const persistent_records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const entities = @import("entities");
const inventories = @import("inventories");
const worlds = @import("worlds");
const game_data = @import("game_data");
const Items = @import("vanilla_items").items.Items;
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const Players = @import("players").players.Players;
const chunks = @import("chunks");
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const item_physics = @import("vanilla_item_entities").item_physics;
const test_levels = @import("test_levels.zig");

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
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 1, .cache_sections = 19, .cache_groups = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try persistent_records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = 4, .z = 0 };
    const reader = try terrain.client(.{ .name = "test", .sections = 2 });
    const warm = try reader.acquire(section);
    warm.release();
    const physics = try test_levels.itemPhysics(arena.allocator(), try vanilla_content.blocks(arena.allocator()), terrain, try test_levels.testWorlds(arena.allocator(), try store.openSpace("worlds")));
    const level = physics.level(0);
    const body: entities.State = .{ .uuid = 1, .kind = 1, .world = 0, .position = .{ 8, 70, 8 }, .velocity = .{ 0.1, 0, 0.1 } };
    try output.writeAll("moving items | section acquisitions | storage reads | generated sections\n");
    for ([_]usize{ 1, 64, 1024 }) |count| {
        const before = terrain.cache.metrics.acquired.value();
        const reads = terrain.cache.metrics.reads.value();
        const generated = source.generated;
        for (0..count) |index| {
            const result = try physics.step(&level, @intCast(index + 1), 1, body, false, false);
            try std.testing.expectApproxEqAbs(@as(f64, 8.1), result.body.position[0], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 69.96), result.body.position[1], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 8.1), result.body.position[2], 0.000001);
        }
        // The section is read once, then every body finds it copied.
        try std.testing.expect(terrain.cache.metrics.acquired.value() - before <= 1);
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        try std.testing.expectEqual(generated, source.generated);
        try output.print("{d:12} | {d:20} | {d:13} | {d}\n", .{ count, terrain.cache.metrics.acquired.value() - before, terrain.cache.metrics.reads.value() - reads, source.generated - generated });
    }
    try terrain.setBlock(0, .{ .x = 8, .y = 69, .z = 8 }, game_data.registry.block_stone_default_state);
    try terrain.setBlock(0, .{ .x = 9, .y = 70, .z = 8 }, game_data.registry.block_stone_default_state);
    var moving = body;
    moving.velocity[0] = 1;
    const collision = try physics.step(&level, 1, 1, moving, false, false);
    try std.testing.expect(collision.on_ground);
    try std.testing.expectApproxEqAbs(@as(f64, 8.875), collision.body.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 70), collision.body.position[1], 0.000001);
    try std.testing.expectEqual(@as(f64, 0), collision.body.velocity[0]);
    moving.position = .{ -8, 70, -8 };
    moving.velocity = .{ -0.1, 0, -0.1 };
    const negative = try physics.step(&level, 1, 1, moving, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, -8.1), negative.body.position[0], 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, -8.1), negative.body.position[2], 0.000001);
    moving.position = .{ 15.8, 70, 8 };
    moving.velocity = .{ 0.4, 0, 0 };
    const crossing = try physics.step(&level, 1, 1, moving, false, false);
    try std.testing.expectApproxEqAbs(@as(f64, 16.2), crossing.body.position[0], 0.000001);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);

    // Items lying on blocks that go fall on their own tick of four, by network id, which wireless
    // redstone relies on: until then they keep to the ground they no longer have.
    var fell_at: [4]u32 = @splat(0);
    for (&fell_at, 1..) |*fell, id| {
        const at: chunks.Position = .{ .x = 2 + @as(i32, @intCast(id)) * 2, .y = 69, .z = 3 };
        try terrain.setBlock(0, at, game_data.registry.block_stone_default_state);
        try terrain.setBlock(0, at, game_data.registry.block_air_default_state);
        var resting: entities.State = .{ .uuid = 2 + id, .kind = 1, .world = 0, .position = .{ @as(f64, @floatFromInt(at.x)) + 0.5, 70, 3.5 }, .velocity = .{ 0, 0, 0 } };
        var ground = true;
        for (1..9) |tick| {
            const result = try physics.step(&level, @intCast(id), @intCast(tick), resting, ground, false);
            resting = result.body;
            ground = result.on_ground;
            if (fell.* == 0 and resting.position[1] < 70) fell.* = @intCast(tick);
        }
        var first: u32 = 1;
        while (!item_physics.movesOnPhase(first, @intCast(id))) first += 1;
        try std.testing.expectEqual(first, fell.*);
    }
    for (fell_at, 0..) |a, i| for (fell_at[i + 1 ..]) |b| try std.testing.expect(a != b);

    for ([_]u16{ game_data.registry.block_air_default_state, game_data.registry.block_water_default_state, game_data.registry.block_stone_default_state, std.math.maxInt(u16) }, 0..) |state, index| {
        source.state = state;
        const uniform_section: chunks.Section = .{ .world = 0, .x = @intCast(4 + index * 2), .y = 4, .z = 0 };
        const dense_section: chunks.Section = .{ .world = 0, .x = uniform_section.x + 1, .y = 4, .z = 0 };
        try terrain.setBlocks(dense_section, &.{.{ .index = 0, .state = if (state == 0) game_data.registry.block_stone_default_state else 0 }});
        var edits: [4096]chunks.BlockEdit = undefined;
        for (&edits, 0..) |*edit, at| edit.* = .{ .index = @intCast(at), .state = state };
        try terrain.setBlocks(dense_section, &edits);
        const uniform = try reader.acquire(uniform_section);
        const dense = try reader.acquire(dense_section);
        try std.testing.expect(uniform.view() == .uniform and dense.view() == .uniform);
        uniform.release();
        dense.release();

        var falling = body;
        falling.position = .{ @as(f64, @floatFromInt(uniform_section.x * 16)) + 8, 80.01, 8 };
        falling.velocity[1] = -0.1;
        var translated = falling;
        translated.position[0] += 16;
        if (state == std.math.maxInt(u16)) {
            try std.testing.expectError(error.Corrupt, physics.step(&level, 1, 1, falling, false, false));
            try std.testing.expectError(error.Corrupt, physics.step(&level, 1, 1, translated, false, false));
            continue;
        }
        const compact = try physics.step(&level, 1, 1, falling, false, false);
        const expanded = try physics.step(&level, 1, 1, translated, false, false);
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

test "item physics reads its blocks once and keeps collision resolution" {
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
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 1), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].position = records[0].position;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 3), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].position.z += 16;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 1), nearbyMask(players.nearby(0, records[0].position, 0)));
    records[1].world = 1;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].stage = .awaiting_teleport;
    records[0].handle = null;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 32)));
    records[1].configuring = true;
    records[1].stage = .login;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].configuring = false;
    records[1].stage = .ready;
    try players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 2), nearbyMask(players.nearby(1, records[1].position, 0)));
    records[1].handle = null;
    try players.rebuildIndexes();
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
    const gameplay_definitions = try vanilla_content.prepare(arena.allocator());
    const items = try Items.init(arena.allocator(), .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
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

/// The items the space has in a column of x, at z 0, as they entered it.
fn inColumn(dropped: *ItemEntities, world: u32, x: i32, output: []entities.Id) !usize {
    var buffer: [4]entities.space.Entry = undefined;
    var ordered = dropped.places.space.ordered(.{ .world = world, .x = x, .z = 0 }, std.math.minInt(i32), std.math.maxInt(i32), ItemEntities.kinds, &buffer);
    var count: usize = 0;
    while (true) {
        const entries = try ordered.next();
        if (entries.len == 0) return count;
        for (entries) |entry| {
            output[count] = entry.id;
            count += 1;
        }
    }
}

test "items read by id see earlier writes, moves and retirement" {
    {
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
        const gameplay_definitions = try vanilla_content.prepare(allocator);
        const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.init(allocator, io, .{}, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try transaction.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{}, .{
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
        try players.rebuildIndexes();
        // The area index holds where each is: both start in column 0.
        var found: [4]entities.Id = undefined;
        try std.testing.expectEqualSlices(entities.Id, &.{ first, second }, found[0..try inColumn(dropped, world, 0, &found)]);
        {
            var metadata = try dropped.get(second);
            metadata.age = 77;
            try dropped.put(second, metadata);
            try std.testing.expectEqual(@as(i32, 77), (try dropped.read(second)).?.metadata.age);
            const was = (try dropped.read(second)).?.body;
            var body = was;
            body.position[0] = 32;
            try dropped.move(second, was, body);
            try std.testing.expectEqual(@as(f64, 32), (try dropped.read(second)).?.body.position[0]);
            try std.testing.expectEqualSlices(entities.Id, &.{first}, found[0..try inColumn(dropped, world, 0, &found)]);
            try std.testing.expectEqualSlices(entities.Id, &.{second}, found[0..try inColumn(dropped, world, 2, &found)]);
            const slot = ItemEntities.slot(body);
            const held = try ownership.get(slot);
            try std.testing.expect(try ownership.set(slot, held.revision, null));
            try dropped.retire(second, body, &metadata);
            try std.testing.expect(!(try dropped.get(second)).alive);
            try std.testing.expect((try bodies.getById(second)) == null);
        }
        // Retired, it is gone from its column; one made there takes its place.
        try std.testing.expectEqual(@as(usize, 0), try inColumn(dropped, world, 2, &found));
        const replacement = try dropped.create(world, .{ 32, 65, 0 }, @splat(0), stack);
        try std.testing.expectEqualSlices(entities.Id, &.{replacement}, found[0..try inColumn(dropped, world, 2, &found)]);
    }
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
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 1, .cache_sections = 19, .cache_groups = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try persistent_records.Workspaces.init(arena.allocator(), io, .{}),
    });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    const physics = try test_levels.itemPhysics(arena.allocator(), try vanilla_content.blocks(arena.allocator()), terrain, try test_levels.testWorlds(arena.allocator(), try store.openSpace("worlds")));
    const level = physics.level(0);
    const body: entities.State = .{ .uuid = 1, .kind = 1, .world = 0, .position = .{ 15.875, 65, 8 }, .velocity = .{ 0.1, 0, 0.1 } };
    // The first step copies the four sections about the item; every step after finds them copied.
    _ = try physics.step(&level, 1, 1, body, true, false);
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("moving items | section acquisitions | acquisition batches | storage reads\n");
    for ([_]usize{ 1, 64, 1024 }) |count| {
        const before = terrain.cache.metrics.acquired.value();
        const batches = terrain.cache.metrics.batches.value();
        const reads = terrain.cache.metrics.reads.value();
        const generated = source.generated;
        for (0..count) |at| {
            const result = try physics.step(&level, @intCast(at + 1), 1, body, true, false);
            try std.testing.expect(result.on_ground);
            try std.testing.expectApproxEqAbs(@as(f64, 15.975), result.body.position[0], 0.000001);
            try std.testing.expectApproxEqAbs(@as(f64, 65), result.body.position[1], 0.000001);
        }
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        try std.testing.expectEqual(generated, source.generated);
        const acquired = terrain.cache.metrics.acquired.value() - before;
        const calls = terrain.cache.metrics.batches.value() - batches;
        try std.testing.expectEqual(@as(u64, 0), acquired);
        try std.testing.expectEqual(@as(u64, 0), calls);
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
