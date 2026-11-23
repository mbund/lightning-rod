//! Entities due at a tick, soonest first: what wakes sleepers when their time comes. Room is
//! fixed when made. An entity rescheduled or woken early leaves its old entry behind, which the
//! owner tells apart when it comes up, and which a full schedule drops to make room.

const std = @import("std");

const assert = std.debug.assert;

pub const Id = u64;

pub const Due = struct { tick: u64, id: Id };

pub const Schedule = struct {
    heap: []Due,
    len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Schedule {
        assert(capacity > 0);
        return .{ .heap = try allocator.alloc(Due, capacity) };
    }

    pub fn count(self: *const Schedule) usize {
        return self.len;
    }

    /// `current` tells whether an entry still stands, for dropping those that do not when full.
    pub fn push(self: *Schedule, due: Due, context: anytype, comptime current: fn (@TypeOf(context), Due) bool) !void {
        if (self.len == self.heap.len) {
            self.drop(context, current);
            if (self.len == self.heap.len) return error.ScheduleFull;
        }
        self.heap[self.len] = due;
        self.len += 1;
        self.up(self.len - 1);
    }

    /// The next entry due at or before `tick`, soonest first.
    pub fn pop(self: *Schedule, tick: u64) ?Due {
        if (self.len == 0 or self.heap[0].tick > tick) return null;
        const first = self.heap[0];
        self.len -= 1;
        if (self.len > 0) {
            self.heap[0] = self.heap[self.len];
            self.down(0);
        }
        return first;
    }

    fn drop(self: *Schedule, context: anytype, comptime current: fn (@TypeOf(context), Due) bool) void {
        var kept: usize = 0;
        for (self.heap[0..self.len]) |due| {
            if (!current(context, due)) continue;
            self.heap[kept] = due;
            kept += 1;
        }
        self.len = kept;
        var at = self.len / 2;
        while (at > 0) {
            at -= 1;
            self.down(at);
        }
    }

    fn less(a: Due, b: Due) bool {
        if (a.tick != b.tick) return a.tick < b.tick;
        return a.id < b.id;
    }

    fn up(self: *Schedule, start: usize) void {
        var at = start;
        while (at > 0) {
            const parent = (at - 1) / 2;
            if (!less(self.heap[at], self.heap[parent])) return;
            std.mem.swap(Due, &self.heap[at], &self.heap[parent]);
            at = parent;
        }
    }

    fn down(self: *Schedule, start: usize) void {
        var at = start;
        while (true) {
            var least = at;
            for ([_]usize{ 2 * at + 1, 2 * at + 2 }) |child| if (child < self.len and less(self.heap[child], self.heap[least])) {
                least = child;
            };
            if (least == at) return;
            std.mem.swap(Due, &self.heap[at], &self.heap[least]);
            at = least;
        }
    }
};

test "entries come due soonest first, and a full schedule drops what no longer stands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var schedule = try Schedule.init(arena.allocator(), 4);
    const all = struct {
        fn current(_: void, _: Due) bool {
            return true;
        }
        fn even(_: void, due: Due) bool {
            return due.id % 2 == 0;
        }
    };
    for ([_]u64{ 40, 10, 30, 20 }, 1..) |tick, entity| try schedule.push(.{ .tick = tick, .id = entity }, {}, all.current);
    try std.testing.expectError(error.ScheduleFull, schedule.push(.{ .tick = 5, .id = 9 }, {}, all.current));
    try std.testing.expectEqual(@as(?Due, null), schedule.pop(9));
    try std.testing.expectEqual(@as(Id, 2), schedule.pop(25).?.id);
    try std.testing.expectEqual(@as(Id, 4), schedule.pop(25).?.id);
    try std.testing.expectEqual(@as(?Due, null), schedule.pop(25));
    try schedule.push(.{ .tick = 1, .id = 6 }, {}, all.current);
    try schedule.push(.{ .tick = 2, .id = 7 }, {}, all.current);
    // Full again: the odd ones no longer stand, and go.
    try schedule.push(.{ .tick = 3, .id = 8 }, {}, all.even);
    try std.testing.expectEqual(@as(Id, 6), schedule.pop(100).?.id);
    try std.testing.expectEqual(@as(Id, 8), schedule.pop(100).?.id);
    try std.testing.expectEqual(@as(?Due, null), schedule.pop(100));
}
