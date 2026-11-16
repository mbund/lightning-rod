const protocols = @import("protocols");
const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(Scene, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// A mob farm's drop: a pit three deep in the flat world's ground at x 12, z 8, under an open
/// trapdoor level with the grass, which mobs path over as if it were floor.
const Scene = struct {
    pub const id = "e2e:mob_farm_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{};
        const trapdoor: u16 = @intCast(protocols.registry.blockStateId("minecraft:oak_trapdoor[facing=north,half=bottom,open=true,powered=false,waterlogged=false]") orelse return error.UnknownBlockState);
        const world = deps.worlds.overworld;
        try deps.chunks.setBlock(world, .{ .x = 12, .y = 64, .z = 8 }, trapdoor);
        try deps.chunks.setBlock(world, .{ .x = 12, .y = 63, .z = 8 }, 0);
        try deps.chunks.setBlock(world, .{ .x = 12, .y = 62, .z = 8 }, 0);
        return self;
    }
};
