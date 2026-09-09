const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const player_store = lightning_rod.players;
const world_identity = lightning_rod.world_identity;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_random = lightning_rod.random;
const Packets = lightning_rod.Packets;
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

pub fn connectedDistance(block_world: *block_store.Blocks, world: world_identity.Handle, origin: geometry.BlockPos) ?u8 {
    const max_nodes = 512;
    const side = 13;
    const visited_bits = side * side * side;
    var positions: [max_nodes]geometry.BlockPos = undefined;
    var depths: [max_nodes]u8 = undefined;
    var visited = [_]u64{0} ** ((visited_bits + 63) / 64);
    positions[0] = origin;
    depths[0] = 0;
    const origin_index = 6 + 6 * side + 6 * side * side;
    visited[origin_index >> 6] |= @as(u64, 1) << @intCast(origin_index & 63);
    var read: usize = 0;
    var count: usize = 1;
    while (read < count) : (read += 1) {
        const pos = positions[read];
        const depth = depths[read];
        if (depth == 6) continue;
        for (directions) |direction| {
            const neighbor = offset(pos, direction);
            const neighbor_state = block_world.blockAtIfResident(world, neighbor) orelse
                return 1;
            const next_depth = depth + 1;
            if (isSupport(neighbor_state)) return next_depth;
            if (next_depth == 6 or distance(neighbor_state) == null) continue;
            const relative_x = neighbor.x - origin.x + 6;
            const relative_y = @as(i32, neighbor.y) - origin.y + 6;
            const relative_z = neighbor.z - origin.z + 6;
            if (relative_x < 0 or relative_x >= side or relative_y < 0 or relative_y >= side or relative_z < 0 or relative_z >= side) continue;
            const visited_index: usize = @intCast(relative_x + relative_y * side + relative_z * side * side);
            const bit = @as(u64, 1) << @intCast(visited_index & 63);
            if (visited[visited_index >> 6] & bit != 0 or count == max_nodes) continue;
            visited[visited_index >> 6] |= bit;
            positions[count] = neighbor;
            depths[count] = next_depth;
            count += 1;
        }
    }
    return null;
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

pub const OakDropSpawnResult = struct {
    rolled: OakDrops,
    sapling_spawned: bool = false,
    sticks_spawned: bool = false,
    apple_spawned: bool = false,
    spawn_failures: u8 = 0,
    capacity_failures: u8 = 0,
};

pub fn rollOakDrops(random: *world_random.DeterministicRng) OakDrops {
    return .{
        .sapling = random.nextIntBounded(20) == 0,
        .sticks = if (random.nextIntBounded(50) == 0) @intCast(1 + random.nextIntBounded(2)) else 0,
        .apple = random.nextIntBounded(200) == 0,
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

pub fn spawnOakDrops(
    random: *world_random.Random,
    block_world: *block_store.Blocks,
    items: *entity_store.ItemEntities,
    world: world_identity.Handle,
    pos: geometry.BlockPos,
    outputs: *Packets,
) OakDropSpawnResult {
    const drops = rollOakDrops(&random.random);
    const position = entity_store.blockDropPosition(pos);
    const candidates = [_]player_store.HotbarStack{
        if (drops.sapling) player_store.stackForItem(oak_sapling_item_id, 1) else .{},
        if (drops.sticks != 0) player_store.stackForItem(stick_item_id, drops.sticks) else .{},
        if (drops.apple) player_store.stackForItem(apple_item_id, 1) else .{},
    };
    var result = OakDropSpawnResult{ .rolled = drops };
    for (candidates, 0..) |stack, candidate_index| {
        if (stack.isEmpty()) continue;
        const index = items.spawn(random, block_world, world, position, .{ .y = 0.1 }, stack, entity_store.block_drop_pickup_delay_ticks) catch |err| {
            result.spawn_failures += 1;
            if (err == error.ItemEntityCapacity) result.capacity_failures += 1;
            continue;
        };
        outputs.item_spawned(@as(u16, @intCast(index)));
        switch (candidate_index) {
            0 => result.sapling_spawned = true,
            1 => result.sticks_spawned = true,
            2 => result.apple_spawned = true,
            else => unreachable,
        }
    }
    return result;
}
