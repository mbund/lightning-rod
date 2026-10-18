const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = @import("e2e").server;
const sessions = @import("sessions");

pub fn main(init: std.process.Init) !void {
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival }),
        }),
        lr.plugin.configured(Probe, .{}),
    });
    try bootstrap.run(init, plugins, .{});
}

const Probe = struct {
    pub const id = "e2e:respawn";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        players: *vanilla.Players,
        sessions: *sessions.Service,
    };
    deps: Dependencies,
    killed: []u32,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const killed = try allocator.alloc(u32, deps.players.records.len);
        @memset(killed, 0);
        const self = try allocator.create(Probe);
        self.* = .{ .deps = deps, .killed = killed };
        return self;
    }

    pub fn tick(self: *Probe) !void {
        for (self.deps.sessions.input_events) |event| {
            if (event == .joined and event.joined.cause == .reload) self.killed[event.joined.handle.index] = event.joined.handle.generation;
        }

        for (self.deps.players.records, self.killed) |*player, *killed| {
            const handle = player.handle orelse continue;
            if (player.stage != .ready or !player.loaded or killed.* == handle.generation) continue;
            player.health = 0;
            killed.* = handle.generation;
        }
    }
};
