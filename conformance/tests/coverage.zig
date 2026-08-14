const std = @import("std");
const scenarios = @import("scenarios.zig");

pub const Domain = enum {
    connection,
    protocol,
    world,
    blocks,
    inventory,
    player,
    combat,
    entities,
    spawning,
    commands,
    persistence,
    security,
    extensibility,
};

pub const Priority = enum(u8) {
    p0,
    p1,
    p2,
    p3,
};

pub const Status = enum(u8) {
    missing,
    partial,
    implemented,
    packet_tested,
    vanilla_verified,
};

pub const CostModel = enum {
    constant,
    per_connection,
    per_player,
    per_active_chunk,
    per_entity,
    per_item_entity,
    per_block_event,
    io_boundary,
};

pub const Foundation = enum {
    entities,
    combat,
    gravity,
    mining,
    players,
    inventory,
    storage,
    lighting,
    drops,
};

pub const Feature = struct {
    id: []const u8,
    domain: Domain,
    priority: Priority,
    status: Status,
    importance: u8,
    cost: CostModel,
    scenarios: []const []const u8 = &.{},
    leverage: u8 = 50,
    effort: u8 = 8,
    foundation: ?Foundation = null,
};

pub const CompletionEvidence = packed struct {
    vanilla_observation: bool = false,
    black_box_conformance: bool = false,
    production_implementation: bool = false,
    performance_measurement: bool = false,
    plugin_boundary_review: bool = false,

    pub fn complete(self: CompletionEvidence) bool {
        return self.vanilla_observation and
            self.black_box_conformance and
            self.production_implementation and
            self.performance_measurement and
            self.plugin_boundary_review;
    }
};

const s = struct {
    const movement = &.{"two client movement"};
    const rotation = &.{"player rotation head and body"};
    const player_collision = &.{"player collision and one block step"};
    const sneaking = &.{"sneaking synchronization"};
    const sprinting = &.{"sprinting synchronization"};
    const mining = &.{
        "survival mining with correct tool",
        "survival mining with wrong tool",
        "survival mining with empty hand",
        "creative instant mining",
        "mining start and abort",
    };
    const mining_loot = &.{
        "survival mining with correct tool",
        "survival mining with wrong tool",
        "survival mining with empty hand",
        "creative instant mining",
        "representative block loot tables",
        "broken oak sapling drops itself",
        "oak leaf drop distribution",
    };
    const block_loot = &.{"representative block loot tables"};
    const crafting = &.{ "craft all", "crafting close clears grid" };
    const placement = &.{"two block placement"};
    const chests = &.{ "shared chest inventory", "chest placement facings" };
    const furnaces = &.{ "furnace smelting", "furnace placement facings" };
    const persistent_block_entities = &.{ "restart persists chest inventory", "restart persists furnace progress" };
    const disconnect = &.{"player disconnect"};
    const held_item = &.{
        "login held item",
        "survival pick block selects matching hotbar stack",
        "creative pick block creates and selects stack",
    };
    const player_inventory_clicks = &.{
        "player inventory click modes",
        "creative slot changes preserve packet order",
    };
    const knockback = &.{ "zombie knockback", "player melee combat" };
    const entity_lifecycle = &.{ "entity lifecycle replication", "mob death and removal" };
    const player_attacks_mob = &.{"player attacks mob"};
    const player_melee = &.{ "player melee combat", "player melee death" };
    const player_death = &.{"mob attacks player and respawn"};
    const player_fall = &.{"player fall motion and landing"};
    const living_fall_death = &.{"falling living entities damage die and drop loot"};
    const item_entities = &.{
        "item spawn motion and landing",
        "compatible item stacks merge",
        "item pickup delay and collection",
        "item despawns at 6000 ticks",
    };
    const cows = &.{
        "cow follows wheat",
        "cow breeding",
        "cow panic",
        "cow ambient sound",
        "calf follows parent",
        "cow swimming",
        "cow milking",
        "calves cannot be milked",
        "cow idle wandering",
        "cow looks at nearby players",
    };
    const leaves = &.{ "broken oak sapling drops itself", "oak leaf drop distribution" };
    const trapdoors = &.{"zombie open trapdoor"};
    const hinged_blocks = &.{
        "trapdoor placement and flipping",
        "door placement and flipping",
        "adjacent doors choose opposite hinges",
        "door placement rejects leaves support",
        "doors require a slab top support face",
    };
    const slabs = &.{"slab placement and merging"};
    const random_ticks = &.{"random tick mechanics"};
    const time = &.{ "time command lifecycle", "daylight cycle progression", "disabled daylight cycle" };
    const zombie_daylight = &.{"zombie daylight burning"};
    const natural_spawning = &.{ "daytime natural spawning", "nighttime natural spawning" };
    const flight = &.{"survival hover rejected"};
    const reach = &.{"remote mining rejected"};
    const inventory_authority = &.{"inventory claim rejected"};
    const persistence_world_player = &.{"restart persists world and player"};
    const persistence_entities = &.{"restart persists item and living entities"};
    const lighting = &.{
        "lighting foundation packets",
        "lighting removal packets",
        "lighting removal preserves overlapping sources",
    };
};

pub const features = [_]Feature{
    .{ .id = "connection.status_ping", .domain = .connection, .priority = .p0, .status = .implemented, .importance = 90, .cost = .per_connection },
    .{ .id = "connection.login_configuration_play", .domain = .connection, .priority = .p0, .status = .partial, .importance = 100, .cost = .per_connection },
    .{ .id = "connection.encryption", .domain = .connection, .priority = .p0, .status = .implemented, .importance = 95, .cost = .per_connection },
    .{ .id = "connection.compression", .domain = .connection, .priority = .p0, .status = .implemented, .importance = 90, .cost = .per_connection },
    .{ .id = "connection.keep_alive", .domain = .connection, .priority = .p0, .status = .implemented, .importance = 85, .cost = .per_connection },
    .{ .id = "connection.disconnect_visibility", .domain = .connection, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_player, .scenarios = s.disconnect },
    .{ .id = "connection.reconnect_persistence", .domain = .connection, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_connection, .scenarios = s.held_item },
    .{ .id = "connection.capacity_and_duplicate_login", .domain = .connection, .priority = .p1, .status = .partial, .importance = 75, .cost = .per_connection },
    .{ .id = "protocol.multi_version_1_21_6_1_21_8", .domain = .protocol, .priority = .p0, .status = .implemented, .importance = 95, .cost = .per_connection },
    .{ .id = "protocol.packet_decode_validation", .domain = .protocol, .priority = .p0, .status = .partial, .importance = 95, .cost = .per_connection },
    .{ .id = "protocol.packet_encode_all_play", .domain = .protocol, .priority = .p0, .status = .partial, .importance = 95, .cost = .per_connection },
    .{ .id = "protocol.components_nbt_data_components", .domain = .protocol, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_block_event },
    .{ .id = "protocol.version_hot_add", .domain = .protocol, .priority = .p1, .status = .partial, .importance = 80, .cost = .constant },

    .{ .id = "world.chunk_generation", .domain = .world, .priority = .p0, .status = .partial, .importance = 100, .cost = .per_active_chunk },
    .{ .id = "world.chunk_loading_and_streaming", .domain = .world, .priority = .p0, .status = .implemented, .importance = 100, .cost = .per_active_chunk },
    .{ .id = "world.chunk_ticket_levels", .domain = .world, .priority = .p0, .status = .partial, .importance = 95, .cost = .per_active_chunk },
    .{ .id = "world.chunk_unload", .domain = .world, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_active_chunk },
    .{ .id = "world.block_light", .domain = .world, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_block_event, .scenarios = s.lighting, .foundation = .lighting },
    .{ .id = "world.sky_light", .domain = .world, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_active_chunk, .scenarios = s.lighting, .foundation = .lighting },
    .{ .id = "world.heightmaps", .domain = .world, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_block_event },
    .{ .id = "world.biomes", .domain = .world, .priority = .p1, .status = .partial, .importance = 80, .cost = .per_active_chunk },
    .{ .id = "world.weather", .domain = .world, .priority = .p1, .status = .missing, .importance = 75, .cost = .constant },
    .{ .id = "world.daylight_cycle_and_sync", .domain = .world, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .constant, .scenarios = s.time },
    .{ .id = "world.dimensions_and_portals", .domain = .world, .priority = .p1, .status = .partial, .importance = 85, .cost = .per_player },
    .{ .id = "world.world_border", .domain = .world, .priority = .p2, .status = .missing, .importance = 50, .cost = .per_player },

    .{ .id = "blocks.placement", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_block_event, .scenarios = s.placement },
    .{ .id = "blocks.mining_progress_abort_finish", .domain = .blocks, .priority = .p0, .status = .vanilla_verified, .importance = 100, .cost = .per_block_event, .scenarios = s.mining, .foundation = .mining },
    .{ .id = "blocks.break_loot_and_tools", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_block_event, .scenarios = s.mining_loot, .foundation = .drops },
    .{ .id = "blocks.neighbor_updates", .domain = .blocks, .priority = .p0, .status = .partial, .importance = 100, .cost = .per_block_event },
    .{ .id = "blocks.scheduled_ticks", .domain = .blocks, .priority = .p0, .status = .partial, .importance = 95, .cost = .per_block_event, .scenarios = s.random_ticks },
    .{ .id = "blocks.random_ticks", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_active_chunk, .scenarios = s.random_ticks },
    .{ .id = "blocks.fluids", .domain = .blocks, .priority = .p0, .status = .partial, .importance = 95, .cost = .per_block_event },
    .{ .id = "blocks.redstone", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 90, .cost = .per_block_event },
    .{ .id = "blocks.pistons", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 85, .cost = .per_block_event },
    .{ .id = "blocks.gravity", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 70, .cost = .per_block_event, .foundation = .gravity },
    .{ .id = "blocks.fire", .domain = .blocks, .priority = .p1, .status = .packet_tested, .importance = 75, .cost = .per_block_event, .scenarios = s.random_ticks },
    .{ .id = "blocks.crops_plants_growth", .domain = .blocks, .priority = .p1, .status = .packet_tested, .importance = 75, .cost = .per_active_chunk, .scenarios = s.random_ticks },
    .{ .id = "blocks.leaves_distance_decay_loot", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 85, .cost = .per_block_event, .scenarios = s.leaves },
    .{ .id = "blocks.chests", .domain = .blocks, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_block_event, .scenarios = s.chests },
    .{ .id = "blocks.furnaces", .domain = .blocks, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_block_event, .scenarios = s.furnaces },
    .{ .id = "blocks.doors_and_trapdoors", .domain = .blocks, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_block_event, .scenarios = s.hinged_blocks },
    .{ .id = "blocks.slabs", .domain = .blocks, .priority = .p0, .status = .vanilla_verified, .importance = 85, .cost = .per_block_event, .scenarios = s.slabs },
    .{ .id = "blocks.signs", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 65, .cost = .per_block_event },
    .{ .id = "blocks.beds_and_respawn_points", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 80, .cost = .per_player },
    .{ .id = "blocks.enchanting_anvil_brewing", .domain = .blocks, .priority = .p1, .status = .missing, .importance = 80, .cost = .per_block_event },
    .{ .id = "mining.harvest_speed_and_tool_tiers", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_block_event, .scenarios = s.mining, .foundation = .mining },
    .{ .id = "mining.survival_creative_adventure_rules", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_block_event, .scenarios = s.mining, .foundation = .mining },
    .{ .id = "mining.durability_and_enchantments", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .per_block_event, .scenarios = s.mining, .foundation = .mining },
    .{ .id = "lighting.propagation_and_removal", .domain = .world, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_block_event, .scenarios = s.lighting, .foundation = .lighting },
    .{ .id = "lighting.chunk_initialization_and_edges", .domain = .world, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_active_chunk, .scenarios = s.lighting, .foundation = .lighting },
    .{ .id = "lighting.packet_representation", .domain = .protocol, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_active_chunk, .scenarios = s.lighting, .foundation = .lighting },
    .{ .id = "drops.block_loot_tables", .domain = .blocks, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_block_event, .scenarios = s.block_loot, .foundation = .drops },
    .{ .id = "drops.entity_loot_tables", .domain = .entities, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_entity, .scenarios = s.living_fall_death, .foundation = .drops },
    .{ .id = "drops.item_spawn_motion_merge_despawn", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_item_entity, .scenarios = s.item_entities, .foundation = .drops },

    .{ .id = "inventory.slot_authority", .domain = .inventory, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_player, .scenarios = s.inventory_authority, .foundation = .inventory },
    .{ .id = "inventory.hotbar_selection_replication", .domain = .inventory, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_player, .scenarios = s.held_item, .foundation = .inventory },
    .{ .id = "inventory.player_inventory_clicks", .domain = .inventory, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_player, .scenarios = s.player_inventory_clicks, .foundation = .inventory },
    .{ .id = "inventory.container_click_modes", .domain = .inventory, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_player, .foundation = .inventory },
    .{ .id = "inventory.crafting_2x2_3x3", .domain = .inventory, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_player, .scenarios = s.crafting, .foundation = .inventory },
    .{ .id = "inventory.recipe_book", .domain = .inventory, .priority = .p1, .status = .partial, .importance = 65, .cost = .per_player, .foundation = .inventory },
    .{ .id = "inventory.item_components", .domain = .inventory, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_player, .foundation = .inventory },
    .{ .id = "inventory.durability_enchantments", .domain = .inventory, .priority = .p1, .status = .partial, .importance = 80, .cost = .per_block_event, .foundation = .inventory },
    .{ .id = "inventory.item_use_food_bows_potions", .domain = .inventory, .priority = .p0, .status = .missing, .importance = 95, .cost = .per_player, .foundation = .inventory },
    .{ .id = "inventory.item_drop_pickup_merge", .domain = .inventory, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_item_entity, .scenarios = s.item_entities, .foundation = .drops },

    .{ .id = "player.movement_replication", .domain = .player, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_player, .scenarios = s.movement, .foundation = .players },
    .{ .id = "player.rotation_head_body", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_player, .scenarios = s.rotation, .foundation = .players },
    .{ .id = "player.sneaking", .domain = .player, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .per_player, .scenarios = s.sneaking, .foundation = .players },
    .{ .id = "player.sprinting", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 85, .cost = .per_player, .scenarios = s.sprinting, .foundation = .players },
    .{ .id = "player.swimming_crawling_gliding", .domain = .player, .priority = .p1, .status = .missing, .importance = 80, .cost = .per_player },
    .{ .id = "player.collision_step_height", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_player, .scenarios = s.player_collision, .foundation = .gravity },
    .{ .id = "player.fall_damage", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_player, .scenarios = s.player_fall, .foundation = .gravity },
    .{ .id = "player.health_death_respawn", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 100, .cost = .per_player, .scenarios = s.player_death, .foundation = .players, .leverage = 100, .effort = 3 },
    .{ .id = "player.hunger_saturation_regeneration", .domain = .player, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_player, .foundation = .players },
    .{ .id = "player.experience_levels", .domain = .player, .priority = .p1, .status = .partial, .importance = 75, .cost = .per_player },
    .{ .id = "player.gamemodes_and_abilities", .domain = .player, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_player, .foundation = .players },
    .{ .id = "gravity.player_motion_and_landing", .domain = .player, .priority = .p0, .status = .vanilla_verified, .importance = 100, .cost = .per_player, .scenarios = s.player_fall, .foundation = .gravity },
    .{ .id = "gravity.living_entity_motion_and_landing", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_entity, .scenarios = s.living_fall_death, .foundation = .gravity },
    .{ .id = "gravity.item_entity_motion_and_landing", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_item_entity, .scenarios = s.item_entities, .foundation = .gravity },
    .{ .id = "player.effects_attributes", .domain = .player, .priority = .p1, .status = .missing, .importance = 85, .cost = .per_player },
    .{ .id = "player.advancements_statistics", .domain = .player, .priority = .p2, .status = .missing, .importance = 55, .cost = .per_player },

    .{ .id = "combat.player_vs_mob", .domain = .combat, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_entity, .scenarios = s.player_attacks_mob, .foundation = .combat },
    .{ .id = "combat.player_vs_player", .domain = .combat, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_player, .scenarios = s.player_melee, .foundation = .combat },
    .{ .id = "combat.mob_vs_player", .domain = .combat, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_entity, .scenarios = s.player_death, .foundation = .combat },
    .{ .id = "combat.attack_cooldown", .domain = .combat, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_player, .scenarios = s.player_melee, .foundation = .combat },
    .{ .id = "combat.armor_enchantments_effects", .domain = .combat, .priority = .p1, .status = .partial, .importance = 85, .cost = .per_entity, .foundation = .combat },
    .{ .id = "combat.projectiles", .domain = .combat, .priority = .p0, .status = .missing, .importance = 90, .cost = .per_entity, .foundation = .combat },
    .{ .id = "combat.shields", .domain = .combat, .priority = .p1, .status = .missing, .importance = 75, .cost = .per_player, .foundation = .combat },
    .{ .id = "combat.knockback", .domain = .combat, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_entity, .scenarios = s.knockback, .foundation = .combat },

    .{ .id = "entities.lifecycle_spawn_move_remove", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 100, .cost = .per_entity, .scenarios = s.entity_lifecycle, .foundation = .entities, .leverage = 100, .effort = 3 },
    .{ .id = "entities.metadata_equipment_replication", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 100, .cost = .per_entity, .scenarios = s.entity_lifecycle, .foundation = .entities, .leverage = 95, .effort = 3 },
    .{ .id = "entities.per_player_visibility", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 95, .cost = .per_player, .scenarios = s.entity_lifecycle, .foundation = .entities, .leverage = 90, .effort = 4 },
    .{ .id = "entities.zombie_ai", .domain = .entities, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_entity, .scenarios = s.trapdoors },
    .{ .id = "entities.zombie_daylight", .domain = .entities, .priority = .p0, .status = .packet_tested, .importance = 80, .cost = .per_entity, .scenarios = s.zombie_daylight },
    .{ .id = "entities.zombie_equipment_loot", .domain = .entities, .priority = .p1, .status = .partial, .importance = 70, .cost = .per_entity },
    .{ .id = "entities.cow_ai_and_breeding", .domain = .entities, .priority = .p0, .status = .packet_tested, .importance = 85, .cost = .per_entity, .scenarios = s.cows },
    .{ .id = "entities.pig_ai_and_breeding", .domain = .entities, .priority = .p1, .status = .partial, .importance = 75, .cost = .per_entity },
    .{ .id = "entities.passive_mob_families", .domain = .entities, .priority = .p1, .status = .missing, .importance = 80, .cost = .per_entity },
    .{ .id = "entities.hostile_mob_families", .domain = .entities, .priority = .p1, .status = .missing, .importance = 85, .cost = .per_entity },
    .{ .id = "entities.bosses", .domain = .entities, .priority = .p2, .status = .missing, .importance = 55, .cost = .per_entity },
    .{ .id = "entities.vehicles", .domain = .entities, .priority = .p1, .status = .missing, .importance = 75, .cost = .per_entity },
    .{ .id = "entities.item_entities", .domain = .entities, .priority = .p0, .status = .vanilla_verified, .importance = 90, .cost = .per_item_entity, .scenarios = s.item_entities, .foundation = .entities },
    .{ .id = "entities.xp_orbs", .domain = .entities, .priority = .p1, .status = .partial, .importance = 70, .cost = .per_entity, .foundation = .drops },
    .{ .id = "entities.pathfinding_block_semantics", .domain = .entities, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_entity, .scenarios = s.trapdoors },

    .{ .id = "spawning.hostile_caps_pack_rules", .domain = .spawning, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_active_chunk, .scenarios = s.natural_spawning },
    .{ .id = "spawning.passive_caps_pack_rules", .domain = .spawning, .priority = .p0, .status = .partial, .importance = 85, .cost = .per_active_chunk, .scenarios = s.natural_spawning },
    .{ .id = "spawning.light_biome_height_conditions", .domain = .spawning, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_active_chunk },
    .{ .id = "spawning.despawn_persistence", .domain = .spawning, .priority = .p0, .status = .partial, .importance = 85, .cost = .per_entity },

    .{ .id = "commands.time", .domain = .commands, .priority = .p0, .status = .packet_tested, .importance = 85, .cost = .constant, .scenarios = s.time },
    .{ .id = "commands.gamemode", .domain = .commands, .priority = .p0, .status = .implemented, .importance = 80, .cost = .constant },
    .{ .id = "commands.summon", .domain = .commands, .priority = .p1, .status = .partial, .importance = 65, .cost = .constant },
    .{ .id = "commands.permissions_and_selectors", .domain = .commands, .priority = .p1, .status = .missing, .importance = 80, .cost = .constant },
    .{ .id = "commands.vanilla_command_set", .domain = .commands, .priority = .p2, .status = .missing, .importance = 60, .cost = .constant },
    .{ .id = "commands.chat_signing_and_filtering", .domain = .commands, .priority = .p0, .status = .partial, .importance = 85, .cost = .per_player },

    .{ .id = "persistence.chunks", .domain = .persistence, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .io_boundary, .scenarios = s.persistence_world_player, .foundation = .storage },
    .{ .id = "persistence.players", .domain = .persistence, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .io_boundary, .scenarios = s.persistence_world_player, .foundation = .storage },
    .{ .id = "persistence.entities", .domain = .persistence, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .io_boundary, .scenarios = s.persistence_entities, .foundation = .storage },
    .{ .id = "persistence.block_entities", .domain = .persistence, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .io_boundary, .scenarios = s.persistent_block_entities, .foundation = .storage },
    .{ .id = "persistence.crash_consistency", .domain = .persistence, .priority = .p0, .status = .partial, .importance = 95, .cost = .io_boundary, .foundation = .storage },

    .{ .id = "security.reach", .domain = .security, .priority = .p0, .status = .packet_tested, .importance = 95, .cost = .per_player, .scenarios = s.reach },
    .{ .id = "security.flight", .domain = .security, .priority = .p0, .status = .packet_tested, .importance = 90, .cost = .per_player, .scenarios = s.flight },
    .{ .id = "security.inventory_authority", .domain = .security, .priority = .p0, .status = .packet_tested, .importance = 100, .cost = .per_player, .scenarios = s.inventory_authority },
    .{ .id = "security.anti_xray", .domain = .security, .priority = .p1, .status = .implemented, .importance = 80, .cost = .per_active_chunk },
    .{ .id = "security.packet_rate_and_resource_limits", .domain = .security, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_connection },

    .{ .id = "extensibility.typed_plugin_dependencies", .domain = .extensibility, .priority = .p0, .status = .implemented, .importance = 95, .cost = .constant },
    .{ .id = "extensibility.plugin_configuration", .domain = .extensibility, .priority = .p0, .status = .implemented, .importance = 85, .cost = .constant },
    .{ .id = "extensibility.plugin_persistence", .domain = .extensibility, .priority = .p0, .status = .implemented, .importance = 85, .cost = .io_boundary },
    .{ .id = "extensibility.hot_reload", .domain = .extensibility, .priority = .p0, .status = .partial, .importance = 90, .cost = .constant },
    .{ .id = "extensibility.protocol_plugins", .domain = .extensibility, .priority = .p0, .status = .partial, .importance = 90, .cost = .per_connection },
};

pub const Summary = struct {
    count: usize = 0,
    missing: usize = 0,
    partial: usize = 0,
    implemented: usize = 0,
    packet_tested: usize = 0,
    vanilla_verified: usize = 0,
    weighted_score: f64 = 0,
    foundation_count: usize = 0,
    foundation_packet_tested: usize = 0,
    foundation_vanilla_verified: usize = 0,
    foundation_weighted_score: f64 = 0,
};

pub fn summarize() Summary {
    var result = Summary{ .count = features.len };
    var earned: u64 = 0;
    var possible: u64 = 0;
    var foundation_earned: u64 = 0;
    var foundation_possible: u64 = 0;
    for (features) |feature| {
        possible += feature.importance;
        const completion: u64 = switch (feature.status) {
            .missing => 0,
            .partial => 25,
            .implemented => 50,
            .packet_tested => 75,
            .vanilla_verified => 100,
        };
        earned += @as(u64, feature.importance) * completion;
        if (feature.foundation != null) {
            result.foundation_count += 1;
            foundation_possible += feature.importance;
            foundation_earned += @as(u64, feature.importance) * completion;
            if (feature.status == .packet_tested) result.foundation_packet_tested += 1;
            if (feature.status == .vanilla_verified) result.foundation_vanilla_verified += 1;
        }
        switch (feature.status) {
            .missing => result.missing += 1,
            .partial => result.partial += 1,
            .implemented => result.implemented += 1,
            .packet_tested => result.packet_tested += 1,
            .vanilla_verified => result.vanilla_verified += 1,
        }
    }
    result.weighted_score = if (possible == 0) 0 else @as(f64, @floatFromInt(earned)) / @as(f64, @floatFromInt(possible));
    result.foundation_weighted_score = if (foundation_possible == 0) 0 else @as(f64, @floatFromInt(foundation_earned)) / @as(f64, @floatFromInt(foundation_possible));
    return result;
}

pub fn summarizeFoundation(area: Foundation) Summary {
    var result = Summary{};
    var earned: u64 = 0;
    var possible: u64 = 0;
    for (features) |feature| {
        if (feature.foundation != area) continue;
        result.count += 1;
        possible += feature.importance;
        const completion: u64 = switch (feature.status) {
            .missing => 0,
            .partial => 25,
            .implemented => 50,
            .packet_tested => 75,
            .vanilla_verified => 100,
        };
        earned += @as(u64, feature.importance) * completion;
        switch (feature.status) {
            .missing => result.missing += 1,
            .partial => result.partial += 1,
            .implemented => result.implemented += 1,
            .packet_tested => result.packet_tested += 1,
            .vanilla_verified => result.vanilla_verified += 1,
        }
    }
    result.weighted_score = if (possible == 0) 0 else @as(f64, @floatFromInt(earned)) / @as(f64, @floatFromInt(possible));
    return result;
}

fn statusGap(status: Status) u32 {
    return switch (status) {
        .missing => 100,
        .partial => 130,
        .implemented => 160,
        .packet_tested => 60,
        .vanilla_verified => 0,
    };
}

pub fn priorityScore(feature: Feature) u32 {
    if (feature.status == .vanilla_verified) return 0;
    const urgency: u32 = switch (feature.priority) {
        .p0 => 400,
        .p1 => 250,
        .p2 => 100,
        .p3 => 25,
    };
    const value = urgency +
        @as(u32, feature.importance) * 4 +
        @as(u32, feature.leverage) * 2 +
        statusGap(feature.status) +
        (if (feature.foundation != null) @as(u32, 500) else 0);
    return value / @max(@as(u32, feature.effort), 1);
}

pub fn nextFeature() *const Feature {
    var best = &features[0];
    for (features[1..]) |*feature| {
        if (priorityScore(feature.*) > priorityScore(best.*)) best = feature;
    }
    return best;
}

test "coverage ledger has unique ids and valid scenario references" {
    var foundation_areas = std.EnumSet(Foundation).initEmpty();
    for (features, 0..) |feature, index| {
        try std.testing.expect(feature.id.len != 0);
        try std.testing.expect(feature.importance > 0 and feature.importance <= 100);
        try std.testing.expect(feature.leverage <= 100);
        try std.testing.expect(feature.effort > 0);
        for (features[0..index]) |previous|
            try std.testing.expect(!std.mem.eql(u8, feature.id, previous.id));
        if (feature.status == .packet_tested or feature.status == .vanilla_verified)
            try std.testing.expect(feature.scenarios.len != 0);
        for (feature.scenarios) |scenario_name|
            try std.testing.expect(scenarios.find(scenario_name) != null);
        if (feature.foundation) |area| foundation_areas.insert(area);
    }
    try std.testing.expectEqual(std.meta.fields(Foundation).len, foundation_areas.count());
}

pub fn printReport() void {
    const summary = summarize();
    const next = nextFeature();
    std.debug.print(
        "Vanilla coverage: {d:.1}% weighted; {d} families ({d} missing, {d} partial, {d} implemented, {d} packet-tested, {d} Vanilla-verified); foundation={d:.1}% ({d} families, {d} packet-tested, {d} Vanilla-verified); next={s} score={d}\n",
        .{
            summary.weighted_score,
            summary.count,
            summary.missing,
            summary.partial,
            summary.implemented,
            summary.packet_tested,
            summary.vanilla_verified,
            summary.foundation_weighted_score,
            summary.foundation_count,
            summary.foundation_packet_tested,
            summary.foundation_vanilla_verified,
            next.id,
            priorityScore(next.*),
        },
    );
    inline for (std.meta.fields(Foundation)) |field| {
        const area: Foundation = @enumFromInt(field.value);
        const area_summary = summarizeFoundation(area);
        std.debug.print(
            "  foundation {s}: {d:.1}% ({d} families, {d} packet-tested, {d} Vanilla-verified)\n",
            .{ field.name, area_summary.weighted_score, area_summary.count, area_summary.packet_tested, area_summary.vanilla_verified },
        );
    }
}

pub fn main() void {
    printReport();
}
