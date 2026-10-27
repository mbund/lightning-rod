const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Readiness = struct {
    const width = @bitSizeOf(usize);
    const maximum_levels = std.math.divCeil(usize, @bitSizeOf(usize), std.math.log2_int(usize, width)) catch unreachable;
    const Level = struct { offset: usize, length: usize };
    const Hierarchy = struct {
        words: []std.atomic.Value(usize),
        levels: [maximum_levels]Level,
        depth: usize,
    };

    pub const Signal = struct {
        hierarchy: *const Hierarchy,
        index: usize,

        pub fn notify(self: Signal) void {
            const leaf = self.hierarchy.levels[0];
            var index = self.index / width;
            assert(index < leaf.length);
            // Acquire observes the previous drain before checking ancestor bits.
            _ = self.hierarchy.words[leaf.offset + index].fetchOr(@as(usize, 1) << @intCast(self.index % width), .acq_rel);
            // Another producer may have set a child without publishing its ancestors yet.
            for (self.hierarchy.levels[1..self.hierarchy.depth]) |level| {
                const mask = @as(usize, 1) << @intCast(index % width);
                index /= width;
                assert(index < level.length);
                const word = &self.hierarchy.words[level.offset + index];
                if (word.load(.acquire) & mask == 0) _ = word.fetchOr(mask, .acq_rel);
            }
            assert(index == 0);
        }
    };
    const Timer = struct { deadline: i96 = 0, position: ?usize = null };

    hierarchy: *Hierarchy,
    ready: []usize,
    timers: []Timer,
    heap: []usize,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Readiness {
        assert(capacity > 0);
        var levels: [maximum_levels]Level = undefined;
        var depth: usize = 0;
        var length = std.math.divCeil(usize, capacity, width) catch unreachable;
        var total: usize = 0;
        while (true) {
            assert(depth < levels.len);
            levels[depth] = .{ .offset = total, .length = length };
            depth += 1;
            total = try std.math.add(usize, total, length);
            if (length == 1) break;
            length = std.math.divCeil(usize, length, width) catch unreachable;
        }
        const hierarchy = try allocator.create(Hierarchy);
        errdefer allocator.destroy(hierarchy);
        const words = try allocator.alloc(std.atomic.Value(usize), total);
        errdefer allocator.free(words);
        hierarchy.* = .{ .words = words, .levels = levels, .depth = depth };
        const ready = try allocator.alloc(usize, capacity);
        errdefer allocator.free(ready);
        const timers = try allocator.alloc(Timer, capacity);
        errdefer allocator.free(timers);
        const heap = try allocator.alloc(usize, capacity);
        for (words) |*word| word.* = .init(0);
        for (timers) |*timer| timer.* = .{};
        return .{ .hierarchy = hierarchy, .ready = ready, .timers = timers, .heap = heap };
    }

    pub fn deinit(self: *Readiness, allocator: std.mem.Allocator) void {
        allocator.free(self.heap);
        allocator.free(self.timers);
        allocator.free(self.ready);
        allocator.free(self.hierarchy.words);
        allocator.destroy(self.hierarchy);
        self.* = undefined;
    }

    pub fn signal(self: *Readiness, index: usize) Signal {
        assert(index < self.timers.len);
        return .{ .hierarchy = self.hierarchy, .index = index };
    }

    pub fn take(self: *Readiness, now: i96) []const usize {
        while (self.count != 0 and self.timers[self.heap[0]].deadline <= now) {
            const index = self.heap[0];
            self.update(index, null);
            self.signal(index).notify();
        }
        const hierarchy = self.hierarchy;
        const root = hierarchy.depth - 1;
        assert(hierarchy.levels[root].length == 1);
        var pending: [maximum_levels]usize = undefined;
        var indices: [maximum_levels]usize = undefined;
        pending[root] = hierarchy.words[hierarchy.levels[root].offset].swap(0, .acq_rel);
        indices[root] = 0;
        var level = root;
        var count: usize = 0;
        while (true) {
            if (pending[level] == 0) {
                if (level == root) break;
                level += 1;
                continue;
            }
            const index = indices[level] * width + @ctz(pending[level]);
            pending[level] &= pending[level] - 1;
            if (level == 0) {
                assert(index < self.timers.len and count < self.ready.len);
                assert(count == 0 or self.ready[count - 1] < index);
                self.ready[count] = index;
                count += 1;
                continue;
            }
            level -= 1;
            assert(index < hierarchy.levels[level].length);
            indices[level] = index;
            pending[level] = hierarchy.words[hierarchy.levels[level].offset + index].swap(0, .acq_rel);
        }
        return self.ready[0..count];
    }

    pub fn deadline(self: *const Readiness, now: i96) ?i96 {
        const hierarchy = self.hierarchy;
        const root = hierarchy.levels[hierarchy.depth - 1];
        assert(root.length == 1);
        if (hierarchy.words[root.offset].load(.acquire) != 0) return now;
        return if (self.count == 0) null else self.timers[self.heap[0]].deadline;
    }

    pub fn update(self: *Readiness, index: usize, expires: ?i96) void {
        assert(index < self.timers.len);
        const timer = &self.timers[index];
        if (timer.position) |position| {
            if (expires) |value| {
                timer.deadline = value;
                self.repair(position);
                return;
            }
            timer.position = null;
            self.count -= 1;
            if (position == self.count) return;
            self.place(position, self.heap[self.count]);
            self.repair(position);
            return;
        }
        const value = expires orelse return;
        assert(self.count < self.heap.len);
        timer.deadline = value;
        self.place(self.count, @intCast(index));
        self.count += 1;
        self.repair(self.count - 1);
    }

    fn repair(self: *Readiness, position: usize) void {
        const index = self.heap[position];
        const expires = self.timers[index].deadline;
        var at = position;
        while (at > 0) {
            const parent = (at - 1) / 2;
            const other = self.heap[parent];
            if (self.timers[other].deadline <= expires) break;
            self.place(at, other);
            at = parent;
        }
        while (at * 2 + 1 < self.count) {
            var child = at * 2 + 1;
            if (child + 1 < self.count and self.timers[self.heap[child + 1]].deadline < self.timers[self.heap[child]].deadline) child += 1;
            const other = self.heap[child];
            if (expires <= self.timers[other].deadline) break;
            self.place(at, other);
            at = child;
        }
        self.place(at, index);
    }

    fn place(self: *Readiness, position: usize, index: usize) void {
        assert(position < self.heap.len and index < self.timers.len);
        self.heap[position] = index;
        self.timers[index].position = position;
    }
};

test "readiness coalesces notifications and only expires due timers" {
    var ready = try Readiness.init(std.testing.allocator, 4096);
    defer ready.deinit(std.testing.allocator);
    for (0..4096) |index| ready.update(index, @intCast(1000 + index));
    for (0..64) |_| try std.testing.expectEqual(@as(usize, 0), ready.take(999).len);
    ready.signal(1024).notify();
    ready.signal(1024).notify();
    try std.testing.expectEqualSlices(usize, &.{1024}, ready.take(999));
    try std.testing.expectEqual(@as(?i96, 1000), ready.deadline(999));
    try std.testing.expectEqualSlices(usize, &.{0}, ready.take(1000));
    ready.update(2048, 1001);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2048 }, ready.take(1001));
    ready.update(2, null);
    try std.testing.expectEqual(@as(?i96, 1003), ready.deadline(1001));
}

test "indexed timer updates match a deterministic unordered model" {
    var ready = try Readiness.init(std.testing.allocator, 128);
    defer ready.deinit(std.testing.allocator);
    var model: [128]?i96 = @splat(null);
    var random = std.Random.DefaultPrng.init(0);
    for (0..10000) |_| {
        const index = random.random().uintLessThan(usize, model.len);
        const value: ?i96 = if (random.random().boolean()) random.random().uintLessThan(u32, 1000) else null;
        model[index] = value;
        ready.update(index, value);
        var earliest: ?i96 = null;
        for (model) |entry| if (entry) |expires| {
            earliest = @min(earliest orelse expires, expires);
        };
        try std.testing.expectEqual(earliest, ready.deadline(-1));
        for (ready.heap[0..ready.count], 0..) |slot, position| {
            try std.testing.expectEqual(position, ready.timers[slot].position.?);
            if (position > 0) try std.testing.expect(ready.timers[ready.heap[(position - 1) / 2]].deadline <= ready.timers[slot].deadline);
        }
    }
}

test "readiness preserves connection indexes beyond sixteen bits" {
    var ready = try Readiness.init(std.testing.allocator, 65_537);
    defer ready.deinit(std.testing.allocator);
    ready.signal(65_536).notify();
    ready.update(0, 9);
    ready.update(65_536, 10);
    try std.testing.expectEqualSlices(usize, &.{65_536}, ready.take(8));
    try std.testing.expectEqualSlices(usize, &.{0}, ready.take(9));
    try std.testing.expectEqualSlices(usize, &.{65_536}, ready.take(10));
    try std.testing.expectEqual(@as(usize, 0), ready.take(11).len);
}

test "readiness remains ordered and bounded across hierarchy boundaries without allocating" {
    for ([_]usize{ 1, 63, 64, 65, 4096, 4097, 65537 }) |capacity| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var ready = try Readiness.init(allocator, capacity);
        defer ready.deinit(allocator);
        failing.fail_index = failing.alloc_index;
        for (0..3) |pass| {
            for (0..capacity) |offset| {
                const index = capacity - offset - 1;
                if (index % 3 != pass) continue;
                ready.signal(index).notify();
                ready.signal(index).notify();
            }
            const batch = ready.take(0);
            var at: usize = 0;
            for (0..capacity) |index| if (index % 3 == pass) {
                try std.testing.expectEqual(index, batch[at]);
                at += 1;
            };
            try std.testing.expectEqual(at, batch.len);
            try std.testing.expectEqual(@as(?i96, null), ready.deadline(0));
            try std.testing.expectEqual(@as(usize, 0), ready.take(0).len);
        }
    }
}

test "a completed notifier publishes a path left incomplete by another producer" {
    var ready = try Readiness.init(std.testing.allocator, 65537);
    defer ready.deinit(std.testing.allocator);
    for ([_]usize{ 1, 64, 4096, 65536 }) |index| {
        const hierarchy = ready.hierarchy;
        var word_index = index / Readiness.width;
        _ = hierarchy.words[word_index].fetchOr(@as(usize, 1) << @intCast(index % Readiness.width), .release);
        ready.signal(index).notify();
        try std.testing.expectEqual(@as(?i96, 0), ready.deadline(0));
        try std.testing.expectEqualSlices(usize, &.{index}, ready.take(0));
        for (hierarchy.levels[1..hierarchy.depth]) |level| {
            const mask = @as(usize, 1) << @intCast(word_index % Readiness.width);
            word_index /= Readiness.width;
            _ = hierarchy.words[level.offset + word_index].fetchOr(mask, .release);
        }
        try std.testing.expectEqual(@as(usize, 0), ready.take(0).len);
        ready.signal(index).notify();
        try std.testing.expectEqualSlices(usize, &.{index}, ready.take(0));
        try std.testing.expectEqual(@as(?i96, null), ready.deadline(0));
    }
}

test "signals retain their storage when readiness moves" {
    var original = try Readiness.init(std.testing.allocator, 4097);
    const signal = original.signal(4096);
    var moved = original;
    original = undefined;
    defer moved.deinit(std.testing.allocator);
    signal.notify();
    try std.testing.expectEqualSlices(usize, &.{4096}, moved.take(0));
}

test "concurrent notifiers preserve every acknowledged round while draining" {
    if (comptime builtin.single_threaded) return error.SkipZigTest;
    const Producer = struct {
        signal: Readiness.Signal,
        wake: *std.Io.Event,
        stopping: *std.atomic.Value(bool),
        published: std.atomic.Value(usize) = .init(0),
        acknowledged: std.atomic.Value(usize) = .init(0),
        completed: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            for (1..1001) |round| {
                self.signal.notify();
                self.published.store(round, .release);
                self.wake.set(std.testing.io);
                self.completed.waitUncancelable(std.testing.io);
                self.completed.reset();
                if (self.stopping.load(.acquire)) return;
                assert(self.acknowledged.load(.acquire) == round);
            }
        }
    };
    var ready = try Readiness.init(std.testing.allocator, 65537);
    defer ready.deinit(std.testing.allocator);
    var wake: std.Io.Event = .unset;
    var stopping: std.atomic.Value(bool) = .init(false);
    const indices = [_]usize{ 0, 1, 4096, 65536 };
    var producers: [indices.len]Producer = undefined;
    var threads: [indices.len]std.Thread = undefined;
    var started: usize = 0;
    defer {
        stopping.store(true, .release);
        for (producers[0..started]) |*producer| producer.completed.set(std.testing.io);
        for (threads[0..started]) |thread| thread.join();
    }
    for (&producers, &threads, indices) |*producer, *thread, index| {
        producer.* = .{ .signal = ready.signal(index), .wake = &wake, .stopping = &stopping };
        thread.* = try std.Thread.spawn(.{}, Producer.run, .{producer});
        started += 1;
    }
    var seen: [indices.len]bool = @splat(false);
    var completed: usize = 0;
    while (completed != 1000 * indices.len) {
        const batch = ready.take(0);
        for (batch) |index| {
            const owner = for (indices, 0..) |expected, at| {
                if (index == expected) break at;
            } else return error.UnexpectedConnection;
            try std.testing.expect(!seen[owner]);
            seen[owner] = true;
        }
        for (&producers, &seen) |*producer, *observed| {
            if (!observed.*) continue;
            const round = producer.published.load(.acquire);
            if (round == producer.acknowledged.load(.monotonic)) continue;
            observed.* = false;
            completed += 1;
            producer.acknowledged.store(round, .release);
            producer.completed.set(std.testing.io);
        }
        if (batch.len == 0) {
            wake.waitUncancelable(std.testing.io);
            wake.reset();
        }
    }
    try std.testing.expectEqual(@as(usize, 0), ready.take(0).len);
}

test "readiness initialization releases partial hierarchy allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var ready = try Readiness.init(allocator, 4097);
            defer ready.deinit(allocator);
            ready.signal(4096).notify();
            try std.testing.expectEqualSlices(usize, &.{4096}, ready.take(0));
        }
    }.run, .{});
}

test "sparse drains leave unpublished branches untouched" {
    var ready = try Readiness.init(std.testing.allocator, 65537);
    defer ready.deinit(std.testing.allocator);
    const index: usize = 65536;
    const word = &ready.hierarchy.words[index / Readiness.width];
    _ = word.fetchOr(1, .release);
    ready.signal(0).notify();
    try std.testing.expectEqualSlices(usize, &.{0}, ready.take(0));
    try std.testing.expectEqual(@as(usize, 1), word.load(.acquire));
    ready.signal(index).notify();
    try std.testing.expectEqualSlices(usize, &.{index}, ready.take(0));
    try std.testing.expectEqual(@as(usize, 0), word.load(.acquire));
}
