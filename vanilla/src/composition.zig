const lightning_rod = @import("lightning_rod");
const generation = @import("vanilla_generation.zig");
const plugins = @import("vanilla_plugins.zig");

const plugin = lightning_rod.plugin;
const seed: u64 = 0x6d_62_75_6e_64_00_00_01;
const worlds = [_]lightning_rod.worlds.Description{
    .{ .key = .{ .value = 1 }, .name = "minecraft:overworld", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Overworld), .generator = generation.Default.generatorId(generation.Overworld), .seed = seed, .spawn_x = 8, .spawn_y = 72, .spawn_z = 8 },
    .{ .key = .{ .value = 2 }, .name = "minecraft:the_nether", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Nether), .generator = generation.Default.generatorId(generation.Nether), .seed = seed, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = .{ .value = 3 }, .name = "minecraft:the_end", .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.End), .generator = generation.Default.generatorId(generation.End), .seed = seed, .spawn_x = 100, .spawn_y = 49, .spawn_z = 0 },
};

const defaults = plugin.compose(.{
    .{
        plugin.configured(lightning_rod.worlds.Worlds, lightning_rod.worlds.Worlds.Configuration{ .initial = &worlds }),
        plugin.configured(lightning_rod.dimensions.Vanilla, lightning_rod.dimensions.Vanilla.Configuration{}),
        plugin.configured(lightning_rod.clock.Clock, lightning_rod.clock.Clock.Configuration{}),
        plugin.configured(lightning_rod.time.Time, lightning_rod.time.Time.Configuration{}),
        plugin.configured(lightning_rod.game_rules.GameRules, lightning_rod.game_rules.GameRules.Configuration{}),
        plugin.configured(lightning_rod.random.Random, lightning_rod.random.Random.Configuration{}),
        plugin.configured(lightning_rod.blocks.Blocks, lightning_rod.blocks.Blocks.Configuration{}),
        plugin.configured(generation.Default, generation.Default.default_configuration),
        plugin.configured(lightning_rod.player_lifecycle.Events, lightning_rod.player_lifecycle.Events.Configuration{}),
        plugin.configured(lightning_rod.players.Players, lightning_rod.players.Players.Configuration{ .initial_world = worlds[0].key }),
        plugin.configured(plugins.status.Status, plugins.status.Status.Configuration{}),
        plugin.configured(@import("vanilla_configuration.zig").ConfigureClient, @import("vanilla_configuration.zig").ConfigureClient.Configuration{}),
        plugin.configured(plugins.active_chunks.ActiveChunks, plugins.active_chunks.ActiveChunks.Configuration{}),
        plugin.configured(lightning_rod.entities.LivingEntities, lightning_rod.entities.LivingEntities.Configuration{}),
        plugin.configured(lightning_rod.entities.ItemEntities, lightning_rod.entities.ItemEntities.Configuration{}),
        plugin.configured(lightning_rod.players.Containers, lightning_rod.players.Containers.Configuration{}),
        plugin.configured(lightning_rod.inputs.Inputs, lightning_rod.inputs.Inputs.Configuration{}),
        plugin.configured(lightning_rod.Packets, lightning_rod.Packets.Configuration{}),
        plugin.configured(plugins.play_decode.PlayDecode, plugins.play_decode.PlayDecode.Configuration{}),
        plugin.configured(lightning_rod.teleportation.Teleportation, lightning_rod.teleportation.Teleportation.Configuration{}),
    },
    .{
        plugin.configured(plugins.chunk_residency.BeginResidency, plugins.chunk_residency.BeginResidency.Configuration{}),
        plugin.configured(plugins.persistence.Persistence, plugins.persistence.Persistence.Configuration{}),
        plugin.configured(plugins.living_death.LivingDeaths, plugins.living_death.LivingDeaths.Configuration{}),
        plugin.configured(plugins.fall_damage.FallTracking, plugins.fall_damage.FallTracking.Configuration{}),
        plugin.configured(plugins.recipes.Recipes, plugins.recipes.Recipes.Configuration{}),
        plugin.configured(plugins.join.PlayJoin, plugins.join.PlayJoin.Configuration{}),
        plugin.configured(plugins.join.PlayJoinMessage, plugins.join.PlayJoinMessage.Configuration{}),
        plugin.configured(plugins.join.PlayJoinProjection, plugins.join.PlayJoinProjection.Configuration{}),
        plugin.configured(plugins.join.PlayDisconnectMessage, plugins.join.PlayDisconnectMessage.Configuration{}),
        plugin.configured(plugins.join.PlayDisconnectProjection, plugins.join.PlayDisconnectProjection.Configuration{}),
        plugin.configured(plugins.commands.Commands, plugins.commands.Commands.Configuration{}),
        plugin.configured(plugins.player_input.MovementValidation, plugins.player_input.MovementValidation.Configuration{}),
        plugin.configured(plugins.player_input.PlayerInput, plugins.player_input.PlayerInput.Configuration{}),
        plugin.configured(plugins.chunk_residency.ChunkResidency, plugins.chunk_residency.ChunkResidency.Configuration{}),
        plugin.configured(plugins.fall_damage.PlayerFallDamage, plugins.fall_damage.PlayerFallDamage.Configuration{}),
        plugin.configured(plugins.player_combat.PlayerCombat, plugins.player_combat.PlayerCombat.Configuration{}),
        plugin.configured(plugins.living_combat.LivingCombat, plugins.living_combat.LivingCombat.Configuration{}),
    },
    .{
        plugin.configured(plugins.slabs.Slabs, plugins.slabs.Slabs.Configuration{}),
        plugin.configured(plugins.chests.Chests, plugins.chests.Chests.Configuration{}),
        plugin.configured(plugins.furnaces.Furnaces, plugins.furnaces.Furnaces.Configuration{}),
        plugin.configured(plugins.hinged_blocks.HingedBlocks, plugins.hinged_blocks.HingedBlocks.Configuration{}),
        plugin.configured(plugins.block_loot.BlockLoot, plugins.block_loot.BlockLoot.Configuration{}),
        plugin.configured(plugins.mining.Mining, plugins.mining.Mining.Configuration{}),
        plugin.configured(plugins.leaf_distance.LeafDistance, plugins.leaf_distance.LeafDistance.Configuration{}),
        plugin.configured(plugins.inventory.Inventory, plugins.inventory.Inventory.Configuration{}),
    },
    .{
        plugin.configured(plugins.random_ticks.ScheduledBlockTicks, plugins.random_ticks.ScheduledBlockTicks.Configuration{}),
        plugin.configured(plugins.random_ticks.CropGrowth, plugins.random_ticks.CropGrowth.Configuration{}),
        plugin.configured(plugins.random_ticks.PlantGrowth, plugins.random_ticks.PlantGrowth.Configuration{}),
        plugin.configured(plugins.random_ticks.PlantSpread, plugins.random_ticks.PlantSpread.Configuration{}),
        plugin.configured(plugins.random_ticks.FarmlandHydration, plugins.random_ticks.FarmlandHydration.Configuration{}),
        plugin.configured(plugins.random_ticks.LeafDecay, plugins.random_ticks.LeafDecay.Configuration{}),
        plugin.configured(plugins.random_ticks.FireAndLava, plugins.random_ticks.FireAndLava.Configuration{}),
        plugin.configured(plugins.random_ticks.IceAndSnow, plugins.random_ticks.IceAndSnow.Configuration{}),
        plugin.configured(plugins.random_ticks.CopperWeathering, plugins.random_ticks.CopperWeathering.Configuration{}),
        plugin.configured(plugins.random_ticks.RandomBlockEvents, plugins.random_ticks.RandomBlockEvents.Configuration{}),
        plugin.configured(plugins.random_ticks.RandomTicks, plugins.random_ticks.RandomTicks.Configuration{}),
        plugin.configured(plugins.lighting.Lighting, plugins.lighting.Lighting.Configuration{}),
    },
    .{
        plugin.configured(plugins.monster_spawning.MonsterSpawning, plugins.monster_spawning.MonsterSpawning.Configuration{}),
        plugin.configured(plugins.passive_spawning.PassiveSpawning, plugins.passive_spawning.PassiveSpawning.Configuration{}),
        plugin.configured(plugins.zombie_ai.ZombieAi, plugins.zombie_ai.ZombieAi.Configuration{}),
        plugin.configured(plugins.zombie_ai.ZombieDaylight, plugins.zombie_ai.ZombieDaylight.Configuration{}),
        plugin.configured(plugins.cow_ai.CowAi, plugins.cow_ai.CowAi.Configuration{}),
        plugin.configured(plugins.pig_ai.PigAi, plugins.pig_ai.PigAi.Configuration{}),
        plugin.configured(plugins.fall_damage.PrimeLivingFalls, plugins.fall_damage.PrimeLivingFalls.Configuration{}),
        plugin.configured(plugins.living_entities.LivingEntityTick, plugins.living_entities.LivingEntityTick.Configuration{}),
        plugin.configured(plugins.fall_damage.LivingFallDamage, plugins.fall_damage.LivingFallDamage.Configuration{}),
        plugin.configured(plugins.living_combat.LivingCombatProjection, plugins.living_combat.LivingCombatProjection.Configuration{}),
    },
    .{
        plugin.configured(plugins.chunk_streaming.ChunkStreaming, plugins.chunk_streaming.ChunkStreaming.Configuration{}),
        plugin.configured(plugins.chat.Prepare, plugins.chat.Prepare.Configuration{}),
        plugin.configured(plugins.chat.Output, plugins.chat.Output.Configuration{}),
        plugin.configured(plugins.player_survival.Survival, plugins.player_survival.Survival.Configuration{}),
        plugin.configured(plugins.item_entities.ItemEntities, plugins.item_entities.ItemEntities.Configuration{}),
        plugin.configured(plugins.zombie_ai.ZombieLoot, plugins.zombie_ai.ZombieLoot.Configuration{}),
        plugin.configured(plugins.commands.UnknownCommands, plugins.commands.UnknownCommands.Configuration{}),
        plugin.configured(plugins.keep_alive.KeepAlive, plugins.keep_alive.KeepAlive.Configuration{}),
        plugin.configured(plugins.end_tick.TimeSync, plugins.end_tick.TimeSync.Configuration{}),
        plugin.configured(plugins.living_death.LivingDeathLoot, plugins.living_death.LivingDeathLoot.Configuration{}),
        plugin.configured(plugins.chunk_residency.EndResidency, plugins.chunk_residency.EndResidency.Configuration{}),
        plugin.configured(plugins.end_tick.EndTick, plugins.end_tick.EndTick.Configuration{}),
    },
});

pub const Plugins = @TypeOf(defaults);

pub fn vanilla() Plugins {
    return defaults;
}
