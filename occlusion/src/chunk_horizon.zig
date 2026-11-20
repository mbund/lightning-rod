const std = @import("std");
const assert = std.debug.assert;

pub const Position = struct { x: i32, z: i32 };
pub const Span = struct {
    minimum: i64,
    maximum: i64,

    fn count(self: Span) usize {
        assert(self.minimum <= self.maximum);
        return @intCast(self.maximum - self.minimum + 1);
    }
};

pub const Index = struct {
    pub const Bit = struct { word: usize, mask: u64 };

    width: u32,
    reciprocal: u64,
    columns: usize,
    words: usize,

    pub fn init(width: i32) Index {
        assert(width > 0);
        const side: usize = @intCast(width);
        const columns = side * side;
        return .{ .width = @intCast(width), .reciprocal = (@as(u64, std.math.maxInt(u64)) / @as(u32, @intCast(width))) +% 1, .columns = columns, .words = (columns + 63) / 64 };
    }

    pub fn wrap(self: *const Index, coordinate: i32) usize {
        // Lemire et al., Faster Remainder by Direct Computation (2019).
        const low = self.reciprocal *% @as(u64, @abs(coordinate));
        const remainder: u32 = @intCast((@as(u128, low) * self.width) >> 64);
        assert(remainder < self.width);
        return if (coordinate < 0 and remainder != 0) self.width - remainder else remainder;
    }

    pub fn at(self: *const Index, position: Position) usize {
        const slot = self.wrap(position.z) * self.width + self.wrap(position.x);
        assert(slot < self.columns);
        return slot;
    }

    pub fn bit(self: *const Index, player: usize, position: Position) Bit {
        const slot = self.at(position);
        return .{ .word = player * self.words + slot / 64, .mask = @as(u64, 1) << @intCast(slot % 64) };
    }
};

/// Vanilla ChunkTrackingView.isInViewDistance measures from the nearest edge
/// of the source chunk and uses a strict squared distance comparison.
pub fn contains(radius: i32, center: Position, at: Position) bool {
    assert(radius >= 0);
    const x = @abs(@as(i64, at.x) - center.x);
    const z = @abs(@as(i64, at.z) - center.z);
    const r: u64 = @intCast(radius);
    if (x > r or z > r) return false;
    if (radius == 0) return true;
    return (x -| 1) * (x -| 1) + (z -| 1) * (z -| 1) < r * r;
}

pub fn row(radius: i32, z: i64) ?Span {
    assert(radius >= 0);
    const r: u64 = @intCast(radius);
    if (@abs(z) > r) return null;
    if (radius == 0) return .{ .minimum = 0, .maximum = 0 };
    const distance = @abs(z) -| 1;
    const x: i64 = @intCast(@min(r, 1 + std.math.sqrt(r * r - distance * distance - 1)));
    return .{ .minimum = -x, .maximum = x };
}

pub fn count(radius: i32) usize {
    assert(radius >= 0);
    var result: usize = 0;
    var z = -@as(i64, radius);
    while (z <= radius) : (z += 1) result += row(radius, z).?.count();
    return result;
}

/// Storage tiles stay adjacent. Alignments share one allocation across all
/// observers and require no sorting during delivery.
pub const Order = struct {
    radius: i32,
    tile_side: u8,
    // The first half packs two u16 coordinates. The second maps coordinates back to ranks.
    ranks: []u32,

    pub fn init(allocator: std.mem.Allocator, radius: i32, tile_side: u8) !Order {
        if (radius < 0 or (tile_side != 1 and tile_side != 2 and tile_side != 4)) return error.InvalidRadius;
        const side: usize = try std.math.add(usize, try std.math.mul(usize, @intCast(radius), 2), 1);
        const area = try std.math.mul(usize, side, side);
        if (area > std.math.maxInt(u32)) return error.InvalidRadius;
        const alignments = @as(usize, tile_side) * tile_side;
        const entries = try std.math.mul(usize, alignments, area);
        const ranks = try allocator.alloc(u32, try std.math.mul(usize, entries, 2));
        const rings: usize = @intCast(@divFloor(radius + tile_side - 1, tile_side));
        const tiles = (2 * rings + 1) * (2 * rings + 1);
        for (0..alignments) |alignment| {
            const origin: Position = .{ .x = @intCast(alignment % tile_side), .z = @intCast(alignment / tile_side) };
            var written: usize = 0;
            var center: usize = 0;
            for (0..tiles) |rank| {
                const tile = spiral(rank);
                for (0..alignments) |cell| {
                    const x = tile.x * tile_side + @as(i32, @intCast(cell % tile_side)) - origin.x;
                    const z = tile.z * tile_side + @as(i32, @intCast(cell / tile_side)) - origin.z;
                    if (@abs(x) > radius or @abs(z) > radius) continue;
                    if (x == 0 and z == 0) center = written;
                    ranks[alignment * area + written] = @as(u32, @intCast(z + radius)) << 16 | @as(u32, @intCast(x + radius));
                    written += 1;
                }
            }
            assert(written == area);
            std.mem.swap(u32, &ranks[alignment * area], &ranks[alignment * area + center]);
            for (ranks[alignment * area ..][0..area], 0..) |offset, rank| ranks[entries + alignment * area + @as(usize, offset >> 16) * side + (offset & 65535)] = @intCast(rank);
        }
        return .{ .radius = radius, .tile_side = tile_side, .ranks = ranks };
    }

    pub fn at(self: Order, center: Position, rank: usize) Position {
        const side: usize = @intCast(2 * self.radius + 1);
        const area = side * side;
        assert(rank < area and self.ranks.len == 2 * @as(usize, self.tile_side) * self.tile_side * area);
        const mask: u32 = self.tile_side - 1;
        const alignment: usize = (@as(u32, @bitCast(center.z)) & mask) * self.tile_side + (@as(u32, @bitCast(center.x)) & mask);
        const offset = self.ranks[alignment * area + rank];
        return .{ .x = center.x - self.radius + @as(i32, @intCast(offset & 65535)), .z = center.z - self.radius + @as(i32, @intCast(offset >> 16)) };
    }

    pub fn positionRank(self: Order, center: Position, position: Position) usize {
        const side: usize = @intCast(2 * self.radius + 1);
        const area = side * side;
        const x = @as(i64, position.x) - center.x + self.radius;
        const z = @as(i64, position.z) - center.z + self.radius;
        assert(x >= 0 and z >= 0 and x < side and z < side);
        const mask: u32 = self.tile_side - 1;
        const alignment: usize = (@as(u32, @bitCast(center.z)) & mask) * self.tile_side + (@as(u32, @bitCast(center.x)) & mask);
        return self.ranks[@as(usize, self.tile_side) * self.tile_side * area + alignment * area + @as(usize, @intCast(z)) * side + @as(usize, @intCast(x))];
    }

    pub fn sameTile(self: Order, a: Position, b: Position) bool {
        const mask = ~@as(i32, self.tile_side - 1);
        return a.x & mask == b.x & mask and a.z & mask == b.z & mask;
    }
};

pub fn spiral(index: usize) Position {
    if (index == 0) return .{ .x = 0, .z = 0 };
    const ring: i32 = @intCast((std.math.sqrt(index) + 1) / 2);
    const side = ring * 2;
    const start = @as(usize, @intCast(side - 1)) * @as(usize, @intCast(side - 1));
    const offset: i32 = @intCast(index - start);
    return switch (@divTrunc(offset, side)) {
        0 => .{ .x = ring, .z = -ring + 1 + offset },
        1 => .{ .x = ring - 1 - (offset - side), .z = ring },
        2 => .{ .x = -ring, .z = ring - 1 - (offset - 2 * side) },
        3 => .{ .x = -ring + 1 + (offset - 3 * side), .z = -ring },
        else => unreachable,
    };
}

/// The columns within `radius` of `center` and not within `target_radius` of `target`: what leaves
/// a view that moves or narrows, or with the two swapped, what a view gains. Each row produces at
/// most two departing spans. Retained columns are skipped in one step and retries copy the cursor
/// without restarting the search.
pub const Difference = struct {
    center: Position = .{ .x = 0, .z = 0 },
    target: Position = .{ .x = 0, .z = 0 },
    radius: i32 = 0,
    target_radius: i32 = 0,
    z: i64 = 1,
    x: i64 = 0,
    end: i64 = 0,
    skip: Span = .{ .minimum = 1, .maximum = 0 },
    started: bool = false,

    pub fn init(center: Position, target: Position, radius: i32) Difference {
        return resized(center, radius, target, radius);
    }

    pub fn resized(center: Position, radius: i32, target: Position, target_radius: i32) Difference {
        assert(radius >= 0 and target_radius >= 0);
        assert(@as(i64, center.x) - radius >= std.math.minInt(i32) and @as(i64, center.x) + radius <= std.math.maxInt(i32));
        assert(@as(i64, center.z) - radius >= std.math.minInt(i32) and @as(i64, center.z) + radius <= std.math.maxInt(i32));
        return .{ .center = center, .target = target, .radius = radius, .target_radius = target_radius, .z = -@as(i64, radius) };
    }

    pub fn next(self: *Difference) ?Position {
        while (self.z <= self.radius) {
            const z = @as(i64, self.center.z) + self.z;
            if (!self.started) {
                const source = row(self.radius, self.z).?;
                self.x = @as(i64, self.center.x) + source.minimum;
                self.end = @as(i64, self.center.x) + source.maximum;
                self.skip = if (row(self.target_radius, z - self.target.z)) |target| .{
                    .minimum = @as(i64, self.target.x) + target.minimum,
                    .maximum = @as(i64, self.target.x) + target.maximum,
                } else .{ .minimum = 1, .maximum = 0 };
                self.started = true;
            }
            if (self.x >= self.skip.minimum and self.x <= self.skip.maximum) self.x = self.skip.maximum + 1;
            if (self.x <= self.end) {
                const at: Position = .{ .x = @intCast(self.x), .z = @intCast(z) };
                self.x += 1;
                assert(contains(self.radius, self.center, at) and !contains(self.target_radius, self.target, at));
                return at;
            }
            self.z += 1;
            self.started = false;
        }
        return null;
    }
};

pub fn differenceCount(radius: i32, center: Position, target: Position) usize {
    assert(radius >= 0);
    if (std.meta.eql(center, target)) return 0;
    var result: usize = 0;
    var z = -@as(i64, radius);
    while (z <= radius) : (z += 1) {
        const source = row(radius, z).?;
        var overlap: usize = 0;
        if (row(radius, @as(i64, center.z) + z - target.z)) |other| {
            const minimum = @max(@as(i64, center.x) + source.minimum, @as(i64, target.x) + other.minimum);
            const maximum = @min(@as(i64, center.x) + source.maximum, @as(i64, target.x) + other.maximum);
            if (minimum <= maximum) overlap = @intCast(maximum - minimum + 1);
        }
        result += source.count() - overlap;
    }
    return result;
}

test "circular horizons retain vanilla chunk edge padding" {
    try std.testing.expectEqual(@as(usize, 3461), count(32));
    try std.testing.expectEqual(@as(usize, 4121), count(35));
    const center: Position = .{ .x = -17, .z = 31 };
    try std.testing.expect(contains(32, center, .{ .x = center.x + 32, .z = center.z }));
    try std.testing.expect(!contains(32, center, .{ .x = center.x + 32, .z = center.z + 32 }));
    for (0..65) |r| {
        const radius: i32 = @intCast(r);
        var total: usize = 0;
        var z = -radius - 1;
        while (z <= radius + 1) : (z += 1) {
            const span = row(radius, z);
            var x = -radius - 1;
            while (x <= radius + 1) : (x += 1) {
                const expected = if (span) |value| x >= value.minimum and x <= value.maximum else false;
                try std.testing.expectEqual(expected, contains(radius, center, .{ .x = center.x + x, .z = center.z + z }));
                total += @intFromBool(expected);
            }
        }
        try std.testing.expectEqual(total, count(radius));
    }
}

test "storage ordered horizons cover every column once and finish each tile before leaving" {
    for ([_]i32{ 0, 1, 2, 4, 8, 32, 35 }) |radius| {
        const order = try Order.init(std.testing.allocator, radius, 4);
        defer std.testing.allocator.free(order.ranks);
        const side: usize = @intCast(2 * radius + 1);
        var seen: [71 * 71]bool = undefined;
        for (0..16) |alignment| {
            @memset(&seen, false);
            const center: Position = .{ .x = @as(i32, @intCast(alignment % 4)) - 8, .z = @as(i32, @intCast(alignment / 4)) - 8 };
            try std.testing.expectEqualDeep(center, order.at(center, 0));
            var previous = order.at(center, 0);
            for (0..side * side) |rank| {
                const at = order.at(center, rank);
                const index = @as(usize, @intCast(at.z - center.z + radius)) * side + @as(usize, @intCast(at.x - center.x + radius));
                try std.testing.expectEqual(rank, order.positionRank(center, at));
                try std.testing.expect(!seen[index]);
                seen[index] = true;
                const same_tile = @divFloor(at.x, 4) == @divFloor(previous.x, 4) and @divFloor(at.z, 4) == @divFloor(previous.z, 4);
                if (!same_tile) for (0..16) |cell| {
                    const x = @divFloor(previous.x, 4) * 4 + @as(i32, @intCast(cell % 4)) - center.x + radius;
                    const z = @divFloor(previous.z, 4) * 4 + @as(i32, @intCast(cell / 4)) - center.z + radius;
                    if (x < 0 or z < 0 or x >= side or z >= side) continue;
                    try std.testing.expect(seen[@as(usize, @intCast(z)) * side + @as(usize, @intCast(x))]);
                };
                previous = at;
            }
            try std.testing.expect(std.mem.allEqual(bool, seen[0 .. side * side], true));
        }
    }
}

test "circular membership matches the vanilla 1.21.8 and 26.2 view predicate" {
    var hash: u64 = 0xcbf29ce484222325;
    for (1..65) |r| {
        const radius: i32 = @intCast(r);
        var z = -radius - 2;
        while (z <= radius + 2) : (z += 1) {
            var x = -radius - 2;
            while (x <= radius + 2) : (x += 1) {
                hash = (hash ^ @as(u64, @intFromBool(contains(radius, .{ .x = -17, .z = 31 }, .{ .x = x - 17, .z = z + 31 })))) *% 0x100000001b3;
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0xdb55ab4890362f95), hash);
}

test "circular departures equal set subtraction across movement and teleports" {
    const center: Position = .{ .x = -17, .z = 31 };
    for ([_]i32{ 0, 1, 2, 4, 8, 32, 35 }) |radius| for ([_]i32{ -73, -3, -1, 0, 1, 3, 73 }) |dx| for ([_]i32{ -73, -3, -1, 0, 1, 3, 73 }) |dz| {
        const target: Position = .{ .x = center.x + dx, .z = center.z + dz };
        const side: usize = @intCast(radius * 2 + 1);
        var seen: [71 * 71]bool = @splat(false);
        var difference = Difference.init(center, target, radius);
        var departed: usize = 0;
        while (difference.next()) |at| {
            const index = @as(usize, @intCast(at.z - center.z + radius)) * side + @as(usize, @intCast(at.x - center.x + radius));
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            departed += 1;
        }
        var expected: usize = 0;
        for (0..side * side) |index| {
            const at: Position = .{ .x = center.x + @as(i32, @intCast(index % side)) - radius, .z = center.z + @as(i32, @intCast(index / side)) - radius };
            const removed = contains(radius, center, at) and !contains(radius, target, at);
            try std.testing.expectEqual(removed, seen[index]);
            expected += @intFromBool(removed);
        }
        try std.testing.expectEqual(expected, departed);
        try std.testing.expectEqual(expected, differenceCount(radius, center, target));
        try std.testing.expectEqual(expected, differenceCount(radius, target, center));
        try std.testing.expectEqual(null, difference.next());
    };
}

test "resized departures equal set subtraction as views widen, narrow and move" {
    const center: Position = .{ .x = 5, .z = -9 };
    for ([_]i32{ 0, 2, 7, 16, 32 }) |radius| for ([_]i32{ 0, 2, 7, 16, 32 }) |target_radius| for ([_]i32{ -40, -1, 0, 3 }) |dx| for ([_]i32{ -2, 0, 40 }) |dz| {
        const target: Position = .{ .x = center.x + dx, .z = center.z + dz };
        const side: usize = @intCast(radius * 2 + 1);
        var seen: [65 * 65]bool = @splat(false);
        var difference = Difference.resized(center, radius, target, target_radius);
        var departed: usize = 0;
        while (difference.next()) |at| {
            const index = @as(usize, @intCast(at.z - center.z + radius)) * side + @as(usize, @intCast(at.x - center.x + radius));
            try std.testing.expect(!seen[index]);
            seen[index] = true;
            departed += 1;
        }
        var expected: usize = 0;
        for (0..side * side) |index| {
            const at: Position = .{ .x = center.x + @as(i32, @intCast(index % side)) - radius, .z = center.z + @as(i32, @intCast(index / side)) - radius };
            const removed = contains(radius, center, at) and !contains(target_radius, target, at);
            try std.testing.expectEqual(removed, seen[index]);
            expected += @intFromBool(removed);
        }
        try std.testing.expectEqual(expected, departed);
    };
}

test "column order follows configured storage tile sizes" {
    for ([_]u8{ 1, 2 }) |tile_side| {
        const order = try Order.init(std.testing.allocator, 8, tile_side);
        defer std.testing.allocator.free(order.ranks);
        const center: Position = .{ .x = -7, .z = -3 };
        var seen: [17 * 17]bool = @splat(false);
        for (0..seen.len) |rank| {
            const at = order.at(center, rank);
            const index = @as(usize, @intCast(at.z - center.z + 8)) * 17 + @as(usize, @intCast(at.x - center.x + 8));
            try std.testing.expect(!seen[index]);
            seen[index] = true;
        }
        try std.testing.expect(std.mem.allEqual(bool, &seen, true));
    }
}

test "ring indexing matches signed modulo across widths coordinates and bitmap boundaries" {
    var random = std.Random.DefaultPrng.init(0x384921);
    for ([_]i32{ 1, 2, 3, 7, 8, 9, 31, 32, 33, 65, 127, 128, 129, 1023, 32767, 32768, 65535, std.math.maxInt(i32) }) |width| {
        const index = Index.init(width);
        for ([_]i32{ std.math.minInt(i32), std.math.minInt(i32) + 1, -65536, -65535, -65, -1, 0, 1, 65, 65535, std.math.maxInt(i32) }) |coordinate| try std.testing.expectEqual(@as(usize, @intCast(@mod(coordinate, width))), index.wrap(coordinate));
        for (0..65536) |trial| {
            const at: Position = .{ .x = random.random().int(i32), .z = random.random().int(i32) };
            const expected = @as(usize, @intCast(@mod(at.z, width))) * @as(usize, @intCast(width)) + @as(usize, @intCast(@mod(at.x, width)));
            try std.testing.expectEqual(expected, index.at(at));
            const player = trial % 4;
            const actual = index.bit(player, at);
            try std.testing.expectEqual(player * index.words + expected / 64, actual.word);
            try std.testing.expectEqual(@as(u64, 1) << @as(u6, @intCast(expected % 64)), actual.mask);
        }
    }
}
