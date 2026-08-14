const std = @import("std");

pub const Setup = union(enum) {
    set_block: struct { x: i32, y: i16, z: i32, state: []const u8 },
    fill_box: struct { min_x: i32, min_y: i16, min_z: i32, max_x: i32, max_y: i16, max_z: i32, state: []const u8 },
    spawn_player: struct { id: []const u8, x: f64, y: f64, z: f64 },
    spawn_entity: struct {
        id: []const u8,
        kind: []const u8,
        x: f64,
        y: f64,
        z: f64,
        baby: bool = false,
        on_ground: bool = true,
    },
    spawn_item: struct {
        id: []const u8,
        item: []const u8,
        count: u8,
        x: f64,
        y: f64,
        z: f64,
        velocity_x: f64 = 0,
        velocity_y: f64 = 0,
        velocity_z: f64 = 0,
        pickup_delay: u16 = 10,
        age: u32 = 0,
    },
    set_player_health: struct { id: []const u8, health: f32 },
    set_entity_health: struct { id: []const u8, health: f32 },
    set_player_gamemode: struct { id: []const u8, gamemode: []const u8 },
    set_held_stack: struct { id: []const u8, item: []const u8, count: u8 },
    set_inventory_stack: struct { id: []const u8, slot: []const u8, item: []const u8, count: u8 },
    set_selected_hotbar_slot: struct { id: []const u8, slot: u4 },
    set_gamerule: struct { name: []const u8, value: []const u8 },
    set_time: i64,
    enable_chunk_streaming,
};

pub const Definition = struct {
    id: []const u8,
    seed: u64,
    frozen_time: i64,
    setup: []const Setup,
};

const flat_world_setup = [_]Setup{};
const craft_all_setup = [_]Setup{
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h1", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h2", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "m26", .item = "minecraft:dirt", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "g0", .item = "minecraft:oak_planks", .count = 4 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "g1", .item = "minecraft:oak_planks", .count = 4 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "g2", .item = "minecraft:oak_planks", .count = 4 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "g3", .item = "minecraft:oak_planks", .count = 4 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h8", .item = "minecraft:air", .count = 0 } },
};
const crafting_close_setup = [_]Setup{
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h1", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h2", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "m26", .item = "minecraft:dirt", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "g0", .item = "minecraft:oak_planks", .count = 16 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h8", .item = "minecraft:air", .count = 0 } },
};
const vanilla_probe_setup = [_]Setup{};
const mining_correct_tool_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const mining_wrong_tool_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const mining_empty_hand_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const mining_creative_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const block_loot_families_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 99, .min_z = -4, .max_x = 36, .max_y = 99, .max_z = 4, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -4, .min_y = 100, .min_z = -4, .max_x = 36, .max_y = 104, .max_z = 4, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 0, .y = 100, .z = 0, .state = "minecraft:dirt" } },
    .{ .set_block = .{ .x = 8, .y = 100, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 16, .y = 100, .z = 0, .state = "minecraft:diamond_ore" } },
    .{ .set_block = .{ .x = 24, .y = 100, .z = 0, .state = "minecraft:glass" } },
    .{ .set_block = .{ .x = 32, .y = 100, .z = 0, .state = "minecraft:clay" } },
    .{ .spawn_player = .{ .id = "self-breaker", .x = 0.5, .y = 100, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "stone-breaker", .x = 8.5, .y = 100, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "tier-breaker", .x = 16.5, .y = 100, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "glass-breaker", .x = 24.5, .y = 100, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "clay-breaker", .x = 32.5, .y = 100, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "observer", .x = 16.5, .y = 100, .z = 4.5 } },
    .{ .set_held_stack = .{ .id = "self-breaker", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_held_stack = .{ .id = "stone-breaker", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_held_stack = .{ .id = "tier-breaker", .item = "minecraft:wooden_pickaxe", .count = 1 } },
    .{ .set_held_stack = .{ .id = "glass-breaker", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_held_stack = .{ .id = "clay-breaker", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const movement_arena_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 10, .min_y = 69, .min_z = -1, .max_x = 16, .max_y = 69, .max_z = 3, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 10, .min_y = 70, .min_z = -1, .max_x = 16, .max_y = 72, .max_z = 3, .state = "minecraft:air" } },
    .{ .spawn_player = .{ .id = "alice", .x = 12, .y = 70, .z = 1 } },
    .{ .spawn_player = .{ .id = "bob", .x = 14, .y = 70, .z = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const flight_arena_setup = [_]Setup{
    .{ .spawn_player = .{ .id = "alice", .x = 12, .y = 80, .z = 1 } },
    .{ .spawn_player = .{ .id = "bob", .x = 14, .y = 70, .z = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const placement_arena_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 1, .y = 65, .z = 0, .state = "minecraft:air" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:dirt", .count = 2 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const item_motion_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -4, .min_y = 65, .min_z = -4, .max_x = 8, .max_y = 72, .max_z = 4, .state = "minecraft:air" } },
    .{ .spawn_player = .{ .id = "alice", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 5.5, .y = 65, .z = 0.5 } },
    .{ .spawn_item = .{
        .id = "falling-stack",
        .item = "minecraft:oak_log",
        .count = 3,
        .x = 0.5,
        .y = 67,
        .z = 0.5,
        .velocity_x = 0.1,
        .velocity_y = 0.2,
        .pickup_delay = 32_767,
    } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};

const item_merge_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 5.5, .y = 65, .z = 0.5 } },
    .{ .spawn_item = .{
        .id = "merge-left",
        .item = "minecraft:oak_log",
        .count = 10,
        .x = 0.5,
        .y = 65,
        .z = 0.5,
        .pickup_delay = 200,
    } },
    .{ .spawn_item = .{
        .id = "merge-right",
        .item = "minecraft:oak_log",
        .count = 20,
        .x = 1,
        .y = 65,
        .z = 0.5,
        .pickup_delay = 200,
    } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};

const item_pickup_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .spawn_item = .{
        .id = "delayed-stack",
        .item = "minecraft:oak_log",
        .count = 3,
        .x = 0.5,
        .y = 65,
        .z = 0.5,
        .pickup_delay = 2,
    } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};

const item_despawn_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 5.5, .y = 65, .z = 0.5 } },
    .{ .spawn_item = .{
        .id = "expiring-stack",
        .item = "minecraft:oak_log",
        .count = 1,
        .x = 0.5,
        .y = 65,
        .z = 0.5,
        .pickup_delay = 32_767,
        .age = 5_998,
    } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};

const lighting_foundation_setup = [_]Setup{
    .{ .fill_box = .{
        .min_x = -8,
        .min_y = 80,
        .min_z = -8,
        .max_x = 22,
        .max_y = 80,
        .max_z = 22,
        .state = "minecraft:stone",
    } },
    .{ .set_block = .{ .x = 15, .y = 81, .z = 0, .state = "minecraft:torch" } },
    .{ .set_block = .{ .x = 14, .y = 81, .z = 0, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 15.5, .y = 81, .z = 3.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 17.5, .y = 81, .z = 3.5 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
    .enable_chunk_streaming,
};
const lighting_overlap_setup = [_]Setup{
    .{ .fill_box = .{
        .min_x = -8,
        .min_y = 80,
        .min_z = -8,
        .max_x = 12,
        .max_y = 80,
        .max_z = 8,
        .state = "minecraft:stone",
    } },
    .{ .set_block = .{ .x = 0, .y = 81, .z = 0, .state = "minecraft:torch" } },
    .{ .set_block = .{ .x = 4, .y = 81, .z = 0, .state = "minecraft:torch" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 81, .z = 3.5 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:torch", .count = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
    .enable_chunk_streaming,
};
const storage_restart_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 4, .y = 64, .z = 0, .state = "minecraft:dirt" } },
    .{ .set_block = .{ .x = 4, .y = 65, .z = 0, .state = "minecraft:oak_sapling[stage=0]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_player_health = .{ .id = "alice", .health = 13 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h4", .item = "minecraft:dirt", .count = 2 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 4 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 3.5, .y = 65, .z = -1.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};
const chest_arena_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:oak_log", .count = 12 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const furnace_arena_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:furnace[facing=north,lit=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:raw_iron", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h1", .item = "minecraft:coal", .count = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const chest_placement_setup = directionalPlacementSetup("minecraft:chest");
const furnace_placement_setup = directionalPlacementSetup("minecraft:furnace");
const pick_block_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:dirt", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h5", .item = "minecraft:stone", .count = 17 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const creative_pick_block_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const creative_inventory_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 4, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 2.5 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const trapdoor_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 3, .min_y = 64, .min_z = 3, .max_x = 8, .max_y = 64, .max_z = 8, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 3, .min_y = 65, .min_z = 3, .max_x = 8, .max_y = 67, .max_z = 8, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 6, .y = 65, .z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 5, .y = 65, .z = 8 } },
    .{ .spawn_player = .{ .id = "bob", .x = 7, .y = 65, .z = 8 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:oak_trapdoor", .count = 4 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const door_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 3, .min_y = 64, .min_z = 3, .max_x = 9, .max_y = 64, .max_z = 8, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 3, .min_y = 65, .min_z = 3, .max_x = 9, .max_y = 67, .max_z = 8, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 6, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 6, .y = 65, .z = 9 } },
    .{ .spawn_player = .{ .id = "bob", .x = 8, .y = 65, .z = 9 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:oak_door", .count = 8 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const slab_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 3, .min_y = 64, .min_z = 3, .max_x = 10, .max_y = 64, .max_z = 8, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 3, .min_y = 65, .min_z = 3, .max_x = 10, .max_y = 67, .max_z = 8, .state = "minecraft:air" } },
    .{ .set_block = .{ .x = 6, .y = 66, .z = 4, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 6, .state = "minecraft:oak_slab[type=top,waterlogged=false]" } },
    .{ .set_block = .{ .x = 9, .y = 64, .z = 6, .state = "minecraft:oak_slab[type=bottom,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 6, .y = 65, .z = 7.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 8, .y = 65, .z = 8.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:oak_slab", .count = 8 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h1", .item = "minecraft:oak_door", .count = 2 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

fn directionalPlacementSetup(comptime item: []const u8) [12]Setup {
    return .{
        .{ .set_block = .{ .x = 4, .y = 64, .z = 4, .state = "minecraft:stone" } },
        .{ .set_block = .{ .x = 6, .y = 64, .z = 4, .state = "minecraft:stone" } },
        .{ .set_block = .{ .x = 4, .y = 64, .z = 6, .state = "minecraft:stone" } },
        .{ .set_block = .{ .x = 6, .y = 64, .z = 6, .state = "minecraft:stone" } },
        .{ .set_block = .{ .x = 4, .y = 65, .z = 4, .state = "minecraft:air" } },
        .{ .set_block = .{ .x = 6, .y = 65, .z = 4, .state = "minecraft:air" } },
        .{ .set_block = .{ .x = 4, .y = 65, .z = 6, .state = "minecraft:air" } },
        .{ .set_block = .{ .x = 6, .y = 65, .z = 6, .state = "minecraft:air" } },
        .{ .spawn_player = .{ .id = "alice", .x = 5, .y = 65, .z = 8 } },
        .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = item, .count = 4 } },
        .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
        .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    };
}
const reach_arena_setup = [_]Setup{
    .{ .set_block = .{ .x = 20, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 20.5, .y = 65, .z = 2.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const login_held_setup = [_]Setup{
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 0.5 } },
    // Declare the inventory instead of relying on an adapter's default kit.
    // A fixture must have the same starting state in Vanilla and every server
    // under test.
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h1", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h2", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h8", .item = "minecraft:oak_planks", .count = 16 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "m26", .item = "minecraft:dirt", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "h1", .item = "minecraft:diamond_pickaxe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "h2", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "h8", .item = "minecraft:oak_planks", .count = 16 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "m26", .item = "minecraft:dirt", .count = 1 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h5", .item = "minecraft:dirt", .count = 2 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const player_inventory_clicks_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 12, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "carol", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "dave", .x = 6.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "erin", .x = 8.5, .y = 65, .z = 0.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:oak_log", .count = 9 } },
    .{ .set_inventory_stack = .{ .id = "bob", .slot = "h0", .item = "minecraft:oak_log", .count = 9 } },
    .{ .set_inventory_stack = .{ .id = "carol", .slot = "m0", .item = "minecraft:oak_log", .count = 2 } },
    .{ .set_inventory_stack = .{ .id = "carol", .slot = "h0", .item = "minecraft:oak_log", .count = 60 } },
    .{ .set_inventory_stack = .{ .id = "dave", .slot = "m0", .item = "minecraft:dirt", .count = 4 } },
    .{ .set_inventory_stack = .{ .id = "dave", .slot = "h2", .item = "minecraft:stone", .count = 3 } },
    .{ .set_inventory_stack = .{ .id = "erin", .slot = "h0", .item = "minecraft:oak_log", .count = 3 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};
const player_collision_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 10, .max_y = 64, .max_z = 2, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 65, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 0, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "observer", .x = 8.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
};
const combat_arena_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_shovel", .count = 1 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const player_combat_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 12, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "observer", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "distant", .x = 8.5, .y = 65, .z = 0.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const player_combat_death_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 2.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "observer", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .set_player_health = .{ .id = "bob", .health = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    .{ .set_gamerule = .{ .name = "naturalRegeneration", .value = "false" } },
};
const entity_lifecycle_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -8, .min_y = 64, .min_z = -8, .max_x = 12, .max_y = 64, .max_z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 6.5, .y = 65, .z = 0.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 2.5, .y = 65, .z = 0.5 } },
    .{ .set_entity_health = .{ .id = "zombie", .health = 19 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const mob_death_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .set_inventory_stack = .{ .id = "alice", .slot = "h0", .item = "minecraft:diamond_axe", .count = 1 } },
    .{ .set_selected_hotbar_slot = .{ .id = "alice", .slot = 0 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_entity_health = .{ .id = "zombie", .health = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const falling_cows_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 65, .min_z = -4, .max_x = 8, .max_y = 80, .max_z = 4, .state = "minecraft:air" } },
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 3.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 4.5, .y = 65, .z = 3.5 } },
    .{ .spawn_entity = .{ .id = "healthy-cow", .kind = "minecraft:cow", .x = 0.5, .y = 77, .z = 0.5, .on_ground = false } },
    .{ .spawn_entity = .{ .id = "fatal-cow", .kind = "minecraft:cow", .x = 3.5, .y = 77, .z = 0.5, .on_ground = false } },
    .{ .set_entity_health = .{ .id = "fatal-cow", .health = 1 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const player_fall_lanes_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 12, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -4, .min_y = 65, .min_z = -4, .max_x = 12, .max_y = 92, .max_z = 4, .state = "minecraft:air" } },
    .{ .spawn_player = .{ .id = "safe-faller", .x = 0.5, .y = 68, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "threshold-faller", .x = 3.5, .y = 69, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "fatal-faller", .x = 6.5, .y = 89, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "observer", .x = 9.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const player_death_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_player = .{ .id = "bob", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .set_player_health = .{ .id = "alice", .health = 1 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_temptation_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 12, .max_y = 64, .max_z = 4, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 0.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:wheat", .count = 1 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const creative_wheat_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 2, .max_y = 64, .max_z = 2, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_breeding_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 8, .max_y = 64, .max_z = 4, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:wheat", .count = 2 } },
    .{ .spawn_entity = .{ .id = "cow-a", .kind = "minecraft:cow", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "cow-b", .kind = "minecraft:cow", .x = 3.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_panic_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -8, .min_y = 64, .min_z = -8, .max_x = 8, .max_y = 64, .max_z = 8, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:wheat", .count = 1 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_parent_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 12, .max_y = 64, .max_z = 4, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 10.5, .y = 65, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "calf", .kind = "minecraft:cow", .x = 0.5, .y = 65, .z = 0.5, .baby = true } },
    .{ .spawn_entity = .{ .id = "parent", .kind = "minecraft:cow", .x = 7.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_swim_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -3, .min_y = 63, .min_z = -3, .max_x = 3, .max_y = 63, .max_z = 3, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -3, .min_y = 64, .min_z = -3, .max_x = 3, .max_y = 66, .max_z = 3, .state = "minecraft:water[level=0]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 2.5, .y = 67, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 0.5, .y = 64, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_milking_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 2, .max_y = 64, .max_z = 2, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:bucket", .count = 1 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 1.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const calf_milking_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -2, .min_y = 64, .min_z = -2, .max_x = 2, .max_y = 64, .max_z = 2, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_held_stack = .{ .id = "alice", .item = "minecraft:bucket", .count = 1 } },
    .{ .spawn_entity = .{ .id = "calf", .kind = "minecraft:cow", .x = 1.5, .y = 65, .z = 0.5, .baby = true } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_wandering_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -16, .min_y = 64, .min_z = -16, .max_x = 16, .max_y = 64, .max_z = 16, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 12.5, .y = 65, .z = 12.5 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const cow_look_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -4, .min_y = 64, .min_z = -4, .max_x = 6, .max_y = 64, .max_z = 4, .state = "minecraft:grass_block" } },
    .{ .spawn_player = .{ .id = "alice", .x = 4.5, .y = 65, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "cow", .kind = "minecraft:cow", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const time_lifecycle_setup = [_]Setup{
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const frozen_daylight_cycle_setup = [_]Setup{
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doDaylightCycle", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const zombie_daylight_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -12, .min_y = 64, .min_z = -12, .max_x = 12, .max_y = 64, .max_z = 12, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = -1, .y = 65, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 65, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = -1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 1, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 10.5, .y = 65, .z = 10.5 } },
    .{ .set_player_gamemode = .{ .id = "alice", .gamemode = "creative" } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const natural_spawning_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = -40, .min_y = 64, .min_z = -40, .max_x = 40, .max_y = 64, .max_z = 40, .state = "minecraft:grass_block[snowy=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "true" } },
};
const oak_leaf_connected_setup = [_]Setup{
    // Distance is derived state. The fixture declares only leaf blocks, then
    // introduces the log whose neighbor update must connect them.
    .{ .set_block = .{ .x = -1, .y = 100, .z = 0, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 1, .y = 100, .z = 0, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 0, .y = 99, .z = 0, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 0, .y = 101, .z = 0, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 0, .y = 100, .z = -1, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 0, .y = 100, .z = 1, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 0, .y = 100, .z = 0, .state = "minecraft:oak_log[axis=y]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 100, .z = 3.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "true" } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const grass_cover_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 0, .max_x = 15, .max_y = 64, .max_z = 15, .state = "minecraft:grass_block[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 65, .min_z = 0, .max_x = 15, .max_y = 65, .max_z = 15, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 65, .min_z = 0, .max_x = 15, .max_y = 65, .max_z = 3, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 65, .min_z = 4, .max_x = 15, .max_y = 65, .max_z = 7, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 6.5, .y = 66, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const oak_sapling_break_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:oak_sapling" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 2.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const oak_leaf_drop_setup = [_]Setup{
    // Eight independent leaf planes stay above procedural trees. Each plane
    // has a catch floor, preventing drops from different heights from falling
    // together and merging before the harness observes their stack counts.
    .{ .fill_box = .{ .min_x = -32, .min_y = 159, .min_z = -32, .max_x = 31, .max_y = 159, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 160, .min_z = -32, .max_x = 31, .max_y = 160, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 161, .min_z = -32, .max_x = 31, .max_y = 161, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 162, .min_z = -32, .max_x = 31, .max_y = 162, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 163, .min_z = -32, .max_x = 31, .max_y = 163, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 164, .min_z = -32, .max_x = 31, .max_y = 164, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 165, .min_z = -32, .max_x = 31, .max_y = 165, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 166, .min_z = -32, .max_x = 31, .max_y = 166, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 167, .min_z = -32, .max_x = 31, .max_y = 167, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 168, .min_z = -32, .max_x = 31, .max_y = 168, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 169, .min_z = -32, .max_x = 31, .max_y = 169, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 170, .min_z = -32, .max_x = 31, .max_y = 170, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 171, .min_z = -32, .max_x = 31, .max_y = 171, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 172, .min_z = -32, .max_x = 31, .max_y = 172, .max_z = 31, .state = "minecraft:oak_leaves" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 173, .min_z = -32, .max_x = 31, .max_y = 173, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = -32, .min_y = 174, .min_z = -32, .max_x = 31, .max_y = 174, .max_z = 31, .state = "minecraft:oak_leaves" } },
    // Alice's ticking ticket covers the complete 4x4 fixture volume.
    .{ .spawn_player = .{ .id = "alice", .x = -24.5, .y = 176, .z = -24.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "true" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};
const zombie_open_trapdoor_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:oak_trapdoor[facing=north,half=bottom,open=true,powered=false,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 2.5, .y = 65, .z = 0.5 } },
    .{ .spawn_entity = .{ .id = "zombie", .kind = "minecraft:zombie", .x = 0.5, .y = 65, .z = 0.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const campfire_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:campfire[facing=north,lit=true,signal_fire=false,waterlogged=false]" } },
    .{ .spawn_player = .{ .id = "alice", .x = 0.5, .y = 65, .z = 3.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "false" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const tree_growth_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 0, .max_x = 15, .max_y = 64, .max_z = 15, .state = "minecraft:dirt" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 0, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 0, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 0, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 5, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 5, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 5, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 5, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 10, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 10, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 10, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 10, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 15, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 15, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 15, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 15, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 18, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 18.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const turtle_crack_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 0, .max_x = 15, .max_y = 64, .max_z = 15, .state = "minecraft:sand" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 65, .min_z = 0, .max_x = 15, .max_y = 65, .max_z = 15, .state = "minecraft:turtle_egg[eggs=1,hatch=0]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 18, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 18.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const turtle_hatch_setup = [_]Setup{
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 0, .max_x = 15, .max_y = 64, .max_z = 15, .state = "minecraft:sand" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 65, .min_z = 0, .max_x = 15, .max_y = 65, .max_z = 15, .state = "minecraft:turtle_egg[eggs=1,hatch=2]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 18, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 18.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const dripstone_cauldron_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:cauldron" } },
    .{ .set_block = .{ .x = 0, .y = 67, .z = 0, .state = "minecraft:pointed_dripstone[thickness=tip,vertical_direction=down,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 68, .z = 0, .state = "minecraft:pointed_dripstone[thickness=frustum,vertical_direction=down,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 69, .z = 0, .state = "minecraft:dripstone_block" } },
    .{ .set_block = .{ .x = 0, .y = 70, .z = 0, .state = "minecraft:water[level=0]" } },
    .{ .set_block = .{ .x = -1, .y = 70, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 70, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 70, .z = -1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 70, .z = 1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 71, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const cactus_growth_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:sand" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:cactus[age=15]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const sugar_cane_growth_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:dirt" } },
    .{ .set_block = .{ .x = 1, .y = 63, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 64, .z = 0, .state = "minecraft:water[level=0]" } },
    .{ .set_block = .{ .x = 1, .y = 64, .z = -1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 1, .y = 64, .z = 1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 2, .y = 64, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:sugar_cane[age=15]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const kelp_growth_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 63, .z = 0, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = "minecraft:water[level=0]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:kelp[age=0]" } },
    .{ .set_block = .{ .x = 0, .y = 66, .z = 0, .state = "minecraft:water[level=0]" } },
    .{ .fill_box = .{ .min_x = -1, .min_y = 64, .min_z = 0, .max_x = -1, .max_y = 66, .max_z = 0, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 1, .min_y = 64, .min_z = 0, .max_x = 1, .max_y = 66, .max_z = 0, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = -1, .max_x = 0, .max_y = 66, .max_z = -1, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 1, .max_x = 0, .max_y = 66, .max_z = 1, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const bamboo_sapling_growth_setup = growthSetup("minecraft:dirt", "minecraft:bamboo_sapling");
const bamboo_growth_setup = growthSetup("minecraft:dirt", "minecraft:bamboo[age=0,leaves=none,stage=0]");
const chorus_growth_setup = growthSetup("minecraft:end_stone", "minecraft:chorus_flower[age=0]");
const berry_growth_setup = growthSetup("minecraft:dirt", "minecraft:sweet_berry_bush[age=0]");

fn growthSetup(comptime below: []const u8, comptime plant: []const u8) [6]Setup {
    return .{
        .{ .set_block = .{ .x = 0, .y = 64, .z = 0, .state = below } },
        .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = plant } },
        .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
        .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
        .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
        .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
    };
}

const mangrove_growth_setup = [_]Setup{
    .{ .set_block = .{ .x = 0, .y = 66, .z = 0, .state = "minecraft:mangrove_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 0, .state = "minecraft:mangrove_propagule[age=0,hanging=true,stage=0,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 64, .z = 8, .state = "minecraft:stone" } },
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 65, .z = 8.5 } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "4096" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "false" } },
};

const random_mechanics_setup = [_]Setup{
    .{ .spawn_player = .{ .id = "alice", .x = 8.5, .y = 176, .z = 24.5 } },
    .{ .set_gamerule = .{ .name = "doRandomTicks", .value = "true" } },
    .{ .set_gamerule = .{ .name = "randomTickSpeed", .value = "128" } },
    .{ .set_gamerule = .{ .name = "doMobSpawning", .value = "true" } },
    .{ .set_block = .{ .x = 1, .y = 74, .z = 17, .state = "minecraft:netherrack" } },
    .{ .set_block = .{ .x = 1, .y = 75, .z = 17, .state = "minecraft:fire[age=0,east=false,north=false,south=false,up=false,west=false]" } },
    .{ .set_block = .{ .x = 2, .y = 75, .z = 17, .state = "minecraft:oak_planks" } },
    .{ .set_block = .{ .x = 0, .y = 75, .z = 17, .state = "minecraft:oak_planks" } },
    .{ .set_block = .{ .x = 1, .y = 75, .z = 16, .state = "minecraft:oak_planks" } },
    .{ .set_block = .{ .x = 1, .y = 75, .z = 18, .state = "minecraft:oak_planks" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 79, .min_z = 16, .max_x = 15, .max_y = 79, .max_z = 31, .state = "minecraft:farmland[moisture=7]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 80, .min_z = 16, .max_x = 15, .max_y = 80, .max_z = 31, .state = "minecraft:wheat[age=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 83, .min_z = 16, .max_x = 15, .max_y = 83, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 84, .min_z = 16, .max_x = 15, .max_y = 84, .max_z = 31, .state = "minecraft:wheat[age=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 87, .min_z = 16, .max_x = 15, .max_y = 87, .max_z = 31, .state = "minecraft:mycelium[snowy=false]" } },
    .{ .set_block = .{ .x = 0, .y = 88, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 88, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 88, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 88, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 88, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 88, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 88, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 88, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 88, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 88, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 88, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 88, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 88, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 88, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 88, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 88, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 90, .min_z = 16, .max_x = 15, .max_y = 90, .max_z = 31, .state = "minecraft:mycelium[snowy=false]" } },
    .{ .set_block = .{ .x = 0, .y = 91, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 91, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 91, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 91, .z = 16, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 91, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 91, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 91, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 91, .z = 21, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 91, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 91, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 91, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 91, .z = 26, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 0, .y = 91, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 5, .y = 91, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 10, .y = 91, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .set_block = .{ .x = 15, .y = 91, .z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 92, .min_z = 16, .max_x = 15, .max_y = 92, .max_z = 31, .state = "minecraft:brown_mushroom" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 16, .max_x = 15, .max_y = 110, .max_z = 16, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 17, .max_x = 15, .max_y = 110, .max_z = 17, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 18, .max_x = 15, .max_y = 110, .max_z = 18, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 19, .max_x = 15, .max_y = 110, .max_z = 19, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 20, .max_x = 15, .max_y = 110, .max_z = 20, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 21, .max_x = 15, .max_y = 110, .max_z = 21, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 22, .max_x = 15, .max_y = 110, .max_z = 22, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 23, .max_x = 15, .max_y = 110, .max_z = 23, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 24, .max_x = 15, .max_y = 110, .max_z = 24, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 25, .max_x = 15, .max_y = 110, .max_z = 25, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 26, .max_x = 15, .max_y = 110, .max_z = 26, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 27, .max_x = 15, .max_y = 110, .max_z = 27, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 28, .max_x = 15, .max_y = 110, .max_z = 28, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 29, .max_x = 15, .max_y = 110, .max_z = 29, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 30, .max_x = 15, .max_y = 110, .max_z = 30, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 95, .min_z = 31, .max_x = 15, .max_y = 110, .max_z = 31, .state = "minecraft:vine[east=false,north=true,south=false,up=false,west=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 111, .min_z = 16, .max_x = 15, .max_y = 111, .max_z = 31, .state = "minecraft:glowstone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 112, .min_z = 16, .max_x = 15, .max_y = 112, .max_z = 31, .state = "minecraft:ice" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 115, .min_z = 16, .max_x = 15, .max_y = 115, .max_z = 31, .state = "minecraft:glowstone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 116, .min_z = 16, .max_x = 15, .max_y = 116, .max_z = 31, .state = "minecraft:snow[layers=1]" } },
    .{ .set_block = .{ .x = 0, .y = 118, .z = 16, .state = "minecraft:water[level=0]" } },
    .{ .fill_box = .{ .min_x = 1, .min_y = 118, .min_z = 16, .max_x = 15, .max_y = 118, .max_z = 31, .state = "minecraft:farmland[moisture=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 120, .min_z = 16, .max_x = 15, .max_y = 120, .max_z = 31, .state = "minecraft:farmland[moisture=7]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 123, .min_z = 16, .max_x = 15, .max_y = 123, .max_z = 31, .state = "minecraft:sand" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 124, .min_z = 16, .max_x = 15, .max_y = 124, .max_z = 31, .state = "minecraft:cactus[age=15]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 127, .min_z = 16, .max_x = 15, .max_y = 127, .max_z = 16, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 128, .min_z = 16, .max_x = 15, .max_y = 128, .max_z = 16, .state = "minecraft:sugar_cane[age=15]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 127, .min_z = 17, .max_x = 15, .max_y = 127, .max_z = 17, .state = "minecraft:water[level=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 131, .min_z = 16, .max_x = 15, .max_y = 131, .max_z = 31, .state = "minecraft:water[level=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 132, .min_z = 16, .max_x = 15, .max_y = 132, .max_z = 31, .state = "minecraft:kelp[age=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 133, .min_z = 16, .max_x = 15, .max_y = 133, .max_z = 31, .state = "minecraft:water[level=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 135, .min_z = 16, .max_x = 15, .max_y = 135, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 136, .min_z = 16, .max_x = 15, .max_y = 136, .max_z = 31, .state = "minecraft:bamboo_sapling" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 139, .min_z = 16, .max_x = 15, .max_y = 139, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 140, .min_z = 16, .max_x = 15, .max_y = 140, .max_z = 31, .state = "minecraft:bamboo[age=0,leaves=none,stage=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 143, .min_z = 16, .max_x = 15, .max_y = 143, .max_z = 31, .state = "minecraft:end_stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 144, .min_z = 16, .max_x = 15, .max_y = 144, .max_z = 31, .state = "minecraft:chorus_flower[age=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 147, .min_z = 16, .max_x = 15, .max_y = 147, .max_z = 31, .state = "minecraft:mangrove_leaves[distance=1,persistent=true,waterlogged=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 146, .min_z = 16, .max_x = 15, .max_y = 146, .max_z = 31, .state = "minecraft:mangrove_propagule[age=0,hanging=true,stage=0,waterlogged=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 149, .min_z = 16, .max_x = 15, .max_y = 149, .max_z = 31, .state = "minecraft:mycelium[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 150, .min_z = 16, .max_x = 15, .max_y = 150, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 151, .min_z = 16, .max_x = 15, .max_y = 151, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 152, .min_z = 16, .max_x = 15, .max_y = 152, .max_z = 31, .state = "minecraft:sweet_berry_bush[age=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 155, .min_z = 16, .max_x = 15, .max_y = 155, .max_z = 31, .state = "minecraft:grass_block[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 156, .min_z = 16, .max_x = 15, .max_y = 156, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 157, .min_z = 16, .max_x = 15, .max_y = 157, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 157, .min_z = 16, .max_x = 15, .max_y = 157, .max_z = 16, .state = "minecraft:mycelium[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 159, .min_z = 16, .max_x = 15, .max_y = 159, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 160, .min_z = 16, .max_x = 15, .max_y = 160, .max_z = 16, .state = "minecraft:grass_block[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 163, .min_z = 16, .max_x = 15, .max_y = 163, .max_z = 31, .state = "minecraft:crimson_nylium" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 164, .min_z = 16, .max_x = 15, .max_y = 164, .max_z = 31, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 167, .min_z = 16, .max_x = 15, .max_y = 167, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 168, .min_z = 16, .max_x = 15, .max_y = 168, .max_z = 31, .state = "minecraft:oak_sapling[stage=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 171, .min_z = 16, .max_x = 15, .max_y = 171, .max_z = 31, .state = "minecraft:oak_planks" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 172, .min_z = 16, .max_x = 15, .max_y = 172, .max_z = 31, .state = "minecraft:lava[level=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 175, .min_z = 16, .max_x = 15, .max_y = 175, .max_z = 31, .state = "minecraft:redstone_ore[lit=true]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 178, .min_z = 16, .max_x = 15, .max_y = 178, .max_z = 31, .state = "minecraft:obsidian" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 179, .min_z = 16, .max_x = 15, .max_y = 194, .max_z = 31, .state = "minecraft:nether_portal[axis=x]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 197, .min_z = 16, .max_x = 15, .max_y = 197, .max_z = 31, .state = "minecraft:sand" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 198, .min_z = 16, .max_x = 15, .max_y = 198, .max_z = 31, .state = "minecraft:turtle_egg[eggs=1,hatch=0]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 200, .min_z = 16, .max_x = 15, .max_y = 200, .max_z = 31, .state = "minecraft:sand" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 201, .min_z = 16, .max_x = 15, .max_y = 201, .max_z = 31, .state = "minecraft:turtle_egg[eggs=1,hatch=2]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 203, .min_z = 16, .max_x = 15, .max_y = 203, .max_z = 31, .state = "minecraft:budding_amethyst" } },
    .{ .set_block = .{ .x = 0, .y = 207, .z = 16, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 5, .y = 207, .z = 16, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 10, .y = 207, .z = 16, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 15, .y = 207, .z = 16, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 0, .y = 207, .z = 21, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 5, .y = 207, .z = 21, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 10, .y = 207, .z = 21, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 15, .y = 207, .z = 21, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 0, .y = 207, .z = 26, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 5, .y = 207, .z = 26, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 10, .y = 207, .z = 26, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 15, .y = 207, .z = 26, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 0, .y = 207, .z = 31, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 5, .y = 207, .z = 31, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 10, .y = 207, .z = 31, .state = "minecraft:copper_block" } },
    .{ .set_block = .{ .x = 15, .y = 207, .z = 31, .state = "minecraft:copper_block" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 211, .min_z = 16, .max_x = 15, .max_y = 211, .max_z = 31, .state = "minecraft:mud" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 210, .min_z = 16, .max_x = 15, .max_y = 210, .max_z = 31, .state = "minecraft:pointed_dripstone[thickness=tip,vertical_direction=down,waterlogged=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 215, .min_z = 16, .max_x = 15, .max_y = 215, .max_z = 31, .state = "minecraft:pointed_dripstone[thickness=tip,vertical_direction=down,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 218, .z = 24, .state = "minecraft:cauldron" } },
    .{ .set_block = .{ .x = 8, .y = 221, .z = 24, .state = "minecraft:pointed_dripstone[thickness=tip,vertical_direction=down,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 222, .z = 24, .state = "minecraft:pointed_dripstone[thickness=frustum,vertical_direction=down,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 223, .z = 24, .state = "minecraft:dripstone_block" } },
    .{ .set_block = .{ .x = 8, .y = 224, .z = 24, .state = "minecraft:water[level=0]" } },
    .{ .set_block = .{ .x = 7, .y = 224, .z = 24, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 9, .y = 224, .z = 24, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 224, .z = 23, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 224, .z = 25, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 8, .y = 225, .z = 24, .state = "minecraft:stone" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 64, .min_z = 16, .max_x = 15, .max_y = 64, .max_z = 31, .state = "minecraft:dirt" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 16, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 16, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 16, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 16, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 21, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 21, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 21, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 21, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 26, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 26, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 26, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 26, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 0, .y = 65, .z = 31, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 5, .y = 65, .z = 31, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 10, .y = 65, .z = 31, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .set_block = .{ .x = 15, .y = 65, .z = 31, .state = "minecraft:oak_sapling[stage=1]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 228, .min_z = 16, .max_x = 15, .max_y = 228, .max_z = 31, .state = "minecraft:grass_block[snowy=false]" } },
    .{ .fill_box = .{ .min_x = 0, .min_y = 229, .min_z = 16, .max_x = 15, .max_y = 229, .max_z = 31, .state = "minecraft:stone" } },
    .{ .set_block = .{ .x = 0, .y = 229, .z = 16, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 4, .y = 229, .z = 16, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 229, .z = 16, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 12, .y = 229, .z = 16, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 229, .z = 20, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 4, .y = 229, .z = 20, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 229, .z = 20, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 12, .y = 229, .z = 20, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 229, .z = 24, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 4, .y = 229, .z = 24, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 229, .z = 24, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 12, .y = 229, .z = 24, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 0, .y = 229, .z = 28, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 4, .y = 229, .z = 28, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 8, .y = 229, .z = 28, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 12, .y = 229, .z = 28, .state = "minecraft:chest[facing=north,type=single,waterlogged=false]" } },
    .{ .set_block = .{ .x = 2, .y = 229, .z = 16, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 6, .y = 229, .z = 16, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 10, .y = 229, .z = 16, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 14, .y = 229, .z = 16, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 2, .y = 229, .z = 20, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 6, .y = 229, .z = 20, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 10, .y = 229, .z = 20, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 14, .y = 229, .z = 20, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 2, .y = 229, .z = 24, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 6, .y = 229, .z = 24, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 10, .y = 229, .z = 24, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 14, .y = 229, .z = 24, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 2, .y = 229, .z = 28, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 6, .y = 229, .z = 28, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 10, .y = 229, .z = 28, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 14, .y = 229, .z = 28, .state = "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=false]" } },
    .{ .set_block = .{ .x = 7, .y = 233, .z = 24, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 9, .y = 233, .z = 24, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 8, .y = 232, .z = 24, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 8, .y = 234, .z = 24, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 8, .y = 233, .z = 23, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 8, .y = 233, .z = 25, .state = "minecraft:oak_leaves" } },
    .{ .set_block = .{ .x = 8, .y = 233, .z = 24, .state = "minecraft:oak_log[axis=y]" } },
};

pub fn builtin(id: []const u8) ?Definition {
    if (std.mem.eql(u8, id, "item-motion")) return .{
        .id = "item-motion",
        .seed = 0x4954_454d_4d4f_544e,
        .frozen_time = 6000,
        .setup = &item_motion_setup,
    };
    if (std.mem.eql(u8, id, "item-merge")) return .{
        .id = "item-merge",
        .seed = 0x4954_454d_4d45_5247,
        .frozen_time = 6000,
        .setup = &item_merge_setup,
    };
    if (std.mem.eql(u8, id, "item-pickup")) return .{
        .id = "item-pickup",
        .seed = 0x4954_454d_5049_434b,
        .frozen_time = 6000,
        .setup = &item_pickup_setup,
    };
    if (std.mem.eql(u8, id, "item-despawn")) return .{
        .id = "item-despawn",
        .seed = 0x4954_454d_4445_5350,
        .frozen_time = 6000,
        .setup = &item_despawn_setup,
    };
    if (std.mem.eql(u8, id, "lighting-foundation")) return .{
        .id = "lighting-foundation",
        .seed = 0x4c49_4748_5449_4e47,
        .frozen_time = 6000,
        .setup = &lighting_foundation_setup,
    };
    if (std.mem.eql(u8, id, "lighting-overlap")) return .{
        .id = "lighting-overlap",
        .seed = 0x4c49_4748_4f56_4552,
        .frozen_time = 6000,
        .setup = &lighting_overlap_setup,
    };
    if (std.mem.eql(u8, id, "flat-world")) return .{
        .id = "flat-world",
        .seed = 0x4d43_435f_464c_4154,
        .frozen_time = 6000,
        .setup = &flat_world_setup,
    };
    if (std.mem.eql(u8, id, "craft-all")) return .{
        .id = "craft-all",
        .seed = 0x4d43_435f_4352_4654,
        .frozen_time = 6000,
        .setup = &craft_all_setup,
    };
    if (std.mem.eql(u8, id, "crafting-close")) return .{
        .id = "crafting-close",
        .seed = 0x4d43_435f_434c_4f53,
        .frozen_time = 6000,
        .setup = &crafting_close_setup,
    };
    if (std.mem.eql(u8, id, "mining-correct-tool")) return .{
        .id = "mining-correct-tool",
        .seed = 0x4d49_4e45_434f_5252,
        .frozen_time = 6000,
        .setup = &mining_correct_tool_setup,
    };
    if (std.mem.eql(u8, id, "mining-wrong-tool")) return .{
        .id = "mining-wrong-tool",
        .seed = 0x4d49_4e45_5752_4f4e,
        .frozen_time = 6000,
        .setup = &mining_wrong_tool_setup,
    };
    if (std.mem.eql(u8, id, "mining-empty-hand")) return .{
        .id = "mining-empty-hand",
        .seed = 0x4d49_4e45_454d_5054,
        .frozen_time = 6000,
        .setup = &mining_empty_hand_setup,
    };
    if (std.mem.eql(u8, id, "mining-creative")) return .{
        .id = "mining-creative",
        .seed = 0x4d49_4e45_4352_4541,
        .frozen_time = 6000,
        .setup = &mining_creative_setup,
    };
    if (std.mem.eql(u8, id, "block-loot-families")) return .{
        .id = "block-loot-families",
        .seed = 0x424c_4f43_4b4c_4f4f,
        .frozen_time = 6000,
        .setup = &block_loot_families_setup,
    };
    if (std.mem.eql(u8, id, "movement-arena")) return .{
        .id = "movement-arena",
        .seed = 0x4d43_435f_4d4f_5645,
        .frozen_time = 6000,
        .setup = &movement_arena_setup,
    };
    if (std.mem.eql(u8, id, "flight-arena")) return .{
        .id = "flight-arena",
        .seed = 0x4d43_435f_464c_5949,
        .frozen_time = 6000,
        .setup = &flight_arena_setup,
    };
    if (std.mem.eql(u8, id, "placement-arena")) return .{
        .id = "placement-arena",
        .seed = 0x4d43_435f_504c_4143,
        .frozen_time = 6000,
        .setup = &placement_arena_setup,
    };
    if (std.mem.eql(u8, id, "storage-restart")) return .{
        .id = "storage-restart",
        .seed = 0x5354_4f52_4147_4552,
        .frozen_time = 13_000,
        .setup = &storage_restart_setup,
    };
    if (std.mem.eql(u8, id, "chest-arena")) return .{
        .id = "chest-arena",
        .seed = 0x4348_4553_545f_4152,
        .frozen_time = 6000,
        .setup = &chest_arena_setup,
    };
    if (std.mem.eql(u8, id, "furnace-arena")) return .{
        .id = "furnace-arena",
        .seed = 0x4655_524e_4143_455f,
        .frozen_time = 6000,
        .setup = &furnace_arena_setup,
    };
    if (std.mem.eql(u8, id, "chest-placement")) return .{
        .id = "chest-placement",
        .seed = 0x4348_4553_545f_504c,
        .frozen_time = 6000,
        .setup = &chest_placement_setup,
    };
    if (std.mem.eql(u8, id, "furnace-placement")) return .{
        .id = "furnace-placement",
        .seed = 0x4655_524e_5f50_4c43,
        .frozen_time = 6000,
        .setup = &furnace_placement_setup,
    };
    if (std.mem.eql(u8, id, "pick-block")) return .{
        .id = "pick-block",
        .seed = 0x5049_434b_424c_4f43,
        .frozen_time = 6000,
        .setup = &pick_block_setup,
    };
    if (std.mem.eql(u8, id, "creative-pick-block")) return .{
        .id = "creative-pick-block",
        .seed = 0x4352_4541_5049_434b,
        .frozen_time = 6000,
        .setup = &creative_pick_block_setup,
    };
    if (std.mem.eql(u8, id, "creative-inventory")) return .{
        .id = "creative-inventory",
        .seed = 0x4352_4541_5449_5645,
        .frozen_time = 6000,
        .setup = &creative_inventory_setup,
    };
    if (std.mem.eql(u8, id, "trapdoors")) return .{
        .id = "trapdoors",
        .seed = 0x5452_4150_444f_4f52,
        .frozen_time = 6000,
        .setup = &trapdoor_setup,
    };
    if (std.mem.eql(u8, id, "doors")) return .{
        .id = "doors",
        .seed = 0x444f_4f52_535f_4d43,
        .frozen_time = 6000,
        .setup = &door_setup,
    };
    if (std.mem.eql(u8, id, "slabs")) return .{
        .id = "slabs",
        .seed = 0x534c_4142_535f_4d43,
        .frozen_time = 6000,
        .setup = &slab_setup,
    };
    if (std.mem.eql(u8, id, "reach-arena")) return .{
        .id = "reach-arena",
        .seed = 0x4d43_435f_5245_4143,
        .frozen_time = 6000,
        .setup = &reach_arena_setup,
    };
    if (std.mem.eql(u8, id, "login-held")) return .{
        .id = "login-held",
        .seed = 0x4d43_435f_4c4f_4749,
        .frozen_time = 6000,
        .setup = &login_held_setup,
    };
    if (std.mem.eql(u8, id, "player-inventory-clicks")) return .{
        .id = "player-inventory-clicks",
        .seed = 0x494e_5645_4e54_4f52,
        .frozen_time = 6000,
        .setup = &player_inventory_clicks_setup,
    };
    if (std.mem.eql(u8, id, "player-collision")) return .{
        .id = "player-collision",
        .seed = 0x434f_4c4c_4953_494f,
        .frozen_time = 6000,
        .setup = &player_collision_setup,
    };
    if (std.mem.eql(u8, id, "combat-arena")) return .{
        .id = "combat-arena",
        .seed = 0x4d43_435f_434f_4d42,
        .frozen_time = 6000,
        .setup = &combat_arena_setup,
    };
    if (std.mem.eql(u8, id, "player-combat")) return .{
        .id = "player-combat",
        .seed = 0x5056_505f_434f_4d42,
        .frozen_time = 6000,
        .setup = &player_combat_setup,
    };
    if (std.mem.eql(u8, id, "player-combat-death")) return .{
        .id = "player-combat-death",
        .seed = 0x5056_505f_4445_4154,
        .frozen_time = 6000,
        .setup = &player_combat_death_setup,
    };
    if (std.mem.eql(u8, id, "entity-lifecycle")) return .{
        .id = "entity-lifecycle",
        .seed = 0x454e_5449_5459_4c43,
        .frozen_time = 13_000,
        .setup = &entity_lifecycle_setup,
    };
    if (std.mem.eql(u8, id, "mob-death")) return .{
        .id = "mob-death",
        .seed = 0x4d4f_4244_4541_5448,
        .frozen_time = 13_000,
        .setup = &mob_death_setup,
    };
    if (std.mem.eql(u8, id, "falling-cows")) return .{
        .id = "falling-cows",
        .seed = 0x4641_4c4c_434f_5753,
        .frozen_time = 13_000,
        .setup = &falling_cows_setup,
    };
    if (std.mem.eql(u8, id, "player-fall-lanes")) return .{
        .id = "player-fall-lanes",
        .seed = 0x504c_4159_4641_4c4c,
        .frozen_time = 13_000,
        .setup = &player_fall_lanes_setup,
    };
    if (std.mem.eql(u8, id, "player-death")) return .{
        .id = "player-death",
        .seed = 0x504c_4159_4445_4154,
        .frozen_time = 13_000,
        .setup = &player_death_setup,
    };
    if (std.mem.eql(u8, id, "cow-temptation")) return .{
        .id = "cow-temptation",
        .seed = 0x434f_575f_5445_4d50,
        .frozen_time = 6000,
        .setup = &cow_temptation_setup,
    };
    if (std.mem.eql(u8, id, "creative-wheat")) return .{
        .id = "creative-wheat",
        .seed = 0x4352_4541_5449_5645,
        .frozen_time = 6000,
        .setup = &creative_wheat_setup,
    };
    if (std.mem.eql(u8, id, "cow-breeding")) return .{
        .id = "cow-breeding",
        .seed = 0x434f_575f_4252_4544,
        .frozen_time = 6000,
        .setup = &cow_breeding_setup,
    };
    if (std.mem.eql(u8, id, "cow-panic")) return .{
        .id = "cow-panic",
        .seed = 0x434f_575f_5041_4e49,
        .frozen_time = 6000,
        .setup = &cow_panic_setup,
    };
    if (std.mem.eql(u8, id, "cow-parent")) return .{
        .id = "cow-parent",
        .seed = 0x434f_575f_5041_5245,
        .frozen_time = 6000,
        .setup = &cow_parent_setup,
    };
    if (std.mem.eql(u8, id, "cow-swim")) return .{
        .id = "cow-swim",
        .seed = 0x434f_575f_5357_494d,
        .frozen_time = 6000,
        .setup = &cow_swim_setup,
    };
    if (std.mem.eql(u8, id, "cow-milking")) return .{
        .id = "cow-milking",
        .seed = 0x434f_575f_4d49_4c4b,
        .frozen_time = 6000,
        .setup = &cow_milking_setup,
    };
    if (std.mem.eql(u8, id, "calf-milking")) return .{
        .id = "calf-milking",
        .seed = 0x4341_4c46_4d49_4c4b,
        .frozen_time = 6000,
        .setup = &calf_milking_setup,
    };
    if (std.mem.eql(u8, id, "cow-wandering")) return .{
        .id = "cow-wandering",
        .seed = 0x434f_575f_5741_4e44,
        .frozen_time = 6000,
        .setup = &cow_wandering_setup,
    };
    if (std.mem.eql(u8, id, "cow-look")) return .{
        .id = "cow-look",
        .seed = 0x434f_575f_4c4f_4f4b,
        .frozen_time = 6000,
        .setup = &cow_look_setup,
    };
    if (std.mem.eql(u8, id, "time-lifecycle")) return .{
        .id = "time-lifecycle",
        .seed = 0x5449_4d45_4c49_4645,
        .frozen_time = 11_999,
        .setup = &time_lifecycle_setup,
    };
    if (std.mem.eql(u8, id, "frozen-daylight-cycle")) return .{
        .id = "frozen-daylight-cycle",
        .seed = 0x5449_4d45_4652_4f5a,
        .frozen_time = 6_000,
        .setup = &frozen_daylight_cycle_setup,
    };
    if (std.mem.eql(u8, id, "zombie-daylight")) return .{
        .id = "zombie-daylight",
        .seed = 0x5a4f_4d42_4945_4441,
        .frozen_time = 1_000,
        .setup = &zombie_daylight_setup,
    };
    if (std.mem.eql(u8, id, "natural-spawning-day")) return .{
        .id = "natural-spawning-day",
        .seed = 0x5350_4157_4e44_4159,
        .frozen_time = 1_000,
        .setup = &natural_spawning_setup,
    };
    if (std.mem.eql(u8, id, "natural-spawning-night")) return .{
        .id = "natural-spawning-night",
        .seed = 0x5350_4157_4e4e_4954,
        .frozen_time = 13_000,
        .setup = &natural_spawning_setup,
    };
    if (std.mem.eql(u8, id, "oak-leaf-connected")) return .{
        .id = "oak-leaf-connected",
        .seed = 0x4d43_435f_4c45_4146,
        .frozen_time = 6000,
        .setup = &oak_leaf_connected_setup,
    };
    if (std.mem.eql(u8, id, "grass-cover")) return .{
        .id = "grass-cover",
        .seed = 0x4752_4153_5343_4f56,
        .frozen_time = 6000,
        .setup = &grass_cover_setup,
    };
    if (std.mem.eql(u8, id, "oak-sapling-break")) return .{
        .id = "oak-sapling-break",
        .seed = 0x4d43_435f_5341_504c,
        .frozen_time = 6000,
        .setup = &oak_sapling_break_setup,
    };
    if (std.mem.eql(u8, id, "oak-leaf-drops")) return .{
        .id = "oak-leaf-drops",
        .seed = 0x4d43_435f_4452_4f50,
        .frozen_time = 6000,
        .setup = &oak_leaf_drop_setup,
    };
    if (std.mem.eql(u8, id, "zombie-open-trapdoor")) return .{
        .id = "zombie-open-trapdoor",
        .seed = 0x4d43_435f_5452_4150,
        .frozen_time = 6000,
        .setup = &zombie_open_trapdoor_setup,
    };
    if (std.mem.eql(u8, id, "campfire")) return .{
        .id = "campfire",
        .seed = 0x4341_4d50_4649_5245,
        .frozen_time = 6000,
        .setup = &campfire_setup,
    };
    if (std.mem.eql(u8, id, "tree-growth")) return .{
        .id = "tree-growth",
        .seed = 0x5452_4545_4752_4f57,
        .frozen_time = 6000,
        .setup = &tree_growth_setup,
    };
    if (std.mem.eql(u8, id, "turtle-crack")) return .{
        .id = "turtle-crack",
        .seed = 0x5455_5254_4c45_4352,
        .frozen_time = 21_595,
        .setup = &turtle_crack_setup,
    };
    if (std.mem.eql(u8, id, "turtle-hatch")) return .{
        .id = "turtle-hatch",
        .seed = 0x5455_5254_4c45_4841,
        .frozen_time = 21_595,
        .setup = &turtle_hatch_setup,
    };
    if (std.mem.eql(u8, id, "dripstone-cauldron")) return .{
        .id = "dripstone-cauldron",
        .seed = 0x4452_4950_4341_554c,
        .frozen_time = 6000,
        .setup = &dripstone_cauldron_setup,
    };
    if (std.mem.eql(u8, id, "cactus-growth")) return .{ .id = "cactus-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &cactus_growth_setup };
    if (std.mem.eql(u8, id, "sugar-cane-growth")) return .{ .id = "sugar-cane-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &sugar_cane_growth_setup };
    if (std.mem.eql(u8, id, "kelp-growth")) return .{ .id = "kelp-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &kelp_growth_setup };
    if (std.mem.eql(u8, id, "bamboo-sapling-growth")) return .{ .id = "bamboo-sapling-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &bamboo_sapling_growth_setup };
    if (std.mem.eql(u8, id, "bamboo-growth")) return .{ .id = "bamboo-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &bamboo_growth_setup };
    if (std.mem.eql(u8, id, "chorus-growth")) return .{ .id = "chorus-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &chorus_growth_setup };
    if (std.mem.eql(u8, id, "mangrove-growth")) return .{ .id = "mangrove-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &mangrove_growth_setup };
    if (std.mem.eql(u8, id, "berry-growth")) return .{ .id = "berry-growth", .seed = 0x4752_4f57_5448_4d45, .frozen_time = 6000, .setup = &berry_growth_setup };
    if (std.mem.eql(u8, id, "random-mechanics")) return .{
        .id = "random-mechanics",
        .seed = 0x5241_4e44_4f4d_544b,
        .frozen_time = 21_595,
        .setup = &random_mechanics_setup,
    };
    if (std.mem.eql(u8, id, "vanilla-1.21.8-flat-seed-7")) return .{
        .id = "vanilla-1.21.8-flat-seed-7",
        .seed = 7,
        .frozen_time = 6000,
        .setup = &vanilla_probe_setup,
    };
    return null;
}
