const engine = @import("engine.zig");
const std = @import("std");

pub const LeafDecay = struct {
    pub const id = "minecraft:leaf_decay";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*LeafDecay {
        return allocator.create(LeafDecay);
    }

    pub fn behavior(self: *LeafDecay) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyLeafDecay(tick);
    }
};
