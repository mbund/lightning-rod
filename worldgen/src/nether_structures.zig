const std = @import("std");
const minecraft = @import("minecraft_registry");
const nbt = @import("nbt");
const base = @import("base_dimension.zig");
const jigsaw = @import("jigsaw.zig");
const fortress = @import("nether_fortress.zig");
const legacy = @import("legacy_noise.zig");
const random = @import("random.zig");
const ruined_portal = @import("ruined_portal.zig");
const processor_data = @import("processor_data");
const structures = @import("structures.zig");

const width = 16;
const terrain_height = 128;
const world_height = 256;
const chunk_block_count = width * width * world_height;
const fossil_count = 14;

pub const Scratch = struct {
    nodes: [262_144]nbt.Node,
    stack: [128]nbt.Frame,
    palette: [128]minecraft.State,
    jigsaw: jigsaw.Scratch,
    fortress: fortress.Scratch,
    density_boxes: [25]Box,
    density_box_count: u8,
    terrain_column: [terrain_height]base.Block,
};

pub fn applySurface(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    scratch: *Scratch,
    blocks: []base.Block,
) void {
    std.debug.assert(blocks.len == 9 * chunk_block_count);
    var source_z = chunk_z - 8;
    while (source_z <= chunk_z + 8) : (source_z += 1) {
        var source_x = chunk_x - 8;
        while (source_x <= chunk_x + 8) : (source_x += 1) {
            const source = structures.ChunkPos{ .x = source_x, .z = source_z };
            if (fortress.generate(world_seed, source, &scratch.fortress)) |plan| {
                fortress.place(plan, chunk_x, chunk_z, blocks);
                continue;
            }
            const plan = jigsaw.bastionPlan(world_seed, source, &scratch.jigsaw) orelse continue;
            const biome = generator.biomeAtQuart(
                @divFloor(plan.center.x, 4),
                @divFloor(plan.center.y, 4),
                @divFloor(plan.center.z, 4),
            );
            if (biome == .basalt_deltas) continue;
            placeBastion(chunk_x, chunk_z, blocks, scratch, plan);
        }
    }
    ruined_portal.apply(
        generator,
        world_seed,
        chunk_x,
        chunk_z,
        &scratch.nodes,
        &scratch.stack,
        &scratch.palette,
        &scratch.terrain_column,
        blocks,
    );
}

fn placeBastion(
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
    scratch: *Scratch,
    plan: jigsaw.Plan,
) void {
    const first = plan.pieces[0].box;
    const pivot = Position{
        .x = @divFloor(first.minimum.x + first.maximum.x, 2),
        .y = first.minimum.y,
        .z = @divFloor(first.minimum.z + first.maximum.z, 2),
    };
    for (plan.pieces) |piece|
        placeJigsawPiece(chunk_x, chunk_z, blocks, scratch, piece, pivot);
}

fn placeJigsawPiece(
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
    scratch: *Scratch,
    piece: jigsaw.Piece,
    pivot: Position,
) void {
    const view = structures.TemplateView.init(piece.template, &scratch.nodes, &scratch.stack) catch unreachable;
    const palette_count = loadPalette(view, scratch);
    var iterator = view.blocks() catch unreachable;
    var state_buffer: [256]u8 = undefined;
    while (iterator.next() catch unreachable) |block| {
        std.debug.assert(block.state < palette_count);
        var state = replacementState(scratch.palette[block.state], block.data, view.document.nodes, &state_buffer);
        if (state.block() == .structure_block or state.block() == .structure_void) continue;
        const offset = structures.rotate(.{
            .x = block.position[0],
            .y = block.position[1],
            .z = block.position[2],
        }, piece.rotation);
        const position = Position{
            .x = piece.origin.x + offset.x,
            .y = piece.origin.y + offset.y,
            .z = piece.origin.z + offset.z,
        };
        state = applyProcessor(piece.processors, state, position, pivot, &state_buffer);
        state = structures.rotateState(state, piece.rotation, &state_buffer);
        setBlock(chunk_x, chunk_z, blocks, position, state);
    }
}

fn applyProcessor(
    id: []const u8,
    state: minecraft.State,
    position: Position,
    pivot: Position,
    buffer: []u8,
) minecraft.State {
    const list = findProcessor(id) orelse return state;
    var source = legacy.Random.init(blockPositionHash(position));
    for (processor_data.rules[list.first..][0..list.count]) |rule| {
        if (!matchesInput(rule.input, state, &source)) continue;
        if (!matchesPosition(rule.position, position, pivot, &source)) continue;
        return minecraft.parseBlockArgument(rule.output, buffer) orelse unreachable;
    }
    return state;
}

fn findProcessor(id: []const u8) ?processor_data.List {
    var low: usize = 0;
    var high: usize = processor_data.lists.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, id, processor_data.lists[middle].id)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return processor_data.lists[middle],
        }
    }
    return null;
}

fn matchesInput(input: processor_data.Input, state: minecraft.State, source: *legacy.Random) bool {
    return switch (input) {
        .always => true,
        .random_block => |rule| blk: {
            const block = minecraft.blockFromName(rule.block) orelse unreachable;
            break :blk state.block() == block and source.nextF32() < rule.probability;
        },
    };
}

fn matchesPosition(rule: processor_data.Position, position: Position, pivot: Position, source: *legacy.Random) bool {
    return switch (rule) {
        .always => true,
        .axis_linear => |linear| blk: {
            const coordinate = switch (linear.axis) {
                'x' => position.x - pivot.x,
                'y' => position.y - pivot.y,
                'z' => position.z - pivot.z,
                else => unreachable,
            };
            const distance: f32 = @floatFromInt(@abs(coordinate));
            const progress = std.math.clamp(
                (distance - @as(f32, @floatFromInt(linear.minimum_distance))) /
                    @as(f32, @floatFromInt(linear.maximum_distance - linear.minimum_distance)),
                0,
                1,
            );
            const chance = linear.minimum_chance + progress * (linear.maximum_chance - linear.minimum_chance);
            break :blk source.nextF32() <= chance;
        },
    };
}

fn blockPositionHash(position: Position) i64 {
    const x_product: i32 = position.x *% 3_129_871;
    var value = @as(i64, x_product) ^ @as(i64, position.z) *% 116_129_781 ^ @as(i64, position.y);
    value = value *% value *% 42_317_861 +% value *% 11;
    return value >> 16;
}

fn loadPalette(view: structures.TemplateView, scratch: *Scratch) usize {
    var palette = view.palette() catch unreachable;
    var state_buffer: [256]u8 = undefined;
    var count: usize = 0;
    while (palette.next(&state_buffer) catch unreachable) |state| {
        std.debug.assert(count < scratch.palette.len);
        scratch.palette[count] = state;
        count += 1;
    }
    return count;
}

fn replacementState(state: minecraft.State, data: ?nbt.Node, nodes: []const nbt.Node, buffer: []u8) minecraft.State {
    if (state.block() != .jigsaw) return state;
    const compound = data orelse return minecraft.defaultState(.air);
    const final_state = compound.childNamed(nodes, "final_state") orelse return minecraft.defaultState(.air);
    return minecraft.parseBlockArgument(final_state.string() catch unreachable, buffer) orelse unreachable;
}

const Rotation = enum(u2) { none, clockwise_90, clockwise_180, counterclockwise_90 };
const Position = struct { x: i32, y: i32, z: i32 };
const Box = struct { minimum: Position, maximum: Position };
const FossilPlan = struct {
    origin: Position,
    rotation: Rotation,
    template: structures.Template,
    box: Box,
};

pub fn prepareDensity(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    scratch: *Scratch,
) void {
    scratch.density_box_count = 0;
    var source_z = chunk_z - 2;
    while (source_z <= chunk_z + 2) : (source_z += 1) {
        var source_x = chunk_x - 2;
        while (source_x <= chunk_x + 2) : (source_x += 1) {
            const source_chunk = structures.ChunkPos{ .x = source_x, .z = source_z };
            if (!structures.nether_fossils.isStart(@bitCast(world_seed), source_chunk)) continue;
            const box = fossilBox(generator, world_seed, source_chunk, scratch) orelse continue;
            if (!intersectsExpandedChunk(box, chunk_x, chunk_z, 12)) continue;
            std.debug.assert(scratch.density_box_count < scratch.density_boxes.len);
            scratch.density_boxes[scratch.density_box_count] = box;
            scratch.density_box_count += 1;
        }
    }
}

pub fn adjustDensity(scratch: *const Scratch, positions: anytype, values: anytype) void {
    for (positions, values) |position, *value| {
        for (scratch.density_boxes[0..scratch.density_box_count]) |box|
            value.* += beardThin(box, .{ .x = position.x, .y = position.y, .z = position.z });
    }
}

pub fn applyUnderground(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    scratch: *Scratch,
    blocks: []base.Block,
) void {
    std.debug.assert(blocks.len == 9 * chunk_block_count);
    var source_z = chunk_z - 1;
    while (source_z <= chunk_z + 1) : (source_z += 1) {
        var source_x = chunk_x - 1;
        while (source_x <= chunk_x + 1) : (source_x += 1) {
            const source_chunk = structures.ChunkPos{ .x = source_x, .z = source_z };
            if (!structures.nether_fossils.isStart(@bitCast(world_seed), source_chunk)) continue;
            applyFossil(generator, world_seed, chunk_x, chunk_z, source_chunk, scratch, blocks);
        }
    }
}

fn applyFossil(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    source_chunk: structures.ChunkPos,
    scratch: *Scratch,
    blocks: []base.Block,
) void {
    const plan = fossilPlan(generator, world_seed, source_chunk, scratch) orelse return;
    _ = placeTemplate(chunk_x, chunk_z, blocks, scratch, plan.template, plan.origin, plan.rotation);
    placeDriedGhast(world_seed, chunk_x, chunk_z, blocks, plan.box);
}

fn fossilBox(generator: anytype, world_seed: u64, source_chunk: structures.ChunkPos, scratch: *Scratch) ?Box {
    const plan = fossilPlan(generator, world_seed, source_chunk, scratch) orelse return null;
    return plan.box;
}

fn fossilPlan(generator: anytype, world_seed: u64, source_chunk: structures.ChunkPos, scratch: *Scratch) ?FossilPlan {
    var source = legacy.Random.init(0);
    source.setCarverSeed(@bitCast(world_seed), source_chunk.x, source_chunk.z);
    const x = source_chunk.x * width + source.nextBoundedI32(width);
    const z = source_chunk.z * width + source.nextBoundedI32(width);
    var y = 32 + source.nextBoundedI32(94);
    generator.generateColumnWithoutStructureAdaptation(x, z, &scratch.terrain_column) catch unreachable;
    while (y > 32) {
        const current_air = isTerrainAir(scratch.terrain_column[@intCast(y)]);
        y -= 1;
        const below_solid = isTerrainSolid(scratch.terrain_column[@intCast(y)]);
        if (current_air and below_solid) break;
    }
    if (y <= 32) return null;
    if (generator.biomeAtQuart(@divFloor(x, 4), @divFloor(y, 4), @divFloor(z, 4)) != .soul_sand_valley) return null;
    const rotation: Rotation = @enumFromInt(source.nextBounded(4));
    const fossil_index = source.nextBounded(fossil_count) + 1;
    var id_buffer: [64]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buffer, "minecraft:nether_fossils/fossil_{d}", .{fossil_index}) catch unreachable;
    const template = structures.vanilla.find(id) orelse unreachable;
    const origin = Position{ .x = x, .y = y, .z = z };
    const box = templateBox(origin, template.size, rotation);
    return .{ .origin = origin, .rotation = rotation, .template = template, .box = box };
}

fn isTerrainAir(block: base.Block) bool {
    return switch (block) {
        .air => true,
        .solid, .cave_air, .fluid, .surface, .feature => false,
    };
}

fn isTerrainSolid(block: base.Block) bool {
    return switch (block) {
        .solid, .surface, .feature => true,
        .air, .cave_air, .fluid => false,
    };
}

fn placeTemplate(
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
    scratch: *Scratch,
    template: structures.Template,
    origin: Position,
    rotation: Rotation,
) Box {
    const view = structures.TemplateView.init(template, &scratch.nodes, &scratch.stack) catch unreachable;
    var palette = view.palette() catch unreachable;
    var state_buffer: [256]u8 = undefined;
    var palette_count: usize = 0;
    while (palette.next(&state_buffer) catch unreachable) |state| {
        std.debug.assert(palette_count < scratch.palette.len);
        scratch.palette[palette_count] = state;
        palette_count += 1;
    }
    var iterator = view.blocks() catch unreachable;
    while (iterator.next() catch unreachable) |block| {
        std.debug.assert(block.state < palette_count);
        var state = scratch.palette[block.state];
        if (state.block() == .air or state.block() == .structure_void) continue;
        state = rotateState(state, rotation);
        const offset = rotate(.{ .x = block.position[0], .y = block.position[1], .z = block.position[2] }, rotation);
        setBlock(chunk_x, chunk_z, blocks, .{
            .x = origin.x + offset.x,
            .y = origin.y + offset.y,
            .z = origin.z + offset.z,
        }, state);
    }
    return templateBox(origin, template.size, rotation);
}

fn placeDriedGhast(world_seed: u64, chunk_x: i32, chunk_z: i32, blocks: []base.Block, box: Box) void {
    var root = legacy.Random.init(@bitCast(world_seed));
    const splitter = random.LegacySplitter.fromSource(&root);
    const center = Position{
        .x = @divFloor(box.minimum.x + box.maximum.x, 2),
        .y = @divFloor(box.minimum.y + box.maximum.y, 2),
        .z = @divFloor(box.minimum.z + box.maximum.z, 2),
    };
    var source = splitter.splitPosition(center.x, center.y, center.z);
    if (source.nextF32() >= 0.5) return;
    const position = Position{
        .x = box.minimum.x + source.nextBoundedI32(box.maximum.x - box.minimum.x + 1),
        .y = box.minimum.y,
        .z = box.minimum.z + source.nextBoundedI32(box.maximum.z - box.minimum.z + 1),
    };
    if (!isAir(chunk_x, chunk_z, blocks, position)) return;
    const rotation: Rotation = @enumFromInt(source.nextBounded(4));
    setBlock(chunk_x, chunk_z, blocks, position, rotateFacing(minecraft.defaultState(.dried_ghast), rotation));
}

fn templateBox(origin: Position, size: [3]i32, rotation: Rotation) Box {
    const corner = rotate(.{ .x = size[0] - 1, .y = size[1] - 1, .z = size[2] - 1 }, rotation);
    return .{
        .minimum = .{
            .x = origin.x + @min(0, corner.x),
            .y = origin.y,
            .z = origin.z + @min(0, corner.z),
        },
        .maximum = .{
            .x = origin.x + @max(0, corner.x),
            .y = origin.y + corner.y,
            .z = origin.z + @max(0, corner.z),
        },
    };
}

fn intersectsExpandedChunk(box: Box, chunk_x: i32, chunk_z: i32, margin: i32) bool {
    const minimum_x = chunk_x * width - margin;
    const minimum_z = chunk_z * width - margin;
    const maximum_x = minimum_x + width - 1 + margin * 2;
    const maximum_z = minimum_z + width - 1 + margin * 2;
    return box.maximum.x >= minimum_x and box.minimum.x <= maximum_x and
        box.maximum.z >= minimum_z and box.minimum.z <= maximum_z;
}

fn beardThin(box: Box, position: Position) f64 {
    const x = @max(0, @max(box.minimum.x - position.x, position.x - box.maximum.x));
    const z = @max(0, @max(box.minimum.z - position.z, position.z - box.maximum.z));
    const y = position.y - box.minimum.y;
    if (x < -12 or x >= 12 or y < -12 or y >= 12 or z < -12 or z >= 12) return 0;
    const shifted_y = @as(f64, @floatFromInt(y)) + 0.5;
    const squared = @as(f64, @floatFromInt(x * x + z * z)) + shifted_y * shifted_y;
    const inverse = fastInverseSqrt(squared / 2.0);
    const direction = -shifted_y * inverse / 2.0;
    const magnitude: f64 = @floatCast(@as(f32, @floatCast(std.math.exp(-squared / 16.0))));
    return direction * magnitude * 0.8;
}

fn fastInverseSqrt(value: f64) f64 {
    const half = 0.5 * value;
    const bits = 6_910_469_410_427_058_090 - (@as(i64, @bitCast(value)) >> 1);
    const estimate: f64 = @bitCast(bits);
    return estimate * (1.5 - half * estimate * estimate);
}

fn rotate(position: Position, rotation: Rotation) Position {
    return switch (rotation) {
        .none => position,
        .clockwise_90 => .{ .x = -position.z, .y = position.y, .z = position.x },
        .clockwise_180 => .{ .x = -position.x, .y = position.y, .z = -position.z },
        .counterclockwise_90 => .{ .x = position.z, .y = position.y, .z = -position.x },
    };
}

fn rotateState(state: minecraft.State, rotation: Rotation) minecraft.State {
    if (state.block() != .bone_block or rotation == .none or rotation == .clockwise_180) return state;
    const axis = state.property("axis") orelse unreachable;
    if (std.mem.eql(u8, axis, "y")) return state;
    return minecraft.State.parse(if (std.mem.eql(u8, axis, "x"))
        "minecraft:bone_block[axis=z]"
    else
        "minecraft:bone_block[axis=x]").?;
}

fn rotateFacing(state: minecraft.State, rotation: Rotation) minecraft.State {
    const facing = state.property("facing") orelse return state;
    const directions = [_][]const u8{ "north", "east", "south", "west" };
    var index: usize = 0;
    while (index < directions.len and !std.mem.eql(u8, facing, directions[index])) : (index += 1) {}
    if (index == directions.len) return state;
    index = @mod(index + @intFromEnum(rotation), directions.len);
    var buffer: [128]u8 = undefined;
    const name = std.fmt.bufPrint(
        &buffer,
        "minecraft:dried_ghast[facing={s},hydration=0,waterlogged=false]",
        .{directions[index]},
    ) catch unreachable;
    return minecraft.State.parse(name).?;
}

fn isAir(chunk_x: i32, chunk_z: i32, blocks: []const base.Block, position: Position) bool {
    const index = regionIndex(chunk_x, chunk_z, position) orelse return true;
    return switch (blocks[index]) {
        .air, .cave_air => true,
        .fluid, .solid, .surface, .feature => false,
    };
}

fn setBlock(chunk_x: i32, chunk_z: i32, blocks: []base.Block, position: Position, state: minecraft.State) void {
    const index = centerIndex(chunk_x, chunk_z, position) orelse return;
    blocks[index] = .{ .feature = state };
}

fn centerIndex(chunk_x: i32, chunk_z: i32, position: Position) ?usize {
    if (@divFloor(position.x, width) != chunk_x or @divFloor(position.z, width) != chunk_z) return null;
    return regionIndex(chunk_x, chunk_z, position);
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
    return chunk_index * chunk_block_count + baseBlockIndex(local_x, local_y, local_z);
}

fn baseBlockIndex(local_x: usize, local_y: usize, local_z: usize) usize {
    std.debug.assert(local_x < width and local_y < world_height and local_z < width);
    return local_y * width * width + local_z * width + local_x;
}

test "fossil rotations preserve the vertical bone axis" {
    const vertical = minecraft.State.parse("minecraft:bone_block[axis=y]").?;
    try std.testing.expectEqual(vertical, rotateState(vertical, .clockwise_90));
    const horizontal = minecraft.State.parse("minecraft:bone_block[axis=x]").?;
    try std.testing.expectEqualStrings(
        "minecraft:bone_block[axis=z]",
        rotateState(horizontal, .clockwise_90).canonicalName(),
    );
}

test "Nether fossil beard influence is bounded" {
    const box = Box{
        .minimum = .{ .x = 0, .y = 40, .z = 0 },
        .maximum = .{ .x = 4, .y = 44, .z = 4 },
    };
    try std.testing.expect(beardThin(box, .{ .x = 2, .y = 36, .z = 2 }) > 0);
    try std.testing.expect(beardThin(box, .{ .x = 2, .y = 44, .z = 2 }) < 0);
    try std.testing.expectEqual(@as(f64, 0), beardThin(box, .{ .x = 16, .y = 40, .z = 2 }));
}
