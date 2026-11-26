const protocols = @import("protocols");
const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;
const Stack = @import("inventories").Stack;

/// Items and arrows, which clients step themselves, traced: the runner holds each client's trace
/// to the server's within the tolerance, and to its class's models of it.
///
/// `arrows`: arrows fly into the grass. `water`: items ride a stream to its end. `ocean`: items
/// drop into deep still water, some from high enough to reach its floor. `blocks`: items are
/// thrown onto blocks that slow or speed them.
pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const kind = std.meta.stringToEnum(Scene.Kind, args.fixture) orelse return error.UnknownFixture;
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(Scene, .{ .kind = kind }),
        lightning_rod.plugin.configured(e2e.EntityTrace, .{ .directory = init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY") }),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}

/// Once the player is in and has its chunks, two waves, the second while the first rest.
/// Arrows fly east across open ground into the grass at y 64. Or a stream runs east along a
/// trench one block wide at z 20: a source at x 2 flows the seven blocks to x 9, walled off past
/// it, and stones drop into its head. Or a pool of still water six blocks across at x 20 and z
/// 20, twenty deep from y 64 down to a sand floor at y 44: stones drop into it from y 100, which
/// carries them to the floor, and others are tossed in from its edge. Or a row of pads of blocks
/// that slow or speed what lies on them, which stones are thrown onto.
const Scene = struct {
    pub const id = "e2e:entity_proof_scene";
    pub const Kind = enum { arrows, water, ocean, blocks };
    pub const Configuration = struct { kind: Kind = .arrows };
    pub const Dependencies = struct {
        chunks: *Chunks,
        worlds: *vanilla.VanillaWorlds,
        players: *Players,
        dropped: *vanilla.ItemEntities,
        items: *vanilla.Items,
        projectiles: *vanilla.Projectiles,
    };

    deps: Dependencies,
    kind: Kind,
    /// Ticks since the player was ready.
    since: ?u32 = null,

    /// The first wave once the water is still, the second once the first has come to rest.
    const waves = [_]u32{ 100, 300 };

    pub fn init(allocator: std.mem.Allocator, config: Configuration, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{ .deps = deps, .kind = config.kind };
        const world = deps.worlds.overworld;
        const water: u16 = @intCast(protocols.registry.blockStateId("minecraft:water[level=0]") orelse return error.UnknownBlockState);
        switch (config.kind) {
            .arrows => {},
            .water => {
                for (2..10) |x| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = 64, .z = 20 }, 0);
                try deps.chunks.setBlock(world, .{ .x = 2, .y = 64, .z = 20 }, water);
            },
            .blocks => for (pads, 0..) |pad, index| {
                const x: i32 = @intCast(2 + 4 * index);
                for (0..3) |offset| {
                    const at: i32 = x + @as(i32, @intCast(offset));
                    try deps.chunks.setBlock(world, .{ .x = at, .y = pad.y, .z = 4 }, @intCast(protocols.registry.blockStateId(pad.block) orelse return error.UnknownBlockState));
                    if (pad.under) |under| try deps.chunks.setBlock(world, .{ .x = at, .y = pad.y - 1, .z = 4 }, @intCast(protocols.registry.blockStateId(under) orelse return error.UnknownBlockState));
                }
            },
            .ocean => {
                const sand: u16 = @intCast(protocols.registry.blockStateId("minecraft:sand") orelse return error.UnknownBlockState);
                for (20..26) |x| for (20..26) |z| {
                    try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = 44, .z = @intCast(z) }, sand);
                    for (45..65) |y| try deps.chunks.setBlock(world, .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) }, water);
                };
            },
        }
        return self;
    }

    pub fn tick(self: *Scene) !void {
        const player = for (self.deps.players.activeSlots()) |index| {
            if (self.deps.players.records[index].stage == .ready) break index;
        } else return;
        const since = if (self.since) |value| value + 1 else 0;
        self.since = since;
        for (waves) |due| if (since == due) {
            switch (self.kind) {
                .arrows => try self.volley(player),
                .water => try self.stream(),
                .ocean => try self.ocean(),
                .blocks => try self.slide(),
            }
        };
    }

    fn volley(self: *Scene, player: usize) !void {
        const world = self.deps.worlds.overworld;
        // East and up a little, landing in the grass.
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

    fn ocean(self: *Scene) !void {
        const world = self.deps.worlds.overworld;
        const stone: Stack = .{ .item = try self.deps.items.define("minecraft:stone"), .count = 1 };
        for (0..3) |index| {
            const at: f64 = @floatFromInt(index);
            // From 35 blocks up, near its top speed as it reaches the water.
            _ = try self.deps.dropped.create(world, .{ 21.5 + 1.5 * at, 100, 22.5 }, .{ 0, 0, 0 }, stone);
            // Tossed in from its west edge.
            _ = try self.deps.dropped.create(world, .{ 19.5, 66, 21.5 + 1.5 * at }, .{ 0.15 + 0.05 * at, 0.1, 0 }, stone);
        }
    }

    /// What items are thrown onto, a pad three blocks wide each along z 4: where a client would
    /// step an item otherwise if any of what a block does to it were wrong.
    const Pad = struct { block: []const u8, y: i32 = 64, under: ?[]const u8 = null };
    const pads = [_]Pad{
        .{ .block = "minecraft:ice" },
        .{ .block = "minecraft:packed_ice" },
        .{ .block = "minecraft:blue_ice" },
        .{ .block = "minecraft:slime_block" },
        .{ .block = "minecraft:soul_sand" },
        .{ .block = "minecraft:honey_block" },
        // An item on a slab slides as the block under it says.
        .{ .block = "minecraft:smooth_stone_slab[type=bottom,waterlogged=false]", .under = "minecraft:ice" },
        .{ .block = "minecraft:cobweb", .y = 65 },
    };

    fn slide(self: *Scene) !void {
        const world = self.deps.worlds.overworld;
        const stone: Stack = .{ .item = try self.deps.items.define("minecraft:stone"), .count = 1 };
        for (0..pads.len) |index| {
            const x: f64 = @floatFromInt(2 + 4 * index);
            _ = try self.deps.dropped.create(world, .{ x + 0.5, 66.5, 4.5 }, .{ 0.2, 0.05, 0 }, stone);
        }
    }

    fn stream(self: *Scene) !void {
        const world = self.deps.worlds.overworld;
        const stone: Stack = .{ .item = try self.deps.items.define("minecraft:stone"), .count = 1 };
        // Into the stream's first blocks, a few ticks of flow apart as they fall.
        for (0..6) |index| {
            const at: f64 = @floatFromInt(index);
            _ = try self.deps.dropped.create(world, .{ 2.5 + 0.3 * at, 65.5 + 0.2 * at, 20.5 }, .{ 0, 0, 0 }, stone);
        }
    }
};
