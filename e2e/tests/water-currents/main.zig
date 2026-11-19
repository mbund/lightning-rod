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

/// A stream in a trench one block wide, cut into the flat world's grass at z 8: a source at x 4
/// flowing east to a pit seven deep at x 12. A cow and a dropped stone go into the stream once
/// the player is in. Neither gets into the pit unless the current carries it there: a cow does
/// not walk down more than three blocks, and an item does not move by itself.
const Scene = struct {
    pub const id = "e2e:water_currents_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        chunks: *Chunks,
        worlds: *vanilla.VanillaWorlds,
        players: *Players,
        mobs: *vanilla.Mobs,
        dropped: *vanilla.ItemEntities,
        items: *vanilla.Items,
    };

    deps: Dependencies,
    placed: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps };
        const world = deps.worlds.overworld;
        for (4..12) |x| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = 64, .z = 8 }, 0);
        for (58..65) |y| try deps.chunks.setBlock(world, .{ .x = 12, .y = @intCast(y), .z = 8 }, 0);
        try deps.chunks.setBlock(world, .{ .x = 4, .y = 64, .z = 8 }, @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState));
        return self;
    }

    pub fn tick(self: *Scene) !void {
        if (self.placed) return;
        const ready = for (self.deps.players.activeSlots()) |index| {
            if (self.deps.players.records[index].stage == .ready) break true;
        } else false;
        if (!ready) return;
        self.placed = true;
        const world = self.deps.worlds.overworld;
        _ = try self.deps.mobs.spawn(.{ .species = .cow, .world = world, .position = .{ 6.5, 64, 8.5 }, .yaw = -90 });
        _ = try self.deps.dropped.create(world, .{ 5.5, 64.5, 8.5 }, .{ 0, 0, 0 }, .{ .item = try self.deps.items.define("minecraft:stone"), .count = 1 });
    }
};
