const engine = @import("engine.zig");
const std = @import("std");

pub const PlantSpread = struct {
    pub const id = "minecraft:plant_spread";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*PlantSpread {
        return allocator.create(PlantSpread);
    }

    pub fn behavior(self: *PlantSpread) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) engine.FatalError!void {
        try engine.applyPlantSpread(tick);
    }
};
