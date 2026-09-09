const engine = @import("engine.zig");
const std = @import("std");

pub const CopperWeathering = struct {
    pub const id = "minecraft:copper_weathering";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*CopperWeathering {
        return allocator.create(CopperWeathering);
    }

    pub fn behavior(self: *CopperWeathering) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) engine.FatalError!void {
        try engine.applyCopperWeathering(tick);
    }
};
