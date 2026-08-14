const std = @import("std");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const skyblock = @import("skyblock");
const vanilla = @import("vanilla");
const worldguard = @import("worldguard");

const plugin_api = lightning_rod.plugin_api;

pub const protocols = vanilla.protocols;
pub const Configuration = struct {
    server: vanilla.Configuration.Server = .{
        .spawn_world = skyblock.hub_key,
        .status_motd = "Lightning Rod Skyblock",
    },

    pub fn validate(comptime self: Configuration) void {
        self.server.validate();
    }
};
pub const configuration: Configuration = .{};

pub const Extensions = struct {
    economy: *economy.Economy,
    skyblock: *skyblock.Skyblock,

    fn create(storage: *lightning_rod.generation_allocator.Allocator, foundation: *const vanilla.Foundation, guard: *worldguard.WorldGuard, services: *lightning_rod.tick_services.Services) !Extensions {
        const init = plugin_api.Initializer(Plugins){ .storage = storage };
        return .{
            .economy = try init.create(economy.Economy, .{ foundation.players, services.packets, services.io, economy.Config{ .unit = "coin", .precision = 2 } }),
            .skyblock = try init.create(skyblock.Skyblock, .{ foundation.worlds, foundation.blocks, foundation.players, foundation.teleportation, services.packets, services.io, guard }),
        };
    }
};

pub const Protection = struct {
    worldguard: *worldguard.WorldGuard,

    fn create(storage: *lightning_rod.generation_allocator.Allocator, foundation: *const vanilla.Foundation, services: *lightning_rod.tick_services.Services) !Protection {
        const init = plugin_api.Initializer(Plugins){ .storage = storage };
        return .{
            .worldguard = try init.create(worldguard.WorldGuard, .{ foundation.players, foundation.inputs, services.packets, worldguard.Config{} }),
        };
    }
};

pub const Plugins = struct {
    foundation: vanilla.Foundation,
    lifecycle: vanilla.Lifecycle,
    protection: Protection,
    blocks: vanilla.BlockGameplay,
    random_ticks: vanilla.RandomTickGameplay,
    mobs: vanilla.MobGameplay,
    extensions: Extensions,
    output: vanilla.Output,
};

pub fn create(storage: *lightning_rod.generation_allocator.Allocator, services: *lightning_rod.tick_services.Services) !*Plugins {
    const self = try storage.allocator().create(Plugins);
    const foundation = try vanilla.Foundation.create(Plugins, storage, services, .{ .worlds = .{ .initial = &.{skyblock.hub} } });
    const lifecycle = try vanilla.Lifecycle.create(Plugins, storage, &foundation, services);
    const protection = try Protection.create(storage, &foundation, services);
    const blocks = try vanilla.BlockGameplay.create(Plugins, storage, &foundation, &lifecycle, services);
    const random_ticks = try vanilla.RandomTickGameplay.create(Plugins, storage, &foundation, services, .{});
    const mobs = try vanilla.MobGameplay.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    const extensions = try Extensions.create(storage, &foundation, protection.worldguard, services);
    const output = try vanilla.Output.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    self.* = .{ .foundation = foundation, .lifecycle = lifecycle, .protection = protection, .blocks = blocks, .random_ticks = random_ticks, .mobs = mobs, .extensions = extensions, .output = output };
    plugin_api.validate(Plugins);
    return self;
}

pub fn commandDeclarations() [plugin_api.commandDeclarations(Plugins).len]lightning_rod.commands.Declaration {
    return plugin_api.commandDeclarations(Plugins);
}

pub fn stores(plugins: *Plugins) vanilla.Stores {
    return vanilla.storesFromFoundation(&plugins.foundation);
}

test "Skyblock composes Vanilla gameplay and Economy without Shop" {
    comptime configuration.validate();
    const declarations = commandDeclarations();
    var has_hub = false;
    var has_island = false;
    var has_balance = false;
    var has_buy = false;
    for (declarations) |declaration| {
        has_hub = has_hub or std.mem.eql(u8, declaration.name, "hub");
        has_island = has_island or std.mem.eql(u8, declaration.name, "island");
        has_balance = has_balance or std.mem.eql(u8, declaration.name, "balance");
        has_buy = has_buy or std.mem.eql(u8, declaration.name, "buy");
    }
    try std.testing.expect(has_hub and has_island and has_balance);
    try std.testing.expect(!has_buy);
}
