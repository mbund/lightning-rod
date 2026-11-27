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
        lightning_rod.plugin.configured(Scene, .{ .cow = std.mem.eql(u8, args.fixture, "cow") }),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// A pool two deep cut into the flat world's grass, from x 3 to 8 and z 3 to 8, its water still,
/// for the client to put a boat on.
const Scene = struct {
    pub const id = "e2e:boats_scene";
    pub const Configuration = struct {
        /// A cow comes up beside the first boat put on the pool.
        cow: bool = false,
    };
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds, boats: *vanilla.Boats, mobs: *vanilla.Mobs };

    deps: Dependencies,
    config: Configuration,
    spawned: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps, .config = config };
        const world = deps.worlds.overworld;
        const water: u16 = @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState);
        for (3..9) |x| for (63..65) |y| for (3..9) |z| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) }, water);
        return self;
    }

    /// Once a boat is on the pool, a cow comes up beside it, near enough to be taken aboard.
    pub fn tick(self: *Scene) !void {
        if (!self.config.cow or self.spawned) return;
        const boats = self.deps.boats;
        if (boats.count() == 0) return;
        const boat = (try boats.get(boats.ids()[0])).?.body orelse return;
        self.spawned = true;
        _ = try self.deps.mobs.spawn(.{ .species = .cow, .world = boat.world, .position = .{ boat.position[0] + 1.0, boat.position[1], boat.position[2] }, .yaw = 90 });
    }
};
