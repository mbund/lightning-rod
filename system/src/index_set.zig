const std = @import("std");
const assert = std.debug.assert;

pub const IndexSet = struct {
    const absent = std.math.maxInt(usize);

    pub const Signal = struct {
        set: *IndexSet,
        index: usize,

        pub fn notify(self: Signal) void {
            self.set.insert(self.index);
        }
    };

    indices: []usize,
    positions: []usize,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !IndexSet {
        assert(capacity > 0 and capacity < absent);
        const indices = try allocator.alloc(usize, capacity);
        errdefer allocator.free(indices);
        const positions = try allocator.alloc(usize, capacity);
        @memset(positions, absent);
        return .{ .indices = indices, .positions = positions };
    }

    pub fn deinit(self: *IndexSet, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
        allocator.free(self.indices);
        self.* = undefined;
    }

    pub fn insert(self: *IndexSet, index: usize) void {
        assert(index < self.positions.len);
        if (self.positions[index] != absent) {
            assert(self.indices[self.positions[index]] == index);
            return;
        }
        assert(self.count < self.indices.len);
        self.positions[index] = @intCast(self.count);
        self.indices[self.count] = index;
        self.count += 1;
    }

    pub fn remove(self: *IndexSet, index: usize) void {
        assert(index < self.positions.len);
        const at = self.positions[index];
        if (at == absent) return;
        assert(at < self.count and self.indices[at] == index);
        self.count -= 1;
        const moved = self.indices[self.count];
        self.indices[at] = moved;
        self.positions[moved] = at;
        self.positions[index] = absent;
    }

    pub fn contains(self: *const IndexSet, index: usize) bool {
        assert(index < self.positions.len);
        return self.positions[index] != absent;
    }

    /// The slice expires at the next mutation.
    pub fn values(self: *const IndexSet) []const usize {
        return self.indices[0..self.count];
    }

    pub fn clear(self: *IndexSet) void {
        for (self.values()) |index| {
            assert(self.positions[index] != absent);
            self.positions[index] = absent;
        }
        self.count = 0;
    }
};

test "index slots deduplicate remove and reuse without allocating" {
    var memory: [2 * 257 * @sizeOf(usize)]u8 align(@alignOf(usize)) = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var pending = try IndexSet.init(allocator.allocator(), 257);
    defer pending.deinit(allocator.allocator());
    const assigned = allocator.end_index;
    var expected: [257]bool = @splat(false);
    var prng = std.Random.DefaultPrng.init(0x70656e64696e67);
    for (0..3000) |_| {
        const index = prng.random().uintLessThan(u32, expected.len);
        if (prng.random().boolean()) {
            const signal: IndexSet.Signal = .{ .set = &pending, .index = index };
            signal.notify();
            pending.insert(index);
            expected[index] = true;
        } else {
            pending.remove(index);
            expected[index] = false;
        }
        var actual: [257]bool = @splat(false);
        for (pending.values()) |slot| {
            try std.testing.expect(!actual[slot]);
            actual[slot] = true;
        }
        try std.testing.expectEqualSlices(bool, &expected, &actual);
    }
    pending.clear();
    try std.testing.expectEqual(@as(usize, 0), pending.values().len);
    pending.insert(256);
    pending.remove(256);
    try std.testing.expectEqual(assigned, allocator.end_index);
}

test "index sets retain indexes beyond sixteen bits" {
    var pending = try IndexSet.init(std.testing.allocator, 65_537);
    defer pending.deinit(std.testing.allocator);
    pending.insert(65_536);
    pending.insert(256);
    pending.remove(256);
    try std.testing.expectEqualSlices(usize, &.{65_536}, pending.values());
    pending.clear();
    try std.testing.expectEqual(@as(usize, 0), pending.count);
}
