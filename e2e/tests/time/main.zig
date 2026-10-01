const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");

pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.executableManifest(protocols.Endpoint);

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    var uuid: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &uuid, .{});
    uuid[6] = (uuid[6] & 15) | 0x30;
    uuid[8] = (uuid[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &uuid, .big)};
    const plugin = lightning_rod.plugin;
    const plugins = plugin.replace(vanilla.plugins(), .{
        plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
        plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        plugin.configured(vanilla.Time, vanilla.Time.Configuration{ .daylight_cycle = false }),
    });
    var selected = try protocols.Default.init(init.gpa);
    defer selected.deinit(init.gpa);
    const session_plugins = plugin.compose(.{
        plugin.configured(protocols.Handshake, protocols.Handshake.Configuration{}),
        vanilla.session_plugins(&selected),
    });
    const router = profile.SingleSimulation{};
    try profile.Server(@TypeOf(plugins), protocols.Endpoint, @TypeOf(session_plugins), @TypeOf(router)).run(init, .{
        .plugins = plugins,
        .session_plugins = session_plugins,
        .router = router,
        .reload_manifest = &lightning_rod_resume_manifest,
        .max_players = 2,
        .protocols = &selected,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .reload = .{ .executable = "/proc/self/exe" },
    });
}
