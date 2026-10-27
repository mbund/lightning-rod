const std = @import("std");
const lightning_rod = @import("lightning_rod");
const spatial = @import("item_spatial.zig");

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
    };
    pub const Work = struct { candidates: usize = 0, matches: usize = 0, coverage_nodes: usize = 0 };
    const Edge = struct {
        x: f64,
        region: usize,
        start: bool,

        fn less(_: void, a: Edge, b: Edge) bool {
            return a.x < b.x or (a.x == b.x and a.start and !b.start);
        }
    };

    bounds: []Bounds,
    count: usize = 0,
    edges: []Edge,
    coordinates: []f64,
    coverage: []usize,
    candidates: []u32,
    active: lightning_rod.system.sparse_sets.Workspace,

    pub fn init(allocator: std.mem.Allocator, regions: usize, residents: usize) !Selection {
        assert(regions > 0 and residents > 0);
        return .{
            .active = try lightning_rod.system.sparse_sets.Workspace.init(allocator, 1, regions),
            .bounds = try allocator.alloc(Bounds, regions),
            .edges = try allocator.alloc(Edge, regions * 2),
            .coordinates = try allocator.alloc(f64, regions * 2),
            .coverage = try allocator.alloc(usize, (try std.math.ceilPowerOfTwo(usize, regions * 4)) * 2),
            .candidates = try allocator.alloc(u32, residents),
        };
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

    /// Index keys and exact positions remain stable until selection returns.
    pub fn select(self: *Selection, index: *const spatial.Index, output: *lightning_rod.system.IndexSet) Work {
        assert(self.candidates.len == index.residents.len and output.positions.len == index.residents.len);
        defer self.count = 0;
        var work: Work = .{};
        std.mem.sort(Bounds, self.bounds[0..self.count], {}, Bounds.less);
        var unique_bounds: usize = 0;
        for (self.bounds[0..self.count]) |area| {
            if (unique_bounds != 0 and std.meta.eql(self.bounds[unique_bounds - 1], area)) continue;
            self.bounds[unique_bounds] = area;
            unique_bounds += 1;
        }
        self.count = unique_bounds;
        var begin: usize = 0;
        while (begin < self.count) {
            var end = begin + 1;
            while (end < self.count and self.bounds[end].world == self.bounds[begin].world) end += 1;
            const group = self.bounds[begin..end];
            const world = group[0].world;
            const edges = self.edges[0 .. group.len * 2];
            for (group, 0..) |area, at| {
                edges[at * 2] = .{ .x = @floor(area.minimum[0] / 16), .region = @intCast(at), .start = true };
                edges[at * 2 + 1] = .{ .x = @floor(area.maximum[0] / 16) + 1, .region = @intCast(at), .start = false };
            }
            std.mem.sort(Edge, edges, {}, Edge.less);
            const active = self.active.row(0);
            active.clear();
            var cursor: usize = 0;
            var count: usize = 0;
            while (cursor < edges.len) {
                const left = edges[cursor].x;
                while (cursor < edges.len and edges[cursor].x == left) : (cursor += 1)
                    active.toggle(edges[cursor].region);
                if (cursor == edges.len) break;
                const right = edges[cursor].x;
                assert(left < right);
                var remaining = active.view().iterator();
                var interval: ?[2]i32 = null;
                var envelope: Bounds = undefined;
                while (true) {
                    var area: Bounds = undefined;
                    const next: ?[2]i32 = if (remaining.next()) |at| range: {
                        area = group[at];
                        break :range .{ @intFromFloat(@floor(group[at].minimum[1] / 16)), @intFromFloat(@floor(group[at].maximum[1] / 16)) };
                    } else null;
                    if (interval) |*previous| {
                        if (next) |range| if (@as(i64, range[0]) <= @as(i64, previous[1]) + 1) {
                            previous[1] = @max(previous[1], range[1]);
                            for (0..2) |axis| {
                                envelope.minimum[axis] = @min(envelope.minimum[axis], area.minimum[axis]);
                                envelope.maximum[axis] = @max(envelope.maximum[axis], area.maximum[axis]);
                            }
                            continue;
                        };
                        var selected = index.rectangle(world, .{ @intFromFloat(left), previous[0] }, .{ @intFromFloat(right - 1), previous[1] });
                        while (selected.next()) |slot| {
                            work.candidates += 1;
                            const point = index.residents[slot].position;
                            if (point[0] < envelope.minimum[0] or point[0] > envelope.maximum[0] or point[1] < envelope.minimum[1] or point[1] > envelope.maximum[1]) continue;
                            assert(count < self.candidates.len);
                            self.candidates[count] = slot;
                            count += 1;
                        }
                    }
                    interval = next;
                    if (next != null) envelope = area;
                    if (next == null) break;
                }
            }
            assert(!active.view().any());
            if (count != 0) {
                const candidates = self.candidates[0..count];
                std.mem.sort(u32, candidates, index.residents, struct {
                    fn less(residents: []const spatial.Resident, a: u32, b: u32) bool {
                        return residents[a].position[0] < residents[b].position[0];
                    }
                }.less);
                for (group, 0..) |area, at| {
                    self.coordinates[at * 2] = area.minimum[1];
                    self.coordinates[at * 2 + 1] = area.maximum[1];
                    edges[at * 2] = .{ .x = area.minimum[0], .region = @intCast(at), .start = true };
                    edges[at * 2 + 1] = .{ .x = area.maximum[0], .region = @intCast(at), .start = false };
                }
                std.mem.sort(f64, self.coordinates[0..edges.len], {}, std.sort.asc(f64));
                var unique: usize = 0;
                for (self.coordinates[0..edges.len]) |coordinate| {
                    if (unique != 0 and self.coordinates[unique - 1] == coordinate) continue;
                    self.coordinates[unique] = coordinate;
                    unique += 1;
                }
                const coordinates = self.coordinates[0..unique];
                // Even leaves are endpoints. Odd leaves are the open gaps between endpoints.
                const base = std.math.ceilPowerOfTwo(usize, unique * 2 - 1) catch unreachable;
                const coverage = self.coverage[0 .. base * 2];
                @memset(coverage, 0);
                std.mem.sort(Edge, edges, {}, Edge.less);
                cursor = 0;
                for (candidates) |slot| {
                    const resident = index.residents[slot];
                    const point = resident.position;
                    assert(resident.alive and resident.world == world);
                    assert(@floor(point[0] / 16) == @as(f64, @floatFromInt(resident.x)) and @floor(point[1] / 16) == @as(f64, @floatFromInt(resident.z)));
                    while (cursor < edges.len and (edges[cursor].x < point[0] or (edges[cursor].x == point[0] and edges[cursor].start))) : (cursor += 1) {
                        const edge = edges[cursor];
                        const area = group[edge.region];
                        var low = base + lowerBound(coordinates, area.minimum[1]) * 2;
                        var high = base + lowerBound(coordinates, area.maximum[1]) * 2 + 1;
                        while (low < high) : ({
                            low /= 2;
                            high /= 2;
                        }) {
                            if (low & 1 != 0) {
                                update(coverage, low, edge.start);
                                low += 1;
                                work.coverage_nodes += 1;
                            }
                            if (high & 1 != 0) {
                                high -= 1;
                                update(coverage, high, edge.start);
                                work.coverage_nodes += 1;
                            }
                        }
                    }
                    if (point[1] < coordinates[0] or point[1] > coordinates[unique - 1]) continue;
                    const at = lowerBound(coordinates, point[1]);
                    var leaf = base + at * 2 - @intFromBool(coordinates[at] != point[1]);
                    while (leaf != 0) : (leaf /= 2) {
                        work.coverage_nodes += 1;
                        if (coverage[leaf] == 0) continue;
                        output.insert(slot);
                        work.matches += 1;
                        break;
                    }
                }
            }
            begin = end;
        }
        assert(work.matches <= work.candidates and work.candidates <= index.count);
        return work;
    }

    fn lowerBound(values: []const f64, value: f64) usize {
        var low: usize = 0;
        var high = values.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (values[middle] < value) low = middle + 1 else high = middle;
        }
        return low;
    }

    fn update(coverage: []usize, at: usize, start: bool) void {
        if (start) {
            coverage[at] += 1;
        } else {
            assert(coverage[at] > 0);
            coverage[at] -= 1;
        }
    }
};
