const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const registry = lightning_rod.registry_data;

pub const directions = [_]geometry.BlockPos{
    .{ .x = 0, .y = -1, .z = 0 },
    .{ .x = 0, .y = 1, .z = 0 },
    .{ .x = 0, .y = 0, .z = -1 },
    .{ .x = 0, .y = 0, .z = 1 },
    .{ .x = -1, .y = 0, .z = 0 },
    .{ .x = 1, .y = 0, .z = 0 },
};

pub fn offset(pos: geometry.BlockPos, delta: geometry.BlockPos) geometry.BlockPos {
    return .{ .x = pos.x + delta.x, .y = pos.y + delta.y, .z = pos.z + delta.z };
}

pub fn distance(block_state: i32) ?u8 {
    return registry.leafDistance(block_state);
}

pub fn withDistance(block_state: i32, value: u8) i32 {
    const block_id = registry.block_state_to_block[@intCast(block_state)];
    const block = registry.blocks[@intCast(block_id)];
    return block.min_state + (@as(i32, value) - 1) * 4 + @mod(block_state - block.min_state, 4);
}

pub fn isSupport(block_state: i32) bool {
    return registry.isLeafSupport(block_state);
}

pub fn isOak(block_state: i32) bool {
    return block_state >= 0 and block_state < registry.block_state_to_block.len and
        registry.block_state_to_block[@intCast(block_state)] == registry.block_oak_leaves_id;
}

pub fn isDecayingOak(block_state: i32) bool {
    if (!isOak(block_state)) return false;
    const leaf = registry.blocks[@intCast(registry.block_oak_leaves_id)];
    const property_index = block_state - leaf.min_state;
    return @divTrunc(property_index, 4) + 1 == 7 and @mod(property_index, 4) >= 2;
}

pub const OakDrops = struct {
    sapling: bool = false,
    sticks: u8 = 0,
    apple: bool = false,
};

pub fn rollOakDrops(random: *world_random.DeterministicRng) OakDrops {
    return .{
        .sapling = random.nextIntBounded(20) == 0,
        .sticks = if (random.nextIntBounded(50) == 0) @intCast(1 + random.nextIntBounded(2)) else 0,
        .apple = random.nextIntBounded(200) == 0,
    };
}

pub fn oakDropStacks(drops: OakDrops) [3]player_store.HotbarStack {
    return .{
        if (drops.sapling) player_store.stackForItem(oak_sapling_item_id, 1) else .{},
        if (drops.sticks != 0) player_store.stackForItem(stick_item_id, drops.sticks) else .{},
        if (drops.apple) player_store.stackForItem(apple_item_id, 1) else .{},
    };
}

const oak_sapling_item_id = blk: {
    @setEvalBranchQuota(10_000);
    break :blk registry.itemId("minecraft:oak_sapling").?;
};
const stick_item_id = blk: {
    @setEvalBranchQuota(10_000);
    break :blk registry.itemId("minecraft:stick").?;
};
const apple_item_id = blk: {
    @setEvalBranchQuota(10_000);
    break :blk registry.itemId("minecraft:apple").?;
};
