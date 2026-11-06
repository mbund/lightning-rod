const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const Worlds = @import("worlds").Worlds;
const definitions = @import("vanilla_content.zig");
const spawn_module = @import("spawn.zig");
const Spawn = spawn_module.Spawn;

const Source = struct {
    extra: [8]u16 = @splat(0),
    solid: bool = true,
    fn read(self: *Source, _: std.Io, batch: chunks.Source.Batch) void {
        for (batch.requests) |*request| {
            const bytes = request.output;
            bytes[0] = 1;
            for (0..4096) |index| {
                const y = request.section.y * 16 + @as(i32, @intCast(index / 256));
                const state: u16 = if (y <= 0) (if (self.solid) game_data.registry.block_stone_default_state else 0) else if (y <= self.extra.len) self.extra[@intCast(y - 1)] else 0;
                std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], state, .little);
            }
            request.result = chunks.encoding.dense_block_bytes;
        }
    }
};
const Fixture = struct {
    store: *storage.Store,
    terrain: *chunks.Chunks,
    spawn: *Spawn,
    world: u32,

    fn init(allocator: std.mem.Allocator, path: []const u8, source: *Source) !Fixture {
        const store = try allocator.create(storage.Store);
        store.* = try storage.Store.init(allocator, std.testing.io, .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 1024 });
        errdefer store.deinit();
        const content = try definitions.prepare(allocator);
        const workspaces = try records.Workspaces.init(allocator, std.testing.io, .{});
        const registry = try allocator.create(metrics.Registry);
        registry.* = try metrics.Registry.init(allocator, std.testing.io, .{ .enabled = false });
        const worlds = try Worlds.init(allocator, .{}, .{ .storage = try store.openSpace(Worlds.id) });
        const world = try worlds.create(.{ .name = "test:world", .dimension = .{ .name = "minecraft:overworld", .minimum_section = -1, .section_count = 3, .skylight = true } });
        const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 64, .demand_sections = 0, .cache_groups = 4 }, .{ .record_workspaces = workspaces, .metrics = registry, .storage = try store.openSpace(chunks.Chunks.id) });
        terrain.setSource(chunks.Source.init(source, Source.read));
        const spawn = try Spawn.init(allocator, .{}, .{ .chunks = terrain, .blocks = content.blocks, .worlds = worlds, .dimensions = content.dimensions, .record_workspaces = workspaces, .storage = try store.openSpace(Spawn.id) });
        return .{ .store = store, .terrain = terrain, .spawn = spawn, .world = world };
    }
};

test "vanilla spawn columns distinguish fluids full faces leaves and slabs" {
    const Case = struct { states: []const u16, expected: ?i32, player_y: f64 };
    const cases = [_]Case{
        .{ .states = &.{}, .expected = 1, .player_y = 1 },
        .{ .states = &.{ game_data.registry.block_water_default_state, game_data.registry.block_water_default_state }, .expected = null, .player_y = 1 },
        .{ .states = &.{ 0, 0, 0, game_data.registry.block_oak_leaves_default_state }, .expected = 5, .player_y = 5 },
        .{ .states = &.{ 0, 0, 0, game_data.registry.block_oak_slab_default_state }, .expected = 1, .player_y = 1 },
        .{ .states = &.{ 0, 0, 0, @intCast(game_data.registry.blockStateId("minecraft:oak_slab[type=top,waterlogged=false]").?) }, .expected = 5, .player_y = 5 },
        .{ .states = &.{game_data.registry.block_white_carpet_default_state}, .expected = 1, .player_y = 2 },
        .{ .states = &.{ 0, game_data.registry.block_stone_default_state }, .expected = 3, .player_y = 3 },
        .{ .states = &.{game_data.registry.block_powder_snow_default_state}, .expected = 1, .player_y = 1 },
        .{ .states = &.{game_data.registry.block_scaffolding_default_state}, .expected = 2, .player_y = 2 },
        .{ .states = &.{game_data.registry.block_oak_fence_default_state}, .expected = 1, .player_y = 3 },
    };
    for (cases) |case| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
        var source: Source = .{};
        @memcpy(source.extra[0..case.states.len], case.states);
        const fixture = try Fixture.init(allocator, path, &source);
        defer fixture.store.deinit();
        const position = try fixture.spawn.column(fixture.world, -1, -1);
        try std.testing.expectEqual(case.expected, if (position) |point| point.y else null);
        if (position) |point| try std.testing.expectEqualDeep(chunks.Position{ .x = -1, .y = case.expected.?, .z = -1 }, point);
        try fixture.spawn.set(fixture.world, .{ .position = .{ .x = -1, .y = 1, .z = -1 }, .radius = 0 });
        const selected = try fixture.spawn.select(fixture.world, .survival, null);
        try std.testing.expectEqual(case.player_y, selected.position.y);
    }
}

test "vanilla spawn random search and imported anchor survive durable reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    var source: Source = .{};
    var expected: [16]Spawn.Result = undefined;
    {
        const fixture = try Fixture.init(allocator, path, &source);
        defer fixture.store.deinit();
        try fixture.spawn.set(fixture.world, .{ .position = .{ .x = -12, .y = 1, .z = 7 }, .angle = 37, .radius = 10 });
        for (0..5) |_| _ = try fixture.spawn.select(fixture.world, .survival, null);
        try fixture.spawn.checkpoint(try fixture.store.openSpace(Spawn.id));
        try fixture.store.waitDurable(try fixture.store.commit(1));
        try fixture.spawn.checkpoint(try fixture.store.openSpace(Spawn.id));
        try std.testing.expect(!fixture.store.hasWrites());
        for (&expected) |*position| position.* = try fixture.spawn.select(fixture.world, .survival, null);
    }
    const fixture = try Fixture.init(allocator, path, &source);
    defer fixture.store.deinit();
    try std.testing.expectEqualDeep(Spawn.Definition{ .position = .{ .x = -12, .y = 1, .z = 7 }, .angle = 37, .radius = 10 }, try fixture.spawn.get(fixture.world));
    for (expected) |position| try std.testing.expectEqualDeep(position, try fixture.spawn.select(fixture.world, .survival, null));
    const adventure = try fixture.spawn.select(fixture.world, .adventure, null);
    try std.testing.expectEqual(@as(f64, -11.5), adventure.position.x);
    try std.testing.expectEqual(@as(f64, 7.5), adventure.position.z);
}

test "void spawn fallback stops one block above the world minimum" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    var source: Source = .{ .solid = false };
    const fixture = try Fixture.init(allocator, path, &source);
    defer fixture.store.deinit();
    try fixture.spawn.set(fixture.world, .{ .position = .{ .x = 0, .y = 1, .z = 0 }, .radius = 0 });
    const position = try fixture.spawn.select(fixture.world, .survival, null);
    try std.testing.expectEqual(@as(f64, -15), position.position.y);
}

test "spawn collision offsets preserve vanilla float rounding and signed coordinate hashing" {
    const x = [_]i32{ 0, 1, -1, 5000 };
    const expected = [_][3]f64{
        .{ 0.016666680574417114, 0, -0.0833333283662796 },
        .{ 0.050000011920928955, 0, 0.25 },
        .{ 0.0833333432674408, 0, 0.25 },
        .{ -0.04999999701976776, 0, 0.050000011920928955 },
    };
    for (x, expected) |coordinate, value| try std.testing.expectEqual(value, game_data.physics_data.offset(coordinate, -5, 0.25, 0));
}
