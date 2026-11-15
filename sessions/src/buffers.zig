const std = @import("std");
const metrics = @import("metrics");

pub const Buffers = struct {
    pub const Configuration = struct { slots: usize, bytes: usize, guaranteed: ?usize = null, overflow: ?*Buffers = null };
    const Slot = struct { state: std.atomic.Value(u64) = .init(0) };
    pub const Lease = struct {
        pool: *Buffers,
        storage_index: usize,
        /// Unique across this stage's private and shared storage slots.
        id: usize,
        generation: u64,
        bytes: []u8,
        borrower: ?*Buffers = null,

        pub fn release(self: Lease) void {
            const slot = &self.pool.slots[self.storage_index];
            std.debug.assert(slot.state.load(.acquire) == (self.generation << 1) | 1);
            // Publish the release count before another owner can acquire this slot.
            const held = self.pool.in_use.fetchSub(1, .monotonic);
            std.debug.assert(held > 0 and held <= self.pool.maximum);
            if (self.borrower) |borrower| {
                const borrowed = borrower.overflow_in_use.fetchSub(1, .monotonic);
                std.debug.assert(borrowed > 0 and borrowed <= borrower.maximum - borrower.slots.len);
                const active = borrower.in_use.fetchSub(1, .monotonic);
                std.debug.assert(active > 0 and active <= borrower.maximum);
            }
            const previous = slot.state.cmpxchgStrong((self.generation << 1) | 1, self.generation << 1, .release, .monotonic);
            std.debug.assert(previous == null);
            self.pool.released.store(true, .release);
            _ = self.pool.release_epoch.fetchAdd(1, .release);
            if (self.borrower) |borrower| borrower.released.store(true, .release);
        }
    };

    bytes: []align(64) u8,
    slots: []Slot,
    stride: usize,
    maximum: usize,
    overflow: ?*Buffers = null,
    overflow_in_use: std.atomic.Value(usize) = .init(0),
    release_epoch: std.atomic.Value(u64) = .init(0),
    observed_release: u64 = 0,
    released: std.atomic.Value(bool) = .init(false),
    in_use: std.atomic.Value(usize) = .init(0),
    maximum_in_use: std.atomic.Value(usize) = .init(0),
    active_metric: metrics.Gauge = .{},
    peak_metric: metrics.Gauge = .{},

    pub fn instrument(self: *Buffers, registry: ?*metrics.Registry, namespace: []const u8) !void {
        const owner = registry orelse return;
        const capacity = try owner.gauge(.{ .namespace = namespace, .name = "slots", .description = "Maximum simultaneous buffer claims" });
        const stride = try owner.gauge(.{ .namespace = namespace, .name = "slot_bytes", .description = "Capacity of each buffer", .unit = .bytes });
        self.active_metric = try owner.gauge(.{ .namespace = namespace, .name = "active", .description = "Checked out buffer slots" });
        self.peak_metric = try owner.gauge(.{ .namespace = namespace, .name = "peak", .description = "Maximum checked out buffer slots" });
        capacity.set(self.maximum);
        stride.set(self.stride);
    }

    pub fn publishUsage(self: *const Buffers) void {
        self.active_metric.set(self.in_use.load(.monotonic));
        self.peak_metric.set(self.maximum_in_use.load(.monotonic));
    }

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Buffers {
        const count = config.guaranteed orelse config.slots;
        const size = config.bytes;
        if (size == 0 or count > config.slots) return error.InvalidBufferCapacity;
        const overflow = if (count < config.slots) config.overflow orelse return error.InvalidBufferCapacity else null;
        if (overflow) |pool| if (pool.overflow != null or pool.stride != size or pool.maximum < config.slots - count) return error.InvalidBufferCapacity;
        const bytes = try allocator.alignedAlloc(u8, .@"64", try std.math.mul(usize, count, size));
        errdefer allocator.free(bytes);
        const slots = try allocator.alloc(Slot, count);
        for (slots) |*slot| slot.* = .{};
        return .{ .bytes = bytes, .slots = slots, .stride = size, .maximum = config.slots, .overflow = overflow };
    }

    pub fn deinit(self: *Buffers, allocator: std.mem.Allocator) void {
        std.debug.assert(self.in_use.load(.monotonic) == 0 and self.maximum_in_use.load(.monotonic) <= self.maximum);
        std.debug.assert(self.overflow_in_use.load(.monotonic) == 0);
        for (self.slots) |*slot| std.debug.assert(slot.state.load(.acquire) & 1 == 0);
        allocator.free(self.slots);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Consumed only by the stage's owning thread.
    pub fn takeReleased(self: *Buffers) bool {
        var released = self.released.load(.acquire) and self.released.swap(false, .acq_rel);
        if (self.overflow) |pool| {
            const epoch = pool.release_epoch.load(.acquire);
            released = released or epoch != self.observed_release;
            self.observed_release = epoch;
        }
        return released;
    }

    pub fn availableCountWithin(self: *const Buffers, count: usize) usize {
        std.debug.assert(count <= self.maximum);
        const shared = self.maximum - self.slots.len;
        const local = count - @min(count, shared);
        var free: usize = 0;
        for (self.slots[0..local]) |*slot| free += @intFromBool(slot.state.load(.acquire) & 1 == 0);
        if (self.overflow) |pool| {
            const used = self.overflow_in_use.load(.acquire);
            const allowed = @min(count, shared);
            free += @min(allowed - @min(allowed, used), pool.availableCountWithin(pool.maximum));
        }
        const active = self.in_use.load(.acquire);
        return @min(free, self.maximum - @min(self.maximum, active));
    }

    pub fn available(self: *const Buffers) bool {
        return self.availableWithin(self.maximum);
    }

    pub fn availableWithin(self: *const Buffers, count: usize) bool {
        return self.availableCountWithin(count) != 0;
    }

    pub fn acquire(self: *Buffers) ?Lease {
        return self.acquireWithin(self.maximum);
    }

    pub fn addressableSlots(self: *const Buffers) usize {
        return self.slots.len + if (self.overflow) |pool| pool.slots.len else @as(usize, 0);
    }

    pub fn acquireWithin(self: *Buffers, count: usize) ?Lease {
        std.debug.assert(count <= self.maximum);
        if (count == 0) return null;
        const held = self.in_use.load(.acquire);
        if (held == self.maximum or self.in_use.cmpxchgStrong(held, held + 1, .acquire, .monotonic) != null) return null;
        var acquired = false;
        defer if (!acquired) {
            const reserved = self.in_use.fetchSub(1, .release);
            std.debug.assert(reserved > 0 and reserved <= self.maximum);
        };
        const shared = self.maximum - self.slots.len;
        const local = count - @min(count, shared);
        for (self.slots[0..local], 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state & 1 != 0) continue;
            const generation = (state >> 1) + 1;
            std.debug.assert(generation <= std.math.maxInt(u63));
            if (slot.state.cmpxchgStrong(state, (generation << 1) | 1, .acquire, .monotonic) != null) continue;
            acquired = true;
            _ = self.maximum_in_use.fetchMax(held + 1, .monotonic);
            const id = index + if (self.overflow) |pool| pool.slots.len else @as(usize, 0);
            std.debug.assert(id < self.addressableSlots());
            return .{ .pool = self, .storage_index = index, .id = id, .generation = generation, .bytes = self.bytes[index * self.stride ..][0..self.stride] };
        }
        if (self.overflow) |pool| {
            const borrowed = self.overflow_in_use.load(.acquire);
            if (borrowed >= @min(count, shared) or self.overflow_in_use.cmpxchgStrong(borrowed, borrowed + 1, .acquire, .monotonic) != null) return null;
            var lease = pool.acquire() orelse {
                _ = self.overflow_in_use.fetchSub(1, .release);
                return null;
            };
            std.debug.assert(lease.borrower == null);
            lease.borrower = self;
            std.debug.assert(lease.id < self.addressableSlots());
            acquired = true;
            _ = self.maximum_in_use.fetchMax(held + 1, .monotonic);
            return lease;
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
    var pool = try Buffers.init(fixed.allocator(), .{ .slots = 2, .bytes = 256 });
    defer pool.deinit(fixed.allocator());
    const allocated = fixed.end_index;
    try std.testing.expect(!pool.takeReleased());
    try std.testing.expectEqual(@as(usize, 2), pool.availableCountWithin(2));
    const first = pool.acquire().?;
    const second = pool.acquire().?;
    @memset(first.bytes, 11);
    @memset(second.bytes, 22);
    try std.testing.expectEqual(null, pool.acquire());
    try std.testing.expectEqual(@as(usize, 2), pool.maximum_in_use.load(.monotonic));
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
    try std.testing.expectEqual(@as(usize, 2), pool.maximum_in_use.load(.monotonic));
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
    var overflow = try Buffers.init(std.testing.allocator, .{ .slots = 1, .bytes = 256 });
    defer overflow.deinit(std.testing.allocator);
    var pool = try Buffers.init(std.testing.allocator, .{ .slots = 2, .bytes = 256, .guaranteed = 1, .overflow = &overflow });
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

test "shared bursts preserve private guarantees and notify every borrowing stage" {
    var bytes: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&bytes);
    const allocator = fixed.allocator();
    var overflow = try Buffers.init(allocator, .{ .slots = 2, .bytes = 256 });
    defer overflow.deinit(allocator);
    var first = try Buffers.init(allocator, .{ .slots = 3, .bytes = 256, .guaranteed = 1, .overflow = &overflow });
    defer first.deinit(allocator);
    var second = try Buffers.init(allocator, .{ .slots = 3, .bytes = 256, .guaranteed = 1, .overflow = &overflow });
    defer second.deinit(allocator);
    const allocated = fixed.end_index;
    const private = first.acquire().?;
    defer private.release();
    const shared = first.acquire().?;
    const other = first.acquire().?;
    defer other.release();
    try std.testing.expect(private.id != shared.id and private.id != other.id and shared.id != other.id);
    @memset(other.bytes, 73);
    try std.testing.expectEqual(null, first.acquire());
    const guaranteed = second.acquire().?;
    defer guaranteed.release();
    try std.testing.expectEqual(null, second.acquire());
    try std.testing.expect(!first.takeReleased() and !second.takeReleased());
    shared.release();
    try std.testing.expect(first.takeReleased());
    try std.testing.expect(second.takeReleased());
    try std.testing.expect(!first.takeReleased() and !second.takeReleased());
    const reused = second.acquire().?;
    defer reused.release();
    try std.testing.expectEqual(shared.bytes.ptr, reused.bytes.ptr);
    try std.testing.expect(std.mem.allEqual(u8, other.bytes, 73));
    try std.testing.expectEqual(@as(usize, 3), first.maximum_in_use.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2), second.maximum_in_use.load(.monotonic));
    try std.testing.expectEqual(allocated, fixed.end_index);
}

test "configuration progresses with a reserved status slot while raw control exhausts shared bursts" {
    const allocator = std.testing.allocator;
    var overflow = try Buffers.init(allocator, .{ .slots = 2, .bytes = 256 });
    defer overflow.deinit(allocator);
    var raw = try Buffers.init(allocator, .{ .slots = 4, .bytes = 256, .guaranteed = 2, .overflow = &overflow });
    defer raw.deinit(allocator);
    var configuration = try Buffers.init(allocator, .{ .slots = 4, .bytes = 256, .guaranteed = 2, .overflow = &overflow });
    defer configuration.deinit(allocator);
    var leases: [4]Buffers.Lease = undefined;
    for (&leases) |*lease| lease.* = raw.acquire().?;
    defer for (leases) |lease| lease.release();
    try std.testing.expectEqual(null, raw.acquire());
    const admitted = configuration.acquireWithin(3).?;
    defer admitted.release();
    try std.testing.expectEqual(null, configuration.acquireWithin(3));
    const status = configuration.acquire().?;
    defer status.release();
    try std.testing.expect(admitted.id != status.id);
    try std.testing.expectEqual(@as(usize, 0), configuration.availableCountWithin(3));
}
