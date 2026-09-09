const std = @import("std");
const minecraft = @import("minecraft_registry");
const nbt = @import("nbt");
const base = @import("base_dimension.zig");
const legacy = @import("legacy_noise.zig");
const random = @import("random.zig");
const structures = @import("structures.zig");

const width = 16;
const terrain_generation_height = 128;
const world_height = 256;
const chunk_block_count = width * width * world_height;
const portal_structure_index = 14;
const portal_structure_step = 4;
const common_templates = [_][]const u8{
    "minecraft:ruined_portal/portal_1", "minecraft:ruined_portal/portal_2",
    "minecraft:ruined_portal/portal_3", "minecraft:ruined_portal/portal_4",
    "minecraft:ruined_portal/portal_5", "minecraft:ruined_portal/portal_6",
    "minecraft:ruined_portal/portal_7", "minecraft:ruined_portal/portal_8",
    "minecraft:ruined_portal/portal_9", "minecraft:ruined_portal/portal_10",
};
const rare_templates = [_][]const u8{
    "minecraft:ruined_portal/giant_portal_1",
    "minecraft:ruined_portal/giant_portal_2",
    "minecraft:ruined_portal/giant_portal_3",
};

pub const Position = structures.Position;
pub const Box = structures.Box;

pub const Plan = struct {
    template: structures.Template,
    origin: Position,
    pivot: Position,
    rotation: structures.Rotation,
    mirror: structures.Mirror,
    box: Box,
    air_pocket: bool,
};

pub fn apply(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    nodes: []nbt.Node,
    stack: []nbt.Frame,
    palette: []minecraft.State,
    column: []base.Block,
    blocks: []base.Block,
) void {
    std.debug.assert(blocks.len == 9 * chunk_block_count);
    var source_z = chunk_z - 2;
    while (source_z <= chunk_z + 2) : (source_z += 1) {
        var source_x = chunk_x - 2;
        while (source_x <= chunk_x + 2) : (source_x += 1) {
            const source = structures.ChunkPos{ .x = source_x, .z = source_z };
            const portal = plan(generator, world_seed, source, column) orelse continue;
            const center = centerOf(portal.box);
            if (@divFloor(center.x, width) != chunk_x or @divFloor(center.z, width) != chunk_z) continue;
            var decoration = random.ChunkRandom.init(random.decoratorSeed(
                random.ChunkRandom.populationSeed(world_seed, chunk_x * width, chunk_z * width),
                portal_structure_index,
                portal_structure_step,
            ));
            const lootable_entities = placeTemplate(chunk_x, chunk_z, blocks, nodes, stack, palette, portal);
            updateWallStates(chunk_x, chunk_z, blocks, portal.box);
            for (0..lootable_entities) |_| _ = decoration.nextI64();
            placeNetherrackBase(&decoration, chunk_x, chunk_z, blocks, portal);
            updateNetherracksInBounds(&decoration, chunk_x, chunk_z, blocks, portal.box);
        }
    }
}

pub fn plan(generator: anytype, world_seed: u64, start: structures.ChunkPos, column: []base.Block) ?Plan {
    if (!structures.ruined_portals.isStart(@bitCast(world_seed), start)) return null;
    var source = legacy.Random.init(0);
    source.setCarverSeed(@bitCast(world_seed), start.x, start.z);
    const air_pocket = source.nextF32() < 0.5;
    const names = if (source.nextF32() < 0.05) rare_templates[0..] else common_templates[0..];
    const template = structures.vanilla.find(names[source.nextBounded(@intCast(names.len))]) orelse unreachable;
    const rotation: structures.Rotation = @enumFromInt(source.nextBounded(4));
    const mirror: structures.Mirror = if (source.nextF32() < 0.5) .none else .front_back;
    const pivot = Position{ .x = @divFloor(template.size[0], 2), .y = 0, .z = @divFloor(template.size[2], 2) };
    var origin = Position{ .x = start.x * width, .y = 0, .z = start.z * width };
    const flat_box = transformedBox(template.size, origin, pivot, mirror, rotation);
    const center = centerOf(flat_box);
    generator.generateColumnWithoutStructureAdaptation(center.x, center.z, column) catch unreachable;
    const terrain_height = highestWorldSurface(column);
    origin.y = netherFloorHeight(generator, &source, air_pocket, terrain_height, template.size[1], flat_box, column);
    return .{
        .template = template,
        .origin = origin,
        .pivot = pivot,
        .rotation = rotation,
        .mirror = mirror,
        .box = transformedBox(template.size, origin, pivot, mirror, rotation),
        .air_pocket = air_pocket,
    };
}

fn netherFloorHeight(
    generator: anytype,
    source: *legacy.Random,
    air_pocket: bool,
    terrain_height: i32,
    block_count_y: i32,
    box: Box,
    column: []base.Block,
) i32 {
    _ = terrain_height;
    _ = block_count_y;
    var y: i32 = if (air_pocket)
        32 + source.nextBoundedI32(69)
    else if (source.nextF32() < 0.5)
        27 + source.nextBoundedI32(3)
    else
        29 + source.nextBoundedI32(72);
    while (y > 15) : (y -= 1) {
        var solid: u8 = 0;
        const corners = [_]Position{
            .{ .x = box.minimum.x, .y = y, .z = box.minimum.z },
            .{ .x = box.maximum.x, .y = y, .z = box.minimum.z },
            .{ .x = box.minimum.x, .y = y, .z = box.maximum.z },
            .{ .x = box.maximum.x, .y = y, .z = box.maximum.z },
        };
        for (corners) |corner| {
            generator.generateColumnWithoutStructureAdaptation(corner.x, corner.z, column) catch unreachable;
            if (worldSurfaceBlock(column[@intCast(y)])) {
                solid += 1;
                if (solid == 3) return y;
            }
        }
    }
    return y;
}

fn placeTemplate(
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
    nodes: []nbt.Node,
    stack: []nbt.Frame,
    palette: []minecraft.State,
    portal: Plan,
) u8 {
    const view = structures.TemplateView.init(portal.template, nodes, stack) catch unreachable;
    var palette_iterator = view.palette() catch unreachable;
    var state_buffer: [256]u8 = undefined;
    var palette_count: usize = 0;
    while (palette_iterator.next(&state_buffer) catch unreachable) |state| {
        std.debug.assert(palette_count < palette.len);
        palette[palette_count] = state;
        palette_count += 1;
    }
    var iterator = view.blocks() catch unreachable;
    var lootable_entities: u8 = 0;
    while (iterator.next() catch unreachable) |block| {
        std.debug.assert(block.state < palette_count);
        var state = palette[block.state];
        if (state.block() == .structure_block or state.block() == .structure_void) continue;
        if (!portal.air_pocket and state.block() == .air) continue;
        const local = transformAround(.{
            .x = block.position[0],
            .y = block.position[1],
            .z = block.position[2],
        }, portal.pivot, portal.mirror, portal.rotation);
        const position = add(portal.origin, local);
        state = processRules(state, position);
        state = processAge(state, position, &state_buffer);
        state = replaceWithBlackstone(state, &state_buffer);
        state = structures.mirrorState(state, portal.mirror, &state_buffer);
        state = structures.rotateState(state, portal.rotation, &state_buffer);
        if (@divFloor(position.x, width) != chunk_x or @divFloor(position.z, width) != chunk_z) continue;
        if (isLavaAt(chunk_x, chunk_z, blocks, position) and !isFullCube(state))
            state = minecraft.defaultState(.lava);
        setBlock(chunk_x, chunk_z, blocks, position, state);
        if (state.block() == .chest and block.data != null) lootable_entities += 1;
    }
    return lootable_entities;
}

fn processRules(state: minecraft.State, position: Position) minecraft.State {
    var source = legacy.Random.init(random.hashBlockPosition(position.x, position.y, position.z));
    if (state.block() == .gold_block and source.nextF32() < 0.3)
        return minecraft.defaultState(.air);
    if (state.block() == .lava and source.nextF32() < 0.2)
        return minecraft.defaultState(.magma_block);
    if (state.block() == .netherrack and source.nextF32() < 0.07)
        return minecraft.defaultState(.magma_block);
    return state;
}

fn processAge(state: minecraft.State, position: Position, buffer: []u8) minecraft.State {
    var source = legacy.Random.init(random.hashBlockPosition(position.x, position.y, position.z));
    const block = state.block();
    if (block == .obsidian)
        return if (source.nextF32() < 0.15) minecraft.defaultState(.crying_obsidian) else state;
    const name = state.canonicalName();
    if (block == .stone_bricks or block == .stone or block == .chiseled_stone_bricks)
        return ageStone(state, &source, buffer);
    if (std.mem.endsWith(u8, blockName(name), "_stairs")) return ageStairs(state, &source);
    if (std.mem.endsWith(u8, blockName(name), "_slab")) {
        _ = source.nextF32();
        return state;
    }
    if (std.mem.endsWith(u8, blockName(name), "_wall")) {
        _ = source.nextF32();
        return state;
    }
    return state;
}

fn ageStone(state: minecraft.State, source: *legacy.Random, buffer: []u8) minecraft.State {
    if (source.nextF32() >= 0.5) return state;
    const regular_stairs = randomStoneBrickStairs(source, false, buffer);
    _ = randomStoneBrickStairs(source, true, buffer);
    _ = source.nextF32();
    return if (source.nextBounded(2) == 0)
        minecraft.defaultState(.cracked_stone_bricks)
    else
        regular_stairs;
}

fn ageStairs(state: minecraft.State, source: *legacy.Random) minecraft.State {
    if (source.nextF32() >= 0.5) return state;
    _ = source.nextF32();
    return if (source.nextBounded(2) == 0)
        minecraft.defaultState(.stone_slab)
    else
        minecraft.defaultState(.stone_brick_slab);
}

fn randomStoneBrickStairs(source: *legacy.Random, mossy: bool, buffer: []u8) minecraft.State {
    const directions = [_][]const u8{ "north", "east", "south", "west" };
    const halves = [_][]const u8{ "top", "bottom" };
    const name = std.fmt.bufPrint(
        buffer,
        "minecraft:{s}[facing={s},half={s},shape=straight,waterlogged=false]",
        .{
            if (mossy) "mossy_stone_brick_stairs" else "stone_brick_stairs",
            directions[source.nextBounded(4)],
            halves[source.nextBounded(2)],
        },
    ) catch unreachable;
    return minecraft.State.parse(name) orelse unreachable;
}

fn replaceWithBlackstone(state: minecraft.State, buffer: []u8) minecraft.State {
    const replacement: ?minecraft.Block = switch (state.block()) {
        .cobblestone, .mossy_cobblestone => .blackstone,
        .stone => .polished_blackstone,
        .stone_bricks, .mossy_stone_bricks => .polished_blackstone_bricks,
        .cobblestone_stairs, .mossy_cobblestone_stairs => .blackstone_stairs,
        .stone_stairs => .polished_blackstone_stairs,
        .stone_brick_stairs, .mossy_stone_brick_stairs => .polished_blackstone_brick_stairs,
        .cobblestone_slab, .mossy_cobblestone_slab => .blackstone_slab,
        .smooth_stone_slab, .stone_slab => .polished_blackstone_slab,
        .stone_brick_slab, .mossy_stone_brick_slab => .polished_blackstone_brick_slab,
        .stone_brick_wall, .mossy_stone_brick_wall => .polished_blackstone_brick_wall,
        .cobblestone_wall, .mossy_cobblestone_wall => .blackstone_wall,
        .chiseled_stone_bricks => .chiseled_polished_blackstone,
        .cracked_stone_bricks => .cracked_polished_blackstone_bricks,
        .iron_bars => .chain,
        else => null,
    };
    const target = replacement orelse return state;
    if (state.block() == .iron_bars) return minecraft.defaultState(target);
    const canonical = state.canonicalName();
    const properties = std.mem.indexOfScalar(u8, canonical, '[') orelse
        return minecraft.defaultState(target);
    const target_name = minecraft.defaultState(target).canonicalName();
    const target_properties = std.mem.indexOfScalar(u8, target_name, '[') orelse target_name.len;
    const name = std.fmt.bufPrint(buffer, "{s}{s}", .{ target_name[0..target_properties], canonical[properties..] }) catch unreachable;
    return minecraft.State.parse(name) orelse minecraft.defaultState(target);
}

const WallConnection = enum { none, low, tall };

fn updateWallStates(chunk_x: i32, chunk_z: i32, blocks: []base.Block, box: Box) void {
    var buffer: [256]u8 = undefined;
    var y = box.minimum.y;
    while (y <= box.maximum.y) : (y += 1) {
        var z = box.minimum.z;
        while (z <= box.maximum.z) : (z += 1) {
            var x = box.minimum.x;
            while (x <= box.maximum.x) : (x += 1) {
                const position = Position{ .x = x, .y = y, .z = z };
                const state = stateAt(chunk_x, chunk_z, blocks, position) orelse continue;
                if (!std.mem.endsWith(u8, blockName(state.canonicalName()), "_wall")) continue;
                const north = wallConnection(chunk_x, chunk_z, blocks, .{ .x = x, .y = y, .z = z - 1 });
                const east = wallConnection(chunk_x, chunk_z, blocks, .{ .x = x + 1, .y = y, .z = z });
                const south = wallConnection(chunk_x, chunk_z, blocks, .{ .x = x, .y = y, .z = z + 1 });
                const west = wallConnection(chunk_x, chunk_z, blocks, .{ .x = x - 1, .y = y, .z = z });
                const up = !(north != .none and east != .none and south != .none and west != .none);
                const name = std.fmt.bufPrint(
                    &buffer,
                    "{s}[east={s},north={s},south={s},up={},waterlogged=false,west={s}]",
                    .{ blockName(state.canonicalName()), @tagName(east), @tagName(north), @tagName(south), up, @tagName(west) },
                ) catch unreachable;
                setBlock(chunk_x, chunk_z, blocks, position, minecraft.State.parse(name) orelse unreachable);
            }
        }
    }
}

fn wallConnection(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, position: Position) WallConnection {
    const state = stateAt(chunk_x, chunk_z, blocks, position) orelse return .none;
    if (isFullCube(state)) return .tall;
    return if (std.mem.endsWith(u8, blockName(state.canonicalName()), "_wall")) .low else .none;
}

fn placeNetherrackBase(source: *random.ChunkRandom, chunk_x: i32, chunk_z: i32, blocks: []base.Block, portal: Plan) void {
    const probabilities = [_]f32{ 1, 1, 1, 1, 1, 1, 1, 0.9, 0.9, 0.8, 0.7, 0.6, 0.4, 0.2 };
    const center = centerOf(portal.box);
    const average_size = @divFloor(portal.box.maximum.x - portal.box.minimum.x + 1 + portal.box.maximum.z - portal.box.minimum.z + 1, 2);
    const offset = source.nextBoundedI32(@max(1, 8 - @divFloor(average_size, 2)));
    const radius: i32 = @intCast(probabilities.len);
    var x = center.x - radius;
    while (x <= center.x + radius) : (x += 1) {
        var z = center.z - radius;
        while (z <= center.z + radius) : (z += 1) {
            const distance: usize = @intCast(@abs(x - center.x) + @abs(z - center.z) + @as(u32, @intCast(offset)));
            if (distance >= probabilities.len or source.nextF64() >= probabilities[distance]) continue;
            const top = worldSurfaceTop(chunk_x, chunk_z, blocks, x, z);
            const y = @min(portal.box.minimum.y, top);
            const position = Position{ .x = x, .y = y, .z = z };
            if (@abs(y - portal.box.minimum.y) > 3 or !canFillNetherrack(chunk_x, chunk_z, blocks, position)) continue;
            placeNetherrackBottom(source, chunk_x, chunk_z, blocks, position);
            updateNetherracks(source, chunk_x, chunk_z, blocks, .{ .x = x, .y = y - 1, .z = z });
        }
    }
}

fn updateNetherracksInBounds(source: *random.ChunkRandom, chunk_x: i32, chunk_z: i32, blocks: []base.Block, box: Box) void {
    var x = box.minimum.x + 1;
    while (x < box.maximum.x) : (x += 1) {
        var z = box.minimum.z + 1;
        while (z < box.maximum.z) : (z += 1) {
            const position = Position{ .x = x, .y = box.minimum.y, .z = z };
            const state = stateAt(chunk_x, chunk_z, blocks, position) orelse continue;
            if (state.block() == .netherrack)
                updateNetherracks(source, chunk_x, chunk_z, blocks, .{ .x = x, .y = box.minimum.y - 1, .z = z });
        }
    }
}

fn updateNetherracks(source: *random.ChunkRandom, chunk_x: i32, chunk_z: i32, blocks: []base.Block, start: Position) void {
    var position = start;
    placeNetherrackBottom(source, chunk_x, chunk_z, blocks, position);
    var remaining: u8 = 8;
    while (remaining > 0 and source.nextF32() < 0.5) : (remaining -= 1) {
        position.y -= 1;
        placeNetherrackBottom(source, chunk_x, chunk_z, blocks, position);
    }
}

fn placeNetherrackBottom(source: *random.ChunkRandom, chunk_x: i32, chunk_z: i32, blocks: []base.Block, position: Position) void {
    const state = if (source.nextF32() < 0.07)
        minecraft.defaultState(.magma_block)
    else
        minecraft.defaultState(.netherrack);
    setBlock(chunk_x, chunk_z, blocks, position, state);
}

fn transformedBox(size: [3]i32, origin: Position, pivot: Position, mirror: structures.Mirror, rotation: structures.Rotation) Box {
    const first = transformAround(.{ .x = 0, .y = 0, .z = 0 }, pivot, mirror, rotation);
    const last = transformAround(.{ .x = size[0] - 1, .y = size[1] - 1, .z = size[2] - 1 }, pivot, mirror, rotation);
    return .{
        .minimum = .{ .x = origin.x + @min(first.x, last.x), .y = origin.y, .z = origin.z + @min(first.z, last.z) },
        .maximum = .{ .x = origin.x + @max(first.x, last.x), .y = origin.y + size[1] - 1, .z = origin.z + @max(first.z, last.z) },
    };
}

fn transformAround(position: Position, pivot: Position, mirror: structures.Mirror, rotation: structures.Rotation) Position {
    var x = position.x;
    var z = position.z;
    if (mirror == .left_right) z = -z;
    if (mirror == .front_back) x = -x;
    return switch (rotation) {
        .none => .{ .x = x, .y = position.y, .z = z },
        .counterclockwise_90 => .{ .x = pivot.x - pivot.z + z, .y = position.y, .z = pivot.x + pivot.z - x },
        .clockwise_90 => .{ .x = pivot.x + pivot.z - z, .y = position.y, .z = pivot.z - pivot.x + x },
        .clockwise_180 => .{ .x = 2 * pivot.x - x, .y = position.y, .z = 2 * pivot.z - z },
    };
}

fn highestWorldSurface(column: []const base.Block) i32 {
    var y: usize = column.len;
    while (y > 0) {
        y -= 1;
        if (worldSurfaceBlock(column[y])) return @intCast(y);
    }
    return 0;
}

fn worldSurfaceBlock(block: base.Block) bool {
    return switch (block) {
        .air, .cave_air => false,
        .solid, .fluid, .surface => true,
        .feature => |state| state.block() != .air and state.block() != .cave_air,
    };
}

fn worldSurfaceTop(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, x: i32, z: i32) i32 {
    var y: i32 = terrain_generation_height - 1;
    while (y >= 0) : (y -= 1) {
        const index = regionIndex(chunk_x, chunk_z, .{ .x = x, .y = y, .z = z }) orelse return 0;
        if (worldSurfaceBlock(blocks[index])) return y;
    }
    return 0;
}

fn canFillNetherrack(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, position: Position) bool {
    const index = regionIndex(chunk_x, chunk_z, position) orelse return false;
    return switch (blocks[index]) {
        .air => false,
        .cave_air => true,
        .feature => |state| state.block() != .air and state.block() != .obsidian and
            !featureCannotReplace(state.block()),
        .solid, .fluid, .surface => true,
    };
}

fn featureCannotReplace(block: minecraft.Block) bool {
    return switch (block) {
        .bedrock,
        .spawner,
        .chest,
        .end_portal_frame,
        .reinforced_deepslate,
        .trial_spawner,
        .vault,
        => true,
        else => false,
    };
}

fn isLavaAt(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, position: Position) bool {
    const index = regionIndex(chunk_x, chunk_z, position) orelse return false;
    return switch (blocks[index]) {
        .fluid => true,
        .feature => |state| state.block() == .lava,
        else => false,
    };
}

fn stateAt(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, position: Position) ?minecraft.State {
    const index = regionIndex(chunk_x, chunk_z, position) orelse return null;
    return switch (blocks[index]) {
        .feature => |state| state,
        .solid, .surface => minecraft.defaultState(.netherrack),
        .fluid => minecraft.defaultState(.lava),
        .air => minecraft.defaultState(.air),
        .cave_air => minecraft.defaultState(.cave_air),
    };
}

fn isFullCube(state: minecraft.State) bool {
    const name = blockName(state.canonicalName());
    return state.block() != .air and state.block() != .cave_air and state.block() != .lava and
        state.block() != .water and state.block() != .chest and state.block() != .chain and
        !std.mem.endsWith(u8, name, "_stairs") and !std.mem.endsWith(u8, name, "_slab") and
        !std.mem.endsWith(u8, name, "_wall") and !std.mem.endsWith(u8, name, "_bars");
}

fn blockName(canonical: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, canonical, '[') orelse canonical.len;
    return canonical[0..end];
}

fn centerOf(box: Box) Position {
    return .{
        .x = box.minimum.x + @divFloor(box.maximum.x - box.minimum.x + 1, 2),
        .y = box.minimum.y + @divFloor(box.maximum.y - box.minimum.y + 1, 2),
        .z = box.minimum.z + @divFloor(box.maximum.z - box.minimum.z + 1, 2),
    };
}

fn add(left: Position, right: Position) Position {
    return .{ .x = left.x + right.x, .y = left.y + right.y, .z = left.z + right.z };
}

fn setBlock(chunk_x: i32, chunk_z: i32, blocks: []base.Block, position: Position, state: minecraft.State) void {
    const index = regionIndex(chunk_x, chunk_z, position) orelse return;
    blocks[index] = .{ .feature = state };
}

fn regionIndex(chunk_x: i32, chunk_z: i32, position: Position) ?usize {
    if (position.y < 0 or position.y >= world_height) return null;
    const offset_x = @divFloor(position.x, width) - chunk_x;
    const offset_z = @divFloor(position.z, width) - chunk_z;
    if (offset_x < -1 or offset_x > 1 or offset_z < -1 or offset_z > 1) return null;
    const local_x: usize = @intCast(@mod(position.x, width));
    const local_z: usize = @intCast(@mod(position.z, width));
    const local_y: usize = @intCast(position.y);
    const region_x: usize = @intCast(offset_x + 1);
    const region_z: usize = @intCast(offset_z + 1);
    const chunk_index = region_z * 3 + region_x;
    return chunk_index * chunk_block_count + local_y * width * width + local_z * width + local_x;
}

test "ruined portal template transform matches the Vanilla reference box" {
    const template = structures.vanilla.find("minecraft:ruined_portal/portal_8") orelse unreachable;
    const box = transformedBox(
        template.size,
        .{ .x = 320, .y = 27, .z = 144 },
        .{ .x = 7, .y = 0, .z = 4 },
        .front_back,
        .clockwise_180,
    );
    try std.testing.expectEqual(Position{ .x = 334, .y = 27, .z = 144 }, box.minimum);
    try std.testing.expectEqual(Position{ .x = 347, .y = 35, .z = 152 }, box.maximum);
}
