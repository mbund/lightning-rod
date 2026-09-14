const std = @import("std");
const commands = @import("commands");

pub const Operators = struct {
    pub const id = "minecraft:operators";

    pub const Configuration = struct { operators: []const u128 = &.{} };

    pub const Dependencies = struct { commands: *commands.Commands };

    config: Configuration,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Operators {
        const self = try allocator.create(Operators);
        self.* = .{ .config = config };

        if (deps.commands.deps.permission_policy == null) deps.commands.deps.permission_policy = .{ .context = self, .allows = allows };

        return self;
    }

    fn allows(context: *anyopaque, uuid: u128, _: *const commands.Permission) bool {
        const self: *const Operators = @ptrCast(@alignCast(context));

        for (self.config.operators) |operator| if (operator == uuid) return true;
        return false;
    }
};
