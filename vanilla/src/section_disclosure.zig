const std = @import("std");
const visibility = @import("section_visibility.zig");
const horizon = @import("chunk_horizon.zig");
const cone = @import("section_cone.zig");
const assert = std.debug.assert;
const absent = std.math.maxInt(u32);

pub const Topology = visibility.Topology;

pub const Column = struct {
    paths: [36]u32 = @splat(0),

    pub fn set(self: *Column, offset: usize, topology: Topology) void {
        assert(offset < 32);
        const bit = @as(u32, 1) << @intCast(offset);
        inline for (0..36) |index| {
            self.paths[index] = (self.paths[index] & ~bit) | (bit * @as(u32, @intFromBool(topology.paths & (@as(u36, 1) << index) != 0)));
        }
    }

    pub fn get(self: *const Column, offset: usize) Topology {
        assert(offset < 32);
        var result: Topology = .{};
        const bit = @as(u32, 1) << @intCast(offset);
        inline for (0..36) |index| if (self.paths[index] & bit != 0) {
            result.paths |= @as(u36, 1) << index;
        };
        return result;
    }
};

pub const Query = struct {
    pub const MissingColumn = struct { index: u32 };
    pub const Upcoming = struct {
        query: *const Query,
        cursor: usize,
        end: usize,
        quadrant: u3 = 0,

        pub fn next(self: *Upcoming) ?MissingColumn {
            const query = self.query;
            const all: u32 = @truncate((@as(u64, 1) << @intCast(query.grid.size[1])) - 1);
            while (self.cursor < self.end) : (self.cursor += 1) {
                const wave = query.waves[self.cursor];
                while (self.quadrant < 4) {
                    const quadrant = self.quadrant;
                    self.quadrant += 1;
                    if (wave.valid & (@as(u4, 1) << @intCast(quadrant)) == 0) continue;
                    const index = wave.columns[quadrant];
                    if (query.known[index] == all) continue;
                    return .{ .index = @intCast(index) };
                }
                self.quadrant = 0;
            }
            return null;
        }
    };
    const Vector = @Vector(8, u32);
    const Active = @Vector(8, bool);
    const upward: Active = .{ false, false, true, true, false, false, true, true };
    const Wave = struct { columns: [4]usize, roots: [4]u8, valid: u4 };
    const Layout = struct { size: [3]usize, relative: [2]i64, radius: i32, exterior: bool };
    pub const Statistics = struct { visits: usize = 0, columns: usize = 0, waves: usize = 0 };

    topology: []Column,
    borrowed: []?*const Column,
    maximum_size: [3]usize,
    known: []u32,
    masks: []u32,
    outgoing: []u32,
    capture_frontier: bool = false,
    waves: []Wave,
    incoming: []Vector,
    // Direction cones of the bits in `horizontal` and `incoming`, by lane and section height.
    horizontal_cones: *[8][32]cone.Cone,
    incoming_cones: [][8][32]cone.Cone,
    // Eye box per octant lane, relative to the source section origin and mirrored into that octant.
    eyes: ?[8]cone.Box = null,
    pending_waves: std.DynamicBitSetUnmanaged,
    root_waves: [36]struct { root: u8, wave: usize } = undefined,
    root_wave_count: usize = 0,
    next_wave: usize = 0,
    horizontal_wave: usize = std.math.maxInt(usize),
    layout: ?Layout = null,
    width: usize = 0,
    height: usize = 0,
    row: usize = 0,
    cursor: usize = 0,
    horizontal: Vector = @splat(0),
    outside: Vector = @splat(0),
    roots: [9]u32 = @splat(0),
    seeds: [9][3]Vector = @splat(@splat(@splat(0))),
    pending: [4]MissingColumn = undefined,
    grid: visibility.Grid = undefined,
    source: [3]i32 = undefined,
    radius: i32 = 0,
    done: bool = false,
    statistics: Statistics = .{},

    pub fn init(allocator: std.mem.Allocator, size: [3]usize) !Query {
        const count = try std.math.mul(usize, size[0], size[2]);
        if (count == 0 or count >= absent or size[1] == 0 or size[1] > 32) return error.InvalidCapacity;
        const topology = try allocator.alloc(Column, count);
        errdefer allocator.free(topology);
        const borrowed = try allocator.alloc(?*const Column, count);
        errdefer allocator.free(borrowed);
        const known = try allocator.alloc(u32, count);
        errdefer allocator.free(known);
        const masks = try allocator.alloc(u32, count);
        errdefer allocator.free(masks);
        const outgoing = try allocator.alloc(u32, count);
        errdefer allocator.free(outgoing);
        const waves = try allocator.alloc(Wave, count);
        errdefer allocator.free(waves);
        const incoming = try allocator.alloc(Vector, size[0]);
        errdefer allocator.free(incoming);
        const horizontal_cones = try allocator.create([8][32]cone.Cone);
        errdefer allocator.destroy(horizontal_cones);
        const incoming_cones = try allocator.alloc([8][32]cone.Cone, size[0]);
        errdefer allocator.free(incoming_cones);
        return .{ .maximum_size = size, .topology = topology, .borrowed = borrowed, .known = known, .masks = masks, .outgoing = outgoing, .waves = waves, .incoming = incoming, .horizontal_cones = horizontal_cones, .incoming_cones = incoming_cones, .pending_waves = try .initEmpty(allocator, count) };
    }

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        allocator.free(self.topology);
        allocator.free(self.borrowed);
        allocator.free(self.known);
        allocator.free(self.masks);
        allocator.free(self.outgoing);
        allocator.free(self.waves);
        allocator.free(self.incoming);
        allocator.destroy(self.horizontal_cones);
        allocator.free(self.incoming_cones);
        self.pending_waves.deinit(allocator);
    }

    /// `eye` bounds every point a ray may start from, in blocks with exclusive maxima.
    /// Without it the flood keeps every direction of each octant.
    pub fn begin(self: *Query, grid: visibility.Grid, source: [3]i32, radius: i32, cells: u32, starts: *const [27]u6, eye: ?visibility.Bounds) void {
        assert(grid.size[1] > 0 and grid.size[1] <= 32 and radius >= 0);
        for (grid.size, self.maximum_size) |extent, maximum| assert(extent > 0 and extent <= maximum);
        @memset(self.borrowed, null);
        self.grid = grid;
        self.source = source;
        self.radius = radius;
        self.eyes = if (eye) |bounds| eyeBoxes(grid, source, bounds) else null;
        self.done = false;
        self.statistics = .{};
        self.row = 0;
        self.cursor = 0;
        self.next_wave = 0;
        self.horizontal_wave = std.math.maxInt(usize);
        self.pending_waves.setRangeValue(.{ .start = 0, .end = self.pending_waves.bit_length }, false);
        self.horizontal = @splat(0);
        self.outside = @splat(0);
        self.roots = @splat(0);
        self.seeds = @splat(@splat(@splat(0)));
        @memset(self.masks, 0);
        if (self.capture_frontier) @memset(self.outgoing, 0);
        @memset(self.known, 0);
        @memset(self.incoming, @splat(0));
        if (cells == 1 << 13 and starts[13] == 0) {
            if (grid.index(source)) |index| {
                self.masks[index / grid.size[1]] = @as(u32, 1) << @intCast(index % grid.size[1]);
                self.statistics = .{ .visits = 8, .columns = 8 };
                self.done = true;
                return;
            }
        }
        const relative = [2]i64{ @as(i64, self.source[0]) - self.grid.minimum[0], @as(i64, self.source[2]) - self.grid.minimum[2] };
        const above = self.source[1] >= self.grid.minimum[1] + @as(i32, @intCast(self.grid.size[1]));
        const below = self.source[1] < self.grid.minimum[1];
        const layout: Layout = .{ .size = self.grid.size, .relative = relative, .radius = self.radius, .exterior = above or below };
        if (self.layout == null or !std.meta.eql(self.layout.?, layout)) {
            self.root_wave_count = 0;
            var first: [2][2]i64 = undefined;
            inline for (0..2) |axis| {
                const extent: i64 = @intCast(self.grid.size[axis * 2]);
                first[axis] = .{ if (layout.exterior) extent - 1 else @min(extent - 1, @max(-1, relative[axis] + 1)), if (layout.exterior) 0 else @min(extent, @max(0, relative[axis] - 1)) };
            }
            self.width = @intCast(@max(first[0][0] + 1, @as(i64, @intCast(self.grid.size[0])) - first[0][1]));
            self.height = @intCast(@max(first[1][0] + 1, @as(i64, @intCast(self.grid.size[2])) - first[1][1]));
            for (0..self.height) |z| for (0..self.width) |x| {
                const wave = &self.waves[z * self.width + x];
                wave.* = .{ .columns = @splat(0), .roots = @splat(255), .valid = 0 };
                inline for (0..4) |q| {
                    const xx = first[0][q & 1] + (if (q & 1 != 0) @as(i64, 1) else -1) * @as(i64, @intCast(x));
                    const zz = first[1][q >> 1] + (if (q & 2 != 0) @as(i64, 1) else -1) * @as(i64, @intCast(z));
                    if (xx >= 0 and xx < self.grid.size[0] and zz >= 0 and zz < self.grid.size[2]) {
                        wave.columns[q] = @intCast(zz * @as(i64, @intCast(self.grid.size[0])) + xx);
                        const at: horizon.Position = .{ .x = @intCast(xx + self.grid.minimum[0]), .z = @intCast(zz + self.grid.minimum[2]) };
                        if (horizon.contains(self.radius, .{ .x = self.source[0], .z = self.source[2] }, at)) wave.valid |= 1 << q;
                        const dx = xx - relative[0];
                        const dz = zz - relative[1];
                        if (@abs(dx) <= 1 and @abs(dz) <= 1) {
                            const root: usize = @intCast((dz + 1) * 3 + dx + 1);
                            wave.roots[q] = @intCast(root);
                            assert(self.root_wave_count < self.root_waves.len);
                            self.root_waves[self.root_wave_count] = .{ .root = @intCast(root), .wave = z * self.width + x };
                            self.root_wave_count += 1;
                        }
                    }
                }
            };
            self.layout = layout;
        }
        for (0..27) |cell| {
            if (cell != 13 and cells & (@as(u32, 1) << @intCast(cell)) == 0) continue;
            const y = source[1] + @as(i32, @intCast(cell / 3 % 3)) - 1 - grid.minimum[1];
            if (y < 0 or y >= grid.size[1]) continue;
            const at = cell / 9 * 3 + cell % 3;
            const bit = @as(u32, 1) << @intCast(y);
            self.roots[at] |= bit;
            inline for (0..8) |lane| inline for (0..3) |axis| {
                const face = axis * 2 + ((lane >> axis) & 1);
                if (starts[cell] & (@as(u6, 1) << face) != 0) self.seeds[at][axis][lane] |= bit;
            };
        }
        inline for (0..8) |lane| {
            if ((above and lane & 2 == 0) or (below and lane & 2 != 0)) self.outside[lane] = @as(u32, 1) << @intCast(if (above) grid.size[1] - 1 else 0);
        }
        if (above or below) {
            self.pending_waves.setRangeValue(.{ .start = 0, .end = self.width * self.height }, true);
        } else for (self.root_waves[0..self.root_wave_count]) |seed| {
            if (self.roots[seed.root] != 0) self.pending_waves.set(seed.wave);
        }
    }

    inline fn nextWave(self: *const Query) ?usize {
        if (self.horizontal_wave == self.next_wave) return self.next_wave;
        const bits = @bitSizeOf(usize);
        var cursor = self.next_wave;
        const limit = self.width * self.height;
        while (cursor < limit) {
            const word = cursor / bits;
            const mask = self.pending_waves.masks[word] & (@as(usize, std.math.maxInt(usize)) << @as(std.math.Log2Int(usize), @intCast(cursor % bits)));
            if (mask != 0) {
                const index = word * bits + @ctz(mask);
                assert(index < limit);
                return index;
            }
            cursor = (word + 1) * bits;
        }
        return null;
    }

    pub fn supply(self: *Query, column: usize, topology: *const Column, known: u32) void {
        assert(!self.done and column < self.grid.size[0] * self.grid.size[2]);
        const all: u32 = @truncate((@as(u64, 1) << @intCast(self.grid.size[1])) - 1);
        const retained = self.known[column];
        assert(known & ~all == 0 and retained & ~known == 0);
        if (retained != 0) {
            for ((self.borrowed[column] orelse &self.topology[column]).paths, topology.paths) |before, after| assert((before ^ after) & retained == 0);
        }
        self.borrowed[column] = null;
        self.topology[column] = topology.*;
        self.known[column] = known;
        assert(self.known[column] == known);
    }
    /// The caller retains the column until completion and cancels the query before mutating it.
    pub fn supplyBorrowed(self: *Query, column: usize, topology: *const Column, known: u32) void {
        assert(!self.done and column < self.grid.size[0] * self.grid.size[2]);
        const all: u32 = @truncate((@as(u64, 1) << @intCast(self.grid.size[1])) - 1);
        assert(known & ~all == 0 and self.known[column] & ~known == 0);
        self.borrowed[column] = topology;
        self.known[column] = known;
        assert(self.borrowed[column] == topology and self.known[column] == known);
    }

    fn shift(bits: Vector, comptime amount: u5) Vector {
        return @select(u32, upward, bits << @as(@Vector(8, u5), @splat(amount)), bits >> @as(@Vector(8, u5), @splat(amount)));
    }

    fn fill(bits: Vector, chain: Vector) Vector {
        const forward = @select(u32, upward, bits, @bitReverse(bits));
        const propagation = @select(u32, upward, chain, @bitReverse(chain));
        const a = propagation | forward;
        // Binary carries implement generated bits followed by uninterrupted propagation bits.
        const carries = a ^ forward ^ (a +% forward);
        const reached = forward | (propagation & carries);
        return @select(u32, upward, reached, @bitReverse(reached));
    }

    /// Pending indices borrow query scratch until the next advance.
    pub fn advance(self: *Query) []const MissingColumn {
        return if (self.capture_frontier) self.advanceFrontier(true) else self.advanceFrontier(false);
    }

    fn advanceFrontier(self: *Query, comptime capture_frontier: bool) []const MissingColumn {
        if (self.done) return &.{};
        const height = self.grid.size[1];
        const all: u32 = @truncate((@as(u64, 1) << @intCast(height)) - 1);
        while (self.nextWave()) |wave_index| {
            const relative = wave_index - self.row * self.width;
            if (relative < self.width) {
                self.cursor = relative;
            } else {
                self.row = wave_index / self.width;
                self.cursor = wave_index % self.width;
            }
            const z = self.row;
            const x = self.cursor;
            const wave = self.waves[z * self.width + x];
            const z_in = self.incoming[x];
            const x_in: Vector = if (self.horizontal_wave == wave_index) self.horizontal else @splat(0);
            var seed: [3]Vector = @splat(@splat(0));
            var root: Vector = @splat(0);
            var valid: Active = @splat(false);
            inline for (0..8) |lane| {
                const quadrant = (lane & 1) | ((lane >> 1) & 2);
                valid[lane] = wave.valid & (@as(u4, 1) << quadrant) != 0;
                if (wave.roots[quadrant] != 255) {
                    root[lane] = self.roots[wave.roots[quadrant]];
                    inline for (0..3) |axis| seed[axis][lane] = self.seeds[wave.roots[quadrant]][axis][lane];
                }
            }
            const active = valid & ((x_in | z_in | root | self.outside) != @as(Vector, @splat(0)));
            if (!@reduce(.Or, active)) {
                self.horizontal = @splat(0);
                self.incoming[x] = @splat(0);
                self.next_wave = wave_index + 1;
                continue;
            }
            var requested: [4]usize = undefined;
            var columns: usize = 0;
            var count: usize = 0;
            inline for (0..4) |quadrant| {
                const lane = (quadrant & 1) | ((quadrant & 2) << 1);
                if (active[lane] or active[lane + 2]) {
                    const column = wave.columns[quadrant];
                    var duplicate = false;
                    for (requested[0..columns]) |previous| duplicate = duplicate or previous == column;
                    if (!duplicate) {
                        requested[columns] = column;
                        columns += 1;
                        if (all & ~self.known[column] != 0) {
                            self.pending[count] = .{ .index = @intCast(column) };
                            count += 1;
                        }
                    }
                }
            }
            if (count != 0) return self.pending[0..count];
            self.statistics.waves += 1;
            var connections: [3][3]Vector = @splat(@splat(@splat(0)));
            inline for (0..4) |quadrant| {
                const first_lane = (quadrant & 1) | ((quadrant & 2) << 1);
                if (active[first_lane] or active[first_lane + 2]) {
                    const data = self.borrowed[wave.columns[quadrant]] orelse &self.topology[wave.columns[quadrant]];
                    inline for (.{ first_lane, first_lane + 2 }) |lane| {
                        inline for (0..3) |entry_axis| inline for (0..3) |exit_axis| {
                            connections[entry_axis][exit_axis][lane] = data.paths[comptime Topology.index(lane, entry_axis, exit_axis)];
                        };
                    }
                }
            }
            const vertical = seed[1] | (x_in & connections[0][1]) | (z_in & connections[2][1]) | (self.outside & connections[1][1]);
            const world_mask: Vector = @splat(all);
            const y = shift(fill(vertical, connections[1][1]) & world_mask, 1) & world_mask | self.outside;
            var mask = @select(u32, active, (root | x_in | y | z_in) & world_mask, @as(Vector, @splat(0)));
            var outgoing_x = @select(u32, active, (seed[0] | (x_in & connections[0][0]) | (y & connections[1][0]) | (z_in & connections[2][0])) & world_mask, @as(Vector, @splat(0)));
            var outgoing_y = @select(u32, active, (seed[1] | (x_in & connections[0][1]) | (y & connections[1][1]) | (z_in & connections[2][1])) & world_mask, @as(Vector, @splat(0)));
            var outgoing_z = @select(u32, active, (seed[2] | (x_in & connections[0][2]) | (y & connections[1][2]) | (z_in & connections[2][2])) & world_mask, @as(Vector, @splat(0)));
            // The bitwise pass is a superset; direction cones keep only what straight rays reach.
            if (self.eyes) |*eyes| {
                const narrowed = self.narrow(eyes, &wave, x, mask, root, seed, x_in, z_in, &connections);
                assert(@reduce(.And, narrowed.mask & ~mask == @as(Vector, @splat(0))));
                assert(@reduce(.And, narrowed.exits[0] & ~outgoing_x == @as(Vector, @splat(0))));
                assert(@reduce(.And, narrowed.exits[1] & ~outgoing_y == @as(Vector, @splat(0))));
                assert(@reduce(.And, narrowed.exits[2] & ~outgoing_z == @as(Vector, @splat(0))));
                mask = narrowed.mask;
                outgoing_x = narrowed.exits[0];
                outgoing_y = narrowed.exits[1];
                outgoing_z = narrowed.exits[2];
            }
            self.incoming[x] = outgoing_z;
            self.statistics.visits += @reduce(.Add, @as(Vector, @popCount(mask)));
            self.statistics.columns += @popCount(@as(u8, @bitCast(active)));
            inline for (0..4) |quadrant| {
                const lane = (quadrant & 1) | ((quadrant & 2) << 1);
                if (active[lane] or active[lane + 2]) {
                    self.masks[wave.columns[quadrant]] |= mask[lane] | mask[lane + 2];
                }
            }
            if (capture_frontier) {
                const outgoing = @select(u32, active, (outgoing_x | outgoing_y | self.incoming[x]) & world_mask, @as(Vector, @splat(0)));
                inline for (0..4) |quadrant| {
                    const lane = (quadrant & 1) | ((quadrant & 2) << 1);
                    if (active[lane] or active[lane + 2]) self.outgoing[wave.columns[quadrant]] |= outgoing[lane] | outgoing[lane + 2];
                }
            }
            self.horizontal = outgoing_x;
            self.horizontal_wave = if (x + 1 < self.width and @reduce(.Or, outgoing_x) != 0) wave_index + 1 else std.math.maxInt(usize);
            if (z + 1 < self.height and @reduce(.Or, self.incoming[x]) != 0) self.pending_waves.set(wave_index + self.width);
            self.next_wave = wave_index + 1;
        }
        self.row = self.height;
        self.cursor = 0;
        self.done = true;
        return &.{};
    }

    pub fn upcoming(self: *const Query, maximum_waves: usize) Upcoming {
        assert(!self.done and maximum_waves > 0);
        const cursor = self.row * self.width + self.cursor;
        return .{ .query = self, .cursor = cursor, .end = cursor + @min(maximum_waves, self.width * self.height - cursor) };
    }
    fn eyeBoxes(grid: visibility.Grid, source: [3]i32, bounds: visibility.Bounds) ?[8]cone.Box {
        var relative: cone.Box = undefined;
        inline for (0..3) |axis| {
            assert(bounds.minimum[axis] < bounds.maximum[axis]);
            const origin = @as(i64, source[axis]) * 16;
            const low = @as(i64, grid.minimum[axis]) * 16 - origin;
            const extent: i64 = @intCast(if (axis == 1) grid.size[1] else grid.size[axis]);
            const high = low + extent * 16;
            const eye_low = @as(i64, bounds.minimum[axis]) - origin;
            const eye_high = @as(i64, bounds.maximum[axis]) - origin;
            // Rays only start in seeded sections around the source.
            assert(eye_low >= -16 and eye_high <= 32);
            // Rays from beyond the grid, such as a camera above the build limit, enter where no
            // seed is, so such an eye floods unnarrowed. Slopes also cap the coordinate span.
            if (eye_low < low or eye_high > high or high - low > cone.maximum_span) return null;
            relative.low[axis] = @intCast(eye_low);
            relative.high[axis] = @intCast(eye_high);
        }
        var result: [8]cone.Box = undefined;
        for (&result, 0..) |*box, octant| box.* = relative.mirror(@intCast(octant));
        return result;
    }

    const Narrowed = struct { mask: Vector, exits: [3]Vector };

    /// Recomputes one wave's reached sections and exits with direction cones.
    /// Sections are visited along each lane's vertical direction so a vertical exit feeds the next one.
    fn narrow(self: *Query, eyes: *const [8]cone.Box, wave: *const Wave, x: usize, candidates: Vector, root: Vector, seed: [3]Vector, x_in: Vector, z_in: Vector, connections: *const [3][3]Vector) Narrowed {
        const candidate_lanes: [8]u32 = candidates;
        const root_lanes: [8]u32 = root;
        const x_lanes: [8]u32 = x_in;
        const z_lanes: [8]u32 = z_in;
        const outside_lanes: [8]u32 = self.outside;
        var seed_lanes: [3][8]u32 = undefined;
        var connection_lanes: [3][3][8]u32 = undefined;
        inline for (0..3) |axis| seed_lanes[axis] = seed[axis];
        inline for (0..3) |entry| inline for (0..3) |exit| {
            connection_lanes[entry][exit] = connections[entry][exit];
        };
        var mask: [8]u32 = @splat(0);
        var exits: [3][8]u32 = @splat(@splat(0));
        const height: i32 = @intCast(self.grid.size[1]);
        for (0..8) |lane| {
            var pending = candidate_lanes[lane];
            if (pending == 0) continue;
            const octant: u3 = @intCast(lane);
            const ascending = lane & 2 != 0;
            const quadrant = (lane & 1) | ((lane >> 1) & 2);
            const column = wave.columns[quadrant];
            const section_x = @as(i32, @intCast(column % self.grid.size[0])) + self.grid.minimum[0] - self.source[0];
            const section_z = @as(i32, @intCast(column / self.grid.size[0])) + self.grid.minimum[2] - self.source[2];
            const horizontal = &self.horizontal_cones[lane];
            const incoming = &self.incoming_cones[x][lane];
            var vertical: cone.Cone = .empty;
            var vertical_at: i32 = -1;
            while (pending != 0) {
                const y: u5 = @intCast(if (ascending) @ctz(pending) else 31 - @clz(pending));
                const bit = @as(u32, 1) << y;
                pending &= ~bit;
                var entries: [3]cone.Cone = .{
                    if (x_lanes[lane] & bit != 0) horizontal[y] else .empty,
                    if (outside_lanes[lane] & bit != 0) .full else if (vertical_at == y) vertical else .empty,
                    if (z_lanes[lane] & bit != 0) incoming[y] else .empty,
                };
                vertical_at = -1;
                var entered = root_lanes[lane] & bit != 0;
                for (&entries) |*entry| entered = entered or !entry.isEmpty();
                if (!entered) continue;
                mask[lane] |= bit;
                const section_y = @as(i32, y) + self.grid.minimum[1] - self.source[1];
                const box: cone.Box = .{
                    .low = .{ section_x * 16, section_y * 16, section_z * 16 },
                    .high = .{ section_x * 16 + 16, section_y * 16 + 16, section_z * 16 + 16 },
                };
                const target = box.mirror(octant);
                inline for (0..3) |exit| {
                    var leaving: cone.Cone = if (seed_lanes[exit][lane] & bit != 0) .full else .empty;
                    inline for (0..3) |entry| {
                        if (connection_lanes[entry][exit][lane] & bit != 0) leaving = leaving.hull(&entries[entry]);
                    }
                    if (!leaving.isEmpty()) {
                        const face = cone.exitCone(&eyes[lane], &target, exit);
                        leaving = leaving.intersect(&face);
                    }
                    if (!leaving.isEmpty()) {
                        exits[exit][lane] |= bit;
                        // Each slot is read above before this section overwrites it for the next wave or row.
                        switch (exit) {
                            0 => horizontal[y] = leaving,
                            1 => {
                                const next = @as(i32, y) + @as(i32, if (ascending) 1 else -1);
                                if (next >= 0 and next < height) {
                                    vertical = leaving;
                                    vertical_at = next;
                                }
                            },
                            2 => incoming[y] = leaving,
                            else => unreachable,
                        }
                    }
                }
            }
        }
        return .{ .mask = mask, .exits = .{ exits[0], exits[1], exits[2] } };
    }

    pub fn solve(self: *Query, grid: visibility.Grid, source: [3]i32, radius: i32, cells: u32, starts: *const [27]u6, eye: ?visibility.Bounds) Statistics {
        self.begin(grid, source, radius, cells, starts, eye);
        @memset(self.known, @as(u32, @truncate((@as(u64, 1) << @intCast(grid.size[1])) - 1)));
        const missing = self.advance();
        assert(missing.len == 0 and self.done);
        return self.statistics;
    }
};

test "upcoming metadata stays bounded without advancing or disclosing future columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -8, 0, -8 }, .size = .{ 17, 3, 17 } };
    var query = try Query.init(arena.allocator(), grid.size);
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    query.begin(grid, .{ 0, 1, 0 }, 8, 1 << 13, &starts, null);
    const required = query.advance();
    const row = query.row;
    const cursor = query.cursor;
    const masks = try arena.allocator().dupe(u32, query.masks);
    var seen: std.StaticBitSet(17 * 17) = .empty;
    var count: usize = 0;
    var upcoming = query.upcoming(8);
    while (upcoming.next()) |candidate| {
        const point = grid.position(@as(usize, candidate.index) * grid.size[1]);
        try std.testing.expect(horizon.contains(8, .{ .x = 0, .z = 0 }, .{ .x = point[0], .z = point[2] }));
        seen.set(candidate.index);
        count += 1;
    }
    try std.testing.expect(count <= 8 * 4 and seen.count() > required.len);
    try std.testing.expectEqual(row, query.row);
    try std.testing.expectEqual(cursor, query.cursor);
    try std.testing.expectEqualSlices(u32, masks, query.masks);
    const first = seen.findFirstSet().?;
    const open: Column = .{ .paths = @splat(7) };
    query.supply(first, &open, 7);
    upcoming = query.upcoming(8);
    while (upcoming.next()) |candidate| try std.testing.expect(candidate.index != first);
}

test "lazy frontiers batch only reached columns and match resident traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const grid: visibility.Grid = .{ .minimum = .{ -2, 0, -2 }, .size = .{ 5, 3, 5 } };
    var lazy = try Query.init(bounded.allocator(), grid.size);
    var resident = try Query.init(bounded.allocator(), grid.size);
    for (resident.topology) |*topology| topology.* = .{};
    const center = grid.index(.{ 0, 1, 0 }).?;
    resident.topology[center / 3].set(center % 3, .open);
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    _ = resident.solve(grid, .{ 0, 1, 0 }, 2, 1 << 13, &starts, null);
    lazy.begin(grid, .{ 0, 1, 0 }, 2, 1 << 13, &starts, null);
    var requests: usize = 0;
    while (!lazy.done) {
        for (lazy.advance()) |request| {
            const index = request.index;
            try std.testing.expectEqual(@as(u32, 0), lazy.known[index]);
            lazy.supply(index, &resident.topology[index], 7);
            requests += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 5), requests);
    try std.testing.expectEqualSlices(u32, resident.masks, lazy.masks);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "closed frontiers terminate without scanning the horizon and retain stopping sections" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var query = try Query.init(bounded.allocator(), .{ 65, 24, 65 });
    defer query.deinit(bounded.allocator());
    query.capture_frontier = true;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const grid: visibility.Grid = .{ .minimum = .{ -32, 0, -32 }, .size = .{ 65, 24, 65 } };
    for (query.topology) |*column| column.* = .{};
    const center = grid.index(.{ 0, 12, 0 }).?;
    query.topology[center / 24].set(12, .open);
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    const stats = query.solve(grid, .{ 0, 12, 0 }, 32, 1 << 13, &starts, null);
    try std.testing.expect(stats.waves <= 9);
    try std.testing.expectEqual(@as(u32, 7 << 11), query.masks[center / 24]);
    try std.testing.expectEqual(@as(u32, 5 << 11), query.masks[center / 24] & ~query.outgoing[center / 24]);
    for ([_][3]i32{ .{ -1, 12, 0 }, .{ 1, 12, 0 }, .{ 0, 12, -1 }, .{ 0, 12, 1 } }) |neighbor| {
        const column = grid.index(neighbor).? / 24;
        try std.testing.expectEqual(@as(u32, 1 << 12), query.masks[column]);
        try std.testing.expectEqual(@as(u32, 0), query.outgoing[column]);
    }
    for (query.masks, 0..) |mask, index| {
        const at = grid.position(index * 24);
        if (@abs(at[0]) + @abs(at[2]) > 1) try std.testing.expectEqual(@as(u32, 0), mask);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "vector traversal equals an independent ordered graph sweep" {
    var query = try Query.init(std.testing.allocator, .{ 5, 32, 5 });
    defer query.deinit(std.testing.allocator);
    var random = std.Random.DefaultPrng.init(0x59182);
    var starts: [27]u6 = undefined;
    for ([_]usize{ 1, 3, 24, 32 }) |height| {
        const grid: visibility.Grid = .{ .minimum = .{ -2, -4, -2 }, .size = .{ 5, height, 5 } };
        for (0..32) |trial| {
            const source: [3]i32 = .{ random.random().intRangeAtMost(i32, -3, 3), @as(i32, @intCast(trial % (height + 4))) - 6, random.random().intRangeAtMost(i32, -3, 3) };
            const radius = random.random().intRangeAtMost(i32, 0, 3);
            const cells: u32 = if (trial == 0) 1 << 13 else random.random().int(u27);
            for (&starts) |*faces| faces.* = if (trial == 0) 0 else random.random().int(u6);
            for (query.topology) |*topology| {
                topology.* = .{};
                for (0..height) |y| {
                    const value: Topology = .{ .paths = random.random().int(u36) };
                    topology.set(y, value);
                }
            }
            var expected: [25]u32 = @splat(0);
            for (0..8) |direction| {
                var entries: [25 * 32]u6 = @splat(0);
                for (0..grid.count()) |linear| {
                    var local = [3]usize{ linear / height % 5, linear % height, linear / (5 * height) };
                    for (&local, grid.size, 0..) |*coordinate, extent, axis| if (direction & (@as(usize, 1) << @intCast(axis)) == 0) {
                        coordinate.* = extent - coordinate.* - 1;
                    };
                    var at: [3]i32 = undefined;
                    for (&at, grid.minimum, local) |*coordinate, minimum, offset| coordinate.* = minimum + @as(i32, @intCast(offset));
                    if (!horizon.contains(radius, .{ .x = source[0], .z = source[2] }, .{ .x = at[0], .z = at[2] })) continue;
                    const index = grid.index(at).?;
                    const dx = at[0] - source[0] + 1;
                    const dy = at[1] - source[1] + 1;
                    const dz = at[2] - source[2] + 1;
                    const cell: ?usize = if (dx >= 0 and dx < 3 and dy >= 0 and dy < 3 and dz >= 0 and dz < 3) @intCast(dz * 9 + dy * 3 + dx) else null;
                    const seeded = if (cell) |seed| seed == 13 or cells & (@as(u32, 1) << @intCast(seed)) != 0 else false;
                    const ascending = direction & 2 != 0;
                    if ((source[1] < grid.minimum[1] and ascending and local[1] == 0) or
                        (source[1] >= grid.minimum[1] + @as(i32, @intCast(height)) and !ascending and local[1] == height - 1)) entries[index] |= @as(u6, 1) << @intCast((2 + @as(usize, @intFromBool(ascending))) ^ 1);
                    if (entries[index] == 0 and !seeded) continue;
                    expected[index / height] |= @as(u32, 1) << @intCast(index % height);
                    var exits: u6 = if (seeded) starts[cell.?] else 0;
                    for (0..6) |face| if (entries[index] & (@as(u6, 1) << @intCast(face)) != 0) {
                        const topology = query.topology[index / height].get(index % height);
                        for (0..3) |exit| {
                            const path = Topology.index(direction, face / 2, exit);
                            if (topology.paths & (@as(u36, 1) << @intCast(path)) != 0) exits |= @as(u6, 1) << @intCast(exit * 2 + ((direction >> @intCast(exit)) & 1));
                        }
                    };
                    for (0..3) |axis| {
                        const positive = direction & (@as(usize, 1) << @intCast(axis)) != 0;
                        const face = axis * 2 + @intFromBool(positive);
                        if (exits & (@as(u6, 1) << @intCast(face)) == 0) continue;
                        var next = at;
                        next[axis] += if (positive) @as(i32, 1) else -1;
                        if (grid.index(next)) |neighbor| entries[neighbor] |= @as(u6, 1) << @intCast(face ^ 1);
                    }
                }
            }
            _ = query.solve(grid, source, radius, cells, &starts, null);
            try std.testing.expectEqualSlices(u32, &expected, query.masks);
            try std.testing.expect(query.statistics.visits <= grid.count() * 8);
            query.capture_frontier = true;
            _ = query.solve(grid, source, radius, cells, &starts, null);
            try std.testing.expectEqualSlices(u32, &expected, query.masks);
            for (query.outgoing, query.masks) |outgoing, reached| try std.testing.expectEqual(@as(u32, 0), outgoing & ~reached);
            query.capture_frontier = false;
        }
    }
}

test "carry propagation matches independent vertical stepping for every byte and random full words" {
    var random = std.Random.DefaultPrng.init(0x581d13);
    for (0..65536 + 4096) |trial| {
        var bits: Query.Vector = undefined;
        var chain: Query.Vector = undefined;
        inline for (0..8) |lane| {
            bits[lane] = if (trial < 65536) @intCast(trial % 256) else random.random().int(u32);
            chain[lane] = if (trial < 65536) @intCast(trial / 256) else random.random().int(u32);
        }
        var expected = bits;
        for (0..31) |_| expected |= Query.shift(expected, 1) & chain;
        const result = Query.fill(bits, chain);
        try std.testing.expectEqual(@as([8]u32, expected), @as([8]u32, result));
    }
}

fn openClosedTopology(query: *Query, grid: visibility.Grid, open: []const bool) void {
    for (query.topology[0 .. grid.size[0] * grid.size[2]], 0..) |*column, at| {
        column.* = .{};
        for (0..grid.size[1]) |y| column.set(y, if (open[at * grid.size[1] + y]) .open else .closed);
    }
}

test "direction cones disclose every section a straight ray from the eye box crosses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -4, 0, -4 }, .size = .{ 9, 8, 9 } };
    const source = [3]i32{ 0, 3, 0 };
    const radius = 4;
    var query = try Query.init(arena.allocator(), grid.size);
    var open: [9 * 8 * 9]bool = undefined;
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    var random = std.Random.DefaultPrng.init(0x5ec7);
    for (0..256) |trial| {
        for (&open) |*flag| flag.* = random.random().uintLessThan(u8, 10) < 7;
        open[grid.index(source).?] = true;
        openClosedTopology(&query, grid, &open);
        var eye: visibility.Bounds = undefined;
        for (0..3) |axis| {
            const low = source[axis] * 16 + random.random().intRangeAtMost(i32, 0, 12);
            eye.minimum[axis] = low;
            eye.maximum[axis] = @min(source[axis] * 16 + 16, low + random.random().intRangeAtMost(i32, 1, 8));
        }
        _ = query.solve(grid, source, radius, 1 << 13, &starts, eye);
        for (0..64) |_| {
            var point: [3]f64 = undefined;
            var direction: [3]f64 = undefined;
            for (0..3) |axis| {
                const low: f64 = @floatFromInt(eye.minimum[axis]);
                const high: f64 = @floatFromInt(eye.maximum[axis]);
                point[axis] = low + (high - low) * random.random().float(f64);
                direction[axis] = random.random().float(f64) * 2 - 1;
            }
            if (trial % 4 == 0) direction[1] = @abs(direction[1]) * 8;
            // Section-by-section traversal of the ray until it meets a closed section or leaves the horizon.
            var section: [3]i32 = undefined;
            var next: [3]f64 = undefined;
            var delta: [3]f64 = undefined;
            for (0..3) |axis| {
                section[axis] = @intFromFloat(@floor(point[axis] / 16));
                const step = direction[axis];
                const boundary: f64 = @floatFromInt(if (step > 0) section[axis] * 16 + 16 else section[axis] * 16);
                next[axis] = if (step == 0) std.math.inf(f64) else (boundary - point[axis]) / step;
                delta[axis] = if (step == 0) std.math.inf(f64) else 16 / @abs(step);
            }
            while (true) {
                const index = grid.index(section) orelse break;
                if (!horizon.contains(radius, .{ .x = source[0], .z = source[2] }, .{ .x = section[0], .z = section[2] })) break;
                const column = index / grid.size[1];
                const bit = @as(u32, 1) << @intCast(index % grid.size[1]);
                try std.testing.expect(query.masks[column] & bit != 0);
                if (!open[index]) break;
                var axis: usize = 0;
                if (next[1] < next[axis]) axis = 1;
                if (next[2] < next[axis]) axis = 2;
                section[axis] += if (direction[axis] > 0) 1 else -1;
                next[axis] += delta[axis];
            }
        }
    }
}

test "direction cones keep open air whole and never disclose beyond the octant flood" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -3, -2, -3 }, .size = .{ 7, 6, 7 } };
    var query = try Query.init(arena.allocator(), grid.size);
    var random = std.Random.DefaultPrng.init(0xa1e);
    for (0..512) |trial| {
        const source = [3]i32{ random.random().intRangeAtMost(i32, -1, 1), random.random().intRangeAtMost(i32, -4, 5), random.random().intRangeAtMost(i32, -1, 1) };
        // Open air needs the flood to cover every column an eye box can reach, as production radii do.
        const radius = random.random().intRangeAtMost(i32, if (trial % 2 == 0) 2 else 0, 3);
        const cells: u32 = if (trial % 2 == 0) (1 << 27) - 1 else random.random().int(u27) | 1 << 13;
        var starts: [27]u6 = undefined;
        for (&starts) |*faces| faces.* = if (trial % 2 == 0) 63 else random.random().int(u6);
        var eye: visibility.Bounds = undefined;
        for (0..3) |axis| {
            // Rays start in the seeded neighborhood, as every production eye box does.
            eye.minimum[axis] = source[axis] * 16 + random.random().intRangeAtMost(i32, -16, 31);
            eye.maximum[axis] = @min(source[axis] * 16 + 32, eye.minimum[axis] + random.random().intRangeAtMost(i32, 1, 26));
        }
        for (query.topology[0 .. grid.size[0] * grid.size[2]]) |*column| {
            column.* = .{};
            for (0..grid.size[1]) |y| column.set(y, if (trial % 2 == 0) .open else .{ .paths = random.random().int(u36) });
        }
        _ = query.solve(grid, source, radius, cells, &starts, null);
        const octant = try arena.allocator().dupe(u32, query.masks[0 .. grid.size[0] * grid.size[2]]);
        query.capture_frontier = true;
        _ = query.solve(grid, source, radius, cells, &starts, eye);
        query.capture_frontier = false;
        for (octant, query.masks[0..octant.len], query.outgoing[0..octant.len]) |wide, narrow, outgoing| {
            try std.testing.expectEqual(@as(u32, 0), narrow & ~wide);
            try std.testing.expectEqual(@as(u32, 0), outgoing & ~narrow);
            // Inside the grid, open air is visible along a straight ray from anywhere.
            const inside = source[1] >= grid.minimum[1] and source[1] < grid.minimum[1] + @as(i32, @intCast(grid.size[1]));
            if (trial % 2 == 0 and inside) try std.testing.expectEqual(wide, narrow);
        }
    }
}

test "a vertical shaft discloses a narrow cone of sky instead of whole quadrants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -16, 0, -16 }, .size = .{ 33, 16, 33 } };
    const source = [3]i32{ 0, 0, 0 };
    var query = try Query.init(arena.allocator(), grid.size);
    var open: [33 * 16 * 33]bool = undefined;
    for (&open, 0..) |*flag, index| {
        const at = grid.position(index);
        // Rock up to section 6 with a one-section shaft above the eye, then open sky.
        flag.* = at[1] >= 7 or (at[0] == 0 and at[2] == 0);
    }
    openClosedTopology(&query, grid, &open);
    var starts: [27]u6 = @splat(0);
    starts[13] = 63;
    const eye: visibility.Bounds = .{ .minimum = .{ 4, 2, 4 }, .maximum = .{ 12, 10, 12 } };
    _ = query.solve(grid, source, 16, 1 << 13, &starts, null);
    var octant: usize = 0;
    for (query.masks[0 .. 33 * 33]) |mask| octant += @popCount(mask);
    _ = query.solve(grid, source, 16, 1 << 13, &starts, eye);
    var narrowed: usize = 0;
    var widest: u32 = 0;
    for (query.masks[0 .. 33 * 33], 0..) |mask, column| {
        narrowed += @popCount(mask);
        if (mask & ~@as(u32, 0x7f) == 0) continue;
        const at = grid.position(column * grid.size[1]);
        widest = @max(widest, @max(@abs(at[0]), @abs(at[2])));
    }
    // Through a 16 block opening 112 blocks up, the top layer is at most a few sections across.
    try std.testing.expect(widest <= 4);
    try std.testing.expect(narrowed * 20 < octant);
}
