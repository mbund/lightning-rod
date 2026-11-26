const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Players = @import("players").players.Players;

/// Arrows sent as exact states, and traced: the runner holds the client's trace to the server's,
/// so every tick the client computed between exact states must be the server's. Items are not
/// here: a client bounces a landed item, which no exact state before the landing can fix.
pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2 }),
            lightning_rod.plugin.configured(vanilla.ProjectileReplication, .{ .exact_states = true }),
        }),
        lightning_rod.plugin.configured(Scene, .{}),
        lightning_rod.plugin.configured(e2e.EntityTrace, .{ .directory = init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY") }),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// Once the player is in and has its chunks, arrows fly east across open ground into the grass at
/// y 64: twice, the second while the first are stuck.
const Scene = struct {
    pub const id = "e2e:entity_proof_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        worlds: *vanilla.VanillaWorlds,
        players: *Players,
        items: *vanilla.Items,
        projectiles: *vanilla.Projectiles,
    };

    deps: Dependencies,
    /// Ticks since the player was ready.
    since: ?u32 = null,

    const waves = [_]u32{ 60, 260 };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Scene) !void {
        const player = for (self.deps.players.activeSlots()) |index| {
            if (self.deps.players.records[index].stage == .ready) break index;
        } else return;
        const since = if (self.since) |value| value + 1 else 0;
        self.since = since;
        for (waves) |due| if (since == due) try self.wave(player);
    }

    fn wave(self: *Scene, player: usize) !void {
        const world = self.deps.worlds.overworld;
        // Arrows east and up a little, landing in the grass.
        for (0..4) |index| {
            const at: f64 = @floatFromInt(index);
            try self.deps.projectiles.launch(.{
                .kind = .arrow,
                .world = world,
                .position = .{ 0.5, 66, 10.5 + at },
                .velocity = .{ 1.1 + 0.1 * at, 0.3, 0.05 * at },
                .owner = player,
                .stack = .{ .item = try self.deps.items.define("minecraft:arrow"), .count = 1 },
            });
        }
    }
};
