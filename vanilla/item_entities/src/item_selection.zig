//! Which items a set of bounds holds: those whose places, as the space keeps them, lie within
//! any bound of their world, edges included.

const std = @import("std");
const entities = @import("entities");

const assert = std.debug.assert;

pub const Selection = struct {
    pub const Bounds = struct {
        world: u32,
        minimum: [2]f64,
        maximum: [2]f64,

        fn less(_: void, a: Bounds, b: Bounds) bool {
            if (a.world != b.world) return a.world < b.world;
            for ([_]f64{ a.minimum[1], a.maximum[1], a.minimum[0], a.maximum[0] }, [_]f64{ b.minimum[1], b.maximum[1], b.minimum[0], b.maximum[0] }) |left, right| {
                if (left != right) return left < right;
            }
            return false;
        }

        fn holds(self: Bounds, point: [3]f64) bool {
            return point[0] >= self.minimum[0] and point[0] <= self.maximum[0] and point[2] >= self.minimum[1] and point[2] <= self.maximum[1];
        }
    };
    pub const Work = struct { candidates: usize = 0, matches: usize = 0, coverage_nodes: usize = 0 };

    bounds: []Bounds,
    count: usize = 0,
    /// Columns some bound touches, each looked over once against every bound.
    columns: std.AutoArrayHashMapUnmanaged(entities.Column, void) = .empty,
    const column_capacity = 4096;

    pub fn init(allocator: std.mem.Allocator, regions: usize) !Selection {
        assert(regions > 0);
        var self: Selection = .{ .bounds = try allocator.alloc(Bounds, regions) };
        try self.columns.ensureTotalCapacity(allocator, column_capacity);
        return self;
    }

    pub fn append(self: *Selection, world: u32, minimum: [2]f64, maximum: [2]f64) void {
        assert(self.count < self.bounds.len);
        for (minimum, maximum) |low, high| {
            assert(std.math.isFinite(low) and std.math.isFinite(high) and low <= high);
            assert(@floor(low / 16) >= std.math.minInt(i32) and @floor(high / 16) <= std.math.maxInt(i32));
        }
        self.bounds[self.count] = .{ .world = world, .minimum = minimum, .maximum = maximum };
        self.count += 1;
    }

    /// Puts the items within the bounds into `output`: the columns the bounds touch, each looked
    /// over once, as many at a time as there is room for.
    pub fn select(self: *Selection, area: *const entities.Space, kinds: entities.Kinds, output: *entities.IdSet) !Work {
        defer self.count = 0;
        var work: Work = .{};
        std.mem.sort(Bounds, self.bounds[0..self.count], {}, Bounds.less);
        var unique: usize = 0;
        for (self.bounds[0..self.count]) |bound| {
            if (unique != 0 and std.meta.eql(self.bounds[unique - 1], bound)) continue;
            self.bounds[unique] = bound;
            unique += 1;
        }
        const bounds = self.bounds[0..unique];
        if (self.columns.count() != 0) self.columns.clearRetainingCapacity();
        for (bounds) |bound| {
            const low = lowColumn(bound);
            const high = highColumn(bound);
            var x = low[0];
            while (x <= high[0]) : (x += 1) {
                var z = low[1];
                while (z <= high[1]) : (z += 1) {
                    if (self.columns.count() == column_capacity) try self.lookOver(area, kinds, bounds, output, &work);
                    self.columns.putAssumeCapacity(.{ .world = bound.world, .x = x, .z = z }, {});
                    if (z == std.math.maxInt(i32)) break;
                }
                if (x == std.math.maxInt(i32)) break;
            }
        }
        try self.lookOver(area, kinds, bounds, output, &work);
        return work;
    }

    fn lowColumn(bound: Bounds) [2]i32 {
        return .{ @intFromFloat(@floor(bound.minimum[0] / 16)), @intFromFloat(@floor(bound.minimum[1] / 16)) };
    }

    fn highColumn(bound: Bounds) [2]i32 {
        return .{ @intFromFloat(@floor(bound.maximum[0] / 16)), @intFromFloat(@floor(bound.maximum[1] / 16)) };
    }

    /// Looks over the gathered columns: an item is in when a bound touching its column holds it.
    fn lookOver(self: *Selection, area: *const entities.Space, kinds: entities.Kinds, bounds: []const Bounds, output: *entities.IdSet, work: *Work) !void {
        defer if (self.columns.count() != 0) self.columns.clearRetainingCapacity();
        for (self.columns.keys()) |column| {
            if (area.countIn(column) == 0) continue;
            var entries = area.entries(column, kinds);
            var touching: [256]usize = undefined;
            var touching_count: usize = 0;
            for (bounds, 0..) |bound, at| {
                const low = lowColumn(bound);
                const high = highColumn(bound);
                if (bound.world != column.world or column.x < low[0] or column.x > high[0] or column.z < low[1] or column.z > high[1]) continue;
                if (touching_count == touching.len) break;
                touching[touching_count] = at;
                touching_count += 1;
            }
            while (entries.next()) |entry| {
                work.candidates += 1;
                // More bounds touch it than are kept: look at every one.
                const held = for (touching[0..touching_count]) |at| {
                    if (bounds[at].holds(entry.position)) break true;
                } else if (touching_count == touching.len) for (bounds) |bound| {
                    if (bound.world == column.world and bound.holds(entry.position)) break true;
                } else false else false;
                if (!held) continue;
                output.insert(entry.id);
                work.matches += 1;
            }
        }
    }
};
