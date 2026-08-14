const std = @import("std");

const linux = std.os.linux;
const entry_count = 128;
const entry_bytes = 1024;

const Status = enum { free, queued, submitted };

const Entry = struct {
    status: Status = .free,
    offset: usize = 0,
    len: usize = 0,
    bytes: []u8 = &.{},

    fn reset(self: *Entry) void {
        const bytes = self.bytes;
        self.* = .{ .bytes = bytes };
    }
};

pub const Queue = struct {
    entries: []Entry = &.{},
    dropped: usize = 0,

    pub fn allocate(self: *Queue, allocator: std.mem.Allocator) !void {
        self.* = .{};
        self.entries = try allocator.alloc(Entry, entry_count);
        @memset(self.entries, .{});
        for (self.entries) |*entry|
            entry.bytes = try allocator.alloc(u8, entry_bytes);
    }

    pub fn activate(self: *Queue) void {
        active = self;
    }

    pub fn deactivate(self: *Queue) void {
        if (active == self) active = null;
    }

    pub fn submit(self: *Queue, ring: *linux.IoUring, user_data_base: u64) !void {
        for (self.entries, 0..) |*entry, index| {
            if (entry.status != .queued) continue;
            _ = try ring.write(user_data_base | @as(u64, @intCast(index)), 2, entry.bytes[entry.offset..entry.len], 0);
            entry.status = .submitted;
        }
    }

    pub fn complete(self: *Queue, index: usize, result: i32) void {
        if (index >= self.entries.len) return;
        const entry = &self.entries[index];
        if (result <= 0) {
            self.dropped += 1;
            entry.reset();
            return;
        }
        entry.offset += @intCast(result);
        if (entry.offset < entry.len) {
            entry.status = .queued;
            return;
        }
        entry.reset();
    }

    pub fn enqueue(self: *Queue, message: []const u8) void {
        if (message.len > entry_bytes) {
            self.dropped += 1;
            return;
        }
        const entry = self.acquire() orelse return;
        @memcpy(entry.bytes[0..message.len], message);
        entry.offset = 0;
        entry.len = message.len;
        entry.status = .queued;
    }

    fn append(self: *Queue, comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
        const entry = self.acquire() orelse return;
        var writer = std.Io.Writer.fixed(entry.bytes);
        writer.print("{s}", .{level.asText()}) catch return;
        if (scope != .default) writer.print("({s})", .{@tagName(scope)}) catch return;
        writer.writeAll(": ") catch return;
        writer.print(format, args) catch return;
        writer.writeByte('\n') catch return;
        entry.offset = 0;
        entry.len = writer.end;
        entry.status = .queued;
    }

    fn acquire(self: *Queue) ?*Entry {
        for (self.entries) |*entry| {
            if (entry.status == .free) return entry;
        }
        self.dropped += 1;
        return null;
    }
};

var active: ?*Queue = null;

pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (active) |queue| return queue.append(level, scope, format, args);
    std.log.defaultLog(level, scope, format, args);
}

test "messages remain stable until their write completes" {
    var queue: Queue = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try queue.allocate(arena.allocator());
    queue.append(.info, .test_scope, "value={d}", .{42});
    try std.testing.expectEqual(.queued, queue.entries[0].status);
    try std.testing.expectEqualStrings("info(test_scope): value=42\n", queue.entries[0].bytes[0..queue.entries[0].len]);
    queue.entries[0].status = .submitted;
    queue.complete(0, @intCast(queue.entries[0].len));
    try std.testing.expectEqual(.free, queue.entries[0].status);
}

test "preformatted tick-module messages use the same queue" {
    var queue: Queue = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try queue.allocate(arena.allocator());
    queue.enqueue("info(example): hello\n");
    try std.testing.expectEqualStrings("info(example): hello\n", queue.entries[0].bytes[0..queue.entries[0].len]);
}
