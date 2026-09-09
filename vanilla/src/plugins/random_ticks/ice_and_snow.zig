const engine = @import("engine.zig");
const std = @import("std");

pub const IceAndSnow = struct {
    pub const id = "minecraft:ice_and_snow";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*IceAndSnow {
        return allocator.create(IceAndSnow);
    }

    pub fn behavior(self: *IceAndSnow) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyIceAndSnow(tick);
    }
};
