//! Block properties for engine tests and benchmarks, built from the game data snapshot
//! instead of vanilla content: vanilla light, with chests and furnaces as block entities.
const std = @import("std");
const game_data = @import("game_data");
const BlockProperties = @import("block_properties").BlockProperties;

pub fn vanilla(allocator: std.mem.Allocator) !*BlockProperties {
    const light = try game_data.lighting.init(allocator);
    const entities = try allocator.alloc(?u8, light.states.len);
    const chest = game_data.registry.block_state_to_block[game_data.registry.block_chest_default_state];
    const furnace = game_data.registry.block_state_to_block[game_data.registry.block_furnace_default_state];
    for (entities, 0..) |*entity, state| {
        const block = game_data.registry.block_state_to_block[state];
        entity.* = if (block == chest) 0 else if (block == furnace) 1 else null;
    }
    const blocks = try allocator.create(BlockProperties);
    blocks.* = .init(light, entities, &.{ "minecraft:chest", "minecraft:furnace" });
    return blocks;
}
