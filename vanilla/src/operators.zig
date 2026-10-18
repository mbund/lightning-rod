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

        deps.commands.installPolicyIfUnset(commands.Policy.init(self, allows));

        return self;
    }

    fn allows(self: *const Operators, uuid: u128, _: *const commands.Permission) bool {
        for (self.config.operators) |operator| if (operator == uuid) return true;
        return false;
    }
};
