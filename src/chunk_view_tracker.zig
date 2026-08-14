const geometry = @import("world/geometry.zig");
const std = @import("std");
const preallocated = @import("preallocated");
const config = @import("config.zig").value;

pub const visible_radius: i32 = config.view_distance_chunks;
pub const radius: i32 = visible_radius;
pub const diameter: usize = @intCast(radius * 2 + 1);
pub const chunk_count: usize = diameter * diameter;
const bit_word_count = std.math.divCeil(usize, chunk_count, 64) catch unreachable;
const radial_indices = buildRadialIndices();

pub const Tracker = struct {
    pub const MissingIterator = struct {
        tracker: *const Tracker,
        cursor: usize,

        pub fn next(self: *MissingIterator) ?geometry.ChunkPos {
            while (self.cursor < radial_indices.len) {
                const index = radial_indices[self.cursor];
                self.cursor += 1;
                if (!self.tracker.bit(index) or
                    self.tracker.dirtyBit(index))
                    return positionForIndex(self.tracker.center, index);
            }
            return null;
        }
    };

    center: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    sent_count: usize = 0,
    radial_cursor: usize = 0,
    stream_radius: i32 = radius,
    sent_bits: []u64 = &.{},
    dirty_bits: []u64 = &.{},

    pub fn allocate(self: *Tracker, allocator: std.mem.Allocator) !void {
        self.* = .{};
        self.sent_bits = try preallocated.alloc(u64, allocator, bit_word_count);
        self.dirty_bits = try preallocated.alloc(u64, allocator, bit_word_count);
    }

    pub fn reset(self: *Tracker, center: geometry.ChunkPos) void {
        self.center = center;
        self.sent_count = 0;
        self.radial_cursor = 0;
        @memset(self.sent_bits, 0);
        @memset(self.dirty_bits, 0);
        self.maskOutsideStream();
    }

    pub fn setRadius(self: *Tracker, center: geometry.ChunkPos, requested_radius: i32) void {
        std.debug.assert(requested_radius >= 0 and requested_radius <= visible_radius);
        self.stream_radius = requested_radius;
        self.reset(center);
    }

    fn maskOutsideStream(self: *Tracker) void {
        if (self.stream_radius == radius) {
            self.advanceCursor();
            return;
        }
        for (radial_indices) |index| {
            const position = positionForIndex(self.center, index);
            const dx = position.x - self.center.x;
            const dz = position.z - self.center.z;
            const inside =
                @abs(dx) <= self.stream_radius and @abs(dz) <= self.stream_radius;
            if (inside) continue;
            if (!self.bit(index)) {
                self.setBit(index);
                self.sent_count += 1;
            }
            self.clearDirtyBit(index);
        }
        self.advanceCursor();
    }

    pub fn has(self: *const Tracker, pos: geometry.ChunkPos) bool {
        const index = viewIndex(pos, self.center) orelse return false;
        return self.bit(index);
    }

    pub fn delivered(self: *const Tracker, pos: geometry.ChunkPos) bool {
        if (@abs(pos.x - self.center.x) > self.stream_radius or
            @abs(pos.z - self.center.z) > self.stream_radius)
            return false;
        return self.has(pos);
    }

    pub fn ready(self: *const Tracker, pos: geometry.ChunkPos) bool {
        if (@abs(pos.x - self.center.x) > self.stream_radius or
            @abs(pos.z - self.center.z) > self.stream_radius)
            return false;
        const index = viewIndex(pos, self.center) orelse return false;
        return self.bit(index) and !self.dirtyBit(index);
    }

    pub fn mark(self: *Tracker, pos: geometry.ChunkPos) void {
        const index = viewIndex(pos, self.center) orelse return;
        if (self.bit(index)) {
            self.clearDirtyBit(index);
            self.advanceCursor();
            return;
        }
        if (self.sent_count >= chunk_count)
            std.debug.panic("chunk view tracker invariant failed: marking ({d}, {d}) around center ({d}, {d}) with sent count {d} at capacity {d}", .{ pos.x, pos.z, self.center.x, self.center.z, self.sent_count, chunk_count });
        self.setBit(index);
        self.sent_count += 1;
        self.advanceCursor();
    }

    pub fn unmark(self: *Tracker, pos: geometry.ChunkPos) bool {
        if (@abs(pos.x - self.center.x) > self.stream_radius or
            @abs(pos.z - self.center.z) > self.stream_radius)
            return false;
        const index = viewIndex(pos, self.center) orelse return false;
        if (!self.bit(index)) return false;
        self.clearBit(index);
        self.clearDirtyBit(index);
        self.sent_count -= 1;
        self.radial_cursor = 0;
        self.advanceCursor();
        return true;
    }

    pub fn markDirty(self: *Tracker, pos: geometry.ChunkPos) bool {
        if (@abs(pos.x - self.center.x) > self.stream_radius or
            @abs(pos.z - self.center.z) > self.stream_radius)
            return false;
        const index = viewIndex(pos, self.center) orelse return false;
        if (!self.bit(index) or self.dirtyBit(index)) return false;
        self.setDirtyBit(index);
        self.radial_cursor = 0;
        self.advanceCursor();
        return true;
    }

    pub fn recenter(self: *Tracker, center: geometry.ChunkPos) void {
        if (center.x == self.center.x and center.z == self.center.z) return;
        const old_center = self.center;
        self.center = center;
        const delta_x = center.x - old_center.x;
        const delta_z = center.z - old_center.z;
        if (@abs(delta_x) >= diameter or @abs(delta_z) >= diameter) {
            @memset(self.sent_bits, 0);
            @memset(self.dirty_bits, 0);
            self.sent_count = 0;
            self.radial_cursor = 0;
            return;
        }
        const shift = delta_z * @as(i32, @intCast(diameter)) + delta_x;
        translateBits(self.sent_bits, shift);
        translateBits(self.dirty_bits, shift);
        const first_x: usize = @intCast(@max(0, -delta_x));
        const last_x: usize = @intCast(@min(@as(i32, @intCast(diameter)), @as(i32, @intCast(diameter)) - delta_x));
        const first_z: usize = @intCast(@max(0, -delta_z));
        const last_z: usize = @intCast(@min(@as(i32, @intCast(diameter)), @as(i32, @intCast(diameter)) - delta_z));
        for (0..diameter) |z| {
            if (z < first_z or z >= last_z) {
                self.clearRange(z * diameter, diameter);
                clearBitsRange(self.dirty_bits, z * diameter, diameter);
                continue;
            }
            if (first_x != 0) {
                self.clearRange(z * diameter, first_x);
                clearBitsRange(self.dirty_bits, z * diameter, first_x);
            }
            if (last_x != diameter) {
                self.clearRange(z * diameter + last_x, diameter - last_x);
                clearBitsRange(self.dirty_bits, z * diameter + last_x, diameter - last_x);
            }
        }
        const tail_bits = chunk_count & 63;
        if (tail_bits != 0)
            self.sent_bits[self.sent_bits.len - 1] &= (@as(u64, 1) << @intCast(tail_bits)) - 1;
        if (tail_bits != 0)
            self.dirty_bits[self.dirty_bits.len - 1] &= (@as(u64, 1) << @intCast(tail_bits)) - 1;
        self.sent_count = 0;
        for (self.sent_bits) |word| self.sent_count += @popCount(word);
        self.maskOutsideStream();
        self.radial_cursor = 0;
        self.advanceCursor();
    }

    fn translateBits(bits_slice: []u64, shift: i32) void {
        const source = bits_slice;
        var translated = [_]u64{0} ** bit_word_count;
        if (shift > 0) {
            const amount: usize = @intCast(shift);
            const words = amount / 64;
            const bits: u6 = @intCast(amount & 63);
            for (&translated, 0..) |*destination, index| {
                const source_index = index + words;
                if (source_index >= source.len) break;
                destination.* = source[source_index] >> bits;
                if (bits != 0 and source_index + 1 < source.len)
                    destination.* |= source[source_index + 1] << @intCast(64 - @as(u7, bits));
            }
        } else {
            const amount: usize = @intCast(-shift);
            const words = amount / 64;
            const bits: u6 = @intCast(amount & 63);
            for (&translated, 0..) |*destination, index| {
                if (index < words) continue;
                const source_index = index - words;
                destination.* = source[source_index] << bits;
                if (bits != 0 and source_index != 0)
                    destination.* |= source[source_index - 1] >> @intCast(64 - @as(u7, bits));
            }
        }
        @memcpy(bits_slice, &translated);
    }

    fn clearRange(self: *Tracker, first: usize, len: usize) void {
        clearBitsRange(self.sent_bits, first, len);
    }

    fn clearBitsRange(bits: []u64, first: usize, len: usize) void {
        if (len == 0) return;
        const end = first + len;
        const first_word = first / 64;
        const last_word = (end - 1) / 64;
        const first_bit = first & 63;
        const end_bit = ((end - 1) & 63) + 1;
        if (first_word == last_word) {
            const clear_mask = lowMask(end_bit) & ~lowMask(first_bit);
            bits[first_word] &= ~clear_mask;
            return;
        }
        bits[first_word] &= lowMask(first_bit);
        for (first_word + 1..last_word) |word| bits[word] = 0;
        bits[last_word] &= ~lowMask(end_bit);
    }

    pub fn nextMissing(self: *const Tracker) ?geometry.ChunkPos {
        if (self.radial_cursor == radial_indices.len) return null;
        return positionForIndex(self.center, radial_indices[self.radial_cursor]);
    }

    pub fn nextMissingFrom(self: *const Tracker, cursor: *usize) ?geometry.ChunkPos {
        var iterator = MissingIterator{
            .tracker = self,
            .cursor = @max(cursor.*, self.radial_cursor),
        };
        const position = iterator.next();
        cursor.* = iterator.cursor;
        return position;
    }

    /// Iterates unsent chunks ahead of the radial cursor without changing the
    /// visible send order. A single cursor keeps prefetch linear in lookahead.
    pub fn missingIterator(self: *const Tracker) MissingIterator {
        return .{ .tracker = self, .cursor = self.radial_cursor };
    }

    fn advanceCursor(self: *Tracker) void {
        while (self.radial_cursor < radial_indices.len and
            (self.bit(radial_indices[self.radial_cursor]) and
                !self.dirtyBit(radial_indices[self.radial_cursor])))
            self.radial_cursor += 1;
    }

    fn bit(self: *const Tracker, index: usize) bool {
        const bit_index: u6 = @intCast(index & 63);
        return self.sent_bits[index / 64] & (@as(u64, 1) << bit_index) != 0;
    }

    fn setBit(self: *Tracker, index: usize) void {
        const bit_index: u6 = @intCast(index & 63);
        self.sent_bits[index / 64] |= @as(u64, 1) << bit_index;
    }

    fn clearBit(self: *Tracker, index: usize) void {
        const bit_index: u6 = @intCast(index & 63);
        self.sent_bits[index / 64] &= ~(@as(u64, 1) << bit_index);
    }

    fn dirtyBit(self: *const Tracker, index: usize) bool {
        const bit_index: u6 = @intCast(index & 63);
        return self.dirty_bits[index / 64] & (@as(u64, 1) << bit_index) != 0;
    }

    fn setDirtyBit(self: *Tracker, index: usize) void {
        const bit_index: u6 = @intCast(index & 63);
        self.dirty_bits[index / 64] |= @as(u64, 1) << bit_index;
    }

    fn clearDirtyBit(self: *Tracker, index: usize) void {
        const bit_index: u6 = @intCast(index & 63);
        self.dirty_bits[index / 64] &= ~(@as(u64, 1) << bit_index);
    }
};

test "bounded streaming cursor skips a pending nearest chunk" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });

    var cursor: usize = 0;
    const first = tracker.nextMissingFrom(&cursor).?;
    const second = tracker.nextMissingFrom(&cursor).?;
    try std.testing.expect(first.x != second.x or first.z != second.z);
    try std.testing.expectEqual(first, tracker.nextMissing().?);
}

inline fn lowMask(bits: usize) u64 {
    return if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
}

pub inline fn inView(pos: geometry.ChunkPos, center: geometry.ChunkPos) bool {
    return @abs(pos.x - center.x) <= visible_radius and
        @abs(pos.z - center.z) <= visible_radius;
}

pub inline fn inStream(pos: geometry.ChunkPos, center: geometry.ChunkPos) bool {
    return @abs(pos.x - center.x) <= radius and
        @abs(pos.z - center.z) <= radius;
}

fn viewIndex(pos: geometry.ChunkPos, center: geometry.ChunkPos) ?usize {
    const relative_x = pos.x - center.x + radius;
    const relative_z = pos.z - center.z + radius;
    if (relative_x < 0 or relative_z < 0 or relative_x >= @as(i32, @intCast(diameter)) or relative_z >= @as(i32, @intCast(diameter))) return null;
    return @as(usize, @intCast(relative_z)) * diameter + @as(usize, @intCast(relative_x));
}

fn positionForIndex(center: geometry.ChunkPos, index: usize) geometry.ChunkPos {
    return .{
        .x = center.x + @as(i32, @intCast(index % diameter)) - radius,
        .z = center.z + @as(i32, @intCast(index / diameter)) - radius,
    };
}

fn buildRadialIndices() [chunk_count]u16 {
    @setEvalBranchQuota(chunk_count * 128);
    var indices: [chunk_count]u16 = undefined;
    for (&indices, 0..) |*index, value| index.* = @intCast(value);

    var root = indices.len / 2;
    while (root != 0) {
        root -= 1;
        siftDown(&indices, root, indices.len);
    }
    var end = indices.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(u16, &indices[0], &indices[end]);
        siftDown(&indices, 0, end);
    }
    return indices;
}

fn siftDown(indices: *[chunk_count]u16, start: usize, end: usize) void {
    var root = start;
    while (root * 2 + 1 < end) {
        var child = root * 2 + 1;
        if (child + 1 < end and radialLess(indices[child], indices[child + 1])) child += 1;
        if (!radialLess(indices[root], indices[child])) return;
        std.mem.swap(u16, &indices[root], &indices[child]);
        root = child;
    }
}

fn radialLess(left_index: u16, right_index: u16) bool {
    const left = relativePosition(left_index);
    const right = relativePosition(right_index);
    const left_distance = left.x * left.x + left.z * left.z;
    const right_distance = right.x * right.x + right.z * right.z;
    if (left_distance != right_distance) return left_distance < right_distance;
    if (left.z != right.z) return left.z < right.z;
    return left.x < right.x;
}

fn relativePosition(index: u16) struct { x: i32, z: i32 } {
    const wide: usize = index;
    return .{
        .x = @as(i32, @intCast(wide % diameter)) - radius,
        .z = @as(i32, @intCast(wide / diameter)) - radius,
    };
}

test "tracker streams radially and retains membership" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });
    tracker.mark(.{ .x = 0, .z = 0 });
    const next = tracker.nextMissing().?;
    try std.testing.expect(inView(next, tracker.center));
    try std.testing.expect(!tracker.has(next));
}

test "unmark schedules an already sent chunk for radial retransmission" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });
    const center = geometry.ChunkPos{ .x = 0, .z = 0 };
    tracker.mark(center);
    try std.testing.expect(tracker.unmark(center));
    try std.testing.expect(!tracker.has(center));
    try std.testing.expect(geometry.sameChunk(center, tracker.nextMissing().?));
}

test "dirty retransmission preserves client chunk possession" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    const center = geometry.ChunkPos{ .x = 0, .z = 0 };
    tracker.reset(center);
    tracker.mark(center);
    try std.testing.expect(tracker.has(center));
    try std.testing.expect(tracker.markDirty(center));
    try std.testing.expect(tracker.has(center));
    try std.testing.expect(geometry.sameChunk(center, tracker.nextMissing().?));
    tracker.mark(center);
    try std.testing.expect(tracker.has(center));
    try std.testing.expect(!geometry.sameChunk(center, tracker.nextMissing().?));
}

test "radius sentinels cannot be scheduled for retransmission" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.setRadius(.{ .x = 0, .z = 0 }, 1);
    try std.testing.expect(!tracker.unmark(.{ .x = 2, .z = 0 }));
    try std.testing.expect(tracker.has(.{ .x = 2, .z = 0 }));
    try std.testing.expect(!tracker.delivered(.{ .x = 2, .z = 0 }));
}

test "reset preserves the configured stream radius" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.setRadius(.{ .x = 0, .z = 0 }, 1);
    tracker.reset(.{ .x = 7, .z = -4 });
    try std.testing.expect(tracker.has(.{ .x = 9, .z = -4 }));
    try std.testing.expect(!tracker.has(.{ .x = 8, .z = -4 }));
}

test "stream order is nondecreasing by Euclidean radius" {
    var previous_distance: i32 = -1;
    for (radial_indices) |index| {
        const position = relativePosition(index);
        const distance = position.x * position.x + position.z * position.z;
        try std.testing.expect(distance >= previous_distance);
        previous_distance = distance;
    }
}

test "missing iterator looks ahead without advancing stream order" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.reset(.{ .x = 4, .z = -3 });
    const first = tracker.nextMissing().?;
    var iterator = tracker.missingIterator();
    try std.testing.expect(geometry.sameChunk(first, iterator.next().?));
    const second = iterator.next().?;
    try std.testing.expect(!geometry.sameChunk(first, second));
    try std.testing.expect(geometry.sameChunk(first, tracker.nextMissing().?));
    iterator = tracker.missingIterator();
    try std.testing.expect(geometry.sameChunk(first, iterator.next().?));
    try std.testing.expect(geometry.sameChunk(second, iterator.next().?));
}

test "stream order covers the radial view exactly once" {
    var seen = [_]bool{false} ** chunk_count;
    for (radial_indices) |index| {
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "recenter retains overlap without growing beyond the view" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });
    for (radial_indices) |index| tracker.mark(positionForIndex(tracker.center, index));
    try std.testing.expectEqual(chunk_count, tracker.sent_count);
    tracker.recenter(.{ .x = 1, .z = 0 });
    try std.testing.expectEqual(chunk_count - diameter, tracker.sent_count);
    try std.testing.expect(tracker.delivered(.{
        .x = tracker.center.x + visible_radius - 1,
        .z = tracker.center.z,
    }));
    try std.testing.expect(!tracker.delivered(.{
        .x = tracker.center.x + visible_radius,
        .z = tracker.center.z,
    }));
    while (tracker.nextMissing()) |pos| tracker.mark(pos);
    try std.testing.expectEqual(chunk_count, tracker.sent_count);
}

test "stream radius equals the advertised view distance" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try tracker.allocate(arena.allocator());
    const center = geometry.ChunkPos{ .x = 7, .z = -3 };
    tracker.reset(center);
    const visible_edge = geometry.ChunkPos{
        .x = center.x + visible_radius,
        .z = center.z,
    };
    const outside = geometry.ChunkPos{
        .x = center.x + radius + 1,
        .z = center.z,
    };
    try std.testing.expect(inView(visible_edge, center));
    try std.testing.expect(!inStream(outside, center));
    tracker.mark(visible_edge);
    try std.testing.expect(tracker.delivered(visible_edge));
    try std.testing.expect(!tracker.delivered(outside));
}

test "packed recenter matches coordinate remapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var original: Tracker = .{};
    try original.allocate(arena.allocator());
    original.reset(.{ .x = 11, .z = -7 });
    for (radial_indices, 0..) |index, sample| {
        if (sample % 7 == 0 or sample % 19 == 0)
            original.mark(positionForIndex(original.center, index));
    }
    const deltas = [_]geometry.ChunkPos{
        .{ .x = -66, .z = 0 },
        .{ .x = -3, .z = 2 },
        .{ .x = -1, .z = 0 },
        .{ .x = 0, .z = -1 },
        .{ .x = 0, .z = 1 },
        .{ .x = 1, .z = 0 },
        .{ .x = 3, .z = -2 },
        .{ .x = 66, .z = 0 },
    };
    for (deltas) |delta| {
        const center = geometry.ChunkPos{ .x = original.center.x + delta.x, .z = original.center.z + delta.z };
        var actual: Tracker = .{};
        try actual.allocate(arena.allocator());
        actual.center = original.center;
        actual.sent_count = original.sent_count;
        actual.radial_cursor = original.radial_cursor;
        @memcpy(actual.sent_bits, original.sent_bits);
        actual.recenter(center);

        var expected: Tracker = .{};
        try expected.allocate(arena.allocator());
        expected.reset(center);
        for (0..chunk_count) |old_index| {
            if (!original.bit(old_index)) continue;
            const pos = positionForIndex(original.center, old_index);
            if (viewIndex(pos, center)) |new_index| {
                expected.setBit(new_index);
                expected.sent_count += 1;
            }
        }
        expected.advanceCursor();
        try std.testing.expectEqual(expected.sent_count, actual.sent_count);
        try std.testing.expectEqual(expected.radial_cursor, actual.radial_cursor);
        try std.testing.expectEqualSlices(u64, expected.sent_bits, actual.sent_bits);
    }
}
