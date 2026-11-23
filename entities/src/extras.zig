//! Rare and variable state beside kinds' tables, in the entities' pool. `Records(T)` keeps
//! records of one type, each at an index it keeps until let go, so a row's link to it holds
//! while others come and go. `Blobs` keeps byte strings of any length as chains of fixed blocks.

const std = @import("std");
const pool_module = @import("pool.zig");

const assert = std.debug.assert;
const Array = pool_module.Array;
const Pool = pool_module.Pool;

pub const none = std.math.maxInt(u32);

pub fn Records(comptime T: type) type {
    return struct {
        const Self = @This();

        values: Array(T),
        /// Indices let go, the last let go taken first.
        free: Array(u32),
        free_count: usize = 0,
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, pool: *Pool) !Self {
            return .{ .values = try .init(allocator, pool), .free = try .init(allocator, pool) };
        }

        pub fn at(self: *const Self, index: u32) *T {
            return self.values.at(index);
        }

        /// A record kept, at an index of its own.
        pub fn add(self: *Self, value: T) !u32 {
            const index: u32 = index: {
                if (self.free_count > 0) {
                    self.free_count -= 1;
                    break :index self.free.at(self.free_count).*;
                }
                try self.free.ensure(self.values.len + 1);
                break :index @intCast(self.values.grow() catch return error.EntityMemoryExhausted);
            };
            self.values.at(index).* = value;
            self.count += 1;
            return index;
        }

        pub fn remove(self: *Self, index: u32) void {
            assert(index < self.values.len);
            self.values.at(index).* = undefined;
            self.free.at(self.free_count).* = index;
            self.free_count += 1;
            self.count -= 1;
        }

        pub fn clear(self: *Self) void {
            self.values.clear();
            self.free.clear();
            self.free_count = 0;
            self.count = 0;
        }
    };
}

/// Byte strings as chains of blocks, each holding `payload` bytes and the next block's index.
pub const Blobs = struct {
    pub const payload = 248;
    const Block = struct { next: u32, length: u32, bytes: [payload]u8 };

    blocks: Records(Block),

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) !Blobs {
        return .{ .blocks = try .init(allocator, pool) };
    }

    /// A blob holding `bytes`, by its first block. An empty one has none.
    pub fn create(self: *Blobs, bytes: []const u8) !u32 {
        if (bytes.len == 0) return none;
        var first: u32 = none;
        var last: u32 = none;
        errdefer if (first != none) self.free(first);
        var at: usize = 0;
        while (at < bytes.len) {
            const length = @min(payload, bytes.len - at);
            var block: Block = .{ .next = none, .length = @intCast(bytes.len), .bytes = undefined };
            @memcpy(block.bytes[0..length], bytes[at..][0..length]);
            const index = try self.blocks.add(block);
            if (last == none) first = index else self.blocks.at(last).next = index;
            last = index;
            at += length;
        }
        return first;
    }

    /// How many bytes a blob holds.
    pub fn len(self: *const Blobs, first: u32) usize {
        return if (first == none) 0 else self.blocks.at(first).length;
    }

    /// `out.len` bytes of a blob from `offset` on.
    pub fn read(self: *const Blobs, first: u32, offset: usize, out: []u8) void {
        assert(offset + out.len <= self.len(first));
        var block = self.walk(first, offset / payload);
        var within = offset % payload;
        var done: usize = 0;
        while (done < out.len) {
            const length = @min(payload - within, out.len - done);
            @memcpy(out[done..][0..length], self.blocks.at(block).bytes[within..][0..length]);
            done += length;
            within = 0;
            block = self.blocks.at(block).next;
        }
    }

    /// Bytes of a blob from `offset` on written again.
    pub fn write(self: *Blobs, first: u32, offset: usize, bytes: []const u8) void {
        assert(offset + bytes.len <= self.len(first));
        var block = self.walk(first, offset / payload);
        var within = offset % payload;
        var done: usize = 0;
        while (done < bytes.len) {
            const length = @min(payload - within, bytes.len - done);
            @memcpy(self.blocks.at(block).bytes[within..][0..length], bytes[done..][0..length]);
            done += length;
            within = 0;
            block = self.blocks.at(block).next;
        }
    }

    fn walk(self: *const Blobs, first: u32, steps: usize) u32 {
        var block = first;
        for (0..steps) |_| block = self.blocks.at(block).next;
        return block;
    }

    pub fn free(self: *Blobs, first: u32) void {
        var block = first;
        while (block != none) {
            const next = self.blocks.at(block).next;
            self.blocks.remove(block);
            block = next;
        }
    }
};

test "records keep their indices, and blobs their bytes across blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try Pool.init(arena.allocator(), 8 * pool_module.page_bytes);
    var records = try Records(u64).init(arena.allocator(), &pool);
    const a = try records.add(1);
    const b = try records.add(2);
    records.remove(a);
    try std.testing.expectEqual(a, try records.add(3));
    try std.testing.expectEqual(@as(u64, 2), records.at(b).*);
    try std.testing.expectEqual(@as(usize, 2), records.count);
    var blobs = try Blobs.init(arena.allocator(), &pool);
    var bytes: [700]u8 = undefined;
    for (&bytes, 0..) |*byte, at| byte.* = @truncate(at * 7);
    const blob = try blobs.create(&bytes);
    try std.testing.expectEqual(@as(usize, 700), blobs.len(blob));
    var out: [300]u8 = undefined;
    blobs.read(blob, 200, &out);
    try std.testing.expectEqualSlices(u8, bytes[200..500], &out);
    blobs.write(blob, 240, &.{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 });
    blobs.read(blob, 240, out[0..12]);
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 }, out[0..12]);
    blobs.free(blob);
    try std.testing.expectEqual(@as(usize, 0), blobs.blocks.count);
    try std.testing.expectEqual(none, try blobs.create(&.{}));
}
