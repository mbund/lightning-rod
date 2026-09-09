const std = @import("std");
const data = @import("jigsaw_data");
const legacy = @import("legacy_noise.zig");
const structures = @import("structures.zig");

const maximum_jigsaws = 256;
const maximum_elements = 512;
const maximum_pieces = 512;

pub const Piece = struct {
    template: structures.Template,
    processors: []const u8,
    origin: structures.Position,
    rotation: structures.Rotation,
    box: structures.Box,
    depth: u8,
    domain: u16,
};

pub const Scratch = struct {
    parent_jigsaws: [maximum_jigsaws]Jigsaw,
    candidate_jigsaws: [maximum_jigsaws]Jigsaw,
    element_order: [maximum_elements]u16,
    pieces: [maximum_pieces]Piece,
    queue: [maximum_pieces]QueueEntry,
    domains: [maximum_pieces]Domain,
};

pub const Plan = struct {
    pieces: []const Piece,
    center: structures.Position,
};

const Direction = enum(u3) { down, up, north, south, west, east };
const Jigsaw = struct {
    position: structures.Position,
    facing: Direction,
    rotation: Direction,
    rollable: bool,
    name: []const u8,
    pool: []const u8,
    target: []const u8,
    placement_priority: i32,
    selection_priority: i32,
};
const QueueEntry = struct { piece: u16, depth: u8, priority: i32 };
const Domain = struct { bounds: structures.Box };

pub fn bastionPlan(world_seed: u64, start: structures.ChunkPos, scratch: *Scratch) ?Plan {
    if (!structures.nether_complexes.isStart(@bitCast(world_seed), start)) return null;
    var selection = legacy.Random.init(0);
    selection.setCarverSeed(@bitCast(world_seed), start.x, start.z);
    if (selection.nextBounded(5) < 2) return null;

    var source = legacy.Random.init(0);
    source.setCarverSeed(@bitCast(world_seed), start.x, start.z);
    const rotation: structures.Rotation = @enumFromInt(source.nextBounded(4));
    const root_pool = findPool("minecraft:bastion/starts") orelse unreachable;
    const root_element = poolElements(root_pool)[source.nextBounded(root_pool.count)];
    const template = structures.vanilla.find(root_element.template) orelse unreachable;
    var origin = structures.Position{ .x = start.x * 16, .y = 33, .z = start.z * 16 };
    origin.y -= 1;
    const root = Piece{
        .template = template,
        .processors = root_element.processors,
        .origin = origin,
        .rotation = rotation,
        .box = structures.templateBox(template, origin, rotation),
        .depth = 0,
        .domain = 0,
    };
    scratch.pieces[0] = root;
    scratch.domains[0] = .{ .bounds = globalBounds(root.box) };
    var piece_count: usize = 1;
    var domain_count: usize = 1;
    var queue_count: usize = 0;
    generateChildren(&source, scratch, 0, &piece_count, &domain_count, &queue_count);
    while (queue_count != 0) {
        const next = removeHighestPriority(scratch.queue[0..queue_count]);
        queue_count -= 1;
        if (next.index != queue_count)
            std.mem.copyForwards(QueueEntry, scratch.queue[next.index..queue_count], scratch.queue[next.index + 1 .. queue_count + 1]);
        generateChildren(&source, scratch, next.entry.piece, &piece_count, &domain_count, &queue_count);
    }
    return .{
        .pieces = scratch.pieces[0..piece_count],
        .center = .{
            .x = @divFloor(root.box.minimum.x + root.box.maximum.x, 2),
            .y = 33,
            .z = @divFloor(root.box.minimum.z + root.box.maximum.z, 2),
        },
    };
}

const Removed = struct { index: usize, entry: QueueEntry };

fn removeHighestPriority(queue: []const QueueEntry) Removed {
    std.debug.assert(queue.len != 0);
    var best: usize = 0;
    for (queue[1..], 1..) |entry, index| {
        if (entry.priority > queue[best].priority) best = index;
    }
    return .{ .index = best, .entry = queue[best] };
}

fn generateChildren(
    source: *legacy.Random,
    scratch: *Scratch,
    piece_index: u16,
    piece_count: *usize,
    domain_count: *usize,
    queue_count: *usize,
) void {
    const piece = scratch.pieces[piece_index];
    const parent_count = loadJigsaws(
        piece.template,
        piece.origin,
        piece.rotation,
        source,
        &scratch.parent_jigsaws,
    );
    var internal_domain: ?u16 = null;
    for (scratch.parent_jigsaws[0..parent_count]) |parent| {
        const target = move(parent.position, parent.facing);
        const pool = findPool(parent.pool) orelse continue;
        const element_count = shuffledElements(source, pool, piece.depth, &scratch.element_order);
        if (attachFirst(
            source,
            scratch,
            piece,
            parent,
            target,
            scratch.element_order[0..element_count],
            piece_count,
            domain_count,
            queue_count,
            &internal_domain,
        )) continue;
    }
}

fn attachFirst(
    source: *legacy.Random,
    scratch: *Scratch,
    parent_piece: Piece,
    parent: Jigsaw,
    target: structures.Position,
    element_order: []const u16,
    piece_count: *usize,
    domain_count: *usize,
    queue_count: *usize,
    internal_domain: *?u16,
) bool {
    for (element_order) |element_index| {
        const element = data.elements[element_index];
        const template = structures.vanilla.find(element.template) orelse unreachable;
        var rotations = [_]structures.Rotation{ .none, .clockwise_90, .clockwise_180, .counterclockwise_90 };
        shuffle(structures.Rotation, source, &rotations);
        for (rotations) |rotation| {
            const candidate_count = loadJigsaws(
                template,
                .{ .x = 0, .y = 0, .z = 0 },
                rotation,
                source,
                &scratch.candidate_jigsaws,
            );
            for (scratch.candidate_jigsaws[0..candidate_count]) |candidate| {
                if (!attachmentMatches(parent, candidate)) continue;
                const origin = subtract(target, candidate.position);
                const box = structures.templateBox(template, origin, rotation);
                const internal = contains(parent_piece.box, target);
                const domain = if (internal)
                    ensureInternalDomain(scratch, parent_piece.box, domain_count, internal_domain)
                else
                    parent_piece.domain;
                if (!canPlace(scratch, scratch.pieces[0..piece_count.*], domain, box)) continue;
                std.debug.assert(piece_count.* < scratch.pieces.len);
                const new_index: u16 = @intCast(piece_count.*);
                scratch.pieces[piece_count.*] = .{
                    .template = template,
                    .processors = element.processors,
                    .origin = origin,
                    .rotation = rotation,
                    .box = box,
                    .depth = parent_piece.depth + 1,
                    .domain = domain,
                };
                piece_count.* += 1;
                if (parent_piece.depth + 1 <= 6) {
                    std.debug.assert(queue_count.* < scratch.queue.len);
                    scratch.queue[queue_count.*] = .{
                        .piece = new_index,
                        .depth = parent_piece.depth + 1,
                        .priority = parent.placement_priority,
                    };
                    queue_count.* += 1;
                }
                return true;
            }
        }
    }
    return false;
}

fn ensureInternalDomain(
    scratch: *Scratch,
    bounds: structures.Box,
    domain_count: *usize,
    existing: *?u16,
) u16 {
    if (existing.*) |domain| return domain;
    std.debug.assert(domain_count.* < scratch.domains.len);
    const domain: u16 = @intCast(domain_count.*);
    scratch.domains[domain_count.*] = .{ .bounds = bounds };
    domain_count.* += 1;
    existing.* = domain;
    return domain;
}

fn canPlace(
    scratch: *const Scratch,
    pieces: []const Piece,
    domain: u16,
    candidate: structures.Box,
) bool {
    if (!containsBox(scratch.domains[domain].bounds, candidate)) return false;
    for (pieces) |piece|
        if (piece.domain == domain and piece.box.intersects(candidate)) return false;
    return true;
}

fn globalBounds(root: structures.Box) structures.Box {
    const center_x = @divFloor(root.minimum.x + root.maximum.x, 2);
    const center_z = @divFloor(root.minimum.z + root.maximum.z, 2);
    return .{
        .minimum = .{ .x = center_x - 80, .y = 0, .z = center_z - 80 },
        .maximum = .{ .x = center_x + 80, .y = 113, .z = center_z + 80 },
    };
}

fn shuffledElements(source: *legacy.Random, pool: data.Pool, depth: u8, output: []u16) usize {
    var count: usize = 0;
    if (depth != 6) {
        for (0..pool.count) |offset| output[count + offset] = pool.first + @as(u16, @intCast(offset));
        shuffle(u16, source, output[count..][0..pool.count]);
        count += pool.count;
    }
    if (findPool(pool.fallback)) |fallback| {
        for (0..fallback.count) |offset| output[count + offset] = fallback.first + @as(u16, @intCast(offset));
        shuffle(u16, source, output[count..][0..fallback.count]);
        count += fallback.count;
    }
    return count;
}

fn loadJigsaws(
    template: structures.Template,
    origin: structures.Position,
    rotation: structures.Rotation,
    source: *legacy.Random,
    output: []Jigsaw,
) usize {
    var count: usize = 0;
    for (template.jigsaws) |jigsaw| {
        std.debug.assert(count < output.len);
        const local = structures.rotate(.{ .x = jigsaw.position[0], .y = jigsaw.position[1], .z = jigsaw.position[2] }, rotation);
        output[count] = parseJigsaw(jigsaw, add(origin, local), rotation);
        count += 1;
    }
    shuffle(Jigsaw, source, output[0..count]);
    stableSelectionSort(output[0..count]);
    return count;
}

fn parseJigsaw(
    source: anytype,
    position: structures.Position,
    rotation: structures.Rotation,
) Jigsaw {
    const orientation = source.orientation;
    const separator = std.mem.indexOfScalar(u8, orientation, '_') orelse unreachable;
    const raw_facing = parseDirection(orientation[0..separator]);
    const raw_rotation = parseDirection(orientation[separator + 1 ..]);
    const facing = rotateDirection(raw_facing, rotation);
    const joint = if (source.joint.len != 0)
        source.joint
    else if (horizontal(facing))
        "aligned"
    else
        "rollable";
    return .{
        .position = position,
        .facing = facing,
        .rotation = rotateDirection(raw_rotation, rotation),
        .rollable = std.mem.eql(u8, joint, "rollable"),
        .name = source.name,
        .pool = source.pool,
        .target = source.target,
        .placement_priority = source.placement_priority,
        .selection_priority = source.selection_priority,
    };
}

fn stableSelectionSort(values: []Jigsaw) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var insert = index;
        while (insert != 0 and values[insert - 1].selection_priority < value.selection_priority) : (insert -= 1)
            values[insert] = values[insert - 1];
        values[insert] = value;
    }
}

fn findPool(id: []const u8) ?data.Pool {
    var low: usize = 0;
    var high: usize = data.pools.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, id, data.pools[middle].id)) {
            .lt => high = middle,
            .gt => low = middle + 1,
            .eq => return data.pools[middle],
        }
    }
    return null;
}

fn poolElements(pool: data.Pool) []const data.Element {
    return data.elements[pool.first..][0..pool.count];
}

fn attachmentMatches(parent: Jigsaw, candidate: Jigsaw) bool {
    return parent.facing == opposite(candidate.facing) and
        (parent.rollable or parent.rotation == candidate.rotation) and
        std.mem.eql(u8, parent.target, candidate.name);
}

fn shuffle(comptime T: type, source: *legacy.Random, values: []T) void {
    var remaining = values.len;
    while (remaining > 1) {
        const selected: usize = @intCast(source.nextBounded(@intCast(remaining)));
        remaining -= 1;
        std.mem.swap(T, &values[remaining], &values[selected]);
    }
}

fn parseDirection(value: []const u8) Direction {
    inline for (std.enums.values(Direction)) |direction|
        if (std.mem.eql(u8, value, @tagName(direction))) return direction;
    unreachable;
}

fn rotateDirection(direction: Direction, rotation: structures.Rotation) Direction {
    if (!horizontal(direction)) return direction;
    const directions = [_]Direction{ .north, .east, .south, .west };
    var index: usize = 0;
    while (directions[index] != direction) : (index += 1) {}
    return directions[@mod(index + @intFromEnum(rotation), directions.len)];
}

fn opposite(direction: Direction) Direction {
    return switch (direction) {
        .down => .up,
        .up => .down,
        .north => .south,
        .south => .north,
        .west => .east,
        .east => .west,
    };
}

fn horizontal(direction: Direction) bool {
    return direction != .down and direction != .up;
}

fn move(position: structures.Position, direction: Direction) structures.Position {
    const offset: structures.Position = switch (direction) {
        .down => structures.Position{ .x = 0, .y = -1, .z = 0 },
        .up => structures.Position{ .x = 0, .y = 1, .z = 0 },
        .north => structures.Position{ .x = 0, .y = 0, .z = -1 },
        .south => structures.Position{ .x = 0, .y = 0, .z = 1 },
        .west => structures.Position{ .x = -1, .y = 0, .z = 0 },
        .east => structures.Position{ .x = 1, .y = 0, .z = 0 },
    };
    return add(position, offset);
}

fn add(left: structures.Position, right: structures.Position) structures.Position {
    return .{ .x = left.x + right.x, .y = left.y + right.y, .z = left.z + right.z };
}

fn subtract(left: structures.Position, right: structures.Position) structures.Position {
    return .{ .x = left.x - right.x, .y = left.y - right.y, .z = left.z - right.z };
}

fn contains(box: structures.Box, position: structures.Position) bool {
    return position.x >= box.minimum.x and position.x <= box.maximum.x and
        position.y >= box.minimum.y and position.y <= box.maximum.y and
        position.z >= box.minimum.z and position.z <= box.maximum.z;
}

fn containsBox(outer: structures.Box, inner: structures.Box) bool {
    return contains(outer, inner.minimum) and contains(outer, inner.maximum);
}

test "bastion jigsaw plan is deterministic and bounded" {
    const scratch = try std.testing.allocator.create(Scratch);
    defer std.testing.allocator.destroy(scratch);
    const plan = bastionPlan(@bitCast(@as(i64, -2842400717068830474)), .{ .x = -511632, .z = -918863 }, scratch) orelse
        return error.MissingBastionPlan;
    try std.testing.expect(plan.pieces.len > 1);
    try std.testing.expect(plan.pieces.len <= maximum_pieces);
    try std.testing.expectEqual(@as(usize, 181), plan.pieces.len);
    try std.testing.expectEqualStrings("minecraft:bastion/treasure/big_air_full", plan.pieces[0].template.id);
    try std.testing.expectEqual(structures.Rotation.counterclockwise_90, plan.pieces[0].rotation);
    try std.testing.expectEqualStrings("minecraft:bastion/treasure/bases/lava_basin", plan.pieces[1].template.id);
    try std.testing.expectEqual(structures.Position{ .x = -8_186_105, .y = 32, .z = -14_701_815 }, plan.pieces[1].origin);
}
