//! Which columns' entities are in memory: those near a player, as vanilla keeps the entities of
//! loaded chunks. A column coming near comes in from the store, and one going far goes out to
//! it; lookups see only the columns in memory, as vanilla's see only loaded sections.

const std = @import("std");
const space_module = @import("space.zig");

pub const Column = space_module.Column;

pub const Center = struct { world: u32, x: i32, z: i32 };

/// No columns, for `refresh` to want besides the centers'.
pub const NoColumns = struct {
    pub fn next(_: *NoColumns) ?Column {
        return null;
    }
};

pub const Residency = struct {
    loaded: std.AutoHashMapUnmanaged(Column, void) = .empty,
    wanted: std.AutoHashMapUnmanaged(Column, void) = .empty,
    capacity: usize,
    leaving: []Column,
    coming: []Column,
    /// Rises whenever a column comes in by being held, so a refresh knows to look again.
    held: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Residency {
        var self: Residency = .{ .capacity = capacity, .leaving = try allocator.alloc(Column, capacity), .coming = try allocator.alloc(Column, capacity) };
        try self.loaded.ensureTotalCapacity(allocator, @intCast(capacity));
        try self.wanted.ensureTotalCapacity(allocator, @intCast(capacity));
        return self;
    }

    pub fn holds(self: *const Residency, column: Column) bool {
        return self.loaded.contains(column);
    }

    /// A column the loaded domain brought in; false if it was held already.
    pub fn enter(self: *Residency, column: Column) !bool {
        if (self.loaded.contains(column)) return false;
        if (self.loaded.count() == self.capacity) return error.TooManyColumns;
        self.loaded.putAssumeCapacity(column, {});
        return true;
    }

    /// A column the loaded domain let go; false if it was not held.
    pub fn leave(self: *Residency, column: Column) bool {
        return self.loaded.remove(column);
    }

    /// A column in memory from now, as one an entity is made in.
    pub fn hold(self: *Residency, column: Column) !void {
        if (self.loaded.contains(column)) return;
        if (self.loaded.count() == self.capacity) return error.TooManyColumns;
        self.loaded.putAssumeCapacity(column, {});
        self.held += 1;
    }

    /// The columns within `radius` of the centers, a square as chunk loading goes, and any
    /// others `also` gives, an iterator of columns. What leaves is told first, then what comes, each in column order.
    pub fn refresh(self: *Residency, centers: []const Center, radius: i32, also: anytype, context: anytype, comptime leaving_column: fn (@TypeOf(context), Column) anyerror!void, comptime coming_column: fn (@TypeOf(context), Column) anyerror!void) !void {
        self.wanted.clearRetainingCapacity();
        for (centers) |center| {
            var x = center.x - radius;
            while (x <= center.x + radius) : (x += 1) {
                var z = center.z - radius;
                while (z <= center.z + radius) : (z += 1) try self.want(.{ .world = center.world, .x = x, .z = z });
            }
        }
        var others = also;
        while (others.next()) |column| try self.want(column);
        var leaving_count: usize = 0;
        var loaded = self.loaded.keyIterator();
        while (loaded.next()) |column| if (!self.wanted.contains(column.*)) {
            self.leaving[leaving_count] = column.*;
            leaving_count += 1;
        };
        var coming_count: usize = 0;
        var wanted = self.wanted.keyIterator();
        while (wanted.next()) |column| if (!self.loaded.contains(column.*)) {
            self.coming[coming_count] = column.*;
            coming_count += 1;
        };
        std.sort.pdq(Column, self.leaving[0..leaving_count], {}, before);
        std.sort.pdq(Column, self.coming[0..coming_count], {}, before);
        for (self.leaving[0..leaving_count]) |column| {
            try leaving_column(context, column);
            _ = self.loaded.remove(column);
        }
        for (self.coming[0..coming_count]) |column| {
            self.loaded.putAssumeCapacity(column, {});
            try coming_column(context, column);
        }
    }

    fn want(self: *Residency, column: Column) !void {
        if (self.wanted.contains(column)) return;
        if (self.wanted.count() == self.capacity) return error.TooManyColumns;
        self.wanted.putAssumeCapacity(column, {});
    }

    fn before(_: void, a: Column, b: Column) bool {
        if (a.world != b.world) return a.world < b.world;
        if (a.x != b.x) return a.x < b.x;
        return a.z < b.z;
    }
};

test "columns come and go as centers move" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var residency = try Residency.init(arena.allocator(), 32);
    var log: struct { came: usize = 0, left: usize = 0 } = .{};
    const Log = @TypeOf(log);
    const hooks = struct {
        fn leave(state: *Log, _: Column) anyerror!void {
            state.left += 1;
        }
        fn come(state: *Log, _: Column) anyerror!void {
            state.came += 1;
        }
    };
    try residency.refresh(&.{.{ .world = 0, .x = 0, .z = 0 }}, 1, NoColumns{}, &log, hooks.leave, hooks.come);
    try std.testing.expectEqual(@as(usize, 9), log.came);
    try residency.refresh(&.{.{ .world = 0, .x = 1, .z = 0 }}, 1, NoColumns{}, &log, hooks.leave, hooks.come);
    try std.testing.expect(log.came == 12 and log.left == 3);
    try std.testing.expect(residency.holds(.{ .world = 0, .x = 2, .z = 1 }) and !residency.holds(.{ .world = 0, .x = -1, .z = 0 }));
}
