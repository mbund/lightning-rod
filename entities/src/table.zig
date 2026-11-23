//! One component's values for the entities that have it: dense, so passes over it read
//! memory in order, with each entity's place found by id. Its room is fixed when it is made,
//! as every plugin's memory is; past it, a put fails and the caller must make room. Removing
//! moves the last value into the hole, so pointers into a table last only until its next insert
//! or removal.

const std = @import("std");
const pool_module = @import("pool.zig");
const IdIndexOf = @import("id_index.zig").IdIndexOf;

const assert = std.debug.assert;

pub const Id = u64;

pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        ids: []Id,
        values: []T,
        len: usize = 0,
        /// Each id's place, through an id index, without hashing.
        index: IdIndexOf(1024),

        pub fn init(allocator: std.mem.Allocator, pool: *pool_module.Pool, room: usize) !Self {
            assert(room > 0 and room <= std.math.maxInt(u32));
            return .{ .ids = try allocator.alloc(Id, room), .values = try allocator.alloc(T, room), .index = try .init(allocator, pool) };
        }

        pub fn capacity(self: *const Self) usize {
            return self.ids.len;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// The ids with values, in no order; good until the next insert or removal.
        pub fn keys(self: *const Self) []const Id {
            return self.ids[0..self.len];
        }

        pub fn items(self: *Self) []T {
            return self.values[0..self.len];
        }

        pub fn constItems(self: *const Self) []const T {
            return self.values[0..self.len];
        }

        pub fn contains(self: *const Self, entity: Id) bool {
            return @constCast(&self.index).contains(entity);
        }

        pub fn get(self: *Self, entity: Id) ?*T {
            const at = self.index.get(entity) orelse return null;
            return &self.values[at];
        }

        pub fn getConst(self: *const Self, entity: Id) ?*const T {
            const at = @constCast(&self.index).get(entity) orelse return null;
            return &self.values[at];
        }

        /// The entity's value, made or replaced.
        pub fn put(self: *Self, entity: Id, value: T) !*T {
            if (self.index.get(entity)) |at| {
                self.values[at] = value;
                return &self.values[at];
            }
            if (self.len == self.ids.len) return error.TableFull;
            const at: u32 = @intCast(self.len);
            try self.index.put(entity, at);
            self.ids[at] = entity;
            self.values[at] = value;
            self.len += 1;
            return &self.values[at];
        }

        /// Takes the entity's value out, if it had one.
        pub fn remove(self: *Self, entity: Id) ?T {
            const at = self.index.get(entity) orelse return null;
            _ = self.index.remove(entity);
            const value = self.values[at];
            const last = self.len - 1;
            if (at != last) {
                const moved = self.ids[last];
                self.ids[at] = moved;
                self.values[at] = self.values[last];
                self.index.set(moved, at);
            }
            self.len = last;
            return value;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.index.clear();
        }
    };
}

test "a table finds values by id and keeps them dense as they go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var pool = try pool_module.Pool.init(arena.allocator(), 8 * pool_module.page_bytes);
    var table = try Table(u32).init(arena.allocator(), &pool, 5);
    for (1..6) |entity| _ = try table.put(entity, @intCast(entity * 10));
    try std.testing.expectError(error.TableFull, table.put(9, 1));
    try std.testing.expectEqual(@as(usize, 5), table.count());
    try std.testing.expectEqual(@as(u32, 30), table.get(3).?.*);
    try std.testing.expectEqual(@as(?u32, 20), table.remove(2));
    try std.testing.expect(table.get(2) == null and table.remove(2) == null);
    // The last took the hole, and is still found.
    try std.testing.expectEqual(@as(u32, 50), table.get(5).?.*);
    try std.testing.expectEqual(@as(usize, 4), table.count());
    for (table.keys(), table.constItems()) |entity, value| try std.testing.expectEqual(@as(u32, @intCast(entity * 10)), value);
    _ = try table.put(4, 7);
    try std.testing.expectEqual(@as(u32, 7), table.get(4).?.*);
    // Room comes back as values go, removals and all.
    for (0..1000) |round| {
        _ = try table.put(100 + round, 1);
        _ = table.remove(100 + round);
    }
    try std.testing.expectEqual(@as(usize, 4), table.count());
}
