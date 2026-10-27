const std = @import("std");

pub const Buffers = struct {
    const Slot = struct { state: std.atomic.Value(u64) = .init(0) };
    pub const Lease = struct {
        pool: *Buffers,
        index: usize,
        generation: u64,
        bytes: []u8,

        pub fn release(self: Lease) void {
            const slot = &self.pool.slots[self.index];
            const previous = slot.state.cmpxchgStrong((self.generation << 1) | 1, self.generation << 1, .release, .monotonic);
            std.debug.assert(previous == null);
            self.pool.released.store(true, .release);
        }
    };

    bytes: []align(64) u8,
    slots: []Slot,
    stride: usize,
    released: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, count: usize, size: usize) !Buffers {
        if (size == 0) return error.InvalidBufferCapacity;
        const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, count, size));
        errdefer allocator.free(bytes);
        const slots = try allocator.alloc(Slot, count);
        for (slots) |*slot| slot.* = .{};
        return .{ .bytes = bytes, .slots = slots, .stride = size };
    }

    pub fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| std.debug.assert(slot.state.load(.acquire) & 1 == 0);
        allocator.free(self.slots);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn takeReleased(self: *Buffers) bool {
        return self.released.load(.acquire) and self.released.swap(false, .acq_rel);
    }

    pub fn availableCountWithin(self: *const Buffers, count: usize) usize {
        std.debug.assert(count <= self.slots.len);
        var free: usize = 0;
        for (self.slots[0..count]) |*slot| free += @intFromBool(slot.state.load(.acquire) & 1 == 0);
        return free;
    }

    pub fn available(self: *const Buffers) bool {
        return self.availableWithin(self.slots.len);
    }

    pub fn availableWithin(self: *const Buffers, count: usize) bool {
        std.debug.assert(count <= self.slots.len);
        for (self.slots[0..count]) |*slot| if (slot.state.load(.acquire) & 1 == 0) return true;
        return false;
    }

    pub fn acquire(self: *Buffers) ?Lease {
        return self.acquireWithin(self.slots.len);
    }

    pub fn acquireWithin(self: *Buffers, count: usize) ?Lease {
        std.debug.assert(count <= self.slots.len);
        for (self.slots[0..count], 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state & 1 != 0) continue;
            const generation = (state >> 1) + 1;
            std.debug.assert(generation <= std.math.maxInt(u63));
            if (slot.state.cmpxchgStrong(state, (generation << 1) | 1, .acquire, .monotonic) != null) continue;
            return .{ .pool = self, .index = index, .generation = generation, .bytes = self.bytes[index * self.stride ..][0..self.stride] };
        }
        return null;
    }

    pub fn memoryBytes(self: *const Buffers) usize {
        return self.bytes.len + self.slots.len * @sizeOf(Slot);
    }
};

test "held buffers remain intact under pool exhaustion and reuse" {
    var bytes: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&bytes);
    var pool = try Buffers.init(fixed.allocator(), 2, 256);
    defer pool.deinit(fixed.allocator());
    const allocated = fixed.end_index;
    try std.testing.expect(!pool.takeReleased());
    try std.testing.expectEqual(@as(usize, 2), pool.availableCountWithin(2));
    const first = pool.acquire().?;
    const second = pool.acquire().?;
    @memset(first.bytes, 11);
    @memset(second.bytes, 22);
    try std.testing.expectEqual(null, pool.acquire());
    first.release();
    try std.testing.expect(pool.takeReleased());
    try std.testing.expect(!pool.takeReleased());
    try std.testing.expectEqual(@as(usize, 1), pool.availableCountWithin(2));
    const reused = pool.acquire().?;
    try std.testing.expectEqual(first.bytes.ptr, reused.bytes.ptr);
    try std.testing.expect(reused.generation != first.generation);
    @memset(reused.bytes, 33);
    try std.testing.expectEqual(@as(u8, 22), second.bytes[0]);
    try std.testing.expectEqual(allocated, fixed.end_index);
    reused.release();
    second.release();
}

test "concurrent buffer claims preserve exclusive ownership" {
    const Worker = struct {
        pool: *Buffers,
        start: *std.Io.Event,
        value: u8,
        claims: usize = 0,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.exercise();
        }
        fn exercise(self: *@This()) !void {
            self.start.waitUncancelable(std.testing.io);
            for (0..10000) |_| {
                const lease = self.pool.acquire() orelse continue;
                defer lease.release();
                @memset(lease.bytes, self.value);
                try std.testing.expect(std.mem.allEqual(u8, lease.bytes, self.value));
                self.claims += 1;
            }
        }
    };
    var pool = try Buffers.init(std.testing.allocator, 2, 256);
    defer pool.deinit(std.testing.allocator);
    var start: std.Io.Event = .unset;
    var first: Worker = .{ .pool = &pool, .start = &start, .value = 11 };
    var second: Worker = .{ .pool = &pool, .start = &start, .value = 22 };
    const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
    {
        defer first_thread.join();
        defer start.set(std.testing.io);
        const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
        start.set(std.testing.io);
        second_thread.join();
    }
    try first.result;
    try second.result;
    try std.testing.expect(first.claims > 0 and second.claims > 0);
}
