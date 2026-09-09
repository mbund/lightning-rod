const std = @import("std");
const minecraft = @import("minecraft_registry");
const base = @import("base_dimension.zig");
const legacy = @import("legacy_noise.zig");
const structures = @import("structures.zig");

const maximum_pieces = 512;

pub const Kind = enum(u4) {
    start,
    bridge,
    bridge_crossing,
    bridge_end,
    bridge_platform,
    bridge_small_crossing,
    bridge_stairs,
    corridor_balcony,
    corridor_crossing,
    corridor_exit,
    corridor_left_turn,
    corridor_nether_warts_room,
    corridor_right_turn,
    corridor_stairs,
    small_corridor,
};

pub const Facing = enum(u2) { north, east, south, west };

pub const Piece = struct {
    kind: Kind,
    box: structures.Box,
    facing: Facing,
    chain_length: u8,
    seed: i32 = 0,
    contains_chest: bool = false,
};

pub const Plan = struct { pieces: []const Piece };

const width = 16;
const world_height = 256;
const chunk_block_count = width * width * world_height;

pub const Scratch = struct {
    pieces: [maximum_pieces]Piece,
    pending: [maximum_pieces]u16,
    bridge: [bridge_types.len]Choice,
    corridor: [corridor_types.len]Choice,
};

const Choice = struct {
    kind: Kind,
    weight: u8,
    limit: u8,
    generated: u8 = 0,
    repeatable: bool = false,
    active: bool = true,
};

const bridge_types = [_]Choice{
    .{ .kind = .bridge, .weight = 30, .limit = 0, .repeatable = true },
    .{ .kind = .bridge_crossing, .weight = 10, .limit = 4 },
    .{ .kind = .bridge_small_crossing, .weight = 10, .limit = 4 },
    .{ .kind = .bridge_stairs, .weight = 10, .limit = 3 },
    .{ .kind = .bridge_platform, .weight = 5, .limit = 2 },
    .{ .kind = .corridor_exit, .weight = 5, .limit = 1 },
};

const corridor_types = [_]Choice{
    .{ .kind = .small_corridor, .weight = 25, .limit = 0, .repeatable = true },
    .{ .kind = .corridor_crossing, .weight = 15, .limit = 5 },
    .{ .kind = .corridor_right_turn, .weight = 5, .limit = 10 },
    .{ .kind = .corridor_left_turn, .weight = 5, .limit = 10 },
    .{ .kind = .corridor_stairs, .weight = 10, .limit = 3, .repeatable = true },
    .{ .kind = .corridor_balcony, .weight = 7, .limit = 2 },
    .{ .kind = .corridor_nether_warts_room, .weight = 5, .limit = 2 },
};

pub fn generate(world_seed: u64, start: structures.ChunkPos, scratch: *Scratch) ?Plan {
    if (!structures.nether_complexes.isStart(@bitCast(world_seed), start)) return null;
    var selection = legacy.Random.init(0);
    selection.setCarverSeed(@bitCast(world_seed), start.x, start.z);
    if (selection.nextBounded(5) >= 2) return null;

    var source = legacy.Random.init(0);
    source.setCarverSeed(@bitCast(world_seed), start.x, start.z);
    scratch.bridge = bridge_types;
    scratch.corridor = corridor_types;
    const facing: Facing = @enumFromInt(source.nextBounded(4));
    scratch.pieces[0] = .{
        .kind = .start,
        .box = createRootBox(start.x * 16 + 2, start.z * 16 + 2, facing),
        .facing = facing,
        .chain_length = 0,
    };
    var piece_count: usize = 1;
    var pending_count: usize = 0;
    var last_kind: ?Kind = null;
    fillOpenings(&source, scratch, 0, &piece_count, &pending_count, &last_kind);
    while (pending_count != 0) {
        const pending_index = source.nextBounded(@intCast(pending_count));
        const piece_index = scratch.pending[pending_index];
        pending_count -= 1;
        if (pending_index != pending_count)
            std.mem.copyForwards(u16, scratch.pending[pending_index..pending_count], scratch.pending[pending_index + 1 .. pending_count + 1]);
        fillOpenings(&source, scratch, piece_index, &piece_count, &pending_count, &last_kind);
    }
    shiftInto(&source, scratch.pieces[0..piece_count], 48, 70);
    return .{ .pieces = scratch.pieces[0..piece_count] };
}

fn fillOpenings(
    source: *legacy.Random,
    scratch: *Scratch,
    piece_index: u16,
    piece_count: *usize,
    pending_count: *usize,
    last_kind: *?Kind,
) void {
    const piece = scratch.pieces[piece_index];
    switch (piece.kind) {
        .start, .bridge_crossing => {
            addForward(source, scratch, piece, 8, 3, false, piece_count, pending_count, last_kind);
            addNorthWest(source, scratch, piece, 3, 8, false, piece_count, pending_count, last_kind);
            addSouthEast(source, scratch, piece, 3, 8, false, piece_count, pending_count, last_kind);
        },
        .bridge => addForward(source, scratch, piece, 1, 3, false, piece_count, pending_count, last_kind),
        .bridge_small_crossing => {
            addForward(source, scratch, piece, 2, 0, false, piece_count, pending_count, last_kind);
            addNorthWest(source, scratch, piece, 0, 2, false, piece_count, pending_count, last_kind);
            addSouthEast(source, scratch, piece, 0, 2, false, piece_count, pending_count, last_kind);
        },
        .bridge_stairs => addSouthEast(source, scratch, piece, 6, 2, false, piece_count, pending_count, last_kind),
        .corridor_exit => addForward(source, scratch, piece, 5, 3, true, piece_count, pending_count, last_kind),
        .small_corridor, .corridor_stairs => addForward(source, scratch, piece, 1, 0, true, piece_count, pending_count, last_kind),
        .corridor_crossing => {
            addForward(source, scratch, piece, 1, 0, true, piece_count, pending_count, last_kind);
            addNorthWest(source, scratch, piece, 0, 1, true, piece_count, pending_count, last_kind);
            addSouthEast(source, scratch, piece, 0, 1, true, piece_count, pending_count, last_kind);
        },
        .corridor_right_turn => addSouthEast(source, scratch, piece, 0, 1, true, piece_count, pending_count, last_kind),
        .corridor_left_turn => addNorthWest(source, scratch, piece, 0, 1, true, piece_count, pending_count, last_kind),
        .corridor_nether_warts_room => {
            addForward(source, scratch, piece, 5, 3, true, piece_count, pending_count, last_kind);
            addForward(source, scratch, piece, 5, 11, true, piece_count, pending_count, last_kind);
        },
        .corridor_balcony => {
            const offset: i32 = if (piece.facing == .west or piece.facing == .north) 5 else 1;
            addNorthWest(source, scratch, piece, 0, offset, source.nextBounded(8) > 0, piece_count, pending_count, last_kind);
            addSouthEast(source, scratch, piece, 0, offset, source.nextBounded(8) > 0, piece_count, pending_count, last_kind);
        },
        .bridge_end, .bridge_platform => {},
    }
}

fn addForward(source: *legacy.Random, scratch: *Scratch, piece: Piece, side: i32, up: i32, inside: bool, piece_count: *usize, pending_count: *usize, last: *?Kind) void {
    const request = switch (piece.facing) {
        .north => Request{ .x = piece.box.minimum.x + side, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z - 1, .facing = .north },
        .south => Request{ .x = piece.box.minimum.x + side, .y = piece.box.minimum.y + up, .z = piece.box.maximum.z + 1, .facing = .south },
        .west => Request{ .x = piece.box.minimum.x - 1, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z + side, .facing = .west },
        .east => Request{ .x = piece.box.maximum.x + 1, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z + side, .facing = .east },
    };
    addRequested(source, scratch, piece, request, inside, piece_count, pending_count, last);
}

fn addNorthWest(source: *legacy.Random, scratch: *Scratch, piece: Piece, up: i32, side: i32, inside: bool, piece_count: *usize, pending_count: *usize, last: *?Kind) void {
    const request = switch (piece.facing) {
        .north, .south => Request{ .x = piece.box.minimum.x - 1, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z + side, .facing = .west },
        .west, .east => Request{ .x = piece.box.minimum.x + side, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z - 1, .facing = .north },
    };
    addRequested(source, scratch, piece, request, inside, piece_count, pending_count, last);
}

fn addSouthEast(source: *legacy.Random, scratch: *Scratch, piece: Piece, up: i32, side: i32, inside: bool, piece_count: *usize, pending_count: *usize, last: *?Kind) void {
    const request = switch (piece.facing) {
        .north, .south => Request{ .x = piece.box.maximum.x + 1, .y = piece.box.minimum.y + up, .z = piece.box.minimum.z + side, .facing = .east },
        .west, .east => Request{ .x = piece.box.minimum.x + side, .y = piece.box.minimum.y + up, .z = piece.box.maximum.z + 1, .facing = .south },
    };
    addRequested(source, scratch, piece, request, inside, piece_count, pending_count, last);
}

const Request = struct { x: i32, y: i32, z: i32, facing: Facing };

fn addRequested(source: *legacy.Random, scratch: *Scratch, parent: Piece, request: Request, inside: bool, piece_count: *usize, pending_count: *usize, last: *?Kind) void {
    const root = scratch.pieces[0].box;
    const within = @abs(request.x - root.minimum.x) <= 112 and
        @abs(request.z - root.minimum.z) <= 112;
    if (!within) {
        _ = createPiece(source, .bridge_end, request, parent.chain_length, scratch.pieces[0..piece_count.*]);
        return;
    }
    const chain = parent.chain_length + 1;
    const piece = pickPiece(source, scratch, request, chain, inside, scratch.pieces[0..piece_count.*], last) orelse
        createPiece(source, .bridge_end, request, chain, scratch.pieces[0..piece_count.*]) orelse return;
    std.debug.assert(piece_count.* < scratch.pieces.len);
    std.debug.assert(pending_count.* < scratch.pending.len);
    scratch.pieces[piece_count.*] = piece;
    scratch.pending[pending_count.*] = @intCast(piece_count.*);
    piece_count.* += 1;
    pending_count.* += 1;
}

fn pickPiece(source: *legacy.Random, scratch: *Scratch, request: Request, chain: u8, inside: bool, pieces: []const Piece, last: *?Kind) ?Piece {
    const choices = if (inside) scratch.corridor[0..] else scratch.bridge[0..];
    var total: u32 = 0;
    var limited_remaining = false;
    for (choices) |choice| if (choice.active) {
        total += choice.weight;
        if (choice.limit > 0 and choice.generated < choice.limit) limited_remaining = true;
    };
    if (!limited_remaining or chain > 30) return null;
    for (0..5) |_| {
        var selected: i32 = @intCast(source.nextBounded(total));
        for (choices) |*choice| {
            if (!choice.active) continue;
            selected -= choice.weight;
            if (selected >= 0) continue;
            if ((choice.limit != 0 and choice.generated >= choice.limit) or
                (last.* == choice.kind and !choice.repeatable)) break;
            const piece = createPiece(source, choice.kind, request, chain, pieces) orelse continue;
            choice.generated += 1;
            last.* = choice.kind;
            if (choice.limit != 0 and choice.generated >= choice.limit) choice.active = false;
            return piece;
        }
    }
    return null;
}

fn createPiece(source: *legacy.Random, kind: Kind, request: Request, chain: u8, pieces: []const Piece) ?Piece {
    const shape = shapeFor(kind);
    const box = rotatedBox(request, shape);
    if (box.minimum.y <= 10) return null;
    for (pieces) |piece| if (piece.box.intersects(box)) return null;
    var result = Piece{ .kind = kind, .box = box, .facing = request.facing, .chain_length = chain };
    switch (kind) {
        .bridge_end => result.seed = @bitCast(source.next(32)),
        .corridor_left_turn, .corridor_right_turn => result.contains_chest = source.nextBounded(3) == 0,
        else => {},
    }
    return result;
}

const Shape = struct { offset_x: i32, offset_y: i32, offset_z: i32, size_x: i32, size_y: i32, size_z: i32 };

fn shapeFor(kind: Kind) Shape {
    return switch (kind) {
        .bridge => .{ .offset_x = -1, .offset_y = -3, .offset_z = 0, .size_x = 5, .size_y = 10, .size_z = 19 },
        .bridge_crossing, .start => .{ .offset_x = -8, .offset_y = -3, .offset_z = 0, .size_x = 19, .size_y = 10, .size_z = 19 },
        .bridge_end => .{ .offset_x = -1, .offset_y = -3, .offset_z = 0, .size_x = 5, .size_y = 10, .size_z = 8 },
        .bridge_platform => .{ .offset_x = -2, .offset_y = 0, .offset_z = 0, .size_x = 7, .size_y = 8, .size_z = 9 },
        .bridge_small_crossing => .{ .offset_x = -2, .offset_y = 0, .offset_z = 0, .size_x = 7, .size_y = 9, .size_z = 7 },
        .bridge_stairs => .{ .offset_x = -2, .offset_y = 0, .offset_z = 0, .size_x = 7, .size_y = 11, .size_z = 7 },
        .corridor_balcony => .{ .offset_x = -3, .offset_y = 0, .offset_z = 0, .size_x = 9, .size_y = 7, .size_z = 9 },
        .corridor_crossing, .corridor_left_turn, .corridor_right_turn, .small_corridor => .{ .offset_x = -1, .offset_y = 0, .offset_z = 0, .size_x = 5, .size_y = 7, .size_z = 5 },
        .corridor_exit, .corridor_nether_warts_room => .{ .offset_x = -5, .offset_y = -3, .offset_z = 0, .size_x = 13, .size_y = 14, .size_z = 13 },
        .corridor_stairs => .{ .offset_x = -1, .offset_y = -7, .offset_z = 0, .size_x = 5, .size_y = 14, .size_z = 10 },
    };
}

fn rotatedBox(request: Request, shape: Shape) structures.Box {
    return switch (request.facing) {
        .south => boundingBox(request.x + shape.offset_x, request.y + shape.offset_y, request.z + shape.offset_z, shape.size_x, shape.size_y, shape.size_z),
        .north => boundingBox(request.x + shape.offset_x, request.y + shape.offset_y, request.z - shape.size_z + 1 + shape.offset_z, shape.size_x, shape.size_y, shape.size_z),
        .west => boundingBox(request.x - shape.size_z + 1 + shape.offset_z, request.y + shape.offset_y, request.z + shape.offset_x, shape.size_z, shape.size_y, shape.size_x),
        .east => boundingBox(request.x + shape.offset_z, request.y + shape.offset_y, request.z + shape.offset_x, shape.size_z, shape.size_y, shape.size_x),
    };
}

fn createRootBox(x: i32, z: i32, facing: Facing) structures.Box {
    return if (facing == .north or facing == .south)
        boundingBox(x, 64, z, 19, 10, 19)
    else
        boundingBox(x, 64, z, 19, 10, 19);
}

fn boundingBox(x: i32, y: i32, z: i32, size_x: i32, size_y: i32, size_z: i32) structures.Box {
    return .{
        .minimum = .{ .x = x, .y = y, .z = z },
        .maximum = .{ .x = x + size_x - 1, .y = y + size_y - 1, .z = z + size_z - 1 },
    };
}

fn shiftInto(source: *legacy.Random, pieces: []Piece, minimum_y: i32, maximum_y: i32) void {
    var bounds = pieces[0].box;
    for (pieces[1..]) |piece| {
        bounds.minimum.y = @min(bounds.minimum.y, piece.box.minimum.y);
        bounds.maximum.y = @max(bounds.maximum.y, piece.box.maximum.y);
    }
    const available = maximum_y - minimum_y + 1 - (bounds.maximum.y - bounds.minimum.y + 1);
    const target = if (available > 1) minimum_y + source.nextBoundedI32(available) else minimum_y;
    const offset = target - bounds.minimum.y;
    for (pieces) |*piece| {
        piece.box.minimum.y += offset;
        piece.box.maximum.y += offset;
    }
}

pub fn place(plan: Plan, chunk_x: i32, chunk_z: i32, blocks: []base.Block) void {
    std.debug.assert(blocks.len == 9 * chunk_block_count);
    for (plan.pieces) |piece| {
        var renderer = Renderer{ .piece = piece, .chunk_x = chunk_x, .chunk_z = chunk_z, .blocks = blocks };
        renderPiece(&renderer);
    }
}

const Renderer = struct {
    piece: Piece,
    chunk_x: i32,
    chunk_z: i32,
    blocks: []base.Block,

    fn fill(self: *Renderer, minimum: [3]i32, maximum: [3]i32, state: minecraft.State) void {
        var y = minimum[1];
        while (y <= maximum[1]) : (y += 1) {
            var z = minimum[2];
            while (z <= maximum[2]) : (z += 1) {
                var x = minimum[0];
                while (x <= maximum[0]) : (x += 1) self.set(x, y, z, state);
            }
        }
    }

    fn set(self: *Renderer, x: i32, y: i32, z: i32, state: minecraft.State) void {
        const position = self.worldPosition(x, y, z);
        const index = regionIndex(self.chunk_x, self.chunk_z, position) orelse return;
        var buffer: [256]u8 = undefined;
        const mirrored = structures.mirrorState(state, self.mirror(), &buffer);
        self.blocks[index] = .{ .feature = structures.rotateState(mirrored, self.rotation(), &buffer) };
    }

    fn down(self: *Renderer, x: i32, z: i32) void {
        var position = self.worldPosition(x, -1, z);
        while (position.y > 1) : (position.y -= 1) {
            const index = regionIndex(self.chunk_x, self.chunk_z, position) orelse return;
            if (!replaceable(self.blocks[index])) return;
            self.blocks[index] = .{ .feature = minecraft.defaultState(.nether_bricks) };
        }
    }

    fn worldPosition(self: Renderer, x: i32, y: i32, z: i32) structures.Position {
        return .{
            .x = switch (self.piece.facing) {
                .north, .south => self.piece.box.minimum.x + x,
                .west => self.piece.box.maximum.x - z,
                .east => self.piece.box.minimum.x + z,
            },
            .y = self.piece.box.minimum.y + y,
            .z = switch (self.piece.facing) {
                .north => self.piece.box.maximum.z - z,
                .south => self.piece.box.minimum.z + z,
                .west, .east => self.piece.box.minimum.z + x,
            },
        };
    }

    fn rotation(self: Renderer) structures.Rotation {
        return switch (self.piece.facing) {
            .north, .south => .none,
            .east => .clockwise_90,
            .west => .clockwise_90,
        };
    }

    fn mirror(self: Renderer) structures.Mirror {
        return switch (self.piece.facing) {
            .north, .east => .none,
            .south, .west => .left_right,
        };
    }
};

fn renderPiece(renderer: *Renderer) void {
    switch (renderer.piece.kind) {
        .start, .bridge_crossing => renderBridgeCrossing(renderer),
        .bridge => renderBridge(renderer),
        .bridge_end => renderBridgeEnd(renderer),
        .bridge_platform => renderBridgePlatform(renderer),
        .bridge_small_crossing => renderBridgeSmallCrossing(renderer),
        .bridge_stairs => renderBridgeStairs(renderer),
        .corridor_balcony => renderCorridorBalcony(renderer),
        .corridor_crossing => renderCorridorCrossing(renderer),
        .corridor_exit => renderCorridorExit(renderer),
        .corridor_left_turn => renderCorridorTurn(renderer, false),
        .corridor_nether_warts_room => renderWartsRoom(renderer),
        .corridor_right_turn => renderCorridorTurn(renderer, true),
        .corridor_stairs => renderCorridorStairs(renderer),
        .small_corridor => renderSmallCorridor(renderer),
    }
}

fn fill(renderer: *Renderer, x0: i32, y0: i32, z0: i32, x1: i32, y1: i32, z1: i32, state: minecraft.State) void {
    renderer.fill(.{ x0, y0, z0 }, .{ x1, y1, z1 }, state);
}

fn air() minecraft.State {
    return minecraft.defaultState(.air);
}

fn bricks() minecraft.State {
    return minecraft.defaultState(.nether_bricks);
}

fn fence(arguments: []const u8) minecraft.State {
    var buffer: [256]u8 = undefined;
    return minecraft.parseBlockArgument(arguments, &buffer) orelse unreachable;
}

fn replaceable(block: base.Block) bool {
    return switch (block) {
        .air, .cave_air, .fluid => true,
        .feature => |state| state.block() == .air or state.block() == .cave_air or state.block() == .lava,
        .solid, .surface => false,
    };
}

fn regionIndex(chunk_x: i32, chunk_z: i32, position: structures.Position) ?usize {
    if (position.y < 0 or position.y >= world_height) return null;
    const offset_x = @divFloor(position.x, width) - chunk_x;
    const offset_z = @divFloor(position.z, width) - chunk_z;
    if (offset_x != 0 or offset_z != 0) return null;
    const local_x: usize = @intCast(@mod(position.x, width));
    const local_z: usize = @intCast(@mod(position.z, width));
    const local_y: usize = @intCast(position.y);
    return 4 * chunk_block_count + local_y * 256 + local_z * 16 + local_x;
}

fn renderBridge(renderer: *Renderer) void {
    const wall_east = fence("minecraft:nether_brick_fence[east=true,north=true,south=true]");
    const wall_west = fence("minecraft:nether_brick_fence[north=true,south=true,west=true]");
    fill(renderer, 0, 3, 0, 4, 4, 18, bricks());
    fill(renderer, 1, 5, 0, 3, 7, 18, air());
    fill(renderer, 0, 5, 0, 0, 5, 18, bricks());
    fill(renderer, 4, 5, 0, 4, 5, 18, bricks());
    fill(renderer, 0, 2, 0, 4, 2, 5, bricks());
    fill(renderer, 0, 2, 13, 4, 2, 18, bricks());
    fill(renderer, 0, 0, 0, 4, 1, 3, bricks());
    fill(renderer, 0, 0, 15, 4, 1, 18, bricks());
    for (0..5) |x| for (0..3) |z| {
        renderer.down(@intCast(x), @intCast(z));
        renderer.down(@intCast(x), 18 - @as(i32, @intCast(z)));
    };
    for ([_]i32{ 1, 4, 14, 17 }) |z| {
        const low: i32 = if (z == 1 or z == 17) 1 else 3;
        fill(renderer, 0, low, z, 0, 4, z, wall_east);
        fill(renderer, 4, low, z, 4, 4, z, wall_west);
    }
}

fn renderBridgeCrossing(renderer: *Renderer) void {
    fill(renderer, 7, 3, 0, 11, 4, 18, bricks());
    fill(renderer, 0, 3, 7, 18, 4, 11, bricks());
    fill(renderer, 8, 5, 0, 10, 7, 18, air());
    fill(renderer, 0, 5, 8, 18, 7, 10, air());
    fill(renderer, 7, 5, 0, 7, 5, 7, bricks());
    fill(renderer, 7, 5, 11, 7, 5, 18, bricks());
    fill(renderer, 11, 5, 0, 11, 5, 7, bricks());
    fill(renderer, 11, 5, 11, 11, 5, 18, bricks());
    fill(renderer, 0, 5, 7, 7, 5, 7, bricks());
    fill(renderer, 11, 5, 7, 18, 5, 7, bricks());
    fill(renderer, 0, 5, 11, 7, 5, 11, bricks());
    fill(renderer, 11, 5, 11, 18, 5, 11, bricks());
    bridgeCrossingSupport(renderer, 7, 11, 0, 18);
    bridgeCrossingSupport(renderer, 0, 18, 7, 11);
}

fn bridgeCrossingSupport(renderer: *Renderer, x0: i32, x1: i32, z0: i32, z1: i32) void {
    fill(renderer, x0, 2, z0, x1, 2, if (z0 == 0) 5 else z1, bricks());
    if (z0 == 0) {
        fill(renderer, x0, 2, 13, x1, 2, 18, bricks());
        fill(renderer, x0, 0, 0, x1, 1, 3, bricks());
        fill(renderer, x0, 0, 15, x1, 1, 18, bricks());
        var x = x0;
        while (x <= x1) : (x += 1) for (0..3) |z| {
            renderer.down(x, @intCast(z));
            renderer.down(x, 18 - @as(i32, @intCast(z)));
        };
    } else {
        fill(renderer, 13, 2, z0, 18, 2, z1, bricks());
        fill(renderer, 0, 0, z0, 3, 1, z1, bricks());
        fill(renderer, 15, 0, z0, 18, 1, z1, bricks());
        for (0..3) |x| {
            var z = z0;
            while (z <= z1) : (z += 1) {
                renderer.down(@intCast(x), z);
                renderer.down(18 - @as(i32, @intCast(x)), z);
            }
        }
    }
}

fn renderBridgeEnd(renderer: *Renderer) void {
    var source = legacy.Random.init(renderer.piece.seed);
    for (0..5) |x| for (3..5) |y|
        fill(renderer, @intCast(x), @intCast(y), 0, @intCast(x), @intCast(y), source.nextBoundedI32(8), bricks());
    fill(renderer, 0, 5, 0, 0, 5, source.nextBoundedI32(8), bricks());
    fill(renderer, 4, 5, 0, 4, 5, source.nextBoundedI32(8), bricks());
    for (0..5) |x| fill(renderer, @intCast(x), 2, 0, @intCast(x), 2, source.nextBoundedI32(5), bricks());
    for (0..5) |x| for (0..2) |y|
        fill(renderer, @intCast(x), @intCast(y), 0, @intCast(x), @intCast(y), source.nextBoundedI32(3), bricks());
}

fn renderBridgeSmallCrossing(renderer: *Renderer) void {
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    fill(renderer, 0, 0, 0, 6, 1, 6, bricks());
    fill(renderer, 0, 2, 0, 6, 7, 6, air());
    fill(renderer, 0, 2, 0, 1, 6, 0, bricks());
    fill(renderer, 0, 2, 6, 1, 6, 6, bricks());
    fill(renderer, 5, 2, 0, 6, 6, 0, bricks());
    fill(renderer, 5, 2, 6, 6, 6, 6, bricks());
    fill(renderer, 0, 2, 0, 0, 6, 1, bricks());
    fill(renderer, 0, 2, 5, 0, 6, 6, bricks());
    fill(renderer, 6, 2, 0, 6, 6, 1, bricks());
    fill(renderer, 6, 2, 5, 6, 6, 6, bricks());
    fill(renderer, 2, 6, 0, 4, 6, 0, bricks());
    fill(renderer, 2, 5, 0, 4, 5, 0, fence_x);
    fill(renderer, 2, 6, 6, 4, 6, 6, bricks());
    fill(renderer, 2, 5, 6, 4, 5, 6, fence_x);
    fill(renderer, 0, 6, 2, 0, 6, 4, bricks());
    fill(renderer, 0, 5, 2, 0, 5, 4, fence_z);
    fill(renderer, 6, 6, 2, 6, 6, 4, bricks());
    fill(renderer, 6, 5, 2, 6, 5, 4, fence_z);
    for (0..7) |x| for (0..7) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderSmallCorridor(renderer: *Renderer) void {
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    fill(renderer, 0, 0, 0, 4, 1, 4, bricks());
    fill(renderer, 0, 2, 0, 4, 5, 4, air());
    fill(renderer, 0, 2, 0, 0, 5, 4, bricks());
    fill(renderer, 4, 2, 0, 4, 5, 4, bricks());
    for ([_]i32{ 1, 3 }) |z| {
        fill(renderer, 0, 3, z, 0, 4, z, fence_z);
        fill(renderer, 4, 3, z, 4, 4, z, fence_z);
    }
    fill(renderer, 0, 6, 0, 4, 6, 4, bricks());
    for (0..5) |x| for (0..5) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderCorridorCrossing(renderer: *Renderer) void {
    fill(renderer, 0, 0, 0, 4, 1, 4, bricks());
    fill(renderer, 0, 2, 0, 4, 5, 4, air());
    fill(renderer, 0, 2, 0, 0, 5, 0, bricks());
    fill(renderer, 4, 2, 0, 4, 5, 0, bricks());
    fill(renderer, 0, 2, 4, 0, 5, 4, bricks());
    fill(renderer, 4, 2, 4, 4, 5, 4, bricks());
    fill(renderer, 0, 6, 0, 4, 6, 4, bricks());
    for (0..5) |x| for (0..5) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderCorridorTurn(renderer: *Renderer, right: bool) void {
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    fill(renderer, 0, 0, 0, 4, 1, 4, bricks());
    fill(renderer, 0, 2, 0, 4, 5, 4, air());
    const wall_x: i32 = if (right) 0 else 4;
    fill(renderer, wall_x, 2, 0, wall_x, 5, 4, bricks());
    const front_x: i32 = if (right) 4 else 0;
    fill(renderer, front_x, 2, 0, front_x, 5, 0, bricks());
    fill(renderer, if (right) 1 else 0, 2, 4, if (right) 4 else 3, 5, 4, bricks());
    fill(renderer, wall_x, 3, 1, wall_x, 4, 1, fence_z);
    fill(renderer, wall_x, 3, 3, wall_x, 4, 3, fence_z);
    fill(renderer, 1, 3, 4, 1, 4, 4, fence_x);
    fill(renderer, 3, 3, 4, 3, 4, 4, fence_x);
    fill(renderer, 0, 6, 0, 4, 6, 4, bricks());
    if (renderer.piece.contains_chest) renderer.set(if (right) 1 else 3, 2, 3, minecraft.defaultState(.chest));
    for (0..5) |x| for (0..5) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderBridgeStairs(renderer: *Renderer) void {
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    fill(renderer, 0, 0, 0, 6, 1, 6, bricks());
    fill(renderer, 0, 2, 0, 6, 10, 6, air());
    fill(renderer, 0, 2, 0, 1, 8, 0, bricks());
    fill(renderer, 5, 2, 0, 6, 8, 0, bricks());
    fill(renderer, 0, 2, 1, 0, 8, 6, bricks());
    fill(renderer, 6, 2, 1, 6, 8, 6, bricks());
    fill(renderer, 1, 2, 6, 5, 8, 6, bricks());
    fill(renderer, 0, 3, 2, 0, 5, 4, fence_z);
    fill(renderer, 6, 3, 2, 6, 5, 2, fence_z);
    fill(renderer, 6, 3, 4, 6, 5, 4, fence_z);
    renderer.set(5, 2, 5, bricks());
    fill(renderer, 4, 2, 5, 4, 3, 5, bricks());
    fill(renderer, 3, 2, 5, 3, 4, 5, bricks());
    fill(renderer, 2, 2, 5, 2, 5, 5, bricks());
    fill(renderer, 1, 2, 5, 1, 6, 5, bricks());
    fill(renderer, 1, 7, 1, 5, 7, 4, bricks());
    fill(renderer, 6, 8, 2, 6, 8, 4, air());
    fill(renderer, 2, 6, 0, 4, 8, 0, bricks());
    fill(renderer, 2, 5, 0, 4, 5, 0, fence_x);
    for (0..7) |x| for (0..7) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderCorridorBalcony(renderer: *Renderer) void {
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    fill(renderer, 0, 0, 0, 8, 1, 8, bricks());
    fill(renderer, 0, 2, 0, 8, 5, 8, air());
    fill(renderer, 0, 6, 0, 8, 6, 5, bricks());
    fill(renderer, 0, 2, 0, 2, 5, 0, bricks());
    fill(renderer, 6, 2, 0, 8, 5, 0, bricks());
    fill(renderer, 1, 3, 0, 1, 4, 0, fence_x);
    fill(renderer, 7, 3, 0, 7, 4, 0, fence_x);
    fill(renderer, 0, 2, 4, 8, 2, 8, bricks());
    fill(renderer, 1, 1, 4, 2, 2, 4, air());
    fill(renderer, 6, 1, 4, 7, 2, 4, air());
    fill(renderer, 1, 3, 8, 7, 3, 8, fence_x);
    renderer.set(0, 3, 8, fence("minecraft:nether_brick_fence[east=true,south=true]"));
    renderer.set(8, 3, 8, fence("minecraft:nether_brick_fence[south=true,west=true]"));
    fill(renderer, 0, 3, 6, 0, 3, 7, fence_z);
    fill(renderer, 8, 3, 6, 8, 3, 7, fence_z);
    fill(renderer, 0, 3, 4, 0, 5, 5, bricks());
    fill(renderer, 8, 3, 4, 8, 5, 5, bricks());
    fill(renderer, 1, 3, 5, 2, 5, 5, bricks());
    fill(renderer, 6, 3, 5, 7, 5, 5, bricks());
    fill(renderer, 1, 4, 5, 1, 5, 5, fence_x);
    fill(renderer, 7, 4, 5, 7, 5, 5, fence_x);
    for (0..6) |z| for (0..9) |x| renderer.down(@intCast(x), @intCast(z));
}

fn renderCorridorStairs(renderer: *Renderer) void {
    var state_buffer: [256]u8 = undefined;
    const stair = minecraft.parseBlockArgument("minecraft:nether_brick_stairs[facing=south]", &state_buffer) orelse unreachable;
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    for (0..10) |index| {
        const z: i32 = @intCast(index);
        const floor_y = @max(1, 7 - z);
        const roof_y = @min(@max(floor_y + 5, 14 - z), 13);
        fill(renderer, 0, 0, z, 4, floor_y, z, bricks());
        fill(renderer, 1, floor_y + 1, z, 3, roof_y - 1, z, air());
        if (z <= 6) fill(renderer, 1, floor_y + 1, z, 3, floor_y + 1, z, stair);
        fill(renderer, 0, roof_y, z, 4, roof_y, z, bricks());
        fill(renderer, 0, floor_y + 1, z, 0, roof_y - 1, z, bricks());
        fill(renderer, 4, floor_y + 1, z, 4, roof_y - 1, z, bricks());
        if ((z & 1) == 0) {
            fill(renderer, 0, floor_y + 2, z, 0, floor_y + 3, z, fence_z);
            fill(renderer, 4, floor_y + 2, z, 4, floor_y + 3, z, fence_z);
        }
        for (0..5) |x| renderer.down(@intCast(x), z);
    }
}

fn renderBridgePlatform(renderer: *Renderer) void {
    fill(renderer, 0, 2, 0, 6, 7, 7, air());
    fill(renderer, 1, 0, 0, 5, 1, 7, bricks());
    fill(renderer, 1, 2, 1, 5, 2, 7, bricks());
    fill(renderer, 1, 3, 2, 5, 3, 7, bricks());
    fill(renderer, 1, 4, 3, 5, 4, 7, bricks());
    fill(renderer, 1, 2, 0, 1, 4, 2, bricks());
    fill(renderer, 5, 2, 0, 5, 4, 2, bricks());
    fill(renderer, 1, 5, 2, 1, 5, 3, bricks());
    fill(renderer, 5, 5, 2, 5, 5, 3, bricks());
    fill(renderer, 0, 5, 3, 0, 5, 8, bricks());
    fill(renderer, 6, 5, 3, 6, 5, 8, bricks());
    fill(renderer, 1, 5, 8, 5, 5, 8, bricks());
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    renderer.set(1, 6, 3, fence("minecraft:nether_brick_fence[west=true]"));
    renderer.set(5, 6, 3, fence("minecraft:nether_brick_fence[east=true]"));
    renderer.set(0, 6, 3, fence("minecraft:nether_brick_fence[east=true,north=true]"));
    renderer.set(6, 6, 3, fence("minecraft:nether_brick_fence[north=true,west=true]"));
    fill(renderer, 0, 6, 4, 0, 6, 7, fence_z);
    fill(renderer, 6, 6, 4, 6, 6, 7, fence_z);
    renderer.set(0, 6, 8, fence("minecraft:nether_brick_fence[east=true,south=true]"));
    renderer.set(6, 6, 8, fence("minecraft:nether_brick_fence[south=true,west=true]"));
    fill(renderer, 1, 6, 8, 5, 6, 8, fence_x);
    renderer.set(1, 7, 8, fence("minecraft:nether_brick_fence[east=true]"));
    fill(renderer, 2, 7, 8, 4, 7, 8, fence_x);
    renderer.set(5, 7, 8, fence("minecraft:nether_brick_fence[west=true]"));
    renderer.set(2, 8, 8, fence("minecraft:nether_brick_fence[east=true]"));
    renderer.set(3, 8, 8, fence_x);
    renderer.set(4, 8, 8, fence("minecraft:nether_brick_fence[west=true]"));
    renderer.set(3, 5, 5, minecraft.defaultState(.spawner));
    for (0..7) |x| for (0..7) |z| renderer.down(@intCast(x), @intCast(z));
}

fn renderCorridorExit(renderer: *Renderer) void {
    renderLargeRoomShell(renderer);
    fill(renderer, 4, 2, 0, 8, 2, 12, bricks());
    fill(renderer, 0, 2, 4, 12, 2, 8, bricks());
    fill(renderer, 4, 0, 0, 8, 1, 3, bricks());
    fill(renderer, 4, 0, 9, 8, 1, 12, bricks());
    fill(renderer, 0, 0, 4, 3, 1, 8, bricks());
    fill(renderer, 9, 0, 4, 12, 1, 8, bricks());
    fill(renderer, 5, 5, 5, 7, 5, 7, bricks());
    fill(renderer, 6, 1, 6, 6, 4, 6, air());
    renderer.set(6, 0, 6, bricks());
    renderer.set(6, 5, 6, minecraft.defaultState(.lava));
    largeRoomSupports(renderer);
}

fn renderWartsRoom(renderer: *Renderer) void {
    renderLargeRoomShell(renderer);
    var buffer: [256]u8 = undefined;
    const stair_north = minecraft.parseBlockArgument("minecraft:nether_brick_stairs[facing=north]", &buffer) orelse unreachable;
    for (0..7) |j_usize| {
        const j: i32 = @intCast(j_usize);
        const z = j + 4;
        fill(renderer, 5, 5 + j, z, 7, 5 + j, z, stair_north);
        if (z <= 8) fill(renderer, 5, 5, z, 7, j + 4, z, bricks()) else fill(renderer, 5, 8, z, 7, j + 4, z, bricks());
        if (j >= 1) fill(renderer, 5, 6 + j, z, 7, 9 + j, z, air());
    }
    fill(renderer, 5, 12, 11, 7, 12, 11, stair_north);
    fill(renderer, 5, 6, 7, 5, 7, 7, fence("minecraft:nether_brick_fence[east=true,north=true,south=true]"));
    fill(renderer, 7, 6, 7, 7, 7, 7, fence("minecraft:nether_brick_fence[north=true,south=true,west=true]"));
    fill(renderer, 5, 13, 12, 7, 13, 12, air());
    fill(renderer, 2, 5, 2, 3, 5, 3, bricks());
    fill(renderer, 2, 5, 9, 3, 5, 10, bricks());
    fill(renderer, 2, 5, 4, 2, 5, 8, bricks());
    fill(renderer, 9, 5, 2, 10, 5, 3, bricks());
    fill(renderer, 9, 5, 9, 10, 5, 10, bricks());
    fill(renderer, 10, 5, 4, 10, 5, 8, bricks());
    var stair_buffer: [256]u8 = undefined;
    const stair_east = minecraft.parseBlockArgument("minecraft:nether_brick_stairs[facing=east]", &stair_buffer) orelse unreachable;
    const stair_west = minecraft.parseBlockArgument("minecraft:nether_brick_stairs[facing=west]", &stair_buffer) orelse unreachable;
    for ([_]i32{ 2, 3, 9, 10 }) |z| {
        renderer.set(4, 5, z, stair_west);
        renderer.set(8, 5, z, stair_east);
    }
    fill(renderer, 3, 4, 4, 4, 4, 8, minecraft.defaultState(.soul_sand));
    fill(renderer, 8, 4, 4, 9, 4, 8, minecraft.defaultState(.soul_sand));
    fill(renderer, 3, 5, 4, 4, 5, 8, minecraft.defaultState(.nether_wart));
    fill(renderer, 8, 5, 4, 9, 5, 8, minecraft.defaultState(.nether_wart));
    largeRoomSupports(renderer);
}

fn renderLargeRoomShell(renderer: *Renderer) void {
    fill(renderer, 0, 3, 0, 12, 4, 12, bricks());
    fill(renderer, 0, 5, 0, 12, 13, 12, air());
    fill(renderer, 0, 5, 0, 1, 12, 12, bricks());
    fill(renderer, 11, 5, 0, 12, 12, 12, bricks());
    fill(renderer, 2, 5, 11, 4, 12, 12, bricks());
    fill(renderer, 8, 5, 11, 10, 12, 12, bricks());
    fill(renderer, 5, 9, 11, 7, 12, 12, bricks());
    fill(renderer, 2, 5, 0, 4, 12, 1, bricks());
    fill(renderer, 8, 5, 0, 10, 12, 1, bricks());
    fill(renderer, 5, 9, 0, 7, 12, 1, bricks());
    fill(renderer, 2, 11, 2, 10, 12, 10, bricks());
    const fence_x = fence("minecraft:nether_brick_fence[east=true,west=true]");
    const fence_z = fence("minecraft:nether_brick_fence[north=true,south=true]");
    var edge: i32 = 1;
    while (edge <= 11) : (edge += 2) {
        fill(renderer, edge, 10, 0, edge, 11, 0, fence_x);
        fill(renderer, edge, 10, 12, edge, 11, 12, fence_x);
        fill(renderer, 0, 10, edge, 0, 11, edge, fence_z);
        fill(renderer, 12, 10, edge, 12, 11, edge, fence_z);
        renderer.set(edge, 13, 0, bricks());
        renderer.set(edge, 13, 12, bricks());
        renderer.set(0, 13, edge, bricks());
        renderer.set(12, 13, edge, bricks());
        if (edge != 11) {
            renderer.set(edge + 1, 13, 0, fence_x);
            renderer.set(edge + 1, 13, 12, fence_x);
            renderer.set(0, 13, edge + 1, fence_z);
            renderer.set(12, 13, edge + 1, fence_z);
        }
    }
    renderer.set(0, 13, 0, fence("minecraft:nether_brick_fence[east=true,north=true]"));
    renderer.set(0, 13, 12, fence("minecraft:nether_brick_fence[east=true,south=true]"));
    renderer.set(12, 13, 12, fence("minecraft:nether_brick_fence[south=true,west=true]"));
    renderer.set(12, 13, 0, fence("minecraft:nether_brick_fence[north=true,west=true]"));
    var side: i32 = 3;
    while (side <= 9) : (side += 2) {
        fill(renderer, 1, 7, side, 1, 8, side, fence("minecraft:nether_brick_fence[north=true,south=true,west=true]"));
        fill(renderer, 11, 7, side, 11, 8, side, fence("minecraft:nether_brick_fence[east=true,north=true,south=true]"));
    }
}

fn largeRoomSupports(renderer: *Renderer) void {
    for (4..9) |x| for (0..3) |z| {
        renderer.down(@intCast(x), @intCast(z));
        renderer.down(@intCast(x), 12 - @as(i32, @intCast(z)));
    };
    for (0..3) |x| for (4..9) |z| {
        renderer.down(@intCast(x), @intCast(z));
        renderer.down(12 - @as(i32, @intCast(x)), @intCast(z));
    };
}

test "fortress graph matches Vanilla reference" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);
    const plan = generate(6409272458699751175, .{ .x = 494564, .z = -60601 }, scratch) orelse return error.ExpectedFortress;
    try std.testing.expectEqual(structures.Box{
        .minimum = .{ .x = 7_913_026, .y = 52, .z = -969_614 },
        .maximum = .{ .x = 7_913_044, .y = 61, .z = -969_596 },
    }, plan.pieces[0].box);
    try std.testing.expectEqual(@as(usize, 157), plan.pieces.len);
}

test "fortress block states use Vanilla mirror then rotation" {
    const blocks = try std.testing.allocator.alloc(base.Block, 9 * chunk_block_count);
    defer std.testing.allocator.free(blocks);
    @memset(blocks, .air);
    var renderer = Renderer{
        .piece = .{
            .kind = .bridge,
            .box = .{
                .minimum = .{ .x = 0, .y = 64, .z = 0 },
                .maximum = .{ .x = 15, .y = 79, .z = 15 },
            },
            .facing = .south,
            .chain_length = 0,
        },
        .chunk_x = 0,
        .chunk_z = 0,
        .blocks = blocks,
    };
    renderer.set(0, 0, 0, fence("minecraft:nether_brick_fence[east=true,north=true,south=true]"));
    const index = regionIndex(0, 0, .{ .x = 0, .y = 64, .z = 0 }).?;
    try std.testing.expectEqualStrings(
        "minecraft:nether_brick_fence[east=true,north=true,south=true,waterlogged=false,west=false]",
        switch (blocks[index]) {
            .feature => |state| state.canonicalName(),
            else => return error.ExpectedFortressFence,
        },
    );
}
