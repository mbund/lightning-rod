//! Hull replacement for terrain sent to clients.
//!
//! A block is hidden when it is a full opaque occluder and all six face neighbours are full
//! opaque occluders too, including neighbours across section and column borders. A hidden
//! block cannot be seen from anywhere, so the client only needs some occluder there. Hidden
//! replaceable blocks become the section's filler, its most common replaceable block. Ores and
//! other interior blocks then never reach the client until a change exposes them, and section
//! palettes shrink. Occluders stay occluders, so collision, light and heightmaps are unchanged.
const std = @import("std");
const game_data = @import("game_data");
const assert = std.debug.assert;

pub const side = 16;
pub const volume = side * side * side;

/// Bits of a `Table` entry.
pub const occluder: u8 = 1;
/// An occluder without a block entity, so another occluder may stand in for it.
pub const replaceable: u8 = 2;

/// Flags per block state. Every replaceable state is an occluder.
pub const Table = []const u8;

/// Cells in rows of x bits, indexed by y then z, matching section order y * 256 + z * 16 + x.
pub const Rows = [side][side]u16;

/// Occluders just outside each face, as 16 rows of 16 bits, ordered -x, +x, -y, +y, -z, +z.
/// x faces: row y, bit z. y faces: row z, bit x. z faces: row y, bit x.
/// Cells outside the world or not loaded must be zero, which keeps their neighbours exposed.
pub const Faces = [6][side]u16;

/// Flags for every block state, from its rendering properties. Owned by the caller.
pub fn initTable(allocator: std.mem.Allocator) ![]u8 {
    const result = try allocator.alloc(u8, game_data.registry.block_state_to_block.len);
    for (result, 0..) |*value, state| {
        const rendering = game_data.physics.rendering(@intCast(state));
        value.* = if (!rendering.occluder) 0 else if (rendering.block_entity) occluder else occluder | replaceable;
    }
    assert(result.len > 0 and result[0] == 0);
    return result;
}

/// Occluder rows of a section.
pub fn rows(states: *const [volume]u16, table: Table) Rows {
    assert(table.len > 0);
    var result: Rows = undefined;
    for (0..side) |y| for (0..side) |z| {
        var row: u16 = 0;
        const base = (y * side + z) * side;
        for (0..side) |x| row |= @as(u16, @intFromBool(table[states[base + x]] & occluder != 0)) << @intCast(x);
        result[y][z] = row;
    };
    return result;
}

/// The cells of `occupied` on `face` of their section, laid out as the section beyond that
/// face reads them in its `Faces`: the +x cells of one section are the -x face of the next.
pub fn face(occupied: *const Rows, comptime index: usize) [side]u16 {
    comptime assert(index < 6);
    var result: [side]u16 = @splat(0);
    switch (index) {
        0, 1 => {
            const x: u4 = if (index == 0) 0 else side - 1;
            for (0..side) |y| for (0..side) |z| {
                result[y] |= ((occupied[y][z] >> x) & 1) << @intCast(z);
            };
        },
        2, 3 => result = occupied[if (index == 2) 0 else side - 1],
        4, 5 => for (0..side) |y| {
            result[y] = occupied[y][if (index == 4) 0 else side - 1];
        },
        else => unreachable,
    }
    return result;
}

/// Occluders whose six face neighbours are all occluders.
pub fn hidden(occupied: *const Rows, faces: *const Faces) Rows {
    var result: Rows = undefined;
    for (0..side) |y| for (0..side) |z| {
        const row = occupied[y][z];
        const west = (row << 1) | ((faces[0][y] >> @intCast(z)) & 1);
        const east = (row >> 1) | (((faces[1][y] >> @intCast(z)) & 1) << (side - 1));
        const below = if (y == 0) faces[2][z] else occupied[y - 1][z];
        const above = if (y == side - 1) faces[3][z] else occupied[y + 1][z];
        const north = if (z == 0) faces[4][y] else occupied[y][z - 1];
        const south = if (z == side - 1) faces[5][y] else occupied[y][z + 1];
        result[y][z] = row & west & east & below & above & north & south;
        assert(result[y][z] & ~row == 0);
    };
    return result;
}

/// The most common replaceable state of the section, or null when it has none. Counting is
/// bounded to the first `filler_candidates` distinct states, which covers real section palettes;
/// any replaceable state is a correct filler, the most common one only compresses best.
pub fn filler(states: *const [volume]u16, table: Table) ?u16 {
    var values: [filler_candidates]u16 = undefined;
    var counts: [filler_candidates]u16 = @splat(0);
    var distinct: usize = 0;
    for (states) |state| {
        if (table[state] & replaceable == 0) continue;
        const found = std.mem.indexOfScalar(u16, values[0..distinct], state) orelse found: {
            if (distinct == filler_candidates) continue;
            values[distinct] = state;
            distinct += 1;
            break :found distinct - 1;
        };
        counts[found] += 1;
    }
    if (distinct == 0) return null;
    const result = values[std.mem.indexOfMax(u16, counts[0..distinct])];
    assert(table[result] & replaceable != 0);
    return result;
}

const filler_candidates = 32;

/// The cells filler replaced in delivered terrain, as a mask in section order, and how many.
/// These are the only cells a client holding the filled section lacks the true states of.
pub fn changedCells(states: *const [volume]u16, faces: *const Faces, table: Table, mask: *[volume / 64]u64) usize {
    @memset(mask, 0);
    const occupied = rows(states, table);
    const cells = hidden(&occupied, faces);
    const value = filler(states, table) orelse return 0;
    var count: usize = 0;
    for (0..side) |y| for (0..side) |z| {
        var row = cells[y][z];
        while (row != 0) : (row &= row - 1) {
            const index = (y * side + z) * side + @ctz(row);
            const state = states[index];
            if (table[state] & replaceable == 0 or state == value) continue;
            mask[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            count += 1;
        }
    };
    return count;
}

/// Occluders of the plane at `at` along `axis` of a neighbouring section, laid out for
/// `Faces`: x planes row y, bit z; y planes row z, bit x; z planes row y, bit x. `source`
/// provides `get(local) u16` in section order.
pub fn readPlane(source: anytype, table: Table, comptime axis: usize, at: usize) [side]u16 {
    comptime assert(axis < 3);
    assert(at < side);
    var result: [side]u16 = @splat(0);
    for (0..side) |row| for (0..side) |bit| {
        const local = switch (axis) {
            0 => (row * side + bit) * side + at,
            1 => (at * side + row) * side + bit,
            2 => (row * side + at) * side + bit,
            else => unreachable,
        };
        result[row] |= @as(u16, @intFromBool(table[source.get(@intCast(local))] & occluder != 0)) << @intCast(bit);
    };
    return result;
}

/// Replaces hidden replaceable blocks with the section filler. Returns the number replaced.
pub fn apply(states: *[volume]u16, faces: *const Faces, table: Table) usize {
    const occupied = rows(states, table);
    const cells = hidden(&occupied, faces);
    var any: u16 = 0;
    for (cells) |plane| for (plane) |row| {
        any |= row;
    };
    if (any == 0) return 0;
    const value = filler(states, table) orelse return 0;
    var replaced: usize = 0;
    for (0..side) |y| for (0..side) |z| {
        var row = cells[y][z];
        while (row != 0) : (row &= row - 1) {
            const state = &states[(y * side + z) * side + @ctz(row)];
            if (table[state.*] & replaceable == 0 or state.* == value) continue;
            state.* = value;
            replaced += 1;
        }
    };
    assert(replaced <= volume);
    return replaced;
}

fn testTable() [8]u8 {
    // 0 air, 1 stone, 2 ore, 3 furnace (occluder with a block entity), 4 glass (not an occluder).
    return .{ 0, occluder | replaceable, occluder | replaceable, occluder, 0, 0, 0, 0 };
}

test "hidden cells match a direct neighbour check across random sections and faces" {
    const table = testTable();
    var random = std.Random.DefaultPrng.init(0x4b11);
    for (0..64) |trial| {
        var states: [4096]u16 = undefined;
        for (&states) |*state| state.* = if (random.random().uintLessThan(u8, 100) < 90 - trial) @intCast(1 + random.random().uintLessThan(u8, 3)) else if (random.random().boolean()) 0 else 4;
        var faces: Faces = undefined;
        for (&faces) |*plane| for (plane) |*row| {
            row.* = if (trial % 4 == 0) 0xffff else random.random().int(u16) | random.random().int(u16);
        };
        const occupied = rows(&states, &table);
        const result = hidden(&occupied, &faces);
        for (0..16) |y| for (0..16) |z| for (0..16) |x| {
            const solid = struct {
                fn at(cells: *const [4096]u16, sides: *const Faces, lookup: *const [8]u8, cx: i32, cy: i32, cz: i32) bool {
                    if (cx < 0) return (sides[0][@intCast(cy)] >> @intCast(cz)) & 1 != 0;
                    if (cx > 15) return (sides[1][@intCast(cy)] >> @intCast(cz)) & 1 != 0;
                    if (cy < 0) return (sides[2][@intCast(cz)] >> @intCast(cx)) & 1 != 0;
                    if (cy > 15) return (sides[3][@intCast(cz)] >> @intCast(cx)) & 1 != 0;
                    if (cz < 0) return (sides[4][@intCast(cy)] >> @intCast(cx)) & 1 != 0;
                    if (cz > 15) return (sides[5][@intCast(cy)] >> @intCast(cx)) & 1 != 0;
                    return lookup[cells[@intCast(cy * 256 + cz * 16 + cx)]] & occluder != 0;
                }
            }.at;
            const ix: i32 = @intCast(x);
            const iy: i32 = @intCast(y);
            const iz: i32 = @intCast(z);
            const expected = solid(&states, &faces, &table, ix, iy, iz) and solid(&states, &faces, &table, ix - 1, iy, iz) and solid(&states, &faces, &table, ix + 1, iy, iz) and
                solid(&states, &faces, &table, ix, iy - 1, iz) and solid(&states, &faces, &table, ix, iy + 1, iz) and solid(&states, &faces, &table, ix, iy, iz - 1) and solid(&states, &faces, &table, ix, iy, iz + 1);
            try std.testing.expectEqual(expected, (result[y][z] >> @intCast(x)) & 1 != 0);
        };
    }
}

test "faces of a section line up with the neighbour that reads them" {
    var random = std.Random.DefaultPrng.init(0xface);
    var occupied: [16][16]u16 = undefined;
    for (&occupied) |*plane| for (plane) |*row| {
        row.* = random.random().int(u16);
    };
    // The +x face of this section is the -x neighbour face of the section to its east.
    const east = face(&occupied, 1);
    for (0..16) |y| for (0..16) |z| {
        try std.testing.expectEqual((occupied[y][z] >> 15) & 1, (east[y] >> @intCast(z)) & 1);
    };
    const below = face(&occupied, 2);
    for (0..16) |z| try std.testing.expectEqual(occupied[0][z], below[z]);
    const north = face(&occupied, 4);
    for (0..16) |y| try std.testing.expectEqual(occupied[y][0], north[y]);
}

test "only hidden replaceable blocks change, to the most common replaceable block" {
    const table = testTable();
    var states: [4096]u16 = @splat(1);
    states[8 * 256 + 8 * 16 + 8] = 2;
    states[8 * 256 + 8 * 16 + 9] = 3;
    states[0] = 2;
    states[15 * 256 + 4 * 16 + 4] = 2;
    states[14 * 256 + 4 * 16 + 4] = 2;
    const sealed: Faces = @splat(@splat(0xffff));
    try std.testing.expectEqual(@as(usize, 4), apply(&states, &sealed, &table));
    try std.testing.expectEqual(@as(u16, 1), states[8 * 256 + 8 * 16 + 8]);
    try std.testing.expectEqual(@as(u16, 3), states[8 * 256 + 8 * 16 + 9]);
    try std.testing.expectEqual(@as(u16, 1), states[0]);
    states[15 * 256 + 4 * 16 + 4] = 2;
    states[0] = 2;
    var open = sealed;
    open[3] = @splat(0);
    open[0][0] = 0;
    _ = apply(&states, &open, &table);
    try std.testing.expectEqual(@as(u16, 2), states[15 * 256 + 4 * 16 + 4]);
    try std.testing.expectEqual(@as(u16, 2), states[0]);
    // A block next to air stays exposed.
    states[5 * 256 + 5 * 16 + 5] = 0;
    states[5 * 256 + 5 * 16 + 6] = 2;
    _ = apply(&states, &sealed, &table);
    try std.testing.expectEqual(@as(u16, 2), states[5 * 256 + 5 * 16 + 6]);
}

test "sections without replaceable blocks and open sections stay untouched" {
    const table = testTable();
    const sealed: Faces = @splat(@splat(0xffff));
    var furnaces: [volume]u16 = @splat(3);
    try std.testing.expectEqual(@as(?u16, null), filler(&furnaces, &table));
    try std.testing.expectEqual(@as(usize, 0), apply(&furnaces, &sealed, &table));
    for (furnaces) |state| try std.testing.expectEqual(@as(u16, 3), state);
    var open: [volume]u16 = @splat(0);
    try std.testing.expectEqual(@as(usize, 0), apply(&open, &sealed, &table));
}

test "changed cells match replacement and planes agree with faces" {
    const table = testTable();
    var random = std.Random.DefaultPrng.init(0xc4a9);
    const Source = struct {
        states: *const [volume]u16,
        pub fn get(self: @This(), local: u12) u16 {
            return self.states[local];
        }
    };
    for (0..128) |trial| {
        var states: [volume]u16 = undefined;
        for (&states) |*state| state.* = switch (random.random().uintLessThan(u8, 100)) {
            0...1 => 0,
            2...3 => if (trial % 3 == 0) 2 else 1,
            4 => 3,
            else => 1,
        };
        var faces: Faces = undefined;
        for (&faces) |*plane_rows| for (plane_rows) |*row| {
            row.* = if (trial % 2 == 0) 0xffff else random.random().int(u16);
        };
        var copy = states;
        const replaced = apply(&copy, &faces, &table);
        // The mask names exactly the cells replacement changed.
        var mask: [volume / 64]u64 = undefined;
        const marked = changedCells(&states, &faces, &table, &mask);
        var changed: usize = 0;
        for (states, copy, 0..) |before, after, index| {
            try std.testing.expectEqual(before != after, mask[index / 64] >> @intCast(index % 64) & 1 != 0);
            changed += @intFromBool(before != after);
        }
        try std.testing.expectEqual(changed, marked);
        try std.testing.expectEqual(replaced, marked);
        const occupied = rows(&states, &table);
        const source: Source = .{ .states = &states };
        inline for (0..6) |index| {
            const expected = face(&occupied, index);
            const actual = readPlane(source, &table, index / 2, if (index % 2 == 0) 0 else side - 1);
            try std.testing.expectEqualSlices(u16, &expected, &actual);
        }
    }
}
