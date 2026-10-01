const std = @import("std");
const protocol_set = @import("protocols");
const fixture = @import("src/fixture.zig");
const fall_damage_fixture = @import("tests/fall-damage/server.zig");
const inventory_fixture = @import("tests/inventory/server.zig");
const respawn_fixture = @import("tests/respawn/server.zig");
const reload_fixture = @import("tests/reload/server.zig");
const block_sync_fixture = @import("tests/block-sync/server.zig");
const items_fixture = @import("tests/items/server.zig");
const gamemode_fixture = @import("tests/gamemode/server.zig");
const encryption = @import("src/encryption.zig");
const simulations = @import("src/simulations.zig");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const bossbars = @import("bossbars");

const Fixture = fixture.Plugin;
const command_probe = @import("tests/commands/server.zig");
const teleport_probe = @import("tests/teleport/server.zig");

pub export const lightning_rod_resume_manifest linksection(linux.Reload.section_name) = linux.Reload.executableManifest(protocol_set.Endpoint);

pub fn main(init: std.process.Init) !void {
    var protocols = try protocol_set.Default.init(init.gpa);
    defer protocols.deinit(init.gpa);
    const Scenario = enum {
        encryption,
        encryption_reject,
        fall_damage,
        inventory,
        inventory_creative,
        respawn,
        simulations,
        transfer,
        reload,
        reload_creative,
        block_sync,
        items,
        items_plaintext,
        commands,
        gamemode,
        teleport,
        isolation,
    };
    var scenario: Scenario = .encryption;
    var port: u16 = 25565;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--fixture=")) {
            scenario = std.meta.stringToEnum(Scenario, arg[10..]) orelse return error.UnknownFixture;
        } else if (std.mem.startsWith(u8, arg, "--port=")) {
            port = try std.fmt.parseInt(u16, arg[7..], 10);
        } else return error.InvalidArgument;
    }

    const settings: fixture.Settings = switch (scenario) {
        .fall_damage => fall_damage_fixture.settings,
        .inventory => inventory_fixture.settings,
        .inventory_creative => .{ .kind = .inventory },
        .respawn => respawn_fixture.settings,
        .reload => reload_fixture.settings,
        .reload_creative => .{ .kind = .reload },
        .block_sync => block_sync_fixture.settings,
        .items, .items_plaintext => items_fixture.settings,
        .commands => command_probe.settings,
        .gamemode => gamemode_fixture.settings,
        .teleport => teleport_probe.settings,
        else => .{},
    };
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &digest, .big)};
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(vanilla.Players, settings.players),
            lightning_rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = settings.delta_sections }),
            lightning_rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = if (settings.teleport.enabled or scenario == .gamemode) &operators else &.{} }),
            lightning_rod.plugin.configured(vanilla.Worlds, vanilla.Worlds.Configuration{ .maximum = settings.worlds }),
        }),
        lightning_rod.plugin.configured(bossbars.Bossbars, bossbars.Bossbars.Configuration{}),
        lightning_rod.plugin.configured(Fixture, Fixture.Configuration{ .kind = settings.kind }),
        lightning_rod.plugin.configured(command_probe.Probe, settings.commands),
        lightning_rod.plugin.configured(teleport_probe.Probe, settings.teleport),
    });
    var provider = try encryption.Encryption.init(scenario == .encryption_reject);
    defer provider.deinit();
    if (scenario == .simulations or scenario == .transfer) return simulations.run(init, plugins, &protocols, if (scenario == .transfer) provider.interface() else null, scenario == .transfer, port);

    const reloading = scenario == .reload or scenario == .reload_creative;
    var command_state: command_probe.State = .{ .reload = reloading };
    const ConfigurationPlugin = vanilla.SessionConfiguration(protocol_set.Default);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginStart, vanilla.LoginStart.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{ .key = if (scenario == .items_plaintext) null else provider.interface() }),
        lightning_rod.plugin.configured(vanilla.Disconnect, vanilla.Disconnect.Configuration{}),
        lightning_rod.plugin.configured(vanilla.OfflineAuthentication, vanilla.OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginCompression, vanilla.LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginSuccess, vanilla.LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Keepalive, vanilla.Keepalive.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{ .description = "E2E Vanilla Status" }),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = &protocols }),
        lightning_rod.plugin.configured(vanilla.ConfigurationFinish, vanilla.ConfigurationFinish.Configuration{}),
    });
    const router = linux.SingleSimulation{};
    try linux.Server(@TypeOf(plugins), protocol_set.Endpoint, @TypeOf(session_plugins), @TypeOf(router)).runWithEnvironment(init, .{
        .plugins = plugins,
        .session_plugins = session_plugins,
        .reload_manifest = &lightning_rod_resume_manifest,
        .router = router,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .protocols = &protocols,

        .compression_threshold = if (scenario == .isolation) null else 256,
        .reload = .{ .executable = if (reloading) "reload-target" else if (scenario == .items or scenario == .items_plaintext) "/proc/self/exe" else null },
    }, .{
        .permission_policy = if (settings.teleport.enabled or scenario == .gamemode) @as(?vanilla.commands.Policy, null) else vanilla.commands.Policy{
            .context = &command_state,
            .allows = command_probe.State.allows,
        },
        .state = &command_state,
        .label = "typed-environment",
        .limit = 7,
    });
}
