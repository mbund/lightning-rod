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
            // Noon without a cycle, so the sky lights the grass the whole run.
            lightning_rod.plugin.configured(vanilla.Time, .{ .day_time = 6000, .daylight_cycle = false }),
            // Eighty-five times vanilla's rate, so a run sees growth in seconds.
            lightning_rod.plugin.configured(vanilla.RandomTicks, .{ .speed = 255 }),
        }),
        lightning_rod.plugin.configured(Scene, .{}),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// Builds what grows on the flat world's grass at y 64, near spawn.
const Scene = struct {
    pub const id = "e2e:growth_scene";
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
        // Sugar cane on sand beside water grows to three tall.
        try deps.chunks.setBlock(world, .{ .x = 4, .y = 64, .z = 6 }, try state.of("minecraft:sand"));
        try deps.chunks.setBlock(world, .{ .x = 5, .y = 64, .z = 6 }, try state.of("minecraft:water[level=0]"));
        try deps.chunks.setBlock(world, .{ .x = 4, .y = 65, .z = 6 }, try state.of("minecraft:sugar_cane[age=0]"));
        // Bare dirt among grass is grown over.
        try deps.chunks.setBlock(world, .{ .x = 8, .y = 64, .z = 8 }, try state.of("minecraft:dirt"));
        // Grass under stone dies.
        try deps.chunks.setBlock(world, .{ .x = 12, .y = 65, .z = 4 }, try state.of("minecraft:stone"));
        // Leaves no log holds decay, and a leaf on a log stays.
        try deps.chunks.setBlock(world, .{ .x = 10, .y = 70, .z = 10 }, try state.of("minecraft:oak_leaves[distance=1,persistent=false,waterlogged=false]"));
        try deps.chunks.setBlock(world, .{ .x = 14, .y = 66, .z = 14 }, try state.of("minecraft:oak_log[axis=y]"));
        try deps.chunks.setBlock(world, .{ .x = 15, .y = 66, .z = 14 }, try state.of("minecraft:oak_leaves[distance=7,persistent=false,waterlogged=false]"));
        return self;
    }
};
