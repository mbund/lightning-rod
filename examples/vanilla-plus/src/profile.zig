const std = @import("std");
const economy = @import("economy");
const lightning_rod = @import("lightning_rod");
const shop = @import("shop");
const vanilla = @import("vanilla");

const plugin_api = lightning_rod.plugin_api;

pub const protocols = vanilla.protocols;
pub const Configuration = struct {
    server: vanilla.Configuration.Server = .{},

    pub fn validate(comptime self: Configuration) void {
        self.server.validate();
    }
};
pub const configuration: Configuration = .{
    .server = .{
        .maximum_memory_bytes = 128 * 1024 * 1024,
        .storage_io = .{ .maximum_concurrent_operations = 64 },
    },
};

pub const Extensions = struct {
    economy: *economy.Economy,
    shop: *shop.Shop,

    fn create(storage: *lightning_rod.generation_allocator.Allocator, foundation: *const vanilla.Foundation, services: *lightning_rod.tick_services.Services) !Extensions {
        const init = plugin_api.Initializer(Plugins){ .storage = storage };
        const economy_plugin = try init.create(economy.Economy, .{ foundation.players, services.packets, services.io, economy.Config{ .unit = "credit", .precision = 3 } });
        return .{
            .economy = economy_plugin,
            .shop = try init.create(shop.Shop, .{ foundation.players, economy_plugin, services.packets, shop.Config{
                .offers = &.{.{ .item = "minecraft:bread", .buy = 750, .sell = 300 }},
            } }),
        };
    }
};

pub const Plugins = struct {
    foundation: vanilla.Foundation,
    lifecycle: vanilla.Lifecycle,
    blocks: vanilla.BlockGameplay,
    random_ticks: vanilla.RandomTickGameplay,
    mobs: vanilla.MobGameplay,
    extensions: Extensions,
    output: vanilla.Output,
};

pub fn create(storage: *lightning_rod.generation_allocator.Allocator, services: *lightning_rod.tick_services.Services) !*Plugins {
    var profile_ns = monotonicNanoseconds();
    const self = try storage.allocator().create(Plugins);
    const foundation = try vanilla.Foundation.create(Plugins, storage, services, .{
        .worlds = .{ .initial = &vanilla.default_worlds },
        .blocks = .{
            .maximum_resident_chunks = 256,
            .maximum_modified_sections = 128,
        },
        .world_generation = .{
            lightning_rod.world_generation.Overworld{ .base_chunk_cache_capacity = 3 },
            lightning_rod.world_generation.Void{},
            lightning_rod.world_generation.Flat{},
        },
    });
    profileInit("foundation", &profile_ns);
    const lifecycle = try vanilla.Lifecycle.create(Plugins, storage, &foundation, services);
    profileInit("lifecycle", &profile_ns);
    const blocks = try vanilla.BlockGameplay.create(Plugins, storage, &foundation, &lifecycle, services);
    profileInit("block_gameplay", &profile_ns);
    const random_ticks = try vanilla.RandomTickGameplay.create(Plugins, storage, &foundation, services, .{
        .random_ticks = .{ .maximum_ticking_chunks = 256 },
        .lighting = .{
            .maximum_cached_chunks = 256,
            .light_pages = 512,
            .source_mutations = 16,
        },
    });
    profileInit("random_ticks", &profile_ns);
    const mobs = try vanilla.MobGameplay.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    profileInit("mob_gameplay", &profile_ns);
    const extensions = try Extensions.create(storage, &foundation, services);
    profileInit("extensions", &profile_ns);
    const output = try vanilla.Output.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    profileInit("output", &profile_ns);
    self.* = .{ .foundation = foundation, .lifecycle = lifecycle, .blocks = blocks, .random_ticks = random_ticks, .mobs = mobs, .extensions = extensions, .output = output };
    plugin_api.validate(Plugins);
    return self;
}

fn profileInit(name: []const u8, previous_ns: *u64) void {
    const now_ns = monotonicNanoseconds();
    std.log.info("event=profile_init component={s} elapsed_ms={d:.3}", .{
        name,
        @as(f64, @floatFromInt(now_ns -| previous_ns.*)) / std.time.ns_per_ms,
    });
    previous_ns.* = now_ns;
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(now.nsec));
}

pub fn commandDeclarations() [plugin_api.commandDeclarations(Plugins).len]lightning_rod.commands.Declaration {
    return plugin_api.commandDeclarations(Plugins);
}

pub fn stores(plugins: *Plugins) vanilla.Stores {
    return vanilla.storesFromFoundation(&plugins.foundation);
}
