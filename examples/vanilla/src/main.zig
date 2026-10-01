const std = @import("std");
const protocol_set = @import("protocols");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const tui = @import("lightning_rod_tui");
const bossbars = @import("bossbars");
const tps = @import("tps");

pub const std_options: std.Options = .{ .log_level = .debug };
pub export const lightning_rod_resume_manifest linksection(profile.Reload.section_name) = profile.Reload.executableManifest(protocol_set.Endpoint);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var compression: ?usize = 256;
    var terminal = false;

    for (args[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--no-compression")) compression = null else if (std.mem.eql(u8, argument, "--tui")) terminal = true else return error.UnknownArgument;
    }

    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:CMakeLists_txt", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &digest, .big)};

    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{
                .operators = &operators,
            }),
        }),
        lightning_rod.plugin.configured(tui.Plugin, tui.Plugin.Configuration{ .enabled = terminal }),
        lightning_rod.plugin.configured(bossbars.Bossbars, bossbars.Bossbars.Configuration{}),
        lightning_rod.plugin.configured(tps.Tps, tps.Tps.Configuration{}),
    });
    var protocols = try protocol_set.Default.init(init.gpa);
    defer protocols.deinit(init.gpa);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        vanilla.session_plugins(&protocols),
    });
    const router = profile.SingleSimulation{};
    const Server = profile.Server(@TypeOf(plugins), protocol_set.Endpoint, @TypeOf(session_plugins), @TypeOf(router));
    const port = if (init.environ_map.get("LIGHTNING_ROD_PORT")) |value| try std.fmt.parseInt(u16, value, 10) else 25565;
    std.log.info("Starting Lightning Rod", .{});
    try Server.run(init, .{
        .plugins = plugins,
        .session_plugins = session_plugins,
        .reload_manifest = &lightning_rod_resume_manifest,
        .router = router,
        .protocols = &protocols,
        .compression_threshold = compression,
        .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } },
    });
}
