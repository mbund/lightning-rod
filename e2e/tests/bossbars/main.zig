const sessions = @import("sessions");
const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const bossbars = @import("bossbars");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(bootstrap.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(bossbars.Bossbars, .{}),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try bootstrap.run(init, plugins, .{ .plaintext = true, .reload_executable = "/proc/self/exe" });
}

const Probe = struct {
    pub const id = "e2e:bossbars";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *vanilla.Players,
        bars: *bossbars.Bossbars,
        control: *e2e.Control,
        reload: *vanilla.Reload,
    };
    const Phase = enum { waiting, created, updated, alice, bob, removed, recreated, reloaded };

    deps: Dependencies,
    phase: Phase = .waiting,
    observed: u2 = 0,
    bar: ?bossbars.Handle = null,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps };
        if (deps.reload.latest()) |request| {
            // The sequence is restored before init. The reload result is assigned afterwards.
            if (request.sequence > 0) {
                self.phase = .reloaded;
                self.bar = try deps.bars.create(.{ .title = "Fixture restored", .progress = 0.75, .color = .purple, .division = .ten });
            }
        }
        deps.control.on(self, message);
        return self;
    }

    fn message(self: *Probe, handle: sessions.Handle, text: []const u8) !e2e.Control.Result {
        if (!std.mem.eql(u8, text, "ready") and !std.mem.eql(u8, text, "observed")) return .unhandled;
        if (!std.mem.eql(u8, text, if (self.phase == .waiting or self.phase == .reloaded) "ready" else "observed")) return error.UnexpectedBossbarMessage;
        std.debug.assert(handle.index < 2);
        const bit = @as(u2, 1) << @as(u1, @intCast(handle.index));
        if (self.observed & bit != 0) return error.DuplicateBossbarObservation;
        self.observed |= bit;
        if (self.observed != 3) return .handled;
        self.observed = 0;

        switch (self.phase) {
            .waiting => {
                for (self.deps.players.records) |*player| {
                    std.debug.assert(player.handle != null and player.stage == .ready and player.loaded);
                    const alice = std.mem.eql(u8, player.name[0..player.name_len], "alice");
                    try self.deps.players.teleport(player, player.world, .{ .x = if (alice) -3.5 else 3.5, .y = 65, .z = 3.5 }, .{ .yaw = if (alice) -90 else 90, .pitch = 0 });
                }
                self.bar = try self.deps.bars.create(.{ .title = "Fixture created", .progress = 0.25 });
                self.phase = .created;
            },
            .created => {
                try self.deps.bars.update(self.bar.?, .{ .title = "Fixture updated", .progress = 0.75, .color = .purple, .division = .ten });
                self.phase = .updated;
            },
            .updated, .alice => {
                const audience = if (self.phase == .updated) "alice" else "bob";
                for (self.deps.players.records) |player| {
                    if (!std.mem.eql(u8, player.name[0..player.name_len], audience)) continue;
                    try self.deps.bars.update(self.bar.?, .{
                        .title = if (self.phase == .updated) "Private alice" else "Private bob",
                        .progress = 0.5,
                        .color = .blue,
                        .division = .six,
                        .audience = .{ .player = player.uuid },
                    });
                }
                self.phase = if (self.phase == .updated) .alice else .bob;
            },
            .bob => {
                try self.deps.bars.remove(self.bar.?);
                self.bar = null;
                self.phase = .removed;
            },
            .removed => {
                self.bar = try self.deps.bars.create(.{ .title = "Fixture recreated", .progress = 0.75, .color = .purple, .division = .ten });
                self.phase = .recreated;
            },
            .recreated => {
                try self.deps.reload.stage("e2e:bossbars");
                return .handled;
            },
            .reloaded => {},
        }
        for (self.deps.players.records) |player| try self.deps.control.send(player.handle.?, @tagName(self.phase));
        return .handled;
    }
};
