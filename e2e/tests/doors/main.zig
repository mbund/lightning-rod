const std = @import("std");
const registry = @import("protocols").registry;
const rod = @import("lightning_rod");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");

pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.manifest;

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    var uuid: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &uuid, .{});
    uuid[6] = (uuid[6] & 15) | 0x30;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &uuid, .big)};
    const plugins = rod.plugin.compose(.{
        rod.plugin.replace(vanilla.plugins(), .{
            rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
            rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        }),
        rod.plugin.configured(Scene, Scene.Configuration{}),
    });
    var protocols = try vanilla.Protocols.init(init.gpa);
    defer protocols.deinit(init.gpa);
    try profile.Profile(@TypeOf(plugins)).run(init, .{
        .plugins = plugins,
        .max_players = 2,
        .protocols = &protocols.values,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .reload = .{ .executable = "/proc/self/exe" },
    });
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
