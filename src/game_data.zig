const std = @import("std");
const data = @import("registry_data");

pub const CraftResult = struct { item_id: i32, count: u8 };
pub const SmeltResult = struct { item_id: i32, count: u8 = 1, cooking_ticks: u16 = 200 };

pub fn itemInfo(item_id: i32) data.ItemInfo {
    if (item_id <= 0 or item_id >= data.items.len) return data.items[0];
    return data.items[@intCast(item_id)];
}

pub fn blockInfo(block_state: i32) data.BlockInfo {
    if (block_state < 0 or block_state > data.maximum_block_state) return data.blocks[0];
    return data.blocks[data.block_state_to_block[@intCast(block_state)]];
}

const empty_light_faces: data.LightFaces = @splat(@splat(0));

pub fn lightFaceOcclusion(block_state: i32) *const data.LightFaces {
    if (block_state < 0 or block_state > data.maximum_block_state)
        return &empty_light_faces;
    if (blockInfo(block_state).visually_transparent)
        return &empty_light_faces;
    const shape = data.block_state_collision_shape[@intCast(block_state)];
    return &data.collision_light_faces[shape];
}

test "generated light faces preserve full cubes and partial support" {
    try std.testing.expectEqual(
        [_]data.LightFace{[_]u64{std.math.maxInt(u64)} ** 4} ** 6,
        lightFaceOcclusion(data.block_stone_default_state).*,
    );
    try std.testing.expectEqual(
        [_]data.LightFace{[_]u64{0} ** 4} ** 6,
        lightFaceOcclusion(data.block_air_default_state).*,
    );
    const bottom_slab = data.blockStateId(
        "minecraft:oak_slab[type=bottom,waterlogged=false]",
    ).?;
    const faces = lightFaceOcclusion(bottom_slab).*;
    try std.testing.expectEqual(
        [_]u64{std.math.maxInt(u64)} ** 4,
        faces[2],
    );
    try std.testing.expectEqual([_]u64{0} ** 4, faces[3]);
}

pub fn preventsGrassSurvival(block_state: i32) bool {
    if (block_state < 0 or block_state > data.maximum_block_state) return false;
    const behavior = data.randomTickState(block_state);
    if (behavior.kind == .snow) return behavior.layers != 1;
    return blockInfo(block_state).filtered_light >= 15 or
        block_state == data.state_water_level_0 or
        block_state == data.state_lava_level_0 or
        data.stateIsWaterlogged(block_state);
}

test "grass survival follows generated light filtering rather than collision" {
    try std.testing.expectEqual(false, preventsGrassSurvival(data.block_chest_default_state));
    try std.testing.expectEqual(false, preventsGrassSurvival(data.block_oak_leaves_default_state));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.block_stone_default_state));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.block_furnace_default_state));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.state_water_level_0));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.state_lava_level_0));
    try std.testing.expectEqual(false, preventsGrassSurvival(data.blockStateId("minecraft:snow[layers=1]").?));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.blockStateId("minecraft:snow[layers=2]").?));
    try std.testing.expectEqual(true, preventsGrassSurvival(data.blockStateId(
        "minecraft:oak_leaves[distance=7,persistent=true,waterlogged=true]",
    ).?));
}

pub fn stackSize(item_id: i32) u8 {
    return itemInfo(item_id).stack_size;
}

pub fn maxDurability(item_id: i32) u16 {
    return itemInfo(item_id).max_durability;
}

pub fn blockStateForItem(item_id: i32) i32 {
    return itemInfo(item_id).block_state;
}

/// Total unenchanted player attack damage for the generated 1.21.8 item ids.
/// The empty hand contributes the player's intrinsic one point of damage.
pub fn playerAttackDamage(item_id: i32) f32 {
    return itemInfo(item_id).attack_damage;
}

pub fn playerAttackSpeed(item_id: i32) f32 {
    return itemInfo(item_id).attack_speed;
}

pub fn playerAttackCooldownTicks(item_id: i32) f32 {
    return 20 / playerAttackSpeed(item_id);
}

pub fn playerAttackCooldownProgress(item_id: i32, elapsed_ticks: u32) f32 {
    return std.math.clamp((@as(f32, @floatFromInt(elapsed_ticks)) + 0.5) / playerAttackCooldownTicks(item_id), 0, 1);
}

pub fn cooldownScaledAttackDamage(item_id: i32, elapsed_ticks: u32) f32 {
    const progress = playerAttackCooldownProgress(item_id, elapsed_ticks);
    return playerAttackDamage(item_id) * (0.2 + progress * progress * 0.8);
}

pub fn equipmentSlot(item_id: i32) u8 {
    return itemInfo(item_id).equipment_slot;
}

test "generated 1.21.8 weapons and tools retain Vanilla attack periods" {
    try std.testing.expectEqual(@as(f32, 12.5), playerAttackCooldownTicks(data.item_diamond_sword_id));
    try std.testing.expectEqual(@as(f32, 20), playerAttackCooldownTicks(data.item_diamond_shovel_id));
    try std.testing.expectApproxEqAbs(@as(f32, 16.666666), playerAttackCooldownTicks(data.item_diamond_pickaxe_id), 0.00001);
    try std.testing.expectEqual(@as(f32, 20), playerAttackCooldownTicks(data.item_diamond_axe_id));
    try std.testing.expectEqual(@as(f32, 5), playerAttackCooldownTicks(data.item_diamond_hoe_id));
    try std.testing.expectApproxEqAbs(@as(f32, 18.181818), playerAttackCooldownTicks(data.item_trident_id), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 33.333332), playerAttackCooldownTicks(data.item_mace_id), 0.00001);
}

test "attack damage follows Vanilla's partial-tick cooldown curve" {
    const shovel = data.item_diamond_shovel_id;
    try std.testing.expectApproxEqAbs(@as(f32, 1.10275), cooldownScaledAttackDamage(shovel, 0), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.31275), cooldownScaledAttackDamage(shovel, 10), 0.00001);
    try std.testing.expectEqual(@as(f32, 5.5), cooldownScaledAttackDamage(shovel, 20));
    try std.testing.expectEqual(@as(f32, 7), cooldownScaledAttackDamage(data.item_diamond_sword_id, 12));
}
pub fn armor(item_id: i32) f32 {
    return itemInfo(item_id).armor;
}
pub fn armorToughness(item_id: i32) f32 {
    return itemInfo(item_id).armor_toughness;
}

pub fn dropItemForBlock(block_state: i32) i32 {
    return blockInfo(block_state).drop_item;
}

pub fn canHarvest(block_state: i32, item_id: i32) bool {
    const block = blockInfo(block_state);
    if (block.harvest_count == 0) return true;
    for (data.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |tool_id| if (tool_id == item_id) return true;
    return false;
}

/// Vanilla's base destruction-time calculation. Status effects,
/// enchantments, water, and airborne penalties can be layered onto speed.
pub fn blockBreakTicks(block_state: i32, item_id: i32) u16 {
    const damage = blockDamagePerTick(block_state, item_id);
    if (damage == 0) return std.math.maxInt(u16);
    return @intFromFloat(@max(1, @min(@as(f32, std.math.maxInt(u16)), @ceil(1.0 / damage))));
}

/// Vanilla's destroy-progress increment for one server game-mode tick.
pub fn blockDamagePerTick(block_state: i32, item_id: i32) f32 {
    const block = blockInfo(block_state);
    if (!block.diggable or block.hardness < 0) return 0;
    if (block.hardness == 0) return 1;

    var speed: f32 = 1;
    for (data.material_tools[block.material_offset..][0..block.material_count]) |tool| {
        if (tool.item_id == item_id) {
            speed = tool.multiplier;
            break;
        }
    }
    const harvestable = canHarvest(block_state, item_id);
    const divisor: f32 = if (harvestable) 30 else 100;
    return speed / block.hardness / divisor;
}

pub fn blockDamageQ32(block_state: i32, item_id: i32) u64 {
    const damage = blockDamagePerTick(block_state, item_id);
    if (damage <= 0) return 0;
    const one: u64 = @as(u64, 1) << 32;
    if (damage >= 1) return one;
    return @intFromFloat(@ceil(@as(f64, damage) * @as(f64, @floatFromInt(one))));
}

/// Matches a normalized 2x2 or 3x3 crafting grid. Item id zero is empty.
pub fn craft(grid: []const i32, width: u8, height: u8) ?CraftResult {
    if ((width != 2 and width != 3) or (height != 2 and height != 3) or grid.len != @as(usize, width) * height) return null;
    var min_x: usize = width;
    var min_y: usize = height;
    var max_x: usize = 0;
    var max_y: usize = 0;
    var occupied: usize = 0;
    for (grid, 0..) |item_id, index| {
        if (item_id == 0) continue;
        const x = index % width;
        const y = index / width;
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
        occupied += 1;
    }
    if (occupied == 0) return null;

    const recipe_indices = data.recipe_indices_by_count[data.recipe_count_offsets[occupied]..data.recipe_count_offsets[occupied + 1]];
    for (recipe_indices) |recipe_index| {
        const recipe = data.recipes[recipe_index];
        switch (recipe.kind) {
            .shaped => {
                if (recipe.width != max_x - min_x + 1 or recipe.height != max_y - min_y + 1) continue;
                if (matchesShaped(grid, width, min_x, min_y, recipe, false) or matchesShaped(grid, width, min_x, min_y, recipe, true))
                    return .{ .item_id = recipe.result_item, .count = recipe.result_count };
            },
            .shapeless => if (matchesShapeless(grid, recipe))
                return .{ .item_id = recipe.result_item, .count = recipe.result_count },
        }
    }
    return null;
}

pub fn smelt(item_id: i32) ?SmeltResult {
    const result = switch (item_id) {
        data.item_raw_iron_id, data.item_iron_ore_id, data.item_deepslate_iron_ore_id => data.item_iron_ingot_id,
        data.item_raw_gold_id, data.item_gold_ore_id, data.item_deepslate_gold_ore_id => data.item_gold_ingot_id,
        data.item_raw_copper_id, data.item_copper_ore_id, data.item_deepslate_copper_ore_id => data.item_copper_ingot_id,
        data.item_sand_id, data.item_red_sand_id => data.item_glass_id,
        data.item_cobblestone_id => data.item_stone_id,
        data.item_stone_id => data.item_smooth_stone_id,
        data.item_clay_ball_id => data.item_brick_id,
        data.item_netherrack_id => data.item_nether_brick_id,
        data.item_cactus_id => data.item_green_dye_id,
        data.item_oak_log_id => data.item_charcoal_id,
        data.item_porkchop_id => data.item_cooked_porkchop_id,
        data.item_beef_id => data.item_cooked_beef_id,
        data.item_chicken_id => data.item_cooked_chicken_id,
        data.item_cod_id => data.item_cooked_cod_id,
        data.item_salmon_id => data.item_cooked_salmon_id,
        data.item_potato_id => data.item_baked_potato_id,
        data.item_mutton_id => data.item_cooked_mutton_id,
        data.item_rabbit_id => data.item_cooked_rabbit_id,
        data.item_kelp_id => data.item_dried_kelp_id,
        data.item_clay_id => data.item_terracotta_id,
        data.item_ancient_debris_id => data.item_netherite_scrap_id,
        else => return null,
    };
    return .{ .item_id = result };
}

pub fn fuelTicks(item_id: i32) u16 {
    return switch (item_id) {
        data.item_lava_bucket_id => 20_000,
        data.item_coal_block_id => 16_000,
        data.item_coal_id, data.item_charcoal_id => 1_600,
        data.item_dried_kelp_block_id => 4_000,
        data.item_blaze_rod_id => 2_400,
        data.item_oak_log_id, data.item_oak_planks_id, data.item_chest_id, data.item_crafting_table_id => 300,
        data.item_stick_id, data.item_oak_sapling_id => 100,
        data.item_bamboo_id => 50,
        else => 0,
    };
}

fn matchesShaped(grid: []const i32, grid_width: usize, min_x: usize, min_y: usize, recipe: data.Recipe, mirrored: bool) bool {
    for (0..recipe.height) |y| for (0..recipe.width) |x| {
        const recipe_x = if (mirrored) recipe.width - 1 - x else x;
        if (grid[(min_y + y) * grid_width + min_x + x] != recipe.ingredients[y * 3 + recipe_x]) return false;
    };
    return true;
}

fn matchesShapeless(grid: []const i32, recipe: data.Recipe) bool {
    var used = [_]bool{false} ** 9;
    for (grid) |item_id| {
        if (item_id == 0) continue;
        var found = false;
        for (recipe.ingredients[0..recipe.ingredient_count], 0..) |ingredient, index| {
            if (!used[index] and ingredient == item_id) {
                used[index] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "generated item and block metadata covers ordinary and durable items" {
    try std.testing.expectEqual(@as(u8, 64), stackSize(data.item_stone_id));
    try std.testing.expectEqual(@as(u16, 1561), maxDurability(data.item_diamond_pickaxe_id));
    try std.testing.expectEqual(data.block_stone_default_state, blockStateForItem(data.item_stone_id));
    try std.testing.expect(blockBreakTicks(data.block_stone_default_state, data.item_diamond_pickaxe_id) < blockBreakTicks(data.block_stone_default_state, 0));
    try std.testing.expectEqual(@as(u16, 6), blockBreakTicks(data.block_stone_default_state, data.item_diamond_pickaxe_id));
    try std.testing.expectApproxEqAbs(@as(f32, 8.0 / 1.5 / 30.0), blockDamagePerTick(data.block_stone_default_state, data.item_diamond_pickaxe_id), 0.00001);
}

test "generated recipes match shaped and shapeless layouts" {
    // Four stone blocks craft stone bricks in this data version.
    const shaped = [_]i32{ data.item_stone_id, data.item_stone_id, data.item_stone_id, data.item_stone_id };
    try std.testing.expect(craft(&shaped, 2, 2) != null);
}
