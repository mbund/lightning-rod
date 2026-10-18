const records = @import("records");
const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const e2e = @import("e2e");
const sessions = @import("sessions");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{lr.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2, .gamemode = .survival })}),
        lr.plugin.configured(Probe, .{}),
    });
    try bootstrap.run(init, plugins, .{ .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:reload_progress";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *vanilla.Players,
        control: *e2e.Control,
        reload: *vanilla.Reload,
        storage: lr.storage.Space,
    };
    const Phase = enum { waiting, restored, configuring, progressing, released };
    const Round = struct { health: f32, x: f64 };
    const rounds = [_]Round{ .{ .health = 10, .x = 5.5 }, .{ .health = 7, .x = 8.5 } };
    const progress_ticks = 10;
    deps: Dependencies,
    phase: Phase = .waiting,
    ready: u2 = 0,
    round: u8 = 0,
    ticks: u8 = 0,
    bob: ?sessions.Handle = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        var saved: [1]u8 = undefined;
        if (try records.Value.init(deps.storage).read(&saved)) |length| {
            if (length != 1 or saved[0] > 2) return error.InvalidReloadRound;
            self.round = saved[0];
            self.phase = .restored;
        }
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (std.mem.eql(u8, text, "reload_configuring")) {
            if (self.round != 1 or self.phase != .released) return error.UnexpectedReloadRound;
            self.round = 2;
            try self.deps.reload.stage("e2e:reload_progress");
            return .handled;
        }
        if (!std.mem.eql(u8, text, "ready")) return .unhandled;
        const player = self.deps.players.records[handle.index];
        if (self.phase == .waiting) {
            self.ready |= @as(u2, 1) << @as(u1, @intCast(handle.index));
            if (self.ready == 3) {
                self.round = 1;
                try self.deps.reload.stage("e2e:reload_progress");
            }
        } else if (std.mem.eql(u8, player.name[0..player.name_len], "bob")) {
            if (self.phase != .configuring) return error.UnexpectedReloadProgress;
            self.bob = handle;
            self.phase = .progressing;
        }
        return .handled;
    }

    pub fn checkpoint(self: *Probe, space: lr.storage.Space) !void {
        try records.Value.init(space).write(&.{self.round});
    }

    pub fn tick(self: *Probe) !void {
        if (self.phase == .waiting or self.phase == .released) return;
        var count: usize = 0;
        var alice: ?*vanilla.Players.Player = null;
        for (self.deps.players.records) |*player| {
            if (player.handle == null) continue;
            count += 1;
            if (std.mem.eql(u8, player.name[0..player.name_len], "alice")) alice = player;
        }
        if (count != 2 or alice == null or !alice.?.configuring or !alice.?.inWorld()) return error.ReloadLostPlayer;
        const player = alice.?;
        const expected = rounds[self.round - 1];
        if (self.phase == .restored) {
            player.health = expected.health;
            try self.deps.players.teleport(player, player.world, .{ .x = expected.x, .y = 65, .z = 0.5 }, .{ .yaw = 0, .pitch = 0 });
            self.phase = .configuring;
        }
        if (player.health != expected.health or player.position.x != expected.x) return error.ReloadRestoredStalePlayer;
        if (self.phase == .progressing) {
            self.ticks += 1;
            if (self.ticks == progress_ticks) {
                try self.deps.control.send(self.bob.?, if (self.round == 1) "ack_progressed" else "configuration_progressed");
                self.phase = .released;
            }
        }
    }
};
