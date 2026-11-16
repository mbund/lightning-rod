//! Mobs by the column of two by two blocks they stand in, for what lies near a box: pushing,
//! waking and kin. A query costs what stands near it, not what stands in its chunk. It only
//! finds candidates, so callers test boxes themselves and put what they keep in vanilla's order
//! with `before`.

const std = @import("std");
const mth = @import("mth.zig");
const Box = @import("body.zig").Box;

const assert = std.debug.assert;

/// Blocks across a cell.
pub const cell_size = 2;
const absent = std.math.maxInt(u32);

pub const Cell = struct { world: u32, x: i32, z: i32 };

pub const Grid = struct {
    /// First mob of each bucket, a chain through `next` and `previous`.
    heads: []u32,
    next: []u32,
    previous: []u32,
    /// The cell each mob is in, by slot.
    cells: []Cell,
    /// Each mob's box as it last stood, so queries test boxes without reading the mobs.
    boxes: []Box,
    placed: []bool,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Grid {
        const buckets = try std.math.ceilPowerOfTwo(usize, capacity * 2);
        const grid: Grid = .{
            .heads = try allocator.alloc(u32, buckets),
            .next = try allocator.alloc(u32, capacity),
            .previous = try allocator.alloc(u32, capacity),
            .cells = try allocator.alloc(Cell, capacity),
            .boxes = try allocator.alloc(Box, capacity),
            .placed = try allocator.alloc(bool, capacity),
        };
        @memset(grid.heads, absent);
        @memset(grid.placed, false);
        return grid;
    }

    pub fn cellOf(world: u32, x: f64, z: f64) Cell {
        return .{ .world = world, .x = @divFloor(mth.floor(x), cell_size), .z = @divFloor(mth.floor(z), cell_size) };
    }

    fn bucket(self: *const Grid, cell: Cell) usize {
        const hash = (@as(u64, @as(u32, @bitCast(cell.x))) *% 0x9e3779b97f4a7c15) ^ (@as(u64, @as(u32, @bitCast(cell.z))) *% 0xc2b2ae3d27d4eb4f) ^ (@as(u64, cell.world) *% 0x165667b19e3779f9);
        return @intCast((hash >> 32) & (self.heads.len - 1));
    }

    /// Puts a mob in the cell of a position, moving it if it was elsewhere.
    pub fn place(self: *Grid, slot: u32, cell: Cell, box: Box) void {
        self.boxes[slot] = box;
        if (self.placed[slot]) {
            if (std.meta.eql(self.cells[slot], cell)) return;
            self.remove(slot);
        }
        const at = self.bucket(cell);
        self.cells[slot] = cell;
        self.placed[slot] = true;
        self.previous[slot] = absent;
        self.next[slot] = self.heads[at];
        if (self.heads[at] != absent) self.previous[self.heads[at]] = slot;
        self.heads[at] = slot;
    }

    pub fn remove(self: *Grid, slot: u32) void {
        if (!self.placed[slot]) return;
        const at = self.bucket(self.cells[slot]);
        if (self.previous[slot] != absent) self.next[self.previous[slot]] = self.next[slot] else self.heads[at] = self.next[slot];
        if (self.next[slot] != absent) self.previous[self.next[slot]] = self.previous[slot];
        self.placed[slot] = false;
    }

    /// The mobs in the cells under a horizontal span, in no order.
    pub fn query(self: *const Grid, world: u32, low: [2]f64, high: [2]f64) Query {
        const first = cellOf(world, low[0], low[1]);
        const last = cellOf(world, high[0], high[1]);
        var result: Query = .{ .grid = self, .world = world, .first = first, .last = last, .x = first.x, .z = first.z, .current = absent };
        result.current = self.heads[self.bucket(.{ .world = world, .x = first.x, .z = first.z })];
        return result;
    }

    pub const Query = struct {
        grid: *const Grid,
        world: u32,
        first: Cell,
        last: Cell,
        x: i32,
        z: i32,
        current: u32,

        pub fn next(self: *Query) ?u32 {
            while (true) {
                while (self.current != absent) {
                    const slot = self.current;
                    self.current = self.grid.next[slot];
                    const cell = self.grid.cells[slot];
                    // Buckets mix cells, so only this cell's mobs count.
                    if (cell.x == self.x and cell.z == self.z and cell.world == self.world) return slot;
                }
                self.z += 1;
                if (self.z > self.last.z) {
                    self.z = self.first.z;
                    self.x += 1;
                    if (self.x > self.last.x) return null;
                }
                self.current = self.grid.heads[self.grid.bucket(.{ .world = self.world, .x = self.x, .z = self.z })];
            }
        }
    };
};

/// Where a mob stands in vanilla's entity sections, and when it came there: the order
/// EntitySectionStorage.getEntities finds entities in. Sections go by x, then by
/// SectionPos.asLong's order within a column, z then y as unsigned bit fields, and entities by
/// when they came into their section.
pub const Arrival = struct {
    section: [3]i32 = .{ 0, 0, 0 },
    stamp: u64 = 0,

    pub fn before(a: Arrival, b: Arrival) bool {
        if (a.section[0] != b.section[0]) return a.section[0] < b.section[0];
        const a_z: u32 = @as(u22, @truncate(@as(u32, @bitCast(a.section[2]))));
        const b_z: u32 = @as(u22, @truncate(@as(u32, @bitCast(b.section[2]))));
        if (a_z != b_z) return a_z < b_z;
        const a_y: u32 = @as(u20, @truncate(@as(u32, @bitCast(a.section[1]))));
        const b_y: u32 = @as(u20, @truncate(@as(u32, @bitCast(b.section[1]))));
        if (a_y != b_y) return a_y < b_y;
        return a.stamp < b.stamp;
    }
};

test "vanilla orders sections by x, then z and y as unsigned fields" {
    const east: Arrival = .{ .section = .{ 1, 4, 0 } };
    const west: Arrival = .{ .section = .{ -1, 4, 0 } };
    try std.testing.expect(Arrival.before(west, east));
    // Within a column, a negative z comes after every positive one.
    const north: Arrival = .{ .section = .{ 0, 4, -1 } };
    const south: Arrival = .{ .section = .{ 0, 4, 5 } };
    try std.testing.expect(Arrival.before(south, north));
    const first: Arrival = .{ .section = .{ 0, 4, 0 }, .stamp = 3 };
    const second: Arrival = .{ .section = .{ 0, 4, 0 }, .stamp = 7 };
    try std.testing.expect(Arrival.before(first, second));
}

test "the grid finds the mobs near a span and nothing farther" {
    var grid = try Grid.init(std.testing.allocator, 8);
    defer {
        std.testing.allocator.free(grid.heads);
        std.testing.allocator.free(grid.next);
        std.testing.allocator.free(grid.previous);
        std.testing.allocator.free(grid.cells);
        std.testing.allocator.free(grid.placed);
        std.testing.allocator.free(grid.boxes);
    }
    grid.place(0, Grid.cellOf(0, 0.5, 0.5), .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } });
    grid.place(1, Grid.cellOf(0, 3.5, 0.5), .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } });
    grid.place(2, Grid.cellOf(0, 40.5, 0.5), .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } });
    grid.place(3, Grid.cellOf(1, 0.5, 0.5), .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } });
    var found: [8]bool = @splat(false);
    var query = grid.query(0, .{ -1, -1 }, .{ 4, 1 });
    while (query.next()) |slot| found[slot] = true;
    try std.testing.expect(found[0] and found[1] and !found[2] and !found[3]);
    grid.place(1, Grid.cellOf(0, 41.5, 0.5), .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 1, 1 } });
    grid.remove(0);
    found = @splat(false);
    query = grid.query(0, .{ -1, -1 }, .{ 4, 1 });
    while (query.next()) |slot| found[slot] = true;
    try std.testing.expect(!found[0] and !found[1]);
}
