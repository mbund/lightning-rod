const engine = @import("engine.zig");
const std = @import("std");

pub const FarmlandHydration = struct {
    pub const id = "minecraft:farmland_hydration";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*FarmlandHydration {
        return allocator.create(FarmlandHydration);
    }

    pub fn behavior(self: *FarmlandHydration) engine.Behavior {
        return .{ .context = self, .apply = apply };
    }

    fn apply(_: *anyopaque, tick: *engine.Invocation) void {
        engine.applyFarmlandHydration(tick);
    }
};
