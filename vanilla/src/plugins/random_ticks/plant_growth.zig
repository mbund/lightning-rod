const engine = @import("engine.zig");
const std = @import("std");

pub const PlantGrowth = struct {
    pub const id = "minecraft:plant_growth";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*PlantGrowth {
        return allocator.create(PlantGrowth);
    }

    pub fn behavior(self: *PlantGrowth) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyPlantGrowth(tick);
    }
};
