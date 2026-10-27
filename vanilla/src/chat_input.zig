const std = @import("std");
const sessions = @import("sessions");
const wire = @import("wire_1_21_5");
const Chat = @import("chat.zig").Chat;
const Input = @import("input.zig").Input;
const Players = @import("players.zig").Players;

pub const ChatInput = struct {
    pub const id = "minecraft:chat_input";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *Input, players: *Players, chat: *Chat, sessions: *sessions.Service };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ChatInput {
        const self = try allocator.create(ChatInput);
        self.* = .{ .deps = deps };
        try deps.input.on(.chat_message, self, message);
        return self;
    }

    fn message(self: *ChatInput, handle: sessions.Handle, body: wire.play.toServer.packet_chat_message.Reader) !void {
        const text, _ = body.message() catch return error.InvalidPacket;
        const player = self.deps.players.records[handle.index];
        if (!player.inPlay()) return;
        if (text.len > 1024 or !std.unicode.utf8ValidateSlice(text)) {
            self.deps.sessions.disconnect(handle);
            return;
        }
        var buffer: [1096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "<{s}> {s}", .{ player.name[0..player.name_len], text }) catch unreachable;
        if (!self.deps.chat.broadcast(formatted)) self.deps.sessions.disconnect(handle);
    }
};
