const std = @import("std");
const commands = @import("commands.zig");
const players_package = @import("players");
const Players = players_package.players.Players;
const chat_package = @import("chat");
const PlayerChat = chat_package.player_chat.PlayerChat;
const component = chat_package.component;
const assert = std.debug.assert;

/// Vanilla's commands that send chat: private messages, emotes and announcements. Each sends the
/// message its sender signed, under the chat type vanilla gives it, so it stays as secure as chat.
pub const ChatCommands = struct {
    pub const id = "minecraft:chat_commands";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        commands: *commands.Commands,
        players: *Players,
        player_chat: *PlayerChat,
    };

    pub const say_permission: commands.Permission = .{ .name = "minecraft.command.say", .description = "Announce a message to every player" };

    const Private = struct { targets: []const u8, message: []const u8 };
    const Message = struct { message: []const u8 };
    const Action = struct { action: []const u8 };

    deps: Dependencies,
    selected: []usize,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ChatCommands {
        const self = try allocator.create(ChatCommands);
        self.* = .{ .deps = deps, .selected = try allocator.alloc(usize, deps.players.records.len) };
        // Vanilla's msg, and tell and w, which redirect to it.
        inline for (.{ "msg", "tell", "w" }) |name| {
            _ = try deps.commands.register(self, commands.leaf(ChatCommands, Private, .{
                .name = name,
                .description = "Send a private message to players",
                .handler = private,
                .arguments = .{ .targets = .{ .kind = .players }, .message = .{ .kind = .message } },
            }));
        }
        _ = try deps.commands.register(self, commands.leaf(ChatCommands, Action, .{
            .name = "me",
            .description = "Describe what you are doing",
            .handler = emote,
            .arguments = .{ .action = .{ .kind = .message } },
        }));
        _ = try deps.commands.register(self, commands.leaf(ChatCommands, Message, .{
            .name = "say",
            .description = "Announce a message to every player",
            .permission = &say_permission,
            .handler = say,
            .arguments = .{ .message = .{ .kind = .message } },
        }));
        return self;
    }

    fn private(self: *ChatCommands, context: commands.Context, args: Private) !void {
        const signed = self.deps.player_chat.commandMessage("message") orelse return error.InvalidArgument;
        const sender = self.deps.players.find(context.sender) orelse return error.InvalidArgument;
        const sender_slot = sender.handle.?.index;
        const count = self.select(sender, args.targets) orelse return error.InvalidArgument;
        assert(count <= self.selected.len);
        if (count == 0) {
            context.reply("No player was found");
            return;
        }
        for (self.selected[0..count]) |slot| {
            const target = &self.deps.players.records[slot];
            var name: [64]u8 = undefined;
            // A string tag, its length and the name.
            comptime assert(3 + @typeInfo(@FieldType(Players.Player, "name")).array.len <= name.len);
            const target_name = component.plain(&name, target.name[0..target.name_len]) catch unreachable;
            // The sender sees whom they whispered to; the target sees who whispered.
            if (!self.deps.player_chat.sendCommandMessage(signed, .msg_outgoing, &.{sender_slot}, target_name) or
                !self.deps.player_chat.sendCommandMessage(signed, .msg_incoming, &.{slot}, null))
            {
                context.reply("The message could not be sent; try again.");
                return;
            }
        }
    }

    fn emote(self: *ChatCommands, context: commands.Context, _: Action) !void {
        const signed = self.deps.player_chat.commandMessage("action") orelse return error.InvalidArgument;
        if (!self.deps.player_chat.sendCommandMessage(signed, .emote, null, null)) context.reply("The message could not be sent; try again.");
    }

    fn say(self: *ChatCommands, context: commands.Context, _: Message) !void {
        const signed = self.deps.player_chat.commandMessage("message") orelse return error.InvalidArgument;
        if (!self.deps.player_chat.sendCommandMessage(signed, .say, null, null)) context.reply("The message could not be sent; try again.");
    }

    /// The players a target names: one by name, @s the sender, @a everyone in play, @p the
    /// nearest to the sender and @r any one. Null for a target no player could match.
    fn select(self: *ChatCommands, sender: *const Players.Player, target: []const u8) ?usize {
        const selector = target.len == 2 and target[0] == '@';
        if (target.len > 0 and target[0] == '@' and (!selector or std.mem.indexOfScalar(u8, "aspr", target[1]) == null)) return null;
        var count: usize = 0;
        var nearest: f64 = std.math.inf(f64);
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (!player.inPlay()) continue;
            const matches = if (selector) switch (target[1]) {
                's' => player == sender,
                'a', 'p', 'r' => true,
                else => unreachable,
            } else std.ascii.eqlIgnoreCase(player.name[0..player.name_len], target);
            if (!matches) continue;
            if (selector and target[1] == 'p') {
                if (player.world != sender.world) continue;
                const dx = player.position.x - sender.position.x;
                const dy = player.position.y - sender.position.y;
                const dz = player.position.z - sender.position.z;
                const distance = dx * dx + dy * dy + dz * dz;
                if (distance >= nearest) continue;
                nearest = distance;
                assert(self.selected.len > 0);
                self.selected[0] = slot;
                count = 1;
                continue;
            }
            assert(count < self.selected.len and slot < self.deps.players.records.len);
            self.selected[count] = slot;
            count += 1;
            // A name, or @r, is one player.
            if (!selector or target[1] == 'r') break;
        }
        return count;
    }
};

test {
    std.testing.refAllDecls(ChatCommands);
}
