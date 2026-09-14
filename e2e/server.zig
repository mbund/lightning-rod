const std = @import("std");
const fixture = @import("src/fixture.zig");
const fall_damage_fixture = @import("tests/fall-damage/server.zig");
const inventory_fixture = @import("tests/inventory/server.zig");
const respawn_fixture = @import("tests/respawn/server.zig");
const reload_fixture = @import("tests/reload/server.zig");
const block_sync_fixture = @import("tests/block-sync/server.zig");
const items_fixture = @import("tests/items/server.zig");
const encryption = @import("src/encryption.zig");
const simulations = @import("src/simulations.zig");
const rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("vanilla");

const Fixture = fixture.Plugin;
const command_probe = @import("tests/commands/server.zig");
const teleport_probe = @import("tests/teleport/server.zig");

pub export const lightning_rod_resume_manifest linksection(linux.Reload.section_name) = linux.Reload.manifest;

pub fn main(init: std.process.Init) !void {
    var protocols = try vanilla.Protocols.init(init.gpa);
    defer protocols.deinit(init.gpa);
    const Scenario = enum {
        encryption,
        encryption_reject,
        fall_damage,
        inventory,
        respawn,
        simulations,
        transfer,
        reload,
        block_sync,
        items,
        commands,
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
        .respawn => respawn_fixture.settings,
        .reload => reload_fixture.settings,
        .block_sync => block_sync_fixture.settings,
        .items => items_fixture.settings,
        .commands => command_probe.settings,
        .teleport => teleport_probe.settings,
        else => .{},
    };
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &digest, .big)};
    const plugins = rod.plugin.compose(.{
        rod.plugin.replace(vanilla.plugins(), .{
            rod.plugin.configured(vanilla.Players, settings.players),
            rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = settings.delta_sections }),
            rod.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = if (settings.teleport.enabled) &operators else &.{} }),
            rod.plugin.configured(vanilla.Worlds, vanilla.Worlds.Configuration{ .maximum = settings.worlds }),
        }),
        rod.plugin.configured(Fixture, Fixture.Configuration{ .kind = settings.kind }),
        rod.plugin.configured(command_probe.Probe, settings.commands),
        rod.plugin.configured(teleport_probe.Probe, settings.teleport),
    });
    var provider = try encryption.Encryption.init(scenario == .encryption_reject);
    defer provider.deinit();
    if (scenario == .simulations or scenario == .transfer) return simulations.run(init, plugins, &protocols, if (scenario == .transfer) provider.interface() else null, scenario == .transfer, port);

    var command_state: command_probe.State = .{ .reload = scenario == .reload };
    try linux.Profile(@TypeOf(plugins)).runWithEnvironment(init, .{
        .plugins = plugins,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .protocols = &protocols.values,
        .compression_threshold = if (scenario == .isolation) null else 256,
        .reload = .{ .executable = if (scenario == .reload) "reload-target" else null },
        .encryption = provider.interface(),
    }, .{
        .permission_policy = if (settings.teleport.enabled) @as(?vanilla.commands.Policy, null) else vanilla.commands.Policy{
            .context = &command_state,
            .allows = command_probe.State.allows,
        },
        .state = &command_state,
        .label = "typed-environment",
        .limit = 7,
    });
}
