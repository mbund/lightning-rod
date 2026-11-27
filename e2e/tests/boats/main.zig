const protocols = @import("protocols");
const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;
const Operators = @import("commands").operators.Operators;

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    // Alice may change her game mode, to break the boat in survival.
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            // Two share a boat in boats-pair.
            lightning_rod.plugin.configured(Players, .{ .maximum = 2, .render_distance = 2 }),
            lightning_rod.plugin.configured(Operators, Operators.Configuration{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(Scene, .{ .arrival = std.meta.stringToEnum(Scene.Arrival, args.fixture) orelse .nothing }),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// A pool two deep cut into the flat world's grass, from x 3 to 8 and z 3 to 8, its water still,
/// for the client to put a boat on.
const Scene = struct {
    pub const id = "e2e:boats_scene";
    /// What comes to the first boat put on the pool: a cow beside it, near enough to be taken
    /// aboard, or a diamond dropped onto it.
    pub const Arrival = enum { nothing, cow, diamond };
    pub const Configuration = struct { arrival: Arrival = .nothing };
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds, boats: *vanilla.Boats, mobs: *vanilla.Mobs, items: *vanilla.Items, dropped: *vanilla.ItemEntities };

    deps: Dependencies,
    config: Configuration,
    spawned: bool = false,
    /// Ticks since the first boat came, which settles on the water first.
    waited: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps, .config = config };
        const world = deps.worlds.overworld;
        const water: u16 = @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState);
        for (3..9) |x| for (63..65) |y| for (3..9) |z| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) }, water);
        return self;
    }

    /// Once a boat is on the pool, what the scenario has arrives.
    pub fn tick(self: *Scene) !void {
        if (self.config.arrival == .nothing or self.spawned) return;
        const boats = self.deps.boats;
        if (boats.count() == 0) return;
        self.waited += 1;
        if (self.config.arrival == .diamond and self.waited < 100) return;
        const boat = (try boats.get(boats.ids()[0])).?.body orelse return;
        self.spawned = true;
        switch (self.config.arrival) {
            .nothing => unreachable,
            .cow => _ = try self.deps.mobs.spawn(.{ .species = .cow, .world = boat.world, .position = .{ boat.position[0] + 1.0, boat.position[1], boat.position[2] }, .yaw = 90 }),
            // Over the middle of the boat, to fall onto it.
            .diamond => _ = try self.deps.dropped.create(boat.world, .{ boat.position[0], boat.position[1] + 1.5, boat.position[2] }, .{ 0, 0, 0 }, .{ .item = try self.deps.items.define("minecraft:diamond"), .count = 1 }),
        }
    }
};
