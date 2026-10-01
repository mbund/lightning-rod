const std = @import("std");
const commands = @import("commands");
const Players = @import("players.zig").Players;

pub const TeleportCommands = struct {
    pub const id = "minecraft:teleport_commands";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
    };

    pub const permission: commands.Permission = .{ .name = "minecraft.command.teleport", .description = "Teleport players" };

    const Arguments = struct {
        player: u128,
        destination: ?u128,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*TeleportCommands {
        const self = try allocator.create(TeleportCommands);
        self.* = .{ .deps = deps };

        inline for (.{ "tp", "teleport" }) |name| _ = try deps.commands.register(self, commands.leaf(TeleportCommands, Arguments, .{
            .name = name,
            .description = "Teleport yourself to a player, or one player to another",
            .permission = &permission,
            .handler = execute,
            .arguments = .{ .player = .{ .parse = parse, .suggest = suggest }, .destination = .{ .parse = parse, .suggest = suggest } },
        }));
        return self;
    }

    fn execute(self: *TeleportCommands, context: commands.Context, args: Arguments) !void {
        const source = self.deps.players.find(args.player) orelse return error.InvalidArgument;
        const target = self.deps.players.find(args.destination orelse args.player) orelse return error.InvalidArgument;
        const moved = if (args.destination != null) source else self.deps.players.find(context.sender) orelse return error.InvalidArgument;
        self.deps.players.teleport(moved, target.world, target.position, target.rotation) catch {
            context.reply("Teleport unavailable while the player is joining or changing worlds.");
            return;
        };
        var text: [96]u8 = undefined;
        context.reply(try std.fmt.bufPrint(&text, "Teleported {s} to {s}", .{ moved.name[0..moved.name_len], target.name[0..target.name_len] }));
    }

    fn parse(self: *TeleportCommands, _: commands.Context, name: []const u8) commands.ParseError!u128 {
        for (self.deps.players.records) |player|
            if (player.inPlay() and std.ascii.eqlIgnoreCase(player.name[0..player.name_len], name)) return player.uuid;
        return error.InvalidArgument;
    }

    fn suggest(self: *TeleportCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        for (self.deps.players.records) |player| {
            if (!player.inPlay()) continue;

            const name = player.name[0..player.name_len];
            if (std.ascii.startsWithIgnoreCase(name, context.prefix)) output.add(.{ .text = name }) catch return;
        }
    }
};
