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

/// Two lava pools set into the flat world's grass at y 64, at x 8 and x 12 on z 8, and fire on
/// the grass at x 16. Five seconds after the player joins, a loaf of bread drops into the first pool, which
/// burns it at once, a netherite ingot into the second, which it floats in unharmed, and a
/// loaf onto the fire, which burns it over a second or so.
const Scene = struct {
    pub const id = "e2e:item_hazards_scene";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        chunks: *Chunks,
        worlds: *vanilla.VanillaWorlds,
        players: *Players,
        dropped: *vanilla.ItemEntities,
        items: *vanilla.Items,
    };

    deps: Dependencies,
    placed: bool = false,
    /// Ticks since the player joined, as items that burn in a few ticks are dropped once its
    /// client is watching.
    waited: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps };
        const lava: u16 = @intCast(protocols.registry.blockStateId("minecraft:lava[level=0]") orelse return error.UnknownBlockState);
        for ([_]i32{ 8, 12 }) |x| try deps.chunks.setBlock(deps.worlds.overworld, .{ .x = x, .y = 64, .z = 8 }, lava);
        const fire: u16 = @intCast(protocols.registry.blockStateId("minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]") orelse return error.UnknownBlockState);
        try deps.chunks.setBlock(deps.worlds.overworld, .{ .x = 16, .y = 65, .z = 8 }, fire);
        return self;
    }

    pub fn tick(self: *Scene) !void {
        if (self.placed) return;
        const ready = for (self.deps.players.activeSlots()) |index| {
            if (self.deps.players.records[index].stage == .ready) break true;
        } else false;
        if (!ready) return;
        self.waited += 1;
        if (self.waited < 100) return;
        self.placed = true;
        const world = self.deps.worlds.overworld;
        _ = try self.deps.dropped.create(world, .{ 8.5, 65.5, 8.5 }, .{ 0, 0, 0 }, .{ .item = try self.deps.items.define("minecraft:bread"), .count = 1 });
        _ = try self.deps.dropped.create(world, .{ 12.5, 65.5, 8.5 }, .{ 0, 0, 0 }, .{ .item = try self.deps.items.define("minecraft:netherite_ingot"), .count = 1 });
        _ = try self.deps.dropped.create(world, .{ 16.5, 65.5, 8.5 }, .{ 0, 0, 0 }, .{ .item = try self.deps.items.define("minecraft:bread"), .count = 1 });
    }
};
