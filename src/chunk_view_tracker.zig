const geometry = @import("world/geometry.zig");
const std = @import("std");
const preallocated = @import("preallocated");
pub const Order = struct {
    indices: []u16 = &.{},
    radius: i32 = 0,
    grid_radius: i32 = 0,
    diameter: usize = 0,

    pub fn create(allocator: std.mem.Allocator, radius: i32) !Order {
        if (radius < 0) return error.InvalidViewDistance;
        const grid_radius = radius + @intFromBool(radius >= 2);
        const diameter: usize = @intCast(grid_radius * 2 + 1);
        const grid_count = diameter * diameter;
        if (grid_count > std.math.maxInt(u16)) return error.ViewDistanceTooLarge;
        const chunk_count = viewChunkCount(radius, grid_radius);
        const result = Order{
            .indices = try preallocated.alloc(u16, allocator, chunk_count),
            .radius = radius,
            .grid_radius = grid_radius,
            .diameter = diameter,
        };
        initializeStreamOrder(result.indices, radius, grid_radius);
        return result;
    }
};

pub const Tracker = struct {
    pub const MissingIterator = struct {
        tracker: *const Tracker,
        cursor: usize,

        pub fn next(self: *MissingIterator) ?geometry.ChunkPos {
            while (self.cursor < self.tracker.order.len) {
                const index = self.tracker.order[self.cursor];
                self.cursor += 1;
                const position = self.tracker.positionForIndex(self.tracker.center, index);
                if (!inView(self.tracker.stream_radius, position, self.tracker.center)) continue;
                if (!self.tracker.bit(index) or self.tracker.dirtyBit(index)) return position;
            }
            return null;
        }
    };

    center: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    sent_count: usize = 0,
    stream_cursor: usize = 0,
    stream_radius: i32 = 0,
    maximum_radius: i32 = 0,
    grid_radius: i32 = 0,
    diameter: usize = 0,
    translated_bits: []u64 = &.{},
    order: []const u16 = &.{},
    sent_bits: []u64 = &.{},
    dirty_bits: []u64 = &.{},

    pub fn allocate(self: *Tracker, allocator: std.mem.Allocator, order: *const Order) !void {
        self.* = .{};
        self.order = order.indices;
        self.maximum_radius = order.radius;
        self.grid_radius = order.grid_radius;
        self.stream_radius = order.radius;
        self.diameter = order.diameter;
        const words = std.math.divCeil(usize, order.diameter * order.diameter, 64) catch unreachable;
        self.sent_bits = try preallocated.alloc(u64, allocator, words);
        self.dirty_bits = try preallocated.alloc(u64, allocator, words);
        self.translated_bits = try preallocated.alloc(u64, allocator, words);
    }

    pub fn reset(self: *Tracker, center: geometry.ChunkPos) void {
        self.center = center;
        self.sent_count = 0;
        self.stream_cursor = 0;
        @memset(self.sent_bits, 0);
        @memset(self.dirty_bits, 0);
        self.maskOutsideStream();
    }

    pub fn setRadius(self: *Tracker, center: geometry.ChunkPos, requested_radius: i32) void {
        std.debug.assert(requested_radius >= 0 and requested_radius <= self.maximum_radius);
        self.stream_radius = requested_radius;
        self.reset(center);
    }

    fn maskOutsideStream(self: *Tracker) void {
        for (0..self.diameter * self.diameter) |index| {
            const position = self.positionForIndex(self.center, index);
            if (inView(self.stream_radius, position, self.center)) continue;
            self.clearBit(index);
            self.clearDirtyBit(index);
        }
        const grid_bits = self.diameter * self.diameter;
        const tail_bits = grid_bits & 63;
        if (tail_bits != 0) {
            const mask = lowMask(tail_bits);
            self.sent_bits[self.sent_bits.len - 1] &= mask;
            self.dirty_bits[self.dirty_bits.len - 1] &= mask;
        }
        self.sent_count = 0;
        for (self.order) |index|
            self.sent_count += @intFromBool(self.bit(index));
        self.advanceCursor();
    }

    pub fn has(self: *const Tracker, pos: geometry.ChunkPos) bool {
        if (!inView(self.stream_radius, pos, self.center)) return false;
        const index = self.viewIndex(pos, self.center) orelse return false;
        return self.bit(index);
    }

    pub fn delivered(self: *const Tracker, pos: geometry.ChunkPos) bool {
        if (!inView(self.stream_radius, pos, self.center)) return false;
        return self.has(pos);
    }

    pub fn ready(self: *const Tracker, pos: geometry.ChunkPos) bool {
        if (@abs(pos.x - self.center.x) > self.stream_radius or
            @abs(pos.z - self.center.z) > self.stream_radius)
            return false;
        const index = self.viewIndex(pos, self.center) orelse return false;
        return self.bit(index) and !self.dirtyBit(index);
    }

    pub fn wants(self: *const Tracker, pos: geometry.ChunkPos) bool {
        return inView(self.stream_radius, pos, self.center) and !self.ready(pos);
    }

    pub fn mark(self: *Tracker, pos: geometry.ChunkPos) void {
        if (!inView(self.stream_radius, pos, self.center)) return;
        const index = self.viewIndex(pos, self.center) orelse return;
        if (self.bit(index)) {
            self.clearDirtyBit(index);
            self.advanceCursor();
            return;
        }
        if (self.sent_count >= self.order.len)
            std.debug.panic("chunk view tracker invariant failed: marking ({d}, {d}) around center ({d}, {d}) with sent count {d} at capacity {d}", .{ pos.x, pos.z, self.center.x, self.center.z, self.sent_count, self.order.len });
        self.setBit(index);
        self.sent_count += 1;
        self.advanceCursor();
    }

    pub fn unmark(self: *Tracker, pos: geometry.ChunkPos) bool {
        if (!inView(self.stream_radius, pos, self.center)) return false;
        const index = self.viewIndex(pos, self.center) orelse return false;
        if (!self.bit(index)) return false;
        self.clearBit(index);
        self.clearDirtyBit(index);
        self.sent_count -= 1;
        self.stream_cursor = 0;
        self.advanceCursor();
        return true;
    }

    pub fn markDirty(self: *Tracker, pos: geometry.ChunkPos) bool {
        if (!inView(self.stream_radius, pos, self.center)) return false;
        const index = self.viewIndex(pos, self.center) orelse return false;
        if (!self.bit(index) or self.dirtyBit(index)) return false;
        self.setDirtyBit(index);
        self.stream_cursor = 0;
        self.advanceCursor();
        return true;
    }

    pub fn recenter(self: *Tracker, center: geometry.ChunkPos) void {
        if (center.x == self.center.x and center.z == self.center.z) return;
        const old_center = self.center;
        self.center = center;
        const delta_x = center.x - old_center.x;
        const delta_z = center.z - old_center.z;
        const diameter: i32 = @intCast(self.diameter);
        if (@abs(delta_x) >= diameter or @abs(delta_z) >= diameter) {
            @memset(self.sent_bits, 0);
            @memset(self.dirty_bits, 0);
            self.sent_count = 0;
            self.stream_cursor = 0;
            return;
        }
        const shift = delta_z * @as(i32, @intCast(self.diameter)) + delta_x;
        self.translateBits(self.sent_bits, shift);
        self.translateBits(self.dirty_bits, shift);
        const first_x: usize = @intCast(@max(0, -delta_x));
        const last_x: usize = @intCast(@min(@as(i32, @intCast(self.diameter)), @as(i32, @intCast(self.diameter)) - delta_x));
        const first_z: usize = @intCast(@max(0, -delta_z));
        const last_z: usize = @intCast(@min(@as(i32, @intCast(self.diameter)), @as(i32, @intCast(self.diameter)) - delta_z));
        for (0..self.diameter) |z| {
            if (z < first_z or z >= last_z) {
                self.clearRange(z * self.diameter, self.diameter);
                clearBitsRange(self.dirty_bits, z * self.diameter, self.diameter);
                continue;
            }
            if (first_x != 0) {
                self.clearRange(z * self.diameter, first_x);
                clearBitsRange(self.dirty_bits, z * self.diameter, first_x);
            }
            if (last_x != self.diameter) {
                self.clearRange(z * self.diameter + last_x, self.diameter - last_x);
                clearBitsRange(self.dirty_bits, z * self.diameter + last_x, self.diameter - last_x);
            }
        }
        self.maskOutsideStream();
        self.stream_cursor = 0;
        self.advanceCursor();
    }

    fn translateBits(self: *Tracker, bits_slice: []u64, shift: i32) void {
        const source = bits_slice;
        @memset(self.translated_bits, 0);
        if (shift > 0) {
            const amount: usize = @intCast(shift);
            const words = amount / 64;
            const bits: u6 = @intCast(amount & 63);
            for (self.translated_bits, 0..) |*destination, index| {
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
            for (self.translated_bits, 0..) |*destination, index| {
                if (index < words) continue;
                const source_index = index - words;
                destination.* = source[source_index] << bits;
                if (bits != 0 and source_index != 0)
                    destination.* |= source[source_index - 1] >> @intCast(64 - @as(u7, bits));
            }
        }
        @memcpy(bits_slice, self.translated_bits);
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
        if (self.stream_cursor == self.order.len) return null;
        return self.positionForIndex(self.center, self.order[self.stream_cursor]);
    }

    pub fn nextMissingFrom(self: *const Tracker, cursor: *usize) ?geometry.ChunkPos {
        var iterator = MissingIterator{
            .tracker = self,
            .cursor = @max(cursor.*, self.stream_cursor),
        };
        const position = iterator.next();
        cursor.* = iterator.cursor;
        return position;
    }

    pub fn missingIterator(self: *const Tracker) MissingIterator {
        return .{ .tracker = self, .cursor = self.stream_cursor };
    }

    fn advanceCursor(self: *Tracker) void {
        while (self.stream_cursor < self.order.len and
            (self.bit(self.order[self.stream_cursor]) and
                !self.dirtyBit(self.order[self.stream_cursor])))
            self.stream_cursor += 1;
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

    fn viewIndex(self: *const Tracker, pos: geometry.ChunkPos, center: geometry.ChunkPos) ?usize {
        const relative_x = pos.x - center.x + self.grid_radius;
        const relative_z = pos.z - center.z + self.grid_radius;
        if (relative_x < 0 or relative_z < 0 or relative_x >= @as(i32, @intCast(self.diameter)) or relative_z >= @as(i32, @intCast(self.diameter))) return null;
        return @as(usize, @intCast(relative_z)) * self.diameter + @as(usize, @intCast(relative_x));
    }

    fn positionForIndex(self: *const Tracker, center: geometry.ChunkPos, index: usize) geometry.ChunkPos {
        return .{
            .x = center.x + @as(i32, @intCast(index % self.diameter)) - self.grid_radius,
            .z = center.z + @as(i32, @intCast(index / self.diameter)) - self.grid_radius,
        };
    }
};

test "bounded streaming cursor skips a pending nearest chunk" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
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

pub inline fn inView(radius: i32, pos: geometry.ChunkPos, center: geometry.ChunkPos) bool {
    if (radius < 2)
        return @abs(pos.x - center.x) <= radius and
            @abs(pos.z - center.z) <= radius;
    const dx = @abs(@as(i64, pos.x) - center.x) -| 2;
    const dz = @abs(@as(i64, pos.z) - center.z) -| 2;
    return dx * dx + dz * dz < @as(u64, @intCast(radius)) * @as(u64, @intCast(radius));
}

fn viewChunkCount(radius: i32, grid_radius: i32) usize {
    const diameter: usize = @intCast(grid_radius * 2 + 1);
    var result: usize = 0;
    for (0..diameter * diameter) |index| {
        const position = relativePosition(@intCast(index), grid_radius);
        result += @intFromBool(inView(radius, position, .{ .x = 0, .z = 0 }));
    }
    return result;
}

fn initializeStreamOrder(indices: []u16, radius: i32, grid_radius: i32) void {
    const diameter: usize = @intCast(grid_radius * 2 + 1);
    var count: usize = 1;
    indices[0] = @intCast(@as(usize, @intCast(grid_radius)) * diameter + @as(usize, @intCast(grid_radius)));
    var x: i32 = 0;
    var z: i32 = 0;
    var leg: i32 = 1;
    const directions = [_]geometry.ChunkPos{
        .{ .x = 1, .z = 0 },
        .{ .x = 0, .z = 1 },
        .{ .x = -1, .z = 0 },
        .{ .x = 0, .z = -1 },
    };
    while (count < indices.len) {
        for (directions, 0..) |direction, direction_index| {
            for (0..@as(usize, @intCast(leg))) |_| {
                x += direction.x;
                z += direction.z;
                if (@abs(x) <= grid_radius and @abs(z) <= grid_radius and
                    inView(radius, .{ .x = x, .z = z }, .{ .x = 0, .z = 0 }))
                {
                    indices[count] = @intCast(@as(usize, @intCast(z + grid_radius)) * diameter + @as(usize, @intCast(x + grid_radius)));
                    count += 1;
                    if (count == indices.len) return;
                }
            }
            if (direction_index & 1 == 1) leg += 1;
        }
    }
}

fn relativePosition(index: u16, radius: i32) geometry.ChunkPos {
    const wide: usize = index;
    const diameter: usize = @intCast(radius * 2 + 1);
    return .{
        .x = @as(i32, @intCast(wide % diameter)) - radius,
        .z = @as(i32, @intCast(wide / diameter)) - radius,
    };
}

fn allocateTestTracker(tracker: *Tracker, allocator: std.mem.Allocator) !void {
    const order = try Order.create(allocator, 4);
    try tracker.allocate(allocator, &order);
}

test "tracker streams in radial order and retains membership" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });
    tracker.mark(.{ .x = 0, .z = 0 });
    const next = tracker.nextMissing().?;
    try std.testing.expect(inView(tracker.maximum_radius, next, tracker.center));
    try std.testing.expect(!tracker.has(next));
}

test "unmark schedules an already sent chunk for retransmission" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
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
    try allocateTestTracker(&tracker, arena.allocator());
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

test "chunks outside the configured radius are never scheduled" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
    tracker.setRadius(.{ .x = 0, .z = 0 }, 1);
    try std.testing.expect(!tracker.unmark(.{ .x = 2, .z = 0 }));
    try std.testing.expect(!tracker.has(.{ .x = 2, .z = 0 }));
    try std.testing.expect(!tracker.delivered(.{ .x = 2, .z = 0 }));
}

test "reset preserves the configured stream radius" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
    tracker.setRadius(.{ .x = 0, .z = 0 }, 1);
    tracker.reset(.{ .x = 7, .z = -4 });
    try std.testing.expect(!tracker.has(.{ .x = 9, .z = -4 }));
    try std.testing.expect(!tracker.has(.{ .x = 8, .z = -4 }));
}

test "missing iterator looks ahead without advancing stream order" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const order = try Order.create(arena.allocator(), 4);
    const seen = try arena.allocator().alloc(bool, order.diameter * order.diameter);
    @memset(seen, false);
    for (order.indices) |index| {
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    var count: usize = 0;
    for (seen, 0..) |present, index| {
        const position = relativePosition(@intCast(index), order.grid_radius);
        try std.testing.expectEqual(inView(order.radius, position, .{ .x = 0, .z = 0 }), present);
        count += @intFromBool(present);
    }
    try std.testing.expectEqual(order.indices.len, count);
}

test "distance 32 matches the Java client tracking shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const order = try Order.create(arena.allocator(), 32);
    try std.testing.expectEqual(@as(usize, 3725), order.indices.len);
}

test "recenter retains overlap without growing beyond the view" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
    tracker.reset(.{ .x = 0, .z = 0 });
    for (tracker.order) |index| tracker.mark(tracker.positionForIndex(tracker.center, index));
    try std.testing.expectEqual(tracker.order.len, tracker.sent_count);
    tracker.recenter(.{ .x = 1, .z = 0 });
    try std.testing.expect(tracker.delivered(.{
        .x = tracker.center.x + tracker.maximum_radius - 1,
        .z = tracker.center.z,
    }));
    try std.testing.expect(!tracker.delivered(.{
        .x = tracker.center.x + tracker.maximum_radius + 1,
        .z = tracker.center.z,
    }));
    while (tracker.nextMissing()) |pos| tracker.mark(pos);
    try std.testing.expectEqual(tracker.order.len, tracker.sent_count);
}

test "stream radius equals the advertised view distance" {
    var tracker: Tracker = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try allocateTestTracker(&tracker, arena.allocator());
    const center = geometry.ChunkPos{ .x = 7, .z = -3 };
    tracker.reset(center);
    const visible_edge = geometry.ChunkPos{
        .x = center.x + tracker.maximum_radius + 1,
        .z = center.z,
    };
    const outside = geometry.ChunkPos{
        .x = center.x + tracker.maximum_radius + 2,
        .z = center.z,
    };
    try std.testing.expect(inView(tracker.maximum_radius, visible_edge, center));
    try std.testing.expect(!inView(tracker.maximum_radius, outside, center));
    tracker.mark(visible_edge);
    try std.testing.expect(tracker.delivered(visible_edge));
    try std.testing.expect(!tracker.delivered(outside));
}

test "packed recenter matches coordinate remapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var original: Tracker = .{};
    try allocateTestTracker(&original, arena.allocator());
    original.reset(.{ .x = 11, .z = -7 });
    for (original.order, 0..) |index, sample| {
        if (sample % 7 == 0 or sample % 19 == 0)
            original.mark(original.positionForIndex(original.center, index));
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
        try allocateTestTracker(&actual, arena.allocator());
        actual.center = original.center;
        actual.sent_count = original.sent_count;
        actual.stream_cursor = original.stream_cursor;
        @memcpy(actual.sent_bits, original.sent_bits);
        actual.recenter(center);

        var expected: Tracker = .{};
        try allocateTestTracker(&expected, arena.allocator());
        expected.reset(center);
        for (original.order) |old_index| {
            if (!original.bit(old_index)) continue;
            const pos = original.positionForIndex(original.center, old_index);
            if (!inView(expected.stream_radius, pos, center)) continue;
            const new_index = expected.viewIndex(pos, center) orelse continue;
            expected.setBit(new_index);
            expected.sent_count += 1;
        }
        expected.advanceCursor();
        try std.testing.expectEqual(expected.sent_count, actual.sent_count);
        try std.testing.expectEqual(expected.stream_cursor, actual.stream_cursor);
        try std.testing.expectEqualSlices(u64, expected.sent_bits, actual.sent_bits);
    }
}
