const std = @import("std");
const minecraft = @import("minecraft_registry");
const random = @import("random.zig");
const surface_data = @import("nether_surface_data");

const width = 16;
const generation_height = 128;
const world_height = 256;
const block_count = width * width * world_height;
const region_side = 3;
const Position = struct { x: i32, y: i32, z: i32 };

pub fn apply(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    applyLayerFeature(generator, population_seed, chunk_x, chunk_z, blocks, 3, 8);
    applyLayerFeature(generator, population_seed, chunk_x, chunk_z, blocks, 4, 5);
    applyLayerFeature(generator, population_seed, chunk_x, chunk_z, blocks, 5, 4);
    applyTwistingVines(generator, population_seed, chunk_x, chunk_z, blocks);
    applyWeepingVines(generator, population_seed, chunk_x, chunk_z, blocks);
    applyLayerFeature(generator, population_seed, chunk_x, chunk_z, blocks, 8, 8);
    applyLayerFeature(generator, population_seed, chunk_x, chunk_z, blocks, 9, 6);
}

fn applyLayerFeature(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8, attempts: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, 9));
    var positions: [4_096]Position = undefined;
    const count = collectLayers(&source, chunk_x, chunk_z, blocks, attempts, &positions);
    for (positions[0..count]) |origin| {
        const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
        const allowed = if (index == 8 or index == 9) biome == .crimson_forest else biome == .warped_forest;
        if (!allowed) continue;
        switch (index) {
            3 => placeHugeFungus(&source, chunk_x, chunk_z, blocks, origin, false),
            4 => placeVegetation(&source, chunk_x, chunk_z, blocks, origin, .warped),
            5 => placeVegetation(&source, chunk_x, chunk_z, blocks, origin, .sprouts),
            8 => placeHugeFungus(&source, chunk_x, chunk_z, blocks, origin, true),
            9 => placeVegetation(&source, chunk_x, chunk_z, blocks, origin, .crimson),
            else => unreachable,
        }
    }
}

fn collectLayers(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, attempts: u8, positions: []Position) usize {
    var count: usize = 0;
    var layer: i32 = 0;
    while (layer < world_height) : (layer += 1) {
        var found = false;
        for (0..attempts) |_| {
            const x = center_x * width + source.nextBoundedI32(width);
            const z = center_z * width + source.nextBoundedI32(width);
            const y = findLayer(center_x, center_z, blocks, x, z, layer) orelse continue;
            std.debug.assert(count < positions.len);
            positions[count] = .{ .x = x, .y = y, .z = z };
            count += 1;
            found = true;
        }
        if (!found) break;
    }
    return count;
}

fn findLayer(center_x: i32, center_z: i32, blocks: anytype, x: i32, z: i32, target: i32) ?i32 {
    var top: i32 = world_height;
    var y: i32 = world_height - 1;
    while (y >= 0) : (y -= 1) {
        const state = blockAt(center_x, center_z, blocks, x, y, z) orelse return null;
        if (!motionBlocking(state.*)) continue;
        top = y + 1;
        break;
    }
    var previous_spawns = true;
    var layer: i32 = 0;
    y = top;
    while (y >= 1) : (y -= 1) {
        const below = blockAt(center_x, center_z, blocks, x, y - 1, z) orelse return null;
        const below_spawns = blocksSpawn(below.*);
        if (!below_spawns and previous_spawns and blockKind(below.*) != .bedrock) {
            if (layer == target) return y;
            layer += 1;
        }
        previous_spawns = below_spawns;
    }
    return null;
}

fn motionBlocking(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    if (kind == .water or kind == .lava) return true;
    return !isAir(block) and !isPlant(kind) and kind != .fire and kind != .soul_fire;
}

const Vegetation = enum { warped, crimson, sprouts };

fn placeVegetation(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, vegetation: Vegetation) void {
    const below = blockAt(center_x, center_z, blocks, origin.x, origin.y - 1, origin.z) orelse return;
    if (!isNylium(below.*) or origin.y < 1 or origin.y + 1 > generation_height - 1) return;
    for (0..64) |_| {
        const candidate = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y + source.nextBoundedI32(4) - source.nextBoundedI32(4),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        const state = vegetationState(source, vegetation);
        const target = blockAt(center_x, center_z, blocks, candidate.x, candidate.y, candidate.z) orelse continue;
        if (!isAir(target.*) or candidate.y <= 0 or !forestPlantCanPlace(center_x, center_z, blocks, candidate)) continue;
        target.* = .{ .feature = state };
    }
}

fn vegetationState(source: *random.ChunkRandom, vegetation: Vegetation) minecraft.State {
    if (vegetation == .sprouts) return minecraft.defaultState(.nether_sprouts);
    const roll = source.nextBoundedI32(if (vegetation == .warped) 100 else 99);
    if (vegetation == .warped) return if (roll < 85)
        minecraft.defaultState(.warped_roots)
    else if (roll == 85)
        minecraft.defaultState(.crimson_roots)
    else if (roll < 99)
        minecraft.defaultState(.warped_fungus)
    else
        minecraft.defaultState(.crimson_fungus);
    return if (roll < 87)
        minecraft.defaultState(.crimson_roots)
    else if (roll < 98)
        minecraft.defaultState(.crimson_fungus)
    else
        minecraft.defaultState(.warped_fungus);
}

fn forestPlantCanPlace(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const below = blockAt(center_x, center_z, blocks, position.x, position.y - 1, position.z) orelse return false;
    const kind = blockKind(below.*) orelse return false;
    return kind == .crimson_nylium or kind == .warped_nylium or kind == .soul_soil;
}

fn applyTwistingVines(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 6, 9));
    for (0..10) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{ .x = x, .y = source.nextBoundedI32(generation_height), .z = z };
        const biome = generator.biomeAtBlock(x, origin.y, z);
        if (biome == .warped_forest) placeTwistingPatch(&source, chunk_x, chunk_z, blocks, origin);
    }
}

fn placeTwistingPatch(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    if (twistingUnsuitable(center_x, center_z, blocks, origin)) return;
    for (0..64) |_| {
        var candidate = Position{
            .x = origin.x - 8 + source.nextBoundedI32(17),
            .y = origin.y - 4 + source.nextBoundedI32(9),
            .z = origin.z - 8 + source.nextBoundedI32(17),
        };
        if (!moveDownToGround(center_x, center_z, blocks, &candidate) or twistingUnsuitable(center_x, center_z, blocks, candidate)) continue;
        var length = 1 + source.nextBoundedI32(8);
        if (source.nextBoundedI32(6) == 0) length *= 2;
        if (source.nextBoundedI32(5) == 0) length = 1;
        growVine(center_x, center_z, blocks, candidate, length, 17, 25, true, source);
    }
}

fn moveDownToGround(center_x: i32, center_z: i32, blocks: anytype, position: *Position) bool {
    while (true) {
        position.y -= 1;
        if (position.y < 0) return false;
        const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
        if (!isAir(state.*)) break;
    }
    position.y += 1;
    return true;
}

fn twistingUnsuitable(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const target = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return true;
    if (!isAir(target.*)) return true;
    const below = blockAt(center_x, center_z, blocks, position.x, position.y - 1, position.z) orelse return true;
    const kind = blockKind(below.*) orelse return true;
    return kind != .netherrack and kind != .warped_nylium and kind != .warped_wart_block;
}

fn applyWeepingVines(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 7, 9));
    for (0..10) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{ .x = x, .y = source.nextBoundedI32(generation_height), .z = z };
        const biome = generator.biomeAtBlock(x, origin.y, z);
        if (biome == .crimson_forest) placeWeepingPatch(&source, chunk_x, chunk_z, blocks, origin);
    }
}

fn placeWeepingPatch(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    if (!isAirAt(center_x, center_z, blocks, origin)) return;
    const above = blockAt(center_x, center_z, blocks, origin.x, origin.y + 1, origin.z) orelse return;
    const above_kind = blockKind(above.*) orelse return;
    if (above_kind != .netherrack and above_kind != .nether_wart_block) return;
    setFeature(center_x, center_z, blocks, origin, minecraft.defaultState(.nether_wart_block));
    spreadNetherWart(source, center_x, center_z, blocks, origin);
    spreadWeepingVines(source, center_x, center_z, blocks, origin);
}

fn spreadNetherWart(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    for (0..200) |_| {
        const target = Position{
            .x = origin.x + source.nextBoundedI32(6) - source.nextBoundedI32(6),
            .y = origin.y + source.nextBoundedI32(2) - source.nextBoundedI32(5),
            .z = origin.z + source.nextBoundedI32(6) - source.nextBoundedI32(6),
        };
        if (!isAirAt(center_x, center_z, blocks, target)) continue;
        if (netherWartNeighborCount(center_x, center_z, blocks, target) == 1)
            setFeature(center_x, center_z, blocks, target, minecraft.defaultState(.nether_wart_block));
    }
}

fn netherWartNeighborCount(center_x: i32, center_z: i32, blocks: anytype, position: Position) u8 {
    const offsets = [_]Position{
        .{ .x = 0, .y = -1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
    };
    var count: u8 = 0;
    for (offsets) |offset| {
        const state = blockAt(center_x, center_z, blocks, position.x + offset.x, position.y + offset.y, position.z + offset.z) orelse continue;
        const kind = blockKind(state.*) orelse continue;
        count += @intFromBool(kind == .netherrack or kind == .nether_wart_block);
        if (count > 1) break;
    }
    return count;
}

fn spreadWeepingVines(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    for (0..100) |_| {
        const target = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y + source.nextBoundedI32(2) - source.nextBoundedI32(7),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        if (!isAirAt(center_x, center_z, blocks, target)) continue;
        const above = blockAt(center_x, center_z, blocks, target.x, target.y + 1, target.z) orelse continue;
        const kind = blockKind(above.*) orelse continue;
        if (kind != .netherrack and kind != .nether_wart_block) continue;
        var length = 1 + source.nextBoundedI32(8);
        if (source.nextBoundedI32(6) == 0) length *= 2;
        if (source.nextBoundedI32(5) == 0) length = 1;
        growVine(center_x, center_z, blocks, target, length, 17, 25, false, source);
    }
}

fn growVine(center_x: i32, center_z: i32, blocks: anytype, origin: Position, length: i32, minimum_age: i32, maximum_age: i32, upward: bool, source: *random.ChunkRandom) void {
    var position = origin;
    const first: i32 = if (upward) 1 else 0;
    var index = first;
    while (index <= length) : (index += 1) {
        if (isAirAt(center_x, center_z, blocks, position)) {
            const next = Position{ .x = position.x, .y = position.y + (if (upward) @as(i32, 1) else -1), .z = position.z };
            if (index == length or !isAirAt(center_x, center_z, blocks, next)) {
                const age = minimum_age + source.nextBoundedI32(maximum_age - minimum_age + 1);
                setFeature(center_x, center_z, blocks, position, vineState(upward, age));
                break;
            }
            const plant = if (upward) minecraft.defaultState(.twisting_vines_plant) else minecraft.defaultState(.weeping_vines_plant);
            setFeature(center_x, center_z, blocks, position, plant);
        }
        position.y += if (upward) 1 else -1;
    }
}

fn vineState(upward: bool, age: i32) minecraft.State {
    var state = minecraft.defaultState(if (upward) .twisting_vines else .weeping_vines);
    state.id += @intCast(age);
    return state;
}

fn placeHugeFungus(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, crimson: bool) void {
    const below = blockAt(center_x, center_z, blocks, origin.x, origin.y - 1, origin.z) orelse return;
    const expected: minecraft.Block = if (crimson) .crimson_nylium else .warped_nylium;
    if (blockKind(below.*) != expected) return;
    var fungus_height = 4 + source.nextBoundedI32(10);
    if (source.nextBoundedI32(12) == 0) fungus_height *= 2;
    if (origin.y + fungus_height + 1 >= generation_height) return;
    const thick = source.nextF32() < 0.06;
    setFeature(center_x, center_z, blocks, origin, minecraft.defaultState(.air));
    growFungusStem(source, center_x, center_z, blocks, origin, fungus_height, thick, crimson);
    growFungusHat(source, center_x, center_z, blocks, origin, fungus_height, thick, crimson);
}

fn growFungusStem(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, fungus_height: i32, thick: bool, crimson: bool) void {
    const radius: i32 = if (thick) 1 else 0;
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            const corner = thick and @abs(dx) == radius and @abs(dz) == radius;
            var dy: i32 = 0;
            while (dy < fungus_height) : (dy += 1) {
                const target = Position{ .x = origin.x + dx, .y = origin.y + dy, .z = origin.z + dz };
                if (!fungusReplaceable(center_x, center_z, blocks, target, true)) continue;
                if (!corner or source.nextF32() < 0.1)
                    setFeature(center_x, center_z, blocks, target, minecraft.defaultState(if (crimson) .crimson_stem else .warped_stem));
            }
        }
    }
}

fn growFungusHat(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, fungus_height: i32, thick: bool, crimson: bool) void {
    const cap_height = @min(source.nextBoundedI32(1 + @divFloor(fungus_height, 3)) + 5, fungus_height);
    const first_y = fungus_height - cap_height;
    var dy = first_y;
    while (dy <= fungus_height) : (dy += 1) {
        var radius: i32 = if (dy < fungus_height - source.nextBoundedI32(3)) 2 else 1;
        if (cap_height > 8 and dy < first_y + 4) radius = 3;
        if (thick) radius += 1;
        growFungusHatLayer(source, center_x, center_z, blocks, origin, dy, radius, first_y, fungus_height, crimson);
    }
}

fn growFungusHatLayer(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, dy: i32, radius: i32, first_y: i32, fungus_height: i32, crimson: bool) void {
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            const edge_x = dx == -radius or dx == radius;
            const edge_z = dz == -radius or dz == radius;
            const interior = !edge_x and !edge_z and dy != fungus_height;
            const corner = edge_x and edge_z;
            const low = dy < first_y + 3;
            const target = Position{ .x = origin.x + dx, .y = origin.y + dy, .z = origin.z + dz };
            if (!fungusReplaceable(center_x, center_z, blocks, target, false)) continue;
            if (low) {
                if (!interior) placeHatWithVines(source, center_x, center_z, blocks, target, crimson);
            } else if (interior) {
                placeHatBlock(source, center_x, center_z, blocks, target, 0.1, 0.2, if (crimson) 0.1 else 0, crimson);
            } else if (corner) {
                placeHatBlock(source, center_x, center_z, blocks, target, 0.01, 0.7, if (crimson) 0.083 else 0, crimson);
            } else {
                placeHatBlock(source, center_x, center_z, blocks, target, 0.0005, 0.98, if (crimson) 0.07 else 0, crimson);
            }
        }
    }
}

fn placeHatBlock(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, position: Position, decor_chance: f32, hat_chance: f32, vine_chance: f32, crimson: bool) void {
    if (source.nextF32() < decor_chance) {
        setFeature(center_x, center_z, blocks, position, minecraft.defaultState(.shroomlight));
    } else if (source.nextF32() < hat_chance) {
        setFeature(center_x, center_z, blocks, position, minecraft.defaultState(if (crimson) .nether_wart_block else .warped_wart_block));
        if (source.nextF32() < vine_chance) growHatVine(source, center_x, center_z, blocks, position);
    }
}

fn placeHatWithVines(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, position: Position, crimson: bool) void {
    const below = blockAt(center_x, center_z, blocks, position.x, position.y - 1, position.z) orelse return;
    const hat: minecraft.Block = if (crimson) .nether_wart_block else .warped_wart_block;
    if (blockKind(below.*) == hat) {
        setFeature(center_x, center_z, blocks, position, minecraft.defaultState(hat));
    } else if (source.nextF32() < 0.15) {
        setFeature(center_x, center_z, blocks, position, minecraft.defaultState(hat));
        if (crimson and source.nextBoundedI32(11) == 0) growHatVine(source, center_x, center_z, blocks, position);
    }
}

fn growHatVine(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, position: Position) void {
    const below = Position{ .x = position.x, .y = position.y - 1, .z = position.z };
    if (!isAirAt(center_x, center_z, blocks, below)) return;
    var length = 1 + source.nextBoundedI32(5);
    if (source.nextBoundedI32(7) == 0) length *= 2;
    growVine(center_x, center_z, blocks, below, length, 23, 25, false, source);
}

fn fungusReplaceable(center_x: i32, center_z: i32, blocks: anytype, position: Position, configured: bool) bool {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
    const kind = blockKind(state.*) orelse return false;
    if (isAir(state.*) or kind == .crimson_roots or kind == .warped_roots or kind == .nether_sprouts or
        kind == .fire or kind == .soul_fire or kind == .lava) return true;
    return configured and (kind == .brown_mushroom or kind == .red_mushroom or
        kind == .warped_fungus or kind == .crimson_fungus or kind == .weeping_vines or
        kind == .weeping_vines_plant or kind == .twisting_vines or kind == .twisting_vines_plant);
}

fn isPlant(kind: minecraft.Block) bool {
    return kind == .brown_mushroom or kind == .red_mushroom or kind == .warped_fungus or kind == .crimson_fungus or
        kind == .warped_roots or kind == .crimson_roots or kind == .nether_sprouts or kind == .weeping_vines or
        kind == .weeping_vines_plant or kind == .twisting_vines or kind == .twisting_vines_plant;
}

fn blocksSpawn(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    return isAir(block) or kind == .water or kind == .lava;
}

fn isNylium(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    return kind == .crimson_nylium or kind == .warped_nylium;
}

fn blockKind(block: anytype) ?minecraft.Block {
    return switch (block) {
        .solid => .netherrack,
        .air, .cave_air => .air,
        .fluid => .lava,
        .surface => |state| minecraft.State.parse(surface_data.block_states[state]).?.block(),
        .feature => |state| state.block(),
    };
}

fn isAir(block: anytype) bool {
    return switch (block) {
        .air, .cave_air => true,
        .feature => |state| state.block() == .air or state.block() == .cave_air,
        .solid, .surface, .fluid => false,
    };
}

fn isAirAt(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
    return isAir(state.*);
}

fn setFeature(center_x: i32, center_z: i32, blocks: anytype, position: Position, state: minecraft.State) void {
    const target = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return;
    target.* = .{ .feature = state };
}

fn blockAt(center_x: i32, center_z: i32, blocks: anytype, x: i32, y: i32, z: i32) ?*@TypeOf(blocks[0]) {
    if (y < 0 or y >= world_height) return null;
    const offset_x = @divFloor(x, width) - center_x;
    const offset_z = @divFloor(z, width) - center_z;
    if (offset_x < -1 or offset_x > 1 or offset_z < -1 or offset_z > 1) return null;
    const chunk = @as(usize, @intCast(offset_z + 1)) * region_side + @as(usize, @intCast(offset_x + 1));
    const local = @as(usize, @intCast(y)) * width * width +
        @as(usize, @intCast(@mod(z, width))) * width + @as(usize, @intCast(@mod(x, width)));
    return &blocks[chunk * block_count + local];
}

test "huge fungi replace lava like Vanilla replaceable blocks" {
    const Block = @import("base_dimension.zig").Block;
    const blocks = try std.testing.allocator.alloc(Block, region_side * region_side * block_count);
    defer std.testing.allocator.free(blocks);
    @memset(blocks, .air);
    blocks[4 * block_count] = .fluid;
    try std.testing.expect(fungusReplaceable(0, 0, blocks, .{ .x = 0, .y = 0, .z = 0 }, false));
}
