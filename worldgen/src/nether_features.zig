const std = @import("std");
const minecraft = @import("minecraft_registry");
const random = @import("random.zig");
const surface_data = @import("nether_surface_data");
const forest_features = @import("nether_forest_features.zig");
const nether_structures = @import("nether_structures.zig");

const width = 16;
const generation_height = 128;
const world_height = 256;
const chunk_block_count = width * width * world_height;
pub const enabled = true;
pub const region_side = 3;
pub const Scratch = nether_structures.Scratch;

pub const prepareDensity = nether_structures.prepareDensity;
pub const adjustDensity = nether_structures.adjustDensity;

const Biome = @import("dimension_biome.zig").Biome;
const Position = struct { x: i32, y: i32, z: i32 };
const Height = union(enum) {
    uniform: struct { minimum: i32, maximum: i32 },
    trapezoid: struct { minimum: i32, maximum: i32 },
};
const Target = enum { netherrack, base_stone_nether };
const Ore = struct {
    index: u8,
    count: u8,
    height: Height,
    size: u8,
    discard: f32 = 0,
    target: Target = .netherrack,
    state: minecraft.State,
    biomes: u8,
    scattered: bool = false,
};
const Spring = struct {
    index: u8,
    count: u8,
    minimum_y: i32,
    maximum_y: i32,
    requires_below: bool,
    rock_count: u8,
    hole_count: u8,
    broad_target: bool,
    biomes: u8,
};

const nether_wastes = @as(u8, 1) << @intFromEnum(Biome.nether_wastes);
const crimson_forest = @as(u8, 1) << @intFromEnum(Biome.crimson_forest);
const soul_sand_valley = @as(u8, 1) << @intFromEnum(Biome.soul_sand_valley);
const basalt_deltas = @as(u8, 1) << @intFromEnum(Biome.basalt_deltas);
const warped_forest = @as(u8, 1) << @intFromEnum(Biome.warped_forest);
const all_nether = nether_wastes | crimson_forest | soul_sand_valley |
    basalt_deltas | warped_forest;
const all_except_deltas = all_nether & ~basalt_deltas;

const ores = [_]Ore{
    .{ .index = 11, .count = 4, .height = .{ .uniform = .{ .minimum = 27, .maximum = 36 } }, .size = 33, .state = minecraft.defaultState(.magma_block), .biomes = all_nether },
    .{ .index = 13, .count = 20, .height = .{ .uniform = .{ .minimum = 10, .maximum = 117 } }, .size = 10, .state = minecraft.defaultState(.nether_gold_ore), .biomes = basalt_deltas },
    .{ .index = 14, .count = 32, .height = .{ .uniform = .{ .minimum = 10, .maximum = 117 } }, .size = 14, .state = minecraft.defaultState(.nether_quartz_ore), .biomes = basalt_deltas },
    .{ .index = 16, .count = 12, .height = .{ .uniform = .{ .minimum = 0, .maximum = 31 } }, .size = 12, .state = minecraft.defaultState(.soul_sand), .biomes = soul_sand_valley },
    .{ .index = 17, .count = 2, .height = .{ .uniform = .{ .minimum = 5, .maximum = 41 } }, .size = 33, .state = minecraft.defaultState(.gravel), .biomes = all_except_deltas },
    .{ .index = 18, .count = 2, .height = .{ .uniform = .{ .minimum = 5, .maximum = 31 } }, .size = 33, .state = minecraft.defaultState(.blackstone), .biomes = all_except_deltas },
    .{ .index = 19, .count = 10, .height = .{ .uniform = .{ .minimum = 10, .maximum = 117 } }, .size = 10, .state = minecraft.defaultState(.nether_gold_ore), .biomes = all_except_deltas },
    .{ .index = 20, .count = 16, .height = .{ .uniform = .{ .minimum = 10, .maximum = 117 } }, .size = 14, .state = minecraft.defaultState(.nether_quartz_ore), .biomes = all_except_deltas },
    .{ .index = 21, .count = 1, .height = .{ .trapezoid = .{ .minimum = 8, .maximum = 24 } }, .size = 3, .discard = 1, .target = .base_stone_nether, .state = minecraft.defaultState(.ancient_debris), .biomes = all_nether, .scattered = true },
    .{ .index = 22, .count = 1, .height = .{ .uniform = .{ .minimum = 8, .maximum = 119 } }, .size = 2, .discard = 1, .target = .base_stone_nether, .state = minecraft.defaultState(.ancient_debris), .biomes = all_nether, .scattered = true },
};
const springs = [_]Spring{
    .{ .index = 2, .count = 16, .minimum_y = 4, .maximum_y = 123, .requires_below = true, .rock_count = 4, .hole_count = 1, .broad_target = true, .biomes = basalt_deltas },
    .{ .index = 3, .count = 8, .minimum_y = 4, .maximum_y = 123, .requires_below = false, .rock_count = 4, .hole_count = 1, .broad_target = false, .biomes = all_except_deltas },
    .{ .index = 12, .count = 32, .minimum_y = 10, .maximum_y = 117, .requires_below = false, .rock_count = 5, .hole_count = 0, .broad_target = false, .biomes = basalt_deltas },
    .{ .index = 15, .count = 16, .minimum_y = 10, .maximum_y = 117, .requires_below = false, .rock_count = 5, .hole_count = 0, .broad_target = false, .biomes = all_except_deltas },
};

pub fn apply(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, scratch: *Scratch, blocks: anytype) void {
    applyStructures(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
    applyDecorations(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
}

pub fn applyStructures(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, scratch: *Scratch, blocks: anytype) void {
    std.debug.assert(blocks.len == region_side * region_side * chunk_block_count);
    nether_structures.applyUnderground(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
    nether_structures.applySurface(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
}

pub fn applyDecorations(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, _: *Scratch, blocks: anytype) void {
    std.debug.assert(blocks.len == region_side * region_side * chunk_block_count);
    const population_seed = random.ChunkRandom.populationSeed(world_seed, chunk_x * width, chunk_z * width);
    applyBasaltPillars(generator, population_seed, chunk_x, chunk_z, blocks);
    applyDeltas(generator, population_seed, chunk_x, chunk_z, blocks);
    applyBasaltColumns(generator, population_seed, chunk_x, chunk_z, blocks, 1);
    applyBasaltColumns(generator, population_seed, chunk_x, chunk_z, blocks, 2);
    for (0..23) |index| {
        if (index == 0 or index == 1)
            applyReplaceBlobs(generator, population_seed, chunk_x, chunk_z, blocks, @intCast(index));
        if (index == 4 or index == 5)
            applyFirePatch(generator, population_seed, chunk_x, chunk_z, blocks, @intCast(index));
        if (index == 8)
            applyCrimsonRoots(generator, population_seed, chunk_x, chunk_z, blocks);
        for (springs) |spring|
            if (spring.index == index)
                applySpring(generator, population_seed, chunk_x, chunk_z, blocks, spring);
        if (index == 6 or index == 7)
            applyGlowstone(generator, population_seed, chunk_x, chunk_z, blocks, @intCast(index));
        for (ores) |ore|
            if (ore.index == index)
                applyOre(generator, population_seed, chunk_x, chunk_z, blocks, ore);
        if (index == 9 or index == 10)
            applyMushroomPatch(generator, population_seed, chunk_x, chunk_z, blocks, @intCast(index), 7);
    }
    applyMushroomPatch(generator, population_seed, chunk_x, chunk_z, blocks, 1, 9);
    applyMushroomPatch(generator, population_seed, chunk_x, chunk_z, blocks, 2, 9);
    forest_features.apply(generator, population_seed, chunk_x, chunk_z, blocks);
}

fn applyCrimsonRoots(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 8, 7));
    const origin = Position{ .x = chunk_x * width, .y = source.nextBoundedI32(generation_height), .z = chunk_z * width };
    const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
    if (biome != .soul_sand_valley) return;
    for (0..96) |_| {
        const candidate = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y + source.nextBoundedI32(4) - source.nextBoundedI32(4),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        const target = blockAt(chunk_x, chunk_z, blocks, candidate.x, candidate.y, candidate.z) orelse continue;
        const below = blockAt(chunk_x, chunk_z, blocks, candidate.x, candidate.y - 1, candidate.z) orelse continue;
        const floor = blockKind(below.*) orelse continue;
        if (isAir(target.*) and (floor == .crimson_nylium or floor == .warped_nylium or floor == .soul_soil))
            target.* = .{ .feature = minecraft.defaultState(.crimson_roots) };
    }
}

fn applyFirePatch(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, 7));
    const count = source.nextBoundedI32(6);
    for (0..@as(usize, @intCast(count))) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{ .x = x, .y = 4 + source.nextBoundedI32(120), .z = z };
        const biome = generator.biomeAtBlock(x, origin.y, z);
        if (index == 5 and biome == .crimson_forest) continue;
        placeFirePatch(&source, chunk_x, chunk_z, blocks, origin, index == 5);
    }
}

fn placeFirePatch(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, soul: bool) void {
    const state = minecraft.defaultState(if (soul) .soul_fire else .fire);
    const floor: minecraft.Block = if (soul) .soul_soil else .netherrack;
    for (0..96) |_| {
        const candidate = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y + source.nextBoundedI32(4) - source.nextBoundedI32(4),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        const target = blockAt(center_x, center_z, blocks, candidate.x, candidate.y, candidate.z) orelse continue;
        const below = blockAt(center_x, center_z, blocks, candidate.x, candidate.y - 1, candidate.z) orelse continue;
        if (isPlainAir(target.*) and blockKind(below.*) == floor) target.* = .{ .feature = state };
    }
}

fn applyBasaltPillars(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 2));
    for (0..10) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{ .x = x, .y = source.nextBoundedI32(generation_height), .z = z };
        const biome = generator.biomeAtBlock(x, origin.y, z);
        if (biome == .soul_sand_valley) placeBasaltPillar(&source, chunk_x, chunk_z, blocks, origin);
    }
}

fn placeBasaltPillar(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    if (!isAirAt(center_x, center_z, blocks, origin) or isAirAt(center_x, center_z, blocks, .{ .x = origin.x, .y = origin.y + 1, .z = origin.z })) return;
    var active = [_]bool{ true, true, true, true };
    const offsets = [_]Position{
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
    };
    var position = origin;
    while (position.y >= 0 and isAirAt(center_x, center_z, blocks, position)) : (position.y -= 1) {
        setFeature(center_x, center_z, blocks, position, minecraft.defaultState(.basalt));
        for (offsets, 0..) |offset, index| {
            if (!active[index]) continue;
            const side = offsetBlock(position, offset);
            if (source.nextBoundedI32(10) == 0) active[index] = false else setFeature(center_x, center_z, blocks, side, minecraft.defaultState(.basalt));
        }
    }
    position.y += 1;
    for (offsets) |offset| if (source.nextBool())
        setFeature(center_x, center_z, blocks, offsetBlock(position, offset), minecraft.defaultState(.basalt));
    position.y -= 1;
    placeBasaltPillarBase(source, center_x, center_z, blocks, position);
}

fn placeBasaltPillarBase(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    var dx: i32 = -3;
    while (dx <= 3) : (dx += 1) {
        var dz: i32 = -3;
        while (dz <= 3) : (dz += 1) {
            const product = @as(i32, @intCast(@abs(dx))) * @as(i32, @intCast(@abs(dz)));
            if (source.nextBoundedI32(10) >= 10 - product) continue;
            var target = Position{ .x = origin.x + dx, .y = origin.y, .z = origin.z + dz };
            var remaining: u8 = 3;
            while (remaining > 0 and isAirAt(center_x, center_z, blocks, .{ .x = target.x, .y = target.y - 1, .z = target.z })) {
                target.y -= 1;
                remaining -= 1;
            }
            if (!isAirAt(center_x, center_z, blocks, .{ .x = target.x, .y = target.y - 1, .z = target.z }))
                setFeature(center_x, center_z, blocks, target, minecraft.defaultState(.basalt));
        }
    }
}

fn applyMushroomPatch(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8, step: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, step));
    const chance: i32 = if (step == 7) 2 else if (index == 1) 256 else 512;
    if (source.nextF32() >= 1.0 / @as(f32, @floatFromInt(chance))) return;
    const x = chunk_x * width + source.nextBoundedI32(width);
    const z = chunk_z * width + source.nextBoundedI32(width);
    const y = if (step == 7) source.nextBoundedI32(generation_height) else motionBlockingTop(chunk_x, chunk_z, blocks, x, z);
    if (y <= 0) return;
    const origin = Position{ .x = x, .y = y, .z = z };
    const biome = generator.biomeAtBlock(x, y, z);
    const allowed = if (step == 7)
        biome == .nether_wastes or biome == .soul_sand_valley or biome == .basalt_deltas
    else
        biome == .nether_wastes or biome == .crimson_forest or biome == .warped_forest;
    if (!allowed) return;
    const state = if ((step == 7 and index == 9) or (step == 9 and index == 1))
        minecraft.defaultState(.brown_mushroom)
    else
        minecraft.defaultState(.red_mushroom);
    placeRandomPatch(&source, chunk_x, chunk_z, blocks, origin, state);
}

fn placeRandomPatch(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, state: minecraft.State) void {
    for (0..96) |_| {
        const candidate = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y + source.nextBoundedI32(4) - source.nextBoundedI32(4),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        const target = blockAt(center_x, center_z, blocks, candidate.x, candidate.y, candidate.z) orelse continue;
        if (!isPlainAir(target.*) or !mushroomCanPlace(center_x, center_z, blocks, candidate)) continue;
        target.* = .{ .feature = state };
    }
}

fn mushroomCanPlace(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const below = blockAt(center_x, center_z, blocks, position.x, position.y - 1, position.z) orelse return false;
    const kind = blockKind(below.*) orelse return false;
    if (kind == .crimson_nylium or kind == .warped_nylium or kind == .mycelium or kind == .podzol) return true;
    return isOpaqueFullCube(kind);
}

fn isOpaqueFullCube(kind: minecraft.Block) bool {
    return kind != .air and kind != .cave_air and kind != .lava and kind != .water and
        kind != .soul_sand and kind != .soul_soil and
        kind != .brown_mushroom and kind != .red_mushroom and kind != .fire and kind != .soul_fire;
}

fn motionBlockingTop(center_x: i32, center_z: i32, blocks: anytype, x: i32, z: i32) i32 {
    var y: i32 = world_height - 1;
    while (y >= 0) : (y -= 1) {
        const state = blockAt(center_x, center_z, blocks, x, y, z) orelse return 0;
        const kind = blockKind(state.*) orelse continue;
        if (isOpaqueFullCube(kind) or kind == .water or kind == .lava) return y + 1;
    }
    return 0;
}

fn applyReplaceBlobs(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, 7));
    const attempts: usize = if (index == 0) 75 else 25;
    const replacement = if (index == 0) minecraft.defaultState(.basalt) else minecraft.defaultState(.blackstone);
    for (0..attempts) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{
            .x = x,
            .y = source.nextBoundedI32(generation_height),
            .z = z,
        };
        const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
        if (biome != .basalt_deltas) continue;
        placeReplaceBlob(&source, chunk_x, chunk_z, blocks, origin, replacement);
    }
}

fn placeReplaceBlob(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, replacement: minecraft.State) void {
    var center = origin;
    center.y = std.math.clamp(center.y, 1, generation_height - 1);
    while (center.y > 1) : (center.y -= 1) {
        const state = blockAt(center_x, center_z, blocks, center.x, center.y, center.z) orelse return;
        if (blockKind(state.*) == .netherrack) break;
    } else return;
    const range_x = 3 + source.nextBoundedI32(5);
    const range_y = 3 + source.nextBoundedI32(5);
    const range_z = 3 + source.nextBoundedI32(5);
    const maximum = @max(range_x, @max(range_y, range_z));
    replaceBlobOutwards(center_x, center_z, blocks, center, .{ .x = range_x, .y = range_y, .z = range_z }, maximum, replacement);
}

fn replaceBlobOutwards(center_x: i32, center_z: i32, blocks: anytype, origin: Position, range: Position, maximum: i32, replacement: minecraft.State) void {
    var distance: i32 = 0;
    while (distance <= maximum) : (distance += 1) {
        const limit_x = @min(range.x, distance);
        var dx = -limit_x;
        while (dx <= limit_x) : (dx += 1) {
            const limit_y = @min(range.y, distance - @as(i32, @intCast(@abs(dx))));
            var dy = -limit_y;
            while (dy <= limit_y) : (dy += 1) {
                const dz = distance - @as(i32, @intCast(@abs(dx))) - @as(i32, @intCast(@abs(dy)));
                if (dz > range.z) continue;
                replaceBlobPoint(center_x, center_z, blocks, origin, dx, dy, dz, replacement);
                if (dz != 0) replaceBlobPoint(center_x, center_z, blocks, origin, dx, dy, -dz, replacement);
            }
        }
    }
}

fn replaceBlobPoint(center_x: i32, center_z: i32, blocks: anytype, origin: Position, dx: i32, dy: i32, dz: i32, replacement: minecraft.State) void {
    const target = blockAt(center_x, center_z, blocks, origin.x + dx, origin.y + dy, origin.z + dz) orelse return;
    if (blockKind(target.*) == .netherrack) target.* = .{ .feature = replacement };
}

fn applyBasaltColumns(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, 4));
    var positions: [4_096]Position = undefined;
    const attempts: u8 = if (index == 1) 4 else 2;
    const count = collectLayerPositions(&source, chunk_x, chunk_z, blocks, attempts, &positions);
    for (positions[0..count]) |origin| {
        const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
        if (biome != .basalt_deltas) continue;
        placeBasaltColumns(&source, chunk_x, chunk_z, blocks, origin, index);
    }
}

fn placeBasaltColumns(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, index: u8) void {
    if (!canPlaceBasaltAt(center_x, center_z, blocks, origin)) return;
    const column_height = if (index == 1)
        1 + source.nextBoundedI32(4)
    else
        5 + source.nextBoundedI32(6);
    const dense = source.nextF32() < 0.9;
    const radius = @min(column_height, if (dense) @as(i32, 5) else 8);
    const attempts: usize = if (dense) 50 else 15;
    for (0..attempts) |_| {
        const candidate = Position{
            .x = origin.x - radius + source.nextBoundedI32(2 * radius + 1),
            .y = origin.y + source.nextBoundedI32(1),
            .z = origin.z - radius + source.nextBoundedI32(2 * radius + 1),
        };
        const distance = manhattan(candidate, origin);
        if (distance > column_height) continue;
        const reach = if (index == 1) 1 else 2 + source.nextBoundedI32(2);
        placeBasaltColumn(center_x, center_z, blocks, candidate, column_height - distance, reach);
    }
}

fn placeBasaltColumn(center_x: i32, center_z: i32, blocks: anytype, origin: Position, column_height: i32, reach: i32) void {
    var z = origin.z - reach;
    while (z <= origin.z + reach) : (z += 1) {
        var x = origin.x - reach;
        while (x <= origin.x + reach) : (x += 1) {
            const position = Position{ .x = x, .y = origin.y, .z = z };
            const distance = manhattan(position, origin);
            const start = basaltColumnStart(center_x, center_z, blocks, position, distance) orelse continue;
            growBasaltColumn(center_x, center_z, blocks, start, column_height - @divFloor(distance, 2));
        }
    }
}

fn basaltColumnStart(center_x: i32, center_z: i32, blocks: anytype, origin: Position, distance: i32) ?Position {
    if (isAirOrLavaOcean(center_x, center_z, blocks, origin)) {
        var position = origin;
        var remaining = distance;
        while (position.y > 1 and remaining > 0) : (position.y -= 1) {
            remaining -= 1;
            if (canPlaceBasaltAt(center_x, center_z, blocks, position)) return position;
        }
        return null;
    }
    var position = origin;
    var remaining = distance;
    while (position.y <= generation_height - 1 and remaining > 0) : (position.y += 1) {
        remaining -= 1;
        const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return null;
        if (cannotReplaceBasalt(state.*)) return null;
        if (isAir(state.*)) return position;
    }
    return null;
}

fn growBasaltColumn(center_x: i32, center_z: i32, blocks: anytype, start: Position, column_height: i32) void {
    var position = start;
    var remaining = column_height;
    while (remaining >= 0 and position.y < generation_height) : ({
        remaining -= 1;
        position.y += 1;
    }) {
        const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return;
        if (isAirOrLavaOcean(center_x, center_z, blocks, position)) {
            state.* = .{ .feature = minecraft.defaultState(.basalt) };
        } else if (blockKind(state.*) != .basalt) return;
    }
}

fn applyDeltas(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 4));
    var positions: [4_096]Position = undefined;
    const count = collectLayerPositions(&source, chunk_x, chunk_z, blocks, 40, &positions);
    for (positions[0..count]) |origin| {
        const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
        if (biome != .basalt_deltas) continue;
        placeDelta(&source, chunk_x, chunk_z, blocks, origin);
    }
}

fn collectLayerPositions(
    source: *random.ChunkRandom,
    center_x: i32,
    center_z: i32,
    blocks: anytype,
    attempts_per_layer: u8,
    positions: []Position,
) usize {
    var count: usize = 0;
    var layer: i32 = 0;
    while (layer < world_height) : (layer += 1) {
        var found = false;
        for (0..attempts_per_layer) |_| {
            const x = center_x * width + source.nextBoundedI32(width);
            const z = center_z * width + source.nextBoundedI32(width);
            const y = findLayer(blocks, center_x, center_z, x, z, layer) orelse continue;
            std.debug.assert(count < positions.len);
            positions[count] = .{ .x = x, .y = y, .z = z };
            count += 1;
            found = true;
        }
        if (!found) break;
    }
    return count;
}

fn findLayer(blocks: anytype, center_x: i32, center_z: i32, x: i32, z: i32, target_layer: i32) ?i32 {
    var top_y: i32 = world_height;
    var y: i32 = world_height - 1;
    while (y >= 0) : (y -= 1) {
        const state = blockAt(center_x, center_z, blocks, x, y, z) orelse return null;
        if (!motionBlocking(state.*)) continue;
        top_y = y + 1;
        break;
    }
    var current_spawns = true;
    var layer: i32 = 0;
    y = top_y;
    while (y >= 1) : (y -= 1) {
        const below = blockAt(center_x, center_z, blocks, x, y - 1, z) orelse return null;
        const below_spawns = blocksSpawn(below.*);
        if (!below_spawns and current_spawns and blockKind(below.*) != .bedrock) {
            if (layer == target_layer) return y;
            layer += 1;
        }
        current_spawns = below_spawns;
    }
    return null;
}

fn motionBlocking(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    if (kind == .water or kind == .lava) return true;
    return !isAir(block) and kind != .brown_mushroom and kind != .red_mushroom and
        kind != .crimson_roots and kind != .warped_roots and kind != .nether_sprouts and
        kind != .crimson_fungus and kind != .warped_fungus and kind != .weeping_vines and
        kind != .weeping_vines_plant and kind != .twisting_vines and kind != .twisting_vines_plant and
        kind != .fire and kind != .soul_fire;
}

fn placeDelta(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    const rimmed = source.nextF64() < 0.9;
    const rim_x = if (rimmed) source.nextBoundedI32(3) else 0;
    const rim_z = if (rimmed) source.nextBoundedI32(3) else 0;
    const has_rim = rimmed and rim_x != 0 and rim_z != 0;
    const range_x = 3 + source.nextBoundedI32(5);
    const range_z = 3 + source.nextBoundedI32(5);
    const maximum = @max(range_x, range_z);
    var distance: i32 = 0;
    while (distance <= maximum) : (distance += 1) {
        const limit_x = @min(range_x, distance);
        var dx = -limit_x;
        while (dx <= limit_x) : (dx += 1) {
            const dz = distance - @as(i32, @intCast(@abs(dx)));
            if (dz > range_z) continue;
            if (!placeDeltaPoint(center_x, center_z, blocks, origin, dx, dz, rim_x, rim_z, has_rim) or dz == 0) continue;
            _ = placeDeltaPoint(center_x, center_z, blocks, origin, dx, -dz, rim_x, rim_z, has_rim);
        }
    }
}

fn placeDeltaPoint(
    center_x: i32,
    center_z: i32,
    blocks: anytype,
    origin: Position,
    dx: i32,
    dz: i32,
    rim_x: i32,
    rim_z: i32,
    has_rim: bool,
) bool {
    const position = Position{ .x = origin.x + dx, .y = origin.y, .z = origin.z + dz };
    if (!deltaCanPlace(center_x, center_z, blocks, position)) return true;
    if (has_rim) setFeature(center_x, center_z, blocks, position, minecraft.defaultState(.magma_block));
    const content = Position{ .x = position.x + rim_x, .y = position.y, .z = position.z + rim_z };
    if (deltaCanPlace(center_x, center_z, blocks, content))
        setFeature(center_x, center_z, blocks, content, minecraft.defaultState(.lava));
    return true;
}

fn setFeature(center_x: i32, center_z: i32, blocks: anytype, position: Position, state: minecraft.State) void {
    const target = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return;
    target.* = .{ .feature = state };
}

fn blocksSpawn(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    return isAir(block) or kind == .water or kind == .lava;
}

fn isAirAt(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
    return isAir(state.*);
}

fn offsetBlock(position: Position, offset: Position) Position {
    return .{ .x = position.x + offset.x, .y = position.y + offset.y, .z = position.z + offset.z };
}

fn canPlaceBasaltAt(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    if (!isAirOrLavaOcean(center_x, center_z, blocks, position)) return false;
    const below = blockAt(center_x, center_z, blocks, position.x, position.y - 1, position.z) orelse return false;
    return !isAir(below.*) and !cannotReplaceBasalt(below.*);
}

fn isAirOrLavaOcean(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
    return isAir(state.*) or (blockKind(state.*) == .lava and position.y <= 32);
}

fn cannotReplaceBasalt(block: anytype) bool {
    const kind = blockKind(block) orelse return false;
    return kind == .lava or kind == .bedrock or kind == .magma_block or kind == .soul_sand or
        kind == .nether_bricks or kind == .nether_brick_fence or kind == .nether_brick_stairs or
        kind == .nether_wart or kind == .chest or kind == .spawner;
}

fn manhattan(left: Position, right: Position) i32 {
    return @as(i32, @intCast(@abs(left.x - right.x))) +
        @as(i32, @intCast(@abs(left.y - right.y))) +
        @as(i32, @intCast(@abs(left.z - right.z)));
}

fn deltaCanPlace(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return false;
    const kind = blockKind(state.*) orelse return false;
    if (kind == .lava or kind == .bedrock or kind == .nether_bricks or kind == .nether_brick_fence or
        kind == .nether_brick_stairs or kind == .nether_wart or kind == .chest or kind == .spawner) return false;
    const offsets = [_]Position{
        .{ .x = 0, .y = -1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
    };
    for (offsets, 0..) |offset, index| {
        const neighbor = blockAt(center_x, center_z, blocks, position.x + offset.x, position.y + offset.y, position.z + offset.z) orelse return false;
        const air = isAir(neighbor.*);
        if ((air and index != 1) or (!air and index == 1)) return false;
    }
    return true;
}

fn applySpring(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, spring: Spring) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, spring.index, 7));
    for (0..spring.count) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const y = spring.minimum_y + source.nextBoundedI32(spring.maximum_y - spring.minimum_y + 1);
        const biome = generator.biomeAtBlock(x, y, z);
        if (!biomeEnabled(biome, spring.biomes)) continue;
        placeSpring(chunk_x, chunk_z, blocks, .{ .x = x, .y = y, .z = z }, spring);
    }
}

fn applyOre(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, ore: Ore) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, ore.index, 7));
    for (0..ore.count) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const origin = Position{ .x = x, .y = sampleHeight(&source, ore.height), .z = z };
        const biome = generator.biomeAtBlock(origin.x, origin.y, origin.z);
        if (!biomeEnabled(biome, ore.biomes)) continue;
        if (ore.scattered)
            placeScattered(&source, chunk_x, chunk_z, blocks, origin, ore)
        else
            placeVein(&source, chunk_x, chunk_z, blocks, origin, ore);
    }
}

fn placeSpring(center_x: i32, center_z: i32, blocks: anytype, origin: Position, spring: Spring) void {
    const above = blockAt(center_x, center_z, blocks, origin.x, origin.y + 1, origin.z) orelse return;
    if (!springTarget(above.*, spring.broad_target)) return;
    const below = blockAt(center_x, center_z, blocks, origin.x, origin.y - 1, origin.z) orelse return;
    if (spring.requires_below and !springTarget(below.*, spring.broad_target)) return;
    const target = blockAt(center_x, center_z, blocks, origin.x, origin.y, origin.z) orelse return;
    if (!isAir(target.*) and !springTarget(target.*, spring.broad_target)) return;
    const neighbors = [_]Position{
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = 0, .y = -1, .z = 0 },
    };
    var rocks: u8 = 0;
    var holes: u8 = 0;
    for (neighbors) |offset| {
        const state = blockAt(center_x, center_z, blocks, origin.x + offset.x, origin.y + offset.y, origin.z + offset.z) orelse return;
        rocks += @intFromBool(springTarget(state.*, spring.broad_target));
        holes += @intFromBool(isAir(state.*));
    }
    if (rocks == spring.rock_count and holes == spring.hole_count)
        target.* = .{ .feature = minecraft.State.parse("minecraft:lava[level=0]").? };
}

fn springTarget(block: anytype, broad: bool) bool {
    const kind = blockKind(block) orelse return false;
    if (kind == .netherrack) return true;
    return broad and (kind == .soul_sand or kind == .gravel or kind == .magma_block or kind == .blackstone);
}

fn applyGlowstone(generator: anytype, population_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype, index: u8) void {
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, index, 7));
    const count: usize = if (index == 6)
        @intCast(source.nextBoundedI32(source.nextBoundedI32(10) + 1))
    else
        10;
    for (0..count) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const y = if (index == 6) 4 + source.nextBoundedI32(120) else source.nextBoundedI32(generation_height);
        const biome = generator.biomeAtBlock(x, y, z);
        if (!biomeEnabled(biome, all_nether)) continue;
        placeGlowstone(&source, chunk_x, chunk_z, blocks, .{ .x = x, .y = y, .z = z });
    }
}

fn placeGlowstone(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position) void {
    const target = blockAt(center_x, center_z, blocks, origin.x, origin.y, origin.z) orelse return;
    if (!isAir(target.*)) return;
    const above = blockAt(center_x, center_z, blocks, origin.x, origin.y + 1, origin.z) orelse return;
    const support = blockKind(above.*) orelse return;
    if (support != .netherrack and support != .basalt and support != .blackstone) return;
    const glowstone = minecraft.defaultState(.glowstone);
    target.* = .{ .feature = glowstone };
    for (0..1_500) |_| {
        const candidate = Position{
            .x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8),
            .y = origin.y - source.nextBoundedI32(12),
            .z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8),
        };
        const state = blockAt(center_x, center_z, blocks, candidate.x, candidate.y, candidate.z) orelse continue;
        if (!isAir(state.*)) continue;
        var adjacent: u8 = 0;
        const offsets = [_]Position{
            .{ .x = 0, .y = -1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 },
            .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
            .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
        };
        for (offsets) |offset| {
            const neighbor = blockAt(center_x, center_z, blocks, candidate.x + offset.x, candidate.y + offset.y, candidate.z + offset.z) orelse continue;
            adjacent += @intFromBool(blockKind(neighbor.*) == .glowstone);
            if (adjacent > 1) break;
        }
        if (adjacent == 1) state.* = .{ .feature = glowstone };
    }
}

fn biomeEnabled(biome: Biome, mask: u8) bool {
    if (@intFromEnum(biome) > @intFromEnum(Biome.warped_forest)) return false;
    return mask & (@as(u8, 1) << @as(u3, @intCast(@intFromEnum(biome)))) != 0;
}

fn sampleHeight(source: *random.ChunkRandom, provider: Height) i32 {
    return switch (provider) {
        .uniform => |range| range.minimum + source.nextBoundedI32(range.maximum - range.minimum + 1),
        .trapezoid => |range| blk: {
            const span = range.maximum - range.minimum;
            const lower = @divTrunc(span, 2);
            break :blk range.minimum + source.nextBoundedI32(span - lower + 1) +
                source.nextBoundedI32(lower + 1);
        },
    };
}

fn placeScattered(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, ore: Ore) void {
    const attempts: usize = @intCast(source.nextBoundedI32(ore.size + 1));
    for (0..attempts) |attempt| {
        const radius: i32 = @intCast(@min(attempt, 7));
        const candidate = Position{
            .x = origin.x + roundedSpread(source, radius),
            .y = origin.y + roundedSpread(source, radius),
            .z = origin.z + roundedSpread(source, radius),
        };
        replaceOre(source, center_x, center_z, blocks, candidate, ore);
    }
}

fn roundedSpread(source: *random.ChunkRandom, radius: i32) i32 {
    const difference = (source.nextF32() - source.nextF32()) * @as(f32, @floatFromInt(radius));
    return @intFromFloat(@floor(difference + 0.5));
}

const Bounds = struct {
    start: [3]f64,
    end: [3]f64,
    box: Position,
    horizontal: usize,
    vertical: usize,
};

fn placeVein(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, origin: Position, ore: Ore) void {
    const bounds = oreBounds(source, origin, ore.size);
    if (!hasSolidAtOrAbove(center_x, center_z, blocks, bounds)) return;
    var spheres: [64][4]f64 = undefined;
    std.debug.assert(ore.size <= spheres.len);
    prepareSpheres(source, ore.size, bounds, &spheres);
    pruneSpheres(spheres[0..ore.size]);
    placeSpheres(source, center_x, center_z, blocks, ore, bounds, spheres[0..ore.size]);
}

fn oreBounds(source: *random.ChunkRandom, origin: Position, size: u8) Bounds {
    const angle = source.nextF32() * @as(f32, std.math.pi);
    const extent = @as(f32, @floatFromInt(size)) / 8.0;
    const adjustment: i32 = @intFromFloat(@ceil(
        (@as(f32, @floatFromInt(size)) / 16.0 * 2.0 + 1.0) / 2.0,
    ));
    const radius: i32 = @intFromFloat(@ceil(extent));
    return .{
        .start = .{
            @as(f64, @floatFromInt(origin.x)) + @sin(@as(f64, angle)) * extent,
            @floatFromInt(origin.y + source.nextBoundedI32(3) - 2),
            @as(f64, @floatFromInt(origin.z)) + @cos(@as(f64, angle)) * extent,
        },
        .end = .{
            @as(f64, @floatFromInt(origin.x)) - @sin(@as(f64, angle)) * extent,
            @floatFromInt(origin.y + source.nextBoundedI32(3) - 2),
            @as(f64, @floatFromInt(origin.z)) - @cos(@as(f64, angle)) * extent,
        },
        .box = .{ .x = origin.x - radius - adjustment, .y = origin.y - 2 - adjustment, .z = origin.z - radius - adjustment },
        .horizontal = @intCast(2 * (radius + adjustment)),
        .vertical = @intCast(2 * (2 + adjustment)),
    };
}

fn hasSolidAtOrAbove(center_x: i32, center_z: i32, blocks: anytype, bounds: Bounds) bool {
    var z = bounds.box.z;
    while (z <= bounds.box.z + @as(i32, @intCast(bounds.horizontal))) : (z += 1) {
        var x = bounds.box.x;
        while (x <= bounds.box.x + @as(i32, @intCast(bounds.horizontal))) : (x += 1) {
            var y: i32 = generation_height - 1;
            while (y >= bounds.box.y) : (y -= 1) {
                const block = blockAt(center_x, center_z, blocks, x, y, z) orelse break;
                if (isSolid(block.*)) return true;
            }
        }
    }
    return false;
}

fn prepareSpheres(source: *random.ChunkRandom, size: u8, bounds: Bounds, spheres: *[64][4]f64) void {
    for (0..size) |index| {
        const progress = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(size));
        const random_radius = source.nextF64() * @as(f64, @floatFromInt(size)) / 16.0;
        spheres[index] = .{
            lerp(progress, bounds.start[0], bounds.end[0]),
            lerp(progress, bounds.start[1], bounds.end[1]),
            lerp(progress, bounds.start[2], bounds.end[2]),
            (@as(f64, minecraftSin(progress * @as(f32, std.math.pi)) + 1.0) * random_radius + 1.0) / 2.0,
        };
    }
}

fn pruneSpheres(spheres: [][4]f64) void {
    for (0..spheres.len - 1) |left| {
        if (spheres[left][3] <= 0) continue;
        for (left + 1..spheres.len) |right| {
            if (spheres[right][3] <= 0) continue;
            const dx = spheres[left][0] - spheres[right][0];
            const dy = spheres[left][1] - spheres[right][1];
            const dz = spheres[left][2] - spheres[right][2];
            const dr = spheres[left][3] - spheres[right][3];
            if (dr * dr <= dx * dx + dy * dy + dz * dz) continue;
            if (dr > 0) spheres[right][3] = -1 else spheres[left][3] = -1;
        }
    }
}

fn placeSpheres(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, ore: Ore, bounds: Bounds, spheres: []const [4]f64) void {
    var visited_storage: [26 * 14 * 26]bool = undefined;
    const visited_length = bounds.horizontal * bounds.vertical * bounds.horizontal;
    std.debug.assert(visited_length <= visited_storage.len);
    const visited = visited_storage[0..visited_length];
    @memset(visited, false);
    for (spheres) |sphere| placeSphere(source, center_x, center_z, blocks, ore, bounds, sphere, visited);
}

fn placeSphere(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, ore: Ore, bounds: Bounds, sphere: [4]f64, visited: []bool) void {
    const radius = sphere[3];
    if (radius < 0) return;
    const minimum_x = @max(@as(i32, @intFromFloat(@floor(sphere[0] - radius))), bounds.box.x);
    const minimum_y = @max(@as(i32, @intFromFloat(@floor(sphere[1] - radius))), bounds.box.y);
    const minimum_z = @max(@as(i32, @intFromFloat(@floor(sphere[2] - radius))), bounds.box.z);
    const maximum_x = @max(@as(i32, @intFromFloat(@floor(sphere[0] + radius))), minimum_x);
    const maximum_y = @max(@as(i32, @intFromFloat(@floor(sphere[1] + radius))), minimum_y);
    const maximum_z = @max(@as(i32, @intFromFloat(@floor(sphere[2] + radius))), minimum_z);
    var x = minimum_x;
    while (x <= maximum_x) : (x += 1) {
        const dx = (@as(f64, @floatFromInt(x)) + 0.5 - sphere[0]) / radius;
        if (dx * dx >= 1) continue;
        var y = minimum_y;
        while (y <= maximum_y) : (y += 1) {
            const dy = (@as(f64, @floatFromInt(y)) + 0.5 - sphere[1]) / radius;
            if (dx * dx + dy * dy >= 1) continue;
            var z = minimum_z;
            while (z <= maximum_z) : (z += 1) {
                const dz = (@as(f64, @floatFromInt(z)) + 0.5 - sphere[2]) / radius;
                if (dx * dx + dy * dy + dz * dz >= 1 or y < 0 or y >= generation_height) continue;
                const visited_index = @as(usize, @intCast(x - bounds.box.x)) +
                    @as(usize, @intCast(y - bounds.box.y)) * bounds.horizontal +
                    @as(usize, @intCast(z - bounds.box.z)) * bounds.horizontal * bounds.vertical;
                if (visited[visited_index]) continue;
                visited[visited_index] = true;
                replaceOre(source, center_x, center_z, blocks, .{ .x = x, .y = y, .z = z }, ore);
            }
        }
    }
}

fn replaceOre(source: *random.ChunkRandom, center_x: i32, center_z: i32, blocks: anytype, position: Position, ore: Ore) void {
    const state = blockAt(center_x, center_z, blocks, position.x, position.y, position.z) orelse return;
    if (!matchesTarget(state.*, ore.target)) return;
    const discard = if (ore.discard <= 0)
        false
    else if (ore.discard >= 1)
        true
    else
        source.nextF32() < ore.discard;
    if (discard and touchesAir(center_x, center_z, blocks, position)) return;
    state.* = .{ .feature = ore.state };
}

fn touchesAir(center_x: i32, center_z: i32, blocks: anytype, position: Position) bool {
    const offsets = [_]Position{
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = -1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
    };
    for (offsets) |offset| {
        const neighbor = blockAt(center_x, center_z, blocks, position.x + offset.x, position.y + offset.y, position.z + offset.z) orelse continue;
        if (isAir(neighbor.*)) return true;
    }
    return false;
}

fn matchesTarget(block: anytype, target: Target) bool {
    const kind = blockKind(block) orelse return false;
    return switch (target) {
        .netherrack => kind == .netherrack,
        .base_stone_nether => kind == .netherrack or kind == .basalt or kind == .blackstone,
    };
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

fn isSolid(block: anytype) bool {
    return switch (block) {
        .solid, .surface => true,
        .feature => |state| state.block() != .air and state.block() != .cave_air and state.block() != .lava,
        .air, .cave_air, .fluid => false,
    };
}

fn isAir(block: anytype) bool {
    return switch (block) {
        .air, .cave_air => true,
        .feature => |state| state.block() == .air or state.block() == .cave_air,
        .solid, .surface, .fluid => false,
    };
}

fn isPlainAir(block: anytype) bool {
    return switch (block) {
        .air => true,
        .feature => |state| state.block() == .air,
        .solid, .cave_air, .fluid, .surface => false,
    };
}

fn blockAt(center_x: i32, center_z: i32, blocks: anytype, x: i32, y: i32, z: i32) ?*@TypeOf(blocks[0]) {
    if (y < 0 or y >= world_height) return null;
    const offset_x = @divFloor(x, width) - center_x;
    const offset_z = @divFloor(z, width) - center_z;
    if (offset_x < -1 or offset_x > 1 or offset_z < -1 or offset_z > 1) return null;
    const chunk_index = @as(usize, @intCast(offset_z + 1)) * region_side + @as(usize, @intCast(offset_x + 1));
    const local = @as(usize, @intCast(y)) * width * width +
        @as(usize, @intCast(@mod(z, width))) * width + @as(usize, @intCast(@mod(x, width)));
    return &blocks[chunk_index * chunk_block_count + local];
}

fn minecraftSin(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(@as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536)));
}

fn lerp(delta: f32, start: f64, end: f64) f64 {
    return start + @as(f64, delta) * (end - start);
}
