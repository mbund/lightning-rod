const std = @import("std");
const density = @import("density.zig");
const engine = @import("surface_engine.zig");
const program = @import("surface_program.zig");

pub const Engine = engine.Engine;
const Overworld = Engine(program.data, density);
pub const state_count = Overworld.state_count;
pub const Context = Overworld.Context;
pub const Result = Overworld.Result;
pub const Iceberg = Overworld.Iceberg;
pub const Sampler = Overworld.Sampler;
pub const stateName = Overworld.stateName;
pub const canonicalStateId = Overworld.canonicalStateId;
pub const isLogOrLeaves = Overworld.isLogOrLeaves;
pub const stateIndex = Overworld.stateIndex;
pub const stateCount = Overworld.stateCount;
pub const biomeMask = Overworld.biomeMask;

test "surface program applies deterministic bedrock floor" {
    var sampler = try Sampler.init(std.testing.allocator, 0);
    defer sampler.deinit();
    const context: Context = .{
        .position = .{ .x = 0, .y = -64, .z = 0 },
        .biome_mask = biomeMask("minecraft:plains"),
        .run_depth = sampler.runDepth(0, 0),
        .surface_noise = sampler.surfaceNoise(0, 0),
        .secondary_depth = sampler.secondaryDepth(0, 0),
        .fluid_height = std.math.minInt(i32),
        .stone_depth_above = 1,
        .stone_depth_below = 10,
        .preliminary_surface = 60,
        .temperature = 0.8,
        .frozen = false,
        .steep = false,
    };
    const result = sampler.apply(&context).?;
    try std.testing.expectEqualStrings("minecraft:bedrock", stateName(result.state));
}
