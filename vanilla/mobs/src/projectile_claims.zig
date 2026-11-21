//! Claims: the space sleeping projectiles will pass through until they wake, so whatever enters
//! it, an entity or a block edit, can wake them first, and the tick each wakes on.
//!
//! A claim is a box, kept in the 64 block columns it reaches, at most two by two of them, and in
//! the bucket of a wheel for its tick. The pool and the buckets are fixed at startup: with no
//! room, a projectile simply stays awake. Claims live in memory only; a restart wakes everyone.

const std = @import("std");

const assert = std.debug.assert;

pub const cell_shift = 6;
/// Columns of cells a claim may reach on each axis.
pub const span_max = 2;
/// Ticks the wheel tells apart; no one sleeps this long.
pub const wheel_ticks = 32;
const links_per_claim = span_max * span_max;
pub const none = std.math.maxInt(u32);

pub const Box = struct { low: [3]f64, high: [3]f64 };

const Cell = struct { world: u32, x: i32, z: i32 };

const Claim = struct {
    id: u64 = 0,
    world: u32 = 0,
    wake_at: u64 = 0,
    box: Box = undefined,
    cells: [links_per_claim]Cell = undefined,
    cell_count: u8 = 0,
    used: bool = false,
    wheel_next: u32 = none,
    wheel_previous: u32 = none,
};

pub const Claims = struct {
    claims: []Claim,
    free: []u32,
    free_count: usize,
    /// Per link (claim * 4 + its cell), the next and previous link in its bucket.
    next: []u32,
    previous: []u32,
    buckets: []u32,
    wheel: [wheel_ticks]u32 = @splat(none),
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Claims {
        if (capacity == 0 or capacity >= none / links_per_claim) return error.InvalidConfiguration;
        const claims = try allocator.alloc(Claim, capacity);
        @memset(claims, .{});
        const free = try allocator.alloc(u32, capacity);
        for (free, 0..) |*slot, index| slot.* = @intCast(capacity - 1 - index);
        const next = try allocator.alloc(u32, capacity * links_per_claim);
        const previous = try allocator.alloc(u32, capacity * links_per_claim);
        const buckets = try allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, capacity * links_per_claim));
        @memset(buckets, none);
        return .{ .claims = claims, .free = free, .free_count = capacity, .next = next, .previous = previous, .buckets = buckets };
    }

    fn bucket(self: *const Claims, cell: Cell) usize {
        var hasher = std.hash.Wyhash.init(0x636c61696d73);
        std.hash.autoHash(&hasher, cell);
        return @as(usize, @truncate(hasher.final())) & (self.buckets.len - 1);
    }

    fn cellRange(low: f64, high: f64) ?[2]i32 {
        if (!std.math.isFinite(low) or !std.math.isFinite(high) or @abs(low) > 3e7 or @abs(high) > 3e7) return null;
        return .{ @as(i32, @intFromFloat(@floor(low))) >> cell_shift, @as(i32, @intFromFloat(@floor(high))) >> cell_shift };
    }

    /// Claims a box until a tick for a projectile, or returns null when the pool is full or the
    /// box reaches too far for one claim.
    pub fn add(self: *Claims, id: u64, world: u32, box: Box, now: u64, wake_at: u64) ?u32 {
        assert(wake_at > now and wake_at - now < wheel_ticks);
        const xs = cellRange(box.low[0], box.high[0]) orelse return null;
        const zs = cellRange(box.low[2], box.high[2]) orelse return null;
        if (xs[1] - xs[0] >= span_max or zs[1] - zs[0] >= span_max or self.free_count == 0) return null;
        self.free_count -= 1;
        const index = self.free[self.free_count];
        const claim = &self.claims[index];
        assert(!claim.used);
        claim.* = .{ .id = id, .world = world, .wake_at = wake_at, .box = box, .used = true };
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                const cell: Cell = .{ .world = world, .x = x, .z = z };
                const link = index * links_per_claim + claim.cell_count;
                claim.cells[claim.cell_count] = cell;
                claim.cell_count += 1;
                const head = &self.buckets[self.bucket(cell)];
                self.next[link] = head.*;
                self.previous[link] = none;
                if (head.* != none) self.previous[head.*] = link;
                head.* = link;
            }
        }
        const turn = &self.wheel[wake_at % wheel_ticks];
        claim.wheel_next = turn.*;
        if (turn.* != none) self.claims[turn.*].wheel_previous = index;
        turn.* = index;
        self.count += 1;
        return index;
    }

    pub fn used(self: *const Claims, index: u32) bool {
        return self.claims[index].used;
    }

    /// Lets a claim go and gives back whose it was.
    pub fn remove(self: *Claims, index: u32) u64 {
        const claim = &self.claims[index];
        assert(claim.used);
        for (claim.cells[0..claim.cell_count], 0..) |cell, at| {
            const link: u32 = @intCast(index * links_per_claim + at);
            if (self.previous[link] != none) self.next[self.previous[link]] = self.next[link] else self.buckets[self.bucket(cell)] = self.next[link];
            if (self.next[link] != none) self.previous[self.next[link]] = self.previous[link];
        }
        if (claim.wheel_previous != none) self.claims[claim.wheel_previous].wheel_next = claim.wheel_next else self.wheel[claim.wake_at % wheel_ticks] = claim.wheel_next;
        if (claim.wheel_next != none) self.claims[claim.wheel_next].wheel_previous = claim.wheel_previous;
        claim.used = false;
        self.free[self.free_count] = index;
        self.free_count += 1;
        self.count -= 1;
        return claim.id;
    }

    /// The claims due on a tick, taken, their projectiles written to `output`.
    pub fn takeDue(self: *Claims, now: u64, output: []u64, found: *usize) void {
        var index = self.wheel[now % wheel_ticks];
        while (index != none) {
            const claim = &self.claims[index];
            const following = claim.wheel_next;
            assert(claim.used and claim.wake_at >= now);
            if (claim.wake_at == now) {
                assert(found.* < output.len);
                output[found.*] = self.remove(index);
                found.* += 1;
            }
            index = following;
        }
    }

    /// The claims a box meets, horizontally grown by `reach`, written to `output`; one may come
    /// more than once. Returns false when `output` ran out, and the caller must treat every claim
    /// as met.
    pub fn meeting(self: *const Claims, world: u32, box: Box, reach: f64, output: []u32, found: *usize) bool {
        if (self.count == 0) return true;
        const low_x = box.low[0] - reach;
        const high_x = box.high[0] + reach;
        const low_z = box.low[2] - reach;
        const high_z = box.high[2] + reach;
        const xs = cellRange(low_x, high_x) orelse return false;
        const zs = cellRange(low_z, high_z) orelse return false;
        var x = xs[0];
        while (x <= xs[1]) : (x += 1) {
            var z = zs[0];
            while (z <= zs[1]) : (z += 1) {
                const cell: Cell = .{ .world = world, .x = x, .z = z };
                var link = self.buckets[self.bucket(cell)];
                while (link != none) : (link = self.next[link]) {
                    const claim = &self.claims[link / links_per_claim];
                    if (!std.meta.eql(claim.cells[link % links_per_claim], cell)) continue;
                    const c = claim.box;
                    if (c.low[0] > high_x or c.high[0] < low_x or c.low[2] > high_z or c.high[2] < low_z) continue;
                    if (c.low[1] > box.high[1] or c.high[1] < box.low[1]) continue;
                    if (found.* == output.len) return false;
                    output[found.*] = link / links_per_claim;
                    found.* += 1;
                }
            }
        }
        return true;
    }
};

test "claims are found by the boxes that meet them and by their tick, and leave when taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var claims = try Claims.init(arena.allocator(), 4);
    const a = claims.add(7, 0, .{ .low = .{ 60, 70, 10 }, .high = .{ 70, 90, 20 } }, 100, 105).?;
    _ = claims.add(8, 0, .{ .low = .{ 300, 70, 10 }, .high = .{ 310, 90, 20 } }, 100, 110).?;
    try std.testing.expect(claims.add(9, 0, .{ .low = .{ 0, 0, 0 }, .high = .{ 200, 1, 1 } }, 100, 101) == null);
    var output: [8]u32 = undefined;
    var found: usize = 0;
    try std.testing.expect(claims.meeting(0, .{ .low = .{ 65, 80, 15 }, .high = .{ 66, 81, 16 } }, 0, &output, &found));
    try std.testing.expectEqualSlices(u32, &.{a}, output[0..found]);
    found = 0;
    try std.testing.expect(claims.meeting(0, .{ .low = .{ 65, 200, 15 }, .high = .{ 66, 201, 16 } }, 0, &output, &found));
    try std.testing.expectEqual(@as(usize, 0), found);
    found = 0;
    try std.testing.expect(claims.meeting(1, .{ .low = .{ 65, 80, 15 }, .high = .{ 66, 81, 16 } }, 0, &output, &found));
    try std.testing.expectEqual(@as(usize, 0), found);
    var ids: [4]u64 = undefined;
    var due: usize = 0;
    claims.takeDue(104, &ids, &due);
    try std.testing.expectEqual(@as(usize, 0), due);
    claims.takeDue(105, &ids, &due);
    try std.testing.expectEqualSlices(u64, &.{7}, ids[0..due]);
    try std.testing.expect(!claims.used(a));
    try std.testing.expectEqual(@as(u64, 8), claims.remove(claims.wheel[110 % wheel_ticks]));
    try std.testing.expectEqual(@as(usize, 0), claims.count);
}
