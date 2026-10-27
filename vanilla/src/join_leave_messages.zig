const lightning_rod = @import("lightning_rod");
const Visibility = @import("visibility.zig").Visibility;
const std = @import("std");
const sessions = @import("sessions");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;

pub const JoinLeaveMessages = struct {
    pub const id = "minecraft:join_leave_messages";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        visibility: *Visibility,
        players: *Players,
        chat: *Chat,
        sessions: *sessions.Service,
    };

    const Player = struct {
        handle: ?sessions.Handle = null,
        name: [16]u8 = undefined,
        name_len: u8 = 0,
        announced: bool = false,
    };

    deps: Dependencies,
    players: []Player,
    audiences: lightning_rod.system.bit_sets.Matrix,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*JoinLeaveMessages {
        const self = try allocator.create(JoinLeaveMessages);
        const players = try allocator.alloc(Player, deps.players.records.len);
        @memset(players, .{});
        self.* = .{ .deps = deps, .players = players, .audiences = try lightning_rod.system.bit_sets.Matrix.init(allocator, 2, players.len) };
        self.audiences.row(0).fill();
        return self;
    }

    pub fn tick(self: *JoinLeaveMessages) !void {
        var text: [64]u8 = undefined;

        for (self.deps.sessions.input_events) |event| switch (event) {
            .joined => |joined| {
                self.players[joined.handle.index] = .{
                    .handle = joined.handle,
                    .name = joined.name,
                    .name_len = joined.name_len,
                    .announced = joined.cause == .reload,
                };
            },
            .left => |handle| {
                const player = &self.players[handle.index];
                if (player.handle == null or !std.meta.eql(player.handle.?, handle)) continue;

                if (player.announced) {
                    const message = std.fmt.bufPrint(&text, "{s} left the game", .{player.name[0..player.name_len]}) catch unreachable;
                    if (!self.deps.chat.broadcastTo(.{ .players = self.deps.visibility.announcements.filter(handle, self.audiences.row(0).view(), self.audiences.row(1).workspace()) }, message))
                        std.log.warn("event=join_leave_message_dropped player={s}", .{player.name[0..player.name_len]});
                }
                player.* = .{};
            },
            else => {},
        };

        for (self.deps.players.activeSlots()) |index| {
            const player = &self.players[index];
            const record = self.deps.players.records[index];
            if (player.handle == null or player.announced or record.stage != .ready) continue;
            std.debug.assert(std.meta.eql(player.handle, record.handle));

            const message = std.fmt.bufPrint(&text, "{s} joined the game", .{player.name[0..player.name_len]}) catch unreachable;
            if (!self.deps.chat.broadcastTo(.{ .players = self.deps.visibility.announcements.filter(player.handle.?, self.audiences.row(0).view(), self.audiences.row(1).workspace()) }, message)) break;
            player.announced = true;
        }

        try self.deps.chat.flush();
    }
};
