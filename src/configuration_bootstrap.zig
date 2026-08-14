const protocol_support = @import("protocol_support");
const registry_data = @import("registry_data");
const terrain = @import("terrain.zig");
const std = @import("std");

pub const damage_types = [_][]const u8{
    "minecraft:arrow",
    "minecraft:bad_respawn_point",
    "minecraft:cactus",
    "minecraft:campfire",
    "minecraft:cramming",
    "minecraft:dragon_breath",
    "minecraft:drown",
    "minecraft:dry_out",
    "minecraft:ender_pearl",
    "minecraft:explosion",
    "minecraft:fall",
    "minecraft:falling_anvil",
    "minecraft:falling_block",
    "minecraft:falling_stalactite",
    "minecraft:fireball",
    "minecraft:fireworks",
    "minecraft:fly_into_wall",
    "minecraft:freeze",
    "minecraft:generic",
    "minecraft:generic_kill",
    "minecraft:hot_floor",
    "minecraft:in_fire",
    "minecraft:in_wall",
    "minecraft:indirect_magic",
    "minecraft:lava",
    "minecraft:lightning_bolt",
    "minecraft:mace_smash",
    "minecraft:magic",
    "minecraft:mob_attack",
    "minecraft:mob_attack_no_aggro",
    "minecraft:mob_projectile",
    "minecraft:on_fire",
    "minecraft:out_of_world",
    "minecraft:outside_border",
    "minecraft:player_attack",
    "minecraft:player_explosion",
    "minecraft:sonic_boom",
    "minecraft:spit",
    "minecraft:stalagmite",
    "minecraft:starve",
    "minecraft:sting",
    "minecraft:sweet_berry_bush",
    "minecraft:thorns",
    "minecraft:thrown",
    "minecraft:trident",
    "minecraft:unattributed_fireball",
    "minecraft:wind_charge",
    "minecraft:wither",
    "minecraft:wither_skull",
};

pub const SingletonRegistry = struct {
    registry_id: []const u8,
    entry_id: []const u8,
};

pub const singleton_registries = [_]SingletonRegistry{
    .{ .registry_id = "minecraft:dimension_type", .entry_id = "minecraft:overworld" },
    .{ .registry_id = "minecraft:cat_variant", .entry_id = "minecraft:tabby" },
    .{ .registry_id = "minecraft:chicken_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:cow_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:frog_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:painting_variant", .entry_id = "minecraft:kebab" },
    .{ .registry_id = "minecraft:pig_variant", .entry_id = "minecraft:temperate" },
    .{ .registry_id = "minecraft:wolf_sound_variant", .entry_id = "minecraft:classic" },
    .{ .registry_id = "minecraft:wolf_variant", .entry_id = "minecraft:pale" },
};

pub fn biomeNames() []const []const u8 {
    return terrain.biomeNames();
}

pub fn writeGameplayTags(buffer: []u8) ![]const u8 {
    var rest = try protocol_support.write_count(buffer, i32, 1);
    rest = try protocol_support.write_pstring(rest, "minecraft:block", i32);
    rest = try protocol_support.write_count(rest, i32, tool_tags.len);
    inline for (tool_tags) |tool_tag| {
        var entry_count: usize = 0;
        for (registry_data.blocks) |block| {
            if (blockUsesTool(block, tool_tag.item_id)) entry_count += 1;
        }
        rest = try protocol_support.write_pstring(rest, tool_tag.name, i32);
        rest = try protocol_support.write_count(rest, i32, entry_count);
        for (registry_data.blocks, 0..) |block, block_id| {
            if (blockUsesTool(block, tool_tag.item_id))
                rest = try protocol_support.write_varint(rest, @intCast(block_id));
        }
    }
    return buffer[0 .. buffer.len - rest.len];
}

const ToolTag = struct {
    name: []const u8,
    item_id: i32,
};

const tool_tags = [_]ToolTag{
    .{ .name = "minecraft:mineable/shovel", .item_id = registry_data.item_diamond_shovel_id },
    .{ .name = "minecraft:mineable/pickaxe", .item_id = registry_data.item_diamond_pickaxe_id },
    .{ .name = "minecraft:mineable/axe", .item_id = registry_data.item_diamond_axe_id },
    .{ .name = "minecraft:mineable/hoe", .item_id = registry_data.item_diamond_hoe_id },
};

fn blockUsesTool(block: registry_data.BlockInfo, item_id: i32) bool {
    for (registry_data.material_tools[block.material_offset..][0..block.material_count]) |tool| {
        if (tool.item_id == item_id) return true;
    }
    return false;
}

test "gameplay tool tags follow block mining rules" {
    const grass = registry_data.blocks[
        registry_data.block_state_to_block[
            registry_data.block_grass_block_default_state
        ]
    ];
    const stone = registry_data.blocks[
        registry_data.block_state_to_block[
            registry_data.block_stone_default_state
        ]
    ];
    try std.testing.expect(blockUsesTool(grass, registry_data.item_diamond_shovel_id));
    try std.testing.expect(!blockUsesTool(grass, registry_data.item_diamond_pickaxe_id));
    try std.testing.expect(blockUsesTool(stone, registry_data.item_diamond_pickaxe_id));
}
