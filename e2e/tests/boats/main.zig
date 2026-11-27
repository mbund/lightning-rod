const protocols = @import("protocols");
const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;
const Operators = @import("commands").operators.Operators;

pub fn main(init: std.process.Init) !void {
    // Alice may change her game mode, to break the boat in survival.
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2 }),
            lightning_rod.plugin.configured(Operators, Operators.Configuration{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(Scene, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// A pool two deep cut into the flat world's grass, from x 3 to 8 and z 3 to 8, its water still,
/// for the client to put a boat on.
const Scene = struct {
    pub const id = "e2e:boats_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{};
        const world = deps.worlds.overworld;
        const water: u16 = @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState);
        for (3..9) |x| for (63..65) |y| for (3..9) |z| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) }, water);
        return self;
    }
};
