const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const fixture = @import("server.zig");

pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.executableManifest(protocols.Endpoint);

pub fn main(init: std.process.Init) !void {
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    const plugin = lightning_rod.plugin;
    const plugins = plugin.compose(.{
        plugin.replace(vanilla.plugins(), .{
            plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
        }),
        plugin.configured(fixture.Probe, fixture.Probe.Configuration{}),
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
