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

/// A water source for the empty bucket to take up, on the flat world's grass at y 64.
const Scene = struct {
    pub const id = "e2e:buckets_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks, worlds: *vanilla.VanillaWorlds };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{};
        const water: u16 = @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState);
        try deps.chunks.setBlock(deps.worlds.overworld, .{ .x = 4, .y = 65, .z = 4 }, water);
        return self;
    }
};
