const std = @import("std");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const skyblock = @import("skyblock");
const tui = @import("lightning_rod_tui");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const worldguard = @import("worldguard");

pub const std_options: std.Options = .{ .logFn = lightning_rod.logging.logFn };

const plugin = lightning_rod.plugin;
const seed: u64 = 0x6d_62_75_6e_64_00_00_01;
const hub_worlds = [_]lightning_rod.worlds.Description{skyblock.hubDescription(seed)};
pub fn main(init: std.process.Init) !void {
    var chat_service = try skyblock.chat.shared.Service.init(init.gpa, 1, 16);
    defer chat_service.deinit();
    var roster_service = try skyblock.roster.shared.Service.init(init.gpa, 64, 1, 16);
    defer roster_service.deinit();
    const roster_endpoint = try roster_service.activate(0);
    const Roster = skyblock.roster.Publisher(vanilla.TabList);
    const plugins = plugin.compose(.{
        plugin.insertAfter(
            plugin.replace(
                vanilla.plugins(),
                .{
                    plugin.configured(lightning_rod.worlds.Worlds, lightning_rod.worlds.Worlds.Configuration{ .initial = &hub_worlds, .maximum_worlds = 512 }),
                    plugin.configured(lightning_rod.players.Players, lightning_rod.players.Players.Configuration{ .initial_world = skyblock.hub_key, .maximum_connections = 64, .maximum_players = 64 }),
                    plugin.configured(vanilla.Status, vanilla.Status.Configuration{
                        .motd = "Lightning Rod Skyblock",
                        .version_name = "Lightning Rod Skyblock",
                    }),
                    plugin.configured(skyblock.WorldGeneration, skyblock.WorldGeneration.default_configuration),
                    plugin.configured(skyblock.chat.Output, skyblock.chat.Output.Configuration{ .endpoint = &chat_service.endpoints[0] }),
                    plugin.configured(Roster, Roster.Configuration{ .endpoint = roster_endpoint }),
                },
            ),
            lightning_rod.Packets,
            plugin.configured(worldguard.WorldGuard, worldguard.WorldGuard.Configuration{}),
        ),
        plugin.configured(economy.Economy, economy.Economy.Configuration{ .unit = "coin", .precision = 2, .maximum_accounts = 64 }),
        plugin.configured(skyblock.Skyblock, skyblock.Skyblock.Configuration{ .seed = seed, .maximum_islands = 256, .maximum_key_attempts = 256 }),
        plugin.configured(skyblock.chat.Owner, skyblock.chat.Owner.Configuration{ .service = &chat_service }),
        plugin.configured(Roster.Owner, Roster.Owner.Configuration{ .service = &roster_service }),
        plugin.configured(tui.Plugin, tui.Plugin.Configuration{}),
    });
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{
        .port = @import("options").port,
        .memory_bytes = 128 * 1024 * 1024 -
            (comptime skyblock.chat.shared.Service.requiredMemory(1, 16) catch unreachable) -
            (comptime skyblock.roster.shared.Service.requiredMemory(64, 1, 16) catch unreachable),
        .root_path = "lightning-rod-data/skyblock.root",
    });
    try Server.run(init, .{ .plugins = plugins });
}
