const std = @import("std");
const reload = @import("reload");
const commands = @import("commands");
const Players = @import("players.zig").Players;
const Chat = @import("chat.zig").Chat;

pub const ReloadCommands = struct {
    pub const id = "lightning_rod:reload_commands";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        reload: *reload.Reload,
        players: *Players,
        chat: *Chat,
        commands: *commands.Commands,
    };

    pub const notification_permission: commands.Permission = .{ .name = "server.reload.notify", .description = "Receive signal reload results" };
    pub const permission: commands.Permission = .{ .name = "server.reload", .description = "Reload the server" };

    const Args = struct {};

    const player_prefix = "lightning_rod.player.v1";
    deps: Dependencies,
    seen: []u64,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ReloadCommands {
        const self = try allocator.create(ReloadCommands);
        const seen = try allocator.alloc(u64, deps.players.records.len);
        @memset(seen, 0);
        self.* = .{ .deps = deps, .seen = seen };

        if (deps.reload.available()) _ = try deps.commands.register(self, commands.leaf(ReloadCommands, Args, .{
            .name = "reload",
            .description = "Reload at the end of the current tick",
            .permission = &permission,
            .handler = execute,
            .arguments = .{},
        }));
        return self;
    }

    fn execute(self: *ReloadCommands, context: commands.Context, _: Args) !void {
        var token: [player_prefix.len + 16]u8 = undefined;
        token[0..player_prefix.len].* = player_prefix.*;
        std.mem.writeInt(u128, token[player_prefix.len..], context.sender, .big);
        self.deps.reload.stage(&token) catch |err| {
            context.reply(switch (err) {
                error.AlreadyPending => "Reload already requested.",
                error.Unavailable => "Reload is unavailable.",
            });
            return;
        };
        context.reply("Reload requested.");
    }

    pub fn tick(self: *ReloadCommands) !void {
        const request = self.deps.reload.deps.reload_request orelse return;

        for (self.deps.players.deps.sessions.input_events) |event| if (event == .joined and event.joined.cause != .reload) {
            self.seen[event.joined.handle.index] = request.sequence;
        };

        const result = request.result orelse return;
        const token = request.token();
        const signal = std.mem.eql(u8, token, reload.signal_token);
        const player = token.len == player_prefix.len + 16 and std.mem.startsWith(u8, token, player_prefix);
        if (!signal and !player) return;

        var buffer: [128]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "{s} ({d} ms).", .{ switch (result) {
            .succeeded => "Reload successful",
            .rolled_back => "Reload failed; rolled back successfully",
            .rejected => "Reload rejected; server unchanged",
        }, request.elapsed_ms });

        for (self.deps.players.records, self.seen) |recipient, *seen| {
            const handle = recipient.handle orelse continue;
            if (recipient.stage != .ready or seen.* == request.sequence) continue;
            seen.* = request.sequence;

            if (signal) {
                const policy = self.deps.commands.deps.permission_policy orelse continue;
                if (!policy.allows(policy.context, recipient.uuid, &notification_permission)) continue;
            } else if (std.mem.readInt(u128, token[player_prefix.len..][0..16], .big) != recipient.uuid) continue;
            self.deps.chat.system(handle, message);
        }

        try self.deps.chat.flush();
    }
};
