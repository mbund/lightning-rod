const std = @import("std");

pub const Queue = struct {
    records: []Record,
    storage: []u8,
    message_bytes: usize,
    priority_reserve: usize,
    head: usize = 0,
    count: usize = 0,
    lock: std.atomic.Value(u8) = .init(0),
    dropped: [4]std.atomic.Value(u64) = droppedCounters(),

    const Record = struct {
        level: std.log.Level = .debug,
        length: usize = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        message_bytes: usize,
        priority_reserve: usize,
    ) !Queue {
        if (capacity == 0 or message_bytes == 0 or priority_reserve > capacity)
            return error.InvalidLoggingCapacity;
        const records = try allocator.alloc(Record, capacity);
        const storage = try allocator.alloc(u8, try std.math.mul(usize, capacity, message_bytes));
        @memset(records, .{});
        return .{
            .records = records,
            .storage = storage,
            .message_bytes = message_bytes,
            .priority_reserve = priority_reserve,
        };
    }

    pub fn reservedBytes(capacity: usize, message_bytes: usize) !usize {
        if (capacity == 0 or message_bytes == 0) return error.InvalidLoggingCapacity;
        const records = try std.math.mul(usize, capacity, @sizeOf(Record));
        const storage = try std.math.mul(usize, capacity, message_bytes);
        return std.math.add(usize, records, storage);
    }

    pub fn write(
        self: *Queue,
        comptime level: std.log.Level,
        comptime scope: []const u8,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (!self.tryLock()) return self.drop(level);
        defer self.unlock();
        if (!self.admit(level)) return self.drop(level);
        const index = (self.head + self.count) % self.records.len;
        const destination = self.buffer(index);
        const message = formatRecord(destination, level, scope, format, args);
        self.records[index] = .{ .level = level, .length = message.len };
        self.count += 1;
    }

    pub fn peek(self: *Queue) ?[]const u8 {
        if (!self.tryLock()) return null;
        defer self.unlock();
        if (self.count == 0) return null;
        return self.buffer(self.head)[0..self.records[self.head].length];
    }

    pub fn tryConsume(self: *Queue) bool {
        if (!self.tryLock()) return false;
        defer self.unlock();
        std.debug.assert(self.count > 0);
        self.records[self.head] = .{};
        self.head = (self.head + 1) % self.records.len;
        self.count -= 1;
        return true;
    }

    pub fn consume(self: *Queue) void {
        std.debug.assert(self.tryConsume());
    }

    pub fn droppedCount(self: *const Queue, level: std.log.Level) u64 {
        return self.dropped[@intFromEnum(level)].load(.acquire);
    }

    fn admit(self: *const Queue, level: std.log.Level) bool {
        if (self.count == self.records.len) return false;
        const ordinary_limit = self.records.len - self.priority_reserve;
        return isPriority(level) or self.count < ordinary_limit;
    }

    fn buffer(self: *Queue, index: usize) []u8 {
        const start = index * self.message_bytes;
        return self.storage[start..][0..self.message_bytes];
    }

    fn tryLock(self: *Queue) bool {
        return self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    fn unlock(self: *Queue) void {
        self.lock.store(0, .release);
    }

    fn drop(self: *Queue, level: std.log.Level) void {
        _ = self.dropped[@intFromEnum(level)].fetchAdd(1, .monotonic);
    }
};

fn formatRecord(
    destination: []u8,
    comptime level: std.log.Level,
    comptime scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    const level_text = comptime level.asText();
    const prefix = comptime if (scope.len == 0 or std.mem.eql(u8, scope, "default"))
        level_text ++ ": "
    else
        level_text ++ "(" ++ scope ++ "): ";
    const body = std.fmt.bufPrint(destination, prefix ++ format, args) catch {
        const marker = prefix ++ "[log record truncated]";
        const length = @min(destination.len, marker.len);
        @memcpy(destination[0..length], marker[0..length]);
        return destination[0..length];
    };
    if (body.len == destination.len) return body;
    destination[body.len] = '\n';
    return destination[0 .. body.len + 1];
}

fn isPriority(level: std.log.Level) bool {
    return level == .err or level == .warn;
}

fn droppedCounters() [4]std.atomic.Value(u64) {
    return .{ .init(0), .init(0), .init(0), .init(0) };
}

test "priority capacity remains available under ordinary log pressure" {
    var memory: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var queue = try Queue.init(fixed.allocator(), 3, 64, 1);
    queue.write(.info, "test", "first", .{});
    queue.write(.debug, "test", "second", .{});
    queue.write(.info, "test", "dropped", .{});
    queue.write(.err, "test", "priority", .{});
    try std.testing.expectEqual(@as(u64, 1), queue.droppedCount(.info));
    try std.testing.expectEqualStrings("info(test): first\n", queue.peek().?);
    queue.consume();
    try std.testing.expectEqualStrings("debug(test): second\n", queue.peek().?);
    queue.consume();
    try std.testing.expectEqualStrings("error(test): priority\n", queue.peek().?);
}

test "contended producers drop instead of blocking Core" {
    var memory: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var queue = try Queue.init(fixed.allocator(), 1, 64, 0);
    queue.lock.store(1, .release);
    queue.write(.warn, "test", "busy", .{});
    queue.lock.store(0, .release);
    try std.testing.expectEqual(@as(u64, 1), queue.droppedCount(.warn));
}

test "contended consumers retry instead of spinning" {
    var memory: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var queue = try Queue.init(fixed.allocator(), 1, 64, 0);
    queue.write(.info, "test", "record", .{});
    queue.lock.store(1, .release);
    try std.testing.expect(!queue.tryConsume());
    queue.lock.store(0, .release);
    try std.testing.expect(queue.tryConsume());
}
