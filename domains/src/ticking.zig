//! The ticking domain: every column within simulation distance of a player, as vanilla's
//! player tickets reach (a square, by Chebyshev distance), plus forced columns. Columns are
//! counted by the sources that reach them, so a column ticks while any source does.

const std = @import("std");

const assert = std.debug.assert;

pub const Column = struct {
    world: u32,
    x: i32,
    z: i32,

    fn hash(self: Column) u64 {
        var bytes: [12]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.world, .little);
        std.mem.writeInt(i32, bytes[4..8], self.x, .little);
        std.mem.writeInt(i32, bytes[8..12], self.z, .little);
        return std.hash.Wyhash.hash(0x7469636b696e67, &bytes);
    }
};

/// What reaches columns around one player slot this tick.
pub const Source = struct {
    world: u32,
    x: i32,
    z: i32,
    radius: i32,
};

/// The area a source covers. A player who moves within one column of the anchor keeps it, so
/// pacing across a column edge does not start and stop the columns on the far side.
const Anchor = struct {
    world: u32,
    x: i32,
    z: i32,
    radius: i32,

    fn covers(self: Anchor, column: Column) bool {
        return column.world == self.world and @abs(@as(i64, column.x) - self.x) <= self.radius and @abs(@as(i64, column.z) - self.z) <= self.radius;
    }
};

pub const Configuration = struct {
    /// Player slots, each of which may be a source.
    sources: usize,
    /// The largest simulation distance a source may have.
    maximum_radius: i32,
    /// Columns forced to tick at once.
    forced: usize,
};

pub const Ticking = struct {
    const Slot = struct { column: Column, count: u32 };

    anchors: []?Anchor,
    /// Open addressing with linear probing and backward shift deletion.
    slots: []?Slot,
    count: usize = 0,
    capacity: usize,
    forced: []?Column,
    forced_count: usize = 0,
    /// Columns that began or stopped ticking since the last `drain`.
    entered: []Column,
    entered_count: usize = 0,
    left: []Column,
    left_count: usize = 0,
    maximum_radius: i32,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !Ticking {
        if (config.sources == 0 or config.maximum_radius < 1 or config.maximum_radius > 33) return error.InvalidConfiguration;
        const side: usize = @intCast(2 * config.maximum_radius + 1);
        const capacity = config.sources * side * side + config.forced;
        // Twice the capacity, rounded up, keeps probes short at a full table.
        const slot_count = std.math.ceilPowerOfTwo(usize, 2 * capacity) catch return error.InvalidConfiguration;
        // A source that teleports leaves its whole square and enters another in one tick.
        const changes = config.sources * 2 * side * side + 2 * config.forced;
        const anchors = try allocator.alloc(?Anchor, config.sources);
        errdefer allocator.free(anchors);
        const slots = try allocator.alloc(?Slot, slot_count);
        errdefer allocator.free(slots);
        const forced = try allocator.alloc(?Column, config.forced);
        errdefer allocator.free(forced);
        const entered = try allocator.alloc(Column, changes);
        errdefer allocator.free(entered);
        const left = try allocator.alloc(Column, changes);
        @memset(anchors, null);
        @memset(slots, null);
        @memset(forced, null);
        return .{ .anchors = anchors, .slots = slots, .capacity = capacity, .forced = forced, .entered = entered, .left = left, .maximum_radius = config.maximum_radius };
    }

    pub fn deinit(self: *Ticking, allocator: std.mem.Allocator) void {
        allocator.free(self.anchors);
        allocator.free(self.slots);
        allocator.free(self.forced);
        allocator.free(self.entered);
        allocator.free(self.left);
        self.* = undefined;
    }

    pub fn contains(self: *const Ticking, column: Column) bool {
        return self.find(column) != null;
    }

    /// Ticking columns, or ones beside a ticking column, which systems may read but not change.
    pub fn readable(self: *const Ticking, column: Column) bool {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                if (self.contains(.{ .world = column.world, .x = column.x +% dx, .z = column.z +% dz })) return true;
            }
        }
        return false;
    }

    /// Moves a slot's source. Null removes it.
    pub fn update(self: *Ticking, slot: usize, source: ?Source) void {
        assert(slot < self.anchors.len);
        const previous = self.anchors[slot];
        const next: ?Anchor = if (source) |value| next: {
            assert(value.radius >= 1 and value.radius <= self.maximum_radius);
            if (previous) |anchor| {
                const kept = anchor.world == value.world and anchor.radius == value.radius and
                    @abs(@as(i64, value.x) - anchor.x) <= 1 and @abs(@as(i64, value.z) - anchor.z) <= 1;
                if (kept) return;
            }
            break :next .{ .world = value.world, .x = value.x, .z = value.z, .radius = value.radius };
        } else null;
        if (previous == null and next == null) return;
        if (previous) |anchor| self.sweep(anchor, next, .release);
        if (next) |anchor| self.sweep(anchor, previous, .acquire);
        self.anchors[slot] = next;
    }

    /// Makes a column tick regardless of players, until `unforce`.
    pub fn force(self: *Ticking, column: Column) !void {
        for (self.forced) |entry| if (entry) |held| if (std.meta.eql(held, column)) return error.AlreadyForced;
        const free = for (self.forced, 0..) |entry, index| {
            if (entry == null) break index;
        } else return error.ForcedCapacity;
        self.forced[free] = column;
        self.forced_count += 1;
        self.acquire(column);
    }

    pub fn unforce(self: *Ticking, column: Column) !void {
        const index = for (self.forced, 0..) |entry, index| {
            if (entry) |held| if (std.meta.eql(held, column)) break index;
        } else return error.NotForced;
        self.forced[index] = null;
        self.forced_count -= 1;
        self.release(column);
    }

    /// The columns that began and stopped ticking since the last drain. A column that did both
    /// appears in neither.
    pub fn drain(self: *Ticking) struct { entered: []const Column, left: []const Column } {
        // Several sources changing in one tick can enter, leave and enter a column again.
        // Columns are their whole order: equal ones are the same, so unstable sorts do.
        std.sort.pdq(Column, self.entered[0..self.entered_count], {}, lessThan);
        std.sort.pdq(Column, self.left[0..self.left_count], {}, lessThan);
        var entered: usize = 0;
        for (self.entered[0..self.entered_count]) |column| {
            if (!self.contains(column)) continue;
            if (entered != 0 and std.meta.eql(self.entered[entered - 1], column)) continue;
            self.entered[entered] = column;
            entered += 1;
        }
        var left: usize = 0;
        for (self.left[0..self.left_count]) |column| {
            if (self.contains(column)) continue;
            if (left != 0 and std.meta.eql(self.left[left - 1], column)) continue;
            self.left[left] = column;
            left += 1;
        }
        self.entered_count = 0;
        self.left_count = 0;
        return .{ .entered = self.entered[0..entered], .left = self.left[0..left] };
    }

    pub fn columns(self: *const Ticking) usize {
        return self.count;
    }

    pub const Iterator = struct {
        slots: []const ?Slot,
        index: usize = 0,

        pub fn next(self: *Iterator) ?Column {
            while (self.index < self.slots.len) {
                defer self.index += 1;
                if (self.slots[self.index]) |slot| return slot.column;
            }
            return null;
        }
    };

    pub fn iterator(self: *const Ticking) Iterator {
        return .{ .slots = self.slots };
    }

    fn lessThan(_: void, a: Column, b: Column) bool {
        if (a.world != b.world) return a.world < b.world;
        if (a.x != b.x) return a.x < b.x;
        return a.z < b.z;
    }

    const Change = enum { acquire, release };

    /// Counts every column of `anchor` that `other` does not cover.
    fn sweep(self: *Ticking, anchor: Anchor, other: ?Anchor, change: Change) void {
        var z = anchor.z - anchor.radius;
        while (z <= anchor.z + anchor.radius) : (z += 1) {
            var x = anchor.x - anchor.radius;
            while (x <= anchor.x + anchor.radius) : (x += 1) {
                const column: Column = .{ .world = anchor.world, .x = x, .z = z };
                if (other) |kept| if (kept.covers(column)) continue;
                switch (change) {
                    .acquire => self.acquire(column),
                    .release => self.release(column),
                }
            }
        }
    }

    fn acquire(self: *Ticking, column: Column) void {
        const mask = self.slots.len - 1;
        var index: usize = @intCast(column.hash() & mask);
        while (self.slots[index]) |*slot| : (index = (index + 1) & mask) {
            if (!std.meta.eql(slot.column, column)) continue;
            slot.count += 1;
            return;
        }
        // Sources and forced columns are bounded, so the table never fills.
        assert(self.count < self.capacity);
        self.slots[index] = .{ .column = column, .count = 1 };
        self.count += 1;
        assert(self.entered_count < self.entered.len);
        self.entered[self.entered_count] = column;
        self.entered_count += 1;
    }

    fn release(self: *Ticking, column: Column) void {
        const mask = self.slots.len - 1;
        var index = self.find(column) orelse unreachable;
        const slot = &self.slots[index].?;
        assert(slot.count > 0);
        slot.count -= 1;
        if (slot.count != 0) return;
        self.slots[index] = null;
        self.count -= 1;
        assert(self.left_count < self.left.len);
        self.left[self.left_count] = column;
        self.left_count += 1;
        // Backward shift: move later entries of the cluster into the hole when their probe
        // path passes through it.
        var next = (index + 1) & mask;
        while (self.slots[next]) |moved| : (next = (next + 1) & mask) {
            const home: usize = @intCast(moved.column.hash() & mask);
            const distance_home = (next -% home) & mask;
            const distance_hole = (next -% index) & mask;
            if (distance_home < distance_hole) continue;
            self.slots[index] = moved;
            self.slots[next] = null;
            index = next;
        }
    }

    fn find(self: *const Ticking, column: Column) ?usize {
        const mask = self.slots.len - 1;
        var index: usize = @intCast(column.hash() & mask);
        while (self.slots[index]) |slot| : (index = (index + 1) & mask) {
            if (std.meta.eql(slot.column, column)) return index;
        }
        return null;
    }
};

fn expectSquare(ticking: *const Ticking, world: u32, x: i32, z: i32, radius: i32) !void {
    var count: usize = 0;
    var iterator = ticking.iterator();
    while (iterator.next()) |column| {
        try std.testing.expectEqual(world, column.world);
        try std.testing.expect(@abs(column.x - x) <= radius and @abs(column.z - z) <= radius);
        count += 1;
    }
    const side: usize = @intCast(2 * radius + 1);
    try std.testing.expectEqual(side * side, count);
}

test "a player source ticks a square and moving it trades only the edges" {
    var ticking = try Ticking.init(std.testing.allocator, .{ .sources = 2, .maximum_radius = 8, .forced = 4 });
    defer ticking.deinit(std.testing.allocator);
    ticking.update(0, .{ .world = 1, .x = 0, .z = 0, .radius = 2 });
    try expectSquare(&ticking, 1, 0, 0, 2);
    var changes = ticking.drain();
    try std.testing.expectEqual(@as(usize, 25), changes.entered.len);
    try std.testing.expectEqual(@as(usize, 0), changes.left.len);

    // Within one column of the anchor nothing changes.
    ticking.update(0, .{ .world = 1, .x = 1, .z = -1, .radius = 2 });
    changes = ticking.drain();
    try std.testing.expectEqual(@as(usize, 0), changes.entered.len + changes.left.len);

    // Two columns east moves the anchor: two columns of five enter and two leave.
    ticking.update(0, .{ .world = 1, .x = 2, .z = 0, .radius = 2 });
    try expectSquare(&ticking, 1, 2, 0, 2);
    changes = ticking.drain();
    try std.testing.expectEqual(@as(usize, 10), changes.entered.len);
    try std.testing.expectEqual(@as(usize, 10), changes.left.len);
    for (changes.entered) |column| try std.testing.expect(column.x >= 3);
    for (changes.left) |column| try std.testing.expect(column.x <= -1);
    try std.testing.expect(ticking.readable(.{ .world = 1, .x = 5, .z = 0 }));
    try std.testing.expect(!ticking.readable(.{ .world = 1, .x = 6, .z = 0 }));
}

test "overlapping sources and forced columns keep a column until the last releases it" {
    var ticking = try Ticking.init(std.testing.allocator, .{ .sources = 2, .maximum_radius = 8, .forced = 1 });
    defer ticking.deinit(std.testing.allocator);
    ticking.update(0, .{ .world = 0, .x = 0, .z = 0, .radius = 1 });
    ticking.update(1, .{ .world = 0, .x = 2, .z = 0, .radius = 1 });
    // Columns x = 1 are shared by both squares.
    try std.testing.expectEqual(@as(usize, 15), ticking.columns());
    try ticking.force(.{ .world = 0, .x = 1, .z = 0 });
    try std.testing.expectError(error.ForcedCapacity, ticking.force(.{ .world = 0, .x = 9, .z = 9 }));
    try std.testing.expectError(error.AlreadyForced, ticking.force(.{ .world = 0, .x = 1, .z = 0 }));
    _ = ticking.drain();
    ticking.update(0, null);
    ticking.update(1, null);
    try std.testing.expectEqual(@as(usize, 1), ticking.columns());
    try std.testing.expect(ticking.contains(.{ .world = 0, .x = 1, .z = 0 }));
    var changes = ticking.drain();
    try std.testing.expectEqual(@as(usize, 14), changes.left.len);
    try ticking.unforce(.{ .world = 0, .x = 1, .z = 0 });
    try std.testing.expectEqual(@as(usize, 0), ticking.columns());
    changes = ticking.drain();
    try std.testing.expectEqual(@as(usize, 1), changes.left.len);
}

test "random source moves keep the counted columns exactly the covered ones" {
    var ticking = try Ticking.init(std.testing.allocator, .{ .sources = 3, .maximum_radius = 8, .forced = 0 });
    defer ticking.deinit(std.testing.allocator);
    var random = std.Random.DefaultPrng.init(0x74696b);
    for (0..500) |_| {
        const slot = random.random().uintLessThan(usize, 3);
        const source: ?Source = if (random.random().uintLessThan(u8, 5) == 0) null else .{
            .world = random.random().uintLessThan(u32, 2),
            .x = random.random().intRangeAtMost(i32, -20, 20),
            .z = random.random().intRangeAtMost(i32, -20, 20),
            .radius = random.random().intRangeAtMost(i32, 1, 8),
        };
        ticking.update(slot, source);
        _ = ticking.drain();
        // Every counted column is covered by an anchor, and every covered column is counted.
        var iterator = ticking.iterator();
        var seen: usize = 0;
        while (iterator.next()) |column| {
            seen += 1;
            var covered = false;
            for (ticking.anchors) |entry| if (entry) |anchor| {
                covered = covered or anchor.covers(column);
            };
            try std.testing.expect(covered);
        }
        try std.testing.expectEqual(ticking.count, seen);
    }
}
