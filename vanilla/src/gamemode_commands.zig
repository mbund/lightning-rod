const std = @import("std");
const commands = @import("commands");
const minecraft = @import("minecraft_model");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;

pub const GamemodeCommands = struct {
    pub const id = "minecraft:gamemode_commands";
    pub const Configuration = struct {};

    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        chat: *Chat,
    };

    pub const permission: commands.Permission = .{ .name = "minecraft.command.gamemode", .description = "Change player game modes" };

    const Arguments = struct {
        gamemode: minecraft.GameMode,
        target: ?[]const u8,
    };

    deps: Dependencies,
    command: u16 = 0,
    random: std.Random.DefaultPrng = .init(0),

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*GamemodeCommands {
        const self = try allocator.create(GamemodeCommands);
        self.* = .{ .deps = deps };
        const command = try deps.commands.register(self, commands.leaf(GamemodeCommands, Arguments, .{
            .name = "gamemode",
            .description = "Change your game mode or another player's game mode",
            .permission = &permission,
            .handler = execute,
            .arguments = .{ .gamemode = .{}, .target = .{ .kind = .players, .suggest = suggest } },
        }));
        self.command = command.index;
        return self;
    }

    fn execute(self: *GamemodeCommands, context: commands.Context, args: Arguments) !void {
        const players = self.deps.players;
        const sender = players.find(context.sender) orelse return error.InvalidArgument;
        const target = args.target orelse "@s";
        var selected: [256]*Players.Player = undefined;
        var count: usize = 0;
        const selector = target.len == 2 and target[0] == '@';
        if (std.mem.startsWith(u8, target, "@") and (!selector or std.mem.indexOfScalar(u8, "aspr", target[1]) == null))
            return error.InvalidArgument;

        var uuid: ?u128 = null;
        if (target.len == 36) {
            var digits: [32]u8 = undefined;
            var at: usize = 0;
            for (target, 0..) |byte, index| {
                if (index == 8 or index == 13 or index == 18 or index == 23) {
                    if (byte != '-') return error.InvalidArgument;
                } else {
                    digits[at] = byte;
                    at += 1;
                }
            }
            uuid = std.fmt.parseInt(u128, &digits, 16) catch return error.InvalidArgument;
        }

        for (players.records) |*player| {
            if (!player.inPlay()) continue;
            const matches = if (selector) switch (target[1]) {
                's' => player == sender,
                'a', 'p', 'r' => true,
                else => unreachable,
            } else if (uuid) |value| player.uuid == value else std.ascii.eqlIgnoreCase(player.name[0..player.name_len], target);
            if (!matches) continue;
            std.debug.assert(count < selected.len);
            selected[count] = player;
            count += 1;
        }
        if (count == 0) {
            context.reply("No player was found");
            return;
        }

        if (std.mem.eql(u8, target, "@p")) {
            var nearest: f64 = std.math.inf(f64);
            var chosen: usize = 0;
            for (selected[0..count], 0..) |player, index| {
                const dx = player.position.x - sender.position.x;
                const dy = player.position.y - sender.position.y;
                const dz = player.position.z - sender.position.z;
                const distance = dx * dx + dy * dy + dz * dz;
                if (distance < nearest) {
                    nearest = distance;
                    chosen = index;
                }
            }
            selected[0] = selected[chosen];
            count = 1;
        } else if (std.mem.eql(u8, target, "@r")) {
            selected[0] = selected[self.random.random().uintLessThan(usize, count)];
            count = 1;
        }

        const name = switch (args.gamemode) {
            .survival => "Survival Mode",
            .creative => "Creative Mode",
            .adventure => "Adventure Mode",
            .spectator => "Spectator Mode",
        };
        var text: [128]u8 = undefined;
        for (selected[0..count]) |player| {
            if (!players.setGameMode(player, args.gamemode)) continue;
            if (player != sender)
                self.deps.chat.system(player.handle.?, try std.fmt.bufPrint(&text, "Your game mode has been updated to {s}", .{name}));
            const feedback = if (player == sender)
                try std.fmt.bufPrint(&text, "Set own game mode to {s}", .{name})
            else
                try std.fmt.bufPrint(&text, "Set {s}'s game mode to {s}", .{ player.name[0..player.name_len], name });
            context.reply(feedback);
            var notification: [160]u8 = undefined;
            const message = try std.fmt.bufPrint(&notification, "[{s}: {s}]", .{ sender.name[0..sender.name_len], feedback });
            for (players.records) |observer| {
                const handle = observer.handle orelse continue;
                if (observer.uuid == sender.uuid or !observer.inPlay() or !self.deps.commands.allowed(observer.uuid, self.command)) continue;
                self.deps.chat.system(handle, message);
            }
        }
    }

    fn suggest(self: *GamemodeCommands, context: commands.CompletionContext, output: *commands.Suggestions) void {
        for ([_][]const u8{ "@a", "@p", "@r", "@s" }) |selector| {
            if (std.mem.startsWith(u8, selector, context.prefix)) output.add(.{ .text = selector }) catch return;
        }
        for (self.deps.players.records) |player| {
            if (!player.inPlay()) continue;
            const name = player.name[0..player.name_len];
            if (std.ascii.startsWithIgnoreCase(name, context.prefix)) output.add(.{ .text = name }) catch return;
        }
    }
};
