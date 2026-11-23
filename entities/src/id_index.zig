//! Entity ids to small numbers, without hashing. Ids are handed out in rising order, so the ids
//! in memory cluster: they are kept in pages, each covering a run of `span` ids, found by a binary
//! search of the pages' first ids, newest last, the page last found tried first. A page goes back
//! once it holds no id.

const std = @import("std");
const pool_module = @import("pool.zig");
const extras = @import("extras.zig");

const assert = std.debug.assert;
const Array = pool_module.Array;
const Pool = pool_module.Pool;

pub const Id = u64;
const none = std.math.maxInt(u32);

/// The directory's: a page of the pool covers as many ids as it holds slots.
pub const IdIndex = IdIndexOf(pool_module.page_bytes / 4);

pub fn IdIndexOf(comptime span: usize) type {
    return struct {
        const Self = @This();
        const Page = [span]u32;
        const PageRef = struct { number: u64, page: u32, live: u32 };

        pages: extras.Records(Page),
        /// Pages by the ids they cover, in order.
        refs: Array(PageRef),
        count: usize = 0,
        /// The page last found, which most lookups ask again: where it is among the pages, and
        /// its ids' values themselves.
        last: usize = 0,
        last_number: u64 = std.math.maxInt(u64),
        last_page: ?*Page = null,

        pub fn init(allocator: std.mem.Allocator, pool: *Pool) !Self {
            return .{ .pages = try .init(allocator, pool), .refs = try .init(allocator, pool) };
        }

        /// Where the page covering `number` is, or would go.
        fn find(self: *Self, number: u64) struct { at: usize, found: bool } {
            if (self.last < self.refs.len and self.refs.at(self.last).number == number) return .{ .at = self.last, .found = true };
            var low: usize = 0;
            var high: usize = self.refs.len;
            while (low < high) {
                const middle = (low + high) / 2;
                if (self.refs.at(middle).number < number) low = middle + 1 else high = middle;
            }
            const found = low < self.refs.len and self.refs.at(low).number == number;
            if (found) {
                self.last = low;
                self.last_number = number;
                self.last_page = self.pages.at(self.refs.at(low).page);
            }
            return .{ .at = low, .found = found };
        }

        pub fn get(self: *Self, id: Id) ?u32 {
            if (id / span == self.last_number) {
                const value = self.last_page.?[id % span];
                return if (value == none) null else value;
            }
            const place = self.find(id / span);
            if (!place.found) return null;
            const value = self.pages.at(self.refs.at(place.at).page)[id % span];
            return if (value == none) null else value;
        }

        pub fn contains(self: *Self, id: Id) bool {
            return self.get(id) != null;
        }

        /// An id takes a value; it had none.
        pub fn put(self: *Self, id: Id, value: u32) !void {
            assert(value != none);
            const number = id / span;
            const place = self.find(number);
            if (!place.found) {
                const page = try self.pages.add(undefined);
                errdefer self.pages.remove(page);
                @memset(self.pages.at(page), none);
                try self.refs.ensure(self.refs.len + 1);
                var at = self.refs.len - 1;
                while (at > place.at) : (at -= 1) self.refs.at(at).* = self.refs.at(at - 1).*;
                self.refs.at(place.at).* = .{ .number = number, .page = page, .live = 0 };
                self.last = place.at;
            }
            const ref = self.refs.at(place.at);
            const held = &self.pages.at(ref.page)[id % span];
            assert(held.* == none);
            held.* = value;
            ref.live += 1;
            self.count += 1;
        }

        /// An id that has a value takes another.
        pub fn set(self: *Self, id: Id, value: u32) void {
            const place = self.find(id / span);
            assert(place.found);
            self.pages.at(self.refs.at(place.at).page)[id % span] = value;
        }

        pub fn remove(self: *Self, id: Id) bool {
            const place = self.find(id / span);
            if (!place.found) return false;
            const ref = self.refs.at(place.at);
            const held = &self.pages.at(ref.page)[id % span];
            if (held.* == none) return false;
            held.* = none;
            ref.live -= 1;
            self.count -= 1;
            if (ref.live == 0) {
                self.pages.remove(ref.page);
                self.last_number = std.math.maxInt(u64);
                self.last_page = null;
                for (place.at..self.refs.len - 1) |at| self.refs.at(at).* = self.refs.at(at + 1).*;
                self.refs.pop();
                self.last = 0;
            }
            return true;
        }

        /// Every id goes.
        pub fn clear(self: *Self) void {
            self.pages.clear();
            self.refs.clear();
            self.count = 0;
            self.last = 0;
            self.last_number = std.math.maxInt(u64);
            self.last_page = null;
        }
    };
}

test "ids find their values across pages, and empty pages go back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try Pool.init(arena.allocator(), 16 * pool_module.page_bytes);
    const Index = IdIndexOf(1024);
    var index = try Index.init(arena.allocator(), &pool);
    const ids = [_]Id{ 5, 1024 * 3 + 1, 7, 1024 * 1000, 2 };
    for (ids, 0..) |id, value| try index.put(id, @intCast(value));
    for (ids, 0..) |id, value| try std.testing.expectEqual(@as(?u32, @intCast(value)), index.get(id));
    try std.testing.expectEqual(@as(?u32, null), index.get(6));
    try std.testing.expectEqual(@as(?u32, null), index.get(1024 * 2));
    for (ids) |id| try std.testing.expect(index.remove(id));
    try std.testing.expectEqual(@as(usize, 0), index.count);
    try std.testing.expectEqual(@as(usize, 0), index.pages.count);
}
