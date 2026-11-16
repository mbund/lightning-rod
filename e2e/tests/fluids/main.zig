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

/// Pours water and lava on the flat world's grass at y 64, near spawn.
const Scene = struct {
    pub const id = "e2e:fluids_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{};
        const world = deps.worlds.overworld;
        const state = struct {
            fn of(name: []const u8) !u16 {
                return @intCast(protocols.registry.blockStateId(name) orelse return error.UnknownBlockState);
            }
        };
        // A water source spreads seven cells over flat ground.
        try deps.chunks.setBlock(world, .{ .x = 4, .y = 65, .z = 4 }, try state.of("minecraft:water[level=0]"));
        // Lava spreads three in the overworld.
        try deps.chunks.setBlock(world, .{ .x = 30, .y = 65, .z = 10 }, try state.of("minecraft:lava[level=0]"));
        // Water flowing onto a lava source makes obsidian.
        try deps.chunks.setBlock(world, .{ .x = 20, .y = 65, .z = 20 }, try state.of("minecraft:lava[level=0]"));
        try deps.chunks.setBlock(world, .{ .x = 22, .y = 65, .z = 20 }, try state.of("minecraft:water[level=0]"));
        // Water finds the hole two cells away and falls into it.
        for (61..65) |y| try deps.chunks.setBlock(world, .{ .x = 40, .y = @intCast(y), .z = 4 }, 0);
        try deps.chunks.setBlock(world, .{ .x = 40, .y = 65, .z = 6 }, try state.of("minecraft:water[level=0]"));
        // Flowing water passes a stair by rather than filling it.
        try deps.chunks.setBlock(world, .{ .x = 4, .y = 65, .z = 6 }, try state.of("minecraft:oak_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]"));
        return self;
    }
};
