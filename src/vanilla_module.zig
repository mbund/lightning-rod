const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla_plugins.zig");

const config = lightning_rod.config.value;
const plugin_api = lightning_rod.plugin_api;
const services_api = lightning_rod.tick_services;

pub const protocols = lightning_rod.protocol_versions.all;

pub const Configuration = struct {
    server: Server = .{},

    pub const Server = struct {
        max_players: u32 = @intCast(config.max_players),
        maximum_memory_bytes: usize = 4 * 1024 * 1024 * 1024,
        storage_io: lightning_rod.tick_io.Configuration = .{},
        default_gamemode: lightning_rod.players.GameMode = .survival,
        status_motd: []const u8 = config.status_motd,
        spawn_world: lightning_rod.world_identity.Key = overworld_key,

        pub fn validate(comptime self: Server) void {
            if (self.max_players == 0 or self.max_players > config.max_players)
                @compileError("configured maximum players exceeds the tick-module capacity");
            if (self.maximum_memory_bytes < 64 * 1024 * 1024)
                @compileError("configured maximum memory must be at least 64 MiB");
        }
    };

    pub fn validate(comptime self: Configuration) void {
        self.server.validate();
    }
};

pub const configuration: Configuration = .{};

pub const overworld_key = lightning_rod.world_identity.Key{ .value = 1 };
pub const nether_key = lightning_rod.world_identity.Key{ .value = 2 };
pub const end_key = lightning_rod.world_identity.Key{ .value = 3 };

pub const default_worlds = [_]lightning_rod.worlds.Description{
    .{ .key = overworld_key, .name = "minecraft:overworld", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Overworld), .generator = lightning_rod.world_generation.Default.generatorId(lightning_rod.world_generation.Overworld), .seed = config.seed, .spawn_x = 8, .spawn_y = config.spawn_y, .spawn_z = 8 },
    .{ .key = nether_key, .name = "minecraft:the_nether", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Nether), .generator = lightning_rod.world_generation.Default.generatorId(lightning_rod.world_generation.Void), .seed = config.seed, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = end_key, .name = "minecraft:the_end", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.End), .generator = lightning_rod.world_generation.Default.generatorId(lightning_rod.world_generation.Void), .seed = config.seed, .spawn_x = 100, .spawn_y = 49, .spawn_z = 0 },
};

pub const Foundation = struct {
    worlds: *lightning_rod.worlds.Worlds,
    dimensions: *lightning_rod.dimensions.Vanilla,
    clock: *lightning_rod.clock.Clock,
    time: *lightning_rod.time.Time,
    game_rules: *lightning_rod.game_rules.GameRules,
    random: *lightning_rod.random.Random,
    blocks: *lightning_rod.blocks.Blocks,
    world_generation: *lightning_rod.world_generation.Default,
    players: *lightning_rod.players.Players,
    living: *lightning_rod.entities.LivingEntities,
    items: *lightning_rod.entities.ItemEntities,
    containers: *lightning_rod.players.Containers,
    inputs: *lightning_rod.inputs.Inputs,
    teleportation: *lightning_rod.teleportation.Teleportation,
    persistence: *vanilla.persistence.Persistence,

    pub const Configuration = struct {
        worlds: lightning_rod.worlds.Configuration,
        blocks: lightning_rod.blocks.Blocks.Configuration = .{},
        world_generation: lightning_rod.world_generation.Default.Configuration =
            lightning_rod.world_generation.Default.default_configuration,
    };

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, services: *services_api.Services, settings: Foundation.Configuration) !Foundation {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        var profile_ns = monotonicNanoseconds();
        const worlds = try init.create(lightning_rod.worlds.Worlds, .{settings.worlds});
        profileInit("worlds", &profile_ns);
        const dimensions = try init.create(lightning_rod.dimensions.Vanilla, .{worlds});
        profileInit("dimensions", &profile_ns);
        const clock = try init.create(lightning_rod.clock.Clock, .{});
        const time = try init.create(lightning_rod.time.Time, .{});
        const game_rules = try init.create(lightning_rod.game_rules.GameRules, .{});
        const random = try init.create(lightning_rod.random.Random, .{});
        profileInit("small_world_state", &profile_ns);
        const blocks = try init.create(lightning_rod.blocks.Blocks, .{settings.blocks});
        profileInit("blocks", &profile_ns);
        const world_generation = try init.create(lightning_rod.world_generation.Default, .{ worlds, blocks, settings.world_generation });
        profileInit("world_generation", &profile_ns);
        const players = try init.create(lightning_rod.players.Players, .{services.lifecycle});
        profileInit("players", &profile_ns);
        const living = try init.create(lightning_rod.entities.LivingEntities, .{});
        profileInit("living_entities", &profile_ns);
        const items = try init.create(lightning_rod.entities.ItemEntities, .{});
        profileInit("item_entities", &profile_ns);
        const containers = try init.create(lightning_rod.players.Containers, .{services.lifecycle});
        const inputs = try init.create(lightning_rod.inputs.Inputs, .{services.lifecycle});
        profileInit("containers_and_inputs", &profile_ns);
        const teleportation = try init.create(lightning_rod.teleportation.Teleportation, .{ worlds, players, living, items, containers, inputs });
        const persistence = try init.create(vanilla.persistence.Persistence, .{ worlds, clock, time, random, blocks, living, players, items, services.io });
        profileInit("teleportation_and_persistence", &profile_ns);
        return .{ .worlds = worlds, .dimensions = dimensions, .clock = clock, .time = time, .game_rules = game_rules, .random = random, .blocks = blocks, .world_generation = world_generation, .players = players, .living = living, .items = items, .containers = containers, .inputs = inputs, .teleportation = teleportation, .persistence = persistence };
    }
};

pub const Lifecycle = struct {
    capacity: *vanilla.connection.Capacity,
    deaths: *vanilla.living_death.LivingDeaths,
    falls: *vanilla.fall_damage.FallTracking,
    recipes: *vanilla.recipes.Recipes,
    join: *vanilla.join.PlayJoin,
    join_message: *vanilla.join.PlayJoinMessage,
    join_projection: *vanilla.join.PlayJoinProjection,
    disconnect_message: *vanilla.join.PlayDisconnectMessage,
    disconnect_projection: *vanilla.join.PlayDisconnectProjection,
    commands: *vanilla.commands.Commands,
    movement_validation: *vanilla.player_input.MovementValidation,
    player_input: *vanilla.player_input.PlayerInput,
    chunk_residency: *vanilla.chunk_residency.ChunkResidency,
    player_fall_damage: *vanilla.fall_damage.PlayerFallDamage,
    player_combat: *vanilla.player_combat.PlayerCombat,
    living_combat: *vanilla.living_combat.LivingCombat,

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, foundation: *const Foundation, services: *services_api.Services) !Lifecycle {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        const capacity = try init.create(vanilla.connection.Capacity, .{});
        const deaths = try init.create(vanilla.living_death.LivingDeaths, .{});
        const falls = try init.create(vanilla.fall_damage.FallTracking, .{});
        const recipes = try init.create(vanilla.recipes.Recipes, .{});
        const join = try init.create(vanilla.join.PlayJoin, .{ foundation.players, services.packets });
        const join_message = try init.create(vanilla.join.PlayJoinMessage, .{ foundation.players, services.packets });
        const join_projection = try init.create(vanilla.join.PlayJoinProjection, .{ foundation.players, foundation.living, services.packets });
        const disconnect_message = try init.create(vanilla.join.PlayDisconnectMessage, .{services.packets});
        const disconnect_projection = try init.create(vanilla.join.PlayDisconnectProjection, .{services.packets});
        const command_plugin = try init.create(vanilla.commands.Commands, .{ foundation.clock, foundation.time, foundation.random, foundation.blocks, foundation.players, foundation.living, services.packets });
        const movement = try init.create(vanilla.player_input.MovementValidation, .{ foundation.blocks, foundation.players, foundation.inputs, services.packets });
        const player_input = try init.create(vanilla.player_input.PlayerInput, .{ foundation.clock, foundation.worlds, foundation.blocks, foundation.players, foundation.inputs, services.packets });
        const chunk_residency = try init.create(vanilla.chunk_residency.ChunkResidency, .{ foundation.blocks, foundation.players, foundation.living, foundation.items, foundation.inputs, services.packets });
        const player_fall = try init.create(vanilla.fall_damage.PlayerFallDamage, .{ falls, foundation.blocks, foundation.players, services.packets });
        const player_combat = try init.create(vanilla.player_combat.PlayerCombat, .{ foundation.blocks, foundation.players, foundation.inputs, services.packets });
        const living_combat = try init.create(vanilla.living_combat.LivingCombat, .{ deaths, foundation.random, foundation.game_rules, foundation.blocks, foundation.players, foundation.living, foundation.inputs, services.packets });
        return .{
            .capacity = capacity,
            .deaths = deaths,
            .falls = falls,
            .recipes = recipes,
            .join = join,
            .join_message = join_message,
            .join_projection = join_projection,
            .disconnect_message = disconnect_message,
            .disconnect_projection = disconnect_projection,
            .commands = command_plugin,
            .movement_validation = movement,
            .player_input = player_input,
            .chunk_residency = chunk_residency,
            .player_fall_damage = player_fall,
            .player_combat = player_combat,
            .living_combat = living_combat,
        };
    }
};

pub const BlockGameplay = struct {
    slabs: *vanilla.slabs.Slabs,
    chests: *vanilla.chests.Chests,
    furnaces: *vanilla.furnaces.Furnaces,
    hinged_blocks: *vanilla.hinged_blocks.HingedBlocks,
    block_loot: *vanilla.block_loot.BlockLoot,
    mining: *vanilla.mining.Mining,
    leaf_distance: *vanilla.leaf_distance.LeafDistance,
    inventory: *vanilla.inventory.Inventory,

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, foundation: *const Foundation, lifecycle: *const Lifecycle, services: *services_api.Services) !BlockGameplay {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        const slabs = try init.create(vanilla.slabs.Slabs, .{ foundation.blocks, foundation.players, foundation.inputs, services.packets });
        const chests = try init.create(vanilla.chests.Chests, .{ foundation.worlds, foundation.random, foundation.blocks, foundation.players, foundation.items, foundation.inputs, foundation.containers, services.packets, services.io });
        const furnaces = try init.create(vanilla.furnaces.Furnaces, .{ foundation.worlds, foundation.random, foundation.blocks, foundation.players, foundation.items, foundation.inputs, foundation.containers, lifecycle.recipes, services.packets, services.io });
        const hinged = try init.create(vanilla.hinged_blocks.HingedBlocks, .{ foundation.blocks, foundation.players, foundation.inputs, services.packets });
        const loot = try init.create(vanilla.block_loot.BlockLoot, .{});
        return .{
            .slabs = slabs,
            .chests = chests,
            .furnaces = furnaces,
            .hinged_blocks = hinged,
            .block_loot = loot,
            .mining = try init.create(vanilla.mining.Mining, .{ foundation.clock, foundation.random, foundation.blocks, foundation.players, foundation.items, foundation.inputs, foundation.containers, loot, services.packets }),
            .leaf_distance = try init.create(vanilla.leaf_distance.LeafDistance, .{ foundation.blocks, foundation.inputs, services.packets }),
            .inventory = try init.create(vanilla.inventory.Inventory, .{ foundation.random, foundation.blocks, foundation.players, foundation.items, foundation.inputs, foundation.containers, lifecycle.recipes, services.packets, services.lifecycle }),
        };
    }
};

pub const RandomTickGameplay = struct {
    scheduled: *vanilla.random_ticks.ScheduledBlockTicks,
    crops: *vanilla.random_ticks.CropGrowth,
    plant_growth: *vanilla.random_ticks.PlantGrowth,
    plant_spread: *vanilla.random_ticks.PlantSpread,
    farmland: *vanilla.random_ticks.FarmlandHydration,
    leaves: *vanilla.random_ticks.LeafDecay,
    fire_and_lava: *vanilla.random_ticks.FireAndLava,
    ice_and_snow: *vanilla.random_ticks.IceAndSnow,
    copper: *vanilla.random_ticks.CopperWeathering,
    block_events: *vanilla.random_ticks.RandomBlockEvents,
    random_ticks: *vanilla.random_ticks.RandomTicks,
    lighting: *vanilla.lighting.Lighting,

    pub const Configuration = struct {
        random_ticks: vanilla.random_ticks.RandomTicks.Configuration = .{},
        lighting: vanilla.lighting.Lighting.Configuration = .{},
    };

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, foundation: *const Foundation, services: *services_api.Services, settings: RandomTickGameplay.Configuration) !RandomTickGameplay {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        const scheduled = try init.create(vanilla.random_ticks.ScheduledBlockTicks, .{});
        const crops = try init.create(vanilla.random_ticks.CropGrowth, .{});
        const growth = try init.create(vanilla.random_ticks.PlantGrowth, .{});
        const spread = try init.create(vanilla.random_ticks.PlantSpread, .{});
        const farmland = try init.create(vanilla.random_ticks.FarmlandHydration, .{});
        const leaves = try init.create(vanilla.random_ticks.LeafDecay, .{});
        const fire_and_lava = try init.create(vanilla.random_ticks.FireAndLava, .{});
        const ice_and_snow = try init.create(vanilla.random_ticks.IceAndSnow, .{});
        const copper = try init.create(vanilla.random_ticks.CopperWeathering, .{});
        const events = try init.create(vanilla.random_ticks.RandomBlockEvents, .{});
        return .{
            .scheduled = scheduled,
            .crops = crops,
            .plant_growth = growth,
            .plant_spread = spread,
            .farmland = farmland,
            .leaves = leaves,
            .fire_and_lava = fire_and_lava,
            .ice_and_snow = ice_and_snow,
            .copper = copper,
            .block_events = events,
            .random_ticks = try init.create(vanilla.random_ticks.RandomTicks, .{ scheduled, crops, growth, spread, farmland, leaves, fire_and_lava, ice_and_snow, copper, events, foundation.worlds, foundation.clock, foundation.time, foundation.game_rules, foundation.random, foundation.blocks, foundation.players, foundation.living, foundation.items, services.packets, settings.random_ticks }),
            .lighting = try init.create(vanilla.lighting.Lighting, .{ foundation.clock, foundation.blocks, services.packets, settings.lighting }),
        };
    }
};

pub const MobGameplay = struct {
    monster_spawning: *vanilla.monster_spawning.MonsterSpawning,
    passive_spawning: *vanilla.passive_spawning.PassiveSpawning,
    zombie_ai: *vanilla.zombie_ai.ZombieAi,
    zombie_daylight: *vanilla.zombie_ai.ZombieDaylight,
    cow_ai: *vanilla.cow_ai.CowAi,
    pig_ai: *vanilla.pig_ai.PigAi,
    prime_living_falls: *vanilla.fall_damage.PrimeLivingFalls,
    living_tick: *vanilla.living_entities.LivingEntityTick,
    living_fall_damage: *vanilla.fall_damage.LivingFallDamage,
    combat_projection: *vanilla.living_combat.LivingCombatProjection,

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, foundation: *const Foundation, lifecycle: *const Lifecycle, random_tick: *const RandomTickGameplay, services: *services_api.Services) !MobGameplay {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        return .{
            .monster_spawning = try init.create(vanilla.monster_spawning.MonsterSpawning, .{ random_tick.lighting, foundation.worlds, foundation.clock, foundation.time, foundation.game_rules, foundation.random, foundation.blocks, foundation.players, foundation.living, services.packets }),
            .passive_spawning = try init.create(vanilla.passive_spawning.PassiveSpawning, .{ foundation.worlds, foundation.clock, foundation.game_rules, foundation.random, foundation.blocks, foundation.players, foundation.living, services.packets }),
            .zombie_ai = try init.create(vanilla.zombie_ai.ZombieAi, .{ foundation.clock, foundation.game_rules, foundation.random, foundation.blocks, foundation.players, foundation.living, foundation.items, services.packets }),
            .zombie_daylight = try init.create(vanilla.zombie_ai.ZombieDaylight, .{ foundation.time, foundation.blocks, foundation.players, foundation.living }),
            .cow_ai = try init.create(vanilla.cow_ai.CowAi, .{ foundation.random, foundation.blocks, foundation.players, foundation.living, foundation.items, foundation.inputs, services.packets }),
            .pig_ai = try init.create(vanilla.pig_ai.PigAi, .{ foundation.random, foundation.blocks, foundation.players, foundation.living, foundation.inputs, services.packets }),
            .prime_living_falls = try init.create(vanilla.fall_damage.PrimeLivingFalls, .{ lifecycle.falls, foundation.living }),
            .living_tick = try init.create(vanilla.living_entities.LivingEntityTick, .{ lifecycle.deaths, foundation.clock, foundation.blocks, foundation.players, foundation.living, services.packets }),
            .living_fall_damage = try init.create(vanilla.fall_damage.LivingFallDamage, .{ lifecycle.falls, lifecycle.deaths, foundation.blocks, foundation.players, foundation.living, services.packets }),
            .combat_projection = try init.create(vanilla.living_combat.LivingCombatProjection, .{ lifecycle.living_combat, services.packets }),
        };
    }
};

pub const Output = struct {
    chunk_streaming: *vanilla.chunk_streaming.ChunkStreaming,
    chat_prepare: *vanilla.chat.Prepare,
    chat_output: *vanilla.chat.Output,
    survival: *vanilla.player_survival.Survival,
    item_entities: *vanilla.item_entities.ItemEntities,
    zombie_loot: *vanilla.zombie_ai.ZombieLoot,
    unknown_commands: *vanilla.commands.UnknownCommands,
    keep_alive: *vanilla.keep_alive.KeepAlive,
    time_sync: *vanilla.end_tick.TimeSync,
    death_loot: *vanilla.living_death.LivingDeathLoot,
    end_tick: *vanilla.end_tick.EndTick,

    pub fn create(comptime Composition: type, storage: *lightning_rod.generation_allocator.Allocator, foundation: *const Foundation, lifecycle: *const Lifecycle, random_tick: *const RandomTickGameplay, services: *services_api.Services) !Output {
        const init = plugin_api.Initializer(Composition){ .storage = storage };
        return .{
            .chunk_streaming = try init.create(vanilla.chunk_streaming.ChunkStreaming, .{ random_tick.lighting, services.packets }),
            .chat_prepare = try init.create(vanilla.chat.Prepare, .{ foundation.players, services.packets }),
            .chat_output = try init.create(vanilla.chat.Output, .{ foundation.players, services.packets, vanilla.chat.OutputConfig{} }),
            .survival = try init.create(vanilla.player_survival.Survival, .{ foundation.game_rules, foundation.players, services.packets }),
            .item_entities = try init.create(vanilla.item_entities.ItemEntities, .{ foundation.clock, foundation.blocks, foundation.players, foundation.items, services.packets }),
            .zombie_loot = try init.create(vanilla.zombie_ai.ZombieLoot, .{ foundation.clock, foundation.game_rules, foundation.random, foundation.blocks, foundation.players, foundation.living, foundation.items, services.packets }),
            .unknown_commands = try init.create(vanilla.commands.UnknownCommands, .{services.packets}),
            .keep_alive = try init.create(vanilla.keep_alive.KeepAlive, .{ foundation.clock, services.packets }),
            .time_sync = try init.create(vanilla.end_tick.TimeSync, .{ foundation.clock, services.packets }),
            .death_loot = try init.create(vanilla.living_death.LivingDeathLoot, .{ lifecycle.deaths, foundation.random, foundation.blocks, foundation.living, foundation.items, services.packets }),
            .end_tick = try init.create(vanilla.end_tick.EndTick, .{ foundation.clock, foundation.time, foundation.game_rules }),
        };
    }
};

pub const Plugins = struct {
    foundation: Foundation,
    lifecycle: Lifecycle,
    blocks: BlockGameplay,
    random_ticks: RandomTickGameplay,
    mobs: MobGameplay,
    output: Output,
};

pub fn create(storage: *lightning_rod.generation_allocator.Allocator, services: *services_api.Services) !*Plugins {
    var profile_ns = monotonicNanoseconds();
    const self = try storage.allocator().create(Plugins);
    const foundation = try Foundation.create(Plugins, storage, services, .{ .worlds = .{ .initial = &default_worlds } });
    profileInit("foundation", &profile_ns);
    const lifecycle = try Lifecycle.create(Plugins, storage, &foundation, services);
    profileInit("lifecycle", &profile_ns);
    const blocks = try BlockGameplay.create(Plugins, storage, &foundation, &lifecycle, services);
    profileInit("block_gameplay", &profile_ns);
    const random_ticks = try RandomTickGameplay.create(Plugins, storage, &foundation, services, .{});
    profileInit("random_ticks", &profile_ns);
    const mobs = try MobGameplay.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    profileInit("mob_gameplay", &profile_ns);
    const output = try Output.create(Plugins, storage, &foundation, &lifecycle, &random_ticks, services);
    profileInit("output", &profile_ns);
    self.* = .{ .foundation = foundation, .lifecycle = lifecycle, .blocks = blocks, .random_ticks = random_ticks, .mobs = mobs, .output = output };
    plugin_api.validate(Plugins);
    return self;
}

fn profileInit(name: []const u8, previous_ns: *u64) void {
    const now_ns = monotonicNanoseconds();
    std.log.info("event=vanilla_init_profile component={s} elapsed_ms={d:.3}", .{
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

pub const Stores = struct {
    worlds: *lightning_rod.worlds.Worlds,
    clock: *lightning_rod.clock.Clock,
    time: *lightning_rod.time.Time,
    game_rules: *lightning_rod.game_rules.GameRules,
    random: *lightning_rod.random.Random,
    inputs: *lightning_rod.inputs.Inputs,
    containers: *lightning_rod.players.Containers,
    blocks: *lightning_rod.blocks.Blocks,
    living: *lightning_rod.entities.LivingEntities,
    players: *lightning_rod.players.Players,
    items: *lightning_rod.entities.ItemEntities,
};

pub fn stores(plugins: *Plugins) Stores {
    return storesFromFoundation(&plugins.foundation);
}

pub fn storesFromFoundation(foundation: *Foundation) Stores {
    return .{ .worlds = foundation.worlds, .clock = foundation.clock, .time = foundation.time, .game_rules = foundation.game_rules, .random = foundation.random, .inputs = foundation.inputs, .containers = foundation.containers, .blocks = foundation.blocks, .living = foundation.living, .players = foundation.players, .items = foundation.items };
}
