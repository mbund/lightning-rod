//! A bounded set of entity ids, in the order they were put in, in the entities' pool. Full, it
//! takes no more and says so: whoever relies on it then looks over everything it would have held,
//! which is never wrong. Ids find their places through an id index, without hashing.

const std = @import("std");
const pool_module = @import("pool.zig");
const IdIndexOf = @import("id_index.zig").IdIndexOf;

const assert = std.debug.assert;

pub const Id = u64;

pub const IdSet = struct {
    /// The ids in order, and each one's place among them.
    keys: []Id,
    places: IdIndexOf(1024),
    capacity: usize,
    /// Whether an insert found it full since the last clear.
    overflowed: bool = false,

    pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, capacity: usize) !IdSet {
        assert(capacity > 0);
        return .{ .keys = try allocator.alloc(Id, capacity), .places = try .init(allocator, pool), .capacity = capacity };
    }

    pub fn insert(self: *IdSet, entity: Id) void {
        if (self.places.contains(entity)) return;
        if (self.places.count == self.capacity) {
            self.overflowed = true;
            return;
        }
        const at = self.places.count;
        self.places.put(entity, @intCast(at)) catch {
            self.overflowed = true;
            return;
        };
        self.keys[at] = entity;
    }

    /// The last id takes the place of the one removed.
    pub fn remove(self: *IdSet, entity: Id) void {
        const at = self.places.get(entity) orelse return;
        _ = self.places.remove(entity);
        const last = self.places.count;
        if (at != last) {
            self.keys[at] = self.keys[last];
            self.places.set(self.keys[at], at);
        }
    }

    pub fn contains(self: *const IdSet, entity: Id) bool {
        return @constCast(&self.places).contains(entity);
    }

    pub fn count(self: *const IdSet) usize {
        return self.places.count;
    }

    pub fn values(self: *const IdSet) []const Id {
        return self.keys[0..self.places.count];
    }

    /// Clears in time with what it holds, not what it has room for: a set cleared every tick
    /// mostly holds few.
    pub fn clear(self: *IdSet) void {
        if (self.places.count * 16 < self.capacity) {
            for (self.keys[0..self.places.count]) |entity| _ = self.places.remove(entity);
        } else self.places.clear();
        self.overflowed = false;
    }
};

test "an id set takes ids once each, and tells when it had no room" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try pool_module.Pool.init(arena.allocator(), 8 * pool_module.page_bytes);
    var set = try IdSet.init(arena.allocator(), &pool, 3);
    for ([_]Id{ 5, 9, 5, 2 }) |entity| set.insert(entity);
    try std.testing.expectEqualSlices(Id, &.{ 5, 9, 2 }, set.values());
    try std.testing.expect(!set.overflowed);
    set.insert(7);
    try std.testing.expect(set.overflowed and !set.contains(7));
    set.remove(5);
    try std.testing.expectEqualSlices(Id, &.{ 2, 9 }, set.values());
    set.insert(7);
    try std.testing.expect(set.contains(7) and set.count() == 3);
    set.clear();
    try std.testing.expect(!set.overflowed and set.count() == 0);
}
