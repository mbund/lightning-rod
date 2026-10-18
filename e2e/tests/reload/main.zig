const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const bossbars = @import("bossbars");
const e2e = @import("e2e");
const sessions = @import("sessions");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const args = try bootstrap.arguments(init);
    var permissions: Permissions = .{};
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.commands.Commands, .{
                .permission_policy = vanilla.commands.Policy.init(&permissions, Permissions.allows),
            }),
            lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = if (std.mem.eql(u8, args.fixture, "reload_creative")) .creative else .survival }),
        }),
        lr.plugin.configured(bossbars.Bossbars, .{}),
        lr.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
        lr.plugin.configured(Probe, .{ .permissions = &permissions }),
    });
    try bootstrap.run(init, plugins, .{ .reload_executable = "reload-target" });
}

const Probe = struct {
    pub const id = "e2e:reload";
    pub const Configuration = struct { permissions: *Permissions };
    pub const Dependencies = struct {
        bars: *bossbars.Bossbars,
        control: *e2e.Control,
        players: *vanilla.Players,
        reload: *vanilla.Reload,
    };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        config.permissions.players = deps.players;
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "reload_bar") and !std.mem.eql(u8, text, "reload_opaque") and !std.mem.eql(u8, text, "reload_signal")) return .unhandled;
        const player = &self.deps.players.records[handle.index];
        if (player.stage != .ready or !player.loaded) return error.FixturePlayerNotReady;

        if (std.mem.eql(u8, text, "reload_bar")) {
            _ = try self.deps.bars.create(.{ .title = "Reload probe", .audience = .{ .player = player.uuid } });
            return .handled;
        }
        if (!std.mem.eql(u8, player.name[0..player.name_len], "alice")) return error.ReloadRequiresAlice;

        if (std.mem.eql(u8, text, "reload_opaque")) try self.deps.reload.stage("lightning_rod.player.v99\x00");

        if (std.mem.eql(u8, text, "reload_signal")) try std.posix.raise(.USR1);
        return .handled;
    }
};

const Permissions = struct {
    players: ?*vanilla.Players = null,

    pub fn allows(self: *Permissions, uuid: u128, permission: *const vanilla.commands.Permission) bool {
        const players = self.players orelse return false;
        const recipient = if (std.mem.eql(u8, permission.name, "server.reload.notify")) "bob" else "alice";
        for (players.records) |player| {
            if (player.handle != null and player.uuid == uuid)
                return std.mem.eql(u8, player.name[0..player.name_len], recipient);
        }
        return false;
    }
};
