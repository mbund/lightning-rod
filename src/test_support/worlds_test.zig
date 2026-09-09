const std = @import("std");
const dimensions = @import("../world/dimensions.zig");
const generation = @import("../world/generation.zig");
const worlds = @import("../world/worlds.zig");

const TestGeneration = generation.Registry(.{
    generation.Flat{},
    generation.Void{},
});

const initial = [_]worlds.Description{.{
    .key = .{ .value = 1 },
    .name = "test:initial",
    .dimension = dimensions.Vanilla.dimensionId(dimensions.Overworld),
    .generator = TestGeneration.generatorId(generation.Flat),
    .seed = 1,
    .spawn_x = 0,
    .spawn_y = 64,
    .spawn_z = 0,
}};

test "dynamic world slots reject stale handles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state = try worlds.Worlds.init(arena.allocator(), .{ .initial = &initial });
    _ = try dimensions.Vanilla.init(arena.allocator(), .{ .worlds = state }, .{});
    const island = try state.add(.{
        .key = .{ .value = 2 },
        .name = "test:island",
        .dimension = dimensions.Vanilla.dimensionId(dimensions.Overworld),
        .generator = TestGeneration.generatorId(generation.Void),
        .seed = 2,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    });
    try std.testing.expectEqualStrings("test:island", state.getConst(island).?.nameSlice());
    try std.testing.expectError(error.DuplicateWorldName, state.add(.{
        .key = .{ .value = 4 },
        .name = "test:island",
        .dimension = dimensions.Vanilla.dimensionId(dimensions.Nether),
        .generator = TestGeneration.generatorId(generation.Void),
        .seed = 4,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }));
    try state.destroy(island);
    try std.testing.expect(state.get(island) == null);
    const replacement = try state.add(.{
        .key = .{ .value = 3 },
        .name = "test:replacement",
        .dimension = dimensions.Vanilla.dimensionId(dimensions.Overworld),
        .generator = TestGeneration.generatorId(generation.Void),
        .seed = 3,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    });
    try std.testing.expectEqual(island.index, replacement.index);
    try std.testing.expect(island.generation != replacement.generation);
}
