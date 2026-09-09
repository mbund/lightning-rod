const engine = @import("engine.zig");
const std = @import("std");

pub const FireAndLava = struct {
    pub const id = "minecraft:fire_and_lava";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*FireAndLava {
        return allocator.create(FireAndLava);
    }

    pub fn behavior(self: *FireAndLava) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyFireAndLava(tick);
    }
};
