const engine = @import("engine.zig");
const std = @import("std");

pub const RandomBlockEvents = struct {
    pub const id = "minecraft:random_block_events";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*RandomBlockEvents {
        return allocator.create(RandomBlockEvents);
    }

    pub fn behavior(self: *RandomBlockEvents) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) engine.FatalError!void {
        try engine.applyRandomBlockEvents(tick);
    }
};
