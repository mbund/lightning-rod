const std = @import("std");
const minecraft = @import("minecraft_registry");
const nbt = @import("nbt");
const base = @import("base_dimension.zig");
const legacy = @import("legacy_noise.zig");
const structures = @import("structures.zig");

const width = 16;
const world_height = 256;
const chunk_block_count = width * width * world_height;
const maximum_pieces = 256;
const maximum_frames = 16;
const source_radius = 8;

const Position = structures.Position;
const Rotation = structures.Rotation;

pub const Scratch = struct {
    nodes: [65_536]nbt.Node,
    nbt_stack: [128]nbt.Frame,
    palette: [128]minecraft.State,
    pieces: [maximum_pieces]Piece,
    frames: [maximum_frames]Frame,
    terrain: [chunk_block_count]base.Block,
};

const Piece = struct {
    template: structures.Template,
    origin: Position,
    rotation: Rotation,
    box: structures.Box,
    chain: i32 = 0,
    place_air: bool,
};

const Part = enum { building, small_tower, bridge, fat_tower };

const Frame = struct {
    part: Part,
    parent: u16,
    relative: Position,
    depth: u8,
    existing_start: u16,
    start: u16,
    stage: u8 = 0,
    current: u16 = 0,
    anchor: ?u16 = null,
    count: u8 = 0,
    index: u8 = 0,
    rise: i32 = 0,
};

const City = struct {
    pieces: []Piece,
};

pub fn apply(
    generator: anytype,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    scratch: *Scratch,
    blocks: []base.Block,
) void {
    std.debug.assert(blocks.len == 9 * chunk_block_count);
    var source_z = chunk_z - source_radius;
    while (source_z <= chunk_z + source_radius) : (source_z += 1) {
        var source_x = chunk_x - source_radius;
        while (source_x <= chunk_x + source_radius) : (source_x += 1) {
            const source = structures.ChunkPos{ .x = source_x, .z = source_z };
            if (!structures.end_cities.isStart(@bitCast(world_seed), source)) continue;
            const city = generateCity(generator, world_seed, source, scratch, chunk_x, chunk_z, blocks) orelse continue;
            placeCity(chunk_x, chunk_z, blocks, scratch, city);
        }
    }
}

pub fn validStart(generator: anytype, world_seed: u64, source: structures.ChunkPos, scratch: *Scratch) bool {
    if (!structures.end_cities.isStart(@bitCast(world_seed), source)) return false;
    var random = legacy.Random.init(0);
    random.setCarverSeed(@bitCast(world_seed), source.x, source.z);
    const rotation: Rotation = @enumFromInt(random.nextBounded(4));
    const position = shiftedPosition(generator, source, rotation, scratch, source.x + 2, source.z + 2, &.{});
    if (position.y < 60) return false;
    const biome = generator.biomeAtQuart(@divFloor(position.x, 4), @divFloor(position.y, 4), @divFloor(position.z, 4));
    return biome == .end_highlands or biome == .end_midlands;
}

fn generateCity(
    generator: anytype,
    world_seed: u64,
    source: structures.ChunkPos,
    scratch: *Scratch,
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
) ?City {
    var random = legacy.Random.init(0);
    random.setCarverSeed(@bitCast(world_seed), source.x, source.z);
    const rotation: Rotation = @enumFromInt(random.nextBounded(4));
    const position = shiftedPosition(generator, source, rotation, scratch, chunk_x, chunk_z, blocks);
    if (position.y < 60) return null;
    const biome = generator.biomeAtQuart(@divFloor(position.x, 4), @divFloor(position.y, 4), @divFloor(position.z, 4));
    if (biome != .end_highlands and biome != .end_midlands) return null;
    var count: u16 = 0;
    const base_piece = addAbsolute(scratch, &count, "base_floor", position, rotation, true);
    var current = addRelative(scratch, &count, base_piece, .{ .x = -1, .y = 0, .z = -1 }, "second_floor_1", rotation, false);
    current = addRelative(scratch, &count, current, .{ .x = -1, .y = 4, .z = -1 }, "third_floor_1", rotation, false);
    current = addRelative(scratch, &count, current, .{ .x = -1, .y = 8, .z = -1 }, "third_roof", rotation, true);
    generateParts(scratch, &count, &random, current);
    return .{ .pieces = scratch.pieces[0..count] };
}

fn shiftedPosition(
    generator: anytype,
    source: structures.ChunkPos,
    rotation: Rotation,
    scratch: *Scratch,
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
) Position {
    const offset = switch (rotation) {
        .none => Position{ .x = 5, .y = 0, .z = 5 },
        .clockwise_90 => Position{ .x = -5, .y = 0, .z = 5 },
        .clockwise_180 => Position{ .x = -5, .y = 0, .z = -5 },
        .counterclockwise_90 => Position{ .x = 5, .y = 0, .z = -5 },
    };
    const x = source.x * width + 7;
    const z = source.z * width + 7;
    const terrain = terrainFor(generator, source, scratch, chunk_x, chunk_z, blocks);
    const y = @min(
        @min(surfaceHeight(terrain, x, z, source), surfaceHeight(terrain, x + offset.x, z, source)),
        @min(surfaceHeight(terrain, x, z + offset.z, source), surfaceHeight(terrain, x + offset.x, z + offset.z, source)),
    );
    return .{ .x = x, .y = y, .z = z };
}

fn terrainFor(
    generator: anytype,
    source: structures.ChunkPos,
    scratch: *Scratch,
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
) []const base.Block {
    const offset_x = source.x - chunk_x;
    const offset_z = source.z - chunk_z;
    if (offset_x >= -1 and offset_x <= 1 and offset_z >= -1 and offset_z <= 1) {
        const index = @as(usize, @intCast(offset_z + 1)) * 3 + @as(usize, @intCast(offset_x + 1));
        return blocks[index * chunk_block_count ..][0..chunk_block_count];
    }
    generator.generateSurface(source.x, source.z, &scratch.terrain) catch unreachable;
    return &scratch.terrain;
}

fn surfaceHeight(terrain: []const base.Block, x: i32, z: i32, source: structures.ChunkPos) i32 {
    const local_x: usize = @intCast(x - source.x * width);
    const local_z: usize = @intCast(z - source.z * width);
    var y: usize = world_height;
    while (y > 0) {
        y -= 1;
        switch (terrain[y * width * width + local_z * width + local_x]) {
            .air, .cave_air => {},
            .solid, .fluid, .surface, .feature => return @intCast(y),
        }
    }
    return 0;
}

fn generateParts(scratch: *Scratch, count: *u16, random: *legacy.Random, parent: u16) void {
    var frame_count: u8 = 1;
    var child_result = false;
    var ship_generated = false;
    scratch.frames[0] = newFrame(.small_tower, 1, parent, .{ .x = 0, .y = 0, .z = 0 }, 0, count.*);
    while (frame_count > 0) {
        const frame = &scratch.frames[frame_count - 1];
        const action = stepFrame(scratch, count, random, frame, child_result, &ship_generated);
        switch (action) {
            .again => {},
            .call => |call| {
                std.debug.assert(frame_count < scratch.frames.len);
                scratch.frames[frame_count] = newFrame(call.part, call.depth, call.parent, call.relative, frame.start, count.*);
                frame_count += 1;
            },
            .done => |success| {
                child_result = finishFrame(scratch, count, random, frame.*, success);
                frame_count -= 1;
            },
        }
    }
}

const Action = union(enum) {
    again,
    call: struct { part: Part, depth: u8, parent: u16, relative: Position },
    done: bool,
};

fn newFrame(part: Part, depth: u8, parent: u16, relative: Position, existing_start: u16, start: u16) Frame {
    return .{ .part = part, .depth = depth, .parent = parent, .relative = relative, .existing_start = existing_start, .start = start };
}

fn stepFrame(
    scratch: *Scratch,
    count: *u16,
    random: *legacy.Random,
    frame: *Frame,
    child_result: bool,
    ship_generated: *bool,
) Action {
    if (frame.depth > 8) return .{ .done = false };
    return switch (frame.part) {
        .building => stepBuilding(scratch, count, random, frame),
        .small_tower => stepSmallTower(scratch, count, random, frame, child_result),
        .bridge => stepBridge(scratch, count, random, frame, child_result, ship_generated),
        .fat_tower => stepFatTower(scratch, count, random, frame),
    };
}

fn stepBuilding(scratch: *Scratch, count: *u16, random: *legacy.Random, frame: *Frame) Action {
    if (frame.stage != 0) return .{ .done = true };
    var piece = addRelative(scratch, count, frame.parent, frame.relative, "base_floor", pieceRotation(scratch, frame.parent), true);
    switch (random.nextBounded(3)) {
        0 => _ = addRelative(scratch, count, piece, .{ .x = -1, .y = 4, .z = -1 }, "base_roof", pieceRotation(scratch, piece), true),
        1 => {
            piece = addRelative(scratch, count, piece, .{ .x = -1, .y = 0, .z = -1 }, "second_floor_2", pieceRotation(scratch, piece), false);
            piece = addRelative(scratch, count, piece, .{ .x = -1, .y = 8, .z = -1 }, "second_roof", pieceRotation(scratch, piece), false);
            frame.stage = 1;
            return .{ .call = .{ .part = .small_tower, .depth = frame.depth + 1, .parent = piece, .relative = .{ .x = 0, .y = 0, .z = 0 } } };
        },
        2 => {
            piece = addRelative(scratch, count, piece, .{ .x = -1, .y = 0, .z = -1 }, "second_floor_2", pieceRotation(scratch, piece), false);
            piece = addRelative(scratch, count, piece, .{ .x = -1, .y = 4, .z = -1 }, "third_floor_2", pieceRotation(scratch, piece), false);
            piece = addRelative(scratch, count, piece, .{ .x = -1, .y = 8, .z = -1 }, "third_roof", pieceRotation(scratch, piece), true);
            frame.stage = 1;
            return .{ .call = .{ .part = .small_tower, .depth = frame.depth + 1, .parent = piece, .relative = .{ .x = 0, .y = 0, .z = 0 } } };
        },
        else => unreachable,
    }
    return .{ .done = true };
}

fn stepSmallTower(scratch: *Scratch, count: *u16, random: *legacy.Random, frame: *Frame, child_result: bool) Action {
    if (frame.stage == 2) return .{ .done = child_result };
    if (frame.stage == 0) initializeSmallTower(scratch, count, random, frame);
    if (frame.anchor) |anchor| {
        while (frame.index < small_attachments.len) {
            const attachment = small_attachments[frame.index];
            frame.index += 1;
            if (!random.nextBool()) continue;
            const rotation = compose(pieceRotation(scratch, anchor), attachment.rotation);
            const bridge = addRelative(scratch, count, anchor, attachment.position, "bridge_end", rotation, true);
            return .{ .call = .{ .part = .bridge, .depth = frame.depth + 1, .parent = bridge, .relative = .{ .x = 0, .y = 0, .z = 0 } } };
        }
        _ = addRelative(scratch, count, frame.current, .{ .x = -1, .y = 4, .z = -1 }, "tower_top", pieceRotation(scratch, frame.current), true);
        return .{ .done = true };
    }
    if (frame.depth != 7) {
        frame.stage = 2;
        return .{ .call = .{ .part = .fat_tower, .depth = frame.depth + 1, .parent = frame.current, .relative = .{ .x = 0, .y = 0, .z = 0 } } };
    }
    _ = addRelative(scratch, count, frame.current, .{ .x = -1, .y = 4, .z = -1 }, "tower_top", pieceRotation(scratch, frame.current), true);
    return .{ .done = true };
}

fn initializeSmallTower(scratch: *Scratch, count: *u16, random: *legacy.Random, frame: *Frame) void {
    const rotation = pieceRotation(scratch, frame.parent);
    var piece = addRelative(scratch, count, frame.parent, .{
        .x = 3 + random.nextBoundedI32(2),
        .y = -3,
        .z = 3 + random.nextBoundedI32(2),
    }, "tower_base", rotation, true);
    piece = addRelative(scratch, count, piece, .{ .x = 0, .y = 7, .z = 0 }, "tower_piece", rotation, true);
    var anchor: ?u16 = if (random.nextBounded(3) == 0) piece else null;
    const tower_count = 1 + random.nextBounded(3);
    for (0..tower_count) |index| {
        piece = addRelative(scratch, count, piece, .{ .x = 0, .y = 4, .z = 0 }, "tower_piece", rotation, true);
        if (index + 1 < tower_count and random.nextBool()) anchor = piece;
    }
    frame.current = piece;
    frame.anchor = anchor;
    frame.stage = 1;
}

fn stepBridge(
    scratch: *Scratch,
    count: *u16,
    random: *legacy.Random,
    frame: *Frame,
    child_result: bool,
    ship_generated: *bool,
) Action {
    if (frame.stage == 1) {
        if (!child_result) return .{ .done = false };
        addBridgeEnd(scratch, count, frame);
        return .{ .done = true };
    }
    const rotation = pieceRotation(scratch, frame.parent);
    var piece = addRelative(scratch, count, frame.parent, .{ .x = 0, .y = 0, .z = -4 }, "bridge_piece", rotation, true);
    scratch.pieces[piece].chain = -1;
    var rise: i32 = 0;
    for (0..random.nextBounded(4) + 1) |_| {
        if (random.nextBool()) {
            piece = addRelative(scratch, count, piece, .{ .x = 0, .y = rise, .z = -4 }, "bridge_piece", rotation, true);
            rise = 0;
        } else {
            const steep = random.nextBool();
            piece = addRelative(scratch, count, piece, .{ .x = 0, .y = rise, .z = if (steep) -4 else -8 }, if (steep) "bridge_steep_stairs" else "bridge_gentle_stairs", rotation, true);
            rise = 4;
        }
    }
    frame.current = piece;
    frame.rise = rise;
    if (!ship_generated.* and random.nextBounded(@as(u32, 10 - frame.depth)) == 0) {
        _ = addRelative(scratch, count, piece, .{ .x = -8 + random.nextBoundedI32(8), .y = rise, .z = -70 + random.nextBoundedI32(10) }, "ship", rotation, true);
        ship_generated.* = true;
        addBridgeEnd(scratch, count, frame);
        return .{ .done = true };
    }
    frame.stage = 1;
    return .{ .call = .{ .part = .building, .depth = frame.depth + 1, .parent = piece, .relative = .{ .x = -3, .y = rise + 1, .z = -11 } } };
}

fn addBridgeEnd(scratch: *Scratch, count: *u16, frame: *const Frame) void {
    const rotation = compose(pieceRotation(scratch, frame.current), .clockwise_180);
    const piece = addRelative(scratch, count, frame.current, .{ .x = 4, .y = frame.rise, .z = 0 }, "bridge_end", rotation, true);
    scratch.pieces[piece].chain = -1;
}

fn stepFatTower(scratch: *Scratch, count: *u16, random: *legacy.Random, frame: *Frame) Action {
    if (frame.stage == 0) {
        initializeFatTower(scratch, count, frame);
        frame.stage = 1;
    }
    if (frame.stage == 1) {
        if (frame.count >= 2 or random.nextBounded(3) == 0) {
            _ = addRelative(scratch, count, frame.current, .{ .x = -2, .y = 8, .z = -2 }, "fat_tower_top", pieceRotation(scratch, frame.current), true);
            return .{ .done = true };
        }
        frame.current = addRelative(scratch, count, frame.current, .{ .x = 0, .y = 8, .z = 0 }, "fat_tower_middle", pieceRotation(scratch, frame.current), true);
        frame.count += 1;
        frame.index = 0;
        frame.stage = 2;
    }
    while (frame.index < fat_attachments.len) {
        const attachment = fat_attachments[frame.index];
        frame.index += 1;
        if (!random.nextBool()) continue;
        const rotation = compose(pieceRotation(scratch, frame.current), attachment.rotation);
        const bridge = addRelative(scratch, count, frame.current, attachment.position, "bridge_end", rotation, true);
        return .{ .call = .{ .part = .bridge, .depth = frame.depth + 1, .parent = bridge, .relative = .{ .x = 0, .y = 0, .z = 0 } } };
    }
    frame.stage = 1;
    return .again;
}

fn initializeFatTower(scratch: *Scratch, count: *u16, frame: *Frame) void {
    const rotation = pieceRotation(scratch, frame.parent);
    var piece = addRelative(scratch, count, frame.parent, .{ .x = -3, .y = 4, .z = -3 }, "fat_tower_base", rotation, true);
    piece = addRelative(scratch, count, piece, .{ .x = 0, .y = 4, .z = 0 }, "fat_tower_middle", rotation, true);
    frame.current = piece;
    frame.stage = 1;
    frame.index = 0;
    frame.count = 0;
}

const Attachment = struct { rotation: Rotation, position: Position };
const small_attachments = [_]Attachment{
    .{ .rotation = .none, .position = .{ .x = 1, .y = -1, .z = 0 } },
    .{ .rotation = .clockwise_90, .position = .{ .x = 6, .y = -1, .z = 1 } },
    .{ .rotation = .counterclockwise_90, .position = .{ .x = 0, .y = -1, .z = 5 } },
    .{ .rotation = .clockwise_180, .position = .{ .x = 5, .y = -1, .z = 6 } },
};
const fat_attachments = [_]Attachment{
    .{ .rotation = .none, .position = .{ .x = 4, .y = -1, .z = 0 } },
    .{ .rotation = .clockwise_90, .position = .{ .x = 12, .y = -1, .z = 4 } },
    .{ .rotation = .counterclockwise_90, .position = .{ .x = 0, .y = -1, .z = 8 } },
    .{ .rotation = .clockwise_180, .position = .{ .x = 8, .y = -1, .z = 12 } },
};

fn finishFrame(scratch: *Scratch, count: *u16, random: *legacy.Random, frame: Frame, success: bool) bool {
    if (!success) {
        count.* = frame.start;
        return false;
    }
    const chain: i32 = @bitCast(random.next(32));
    for (scratch.pieces[frame.start..count.*]) |*piece| piece.chain = chain;
    for (scratch.pieces[frame.start..count.*]) |piece| {
        for (scratch.pieces[frame.existing_start..frame.start]) |existing| {
            if (!piece.box.intersects(existing.box)) continue;
            if (existing.chain == scratch.pieces[frame.parent].chain) break;
            count.* = frame.start;
            return false;
        }
    }
    return true;
}

fn addAbsolute(scratch: *Scratch, count: *u16, name: []const u8, origin: Position, rotation: Rotation, place_air: bool) u16 {
    std.debug.assert(count.* < scratch.pieces.len);
    var id_buffer: [96]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buffer, "minecraft:end_city/{s}", .{name}) catch unreachable;
    const template = structures.vanilla.find(id) orelse unreachable;
    const index = count.*;
    scratch.pieces[index] = .{
        .template = template,
        .origin = origin,
        .rotation = rotation,
        .box = structures.templateBox(template, origin, rotation),
        .place_air = place_air,
    };
    count.* += 1;
    return index;
}

fn addRelative(scratch: *Scratch, count: *u16, parent: u16, relative: Position, name: []const u8, rotation: Rotation, place_air: bool) u16 {
    const transformed = structures.rotate(relative, scratch.pieces[parent].rotation);
    const parent_origin = scratch.pieces[parent].origin;
    return addAbsolute(scratch, count, name, .{
        .x = parent_origin.x + transformed.x,
        .y = parent_origin.y + transformed.y,
        .z = parent_origin.z + transformed.z,
    }, rotation, place_air);
}

fn pieceRotation(scratch: *const Scratch, piece: u16) Rotation {
    return scratch.pieces[piece].rotation;
}

fn compose(left: Rotation, right: Rotation) Rotation {
    const turns: u8 = @as(u8, @intFromEnum(left)) + @as(u8, @intFromEnum(right));
    return @enumFromInt(@mod(turns, 4));
}

fn placeCity(chunk_x: i32, chunk_z: i32, blocks: []base.Block, scratch: *Scratch, city: City) void {
    for (city.pieces) |piece| {
        var view = structures.TemplateView.init(piece.template, &scratch.nodes, &scratch.nbt_stack) catch unreachable;
        var palette = view.palette() catch unreachable;
        var state_buffer: [256]u8 = undefined;
        var palette_count: usize = 0;
        while (palette.next(&state_buffer) catch unreachable) |state| {
            std.debug.assert(palette_count < scratch.palette.len);
            scratch.palette[palette_count] = state;
            palette_count += 1;
        }
        placePieceBlocks(chunk_x, chunk_z, blocks, scratch, piece, view, palette_count);
    }
}

fn placePieceBlocks(
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,
    scratch: *Scratch,
    piece: Piece,
    view: structures.TemplateView,
    palette_count: usize,
) void {
    var iterator = view.blocks() catch unreachable;
    var state_buffer: [256]u8 = undefined;
    while (iterator.next() catch unreachable) |block| {
        std.debug.assert(block.state < palette_count);
        var state = scratch.palette[block.state];
        if (state.block() == .structure_block or state.block() == .structure_void) continue;
        if (state.block() == .air and !piece.place_air) continue;
        state = structures.rotateState(state, piece.rotation, &state_buffer);
        const offset = structures.rotate(.{ .x = block.position[0], .y = block.position[1], .z = block.position[2] }, piece.rotation);
        setBlock(chunk_x, chunk_z, blocks, .{
            .x = piece.origin.x + offset.x,
            .y = piece.origin.y + offset.y,
            .z = piece.origin.z + offset.z,
        }, state);
    }
}

fn setBlock(chunk_x: i32, chunk_z: i32, blocks: []base.Block, position: Position, state: minecraft.State) void {
    if (position.y < 0 or position.y >= world_height) return;
    const offset_x = @divFloor(position.x, width) - chunk_x;
    const offset_z = @divFloor(position.z, width) - chunk_z;
    if (offset_x != 0 or offset_z != 0) return;
    const local_x: usize = @intCast(@mod(position.x, width));
    const local_z: usize = @intCast(@mod(position.z, width));
    const local_y: usize = @intCast(position.y);
    blocks[4 * chunk_block_count + local_y * width * width + local_z * width + local_x] = .{ .feature = state };
}

test "End city graph uses bounded explicit frames" {
    try std.testing.expect(maximum_frames > 8);
    try std.testing.expect(maximum_pieces >= 128);
}
