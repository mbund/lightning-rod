const std = @import("std");
const biome = @import("biome.zig");
const climate = @import("climate.zig");
const feature = @import("feature.zig");
const generated_state = @import("generated_state.zig");
const legacy = @import("legacy_noise.zig");
const random = @import("random.zig");
const structures = @import("structures.zig");

pub const Locator = struct {
    pub const count = 128;
    pub const distance = 32;
    pub const spread = 3;

    positions: [count]ChunkPos = undefined,
    ready: bool = false,

    pub fn invalidate(self: *Locator) void {
        self.ready = false;
    }

    pub fn prepare(
        self: *Locator,
        world_seed: u64,
        sampler: *const climate.Sampler,
        cache: *biome.Cache,
    ) void {
        if (self.ready) return;

        var source = random.Xoroshiro.init(world_seed);
        var angle = source.nextF64() * std.math.tau;
        var ring: i32 = 0;
        var in_ring: i32 = 0;
        var ring_spread: i32 = spread;

        for (&self.positions, 0..) |*position, index| {
            const radius = 4 * distance + distance * ring * 6 +
                @as(i32, @intFromFloat(@round((source.nextF64() - 0.5) * (distance * 2.5))));
            const x: i32 = @intFromFloat(@round(@cos(angle) * @as(f64, @floatFromInt(radius))));
            const z: i32 = @intFromFloat(@round(@sin(angle) * @as(f64, @floatFromInt(radius))));
            var relocation = source.split();
            position.* = relocate(x, z, sampler, cache, &relocation);

            angle += std.math.tau / @as(f64, @floatFromInt(ring_spread));
            in_ring += 1;
            if (in_ring != ring_spread) continue;
            ring += 1;
            in_ring = 0;
            ring_spread += @divTrunc(2 * ring_spread, ring + 1);
            ring_spread = @min(ring_spread, count - @as(i32, @intCast(index)));
            angle += source.nextF64() * std.math.tau;
        }
        self.ready = true;
    }

    pub fn contains(self: *const Locator, chunk: ChunkPos) bool {
        std.debug.assert(self.ready);
        for (self.positions) |position| if (position.eql(chunk)) return true;
        return false;
    }

    pub fn nearest(self: *const Locator, chunk: ChunkPos) ChunkPos {
        std.debug.assert(self.ready);
        var result = self.positions[0];
        var distance_squared = result.distanceSquared(chunk);
        for (self.positions[1..]) |position| {
            const candidate = position.distanceSquared(chunk);
            if (candidate >= distance_squared) continue;
            result = position;
            distance_squared = candidate;
        }
        return result;
    }
};

pub const ChunkPos = struct {
    x: i32,
    z: i32,

    fn eql(self: ChunkPos, other: ChunkPos) bool {
        return self.x == other.x and self.z == other.z;
    }

    fn distanceSquared(self: ChunkPos, other: ChunkPos) i64 {
        const x = @as(i64, self.x) - other.x;
        const z = @as(i64, self.z) - other.z;
        return x * x + z * z;
    }
};

pub const Plan = struct {
    pub const maximum_pieces = 512;

    pieces: [maximum_pieces]Piece = undefined,
    count: usize = 0,
    portal_piece: ?u16 = null,

    pub fn slice(self: *const Plan) []const Piece {
        return self.pieces[0..self.count];
    }

    fn mutableSlice(self: *Plan) []Piece {
        return self.pieces[0..self.count];
    }
};

pub const Facing = enum(u2) { north, east, south, west };

pub const Kind = enum(u4) {
    start,
    corridor,
    prison_hall,
    left_turn,
    right_turn,
    square_room,
    stairs,
    spiral_staircase,
    five_way_crossing,
    chest_corridor,
    library,
    portal_room,
    small_corridor,
};

pub const Entrance = enum(u2) { opening, wood_door, grates, iron_door };

pub const Piece = struct {
    kind: Kind,
    box: structures.Box,
    facing: Facing,
    chain: u8,
    entrance: Entrance = .opening,
    flags: u8 = 0,
    size_y: u8 = 0,
};

const Choice = struct {
    kind: Kind,
    weight: u8,
    limit: u8,
    generated: u8 = 0,
    active: bool = true,
};

const choices = [_]Choice{
    .{ .kind = .corridor, .weight = 40, .limit = 0 },
    .{ .kind = .prison_hall, .weight = 5, .limit = 5 },
    .{ .kind = .left_turn, .weight = 20, .limit = 0 },
    .{ .kind = .right_turn, .weight = 20, .limit = 0 },
    .{ .kind = .square_room, .weight = 10, .limit = 6 },
    .{ .kind = .stairs, .weight = 5, .limit = 5 },
    .{ .kind = .spiral_staircase, .weight = 5, .limit = 5 },
    .{ .kind = .five_way_crossing, .weight = 5, .limit = 4 },
    .{ .kind = .chest_corridor, .weight = 5, .limit = 4 },
    .{ .kind = .library, .weight = 10, .limit = 2 },
    .{ .kind = .portal_room, .weight = 20, .limit = 1 },
};

pub fn generatePlan(world_seed: u64, start: ChunkPos, output: *Plan) void {
    var retry: i64 = 0;
    while (true) : (retry += 1) {
        var source = legacy.Random.init(0);
        source.setCarverSeed(@as(i64, @bitCast(world_seed)) +% retry, start.x, start.z);
        buildPlan(&source, start, output);
        if (output.portal_piece != null) return;
    }
}

fn buildPlan(source: *legacy.Random, start: ChunkPos, output: *Plan) void {
    var available = choices;
    var pending: [Plan.maximum_pieces]u16 = undefined;
    var pending_count: usize = 0;
    var active: ?Kind = .five_way_crossing;
    var last: ?Kind = null;
    output.* = .{};

    const root_facing: Facing = @enumFromInt(source.nextBounded(4));
    const root_x = start.x * 16 + 2;
    const root_z = start.z * 16 + 2;
    const root_width: i32 = if (root_facing == .north or root_facing == .south) 5 else 5;
    const root_length: i32 = root_width;
    output.pieces[0] = .{
        .kind = .start,
        .box = .{ .minimum = .{ .x = root_x, .y = 64, .z = root_z }, .maximum = .{ .x = root_x + root_width - 1, .y = 74, .z = root_z + root_length - 1 } },
        .facing = root_facing,
        .chain = 0,
    };
    output.count = 1;
    appendOpening(source, output, &available, &active, &last, &pending, &pending_count, 0, .forward, 1, 1);

    while (pending_count != 0) {
        const index: usize = source.nextBounded(@intCast(pending_count));
        const piece_index = pending[index];
        pending_count -= 1;
        if (index != pending_count) pending[index] = pending[pending_count];
        appendOpenings(source, output, &available, &active, &last, &pending, &pending_count, piece_index);
    }
    shiftInto(source, output.mutableSlice(), 63, -64, 10);
}

const Opening = enum { forward, northwest, southeast };
const Request = struct { x: i32, y: i32, z: i32, facing: Facing };
const Shape = struct { x: i32, y: i32, z: i32, width: i32, height: i32, length: i32 };

fn appendOpenings(source: *legacy.Random, output: *Plan, available: *[choices.len]Choice, active: *?Kind, last: *?Kind, pending: *[Plan.maximum_pieces]u16, pending_count: *usize, index: u16) void {
    const piece = output.pieces[index];
    switch (piece.kind) {
        .start, .spiral_staircase => appendOpening(source, output, available, active, last, pending, pending_count, index, .forward, 1, 1),
        .corridor => {
            appendOpening(source, output, available, active, last, pending, pending_count, index, .forward, 1, 1);
            if (piece.flags & 1 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .northwest, 1, 2);
            if (piece.flags & 2 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .southeast, 1, 2);
        },
        .prison_hall, .stairs, .chest_corridor => appendOpening(source, output, available, active, last, pending, pending_count, index, .forward, 1, 1),
        .left_turn => appendOpening(source, output, available, active, last, pending, pending_count, index, if (piece.facing == .north or piece.facing == .east) .northwest else .southeast, 1, 1),
        .right_turn => appendOpening(source, output, available, active, last, pending, pending_count, index, if (piece.facing == .north or piece.facing == .east) .southeast else .northwest, 1, 1),
        .square_room => {
            appendOpening(source, output, available, active, last, pending, pending_count, index, .forward, 1, 4);
            appendOpening(source, output, available, active, last, pending, pending_count, index, .northwest, 1, 4);
            appendOpening(source, output, available, active, last, pending, pending_count, index, .southeast, 1, 4);
        },
        .five_way_crossing => {
            const left_low: i32 = if (piece.facing == .north or piece.facing == .west) 5 else 3;
            const left_high: i32 = if (piece.facing == .north or piece.facing == .west) 3 else 5;
            appendOpening(source, output, available, active, last, pending, pending_count, index, .forward, 1, 5);
            if (piece.flags & 1 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .northwest, 1, left_low);
            if (piece.flags & 2 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .northwest, 7, left_high);
            if (piece.flags & 4 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .southeast, 1, left_low);
            if (piece.flags & 8 != 0) appendOpening(source, output, available, active, last, pending, pending_count, index, .southeast, 7, left_high);
        },
        .library, .portal_room, .small_corridor => {},
    }
}

fn appendOpening(source: *legacy.Random, output: *Plan, available: *[choices.len]Choice, active: *?Kind, last: *?Kind, pending: *[Plan.maximum_pieces]u16, pending_count: *usize, parent_index: u16, opening: Opening, height: i32, side: i32) void {
    const parent = output.pieces[parent_index];
    const request = openingRequest(parent, opening, height, side);
    const root = output.pieces[0].box.minimum;
    if (@abs(request.x - root.x) > 112 or @abs(request.z - root.z) > 112) return;
    const chain = parent.chain + 1;
    if (chain > 50 or output.count == output.pieces.len) return;
    const piece = selectPiece(source, output, available, active, last, request, chain) orelse return;
    const index: u16 = @intCast(output.count);
    output.pieces[output.count] = piece;
    output.count += 1;
    if (piece.kind == .portal_room) output.portal_piece = index;
    if (piece.kind == .portal_room) return;
    std.debug.assert(pending_count.* < pending.len);
    pending[pending_count.*] = index;
    pending_count.* += 1;
}

fn openingRequest(parent: Piece, opening: Opening, height: i32, side: i32) Request {
    return switch (opening) {
        .forward => switch (parent.facing) {
            .north => .{ .x = parent.box.minimum.x + side, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z - 1, .facing = .north },
            .south => .{ .x = parent.box.minimum.x + side, .y = parent.box.minimum.y + height, .z = parent.box.maximum.z + 1, .facing = .south },
            .west => .{ .x = parent.box.minimum.x - 1, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z + side, .facing = .west },
            .east => .{ .x = parent.box.maximum.x + 1, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z + side, .facing = .east },
        },
        .northwest => switch (parent.facing) {
            .north, .south => .{ .x = parent.box.minimum.x - 1, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z + side, .facing = .west },
            .west, .east => .{ .x = parent.box.minimum.x + side, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z - 1, .facing = .north },
        },
        .southeast => switch (parent.facing) {
            .north, .south => .{ .x = parent.box.maximum.x + 1, .y = parent.box.minimum.y + height, .z = parent.box.minimum.z + side, .facing = .east },
            .west, .east => .{ .x = parent.box.minimum.x + side, .y = parent.box.minimum.y + height, .z = parent.box.maximum.z + 1, .facing = .south },
        },
    };
}

fn selectPiece(source: *legacy.Random, output: *const Plan, available: *[choices.len]Choice, active: *?Kind, last: *?Kind, request: Request, chain: u8) ?Piece {
    var total: u32 = 0;
    var remaining_limited = false;
    for (available) |choice| {
        if (!choice.active) continue;
        total += choice.weight;
        if (choice.limit != 0 and choice.generated < choice.limit) remaining_limited = true;
    }
    if (!remaining_limited) return null;
    if (active.*) |kind| {
        active.* = null;
        if (createPiece(source, kind, request, chain, output.slice())) |piece| return piece;
    }
    for (0..5) |_| {
        var selected: i32 = @intCast(source.nextBounded(@intCast(total)));
        for (available) |*choice| {
            if (!choice.active) continue;
            selected -= choice.weight;
            if (selected >= 0) continue;
            const minimum_chain: u8 = if (choice.kind == .library) 5 else if (choice.kind == .portal_room) 6 else 0;
            if ((choice.limit != 0 and choice.generated >= choice.limit) or last.* == choice.kind or chain < minimum_chain) break;
            const piece = createPiece(source, choice.kind, request, chain, output.slice()) orelse continue;
            choice.generated += 1;
            if (choice.limit != 0 and choice.generated == choice.limit) choice.active = false;
            last.* = choice.kind;
            return piece;
        }
    }
    return createSmallCorridor(request, chain, output.slice());
}

fn createPiece(source: *legacy.Random, kind: Kind, request: Request, chain: u8, existing: []const Piece) ?Piece {
    var shape = shapeFor(kind);
    var box = rotatedBox(request, shape);
    if (kind == .library) {
        if (!validBox(box, existing)) {
            shape.height = 6;
            box = rotatedBox(request, shape);
            if (!validBox(box, existing)) return null;
        }
    } else if (!validBox(box, existing)) return null;
    var piece = Piece{ .kind = kind, .box = box, .facing = request.facing, .chain = chain, .size_y = @intCast(shape.height) };
    if (kind != .portal_room) piece.entrance = randomEntrance(source);
    switch (kind) {
        .corridor => piece.flags = @intFromBool(source.nextBounded(2) == 0) | (@as(u8, @intFromBool(source.nextBounded(2) == 0)) << 1),
        .five_way_crossing => piece.flags = @intFromBool(source.nextBool()) | (@as(u8, @intFromBool(source.nextBool())) << 1) | (@as(u8, @intFromBool(source.nextBool())) << 2) | (@as(u8, @intFromBool(source.nextBounded(3) > 0)) << 3),
        .square_room => piece.flags = @intCast(source.nextBounded(5)),
        else => {},
    }
    return piece;
}

fn createSmallCorridor(request: Request, chain: u8, existing: []const Piece) ?Piece {
    const box = rotatedBox(request, .{ .x = -1, .y = -1, .z = 0, .width = 5, .height = 5, .length = 4 });
    const intersecting = firstIntersection(box, existing) orelse return null;
    if (intersecting.box.minimum.y != box.minimum.y) return null;
    var length: i32 = 2;
    while (length >= 1) : (length -= 1) {
        const candidate = rotatedBox(request, .{ .x = -1, .y = -1, .z = 0, .width = 5, .height = 5, .length = length });
        if (intersecting.box.intersects(candidate)) continue;
        const final_length = length + 1;
        return .{
            .kind = .small_corridor,
            .box = rotatedBox(request, .{ .x = -1, .y = -1, .z = 0, .width = 5, .height = 5, .length = final_length }),
            .facing = request.facing,
            .chain = chain,
            .size_y = @intCast(final_length),
        };
    }
    return null;
}

fn shapeFor(kind: Kind) Shape {
    return switch (kind) {
        .corridor, .chest_corridor => .{ .x = -1, .y = -1, .z = 0, .width = 5, .height = 5, .length = 7 },
        .prison_hall => .{ .x = -1, .y = -1, .z = 0, .width = 9, .height = 5, .length = 11 },
        .left_turn, .right_turn => .{ .x = -1, .y = -1, .z = 0, .width = 5, .height = 5, .length = 5 },
        .square_room => .{ .x = -4, .y = -1, .z = 0, .width = 11, .height = 7, .length = 11 },
        .stairs => .{ .x = -1, .y = -7, .z = 0, .width = 5, .height = 11, .length = 8 },
        .spiral_staircase => .{ .x = -1, .y = -7, .z = 0, .width = 5, .height = 11, .length = 5 },
        .five_way_crossing => .{ .x = -4, .y = -3, .z = 0, .width = 10, .height = 9, .length = 11 },
        .library => .{ .x = -4, .y = -1, .z = 0, .width = 14, .height = 11, .length = 15 },
        .portal_room => .{ .x = -4, .y = -1, .z = 0, .width = 11, .height = 8, .length = 16 },
        .start, .small_corridor => unreachable,
    };
}

fn rotatedBox(request: Request, shape: Shape) structures.Box {
    const minimum: structures.Position = switch (request.facing) {
        .south => structures.Position{ .x = request.x + shape.x, .y = request.y + shape.y, .z = request.z + shape.z },
        .north => .{ .x = request.x + shape.x, .y = request.y + shape.y, .z = request.z - shape.length + 1 + shape.z },
        .west => .{ .x = request.x - shape.length + 1 + shape.z, .y = request.y + shape.y, .z = request.z + shape.x },
        .east => .{ .x = request.x + shape.z, .y = request.y + shape.y, .z = request.z + shape.x },
    };
    const size_x = if (request.facing == .north or request.facing == .south) shape.width else shape.length;
    const size_z = if (request.facing == .north or request.facing == .south) shape.length else shape.width;
    return .{ .minimum = minimum, .maximum = .{ .x = minimum.x + size_x - 1, .y = minimum.y + shape.height - 1, .z = minimum.z + size_z - 1 } };
}

fn validBox(box: structures.Box, existing: []const Piece) bool {
    return box.minimum.y > 10 and firstIntersection(box, existing) == null;
}

fn firstIntersection(box: structures.Box, pieces: []const Piece) ?Piece {
    for (pieces) |piece| if (piece.box.intersects(box)) return piece;
    return null;
}

fn randomEntrance(source: *legacy.Random) Entrance {
    return switch (source.nextBounded(5)) {
        2 => .wood_door,
        3 => .grates,
        4 => .iron_door,
        else => .opening,
    };
}

fn shiftInto(source: *legacy.Random, pieces: []Piece, sea_level: i32, minimum_y: i32, top_penalty: i32) void {
    var bounds = pieces[0].box;
    for (pieces[1..]) |piece| {
        bounds.minimum.y = @min(bounds.minimum.y, piece.box.minimum.y);
        bounds.maximum.y = @max(bounds.maximum.y, piece.box.maximum.y);
    }
    const top = sea_level - top_penalty;
    var target = bounds.maximum.y - bounds.minimum.y + 1 + minimum_y + 1;
    if (target < top) target += source.nextBoundedI32(top - target);
    const offset = target - bounds.maximum.y;
    for (pieces) |*piece| {
        piece.box.minimum.y += offset;
        piece.box.maximum.y += offset;
    }
}

fn relocate(
    candidate_x: i32,
    candidate_z: i32,
    sampler: *const climate.Sampler,
    cache: *biome.Cache,
    source: *random.Xoroshiro,
) ChunkPos {
    const origin_x = candidate_x * 4 + 2;
    const origin_z = candidate_z * 4 + 2;
    var selected: ?ChunkPos = null;
    var matches: u32 = 0;
    var offset_z: i32 = -28;
    while (offset_z <= 28) : (offset_z += 1) {
        var offset_x: i32 = -28;
        while (offset_x <= 28) : (offset_x += 1) {
            const quart_x = origin_x + offset_x;
            const quart_z = origin_z + offset_z;
            const biome_index = cache.atQuart(sampler, quart_x, 0, quart_z);
            if (!preferredBiome(biome.name(biome_index))) continue;
            if (selected != null and source.nextBoundedI32(@intCast(matches + 1)) != 0) {
                matches += 1;
                continue;
            }
            selected = .{ .x = @divFloor(quart_x * 4, 16), .z = @divFloor(quart_z * 4, 16) };
            matches += 1;
        }
    }
    return selected orelse .{ .x = candidate_x, .z = candidate_z };
}

fn preferredBiome(name: []const u8) bool {
    const names = .{
        "minecraft:plains",                  "minecraft:sunflower_plains", "minecraft:snowy_plains",             "minecraft:ice_spikes",
        "minecraft:desert",                  "minecraft:forest",           "minecraft:flower_forest",            "minecraft:birch_forest",
        "minecraft:dark_forest",             "minecraft:pale_garden",      "minecraft:old_growth_birch_forest",  "minecraft:old_growth_pine_taiga",
        "minecraft:old_growth_spruce_taiga", "minecraft:taiga",            "minecraft:snowy_taiga",              "minecraft:savanna",
        "minecraft:savanna_plateau",         "minecraft:windswept_hills",  "minecraft:windswept_gravelly_hills", "minecraft:windswept_forest",
        "minecraft:windswept_savanna",       "minecraft:jungle",           "minecraft:sparse_jungle",            "minecraft:bamboo_jungle",
        "minecraft:badlands",                "minecraft:eroded_badlands",  "minecraft:wooded_badlands",          "minecraft:meadow",
        "minecraft:grove",                   "minecraft:snowy_slopes",     "minecraft:frozen_peaks",             "minecraft:jagged_peaks",
        "minecraft:stony_peaks",             "minecraft:mushroom_fields",  "minecraft:dripstone_caves",          "minecraft:lush_caves",
    };
    inline for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

pub fn apply(world_seed: u64, locator: *const Locator, region: *feature.Region) void {
    std.debug.assert(locator.ready);
    var placement_random = placementRandom(world_seed, region);
    for (locator.positions) |start| {
        if (@abs(start.x - region.center_chunk_x) > 8 or @abs(start.z - region.center_chunk_z) > 8)
            continue;
        placeStart(world_seed, start, region, &placement_random);
    }
}

pub fn applyAt(
    world_seed: u64,
    sampler: *const climate.Sampler,
    cache: *biome.Cache,
    region: *feature.Region,
) void {
    var source = random.Xoroshiro.init(world_seed);
    var angle = source.nextF64() * std.math.tau;
    var ring: i32 = 0;
    var in_ring: i32 = 0;
    var ring_spread: i32 = Locator.spread;
    var placement_random = placementRandom(world_seed, region);
    for (0..Locator.count) |index| {
        const radius = 4 * Locator.distance + Locator.distance * ring * 6 +
            @as(i32, @intFromFloat(@round((source.nextF64() - 0.5) * (Locator.distance * 2.5))));
        const x: i32 = @intFromFloat(@round(@cos(angle) * @as(f64, @floatFromInt(radius))));
        const z: i32 = @intFromFloat(@round(@sin(angle) * @as(f64, @floatFromInt(radius))));
        var relocation = source.split();
        if (@abs(x - region.center_chunk_x) <= 15 and
            @abs(z - region.center_chunk_z) <= 15)
        {
            const start = relocate(x, z, sampler, cache, &relocation);
            if (@abs(start.x - region.center_chunk_x) <= 8 and
                @abs(start.z - region.center_chunk_z) <= 8)
                placeStart(world_seed, start, region, &placement_random);
        }
        angle += std.math.tau / @as(f64, @floatFromInt(ring_spread));
        in_ring += 1;
        if (in_ring != ring_spread) continue;
        ring += 1;
        in_ring = 0;
        ring_spread += @divTrunc(2 * ring_spread, ring + 1);
        ring_spread = @min(ring_spread, Locator.count - @as(i32, @intCast(index)));
        angle += source.nextF64() * std.math.tau;
    }
}

fn placementRandom(world_seed: u64, region: *const feature.Region) random.ChunkRandom {
    const population_seed = random.ChunkRandom.populationSeed(
        world_seed,
        region.center_chunk_x * feature.width,
        region.center_chunk_z * feature.width,
    );
    return random.ChunkRandom.init(random.decoratorSeed(population_seed, 8, 4));
}

fn placeStart(world_seed: u64, start: ChunkPos, region: *feature.Region, source: *random.ChunkRandom) void {
    var plan: Plan = undefined;
    generatePlan(world_seed, start, &plan);
    const chunk_box = structures.Box{
        .minimum = .{ .x = region.center_chunk_x * feature.width, .y = feature.minimum_y, .z = region.center_chunk_z * feature.width },
        .maximum = .{ .x = region.center_chunk_x * feature.width + feature.width - 1, .y = feature.minimum_y + feature.height - 1, .z = region.center_chunk_z * feature.width + feature.width - 1 },
    };
    for (plan.slice()) |piece| {
        if (!piece.box.intersects(chunk_box)) continue;
        renderPiece(region, piece, source);
    }
}

const Renderer = struct {
    region: *feature.Region,
    piece: Piece,
    random: *random.ChunkRandom,

    fn set(self: Renderer, x: i32, y: i32, z: i32, block_state: generated_state.GeneratedState) void {
        const position = self.worldPosition(x, y, z);
        if (@divFloor(position.x, feature.width) != self.region.center_chunk_x or
            @divFloor(position.z, feature.width) != self.region.center_chunk_z)
            return;
        const target = self.region.state(position.x, position.y, position.z) orelse return;
        target.* = block_state;
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

    fn isAir(self: Renderer, x: i32, y: i32, z: i32) bool {
        const position = self.worldPosition(x, y, z);
        const block_state = self.region.stateConst(position.x, position.y, position.z) orelse return false;
        return block_state.nameEquals("minecraft:air") or block_state.nameEquals("minecraft:cave_air");
    }
};

fn renderPiece(region: *feature.Region, piece: Piece, placement_random: *random.ChunkRandom) void {
    const renderer = Renderer{ .region = region, .piece = piece, .random = placement_random };
    switch (piece.kind) {
        .start, .spiral_staircase => renderSpiral(renderer),
        .corridor => renderCorridor(renderer),
        .chest_corridor => renderChestCorridor(renderer),
        .prison_hall => renderPrisonHall(renderer),
        .left_turn => renderTurn(renderer, true),
        .right_turn => renderTurn(renderer, false),
        .square_room => renderSquareRoom(renderer),
        .stairs => renderStairs(renderer),
        .five_way_crossing => renderFiveWayCrossing(renderer),
        .library => renderLibrary(renderer),
        .small_corridor => renderSmallCorridor(renderer),
        .portal_room => renderPortalRoom(renderer),
    }
}

const Dimensions = struct { width: i32, height: i32, length: i32 };

fn renderShell(renderer: Renderer, dimensions: Dimensions, cant_replace_air: bool) void {
    var y: i32 = 0;
    while (y < dimensions.height) : (y += 1) {
        var x: i32 = 0;
        while (x < dimensions.width) : (x += 1) {
            var z: i32 = 0;
            while (z < dimensions.length) : (z += 1) {
                if (cant_replace_air and renderer.isAir(x, y, z)) continue;
                const boundary = x == 0 or z == 0 or y == 0 or x == dimensions.width - 1 or z == dimensions.length - 1 or y == dimensions.height - 1;
                renderer.set(x, y, z, if (boundary) randomStoneBrick(renderer.random) else cave_air);
            }
        }
    }
}

fn randomStoneBrick(source: *random.ChunkRandom) generated_state.GeneratedState {
    const value = source.nextF32();
    if (value < 0.2) return cracked_stone_bricks;
    if (value < 0.5) return mossy_stone_bricks;
    if (value < 0.55) return infested_stone_bricks;
    return stone_bricks;
}

fn randomOutline(renderer: Renderer, min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32) void {
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                const boundary = y == min_y or y == max_y or x == min_x or x == max_x or z == min_z or z == max_z;
                renderer.set(x, y, z, if (boundary) randomStoneBrick(renderer.random) else cave_air);
            }
        }
    }
}

fn renderSpiral(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 5, .height = 11, .length = 5 }, true);
    const entrance = if (renderer.piece.kind == .start) Entrance.opening else renderer.piece.entrance;
    carve(renderer, 1, 7, 0, 3, 3, entrance);
    carve(renderer, 1, 1, 4, 3, 3, .opening);
    renderSpiralStaircase(renderer);
}

fn renderCorridor(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 5, .height = 5, .length = 7 }, true);
    carve(renderer, 1, 1, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, 1, 1, 6, 3, 3, .opening);
    addWithRandomThreshold(renderer, 0.1, 1, 2, 1, wallTorch(renderer.piece.facing, .east));
    addWithRandomThreshold(renderer, 0.1, 3, 2, 1, wallTorch(renderer.piece.facing, .west));
    addWithRandomThreshold(renderer, 0.1, 1, 2, 5, wallTorch(renderer.piece.facing, .east));
    addWithRandomThreshold(renderer, 0.1, 3, 2, 5, wallTorch(renderer.piece.facing, .west));
    if (renderer.piece.flags & 1 != 0) carveSide(renderer, 0, 1, 2);
    if (renderer.piece.flags & 2 != 0) carveSide(renderer, 4, 1, 2);
}

fn renderChestCorridor(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 5, .height = 5, .length = 7 }, true);
    carve(renderer, 1, 1, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, 1, 1, 6, 3, 3, .opening);
    fill(renderer, 3, 1, 2, 3, 1, 4, stone_bricks);
    const slab = state("minecraft:stone_brick_slab[type=bottom,waterlogged=false]");
    renderer.set(3, 1, 1, slab);
    renderer.set(3, 1, 5, slab);
    renderer.set(3, 2, 2, slab);
    renderer.set(3, 2, 4, slab);
    fill(renderer, 2, 1, 2, 2, 1, 4, slab);
    placeChest(renderer, 3, 2, 3);
}

fn renderPrisonHall(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 9, .height = 5, .length = 11 }, true);
    carve(renderer, 1, 1, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, 1, 1, 10, 3, 3, .opening);
    randomOutline(renderer, 4, 1, 1, 4, 3, 1);
    randomOutline(renderer, 4, 1, 3, 4, 3, 3);
    randomOutline(renderer, 4, 1, 7, 4, 3, 7);
    randomOutline(renderer, 4, 1, 9, 4, 3, 9);
    var y: i32 = 1;
    while (y <= 3) : (y += 1) {
        renderer.set(4, y, 4, ironBars(renderer.piece.facing, true, false, true, false));
        renderer.set(4, y, 5, ironBars(renderer.piece.facing, true, true, true, false));
        renderer.set(4, y, 6, ironBars(renderer.piece.facing, true, false, true, false));
        fill(renderer, 5, y, 5, 7, y, 5, ironBars(renderer.piece.facing, false, true, false, true));
    }
    renderer.set(4, 3, 2, ironBars(renderer.piece.facing, true, false, true, false));
    renderer.set(4, 3, 8, ironBars(renderer.piece.facing, true, false, true, false));
    renderer.set(4, 1, 2, door(renderer.piece.facing, .west, false, false, .iron));
    renderer.set(4, 2, 2, door(renderer.piece.facing, .west, true, false, .iron));
    renderer.set(4, 1, 8, door(renderer.piece.facing, .west, false, false, .iron));
    renderer.set(4, 2, 8, door(renderer.piece.facing, .west, true, false, .iron));
}

fn renderSquareRoom(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 11, .height = 7, .length = 11 }, true);
    carve(renderer, 4, 1, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, 4, 1, 10, 3, 3, .opening);
    carveSide(renderer, 0, 1, 4);
    carveSide(renderer, 10, 1, 4);
    switch (renderer.piece.flags) {
        0 => renderSquarePillar(renderer),
        1 => renderSquareFountain(renderer),
        2 => renderSquareStore(renderer),
        3, 4 => {},
        else => unreachable,
    }
}

fn renderSquarePillar(renderer: Renderer) void {
    fill(renderer, 5, 1, 5, 5, 3, 5, stone_bricks);
    renderer.set(4, 3, 5, wallTorch(renderer.piece.facing, .west));
    renderer.set(6, 3, 5, wallTorch(renderer.piece.facing, .east));
    renderer.set(5, 3, 4, wallTorch(renderer.piece.facing, .south));
    renderer.set(5, 3, 6, wallTorch(renderer.piece.facing, .north));
    const slab = state("minecraft:smooth_stone_slab[type=bottom,waterlogged=false]");
    fill(renderer, 4, 1, 4, 4, 1, 6, slab);
    fill(renderer, 6, 1, 4, 6, 1, 6, slab);
    renderer.set(5, 1, 4, slab);
    renderer.set(5, 1, 6, slab);
}

fn renderSquareFountain(renderer: Renderer) void {
    var index: i32 = 0;
    while (index < 5) : (index += 1) {
        renderer.set(3, 1, 3 + index, stone_bricks);
        renderer.set(7, 1, 3 + index, stone_bricks);
        renderer.set(3 + index, 1, 3, stone_bricks);
        renderer.set(3 + index, 1, 7, stone_bricks);
    }
    fill(renderer, 5, 1, 5, 5, 3, 5, stone_bricks);
    renderer.set(5, 4, 5, generated_state.GeneratedState.water);
}

fn renderSquareStore(renderer: Renderer) void {
    var index: i32 = 1;
    while (index <= 9) : (index += 1) {
        renderer.set(1, 3, index, generated_state.GeneratedState.featureNamed("minecraft:cobblestone"));
        renderer.set(9, 3, index, generated_state.GeneratedState.featureNamed("minecraft:cobblestone"));
        renderer.set(index, 3, 1, generated_state.GeneratedState.featureNamed("minecraft:cobblestone"));
        renderer.set(index, 3, 9, generated_state.GeneratedState.featureNamed("minecraft:cobblestone"));
    }
    const cobble = state("minecraft:cobblestone");
    for ([_][2]i32{ .{ 5, 4 }, .{ 5, 6 }, .{ 4, 5 }, .{ 6, 5 } }) |position| {
        renderer.set(position[0], 1, position[1], cobble);
        renderer.set(position[0], 3, position[1], cobble);
    }
    for ([_][2]i32{ .{ 4, 4 }, .{ 6, 4 }, .{ 4, 6 }, .{ 6, 6 } }) |position|
        fill(renderer, position[0], 1, position[1], position[0], 3, position[1], cobble);
    renderer.set(5, 3, 5, wallTorch(renderer.piece.facing, .north));
    var z: i32 = 2;
    while (z <= 8) : (z += 1) {
        renderer.set(2, 3, z, state("minecraft:oak_planks"));
        renderer.set(3, 3, z, state("minecraft:oak_planks"));
        if (z <= 3 or z >= 7) {
            renderer.set(4, 3, z, state("minecraft:oak_planks"));
            renderer.set(5, 3, z, state("minecraft:oak_planks"));
            renderer.set(6, 3, z, state("minecraft:oak_planks"));
        }
        renderer.set(7, 3, z, state("minecraft:oak_planks"));
        renderer.set(8, 3, z, state("minecraft:oak_planks"));
    }
    var y: i32 = 1;
    while (y <= 3) : (y += 1) renderer.set(9, y, 3, ladder(renderer.piece.facing, .west));
    placeChest(renderer, 3, 4, 8);
}

fn renderFiveWayCrossing(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 10, .height = 9, .length = 11 }, true);
    carve(renderer, 4, 3, 0, 3, 3, renderer.piece.entrance);
    if (renderer.piece.flags & 1 != 0) carveSide(renderer, 0, 3, 1);
    if (renderer.piece.flags & 4 != 0) carveSide(renderer, 9, 3, 1);
    if (renderer.piece.flags & 2 != 0) carveSide(renderer, 0, 5, 7);
    if (renderer.piece.flags & 8 != 0) carveSide(renderer, 9, 5, 7);
    carve(renderer, 5, 1, 10, 3, 3, .opening);
    fill(renderer, 1, 2, 1, 8, 2, 6, stone_bricks);
    fill(renderer, 4, 1, 5, 4, 4, 9, stone_bricks);
    fill(renderer, 8, 1, 5, 8, 4, 9, stone_bricks);
    fill(renderer, 1, 4, 7, 3, 4, 9, stone_bricks);
    fill(renderer, 1, 3, 5, 3, 3, 6, stone_bricks);
    const slab = state("minecraft:smooth_stone_slab[type=bottom,waterlogged=false]");
    fill(renderer, 1, 3, 4, 3, 3, 4, slab);
    fill(renderer, 1, 4, 6, 3, 4, 6, slab);
    fill(renderer, 5, 1, 7, 7, 1, 8, stone_bricks);
    fill(renderer, 5, 1, 9, 7, 1, 9, slab);
    fill(renderer, 5, 2, 7, 7, 2, 7, slab);
    fill(renderer, 4, 5, 7, 4, 5, 9, slab);
    fill(renderer, 8, 5, 7, 8, 5, 9, slab);
    fill(renderer, 5, 5, 7, 7, 5, 9, state("minecraft:smooth_stone_slab[type=double,waterlogged=false]"));
    renderer.set(6, 5, 6, wallTorch(renderer.piece.facing, .south));
}

fn renderLibrary(renderer: Renderer) void {
    const height = renderer.piece.size_y;
    renderShell(renderer, .{ .width = 14, .height = height, .length = 15 }, true);
    carve(renderer, 4, 1, 0, 3, 3, renderer.piece.entrance);
    fillWithRandomThreshold(renderer, 0.07, 2, 1, 1, 11, 4, 13, state("minecraft:cobweb"));
    const plank = state("minecraft:oak_planks");
    const shelf = state("minecraft:bookshelf");
    var z: i32 = 1;
    while (z <= 13) : (z += 1) {
        const block = if (@mod(z - 1, 4) == 0) plank else shelf;
        fill(renderer, 1, 1, z, 1, 4, z, block);
        fill(renderer, 12, 1, z, 12, 4, z, block);
        if (@mod(z - 1, 4) == 0) {
            renderer.set(2, 3, z, wallTorch(renderer.piece.facing, .east));
            renderer.set(11, 3, z, wallTorch(renderer.piece.facing, .west));
        }
        if (height > 6) {
            fill(renderer, 1, 6, z, 1, 9, z, block);
            fill(renderer, 12, 6, z, 12, 9, z, block);
        }
    }
    var column: i32 = 3;
    while (column < 12) : (column += 2) {
        fill(renderer, 3, 1, column, 4, 3, column, shelf);
        fill(renderer, 6, 1, column, 7, 3, column, shelf);
        fill(renderer, 9, 1, column, 10, 3, column, shelf);
    }
    if (height > 6) renderTallLibrary(renderer);
    placeChest(renderer, 3, 3, 5);
    if (height > 6) {
        renderer.set(12, 9, 1, cave_air);
        placeChest(renderer, 12, 8, 1);
    }
}

fn renderTallLibrary(renderer: Renderer) void {
    const plank = state("minecraft:oak_planks");
    fill(renderer, 1, 5, 1, 3, 5, 13, plank);
    fill(renderer, 10, 5, 1, 12, 5, 13, plank);
    fill(renderer, 4, 5, 1, 9, 5, 2, plank);
    fill(renderer, 4, 5, 12, 9, 5, 13, plank);
    renderer.set(9, 5, 11, plank);
    renderer.set(8, 5, 11, plank);
    renderer.set(9, 5, 10, plank);
    fill(renderer, 3, 6, 3, 3, 6, 11, oakFence(renderer.piece.facing, true, false, true, false));
    fill(renderer, 10, 6, 3, 10, 6, 9, oakFence(renderer.piece.facing, true, false, true, false));
    fill(renderer, 4, 6, 2, 9, 6, 2, oakFence(renderer.piece.facing, false, true, false, true));
    fill(renderer, 4, 6, 12, 7, 6, 12, oakFence(renderer.piece.facing, false, true, false, true));
    renderer.set(3, 6, 2, oakFence(renderer.piece.facing, true, true, false, false));
    renderer.set(3, 6, 12, oakFence(renderer.piece.facing, false, true, true, false));
    renderer.set(10, 6, 2, oakFence(renderer.piece.facing, true, false, false, true));
    for (0..3) |index| {
        const offset: i32 = @intCast(index);
        renderer.set(8 + offset, 6, 12 - offset, oakFence(renderer.piece.facing, false, false, true, true));
        if (index != 2) renderer.set(8 + offset, 6, 11 - offset, oakFence(renderer.piece.facing, true, true, false, false));
    }
    for (1..8) |value| renderer.set(10, @intCast(value), 13, ladder(renderer.piece.facing, .south));
    renderer.set(6, 9, 7, oakFence(renderer.piece.facing, false, true, false, false));
    renderer.set(7, 9, 7, oakFence(renderer.piece.facing, false, false, false, true));
    renderer.set(6, 8, 7, oakFence(renderer.piece.facing, false, true, false, false));
    renderer.set(7, 8, 7, oakFence(renderer.piece.facing, false, false, false, true));
    renderer.set(6, 7, 7, oakFence(renderer.piece.facing, true, true, true, false));
    renderer.set(7, 7, 7, oakFence(renderer.piece.facing, true, true, true, false));
    renderer.set(5, 7, 7, oakFence(renderer.piece.facing, false, true, false, false));
    renderer.set(8, 7, 7, oakFence(renderer.piece.facing, false, false, false, true));
    renderer.set(6, 7, 6, oakFence(renderer.piece.facing, true, true, false, false));
    renderer.set(6, 7, 8, oakFence(renderer.piece.facing, false, true, true, false));
    renderer.set(7, 7, 6, oakFence(renderer.piece.facing, true, false, false, true));
    renderer.set(7, 7, 8, oakFence(renderer.piece.facing, false, false, true, true));
    const torch = state("minecraft:torch");
    renderer.set(5, 8, 7, torch);
    renderer.set(8, 8, 7, torch);
    renderer.set(6, 8, 6, torch);
    renderer.set(6, 8, 8, torch);
    renderer.set(7, 8, 6, torch);
    renderer.set(7, 8, 8, torch);
}

fn renderTurn(renderer: Renderer, comptime left: bool) void {
    renderShell(renderer, .{ .width = 5, .height = 5, .length = 5 }, true);
    carve(renderer, 1, 1, 0, 3, 3, renderer.piece.entrance);
    const opening_left = renderer.piece.facing == .north or renderer.piece.facing == .east;
    const x: i32 = if (left == opening_left) 0 else 4;
    carveSide(renderer, x, 1, 1);
}

fn renderStairs(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 5, .height = 11, .length = 8 }, true);
    carve(renderer, 1, 7, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, 1, 1, 7, 3, 3, .opening);
    const stairs = stairsState(renderer.piece.facing, .south, .cobblestone);
    var index: i32 = 0;
    while (index < 6) : (index += 1) {
        fill(renderer, 1, 6 - index, 1 + index, 3, 6 - index, 1 + index, stairs);
        if (index < 5) fill(renderer, 1, 5 - index, 1 + index, 3, 5 - index, 1 + index, stone_bricks);
    }
}

fn renderSmallCorridor(renderer: Renderer) void {
    const length: i32 = renderer.piece.size_y;
    var z: i32 = 0;
    while (z < length) : (z += 1) {
        fill(renderer, 0, 0, z, 4, 0, z, stone_bricks);
        fill(renderer, 0, 4, z, 4, 4, z, stone_bricks);
        fill(renderer, 0, 1, z, 0, 3, z, stone_bricks);
        fill(renderer, 4, 1, z, 4, 3, z, stone_bricks);
        fill(renderer, 1, 1, z, 3, 3, z, cave_air);
    }
}

fn carveEntrances(renderer: Renderer, width: i32, _: i32, length: i32) void {
    if (renderer.piece.kind == .portal_room) {
        carve(renderer, 4, 1, 0, 3, 3, .grates);
        return;
    }
    carve(renderer, @divTrunc(width - 3, 2), 1, 0, 3, 3, renderer.piece.entrance);
    carve(renderer, @divTrunc(width - 3, 2), 1, length - 1, 3, 3, .opening);
    switch (renderer.piece.kind) {
        .corridor => {
            if (renderer.piece.flags & 1 != 0) carveSide(renderer, 0, 1, 2);
            if (renderer.piece.flags & 2 != 0) carveSide(renderer, width - 1, 1, 2);
        },
        .square_room => {
            carveSide(renderer, 0, 1, 4);
            carveSide(renderer, width - 1, 1, 4);
        },
        .five_way_crossing => {
            if (renderer.piece.flags & 1 != 0) carveSide(renderer, 0, 3, 1);
            if (renderer.piece.flags & 4 != 0) carveSide(renderer, width - 1, 3, 1);
        },
        else => {},
    }
}

fn carve(renderer: Renderer, start_x: i32, start_y: i32, z: i32, width: i32, height: i32, entrance: Entrance) void {
    if (entrance != .opening) {
        renderEntrance(renderer, start_x, start_y, z, entrance);
        return;
    }
    var y: i32 = start_y;
    while (y < start_y + height) : (y += 1) {
        var x: i32 = start_x;
        while (x < start_x + width) : (x += 1) renderer.set(x, y, z, cave_air);
    }
}

fn renderEntrance(renderer: Renderer, x: i32, y: i32, z: i32, entrance: Entrance) void {
    switch (entrance) {
        .opening => unreachable,
        .wood_door, .iron_door => {
            fill(renderer, x, y, z, x, y + 2, z, stone_bricks);
            fill(renderer, x + 2, y, z, x + 2, y + 2, z, stone_bricks);
            fill(renderer, x + 1, y + 2, z, x + 1, y + 2, z, stone_bricks);
            const material: DoorMaterial = if (entrance == .wood_door) .oak else .iron;
            renderer.set(x + 1, y, z, door(renderer.piece.facing, .north, false, false, material));
            renderer.set(x + 1, y + 1, z, door(renderer.piece.facing, .north, true, false, material));
            if (entrance == .iron_door) {
                renderer.set(x + 2, y + 1, z + 1, stoneButton(renderer.piece.facing, .north));
                renderer.set(x + 2, y + 1, z - 1, stoneButton(renderer.piece.facing, .south));
            }
        },
        .grates => {
            renderer.set(x + 1, y, z, cave_air);
            renderer.set(x + 1, y + 1, z, cave_air);
            renderer.set(x, y, z, ironBars(renderer.piece.facing, false, false, false, true));
            renderer.set(x, y + 1, z, ironBars(renderer.piece.facing, false, false, false, true));
            fill(renderer, x, y + 2, z, x + 2, y + 2, z, ironBars(renderer.piece.facing, false, true, false, true));
            renderer.set(x + 2, y, z, ironBars(renderer.piece.facing, false, true, false, false));
            renderer.set(x + 2, y + 1, z, ironBars(renderer.piece.facing, false, true, false, false));
        },
    }
}

fn fill(renderer: Renderer, min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32, block: generated_state.GeneratedState) void {
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) renderer.set(x, y, z, block);
        }
    }
}

fn addWithRandomThreshold(renderer: Renderer, threshold: f32, x: i32, y: i32, z: i32, block: generated_state.GeneratedState) void {
    if (renderer.random.nextF32() < threshold) renderer.set(x, y, z, block);
}

fn fillWithRandomThreshold(renderer: Renderer, threshold: f32, min_x: i32, min_y: i32, min_z: i32, max_x: i32, max_y: i32, max_z: i32, block: generated_state.GeneratedState) void {
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            var z = min_z;
            while (z <= max_z) : (z += 1) {
                if (renderer.random.nextF32() <= threshold) renderer.set(x, y, z, block);
            }
        }
    }
}

fn placeChest(renderer: Renderer, x: i32, y: i32, z: i32) void {
    const position = renderer.worldPosition(x, y, z);
    if (@divFloor(position.x, feature.width) != renderer.region.center_chunk_x or
        @divFloor(position.z, feature.width) != renderer.region.center_chunk_z)
        return;
    const target = renderer.region.stateConst(position.x, position.y, position.z) orelse return;
    if (target.nameEquals("minecraft:chest")) return;
    _ = renderer.random.nextI64();
    renderer.set(x, y, z, chestState(renderer.piece.facing, .north));
}

fn state(comptime name: []const u8) generated_state.GeneratedState {
    @setEvalBranchQuota(10_000);
    return generated_state.GeneratedState.featureNamed(name);
}

fn carveSide(renderer: Renderer, x: i32, start_y: i32, start_z: i32) void {
    var y: i32 = start_y;
    while (y < start_y + 3) : (y += 1) {
        var z: i32 = start_z;
        while (z < start_z + 3) : (z += 1) renderer.set(x, y, z, cave_air);
    }
}

fn renderSpiralStaircase(renderer: Renderer) void {
    const slab = generated_state.GeneratedState.featureNamed("minecraft:smooth_stone_slab[type=bottom,waterlogged=false]");
    renderer.set(2, 6, 1, stone_bricks);
    renderer.set(1, 5, 1, stone_bricks);
    renderer.set(1, 6, 1, slab);
    renderer.set(1, 5, 2, stone_bricks);
    renderer.set(1, 4, 3, stone_bricks);
    renderer.set(1, 5, 3, slab);
    renderer.set(2, 4, 3, stone_bricks);
    renderer.set(3, 3, 3, stone_bricks);
    renderer.set(3, 4, 3, slab);
    renderer.set(3, 3, 2, stone_bricks);
    renderer.set(3, 2, 1, stone_bricks);
    renderer.set(3, 3, 1, slab);
    renderer.set(2, 2, 1, stone_bricks);
    renderer.set(1, 1, 1, stone_bricks);
    renderer.set(1, 2, 1, slab);
    renderer.set(1, 1, 2, stone_bricks);
    renderer.set(1, 1, 3, slab);
}

fn renderPortalRoom(renderer: Renderer) void {
    renderShell(renderer, .{ .width = 11, .height = 8, .length = 16 }, false);
    renderEntrance(renderer, 4, 1, 0, .grates);
    randomOutline(renderer, 1, 6, 1, 1, 6, 14);
    randomOutline(renderer, 9, 6, 1, 9, 6, 14);
    randomOutline(renderer, 2, 6, 1, 8, 6, 2);
    randomOutline(renderer, 2, 6, 14, 8, 6, 14);
    randomOutline(renderer, 1, 1, 1, 2, 1, 4);
    randomOutline(renderer, 8, 1, 1, 9, 1, 4);
    fill(renderer, 1, 1, 1, 1, 1, 3, generated_state.GeneratedState.lava);
    fill(renderer, 9, 1, 1, 9, 1, 3, generated_state.GeneratedState.lava);
    randomOutline(renderer, 3, 1, 8, 7, 1, 12);
    fill(renderer, 4, 1, 9, 6, 1, 11, generated_state.GeneratedState.lava);
    var z: i32 = 3;
    while (z < 14) : (z += 2) {
        fill(renderer, 0, 3, z, 0, 4, z, ironBars(renderer.piece.facing, true, false, true, false));
        fill(renderer, 10, 3, z, 10, 4, z, ironBars(renderer.piece.facing, true, false, true, false));
    }
    var x: i32 = 2;
    while (x < 9) : (x += 2) fill(renderer, x, 3, 15, x, 4, 15, ironBars(renderer.piece.facing, false, true, false, true));
    randomOutline(renderer, 4, 1, 5, 6, 1, 7);
    randomOutline(renderer, 4, 2, 6, 6, 2, 7);
    randomOutline(renderer, 4, 3, 7, 6, 3, 7);
    const stairs = stairsState(renderer.piece.facing, .north, .stone_brick);
    x = 4;
    while (x <= 6) : (x += 1) {
        renderer.set(x, 1, 4, stairs);
        renderer.set(x, 2, 5, stairs);
        renderer.set(x, 3, 6, stairs);
    }
    placePortalFrames(renderer);
    renderer.set(5, 3, 6, state("minecraft:spawner"));
}

fn placePortalFrames(renderer: Renderer) void {
    var eyes: [12]bool = undefined;
    var complete = true;
    for (&eyes) |*eye| {
        eye.* = renderer.random.nextF32() > 0.9;
        complete = complete and eye.*;
    }
    var index: i32 = 0;
    while (index < 3) : (index += 1) {
        const offset: usize = @intCast(index);
        renderer.set(4 + index, 3, 8, portalFrame(renderer.piece.facing, .north, eyes[offset]));
        renderer.set(4 + index, 3, 12, portalFrame(renderer.piece.facing, .south, eyes[3 + offset]));
        renderer.set(3, 3, 9 + index, portalFrame(renderer.piece.facing, .east, eyes[6 + offset]));
        renderer.set(7, 3, 9 + index, portalFrame(renderer.piece.facing, .west, eyes[9 + offset]));
    }
    if (complete) fill(renderer, 4, 3, 9, 6, 3, 11, state("minecraft:end_portal"));
}

fn portalFrame(piece_facing: Facing, local_facing: Facing, eye: bool) generated_state.GeneratedState {
    const facing = transformFacing(piece_facing, local_facing);
    return switch (facing) {
        .north => if (eye) state("minecraft:end_portal_frame[eye=true,facing=north]") else state("minecraft:end_portal_frame[eye=false,facing=north]"),
        .south => if (eye) state("minecraft:end_portal_frame[eye=true,facing=south]") else state("minecraft:end_portal_frame[eye=false,facing=south]"),
        .east => if (eye) state("minecraft:end_portal_frame[eye=true,facing=east]") else state("minecraft:end_portal_frame[eye=false,facing=east]"),
        .west => if (eye) state("minecraft:end_portal_frame[eye=true,facing=west]") else state("minecraft:end_portal_frame[eye=false,facing=west]"),
    };
}

fn transformFacing(piece_facing: Facing, local_facing: Facing) Facing {
    return switch (piece_facing) {
        .north => local_facing,
        .south => switch (local_facing) {
            .north => .south,
            .south => .north,
            .east => .east,
            .west => .west,
        },
        .west => switch (local_facing) {
            .north => .west,
            .east => .south,
            .south => .east,
            .west => .north,
        },
        .east => switch (local_facing) {
            .north => .east,
            .east => .south,
            .south => .west,
            .west => .north,
        },
    };
}

const DoorMaterial = enum { oak, iron };
const StairMaterial = enum { cobblestone, stone_brick };

fn wallTorch(piece_facing: Facing, local_facing: Facing) generated_state.GeneratedState {
    return switch (transformFacing(piece_facing, local_facing)) {
        .north => state("minecraft:wall_torch[facing=north]"),
        .east => state("minecraft:wall_torch[facing=east]"),
        .south => state("minecraft:wall_torch[facing=south]"),
        .west => state("minecraft:wall_torch[facing=west]"),
    };
}

fn stoneButton(piece_facing: Facing, local_facing: Facing) generated_state.GeneratedState {
    return switch (transformFacing(piece_facing, local_facing)) {
        .north => state("minecraft:stone_button[face=wall,facing=north,powered=false]"),
        .east => state("minecraft:stone_button[face=wall,facing=east,powered=false]"),
        .south => state("minecraft:stone_button[face=wall,facing=south,powered=false]"),
        .west => state("minecraft:stone_button[face=wall,facing=west,powered=false]"),
    };
}

fn ladder(piece_facing: Facing, local_facing: Facing) generated_state.GeneratedState {
    return switch (transformFacing(piece_facing, local_facing)) {
        .north => state("minecraft:ladder[facing=north,waterlogged=false]"),
        .east => state("minecraft:ladder[facing=east,waterlogged=false]"),
        .south => state("minecraft:ladder[facing=south,waterlogged=false]"),
        .west => state("minecraft:ladder[facing=west,waterlogged=false]"),
    };
}

fn chestState(piece_facing: Facing, local_facing: Facing) generated_state.GeneratedState {
    return switch (transformFacing(piece_facing, local_facing)) {
        .north => state("minecraft:chest[facing=north,type=single,waterlogged=false]"),
        .east => state("minecraft:chest[facing=east,type=single,waterlogged=false]"),
        .south => state("minecraft:chest[facing=south,type=single,waterlogged=false]"),
        .west => state("minecraft:chest[facing=west,type=single,waterlogged=false]"),
    };
}

fn ironBars(piece_facing: Facing, north: bool, east: bool, south: bool, west: bool) generated_state.GeneratedState {
    var mask: u4 = 0;
    if (north) mask |= facingBit(transformFacing(piece_facing, .north));
    if (east) mask |= facingBit(transformFacing(piece_facing, .east));
    if (south) mask |= facingBit(transformFacing(piece_facing, .south));
    if (west) mask |= facingBit(transformFacing(piece_facing, .west));
    return switch (mask) {
        0 => state("minecraft:iron_bars[east=false,north=false,south=false,waterlogged=false,west=false]"),
        1 => state("minecraft:iron_bars[east=false,north=true,south=false,waterlogged=false,west=false]"),
        2 => state("minecraft:iron_bars[east=true,north=false,south=false,waterlogged=false,west=false]"),
        3 => state("minecraft:iron_bars[east=true,north=true,south=false,waterlogged=false,west=false]"),
        4 => state("minecraft:iron_bars[east=false,north=false,south=true,waterlogged=false,west=false]"),
        5 => state("minecraft:iron_bars[east=false,north=true,south=true,waterlogged=false,west=false]"),
        6 => state("minecraft:iron_bars[east=true,north=false,south=true,waterlogged=false,west=false]"),
        7 => state("minecraft:iron_bars[east=true,north=true,south=true,waterlogged=false,west=false]"),
        8 => state("minecraft:iron_bars[east=false,north=false,south=false,waterlogged=false,west=true]"),
        9 => state("minecraft:iron_bars[east=false,north=true,south=false,waterlogged=false,west=true]"),
        10 => state("minecraft:iron_bars[east=true,north=false,south=false,waterlogged=false,west=true]"),
        11 => state("minecraft:iron_bars[east=true,north=true,south=false,waterlogged=false,west=true]"),
        12 => state("minecraft:iron_bars[east=false,north=false,south=true,waterlogged=false,west=true]"),
        13 => state("minecraft:iron_bars[east=false,north=true,south=true,waterlogged=false,west=true]"),
        14 => state("minecraft:iron_bars[east=true,north=false,south=true,waterlogged=false,west=true]"),
        15 => state("minecraft:iron_bars[east=true,north=true,south=true,waterlogged=false,west=true]"),
    };
}

fn facingBit(facing: Facing) u4 {
    return switch (facing) {
        .north => 1,
        .east => 2,
        .south => 4,
        .west => 8,
    };
}

fn oakFence(piece_facing: Facing, north: bool, east: bool, south: bool, west: bool) generated_state.GeneratedState {
    var mask: u4 = 0;
    if (north) mask |= facingBit(transformFacing(piece_facing, .north));
    if (east) mask |= facingBit(transformFacing(piece_facing, .east));
    if (south) mask |= facingBit(transformFacing(piece_facing, .south));
    if (west) mask |= facingBit(transformFacing(piece_facing, .west));
    return switch (mask) {
        0 => state("minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=false]"),
        1 => state("minecraft:oak_fence[east=false,north=true,south=false,waterlogged=false,west=false]"),
        2 => state("minecraft:oak_fence[east=true,north=false,south=false,waterlogged=false,west=false]"),
        3 => state("minecraft:oak_fence[east=true,north=true,south=false,waterlogged=false,west=false]"),
        4 => state("minecraft:oak_fence[east=false,north=false,south=true,waterlogged=false,west=false]"),
        5 => state("minecraft:oak_fence[east=false,north=true,south=true,waterlogged=false,west=false]"),
        6 => state("minecraft:oak_fence[east=true,north=false,south=true,waterlogged=false,west=false]"),
        7 => state("minecraft:oak_fence[east=true,north=true,south=true,waterlogged=false,west=false]"),
        8 => state("minecraft:oak_fence[east=false,north=false,south=false,waterlogged=false,west=true]"),
        9 => state("minecraft:oak_fence[east=false,north=true,south=false,waterlogged=false,west=true]"),
        10 => state("minecraft:oak_fence[east=true,north=false,south=false,waterlogged=false,west=true]"),
        11 => state("minecraft:oak_fence[east=true,north=true,south=false,waterlogged=false,west=true]"),
        12 => state("minecraft:oak_fence[east=false,north=false,south=true,waterlogged=false,west=true]"),
        13 => state("minecraft:oak_fence[east=false,north=true,south=true,waterlogged=false,west=true]"),
        14 => state("minecraft:oak_fence[east=true,north=false,south=true,waterlogged=false,west=true]"),
        15 => state("minecraft:oak_fence[east=true,north=true,south=true,waterlogged=false,west=true]"),
    };
}

fn stairsState(piece_facing: Facing, local_facing: Facing, material: StairMaterial) generated_state.GeneratedState {
    const facing = transformFacing(piece_facing, local_facing);
    return switch (material) {
        .cobblestone => switch (facing) {
            .north => state("minecraft:cobblestone_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]"),
            .east => state("minecraft:cobblestone_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]"),
            .south => state("minecraft:cobblestone_stairs[facing=south,half=bottom,shape=straight,waterlogged=false]"),
            .west => state("minecraft:cobblestone_stairs[facing=west,half=bottom,shape=straight,waterlogged=false]"),
        },
        .stone_brick => switch (facing) {
            .north => state("minecraft:stone_brick_stairs[facing=north,half=bottom,shape=straight,waterlogged=false]"),
            .east => state("minecraft:stone_brick_stairs[facing=east,half=bottom,shape=straight,waterlogged=false]"),
            .south => state("minecraft:stone_brick_stairs[facing=south,half=bottom,shape=straight,waterlogged=false]"),
            .west => state("minecraft:stone_brick_stairs[facing=west,half=bottom,shape=straight,waterlogged=false]"),
        },
    };
}

fn door(piece_facing: Facing, local_facing: Facing, upper: bool, right_hinge: bool, material: DoorMaterial) generated_state.GeneratedState {
    const mirrored = piece_facing == .south or piece_facing == .west;
    const hinge_right = right_hinge != mirrored;
    const facing = transformFacing(piece_facing, local_facing);
    return switch (material) {
        .oak => oakDoor(facing, upper, hinge_right),
        .iron => ironDoor(facing, upper, hinge_right),
    };
}

fn oakDoor(facing: Facing, upper: bool, right_hinge: bool) generated_state.GeneratedState {
    return switch (facing) {
        .north => if (upper) if (right_hinge) state("minecraft:oak_door[facing=north,half=upper,hinge=right,open=false,powered=false]") else oak_door_upper else if (right_hinge) state("minecraft:oak_door[facing=north,half=lower,hinge=right,open=false,powered=false]") else oak_door_lower,
        .east => if (upper) if (right_hinge) state("minecraft:oak_door[facing=east,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=east,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:oak_door[facing=east,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=east,half=lower,hinge=left,open=false,powered=false]"),
        .south => if (upper) if (right_hinge) state("minecraft:oak_door[facing=south,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=south,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:oak_door[facing=south,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=south,half=lower,hinge=left,open=false,powered=false]"),
        .west => if (upper) if (right_hinge) state("minecraft:oak_door[facing=west,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=west,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:oak_door[facing=west,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:oak_door[facing=west,half=lower,hinge=left,open=false,powered=false]"),
    };
}

fn ironDoor(facing: Facing, upper: bool, right_hinge: bool) generated_state.GeneratedState {
    return switch (facing) {
        .north => if (upper) if (right_hinge) state("minecraft:iron_door[facing=north,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=north,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:iron_door[facing=north,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=north,half=lower,hinge=left,open=false,powered=false]"),
        .east => if (upper) if (right_hinge) state("minecraft:iron_door[facing=east,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=east,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:iron_door[facing=east,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=east,half=lower,hinge=left,open=false,powered=false]"),
        .south => if (upper) if (right_hinge) state("minecraft:iron_door[facing=south,half=upper,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=south,half=upper,hinge=left,open=false,powered=false]") else if (right_hinge) state("minecraft:iron_door[facing=south,half=lower,hinge=right,open=false,powered=false]") else state("minecraft:iron_door[facing=south,half=lower,hinge=left,open=false,powered=false]"),
        .west => if (upper) if (right_hinge) state("minecraft:iron_door[facing=west,half=upper,hinge=right,open=false,powered=false]") else iron_door_upper else if (right_hinge) state("minecraft:iron_door[facing=west,half=lower,hinge=right,open=false,powered=false]") else iron_door_lower,
    };
}

const stone_bricks = generated_state.GeneratedState.featureNamed("minecraft:stone_bricks");
const cracked_stone_bricks = state("minecraft:cracked_stone_bricks");
const mossy_stone_bricks = state("minecraft:mossy_stone_bricks");
const infested_stone_bricks = state("minecraft:infested_stone_bricks");
const cave_air = generated_state.GeneratedState.featureNamed("minecraft:cave_air");
const chest = state("minecraft:chest[facing=north,type=single,waterlogged=false]");
const wall_torch_east = state("minecraft:wall_torch[facing=east]");
const wall_torch_west = state("minecraft:wall_torch[facing=west]");
const oak_door_lower = state("minecraft:oak_door[facing=north,half=lower,hinge=left,open=false,powered=false]");
const oak_door_upper = state("minecraft:oak_door[facing=north,half=upper,hinge=left,open=false,powered=false]");
const iron_door_lower = state("minecraft:iron_door[facing=west,half=lower,hinge=left,open=false,powered=false]");
const iron_door_upper = state("minecraft:iron_door[facing=west,half=upper,hinge=left,open=false,powered=false]");
const stone_button_north = state("minecraft:stone_button[face=wall,facing=north,powered=false]");
const iron_bars_west = state("minecraft:iron_bars[east=false,north=false,south=false,waterlogged=false,west=true]");
const iron_bars_east = state("minecraft:iron_bars[east=true,north=false,south=false,waterlogged=false,west=false]");
const iron_bars_east_west = state("minecraft:iron_bars[east=true,north=false,south=false,waterlogged=false,west=true]");
const iron_bars_north_south = state("minecraft:iron_bars[east=false,north=true,south=true,waterlogged=false,west=false]");
const iron_bars_north_south_east = state("minecraft:iron_bars[east=true,north=true,south=true,waterlogged=false,west=false]");

test "stronghold locator builds Vanilla's bounded ring" {
    var sampler = climate.Sampler.init(0);
    var cache: biome.Cache = .{};
    var locator: Locator = .{};
    locator.prepare(0, &sampler, &cache);
    try std.testing.expect(locator.ready);
    try std.testing.expect(locator.contains(locator.positions[0]));
    try std.testing.expect(!locator.positions[0].eql(locator.positions[1]));
}

test "every generated stronghold graph has a portal room" {
    var plan: Plan = undefined;
    generatePlan(0, .{ .x = 8, .z = -3 }, &plan);
    try std.testing.expect(plan.count != 0);
    try std.testing.expect(plan.count <= Plan.maximum_pieces);
    try std.testing.expect(plan.portal_piece != null);
}

test "structure orientation matches Vanilla mirror then rotation order" {
    try std.testing.expectEqual(Facing.north, transformFacing(.north, .north));
    try std.testing.expectEqual(Facing.south, transformFacing(.south, .north));
    try std.testing.expectEqual(Facing.west, transformFacing(.west, .north));
    try std.testing.expectEqual(Facing.east, transformFacing(.east, .north));
    try std.testing.expectEqual(Facing.south, transformFacing(.west, .east));
    try std.testing.expectEqual(Facing.east, transformFacing(.west, .south));
}
