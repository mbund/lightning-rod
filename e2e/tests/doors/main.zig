const e2e = @import("e2e");
const std = @import("std");
const registry = @import("protocols").registry;
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const operators = bootstrap.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(bootstrap.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2 }),
            lightning_rod.plugin.configured(vanilla.Operators, .{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(Scene, .{}),
    });
    try bootstrap.run(init, plugins, .{ .plaintext = true, .reload_executable = "/proc/self/exe" });
}

const Scene = struct {
    pub const id = "e2e:door_scene";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        chunks: *vanilla.Chunks,
        worlds: *vanilla.VanillaWorlds,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*Scene {
        const self = try allocator.create(Scene);
        self.* = .{};

        for (0..4) |x| for (0..6) |z| {
            try deps.chunks.setBlock(deps.worlds.overworld, .{ .x = 18 + @as(i32, @intCast(x)), .y = 78, .z = @as(i32, @intCast(z)) - 3 }, registry.block_stone_default_state);
        };

        try deps.chunks.setBlock(deps.worlds.overworld, .{ .x = 24, .y = 66, .z = 0 }, registry.block_stone_default_state);
        return self;
    }
};
