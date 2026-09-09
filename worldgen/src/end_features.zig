const std = @import("std");
const minecraft = @import("minecraft_registry");
const legacy = @import("legacy_noise.zig");
const random = @import("random.zig");
const end_structures = @import("end_structures.zig");

const width = 16;
const world_height = 256;
pub const enabled = true;
pub const region_side = 3;
pub const Scratch = end_structures.Scratch;

pub fn apply(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, scratch: *Scratch, blocks: anytype) void {
    applyStructures(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
    applyDecorations(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
}

pub fn applyStructures(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, scratch: *Scratch, blocks: anytype) void {
    const chunk_block_count = width * width * world_height;
    std.debug.assert(blocks.len == chunk_block_count or blocks.len == region_side * region_side * chunk_block_count);
    end_structures.apply(generator, world_seed, chunk_x, chunk_z, scratch, blocks);
}

pub fn applyDecorations(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, _: *Scratch, blocks: anytype) void {
    const chunk_block_count = width * width * world_height;
    std.debug.assert(
        blocks.len == chunk_block_count or
            blocks.len == region_side * region_side * chunk_block_count,
    );
    applySmallIslands(generator, world_seed, chunk_x, chunk_z, blocks);
    applyGateway(generator, world_seed, chunk_x, chunk_z, blocks);
    applySpikes(world_seed, chunk_x, chunk_z, blocks);
    applyChorus(generator, world_seed, chunk_x, chunk_z, blocks);
    applyPlatform(chunk_x, chunk_z, blocks);
}

fn applyGateway(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    const population_seed = random.ChunkRandom.populationSeed(world_seed, chunk_x * width, chunk_z * width);
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 4));
    if (source.nextF32() >= 1.0 / 700.0) return;
    const x = chunk_x * width + source.nextBoundedI32(width);
    const z = chunk_z * width + source.nextBoundedI32(width);
    const y = motionBlockingHeight(blocks, @intCast(@mod(x, width)), @intCast(@mod(z, width))) +
        3 + source.nextBoundedI32(7);
    if (generator.biomeAtBlock(x, y, z) != .end_highlands) return;
    placeGateway(chunk_x, chunk_z, blocks, x, y, z);
}

fn motionBlockingHeight(blocks: anytype, local_x: usize, local_z: usize) i32 {
    var y: usize = world_height;
    while (y > 0) {
        y -= 1;
        switch (blocks[regionIndex(blocks.len, 0, 0, blockIndex(local_x, y, local_z)).?]) {
            .air, .cave_air, .fluid => {},
            .solid, .surface, .feature => return @as(i32, @intCast(y)) + 1,
        }
    }
    return 0;
}

fn placeGateway(chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) void {
    const air = minecraft.defaultState(.air);
    const bedrock = minecraft.defaultState(.bedrock);
    const gateway = minecraft.defaultState(.end_gateway);
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dy: i32 = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const state = if (dx == 0 and dy == 0 and dz == 0)
                    gateway
                else if (dy == 0)
                    air
                else if (@abs(dy) == 2 and (dx == 0 or dz == 0))
                    bedrock
                else
                    air;
                setBlock(chunk_x, chunk_z, blocks, x + dx, y + dy, z + dz, state);
            }
        }
    }
}

fn applyChorus(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    const population_seed = random.ChunkRandom.populationSeed(world_seed, chunk_x * width, chunk_z * width);
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 9));
    const count: usize = @intCast(source.nextBoundedI32(5));
    for (0..count) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const y = motionBlockingHeight(blocks, @intCast(@mod(x, width)), @intCast(@mod(z, width)));
        if (generator.biomeAtBlock(x, y, z) != .end_highlands) continue;
        if (!isAir(chunk_x, chunk_z, blocks, x, y, z) or !isEndStone(chunk_x, chunk_z, blocks, x, y - 1, z)) continue;
        setChorusPlant(chunk_x, chunk_z, blocks, x, y, z);
        growChorus(chunk_x, chunk_z, blocks, &source, .{ .x = x, .y = y, .z = z });
    }
}

const Position = struct { x: i32, y: i32, z: i32 };
const ChorusFrame = struct {
    position: Position,
    depth: u8,
    height: u8 = 0,
    attempts: u8 = 0,
    attempt: u8 = 0,
    branched: bool = false,
    initialized: bool = false,
};
const Direction = enum(u2) { north, east, south, west };

fn growChorus(chunk_x: i32, chunk_z: i32, blocks: anytype, source: *random.ChunkRandom, origin: Position) void {
    var stack: [5]ChorusFrame = undefined;
    var count: usize = 1;
    stack[0] = .{ .position = origin, .depth = 0 };
    while (count > 0) {
        const frame = &stack[count - 1];
        if (!frame.initialized) {
            frame.height = @intCast(source.nextBoundedI32(4) + 1 + @intFromBool(frame.depth == 0));
            if (!placeChorusStem(chunk_x, chunk_z, blocks, frame.position, frame.height)) {
                count -= 1;
                continue;
            }
            frame.attempts = if (frame.depth < 4)
                @intCast(source.nextBoundedI32(4) + @intFromBool(frame.depth == 0))
            else
                0;
            frame.initialized = true;
        }
        if (frame.attempt < frame.attempts) {
            frame.attempt += 1;
            const direction: Direction = @enumFromInt(source.nextBoundedI32(4));
            const branch = chorusBranch(frame.position, frame.height, direction);
            if (!validChorusBranch(chunk_x, chunk_z, blocks, origin, branch, direction)) continue;
            frame.branched = true;
            setChorusPlant(chunk_x, chunk_z, blocks, branch.x, branch.y, branch.z);
            const behind = move(branch, opposite(direction));
            setChorusPlant(chunk_x, chunk_z, blocks, behind.x, behind.y, behind.z);
            std.debug.assert(count < stack.len);
            stack[count] = .{ .position = branch, .depth = frame.depth + 1 };
            count += 1;
            continue;
        }
        if (!frame.branched) {
            const flower = .{ .x = frame.position.x, .y = frame.position.y + frame.height, .z = frame.position.z };
            setBlock(chunk_x, chunk_z, blocks, flower.x, flower.y, flower.z, chorusFlower());
        }
        count -= 1;
    }
}

fn placeChorusStem(chunk_x: i32, chunk_z: i32, blocks: anytype, position: Position, stem_height: u8) bool {
    for (0..stem_height) |offset| {
        const y = position.y + @as(i32, @intCast(offset)) + 1;
        if (!chorusClear(chunk_x, chunk_z, blocks, position.x, y, position.z, null)) return false;
        setChorusPlant(chunk_x, chunk_z, blocks, position.x, y, position.z);
        setChorusPlant(chunk_x, chunk_z, blocks, position.x, y - 1, position.z);
    }
    return true;
}

fn validChorusBranch(
    chunk_x: i32,
    chunk_z: i32,
    blocks: anytype,
    origin: Position,
    branch: Position,
    direction: Direction,
) bool {
    if (@abs(branch.x - origin.x) >= 8 or @abs(branch.z - origin.z) >= 8) return false;
    if (!isAir(chunk_x, chunk_z, blocks, branch.x, branch.y, branch.z)) return false;
    if (!isAir(chunk_x, chunk_z, blocks, branch.x, branch.y - 1, branch.z)) return false;
    return chorusClear(chunk_x, chunk_z, blocks, branch.x, branch.y, branch.z, opposite(direction));
}

fn chorusClear(
    chunk_x: i32,
    chunk_z: i32,
    blocks: anytype,
    x: i32,
    y: i32,
    z: i32,
    excluded: ?Direction,
) bool {
    for (std.enums.values(Direction)) |direction| {
        if (excluded != null and direction == excluded.?) continue;
        const adjacent = move(.{ .x = x, .y = y, .z = z }, direction);
        if (!isAir(chunk_x, chunk_z, blocks, adjacent.x, adjacent.y, adjacent.z)) return false;
    }
    return true;
}

fn chorusBranch(position: Position, stem_height: u8, direction: Direction) Position {
    return move(.{
        .x = position.x,
        .y = position.y + @as(i32, stem_height),
        .z = position.z,
    }, direction);
}

fn move(position: Position, direction: Direction) Position {
    return switch (direction) {
        .north => .{ .x = position.x, .y = position.y, .z = position.z - 1 },
        .east => .{ .x = position.x + 1, .y = position.y, .z = position.z },
        .south => .{ .x = position.x, .y = position.y, .z = position.z + 1 },
        .west => .{ .x = position.x - 1, .y = position.y, .z = position.z },
    };
}

fn opposite(direction: Direction) Direction {
    return switch (direction) {
        .north => .south,
        .east => .west,
        .south => .north,
        .west => .east,
    };
}

fn applySmallIslands(generator: anytype, world_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    applySmallIslandsFrom(generator, world_seed, chunk_x, chunk_z, chunk_x, chunk_z, blocks);
}

fn applySmallIslandsFrom(
    generator: anytype,
    world_seed: u64,
    source_x: i32,
    source_z: i32,
    target_x: i32,
    target_z: i32,
    blocks: anytype,
) void {
    const population_seed = random.ChunkRandom.populationSeed(world_seed, source_x * width, source_z * width);
    var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 0));
    if (source.nextF32() >= 1.0 / 14.0) return;
    const count: usize = if (source.nextBoundedI32(4) < 3) 1 else 2;
    for (0..count) |_| {
        const x = source_x * width + source.nextBoundedI32(width);
        const z = source_z * width + source.nextBoundedI32(width);
        const y = 55 + source.nextBoundedI32(16);
        const biome = generator.biomeAtBlock(x, y, z);
        if (biome != .small_end_islands) continue;
        applyIsland(&source, target_x, target_z, blocks, x, y, z);
    }
}

fn applyIsland(source: *random.ChunkRandom, chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) void {
    var radius = @as(f32, @floatFromInt(source.nextBoundedI32(3))) + 4.0;
    var layer_y = y;
    while (radius > 0.5) : (layer_y -= 1) {
        const minimum: i32 = @intFromFloat(@floor(-radius));
        const maximum: i32 = @intFromFloat(@ceil(radius));
        var dz = minimum;
        while (dz <= maximum) : (dz += 1) {
            var dx = minimum;
            while (dx <= maximum) : (dx += 1) {
                const distance = @as(f32, @floatFromInt(dx * dx + dz * dz));
                if (distance <= (radius + 1.0) * (radius + 1.0))
                    setBlock(chunk_x, chunk_z, blocks, x + dx, layer_y, z + dz, minecraft.defaultState(.end_stone));
            }
        }
        radius -= @as(f32, @floatFromInt(source.nextBoundedI32(2))) + 0.5;
    }
}

fn applySpikes(world_seed: u64, chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    var seed_source = legacy.Random.init(@bitCast(world_seed));
    const spike_seed: i64 = @intCast(@as(u64, @bitCast(seed_source.nextI64())) & 65_535);
    var shuffle = legacy.Random.init(spike_seed);
    var order = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var remaining: usize = order.len;
    while (remaining > 1) {
        const selected: usize = @intCast(shuffle.nextBounded(@intCast(remaining)));
        remaining -= 1;
        std.mem.swap(u8, &order[remaining], &order[selected]);
    }
    for (0..10) |index| {
        const angle = 2.0 * (-std.math.pi + (std.math.pi / 10.0) * @as(f64, @floatFromInt(index)));
        const value = order[index];
        applySpike(chunk_x, chunk_z, blocks, .{
            .x = @intFromFloat(@floor(42.0 * @cos(angle))),
            .z = @intFromFloat(@floor(42.0 * @sin(angle))),
            .radius = 2 + value / 3,
            .height = 76 + @as(i32, value) * 3,
            .guarded = value == 1 or value == 2,
        });
    }
}

const Spike = struct {
    x: i32,
    z: i32,
    radius: u8,
    height: i32,
    guarded: bool,
};

fn applySpike(chunk_x: i32, chunk_z: i32, blocks: anytype, spike: Spike) void {
    const radius: i32 = spike.radius;
    if (@divFloor(spike.x, width) != chunk_x or @divFloor(spike.z, width) != chunk_z) return;
    const obsidian = minecraft.defaultState(.obsidian);
    const air = minecraft.defaultState(.air);
    var z = spike.z - radius;
    while (z <= spike.z + radius) : (z += 1) {
        var x = spike.x - radius;
        while (x <= spike.x + radius) : (x += 1) {
            const dx = x - spike.x;
            const dz = z - spike.z;
            const inside = dx * dx + dz * dz <= radius * radius + 1;
            var y: i32 = 0;
            while (y <= spike.height + 10) : (y += 1) {
                if (inside and y < spike.height)
                    setBlock(chunk_x, chunk_z, blocks, x, y, z, obsidian)
                else if (y > 65)
                    setBlock(chunk_x, chunk_z, blocks, x, y, z, air);
            }
        }
    }
    if (spike.guarded) applyCage(chunk_x, chunk_z, blocks, spike);
    setBlock(chunk_x, chunk_z, blocks, spike.x, spike.height, spike.z, minecraft.defaultState(.bedrock));
    setBlock(chunk_x, chunk_z, blocks, spike.x, spike.height + 1, spike.z, minecraft.defaultState(.fire));
}

fn applyCage(chunk_x: i32, chunk_z: i32, blocks: anytype, spike: Spike) void {
    var dz: i32 = -2;
    while (dz <= 2) : (dz += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            var dy: i32 = 0;
            while (dy <= 3) : (dy += 1) {
                const edge_x = @abs(dx) == 2;
                const edge_z = @abs(dz) == 2;
                const roof = dy == 3;
                if (!edge_x and !edge_z and !roof) continue;
                setBlock(
                    chunk_x,
                    chunk_z,
                    blocks,
                    spike.x + dx,
                    spike.height + dy,
                    spike.z + dz,
                    ironBars(edge_x and dz != -2, edge_x and dz != 2, edge_z and dx != -2, edge_z and dx != 2),
                );
            }
        }
    }
}

fn ironBars(north: bool, south: bool, west: bool, east: bool) minecraft.State {
    var buffer: [128]u8 = undefined;
    const name = std.fmt.bufPrint(
        &buffer,
        "minecraft:iron_bars[east={s},north={s},south={s},waterlogged=false,west={s}]",
        .{ booleanName(east), booleanName(north), booleanName(south), booleanName(west) },
    ) catch unreachable;
    return minecraft.State.parse(name).?;
}

fn booleanName(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn setChorusPlant(chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) void {
    const north = isChorus(chunk_x, chunk_z, blocks, x, y, z - 1);
    const east = isChorus(chunk_x, chunk_z, blocks, x + 1, y, z);
    const south = isChorus(chunk_x, chunk_z, blocks, x, y, z + 1);
    const west = isChorus(chunk_x, chunk_z, blocks, x - 1, y, z);
    const up = isChorus(chunk_x, chunk_z, blocks, x, y + 1, z);
    const down = isChorus(chunk_x, chunk_z, blocks, x, y - 1, z) or
        isEndStone(chunk_x, chunk_z, blocks, x, y - 1, z);
    var buffer: [192]u8 = undefined;
    const name = std.fmt.bufPrint(
        &buffer,
        "minecraft:chorus_plant[down={s},east={s},north={s},south={s},up={s},west={s}]",
        .{ booleanName(down), booleanName(east), booleanName(north), booleanName(south), booleanName(up), booleanName(west) },
    ) catch unreachable;
    setBlock(chunk_x, chunk_z, blocks, x, y, z, minecraft.State.parse(name).?);
}

fn chorusFlower() minecraft.State {
    return minecraft.State.parse("minecraft:chorus_flower[age=5]").?;
}

fn isAir(chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) bool {
    if (y < 0 or y >= world_height) return false;
    const index = regionBlockIndex(blocks.len, chunk_x, chunk_z, x, y, z) orelse return true;
    return switch (blocks[index]) {
        .air, .cave_air, .fluid => true,
        .solid, .surface, .feature => false,
    };
}

fn isEndStone(chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) bool {
    if (y < 0 or y >= world_height) return false;
    const index = regionBlockIndex(blocks.len, chunk_x, chunk_z, x, y, z) orelse return false;
    return switch (blocks[index]) {
        .solid => true,
        .feature => |state| state.block() == .end_stone,
        .surface => true,
        .air, .cave_air, .fluid => false,
    };
}

fn isChorus(chunk_x: i32, chunk_z: i32, blocks: anytype, x: i32, y: i32, z: i32) bool {
    if (y < 0 or y >= world_height) return false;
    const index = regionBlockIndex(blocks.len, chunk_x, chunk_z, x, y, z) orelse return false;
    return switch (blocks[index]) {
        .feature => |state| state.block() == .chorus_plant or state.block() == .chorus_flower,
        else => false,
    };
}

fn applyPlatform(chunk_x: i32, chunk_z: i32, blocks: anytype) void {
    const obsidian = minecraft.defaultState(.obsidian);
    const air = minecraft.defaultState(.air);
    var z: i32 = -2;
    while (z <= 2) : (z += 1) {
        var x: i32 = 98;
        while (x <= 102) : (x += 1) {
            setBlock(chunk_x, chunk_z, blocks, x, 48, z, obsidian);
            var y: i32 = 49;
            while (y <= 51) : (y += 1)
                setBlock(chunk_x, chunk_z, blocks, x, y, z, air);
        }
    }
}

fn setBlock(
    chunk_x: i32,
    chunk_z: i32,
    blocks: anytype,
    x: i32,
    y: i32,
    z: i32,
    state: minecraft.State,
) void {
    if (y < 0 or y >= world_height) return;
    const index = regionBlockIndex(blocks.len, chunk_x, chunk_z, x, y, z) orelse return;
    blocks[index] = .{ .feature = state };
}

fn regionBlockIndex(length: usize, center_x: i32, center_z: i32, x: i32, y: i32, z: i32) ?usize {
    const offset_x = @divFloor(x, width) - center_x;
    const offset_z = @divFloor(z, width) - center_z;
    const local = blockIndex(@intCast(@mod(x, width)), @intCast(y), @intCast(@mod(z, width)));
    return regionIndex(length, offset_x, offset_z, local);
}

fn regionIndex(length: usize, offset_x: i32, offset_z: i32, local: usize) ?usize {
    if (length == width * width * world_height)
        return if (offset_x == 0 and offset_z == 0) local else null;
    std.debug.assert(length == region_side * region_side * width * width * world_height);
    if (offset_x < -1 or offset_x > 1 or offset_z < -1 or offset_z > 1) return null;
    const chunk_index = @as(usize, @intCast(offset_z + 1)) * region_side + @as(usize, @intCast(offset_x + 1));
    return chunk_index * width * width * world_height + local;
}

fn blockIndex(local_x: usize, y: usize, local_z: usize) usize {
    std.debug.assert(local_x < width and y < world_height and local_z < width);
    return y * width * width + local_z * width + local_x;
}

test "End spike permutation and platform are deterministic" {
    const Block = @import("base_dimension.zig").Block;
    var blocks = [_]Block{.air} ** (width * width * world_height);
    applySpikes(0, 2, 0, &blocks);
    applyPlatform(2, 0, &blocks);
    var obsidian: usize = 0;
    var bedrock: usize = 0;
    var fire: usize = 0;
    for (blocks) |block| switch (block) {
        .feature => |state| {
            obsidian += @intFromBool(state.block() == .obsidian);
            bedrock += @intFromBool(state.block() == .bedrock);
            fire += @intFromBool(state.block() == .fire);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3_102), obsidian);
    try std.testing.expectEqual(@as(usize, 1), bedrock);
    try std.testing.expectEqual(@as(usize, 1), fire);
}

test "End gateway rarity stream is deterministic" {
    var found: ?struct { x: i32, z: i32 } = null;
    var chunk_z: i32 = -100;
    while (chunk_z <= 100 and found == null) : (chunk_z += 1) {
        var chunk_x: i32 = -100;
        while (chunk_x <= 100) : (chunk_x += 1) {
            const population_seed = random.ChunkRandom.populationSeed(0, chunk_x * width, chunk_z * width);
            var source = random.ChunkRandom.init(random.decoratorSeed(population_seed, 0, 4));
            if (source.nextF32() < 1.0 / 700.0) {
                found = .{ .x = chunk_x, .z = chunk_z };
                break;
            }
        }
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(i32, -3), found.?.x);
    try std.testing.expectEqual(@as(i32, -99), found.?.z);
}
