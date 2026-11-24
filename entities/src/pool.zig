//! The memory entities live in: one arena of pages of one size, taken whole at startup, on huge
//! pages where the system gives them, every byte written once so it is the process's from the
//! start. Every table of entity state draws whole pages from it and gives them back as it
//! shrinks, so no table has a room of its own and the pool cannot fragment: any free page fits
//! any table. Nothing asks the system for memory after.

const std = @import("std");

const assert = std.debug.assert;

pub const page_bytes = 64 * 1024;
/// A huge page: the arena starts on one, so the system can back it with them.
pub const huge_page_bytes = 2 * 1024 * 1024;
/// What every byte holds until a table writes it, so a read of memory never written stands out.
pub const poison: u8 = 0xaa;
const none = std.math.maxInt(u32);

pub const Pool = struct {
    memory: []align(huge_page_bytes) u8,
    free: []u32,
    free_count: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Pool {
        const count = size / page_bytes;
        if (count == 0 or count >= none) return error.InvalidConfiguration;
        const self: Pool = .{
            .memory = try allocator.alignedAlloc(u8, .fromByteUnits(huge_page_bytes), count * page_bytes),
            .free = try allocator.alloc(u32, count),
            .free_count = count,
        };
        // Asked for huge pages, then touched throughout: the memory is the process's from now on,
        // and not the system's to find later.
        adviseHuge(self.memory);
        @memset(self.memory, poison);
        // Taken from the back, the lowest first.
        for (self.free, 0..) |*page, at| page.* = @intCast(count - 1 - at);
        return self;
    }

    fn adviseHuge(memory: []align(huge_page_bytes) u8) void {
        if (@import("builtin").os.tag != .linux) return;
        const linux = std.os.linux;
        // Best effort: without transparent huge pages it stays on small ones.
        _ = linux.madvise(memory.ptr, memory.len, linux.MADV.HUGEPAGE);
    }

    pub fn pageCount(self: *const Pool) usize {
        return self.free.len;
    }

    pub fn freeCount(self: *const Pool) usize {
        return self.free_count;
    }

    pub fn take(self: *Pool) !u32 {
        // Memory used up is where vanilla runs out of heap: the one bound, which stops the server.
        if (self.free_count == 0) return error.EntityMemoryExhausted;
        self.free_count -= 1;
        return self.free[self.free_count];
    }

    pub fn give(self: *Pool, page: u32) void {
        assert(page < self.free.len);
        self.free[self.free_count] = page;
        self.free_count += 1;
    }

    pub fn bytes(self: *const Pool, page: u32) *align(page_bytes) [page_bytes]u8 {
        return @alignCast(self.memory[@as(usize, page) * page_bytes ..][0..page_bytes]);
    }
};

/// A dense array of values in pool pages, growing a page at a time and giving pages back as it
/// shrinks. Pointers into it hold while it does not shrink past them.
pub fn Array(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Value = T;
        pub const per_page = page_bytes / @sizeOf(T);
        comptime {
            assert(per_page > 0 and @alignOf(T) <= page_bytes);
        }

        pool: *Pool,
        pages: []u32,
        page_count: usize = 0,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, pool: *Pool) !Self {
            return .{ .pool = pool, .pages = try allocator.alloc(u32, pool.pageCount()) };
        }

        pub fn at(self: *const Self, index: usize) *T {
            assert(index < self.len);
            const page = self.pool.bytes(self.pages[index / per_page]);
            const values: *[per_page]T = @ptrCast(page);
            return &values[index % per_page];
        }

        /// Room for one more at the end, a page taken if need be: its index.
        pub fn grow(self: *Self) !usize {
            if (self.len == self.page_count * per_page) {
                if (self.page_count == self.pages.len) return error.EntityMemoryExhausted;
                self.pages[self.page_count] = try self.pool.take();
                self.page_count += 1;
            }
            self.len += 1;
            return self.len - 1;
        }

        pub fn append(self: *Self, value: T) !usize {
            const index = try self.grow();
            self.at(index).* = value;
            return index;
        }

        /// The values from `start` to `end` as one slice, if they share a page.
        pub fn run(self: *const Self, start: usize, end: usize) ?[]T {
            assert(start <= end and end <= self.len);
            if (start == end) return &.{};
            if (start / per_page != (end - 1) / per_page) return null;
            return @as([*]T, @ptrCast(self.at(start)))[0 .. end - start];
        }

        /// At least `count` values, those added undefined.
        pub fn ensure(self: *Self, count: usize) !void {
            while (self.len < count) _ = try self.grow();
        }

        /// At least `count` values, those added set to `value`.
        pub fn ensureFilled(self: *Self, count: usize, value: T) !void {
            while (self.len < count) self.at(try self.grow()).* = value;
        }

        /// `n` values from `first` in a row, as one copy where they share a page.
        pub fn loadRun(self: *const Self, comptime n: usize, first: usize) [n]T {
            assert(first + n <= self.len);
            if (first % per_page + n <= per_page) return @as(*const [n]T, @ptrCast(self.at(first))).*;
            var values: [n]T = undefined;
            for (&values, first..) |*value, index| value.* = self.at(index).*;
            return values;
        }

        pub fn storeRun(self: *Self, comptime n: usize, first: usize, values: [n]T) void {
            assert(first + n <= self.len);
            if (first % per_page + n <= per_page) {
                @as(*[n]T, @ptrCast(self.at(first))).* = values;
                return;
            }
            for (values, first..) |value, index| self.at(index).* = value;
        }

        /// The last value goes, and its page with it once empty.
        pub fn pop(self: *Self) void {
            assert(self.len > 0);
            self.len -= 1;
            if (self.len == (self.page_count - 1) * per_page) {
                self.page_count -= 1;
                self.pool.give(self.pages[self.page_count]);
            }
        }

        pub fn clear(self: *Self) void {
            while (self.len > 0) self.pop();
        }

        /// Empty again, its pages kept for what comes next, as for a list filled every tick.
        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        /// Its first `count` kept, its pages too.
        pub fn shrink(self: *Self, count: usize) void {
            assert(count <= self.len);
            self.len = count;
        }

        /// The bytes its pages hold, for measuring.
        pub fn memoryBytes(self: *const Self) usize {
            return self.page_count * page_bytes;
        }
    };
}

const testing = std.testing;

test "arrays take and give pages as they grow and shrink" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = try Pool.init(arena.allocator(), 4 * page_bytes);
    var values = try Array(u64).init(arena.allocator(), &pool);
    const per_page = Array(u64).per_page;
    for (0..per_page * 3) |at| _ = try values.append(at);
    try testing.expectEqual(@as(usize, 1), pool.freeCount());
    try testing.expectEqual(@as(u64, per_page + 5), values.at(per_page + 5).*);
    for (0..per_page + 1) |_| values.pop();
    try testing.expectEqual(@as(usize, 2), pool.freeCount());
    _ = try values.append(1);
    for (0..per_page * 2) |_| _ = try values.append(2);
    try testing.expectError(error.EntityMemoryExhausted, values.append(3));
}

/// A set of small indices in pool pages, in the order they joined with the last moved into a
/// hole, as `system.IndexSet` keeps them, growing with the largest index and the most members.
pub const IndexSet = struct {
    const absent = std.math.maxInt(u32);

    indices: Array(u32),
    positions: Array(u32),
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) !IndexSet {
        return .{ .indices = try .init(allocator, pool), .positions = try .init(allocator, pool) };
    }

    pub fn insert(self: *IndexSet, index: u32) !void {
        try self.positions.ensureFilled(@as(usize, index) + 1, absent);
        if (self.positions.at(index).* != absent) return;
        try self.indices.ensure(self.count + 1);
        self.positions.at(index).* = @intCast(self.count);
        self.indices.at(self.count).* = index;
        self.count += 1;
    }

    pub fn remove(self: *IndexSet, index: u32) void {
        if (index >= self.positions.len) return;
        const position = self.positions.at(index).*;
        if (position == absent) return;
        self.count -= 1;
        const moved = self.indices.at(self.count).*;
        self.indices.at(position).* = moved;
        self.positions.at(moved).* = position;
        self.positions.at(index).* = absent;
    }

    pub fn contains(self: *const IndexSet, index: u32) bool {
        return index < self.positions.len and self.positions.at(index).* != absent;
    }

    /// The member at a position, below `count`.
    pub fn at(self: *const IndexSet, position: usize) u32 {
        assert(position < self.count);
        return self.indices.at(position).*;
    }
};

test "an index set keeps join order, the last filling a hole" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var pool = try Pool.init(arena.allocator(), 4 * page_bytes);
    var set = try IndexSet.init(arena.allocator(), &pool);
    for ([_]u32{ 5, 2, 9, 2 }) |index| try set.insert(index);
    set.remove(5);
    try testing.expectEqual(@as(usize, 2), set.count);
    try testing.expectEqual(@as(u32, 9), set.at(0));
    try testing.expectEqual(@as(u32, 2), set.at(1));
    try testing.expect(!set.contains(5) and set.contains(9));
}
