//! Sweeps: boxes entities stay in until a tick, for kinds that do not keep their place in the
//! space every tick, as a sleeping arrow passes along a path it planned. While swept, an entity is
//! wherever its box says: whatever enters the box, an entity or a block edit, can wake it first,
//! and tracking answers for every player by the box, asking the kind where the entity is only
//! where the box leaves it unsure. At its tick the kind places it again.
//!
//! A sweep is kept in the 64 block cells it reaches, at most two by two of them, and in the
//! bucket of a wheel for its tick. The pool and the buckets are fixed at startup: with no room an
//! entity is simply not swept and keeps its place. Sweeps live in memory only.

const std = @import("std");
const space_module = @import("space.zig");

const Space = space_module.Space;
const assert = std.debug.assert;

pub const cell_shift = 6;
/// Columns of cells a sweep may reach on each axis.
pub const span_max = 2;
/// Ticks the wheel tells apart; no sweep is longer.
pub const wheel_ticks = 32;
const links_per_sweep = span_max * span_max;
pub const none = std.math.maxInt(u32);

pub const Box = struct {
    low: [3]f64,
    high: [3]f64,

    pub fn contains(self: Box, point: [3]f64) bool {
        for (0..3) |axis| if (point[axis] < self.low[axis] or point[axis] > self.high[axis]) return false;
        return true;
    }
};

const Cell = struct { world: u32, x: i32, z: i32 };

pub const Sweep = struct {
    slot: u32 = 0,
    world: u32 = 0,
    until: u64 = 0,
    /// Where the entity's feet may be until then, and the entity's own half width and height,
    /// so its box anywhere along is the feet's box grown by them.
    box: Box = undefined,
    half_width: f32 = 0,
    height: f32 = 0,
    cells: [links_per_sweep]Cell = undefined,
    cell_count: u8 = 0,
    used: bool = false,
    wheel_next: u32 = none,
    wheel_previous: u32 = none,

    /// The entity's box anywhere along.
    pub fn reach(self: *const Sweep) Box {
        const half: f64 = self.half_width;
        return .{
            .low = .{ self.box.low[0] - half, self.box.low[1], self.box.low[2] - half },
            .high = .{ self.box.high[0] + half, self.box.high[1] + self.height, self.box.high[2] + half },
        };
    }
};

pub const Sweeps = struct {
    sweeps: []Sweep,
    free: []u32,
    free_count: usize,
    /// Per link (sweep * 4 + its cell), the next and previous link in its bucket.
    next: []u32,
    previous: []u32,
    buckets: []u32,
    wheel: [wheel_ticks]u32 = @splat(none),
    count: usize = 0,
    /// Each directory slot's sweep, or none.
    of_slot: []u32,
    /// Where tracking hears of sweeps placed and taken back.
    space: *Space,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, slots: usize, space: *Space) !Sweeps {
        if (capacity == 0 or capacity >= none / links_per_sweep) return error.InvalidConfiguration;
        const sweeps = try allocator.alloc(Sweep, capacity);
        @memset(sweeps, .{});
        const free = try allocator.alloc(u32, capacity);
        for (free, 0..) |*slot, index| slot.* = @intCast(capacity - 1 - index);
        const next = try allocator.alloc(u32, capacity * links_per_sweep);
        const previous = try allocator.alloc(u32, capacity * links_per_sweep);
        const buckets = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, capacity * links_per_sweep));
        @memset(buckets, none);
        const of_slot = try allocator.alloc(u32, slots);
        @memset(of_slot, none);
        return .{ .sweeps = sweeps, .free = free, .free_count = capacity, .next = next, .previous = previous, .buckets = buckets, .of_slot = of_slot, .space = space };
    }

    fn bucket(self: *const Sweeps, cell: Cell) usize {
        // A multiply and a fold: cells are small integers, hashed twice for every sweep.
        const x: u64 = @as(u32, @bitCast(cell.x));
        const z: u64 = @as(u32, @bitCast(cell.z));
        const mixed = ((x << 32) | z) *% 0x9e3779b97f4a7c15 ^ @as(u64, cell.world) *% 0xc2b2ae3d27d4eb4f;
        return @as(usize, @truncate(mixed ^ (mixed >> 29))) & (self.buckets.len - 1);
    }

    fn cellRange(low: f64, high: f64) ?[2]i32 {
        if (!std.math.isFinite(low) or !std.math.isFinite(high) or @abs(low) > 3e7 or @abs(high) > 3e7) return null;
        return .{ @as(i32, @intFromFloat(@floor(low))) >> cell_shift, @as(i32, @intFromFloat(@floor(high))) >> cell_shift };
    }

    /// Whether a box is small enough to sweep.
    pub fn fits(box: Box) bool {
        const xs = cellRange(box.low[0], box.high[0]) orelse return false;
        const zs = cellRange(box.low[2], box.high[2]) orelse return false;
        return xs[1] - xs[0] < span_max and zs[1] - zs[0] < span_max;
    }

    /// Sweeps an entity: its feet stay in `box` until `until`, when it must be placed again. Null
    /// when the pool is full or the box reaches too far, and the entity keeps its place.
    pub fn place(self: *Sweeps, slot: u32, world: u32, box: Box, half_width: f32, height: f32, now: u64, until: u64) ?u32 {
        assert(until > now and until - now < wheel_ticks);
        assert(self.of_slot[slot] == none);
        const xs = cellRange(box.low[0], box.high[0]) orelse return null;
        const zs = cellRange(box.low[2], box.high[2]) orelse return null;
        if (xs[1] - xs[0] >= span_max or zs[1] - zs[0] >= span_max or self.free_count == 0) return null;
        self.free_count -= 1;
        const index = self.free[self.free_count];
        const sweep = &self.sweeps[index];
        assert(!sweep.used);
        sweep.* = .{ .slot = slot, .world = world, .until = until, .box = box, .half_width = half_width, .height = height, .used = true };
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                const cell: Cell = .{ .world = world, .x = x, .z = z };
                const link = index * links_per_sweep + sweep.cell_count;
                sweep.cells[sweep.cell_count] = cell;
                sweep.cell_count += 1;
                const head = &self.buckets[self.bucket(cell)];
                self.next[link] = head.*;
                self.previous[link] = none;
                if (head.* != none) self.previous[head.*] = link;
                head.* = link;
            }
        }
        const turn = &self.wheel[until % wheel_ticks];
        sweep.wheel_next = turn.*;
        if (turn.* != none) self.sweeps[turn.*].wheel_previous = index;
        turn.* = index;
        self.count += 1;
        self.of_slot[slot] = index;
        self.space.note(slot, .swept);
        return index;
    }

    /// The sweep of the entity in a slot, if it is swept.
    pub fn of(self: *const Sweeps, slot: u32) ?*const Sweep {
        if (slot >= self.of_slot.len) return null;
        const index = self.of_slot[slot];
        return if (index == none) null else &self.sweeps[index];
    }

    /// Lets every sweep go.
    pub fn clear(self: *Sweeps) void {
        for (0..self.sweeps.len) |index| if (self.used(@intCast(index))) {
            _ = self.remove(@intCast(index));
        };
    }

    pub fn used(self: *const Sweeps, index: u32) bool {
        return self.sweeps[index].used;
    }

    pub fn at(self: *const Sweeps, index: u32) *const Sweep {
        return &self.sweeps[index];
    }

    /// Lets a sweep go and gives back whose it was. The kind places the entity again, or it is
    /// gone.
    pub fn remove(self: *Sweeps, index: u32) u32 {
        const sweep = &self.sweeps[index];
        assert(sweep.used);
        for (sweep.cells[0..sweep.cell_count], 0..) |cell, link_at| {
            const link: u32 = @intCast(index * links_per_sweep + link_at);
            if (self.previous[link] != none) self.next[self.previous[link]] = self.next[link] else self.buckets[self.bucket(cell)] = self.next[link];
            if (self.next[link] != none) self.previous[self.next[link]] = self.previous[link];
        }
        if (sweep.wheel_previous != none) self.sweeps[sweep.wheel_previous].wheel_next = sweep.wheel_next else self.wheel[sweep.until % wheel_ticks] = sweep.wheel_next;
        if (sweep.wheel_next != none) self.sweeps[sweep.wheel_next].wheel_previous = sweep.wheel_previous;
        sweep.used = false;
        self.free[self.free_count] = index;
        self.free_count += 1;
        self.count -= 1;
        self.of_slot[sweep.slot] = none;
        self.space.note(sweep.slot, .swept);
        return sweep.slot;
    }

    /// The sweep of a slot let go, if it has one.
    pub fn removeSlot(self: *Sweeps, slot: u32) bool {
        const index = self.of_slot[slot];
        if (index == none) return false;
        _ = self.remove(index);
        return true;
    }

    /// The sweeps due on a tick, taken, their slots written to `output`.
    pub fn takeDue(self: *Sweeps, now: u64, output: []u32, found: *usize) void {
        var index = self.wheel[now % wheel_ticks];
        while (index != none) {
            const sweep = &self.sweeps[index];
            const following = sweep.wheel_next;
            assert(sweep.used and sweep.until >= now);
            if (sweep.until == now) {
                assert(found.* < output.len);
                output[found.*] = self.remove(index);
                found.* += 1;
            }
            index = following;
        }
    }

    /// Whether some sweep is overdue: none must be, as kinds place their entities again on time.
    pub fn overdue(self: *const Sweeps, now: u64) bool {
        for (self.wheel) |head| {
            var index = head;
            while (index != none) : (index = self.sweeps[index].wheel_next) {
                if (self.sweeps[index].until < now) return true;
            }
        }
        return false;
    }

    /// The sweeps whose entity's box a box meets, horizontally grown by `reach`, written to
    /// `output`; one may come more than once. Returns false when `output` ran out, and the caller
    /// must treat every sweep as met.
    pub fn meeting(self: *const Sweeps, world: u32, box: Box, reach: f64, output: []u32, found: *usize) bool {
        if (self.count == 0) return true;
        return self.each(world, box, reach, struct {
            output: []u32,
            found: *usize,
            fn visit(context: @This(), index: u32) bool {
                if (context.found.* == context.output.len) return false;
                context.output[context.found.*] = index;
                context.found.* += 1;
                return true;
            }
        }{ .output = output, .found = found }, true);
    }

    /// Visits each sweep whose entity's box meets a box grown by `reach`, horizontally, and also
    /// vertically when `vertical`; `visit` returning false stops the walk, which returns false.
    pub fn each(self: *const Sweeps, world: u32, box: Box, reach: f64, context: anytype, vertical: bool) bool {
        if (self.count == 0) return true;
        // Grown by the widest entity a cell can hold, which a sweep's own box adds.
        const low_x = box.low[0] - reach;
        const high_x = box.high[0] + reach;
        const low_z = box.low[2] - reach;
        const high_z = box.high[2] + reach;
        const xs = cellRange(low_x - 8, high_x + 8) orelse return false;
        const zs = cellRange(low_z - 8, high_z + 8) orelse return false;
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                const cell: Cell = .{ .world = world, .x = x, .z = z };
                var link = self.buckets[self.bucket(cell)];
                while (link != none) : (link = self.next[link]) {
                    const index = link / links_per_sweep;
                    const sweep = &self.sweeps[index];
                    if (!std.meta.eql(sweep.cells[link % links_per_sweep], cell)) continue;
                    // Found once: in the first of its cells the walk meets.
                    if (!firstMet(sweep, xs, zs, link % links_per_sweep)) continue;
                    const c = sweep.reach();
                    if (c.low[0] > high_x or c.high[0] < low_x or c.low[2] > high_z or c.high[2] < low_z) continue;
                    if (vertical and (c.low[1] > box.high[1] or c.high[1] < box.low[1])) continue;
                    if (!context.visit(index)) return false;
                }
            }
        }
        return true;
    }

    /// Whether a sweep's cell at `link_at` is the first of its cells within the walked cells, as
    /// the walk goes, so each sweep is visited once.
    fn firstMet(sweep: *const Sweep, xs: [2]i32, zs: [2]i32, link_at: usize) bool {
        for (sweep.cells[0..link_at]) |cell| {
            if (cell.x >= xs[0] and cell.x <= xs[1] and cell.z >= zs[0] and cell.z <= zs[1]) return false;
        }
        return true;
    }
};

test "sweeps are found by the boxes that meet them and by their tick, and leave when taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var space: Space = undefined;
    space.logging = false;
    var sweeps = try Sweeps.init(arena.allocator(), 4, 16, &space);
    const a = sweeps.place(7, 0, .{ .low = .{ 60, 70, 10 }, .high = .{ 70, 90, 20 } }, 0.25, 0.5, 100, 105).?;
    _ = sweeps.place(8, 0, .{ .low = .{ 300, 70, 10 }, .high = .{ 310, 90, 20 } }, 0.25, 0.5, 100, 110).?;
    try std.testing.expect(sweeps.place(9, 0, .{ .low = .{ 0, 0, 0 }, .high = .{ 200, 1, 1 } }, 0.25, 0.5, 100, 101) == null);
    try std.testing.expectEqual(a, sweeps.of_slot[7]);
    var output: [8]u32 = undefined;
    var found: usize = 0;
    try std.testing.expect(sweeps.meeting(0, .{ .low = .{ 65, 80, 15 }, .high = .{ 66, 81, 16 } }, 0, &output, &found));
    try std.testing.expectEqualSlices(u32, &.{a}, output[0..found]);
    found = 0;
    try std.testing.expect(sweeps.meeting(0, .{ .low = .{ 65, 200, 15 }, .high = .{ 66, 201, 16 } }, 0, &output, &found));
    try std.testing.expectEqual(@as(usize, 0), found);
    found = 0;
    try std.testing.expect(sweeps.meeting(1, .{ .low = .{ 65, 80, 15 }, .high = .{ 66, 81, 16 } }, 0, &output, &found));
    try std.testing.expectEqual(@as(usize, 0), found);
    var slots: [4]u32 = undefined;
    var due: usize = 0;
    sweeps.takeDue(104, &slots, &due);
    try std.testing.expectEqual(@as(usize, 0), due);
    sweeps.takeDue(105, &slots, &due);
    try std.testing.expectEqualSlices(u32, &.{7}, slots[0..due]);
    try std.testing.expect(sweeps.of(7) == null);
    try std.testing.expect(sweeps.removeSlot(8));
    try std.testing.expectEqual(@as(usize, 0), sweeps.count);
}
