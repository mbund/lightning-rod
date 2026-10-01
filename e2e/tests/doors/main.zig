const protocol_set = @import("protocols");
const std = @import("std");
const registry = @import("protocols").registry;
const lightning_rod = @import("lightning_rod");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");

pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.executableManifest(protocol_set.Endpoint);

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    var uuid: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &uuid, .{});
    uuid[6] = (uuid[6] & 15) | 0x30;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &uuid, .big)};
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
            lightning_rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(Scene, Scene.Configuration{}),
    });
    var protocols = try protocol_set.Default.init(init.gpa);
    defer protocols.deinit(init.gpa);
    const ConfigurationPlugin = vanilla.SessionConfiguration(protocol_set.Default);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginStart, vanilla.LoginStart.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Disconnect, vanilla.Disconnect.Configuration{}),
        lightning_rod.plugin.configured(vanilla.OfflineAuthentication, vanilla.OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginCompression, vanilla.LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginSuccess, vanilla.LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Keepalive, vanilla.Keepalive.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{}),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = &protocols }),
        lightning_rod.plugin.configured(vanilla.ConfigurationFinish, vanilla.ConfigurationFinish.Configuration{}),
    });
    const router = profile.SingleSimulation{};
    try profile.Server(@TypeOf(plugins), protocol_set.Endpoint, @TypeOf(session_plugins), @TypeOf(router)).run(init, .{
        .plugins = plugins,
        .session_plugins = session_plugins,
        .reload_manifest = &lightning_rod_resume_manifest,
        .router = router,
        .max_players = 2,
        .protocols = &protocols,

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
