const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const protocols = @import("protocols");
const e2e = @import("e2e");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 1, .render_distance = 2, .spawn = .{ .x = 20.5, .y = 17, .z = 20.5 } }),
            lightning_rod.plugin.configured(vanilla.Flat, .{ .biomes = biomePattern }),
        }),
        lightning_rod.plugin.configured(Probe, .{}),
    });
    try e2e.profile.run(init, plugins, .{});
}

fn biomePattern(section: vanilla.Section, values: *[64]u16) void {
    for (values, 0..) |*biome, cell| {
        const name = if (section.x == 3 and section.z == 1)
            "minecraft:lush_caves"
        else if (section.x == 2 and section.z == 1)
            if (cell % 4 != 3) "minecraft:savanna" else if (cell / 4 % 2 != 0) "minecraft:swamp" else if (cell / 16 % 2 == 0) "minecraft:desert" else "minecraft:badlands"
        else
            "minecraft:forest";
        biome.* = @intCast(protocols.registry.biomeId(name).?);
    }
}

const Probe = struct {
    pub const id = "e2e:occlusion_biomes";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *vanilla.Chunks };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Probe {
        const self = try allocator.create(Probe);
        self.* = .{};
        const edits = try allocator.alloc(vanilla.BlockEdit, 4096);
        defer allocator.free(edits);
        for (edits, 0..) |*edit, index| edit.* = .{
            .index = @intCast(index),
            .state = if (index < 256) @intCast(protocols.registry.block_stone_default_state) else 0,
        };
        edits[4 * 16 + 4].state = @intCast(protocols.registry.block_glowstone_default_state);
        try deps.chunks.setBlocks(.{ .world = 0, .x = 1, .y = 1, .z = 1 }, edits);
        return self;
    }
};
