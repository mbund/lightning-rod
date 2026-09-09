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
const persistence_options: lightning_rod.persistence.Configuration = .{
    .maximum_keys = 4_096,
    .maximum_checkpoint_records = 8,
    .maximum_requests = 16,
    .maximum_namespace_bytes = 64,
    .maximum_key_bytes = 64,
    .maximum_value_bytes = 512 * 1024,
};

pub fn main(init: std.process.Init) !void {
    var vanilla_plugins = vanilla.plugins();
    plugin.configure(&vanilla_plugins, lightning_rod.worlds.Worlds, lightning_rod.worlds.Worlds.Configuration{ .initial = &hub_worlds });
    plugin.configure(&vanilla_plugins, lightning_rod.players.Players, lightning_rod.players.Players.Configuration{ .initial_world = skyblock.hub_key });
    plugin.configure(&vanilla_plugins, vanilla.Status, vanilla.Status.Configuration{
        .motd = "Lightning Rod Skyblock",
        .version_name = "Lightning Rod Skyblock",
    });
    plugin.configure(&vanilla_plugins, lightning_rod.blocks.Blocks, lightning_rod.blocks.Blocks.Configuration{
        .maximum_resident_chunks = 64,
        .maximum_modified_sections = 64,
    });
    const plugins = plugin.compose(.{
        plugin.insertAfter(
            plugin.replace(
                vanilla_plugins,
                vanilla.WorldGeneration,
                plugin.configured(skyblock.WorldGeneration, skyblock.WorldGeneration.default_configuration),
            ),
            lightning_rod.Packets,
            plugin.configured(worldguard.WorldGuard, worldguard.WorldGuard.Configuration{}),
        ),
        plugin.configured(economy.Economy, economy.Economy.Configuration{ .unit = "coin", .precision = 2, .maximum_accounts = 64 }),
        plugin.configured(skyblock.Skyblock, skyblock.Skyblock.Configuration{ .seed = seed, .maximum_islands = 256, .maximum_key_attempts = 256 }),
        plugin.configured(tui.Plugin, tui.Plugin.Configuration{}),
    });
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{
        .core_memory_bytes = 128 * 1024 * 1024,
        .root_path = "skyblock.root",
        .persistence = persistence_options,
    });
    try Server.run(init, .{ .plugins = plugins });
}
