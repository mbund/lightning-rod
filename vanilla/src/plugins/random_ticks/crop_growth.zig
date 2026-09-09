const engine = @import("engine.zig");
const std = @import("std");

pub const CropGrowth = struct {
    pub const id = "minecraft:crop_growth";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*CropGrowth {
        return allocator.create(CropGrowth);
    }

    pub fn behavior(self: *CropGrowth) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyCropGrowth(tick);
    }
};
