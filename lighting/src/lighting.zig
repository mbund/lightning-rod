const std = @import("std");
const assert = std.debug.assert;
pub const testing = @import("testing.zig");
pub const patch = @import("patch.zig");
const reference = testing.reference;

pub const lanes = 16;
pub const Levels = @Vector(lanes, u8);
pub const Layer = enum { block, sky };
pub const Blocks = union(enum) {
    uniform: u16,
    dense: []const u16,
    ring: Ring,

    pub const Ring = struct {
        /// Dense backing starts at first. Outside sections are implicit air.
        /// Uniform sections never read backing rows. Null entries require complete dense rows.
        pub const Sections = struct {
            uniforms: []const ?u16,
            first: usize,
            count: usize,
            stride: usize,
        };
        states: []const u16,
        sections: ?Sections = null,
        /// Horizontal origin in sixteen-cell X rows and single-cell Z rows.
        origin: [2]usize,
        /// Rows below this height are outside the solve. Exact queries need a fifteen-cell halo.
        minimum_y: usize = 0,

        /// Addresses the rows of one logical column, so loading divides once per column
        /// instead of once per row.
        const Cursor = struct {
            /// Section uniforms of this column, starting at the first backed section.
            uniforms: ?[*]const ?u16 = null,
            /// Physical row of this column within one level of the backing.
            offset: usize = 0,
        };

        fn cursor(self: Ring, column: usize, stride: usize, depth: usize) Cursor {
            const x = column % stride;
            const z = column / stride;
            assert(z < depth);
            return .{
                .uniforms = if (self.sections) |sections| sections.uniforms[(z / 16 * stride + x) * sections.stride ..].ptr else null,
                .offset = (z + self.origin[1]) % depth * stride + (x + self.origin[0]) % stride,
            };
        }

        inline fn row(self: Ring, at: Cursor, y: usize, plane: usize) @Vector(lanes, u16) {
            var level = y;
            if (self.sections) |sections| {
                const section = y / 16;
                if (section < sections.first or section - sections.first >= sections.count) return @splat(0);
                if (at.uniforms.?[section - sections.first]) |state| return @splat(state);
                level -= sections.first * 16;
            }
            return self.states[(level * plane + at.offset) * lanes ..][0..lanes].*;
        }

        fn validBacking(self: Ring, dimensions: Dimensions) bool {
            const plane = dimensions.x * dimensions.z;
            if (self.states.len % plane != 0) return false;
            const rows = self.states.len / plane;
            const sections = self.sections orelse return rows == dimensions.y;
            if (sections.first > dimensions.y / 16 or sections.count > dimensions.y / 16 - sections.first) return false;
            return rows >= sections.count * 16 and rows <= dimensions.y - sections.first * 16;
        }

        fn materialEnd(self: Ring, stride: usize, depth: usize) usize {
            const minimum = self.minimum_y * stride * depth * lanes;
            if (self.sections) |sections| {
                assert(depth % 16 == 0 and sections.count <= sections.stride);
                assert(sections.uniforms.len >= stride * (depth / 16) * sections.stride);
                assert(sections.count * 16 * stride * depth * lanes <= self.states.len);
                var section = sections.count;
                while (section != 0) {
                    section -= 1;
                    for (0..stride * (depth / 16)) |column| {
                        if (sections.uniforms[column * sections.stride + section] != 0)
                            return @max(minimum, (sections.first + section + 1) * 16 * stride * depth * lanes);
                    }
                }
                return minimum;
            }
            var remaining = self.states.len;
            while (remaining >= minimum + 64) : (remaining -= 64) {
                const values: @Vector(64, u16) = self.states[remaining - 64 ..][0..64].*;
                if (@reduce(.Or, values != @as(@Vector(64, u16), @splat(0)))) break;
            }
            while (remaining > minimum and self.states[remaining - 1] == 0) remaining -= 1;
            return remaining;
        }
    };
};
pub const Direction = enum(u3) { west, east, north, south, down, up };

pub const Properties = struct {
    opacity: u8,
    emission: u8,
    faces: [6]u16,
};

pub const Registry = struct {
    states: []const Properties,
    faces: usize,
    occlusion: []const u8,

    pub fn blocked(self: Registry, from: u16, to: u16, direction: Direction) bool {
        const face = @backingInt(direction);
        const a = self.states[from].faces[face];
        const b = self.states[to].faces[face ^ 1];
        return self.occlusion[@as(usize, a) * self.faces + b] != 0;
    }

    /// Whether replacing one state with the other leaves every light value as it was.
    pub fn alike(self: Registry, a: u16, b: u16) bool {
        return std.meta.eql(self.states[a], self.states[b]);
    }
};

pub const Dimensions = struct {
    x: usize,
    y: usize,
    z: usize,

    pub fn volume(self: Dimensions) usize {
        return self.x * self.y * self.z;
    }
};

pub const Work = struct {
    seeded_rows: u64 = 0,
    propagated_rows: u64 = 0,
    darkened_rows: u64 = 0,
    restored_rows: u64 = 0,
    candidate_rows: u64 = 0,
    shape_checks: u64 = 0,
    changed_cells: u64 = 0,
    removed_cells: u64 = 0,
    cancelled_rows: u64 = 0,
    source_rows: u64 = 0,
    loaded_rows: u64 = 0,
    retained_rows: u64 = 0,
};

pub const Edit = struct { index: usize, state: u16 };
pub const batch_max = 256;
const EditIndex = std.math.IntFittingRange(0, batch_max - 1);
const EditDigit = u6;

// Keep propagation data in one 64-byte cache line.
const Row = struct {
    attenuation: Levels align(64),
    light: [2]Levels,
    shaped: u16,
    emitters: u16,
    transparent: u16,
    sky_source: u16 = 0,
    blocked_horizontal: [2]u16 = .{ 0, 0 },
    edges_dirty: bool = false,
    boundary: u6,
    restore_queued: bool = false,
};

comptime {
    assert(@sizeOf(Row) == 64);
}

const BlockRow = struct {
    state: [lanes]u16,
    emission: Levels,
};

const none = std.math.maxInt(u32);
const Link = struct { previous: u32 = none, next: u32 = none, mask: u16 = 0, level: u8 = 0 };
const Material = packed struct(u16) { opacity: u4, emission: u4, shaped: bool, reserved: u7 = 0 };
const Change = struct { index: usize, block: bool, sky: bool, block_decrease: bool };
const SourceBounds = struct { highest: u32 = none, lowest: u32 = none };
const PreparedEdits = struct { count: usize, indirect: bool };
/// One column entering the window during a scroll.
const WindowColumn = struct {
    index: u32,
    source: Blocks.Ring.Cursor,
    /// Physical west, east, north and south columns, or none at the window edge.
    adjacent: [4]u32,
    /// One bit per horizontal direction whose neighbour stays from the previous window.
    retained: u4,
};
/// A retained column beside a strip the scroll discards. Light the strip sent across this
/// face leaves with it. The lane is the cell facing the strip, or lanes for a whole row.
const ScrollEdge = struct {
    to: u32,
    from: u32,
    lane: u8,

    inline fn darker(self: ScrollEdge, inside: Levels, outside: Levels) u16 {
        if (self.lane == lanes) return @bitCast(inside < outside);
        const near: [lanes]u8 = inside;
        const far: [lanes]u8 = outside;
        return @as(u16, @intFromBool(near[self.lane] < far[lanes - 1 - self.lane])) << @intCast(self.lane);
    }
};

fn editLess(edits: []const Edit, a: EditIndex, b: EditIndex) bool {
    return edits[a].index < edits[b].index;
}

fn horizontalRemoval(pending: Levels, remaining: Levels) u16 {
    const original = @max(pending, remaining);
    const nonzero = original > @as(Levels, @splat(0));
    var right_edges: u16 = @bitCast(nonzero & (original < std.simd.shiftElementsRight(original, 1, 0)));
    var left_edges: u16 = @bitCast(nonzero & (original < std.simd.shiftElementsLeft(original, 1, 0)));
    var right: u16 = @bitCast(pending > @as(Levels, @splat(0)));
    var left = right;
    // Doubling composes strictly descending paths across the sixteen cells.
    inline for ([_]u4{ 1, 2, 4, 8 }) |distance| {
        right |= (right << distance) & right_edges;
        left |= (left >> distance) & left_edges;
        right_edges &= right_edges << distance;
        left_edges &= left_edges >> distance;
    }
    return right | left;
}

fn horizontalIncrease(old: Levels, attenuation: Levels, blocked: [2]u16) Levels {
    var value = old;
    var right_cost = @select(u8, @as(@Vector(lanes, bool), @bitCast(blocked[1])), @as(Levels, @splat(15)), attenuation);
    var left_cost = @select(u8, @as(@Vector(lanes, bool), @bitCast(blocked[0])), @as(Levels, @splat(15)), attenuation);
    inline for ([_]u4{ 1, 2, 4, 8 }) |distance| {
        const right = std.simd.shiftElementsRight(value, distance, 0) -| right_cost;
        const left = std.simd.shiftElementsLeft(value, distance, 0) -| left_cost;
        const next = @max(value, @max(right, left));
        if (distance == 1 and !@reduce(.Or, next > value)) return value;
        value = next;
        right_cost +|= std.simd.shiftElementsRight(right_cost, distance, 0);
        left_cost +|= std.simd.shiftElementsLeft(left_cost, distance, 0);
    }
    return value;
}

/// One worker owns the mutable workspace. Registry tables are immutable and must outlive it.
pub const Engine = struct {
    allocator: std.mem.Allocator,
    dimensions: Dimensions,
    registry: Registry,
    materials: []Material,
    rows: []Row,
    blocks: []BlockRow,
    stride: u32,
    plane: u32,
    origin: [2]usize = .{ 0, 0 },
    horizontal: []u6,
    window_columns: []WindowColumn,
    cursors: []Blocks.Ring.Cursor,
    scroll_edges: []ScrollEdge,
    /// Two masks per level and edge, for block then sky light a discarded strip may support.
    scroll_masks: []u16,
    /// Rounded up 2^64 / plane, so one widening multiply finds the column of a row.
    reciprocal: u64,
    links: []Link,
    decreases: []Levels,
    decrease_queue: []u32,
    decrease_queued: []bool,
    restore_rows: []u32,
    source_bounds: []SourceBounds,
    source_columns: [batch_max]u32 = undefined,
    source_count: usize = 0,
    restore_count: usize = 0,
    decrease_head: usize = 0,
    decrease_tail: usize = 0,
    decrease_count: usize = 0,
    heads: [16]u32 = @splat(none),
    highest: u8 = 0,
    loaded: bool = false,
    lit: bool = false,
    skylight: bool = false,
    uniform_air: bool = false,
    block_zero: bool = false,
    sky_start: usize = 0,
    air_start: usize = 0,
    minimum: usize = 0,
    emitter_count: usize = 0,
    work: Work = .{},
    changes: [batch_max]Change = undefined,
    edit_order: [batch_max]EditIndex = undefined,
    edit_scratch: [batch_max]EditIndex = undefined,
    edit_counts: [1 << @bitSizeOf(EditDigit)]u16 = undefined,

    pub fn init(allocator: std.mem.Allocator, dimensions: Dimensions, registry: Registry) !Engine {
        if (dimensions.x == 0 or dimensions.x % lanes != 0 or dimensions.y == 0 or dimensions.z == 0) return error.InvalidDimensions;
        const plane = try std.math.mul(usize, dimensions.x / lanes, dimensions.z);
        const count = try std.math.mul(usize, plane, dimensions.y);
        if (count > (none - 1) / lanes) return error.InvalidDimensions;
        if (registry.states.len == 0 or registry.states.len > 65536 or registry.faces == 0 or registry.occlusion.len != try std.math.mul(usize, registry.faces, registry.faces)) return error.InvalidRegistry;
        if (registry.states[0].opacity != 0 or registry.states[0].emission != 0 or !std.mem.allEqual(u16, &registry.states[0].faces, 0)) return error.InvalidAirState;
        if (registry.occlusion[0] != 0) return error.InvalidEmptyFace;
        for (registry.states) |properties| {
            if (properties.opacity > 15 or properties.emission > 15) return error.InvalidRegistry;
            for (properties.faces) |face| if (face >= registry.faces) return error.InvalidRegistry;
        }
        const materials = try allocator.alloc(Material, registry.states.len);
        errdefer allocator.free(materials);
        for (registry.states, materials) |properties, *material| material.* = .{
            .opacity = @intCast(properties.opacity),
            .emission = @intCast(properties.emission),
            .shaped = !std.mem.allEqual(u16, &properties.faces, 0),
        };
        const rows = try allocator.alloc(Row, count);
        errdefer allocator.free(rows);
        const blocks = try allocator.alloc(BlockRow, count);
        errdefer allocator.free(blocks);
        const links = try allocator.alloc(Link, count);
        errdefer allocator.free(links);
        const decreases = try allocator.alloc(Levels, count);
        errdefer allocator.free(decreases);
        const decrease_queue = try allocator.alloc(u32, count);
        errdefer allocator.free(decrease_queue);
        const decrease_queued = try allocator.alloc(bool, count);
        errdefer allocator.free(decrease_queued);
        const source_bounds = try allocator.alloc(SourceBounds, plane);
        errdefer allocator.free(source_bounds);
        const restore_rows = try allocator.alloc(u32, count);
        errdefer allocator.free(restore_rows);
        const horizontal = try allocator.alloc(u6, plane);
        errdefer allocator.free(horizontal);
        const window_columns = try allocator.alloc(WindowColumn, plane);
        errdefer allocator.free(window_columns);
        const cursors = try allocator.alloc(Blocks.Ring.Cursor, plane);
        errdefer allocator.free(cursors);
        // A scroll cuts at most one face along each axis.
        const edges = dimensions.x / lanes + dimensions.z;
        const scroll_edges = try allocator.alloc(ScrollEdge, edges);
        errdefer allocator.free(scroll_edges);
        const scroll_masks = try allocator.alloc(u16, try std.math.mul(usize, 2 * edges, dimensions.y));
        @memset(decreases, @splat(0));
        @memset(decrease_queued, false);
        @memset(links, .{});
        @memset(source_bounds, .{});
        const stride = dimensions.x / lanes;
        for (rows, 0..) |*row, index| {
            const column = index % plane;
            const boundary: @Vector(6, bool) = .{
                column % stride == 0,
                column % stride + 1 == stride,
                column < stride,
                column + stride >= plane,
                index < plane,
                index + plane >= count,
            };
            row.boundary = @bitCast(boundary);
            row.edges_dirty = false;
            row.restore_queued = false;
            if (index < plane) horizontal[index] = @as(u6, @truncate(row.boundary)) & 15;
        }
        const reciprocal: u64 = if (plane == 1) 0 else std.math.maxInt(u64) / plane + 1;
        return .{ .allocator = allocator, .dimensions = dimensions, .registry = registry, .materials = materials, .rows = rows, .blocks = blocks, .stride = @intCast(stride), .plane = @intCast(plane), .horizontal = horizontal, .window_columns = window_columns, .cursors = cursors, .scroll_edges = scroll_edges, .scroll_masks = scroll_masks, .reciprocal = reciprocal, .links = links, .decreases = decreases, .decrease_queue = decrease_queue, .decrease_queued = decrease_queued, .restore_rows = restore_rows, .source_bounds = source_bounds };
    }

    pub fn deinit(self: *Engine) void {
        self.allocator.free(self.horizontal);
        self.allocator.free(self.window_columns);
        self.allocator.free(self.cursors);
        self.allocator.free(self.scroll_edges);
        self.allocator.free(self.scroll_masks);
        self.allocator.free(self.links);
        self.allocator.free(self.restore_rows);
        self.allocator.free(self.decrease_queued);
        self.allocator.free(self.decrease_queue);
        self.allocator.free(self.decreases);
        self.allocator.free(self.rows);
        self.allocator.free(self.blocks);
        self.allocator.free(self.materials);
        self.allocator.free(self.source_bounds);
        self.* = undefined;
    }

    /// Blocks are in YZX order. The engine owns its decoded rows after this returns.
    pub fn load(self: *Engine, input: Blocks) !void {
        self.origin = .{ 0, 0 };
        self.loaded = false;
        self.lit = false;
        const minimum_y = if (input == .ring) input.ring.minimum_y else 0;
        assert(minimum_y < self.dimensions.y and minimum_y % 16 == 0);
        self.minimum = minimum_y * self.plane;
        var remaining = self.dimensions.volume();
        switch (input) {
            .uniform => |state| {
                if (state >= self.materials.len) return error.InvalidState;
                if (state == 0) remaining = 0;
            },
            .dense, .ring => {
                const blocks = if (input == .dense) input.dense else input.ring.states;
                if (input == .ring) {
                    assert(input.ring.origin[0] < self.stride and input.ring.origin[1] < self.dimensions.z);
                    assert(input.ring.origin[1] % 16 == 0);
                    if (!input.ring.validBacking(self.dimensions)) return error.InvalidBlockCount;
                } else if (blocks.len != remaining) return error.InvalidBlockCount;
                remaining = if (input == .ring) input.ring.materialEnd(self.stride, self.dimensions.z) else (Blocks.Ring{ .states = blocks, .origin = .{ 0, 0 }, .minimum_y = minimum_y }).materialEnd(self.stride, self.dimensions.z);
            },
        }
        self.uniform_air = remaining <= self.minimum * lanes;
        // Above the last material, sixteen air layers also contain every block light ray.
        const plane_cells = @as(usize, self.plane) * lanes;
        self.air_start = if (self.uniform_air) self.minimum else @min(self.dimensions.y, (remaining - 1) / plane_cells + 17) * self.plane;
        self.emitter_count = 0;
        self.sky_start = self.minimum;
        for (self.horizontal, 0..) |*column, index| column.* = self.rows[index].boundary & 15;
        if (self.uniform_air) {
            self.loaded = true;
            return;
        }
        if (input == .ring) for (self.cursors, 0..) |*at, column| {
            at.* = input.ring.cursor(column, self.stride, self.dimensions.z);
        };
        var base = self.minimum;
        var level = minimum_y;
        while (base < self.air_start) : ({
            base += self.plane;
            level += 1;
        }) {
            var opaque_plane = true;
            for (self.rows[base..][0..self.plane], self.cursors, base..) |*row, at, r| {
                const states: @Vector(lanes, u16) = switch (input) {
                    .uniform => |state| @splat(state),
                    .dense => |blocks| blocks[r * lanes ..][0..lanes].*,
                    .ring => |blocks| blocks.row(at, level, self.plane),
                };
                try self.loadRow(r, states);
                if (row.emitters != 0) self.emitter_count += @popCount(row.emitters);
                opaque_plane = opaque_plane and @reduce(.And, row.attenuation == @as(Levels, @splat(15)));
            }
            if (opaque_plane) self.sky_start = base;
        }
        self.loaded = true;
    }

    fn loadRow(self: *Engine, r: usize, states: @Vector(lanes, u16)) !void {
        self.work.loaded_rows += 1;
        const row = &self.rows[r];
        const block = &self.blocks[r];
        block.state = states;
        if (@reduce(.And, states == @as(@Vector(lanes, u16), @splat(states[0])))) {
            if (states[0] >= self.materials.len) return error.InvalidState;
            const material = self.materials[states[0]];
            row.attenuation = @splat(@max(@as(u8, material.opacity), 1));
            block.emission = @splat(material.emission);
            row.emitters = if (material.emission != 0) std.math.maxInt(u16) else 0;
            row.transparent = if (material.opacity == 0) std.math.maxInt(u16) else 0;
            row.shaped = if (material.shaped) std.math.maxInt(u16) else 0;
        } else {
            var materials: [lanes]u16 = undefined;
            for (block.state, &materials) |state, *material| {
                if (state >= self.materials.len) return error.InvalidState;
                material.* = @bitCast(self.materials[state]);
            }
            const values: @Vector(lanes, u16) = materials;
            const opacity: Levels = @intCast(values & @as(@Vector(lanes, u16), @splat(15)));
            row.attenuation = @max(@as(Levels, @splat(1)), opacity);
            block.emission = @intCast((values >> @splat(4)) & @as(@Vector(lanes, u16), @splat(15)));
            row.emitters = @bitCast(block.emission > @as(Levels, @splat(0)));
            row.transparent = @bitCast(opacity == @as(Levels, @splat(0)));
            row.shaped = @bitCast((values & @as(@Vector(lanes, u16), @splat(256))) != @as(@Vector(lanes, u16), @splat(0)));
        }
        self.prepareEdges(r);
    }

    /// Horizontal boundaries are opaque. All columns above the top boundary see the sky.
    pub fn relight(self: *Engine, skylight: bool) void {
        assert(self.highest == 0 and self.loaded);
        assert(self.decrease_count == 0 and self.restore_count == 0);
        self.skylight = skylight;
        self.lit = true;
        self.work = .{ .loaded_rows = self.air_start - self.minimum };
        self.block_zero = self.emitter_count == 0;
        if (self.uniform_air) return;
        // The empty decrease queue holds emitting rows until skylight propagation finishes.
        var sources: usize = 0;
        var at = self.air_start;
        const bottom = if (self.block_zero) (if (skylight) self.sky_start else self.air_start) else self.minimum;
        while (at != bottom) {
            at -= 1;
            const row = &self.rows[at];
            if (!self.block_zero) {
                const emission = self.blocks[at].emission;
                const maximum = @reduce(.Max, emission);
                row.light[0] = emission;
                if (maximum > 1) {
                    self.decrease_queue[sources] = @intCast(at);
                    sources += 1;
                    self.work.seeded_rows += 1;
                }
            }
            if (!skylight or at < self.sky_start) continue;
            const adjacent = self.neighbours(at);
            const upstream = if (adjacent[5] != none) self.rows[adjacent[5]].sky_source else std.math.maxInt(u16);
            row.sky_source = self.directSource(at, upstream);
            row.light[1] = @select(u8, @as(@Vector(lanes, bool), @bitCast(row.sky_source)), @as(Levels, @splat(15)), @as(Levels, @splat(0)));
            if (row.sky_source != 0 and row.sky_source != std.math.maxInt(u16)) {
                self.seedSky(at, at, row.sky_source << 1);
                self.seedSky(at, at, row.sky_source >> 1);
            }
            if (adjacent[1] != none) {
                const next = &self.rows[adjacent[1]];
                const forward_source = row.sky_source >> (lanes - 1);
                const backward_source = next.sky_source & 1;
                if (forward_source != backward_source) {
                    if (forward_source != 0) {
                        self.seedSky(at, adjacent[1], 1);
                    } else {
                        self.seedSky(adjacent[1], at, @as(u16, 1) << (lanes - 1));
                    }
                }
            }
            if (adjacent[3] != none and row.sky_source != self.rows[adjacent[3]].sky_source) {
                self.seedSky(at, adjacent[3], row.sky_source);
                self.seedSky(adjacent[3], at, self.rows[adjacent[3]].sky_source);
            }
            if (adjacent[5] != none and upstream != row.sky_source) self.seedSky(adjacent[5], at, upstream);
            if (adjacent[5] == none) self.skyBoundary(at);
        }
        if (skylight) self.propagate(.sky);
        while (sources != 0) {
            sources -= 1;
            self.seedRow(.block, self.decrease_queue[sources]);
        }
        self.propagate(.block);
    }

    /// Scrolls chunk-aligned strips. Every overlapping block must remain unchanged.
    /// The settled light equals a fresh solve of the new window.
    pub fn scroll(self: *Engine, offset: [2]i32, input: Blocks.Ring) !void {
        assert(self.loaded and self.lit and self.highest == 0 and self.source_count == 0);
        assert(self.decrease_count == 0 and self.restore_count == 0);
        assert(offset[0] != 0 or offset[1] != 0);
        assert(@mod(offset[0], lanes) == 0 and @mod(offset[1], 16) == 0 and self.dimensions.z % 16 == 0);
        assert(@abs(offset[0]) < self.dimensions.x and @abs(offset[1]) < self.dimensions.z);
        if (!input.validBacking(self.dimensions)) return error.InvalidBlockCount;
        assert(input.origin[0] < self.stride and input.origin[1] < self.dimensions.z);
        assert(input.origin[1] % 16 == 0);
        assert(input.minimum_y * self.plane == self.minimum);
        const old_air = if (self.uniform_air) self.minimum else self.air_start;
        const old_sky = self.sky_start;
        const old_zero = self.block_zero;
        const remaining = input.materialEnd(self.stride, self.dimensions.z);
        if (remaining == self.minimum * lanes) {
            try self.load(.{ .ring = input });
            self.relight(self.skylight);
            return;
        }
        self.work = .{};
        const count = @min(self.dimensions.y, (remaining - 1) / (self.plane * lanes) + 17) * self.plane;
        const plan = self.planScroll(@divExact(offset[0], lanes), offset[1], input);
        const incoming = self.window_columns[0..plan.incoming];
        const edges = self.scroll_edges[0..plan.edges];
        // Rows above either window are implicit air, which no discarded strip lights.
        const shared = @min(old_air, count);
        self.captureEdges(edges, shared);
        if (count < old_air) for (self.rows[count..old_air]) |row| {
            self.emitter_count -= @popCount(row.emitters);
        };
        self.air_start = count;
        self.uniform_air = false;
        self.sky_start = self.minimum;
        // Newly materialized heights were implicit air in the previous window.
        var base = old_air;
        while (base < count) : (base += self.plane) {
            for (self.horizontal, base..) |column, at| {
                if (column & 16 != 0) continue;
                try self.loadRow(at, @splat(0));
                self.rows[at].light = .{ @splat(0), @splat(if (self.skylight) 15 else 0) };
                self.rows[at].sky_source = if (self.skylight) std.math.maxInt(u16) else 0;
            }
        }
        var end = count;
        var level = count / self.plane;
        while (end != self.minimum) {
            end -= self.plane;
            level -= 1;
            for (incoming) |column| {
                const index = end + column.index;
                if (index < old_air) self.emitter_count -= @popCount(self.rows[index].emitters);
                try self.loadRow(index, input.row(column.source, level, self.plane));
                const row = &self.rows[index];
                self.emitter_count += @popCount(row.emitters);
                const above = index + self.plane;
                const upstream = if (self.skylight) self.directSource(index, if (above < count) self.rows[above].sky_source else std.math.maxInt(u16)) else 0;
                row.sky_source = upstream;
                row.light = .{ self.blocks[index].emission, @select(u8, @as(@Vector(lanes, bool), @bitCast(upstream)), @as(Levels, @splat(15)), @as(Levels, @splat(0))) };
            }
        }
        self.work.retained_rows = count - self.minimum - self.work.loaded_rows;
        var plane_end = count;
        while (plane_end != self.minimum) {
            const begin = plane_end - self.plane;
            const opaque_plane = for (self.rows[begin..plane_end]) |row| {
                if (!@reduce(.And, row.attenuation == @as(Levels, @splat(15)))) break false;
            } else true;
            if (opaque_plane) {
                self.sky_start = begin;
                break;
            }
            plane_end = begin;
        }
        self.block_zero = self.emitter_count == 0;
        if (old_zero and !self.block_zero) self.clearRetained(.block, self.minimum, count);
        if (self.sky_start < old_sky) self.clearRetained(.sky, self.sky_start, @min(old_sky, count));
        inline for (.{ Layer.sky, Layer.block }) |layer| {
            if ((layer == .sky and self.skylight) or (layer == .block and !self.block_zero)) {
                // Darkening settles before any increase, as it does for edits.
                self.removeEdges(layer, edges, shared);
                if (layer == .block and count < old_air) self.removeCeiling(count);
                self.darken(layer);
                for (self.restore_rows[0..self.restore_count]) |at| {
                    self.restoreRow(layer, at);
                    self.rows[at].restore_queued = false;
                }
                self.restore_count = 0;
                self.seedIncoming(layer, incoming, count);
                self.propagate(layer);
            }
        }
        assert(self.highest == 0 and self.decrease_count == 0 and self.restore_count == 0);
    }

    const ScrollPlan = struct { incoming: usize, edges: usize };

    /// Moves the ring origin, then lists the columns entering the window and the retained
    /// columns that faced a discarded strip.
    fn planScroll(self: *Engine, dx: i32, dz: i32, input: Blocks.Ring) ScrollPlan {
        const stride: usize = self.stride;
        const depth = self.dimensions.z;
        self.origin = .{
            @intCast(@mod(@as(i64, @intCast(self.origin[0])) + dx, self.stride)),
            @intCast(@mod(@as(i64, @intCast(self.origin[1])) + dz, @as(i64, @intCast(depth)))),
        };
        var plan: ScrollPlan = .{ .incoming = 0, .edges = 0 };
        var pz = self.origin[1];
        for (0..depth) |z| {
            var px = self.origin[0];
            for (0..stride) |x| {
                const column = pz * stride + px;
                // The ring wraps, so these slots hold the adjacent columns of the old window
                // and of the new one.
                const ring = [4]usize{
                    if (px == 0) column + stride - 1 else column - 1,
                    if (px + 1 == stride) column + 1 - stride else column + 1,
                    if (pz == 0) column + self.plane - stride else column - stride,
                    if (pz + 1 == depth) column + stride - self.plane else column + stride,
                };
                const boundary = [4]bool{ x == 0, x + 1 == stride, z == 0, z + 1 == depth };
                const entering = self.enters(@intCast(x), @intCast(z), dx, dz);
                self.horizontal[column] = @as(u4, @bitCast(@as(@Vector(4, bool), boundary))) | (@as(u6, @intFromBool(entering)) << 4);
                if (entering) {
                    const step = [4][2]i64{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
                    var adjacent: [4]u32 = @splat(none);
                    var retained: u4 = 0;
                    for (0..4) |direction| {
                        if (boundary[direction]) continue;
                        adjacent[direction] = @intCast(ring[direction]);
                        const other = self.enters(@as(i64, @intCast(x)) + step[direction][0], @as(i64, @intCast(z)) + step[direction][1], dx, dz);
                        if (!other) retained |= @as(u4, 1) << @intCast(direction);
                    }
                    self.window_columns[plan.incoming] = .{ .index = @intCast(column), .source = input.cursor(z * stride + x, stride, depth), .adjacent = adjacent, .retained = retained };
                    plan.incoming += 1;
                } else {
                    // The window moved away from these sides, so the strip beyond them is gone.
                    const cut = [4]bool{ dx > 0 and x == 0, dx < 0 and x + 1 == stride, dz > 0 and z == 0, dz < 0 and z + 1 == depth };
                    const facing = [4]u8{ 0, lanes - 1, lanes, lanes };
                    for (cut, ring, facing) |discarded, from, lane| {
                        if (!discarded) continue;
                        self.scroll_edges[plan.edges] = .{ .to = @intCast(column), .from = @intCast(from), .lane = lane };
                        plan.edges += 1;
                    }
                }
                px = if (px + 1 == stride) 0 else px + 1;
            }
            pz = if (pz + 1 == depth) 0 else pz + 1;
        }
        return plan;
    }

    /// Whether a column of the new window lay outside the previous one.
    fn enters(self: *const Engine, x: i64, z: i64, dx: i32, dz: i32) bool {
        const sx = x + dx;
        const sz = z + dz;
        return sx < 0 or sx >= self.stride or sz < 0 or sz >= self.dimensions.z;
    }

    /// Records which cells of the retained boundary rows are darker than the discarded cell
    /// they faced. Incoming rows overwrite the discarded light after this. Rows whose stored
    /// layer is implicit yield stale masks, which the scroll clears or skips before use.
    fn captureEdges(self: *Engine, edges: []const ScrollEdge, limit: usize) void {
        var slot: usize = 0;
        var base = self.minimum;
        while (base < limit) : (base += self.plane) {
            for (edges) |edge| {
                const inside = &self.rows[base + edge.to];
                const outside = &self.rows[base + edge.from];
                inline for (0..2) |layer| self.scroll_masks[slot + layer] = edge.darker(inside.light[layer], outside.light[layer]);
                slot += 2;
            }
        }
    }

    /// Removes light a discarded strip may have supported. Survivors relight what remains.
    fn removeEdges(self: *Engine, comptime layer: Layer, edges: []const ScrollEdge, limit: usize) void {
        var slot: usize = @backingInt(layer);
        var base = self.minimum;
        while (base < limit) : (base += self.plane) {
            for (edges) |edge| {
                const mask = self.scroll_masks[slot];
                slot += 2;
                if (mask == 0 or (layer == .sky and base < self.sky_start)) continue;
                self.removeMask(layer, base + edge.to, mask);
            }
        }
    }

    /// Rows a lower window drops become implicit air. Block light they sent down leaves too.
    fn removeCeiling(self: *Engine, count: usize) void {
        assert(count > self.minimum);
        for (self.horizontal, 0..) |column, offset| {
            if (column & 16 != 0) continue;
            const above = self.rows[count + offset].light[0];
            const at = count - self.plane + offset;
            self.removeMask(.block, at, @bitCast(self.rows[at].light[0] < above));
        }
    }

    /// Zeroes one layer of the retained rows in a range whose stored values were implicit.
    fn clearRetained(self: *Engine, comptime layer: Layer, begin: usize, end: usize) void {
        var base = begin;
        while (base < end) : (base += self.plane) {
            for (self.horizontal, self.rows[base..][0..self.plane]) |column, *row| {
                if (column & 16 != 0) continue;
                row.light[@backingInt(layer)] = @splat(0);
                if (layer == .sky) row.sky_source = 0;
            }
        }
    }

    /// Queues every incoming source and each face where light may cross between incoming
    /// and retained columns. Incoming rows start at their direct sources.
    fn seedIncoming(self: *Engine, comptime layer: Layer, incoming: []const WindowColumn, count: usize) void {
        var base = if (layer == .sky) self.sky_start else self.minimum;
        while (base < count) : (base += self.plane) {
            for (incoming) |column| {
                const index = base + column.index;
                const row = &self.rows[index];
                if (layer == .block and row.emitters != 0) self.seedRow(layer, index);
                if (layer == .sky) {
                    if (row.sky_source != 0 and row.sky_source != std.math.maxInt(u16)) self.seedRow(layer, index);
                    if (index + self.plane >= count) self.skyBoundary(index);
                }
                inline for (0..4) |direction| edge: {
                    if (column.adjacent[direction] == none) break :edge;
                    const next = base + column.adjacent[direction];
                    if (column.retained & (1 << direction) != 0) {
                        self.seedPair(layer, index, next, @fromBackingInt(@intCast(direction)));
                    } else if (layer == .sky and direction & 1 != 0) {
                        self.seedSky(index, next, row.sky_source);
                        self.seedSky(next, index, self.rows[next].sky_source);
                    }
                }
                if (layer == .sky and index + self.plane < count) {
                    const above = index + self.plane;
                    self.seedSky(index, above, row.sky_source);
                    self.seedSky(above, index, self.rows[above].sky_source);
                }
            }
        }
    }

    inline fn seedPair(self: *Engine, comptime layer: Layer, from: usize, to: usize, comptime direction: Direction) void {
        if (layer == .sky and (from < self.sky_start or to < self.sky_start)) return;
        const a = &self.rows[from];
        const b = &self.rows[to];
        const forward = a.light[@backingInt(layer)];
        const backward = b.light[@backingInt(layer)];
        if (direction == .west or direction == .east) {
            const x = if (direction == .east) lanes - 1 else 0;
            const next_x = lanes - 1 - x;
            if (forward[x] -| b.attenuation[next_x] > backward[next_x]) self.seedRow(layer, from);
            if (backward[next_x] -| a.attenuation[x] > forward[x]) self.seedRow(layer, to);
        } else {
            if (@reduce(.Or, forward -| b.attenuation > backward)) self.seedRow(layer, from);
            if (@reduce(.Or, backward -| a.attenuation > forward)) self.seedRow(layer, to);
        }
    }

    fn materialize(self: *Engine) void {
        if (!self.uniform_air and !self.block_zero and self.sky_start == self.minimum and self.air_start == self.rows.len) return;
        for (self.rows[self.minimum..], self.blocks[self.minimum..], self.minimum..) |*row, *block, index| {
            if (self.uniform_air or index >= self.air_start) {
                block.state = @splat(0);
                block.emission = @splat(0);
                row.attenuation = @splat(1);
                row.shaped = 0;
                row.emitters = 0;
                row.transparent = std.math.maxInt(u16);
                row.blocked_horizontal = .{ 0, 0 };
                row.edges_dirty = false;
                row.sky_source = if (self.skylight) std.math.maxInt(u16) else 0;
                row.light[1] = @splat(if (self.skylight) 15 else 0);
            } else if (index < self.sky_start or !self.skylight) {
                row.sky_source = 0;
                row.light[1] = @splat(0);
            }
            if (self.block_zero or index >= self.air_start) row.light[0] = @splat(0);
        }
        self.uniform_air = false;
        self.block_zero = false;
        self.sky_start = self.minimum;
        self.air_start = self.rows.len;
    }

    inline fn directSource(self: *Engine, at: usize, upstream: u16) u16 {
        self.work.source_rows += 1;
        const row = &self.rows[at];
        var source = upstream & row.transparent;
        const above: u32 = if (row.boundary & 32 == 0 and at + self.plane < self.air_start) @intCast(at + self.plane) else none;
        var shapes = source & (row.shaped | (if (above != none) self.rows[above].shaped else 0));
        while (shapes != 0) {
            const x: u4 = @intCast(@ctz(shapes));
            shapes &= shapes - 1;
            self.work.shape_checks += 1;
            if (self.registry.blocked(if (above != none) self.blocks[above].state[x] else 0, self.blocks[at].state[x], .down)) source &= ~(@as(u16, 1) << x);
        }
        return source;
    }

    fn seedSky(self: *Engine, from: usize, to: usize, source: u16) void {
        if (to < self.sky_start) return;
        const target = &self.rows[to];
        const needed = source & ~target.sky_source;
        if (needed == 0) return;
        const transmitting: u16 = @bitCast(target.attenuation < @as(Levels, @splat(15)));
        if (needed & transmitting == 0) return;
        self.seedRow(.sky, from);
    }

    fn skyBoundary(self: *Engine, at: usize) void {
        assert(self.rows[at].boundary & 32 != 0 or at + self.plane >= self.air_start);
        const row = &self.rows[at];
        const old = row.light[1];
        const next = @as(Levels, @splat(15)) -| row.attenuation;
        var improved: u16 = @bitCast(next > old);
        var shapes = improved & row.shaped;
        while (shapes != 0) {
            const x: usize = @ctz(shapes);
            shapes &= shapes - 1;
            self.work.shape_checks += 1;
            if (self.registry.blocked(0, self.blocks[at].state[x], .down)) improved &= ~(@as(u16, 1) << @intCast(x));
        }
        if (improved == 0) return;
        const admitted = @select(u8, @as(@Vector(lanes, bool), @bitCast(improved)), next, @as(Levels, @splat(0)));
        row.light[1] = @max(old, admitted);
        const maximum = @reduce(.Max, admitted);
        if (maximum > 1) self.enqueue(@intCast(at), maximum, improved);
    }

    fn sourceColumn(self: *Engine, bounds: SourceBounds) void {
        const plane = self.dimensions.x / lanes * self.dimensions.z;
        assert(bounds.lowest <= bounds.highest and bounds.highest < self.rows.len);
        var at: usize = bounds.highest;
        const above = self.neighbours(at)[5];
        var source = if (above != none) self.rows[above].sky_source else std.math.maxInt(u16);
        while (true) {
            const row = &self.rows[at];
            source = self.directSource(at, source);
            // A changed downward face can affect the row below an unchanged sky source.
            if (at < bounds.lowest and source == row.sky_source) break;
            const lost = row.sky_source & ~source;
            const added = source & ~row.sky_source;
            row.sky_source = source;
            self.removeMask(.sky, at, lost);
            if (added != 0) {
                row.light[1] = @max(row.light[1], @select(u8, @as(@Vector(lanes, bool), @bitCast(source)), @as(Levels, @splat(15)), @as(Levels, @splat(0))));
                self.enqueue(@intCast(at), 15, added);
            }
            if (at < self.minimum + plane) break;
            at -= plane;
        }
    }

    /// Applies the final state of each cell against a settled light field.
    /// The batch is bounded by batch_max. No allocation or IO occurs.
    pub fn update(self: *Engine, edits: []const Edit) !void {
        if (self.origin[0] == 0 and self.origin[1] == 0) return self.updatePhysical(edits);
        if (edits.len > batch_max) return error.BatchTooLarge;
        var translated: [batch_max]Edit = undefined;
        for (edits, translated[0..edits.len]) |edit, *value| {
            if (edit.index >= self.dimensions.volume()) return error.InvalidEdit;
            value.* = .{ .index = self.physicalRow(edit.index / lanes) * lanes + edit.index % lanes, .state = edit.state };
        }
        return self.updatePhysical(translated[0..edits.len]);
    }

    fn updatePhysical(self: *Engine, edits: []const Edit) !void {
        assert(self.lit and self.highest == 0 and self.source_count == 0 and self.restore_count == 0);
        if (edits.len > batch_max) return error.BatchTooLarge;
        if (edits.len <= 1) {
            for (edits) |edit| {
                if (edit.index >= self.dimensions.volume() or edit.index / lanes < self.minimum or edit.state >= self.registry.states.len) return error.InvalidEdit;
            }
        }
        const prepared: PreparedEdits = if (edits.len > 1) try self.prepareEdits(edits) else .{ .count = edits.len, .indirect = false };
        assert(prepared.count <= edits.len);
        assert(prepared.count != 0 or edits.len == 0);
        self.work = .{};
        if (prepared.count == 0) return;
        if (self.uniform_air) {
            var changed = false;
            for (0..prepared.count) |position| {
                changed = changed or edits[if (prepared.indirect) self.edit_order[position] else position].state != 0;
            }
            if (!changed) return;
        }
        self.materialize();
        const changes = &self.changes;
        var count: usize = 0;
        for (0..prepared.count) |position| {
            const edit = edits[if (prepared.indirect) self.edit_order[position] else position];
            const row = &self.rows[edit.index / lanes];
            const block = &self.blocks[edit.index / lanes];
            const x = edit.index % lanes;
            const old = self.registry.states[block.state[x]];
            const next = self.registry.states[edit.state];
            block.state[x] = edit.state;
            if (std.meta.eql(old, next)) continue;
            const faces_changed = !std.meta.eql(old.faces, next.faces);
            if (faces_changed) row.edges_dirty = true;
            const geometry = old.opacity != next.opacity or faces_changed;
            const old_cost = @max(1, old.opacity);
            const next_cost = @max(1, next.opacity);
            const light = self.getPhysical(.block, edit.index);
            const emission_changed = old.emission != next.emission;
            // Darkening restores the updated emission if another edit removes its stronger support.
            const affects_emission = emission_changed and (next.emission > light or (next.emission < old.emission and old.emission >= light));
            const affects_block = old_cost != next_cost or faces_changed or affects_emission;
            const affects_sky = geometry and self.skylight;
            const dimming = next_cost > old_cost or next.emission < old.emission or faces_changed;
            const supported = next.emission >= light and !faces_changed;
            if (affects_block or affects_sky) {
                changes[count] = .{ .index = edit.index, .block = affects_block, .sky = affects_sky, .block_decrease = dimming and !supported };
                count += 1;
            }
            if (affects_sky) {
                const at = edit.index / lanes;
                const column = at % self.source_bounds.len;
                const bounds = &self.source_bounds[column];
                if (bounds.highest == none) {
                    assert(self.source_count < self.source_columns.len);
                    self.source_columns[self.source_count] = @intCast(column);
                    self.source_count += 1;
                    bounds.highest = @intCast(at);
                } else bounds.highest = @max(bounds.highest, @as(u32, @intCast(at)));
                bounds.lowest = @min(bounds.lowest, @as(u32, @intCast(at)));
            }
            const bit = @as(u16, 1) << @intCast(x);
            if (emission_changed) {
                self.emitter_count += @intFromBool(old.emission == 0 and next.emission != 0);
                self.emitter_count -= @intFromBool(old.emission != 0 and next.emission == 0);
                var emission: [lanes]u8 = block.emission;
                emission[x] = next.emission;
                block.emission = emission;
                row.emitters &= ~bit;
                if (next.emission != 0) row.emitters |= bit;
            }
            if (old.opacity != next.opacity) {
                var attenuation: [lanes]u8 = row.attenuation;
                attenuation[x] = next_cost;
                row.attenuation = attenuation;
                row.transparent &= ~bit;
                if (next.opacity == 0) row.transparent |= bit;
            }
            if (faces_changed) {
                row.shaped &= ~bit;
                for (next.faces) |face| if (face != 0) {
                    row.shaped |= bit;
                    break;
                };
            }
        }
        if (count == 0) return;
        for (changes[0..count]) |change| {
            const row = &self.rows[change.index / lanes];
            if (row.edges_dirty) self.prepareEdges(change.index / lanes);
        }
        inline for ([_]Layer{ .block, .sky }) |layer| {
            for (changes[0..count]) |change| {
                if (!(if (layer == .block) change.block else change.sky)) continue;
                if (layer == .sky or change.block_decrease)
                    self.removeMask(layer, change.index / lanes, @as(u16, 1) << @intCast(change.index % lanes));
                self.seedNeighbours(layer, change.index);
            }
            if (layer == .sky) {
                for (self.source_columns[0..self.source_count]) |column| {
                    self.sourceColumn(self.source_bounds[column]);
                    self.source_bounds[column] = .{};
                }
                self.source_count = 0;
            }
            self.darken(layer);
            for (self.restore_rows[0..self.restore_count]) |at| {
                self.restoreRow(layer, at);
                self.rows[at].restore_queued = false;
            }
            self.restore_count = 0;
            for (changes[0..count]) |change| {
                if (if (layer == .block) change.block else change.sky) self.restoreSource(layer, change.index);
            }
            self.propagate(layer);
        }
        assert(self.source_count == 0 and self.highest == 0 and self.decrease_count == 0 and self.restore_count == 0);
    }

    fn prepareEdits(self: *Engine, edits: []const Edit) !PreparedEdits {
        assert(edits.len > 1 and edits.len <= batch_max);
        var variation: usize = 0;
        var ordered = true;
        var repeated = false;
        for (edits, 0..) |edit, i| {
            if (edit.index >= self.dimensions.volume() or edit.index / lanes < self.minimum or edit.state >= self.registry.states.len) return error.InvalidEdit;
            variation |= edit.index ^ edits[0].index;
            if (i != 0) {
                if (edit.index < edits[i - 1].index) ordered = false;
                if (edit.index == edits[i - 1].index) repeated = true;
            }
        }
        if (ordered and !repeated) return .{ .count = edits.len, .indirect = false };
        if (variation == 0) {
            self.edit_order[0] = @intCast(edits.len - 1);
            return .{ .count = 1, .indirect = true };
        }
        for (0..edits.len) |i| self.edit_order[i] = @intCast(i);
        if (!ordered and edits.len <= 16) {
            std.sort.insertion(EditIndex, self.edit_order[0..edits.len], edits, editLess);
            ordered = true;
        }
        var source = &self.edit_order;
        var target = &self.edit_scratch;
        var shift: std.math.Log2Int(usize) = 0;
        while (!ordered and variation != 0) {
            if (variation & (self.edit_counts.len - 1) != 0) {
                @memset(&self.edit_counts, 0);
                for (source[0..edits.len]) |index| {
                    const digit: EditDigit = @truncate(edits[index].index >> shift);
                    self.edit_counts[digit] += 1;
                }
                var offset: u16 = 0;
                for (&self.edit_counts) |*count| {
                    const next = offset + count.*;
                    count.* = offset;
                    offset = next;
                }
                assert(offset == edits.len);
                for (source[0..edits.len]) |index| {
                    const digit: EditDigit = @truncate(edits[index].index >> shift);
                    target[self.edit_counts[digit]] = index;
                    self.edit_counts[digit] += 1;
                }
                std.mem.swap(*[batch_max]EditIndex, &source, &target);
            }
            variation >>= @bitSizeOf(EditDigit);
            if (variation != 0) shift += @bitSizeOf(EditDigit);
        }
        var count: usize = 0;
        for (source[0..edits.len], 0..) |index, i| {
            if (i + 1 < edits.len and edits[index].index == edits[source[i + 1]].index) continue;
            self.edit_order[count] = index;
            count += 1;
        }
        assert(count > 0 and count <= edits.len);
        return .{ .count = count, .indirect = true };
    }

    /// The physical column of a row. One widening multiply replaces a division by the
    /// runtime plane size, exact while the row index times the plane fits 64 bits.
    inline fn columnOf(self: *const Engine, index: usize) usize {
        if (self.plane == 1) return 0;
        const quotient: usize = @intCast((@as(u128, index) * self.reciprocal) >> 64);
        return index - quotient * self.plane;
    }

    inline fn neighbours(self: *const Engine, index: usize) [6]u32 {
        const at: u32 = @intCast(index);
        const boundary = if (self.origin[0] == 0 and self.origin[1] == 0) self.rows[index].boundary else (self.rows[index].boundary & 48) | (self.horizontal[self.columnOf(index)] & 15);
        return .{
            if (boundary & 1 != 0) none else if (self.rows[index].boundary & 1 != 0) at + self.stride - 1 else at - 1,
            if (boundary & 2 != 0) none else if (self.rows[index].boundary & 2 != 0) at + 1 - self.stride else at + 1,
            if (boundary & 4 != 0) none else if (self.rows[index].boundary & 4 != 0) at + self.plane - self.stride else at - self.stride,
            if (boundary & 8 != 0) none else if (self.rows[index].boundary & 8 != 0) at + self.stride - self.plane else at + self.stride,
            if (at >= self.minimum + self.plane) at - self.plane else none,
            if (boundary & 32 == 0 and at + self.plane < self.air_start) at + self.plane else none,
        };
    }

    fn seedRow(self: *Engine, comptime layer: Layer, row: usize) void {
        const value = self.rows[row].light[@backingInt(layer)];
        const maximum = @reduce(.Max, value);
        if (maximum > 1) self.enqueue(@intCast(row), maximum, @bitCast(value > @as(Levels, @splat(1))));
    }

    fn seedNeighbours(self: *Engine, comptime layer: Layer, index: usize) void {
        const at = index / lanes;
        const adjacent = self.neighbours(at);
        if (index % lanes == 0 and adjacent[0] != none) self.seedRow(layer, adjacent[0]);
        self.seedRow(layer, at);
        if (index % lanes == lanes - 1 and adjacent[1] != none) self.seedRow(layer, adjacent[1]);
        inline for (2..6) |direction| if (adjacent[direction] != none) self.seedRow(layer, adjacent[direction]);
    }

    inline fn removeMask(self: *Engine, comptime layer: Layer, at: usize, mask: u16) void {
        const row = &self.rows[at];
        const value = row.light[@backingInt(layer)];
        const nonzero: u16 = @bitCast(value > @as(Levels, @splat(0)));
        const affected = mask & nonzero;
        if (affected == 0) return;
        self.removeActive(layer, at, affected, value);
    }

    fn removeActive(self: *Engine, comptime layer: Layer, at: usize, affected: u16, value: Levels) void {
        assert(affected != 0);
        const row = &self.rows[at];
        const selected: @Vector(lanes, bool) = @bitCast(affected);
        self.decreases[at] = @max(self.decreases[at], @select(u8, selected, value, @as(Levels, @splat(0))));
        row.light[@backingInt(layer)] = @select(u8, selected, @as(Levels, @splat(0)), value);
        const restore = if (layer == .block) row.emitters != 0 else row.boundary & 32 != 0;
        if (restore and !row.restore_queued) {
            assert(self.restore_count < self.restore_rows.len);
            self.restore_rows[self.restore_count] = @intCast(at);
            self.restore_count += 1;
            row.restore_queued = true;
        }
        const pending = &self.links[at];
        if (pending.level != 0) {
            pending.mask &= ~affected;
            if (pending.mask == 0) {
                self.unlink(@intCast(at));
                self.work.cancelled_rows += 1;
            }
        }
        if (!self.decrease_queued[at]) {
            assert(self.decrease_count < self.decrease_queue.len);
            self.decrease_queue[self.decrease_tail] = @intCast(at);
            self.decrease_tail += 1;
            if (self.decrease_tail == self.decrease_queue.len) self.decrease_tail = 0;
            self.decrease_queued[at] = true;
            self.decrease_count += 1;
        }
        self.work.removed_cells += @popCount(affected);
    }

    fn darken(self: *Engine, comptime layer: Layer) void {
        while (self.decrease_count != 0) {
            const at: usize = self.decrease_queue[self.decrease_head];
            self.decrease_head += 1;
            if (self.decrease_head == self.decrease_queue.len) self.decrease_head = 0;
            self.decrease_count -= 1;
            self.work.darkened_rows += 1;
            const row = &self.rows[at];
            const reached = horizontalRemoval(self.decreases[at], row.light[@backingInt(layer)]);
            self.removeMask(layer, at, reached);
            // Queue survivors while this row is hot. Increases wait for all decreases.
            self.seedRow(layer, at);
            self.decrease_queued[at] = false;
            const value = self.decreases[at];
            self.decreases[at] = @splat(0);
            const adjacent = self.neighbours(at);
            if (adjacent[0] != none and value[0] != 0) {
                var edge: Levels = @splat(0);
                edge[lanes - 1] = value[0];
                self.decreaseTo(layer, adjacent[0], edge);
            }
            if (adjacent[1] != none and value[lanes - 1] != 0) {
                var edge: Levels = @splat(0);
                edge[0] = value[lanes - 1];
                self.decreaseTo(layer, adjacent[1], edge);
            }
            inline for (2..6) |direction| if (adjacent[direction] != none) self.decreaseTo(layer, adjacent[direction], value);
        }
        assert(self.decrease_head == self.decrease_tail);
    }

    fn decreaseTo(self: *Engine, comptime layer: Layer, at: usize, source: Levels) void {
        const value = self.rows[at].light[@backingInt(layer)];
        self.removeMask(layer, at, @bitCast(value < source));
        const boundary = (value >= source) & (source > @as(Levels, @splat(0))) & (value > @as(Levels, @splat(1)));
        const mask: u16 = @bitCast(boundary);
        if (mask == 0) return;
        const maximum = @reduce(.Max, @select(u8, boundary, value, @as(Levels, @splat(0))));
        self.enqueue(@intCast(at), maximum, mask);
    }

    fn restoreRow(self: *Engine, comptime layer: Layer, at: usize) void {
        self.work.restored_rows += 1;
        const row = &self.rows[at];
        assert(row.restore_queued);
        assert(if (layer == .block) row.emitters != 0 else row.boundary & 32 != 0);
        const source = if (layer == .block) self.blocks[at].emission else @select(u8, @as(@Vector(lanes, bool), @bitCast(row.sky_source)), @as(Levels, @splat(15)), @as(Levels, @splat(0)));
        row.light[@backingInt(layer)] = @max(row.light[@backingInt(layer)], source);
        if (layer == .sky and row.boundary & 32 != 0) self.skyBoundary(at);
        self.seedRow(layer, at);
    }

    fn restoreSource(self: *Engine, comptime layer: Layer, index: usize) void {
        const row = &self.rows[index / lanes];
        const state = self.blocks[index / lanes].state[index % lanes];
        const x = index % lanes;
        var source = if (layer == .block) self.registry.states[state].emission else @as(u8, if (row.sky_source & (@as(u16, 1) << @intCast(x)) != 0) 15 else 0);
        const plane = self.dimensions.x * self.dimensions.z;
        if (layer == .sky and self.skylight and index >= self.dimensions.volume() - plane and !self.registry.blocked(0, state, .down))
            source = @max(source, 15 -| @max(1, self.registry.states[state].opacity));
        var light: [lanes]u8 = row.light[@backingInt(layer)];
        if (light[x] >= source) return;
        light[x] = @max(light[x], source);
        row.light[@backingInt(layer)] = light;
        self.seedRow(layer, index / lanes);
    }

    fn enqueue(self: *Engine, index: u32, level: u8, mask: u16) void {
        assert(level > 1 and level <= 15 and index < self.rows.len);
        assert(mask != 0);
        const link = &self.links[index];
        const pending = link.mask | mask;
        if (link.level >= level) {
            link.mask = pending;
            return;
        }
        if (link.level != 0) self.unlink(index);
        link.* = .{ .level = level, .next = self.heads[level], .mask = pending };
        if (link.next != none) self.links[link.next].previous = index;
        self.heads[level] = index;
        if (level > self.highest) self.highest = level;
    }

    fn unlink(self: *Engine, index: u32) void {
        const link = &self.links[index];
        assert(link.level > 1);
        if (link.previous == none) self.heads[link.level] = link.next else self.links[link.previous].next = link.next;
        if (link.next != none) self.links[link.next].previous = link.previous;
        link.* = .{};
    }

    fn propagate(self: *Engine, comptime layer: Layer) void {
        while (self.highest != 0) {
            const level = self.highest;
            const index = self.heads[level];
            if (index == none) {
                self.highest -= 1;
                continue;
            }
            const link = &self.links[index];
            assert(link.level == level);
            self.heads[level] = link.next;
            if (link.next != none) self.links[link.next].previous = none;
            const mask = link.mask;
            link.* = .{};
            const live = mask & @as(u16, @bitCast(self.rows[index].light[@backingInt(layer)] > @as(Levels, @splat(1))));
            if (live == 0) continue;
            self.work.propagated_rows += 1;
            const at: usize = index;
            const adjacent = self.neighbours(at);
            const row = &self.rows[at];
            const old = row.light[@backingInt(layer)];
            const value = horizontalIncrease(old, row.attenuation, row.blocked_horizontal);
            const changed: u16 = @bitCast(value > old);
            self.work.changed_cells += @popCount(changed);
            row.light[@backingInt(layer)] = value;
            const light = @select(u8, @as(@Vector(lanes, bool), @bitCast(live | changed)), value, @as(Levels, @splat(0)));
            if (adjacent[0] != none and light[0] > 1) {
                var edge: Levels = @splat(0);
                edge[lanes - 1] = light[0];
                self.spread(layer, at, adjacent[0], .west, edge);
            }
            if (adjacent[1] != none and light[lanes - 1] > 1) {
                var edge: Levels = @splat(0);
                edge[0] = light[lanes - 1];
                self.spread(layer, at, adjacent[1], .east, edge);
            }
            inline for (2..6) |direction| if (adjacent[direction] != none)
                self.spread(layer, at, adjacent[direction], @fromBackingInt(@intCast(direction)), light);
        }
        assert(std.mem.allEqual(u32, &self.heads, none));
    }

    inline fn prepareEdges(self: *Engine, at: usize) void {
        const row = &self.rows[at];
        row.blocked_horizontal = .{ 0, 0 };
        var pairs = (row.shaped | (row.shaped << 1)) & 0xfffe;
        while (pairs != 0) {
            const x: u4 = @intCast(@ctz(pairs));
            pairs &= pairs - 1;
            if (self.registry.blocked(self.blocks[at].state[x - 1], self.blocks[at].state[x], .east)) row.blocked_horizontal[1] |= @as(u16, 1) << x;
            if (self.registry.blocked(self.blocks[at].state[x], self.blocks[at].state[x - 1], .west)) row.blocked_horizontal[0] |= @as(u16, 1) << (x - 1);
            self.work.shape_checks += 2;
        }
        row.edges_dirty = false;
    }

    fn spread(self: *Engine, comptime layer: Layer, from: usize, to: usize, comptime direction: Direction, source: Levels) void {
        if (layer == .sky and to < self.sky_start) return;
        self.work.candidate_rows += 1;
        const target = &self.rows[to];
        if (direction == .west or direction == .east) {
            const x = if (direction == .west) lanes - 1 else 0;
            const source_x = lanes - 1 - x;
            const next = source[x] -| target.attenuation[x];
            if (next <= target.light[@backingInt(layer)][x]) return;
            const mask = @as(u16, 1) << x;
            if ((self.rows[from].shaped & (@as(u16, 1) << source_x)) != 0 or (target.shaped & mask) != 0) {
                self.work.shape_checks += 1;
                if (self.registry.blocked(self.blocks[from].state[source_x], self.blocks[to].state[x], direction)) return;
            }
            self.work.changed_cells += 1;
            target.light[@backingInt(layer)][x] = next;
            if (next > 1) self.enqueue(@intCast(to), next, mask);
            return;
        }
        const old = target.light[@backingInt(layer)];
        const next = source -| target.attenuation;
        var improved: u16 = @bitCast(next > old);
        if (improved == 0) return;
        var bits = improved & (self.rows[from].shaped | target.shaped);
        while (bits != 0) {
            const x: usize = @ctz(bits);
            bits &= bits - 1;
            self.work.shape_checks += 1;
            if (self.registry.blocked(self.blocks[from].state[x], self.blocks[to].state[x], direction)) {
                improved &= ~(@as(u16, 1) << @intCast(x));
            }
        }
        if (improved == 0) return;
        self.work.changed_cells += @popCount(improved);
        const admitted = @select(u8, @as(@Vector(lanes, bool), @bitCast(improved)), next, @as(Levels, @splat(0)));
        target.light[@backingInt(layer)] = @max(admitted, old);
        const maximum = @reduce(.Max, admitted);
        if (maximum > 1) self.enqueue(@intCast(to), maximum, improved);
    }

    pub fn get(self: *const Engine, layer: Layer, index: usize) u4 {
        assert(index < self.dimensions.volume());
        return self.getPhysical(layer, self.physicalRow(index / lanes) * lanes + index % lanes);
    }

    fn physicalRow(self: *const Engine, index: usize) usize {
        if (self.origin[0] == 0 and self.origin[1] == 0) return index;
        return index / self.plane * self.plane +
            (index % self.plane / self.stride + self.origin[1]) % self.dimensions.z * self.stride +
            (index % self.stride + self.origin[0]) % self.stride;
    }

    fn getPhysical(self: *const Engine, layer: Layer, index: usize) u4 {
        assert(self.lit and index < self.dimensions.volume() and index / lanes >= self.minimum);
        if (layer == .block and self.block_zero) return 0;
        if (layer == .sky and (!self.skylight or index / lanes < self.sky_start)) return 0;
        if (self.uniform_air or index / lanes >= self.air_start) return if (layer == .sky and self.skylight) 15 else 0;
        const values: [lanes]u8 = self.rows[index / lanes].light[@backingInt(layer)];
        return @intCast(values[index % lanes]);
    }

    pub fn blockState(self: *const Engine, index: usize) u16 {
        assert(self.loaded and index < self.dimensions.volume() and index / lanes >= self.minimum);
        if (self.uniform_air or index / lanes >= self.air_start) return 0;
        return self.blocks[self.physicalRow(index / lanes)].state[index % lanes];
    }

    pub fn pack(self: *const Engine, layer: Layer, output: []u8) void {
        assert(self.lit and output.len == self.dimensions.volume() / 2);
        if (self.uniform_air or (layer == .block and self.block_zero) or (layer == .sky and !self.skylight)) {
            @memset(output, if (self.uniform_air and layer == .sky and self.skylight) 255 else 0);
            @memset(output[0 .. self.minimum * 8], 0);
            return;
        }
        const even = [8]i32{ 0, 2, 4, 6, 8, 10, 12, 14 };
        const odd = [8]i32{ 1, 3, 5, 7, 9, 11, 13, 15 };
        const begin = if (layer == .sky) self.sky_start else self.minimum;
        @memset(output[0 .. begin * 8], 0);
        @memset(output[self.air_start * 8 ..], if (layer == .sky) 255 else 0);
        for (begin..self.air_start) |index| {
            const value = self.rows[self.physicalRow(index)].light[@backingInt(layer)];
            const low = @shuffle(u8, value, undefined, even);
            const high = @shuffle(u8, value, undefined, odd);
            output[index * 8 ..][0..8].* = low | (high << @splat(4));
        }
    }

    /// Null means the solve bounds do not prove a uniform section.
    pub fn sectionUniform(self: *const Engine, layer: Layer, section: [3]usize) ?u4 {
        assert(self.lit);
        assert(section[0] < self.dimensions.x / 16 and section[1] < self.dimensions.y / 16 and section[2] < self.dimensions.z / 16);
        if (section[1] * 16 * self.plane < self.minimum) return 0;
        if (layer == .block and self.block_zero) return 0;
        if (layer == .sky and !self.skylight) return 0;
        if (self.uniform_air) return if (layer == .sky and self.skylight) 15 else 0;
        if (section[1] * 16 * self.plane >= self.air_start) return if (layer == .sky) 15 else 0;
        if (layer == .sky and (section[1] + 1) * 16 * self.plane <= self.sky_start) return 0;
        return null;
    }

    pub fn sectionNonempty(self: *const Engine, layer: Layer, section: [3]usize) bool {
        assert(self.lit);
        assert(section[0] < self.dimensions.x / 16 and section[1] < self.dimensions.y / 16 and section[2] < self.dimensions.z / 16);
        if (section[1] * 16 * self.plane < self.minimum) return false;
        if (layer == .block and self.block_zero) return false;
        if (layer == .sky and !self.skylight) return false;
        if (self.uniform_air) return layer == .sky and self.skylight;
        if (section[1] * 16 * self.plane >= self.air_start) return layer == .sky;
        if (layer == .sky and (section[1] + 1) * 16 * self.plane <= self.sky_start) return false;
        const stride = self.dimensions.x / lanes;
        const plane = stride * self.dimensions.z;
        const column_x = (section[0] + self.origin[0]) % stride;
        const column_z = (section[2] * 16 + self.origin[1]) % self.dimensions.z;
        for (0..16) |y| for (0..16) |z| {
            const index = (section[1] * 16 + y) * plane + (column_z + z) * stride + column_x;
            if (layer == .sky and index < self.sky_start) continue;
            if (index >= self.air_start) {
                if (layer == .sky) return true;
                continue;
            }
            if (@reduce(.Or, self.rows[index].light[@backingInt(layer)] != @as(Levels, @splat(0)))) return true;
        };
        return false;
    }

    pub fn packSection(self: *const Engine, layer: Layer, section: [3]usize, output: *[2048]u8) void {
        assert(self.lit);
        assert(section[0] < self.dimensions.x / 16 and section[1] < self.dimensions.y / 16 and section[2] < self.dimensions.z / 16);
        if (section[1] * 16 * self.plane < self.minimum) {
            @memset(output, 0);
            return;
        }
        if (self.uniform_air or (layer == .block and self.block_zero) or (layer == .sky and !self.skylight)) {
            @memset(output, if (self.uniform_air and layer == .sky and self.skylight) 255 else 0);
            return;
        }
        if (section[1] * 16 * self.plane >= self.air_start) {
            @memset(output, if (layer == .sky) 255 else 0);
            return;
        }
        if (layer == .sky and (section[1] + 1) * 16 * self.plane <= self.sky_start) {
            @memset(output, 0);
            return;
        }
        const stride = self.dimensions.x / lanes;
        const plane = stride * self.dimensions.z;
        const even = [8]i32{ 0, 2, 4, 6, 8, 10, 12, 14 };
        const odd = [8]i32{ 1, 3, 5, 7, 9, 11, 13, 15 };
        const column_x = (section[0] + self.origin[0]) % stride;
        const column_z = (section[2] * 16 + self.origin[1]) % self.dimensions.z;
        for (0..16) |y| for (0..16) |z| {
            const index = (section[1] * 16 + y) * plane + (column_z + z) * stride + column_x;
            const value = if (layer == .sky and index < self.sky_start) @as(Levels, @splat(0)) else if (index >= self.air_start) @as(Levels, @splat(if (layer == .sky) 15 else 0)) else self.rows[index].light[@backingInt(layer)];
            output[(y * 16 + z) * 8 ..][0..8].* = @shuffle(u8, value, undefined, even) | (@shuffle(u8, value, undefined, odd) << @splat(4));
        };
    }
};

test "scrolling settled light agrees with fresh solves through reversals and diagonal movement" {
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 0, 1, 0, 1, 0 } },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 2, .occlusion = &.{ 0, 0, 0, 1 } };
    const dimensions: Dimensions = .{ .x = 48, .y = 48, .z = 48 };
    const Scene = struct {
        fn fill(blocks: []u16, origin: [2]i32, mode: usize) void {
            for (blocks, 0..) |*state, index| {
                const x = origin[0] + @as(i32, @intCast(index % 48));
                const y = index / (48 * 48);
                const z = origin[1] + @as(i32, @intCast(index / 48 % 48));
                state.* = switch (mode) {
                    0 => 0,
                    1 => if (y == 15 and @mod(x, 23) == 0 and @mod(z, 19) == 0) 4 else 0,
                    2 => if (y == 15 and @mod(x, 23) == 0 and @mod(z, 19) == 0) 4 else if (y < 8 or (y == 24 and @mod(x, 17) != 0)) 1 else if (y < 24 and @mod(x * 31 + z * 17, 13) < 3) 1 else if (y == 25 and @mod(x + z, 11) == 0) 2 else if (y == 8 and @mod(x - z, 7) == 0) 3 else 0,
                    3 => if (x == 8 and z == 8 and y == 40) 4 else if (y < 3 or (x < 16 and y < 32)) 1 else 0,
                    4 => if (x == 8 and z == 8 and y == 6) 2 else if (x == 8 and z == 8 and y == 7) 3 else 0,
                    5 => if (y < @as(usize, if (x < 32) 8 else 24)) 1 else 0,
                    // An emitter on a wall lights the low side only through rows the next window drops.
                    // A second emitter keeps block light active after the wall leaves.
                    6 => if (x == 15 and y < 30) 1 else if (x == 15 and y == 30 and @mod(z, 5) == 0) 4 else if (@mod(x, 48) == 40 and y == 8 and @mod(z, 48) == 8) 4 else if (y < 6) 1 else 0,
                    else => unreachable,
                };
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var engine = try Engine.init(allocator, dimensions, registry);
    var fresh = try Engine.init(allocator, dimensions, registry);
    const blocks = try allocator.alloc(u16, dimensions.volume());
    const ring_blocks = try allocator.alloc(u16, blocks.len);
    const expected = try allocator.alloc(u8, blocks.len);
    const packed_actual = try allocator.alloc(u8, blocks.len / 2);
    const packed_expected = try allocator.alloc(u8, blocks.len / 2);
    var section_actual: [2048]u8 = undefined;
    var section_expected: [2048]u8 = undefined;
    for (0..7) |mode| for ([_]bool{ false, true }) |skylight| {
        for (engine.rows) |*row| {
            row.light = .{ @splat(170), @splat(170) };
            row.sky_source = 0xaaaa;
        }
        var origin: [2]i32 = .{ 0, 0 };
        Scene.fill(blocks, origin, mode);
        try engine.load(.{ .dense = blocks });
        engine.relight(skylight);
        for ([_][2]i32{ .{ 16, 0 }, .{ 0, 16 }, .{ -16, 0 }, .{ 0, -16 }, .{ 16, 16 }, .{ -16, -16 }, .{ 32, 0 }, .{ -32, 0 }, .{ 0, 32 }, .{ 0, -32 } }, 0..) |offset, step| {
            origin[0] += offset[0];
            origin[1] += offset[1];
            Scene.fill(blocks, origin, mode);
            const ring_origin = [2]usize{ (step + 1) % 3, (step % 3) * 16 };
            for (blocks, 0..) |state, index| {
                const x = (index % 48 + ring_origin[0] * 16) % 48;
                const z = (index / 48 % 48 + ring_origin[1]) % 48;
                ring_blocks[index / (48 * 48) * 48 * 48 + z * 48 + x] = state;
            }
            const input: Blocks.Ring = if (step % 2 == 0) .{ .states = ring_blocks, .origin = ring_origin } else .{ .states = blocks, .origin = .{ 0, 0 } };
            try engine.scroll(offset, input);
            try fresh.load(.{ .dense = blocks });
            fresh.relight(skylight);
            for ([_]Layer{ .block, .sky }) |layer| {
                engine.pack(layer, packed_actual);
                fresh.pack(layer, packed_expected);
                try std.testing.expectEqualSlices(u8, packed_expected, packed_actual);
                for (0..27) |section| {
                    const at = [3]usize{ section % 3, section / 9, section / 3 % 3 };
                    engine.packSection(layer, at, &section_actual);
                    fresh.packSection(layer, at, &section_expected);
                    try std.testing.expectEqualSlices(u8, &section_expected, &section_actual);
                    try std.testing.expectEqual(fresh.sectionNonempty(layer, at), engine.sectionNonempty(layer, at));
                }
                if (step == 2) reference(dimensions, registry, blocks, layer, skylight, expected);
                for (blocks, 0..) |_, index| {
                    const actual = engine.get(layer, index);
                    if (layer == .block) try std.testing.expectEqual(blocks[index], engine.blockState(index));
                    const wanted = fresh.get(layer, index);
                    if (actual != wanted) {
                        std.debug.print("scroll mode={d} sky={} step={d} layer={s} index={d} actual={d} expected={d}\n", .{ mode, skylight, step, @tagName(layer), index, actual, wanted });
                        return error.TestUnexpectedResult;
                    }
                    if (step == 2) try std.testing.expectEqual(expected[index], actual);
                }
            }
            if (step == 3) {
                const cell = (47 * 48 + 16) * 48 + 16;
                const original = blocks[cell];
                for ([_]u16{ 4, original }) |state| {
                    try engine.update(&.{.{ .index = cell, .state = state }});
                    blocks[cell] = state;
                    try fresh.load(.{ .dense = blocks });
                    fresh.relight(skylight);
                    for ([_]Layer{ .block, .sky }) |layer| {
                        engine.pack(layer, packed_actual);
                        fresh.pack(layer, packed_expected);
                        try std.testing.expectEqualSlices(u8, packed_expected, packed_actual);
                    }
                }
            }
            if (step == 5) {
                try engine.load(.{ .ring = .{ .states = ring_blocks, .origin = ring_origin } });
                engine.relight(skylight);
                for ([_]Layer{ .block, .sky }) |layer| {
                    engine.pack(layer, packed_actual);
                    fresh.pack(layer, packed_expected);
                    try std.testing.expectEqualSlices(u8, packed_expected, packed_actual);
                }
            }
        }
    };
}

test "random scrolls over varied terrain agree with fresh solves" {
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 3, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 0, 1, 0, 1, 0 } },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 9, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 12, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 2, .occlusion = &.{ 0, 0, 0, 1 } };
    const dimensions: Dimensions = .{ .x = 48, .y = 96, .z = 48 };
    const Scene = struct {
        fn hash(a: i64, b: i64, c: i64, seed: u64) u64 {
            var value = seed ^ (@as(u64, @bitCast(a)) *% 0x9e3779b97f4a7c15);
            value = (value ^ (value >> 29)) *% 0xbf58476d1ce4e5b9 ^ (@as(u64, @bitCast(b)) *% 0xc2b2ae3d27d4eb4f);
            value = (value ^ (value >> 32)) *% 0x94d049bb133111eb ^ (@as(u64, @bitCast(c)) *% 0x165667b19e3779f9);
            return value ^ (value >> 31);
        }

        // Chunks differ in height, emitters and cover, so scrolls change the stored height,
        // gain and lose every emitter, and move opaque planes.
        fn state(x: i64, y: i64, z: i64, seed: u64) u16 {
            const chunk = hash(@divFloor(x, 16), @divFloor(z, 16), 0, seed);
            const kind = chunk % 6;
            if (kind == 0) return 0;
            const cell = hash(x, y, z, seed);
            const emitters = (chunk >> 8) % 3 != 0;
            if (kind == 3 and y == 60 + @as(i64, @intCast((chunk >> 16) % 8)) and @mod(x, 16) == @as(i64, @intCast((chunk >> 24) % 16)) and @mod(z, 5) == 0) return 5;
            const height: i64 = switch (kind) {
                1, 3 => 6 + @as(i64, @intCast(hash(x, 0, z, seed) % 5)),
                2 => 40 + @as(i64, @intCast(hash(@divFloor(x, 4), 0, @divFloor(z, 4), seed) % 30)),
                else => 20 + @as(i64, @intCast(hash(@divFloor(x, 2), 0, z, seed) % 6)),
            };
            if (y < 2) return 1;
            if (kind == 4 and y == 30) return if (cell % 23 == 0) 0 else 1;
            if (kind == 5 and y > height and y < height + 6) return if (cell % 7 == 0) 3 else 2;
            if (y > height) return if (emitters and cell % 997 == 0) 6 else 0;
            if (cell % 11 < 3) return if (cell % 13 == 0) 4 else 0;
            if (emitters and cell % 211 == 0) return if (cell % 2 == 0) 5 else 7;
            return 1;
        }

        fn fill(blocks: []u16, origin: [2]i64, seed: u64) void {
            for (blocks, 0..) |*block, index| {
                block.* = state(origin[0] + @as(i64, @intCast(index % 48)), @intCast(index / (48 * 48)), origin[1] + @as(i64, @intCast(index / 48 % 48)), seed);
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var engine = try Engine.init(allocator, dimensions, registry);
    var fresh = try Engine.init(allocator, dimensions, registry);
    const blocks = try allocator.alloc(u16, dimensions.volume());
    const ring_blocks = try allocator.alloc(u16, blocks.len);
    const actual = try allocator.alloc(u8, blocks.len / 2);
    const expected = try allocator.alloc(u8, blocks.len / 2);
    var random = std.Random.DefaultPrng.init(0x5c011);
    for ([_]u64{ 3, 17 }) |seed| for ([_]bool{ true, false }) |skylight| {
        var origin: [2]i64 = .{ 0, 0 };
        var ring_origin: [2]usize = .{ 0, 0 };
        Scene.fill(blocks, origin, seed);
        try engine.load(.{ .dense = blocks });
        engine.relight(skylight);
        for (0..28) |step| {
            var offset: [2]i32 = .{ 0, 0 };
            while (offset[0] == 0 and offset[1] == 0) {
                // Single chunk moves dominate, as they do while baking a frontier.
                const reach: i32 = if (random.random().uintLessThan(u8, 4) == 0) 2 else 1;
                offset = .{ random.random().intRangeAtMost(i32, -reach, reach) * 16, random.random().intRangeAtMost(i32, -reach, reach) * 16 };
            }
            origin[0] += offset[0];
            origin[1] += offset[1];
            Scene.fill(blocks, origin, seed);
            ring_origin = .{ random.random().uintLessThan(usize, 3), random.random().uintLessThan(usize, 3) * 16 };
            for (blocks, 0..) |block, index| {
                const x = (index % 48 + ring_origin[0] * 16) % 48;
                const z = (index / 48 % 48 + ring_origin[1]) % 48;
                ring_blocks[index / (48 * 48) * 48 * 48 + z * 48 + x] = block;
            }
            try engine.scroll(offset, .{ .states = ring_blocks, .origin = ring_origin });
            try fresh.load(.{ .dense = blocks });
            fresh.relight(skylight);
            try std.testing.expectEqual(fresh.block_zero, engine.block_zero);
            for ([_]Layer{ .block, .sky }) |layer| {
                engine.pack(layer, actual);
                fresh.pack(layer, expected);
                if (!std.mem.eql(u8, expected, actual)) {
                    const at = std.mem.indexOfDiff(u8, expected, actual).?;
                    std.debug.print("seed={d} sky={} step={d} offset={any} layer={s} byte={d} y={d} z={d} x={d}\n", .{ seed, skylight, step, offset, @tagName(layer), at, at / (24 * 48), at / 24 % 48, at % 24 * 2 });
                    return error.TestUnexpectedResult;
                }
            }
        }
    };
}

test "bounded lighting preserves visible values with hidden emitters and skylight above" {
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 0, 1, 0, 1, 0 } },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 2, .occlusion = &.{ 0, 0, 0, 1 } };
    const dimensions: Dimensions = .{ .x = 48, .y = 96, .z = 48 };
    const Scene = struct {
        fn fill(blocks: []u16, offset: i32) void {
            for (blocks, 0..) |*state, index| {
                const x = offset + @as(i32, @intCast(index % 48));
                const z = index / 48 % 48;
                const y = index / (48 * 48);
                state.* = if (y % 16 == 14 and @mod(x, 19) == 0 and z % 7 == 0) 4 else if (y < 4 or (y == 72 and @mod(x, 13) != 0)) 1 else if (y < 60 and @mod(x, 17) < 3 and z % 11 < 3) 1 else if (y == 73 and @mod(x, 7) == 0) 2 else if (y % 16 == 4 and @mod(x, 11) == 0) 3 else 0;
            }
        }
    };
    const blocks = try std.testing.allocator.alloc(u16, dimensions.volume());
    defer std.testing.allocator.free(blocks);
    var full = try Engine.init(std.testing.allocator, dimensions, registry);
    defer full.deinit();
    var partial = try Engine.init(std.testing.allocator, dimensions, registry);
    defer partial.deinit();
    var actual: [2048]u8 = undefined;
    var expected: [2048]u8 = undefined;
    for ([_]bool{ false, true }) |sky| for (0..5) |floor| {
        for ([_]i32{ 0, 16, 32, 16, 0 }, 0..) |offset, step| {
            Scene.fill(blocks, offset);
            const input: Blocks.Ring = .{ .states = blocks, .origin = .{ 0, 0 }, .minimum_y = floor * 16 };
            if (step == 0) {
                try partial.load(.{ .ring = input });
                partial.relight(sky);
            } else try partial.scroll(.{ if (step < 3) 16 else -16, 0 }, input);
            try full.load(.{ .dense = blocks });
            full.relight(sky);
            for ([_]Layer{ .block, .sky }) |layer| for (floor + 1..6) |section| {
                partial.packSection(layer, .{ 1, section, 1 }, &actual);
                full.packSection(layer, .{ 1, section, 1 }, &expected);
                try std.testing.expectEqualSlices(u8, &expected, &actual);
            };
            const cell = ((floor * 16 + 18) * 48 + 24) * 48 + 24;
            const original = blocks[cell];
            for ([_]u16{ 4, original }) |state| {
                const edits = [_]Edit{.{ .index = cell, .state = state }};
                try partial.update(&edits);
                try full.update(&edits);
                for ([_]Layer{ .block, .sky }) |layer| for (floor + 1..6) |section| {
                    partial.packSection(layer, .{ 1, section, 1 }, &actual);
                    full.packSection(layer, .{ 1, section, 1 }, &expected);
                    try std.testing.expectEqualSlices(u8, &expected, &actual);
                };
            }
        }
    };
}

test "a maximum batch preserves its last writes and ignores cancelled intermediate edits" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 14, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 1, .occlusion = &.{0} };
    const dimensions: Dimensions = .{ .x = 32, .y = 16, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, registry);
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    const expected = try allocator.alloc(u8, blocks.len);
    defer allocator.free(expected);
    @memset(blocks, 0);
    try engine.load(.{ .dense = blocks });
    engine.relight(true);
    var edits: [batch_max]Edit = undefined;
    for (&edits, 0..) |*edit, i| {
        const cell = i * 17 % 64;
        edit.* = .{ .index = cell * 127, .state = @intCast((i / 64 + cell) % states.len) };
        blocks[edit.index] = edit.state;
    }
    try engine.update(&edits);
    for ([_]Layer{ .block, .sky }) |layer| {
        reference(dimensions, registry, blocks, layer, true, expected);
        for (expected, 0..) |value, index| try std.testing.expectEqual(value, engine.get(layer, index));
    }
    try engine.update(&edits);
    try std.testing.expectEqual(@as(u64, 0), engine.work.propagated_rows);
    try std.testing.expectEqual(@as(u64, 0), engine.work.darkened_rows);
    edits[0].state = states.len;
    try std.testing.expectError(error.InvalidEdit, engine.update(&edits));
}

test "batched emission edits preserve dominated and repeated sources" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 7, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 3, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 1, .occlusion = &.{0} };
    const dimensions: Dimensions = .{ .x = 16, .y = 8, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, registry);
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    const expected = try allocator.alloc(u8, blocks.len);
    defer allocator.free(expected);
    const strong = (4 * 16 + 8) * 16 + 8;
    const weak = strong + 1;
    for ([_]u16{ 0, 2, 3 }) |state| {
        for ([_]bool{ false, true }) |reverse| {
            @memset(blocks, 0);
            blocks[strong] = 1;
            blocks[weak] = if (state == 2) 0 else 2;
            try engine.load(.{ .dense = blocks });
            engine.relight(false);
            var edits = [_]Edit{ .{ .index = weak, .state = state }, .{ .index = strong, .state = 0 } };
            if (reverse) std.mem.swap(Edit, &edits[0], &edits[1]);
            try engine.update(&edits);
            blocks[strong] = 0;
            blocks[weak] = state;
            reference(dimensions, registry, blocks, .block, false, expected);
            for (expected, 0..) |value, index| try std.testing.expectEqual(value, engine.get(.block, index));
        }
    }
    @memset(blocks, 0);
    blocks[weak] = 2;
    try engine.load(.{ .dense = blocks });
    engine.relight(false);
    try engine.update(&.{ .{ .index = weak, .state = 1 }, .{ .index = weak, .state = 0 } });
    for (0..blocks.len) |index| try std.testing.expectEqual(@as(u4, 0), engine.get(.block, index));
    try engine.update(&.{ .{ .index = weak, .state = 1 }, .{ .index = strong, .state = 1 }, .{ .index = weak, .state = 0 } });
    try std.testing.expectEqual(@as(u16, 0), engine.blockState(weak));
    try std.testing.expectEqual(@as(u4, 14), engine.get(.block, weak));
}

test "sealing a skylight clears the cave without restoring ordinary rows" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
    };
    const dimensions: Dimensions = .{ .x = 16, .y = 32, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, .{ .states = &states, .faces = 1, .occlusion = &.{0} });
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    @memset(blocks, 0);
    @memset(blocks[16 * 256 ..][0..256], 1);
    try engine.load(.{ .dense = blocks });
    engine.relight(true);
    const opening = (16 * 16 + 8) * 16 + 8;
    try engine.update(&.{.{ .index = opening, .state = 0 }});
    try engine.update(&.{.{ .index = opening, .state = 1 }});
    try std.testing.expect(engine.work.darkened_rows > 0);
    try std.testing.expectEqual(@as(u64, 0), engine.work.restored_rows);
    for (0..blocks.len) |index| {
        try std.testing.expectEqual(@as(u4, if (index / 256 > 16) 15 else 0), engine.get(.sky, index));
        try std.testing.expectEqual(@as(u4, 0), engine.get(.block, index));
    }
}

test "edits preserve scalar lighting across narrow regions and row boundaries" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 14, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 1, .occlusion = &.{0} };
    const dimensions = [_]Dimensions{
        .{ .x = 16, .y = 1, .z = 1 },
        .{ .x = 16, .y = 3, .z = 1 },
        .{ .x = 48, .y = 2, .z = 3 },
    };
    for (dimensions) |size| {
        var engine = try Engine.init(allocator, size, registry);
        defer engine.deinit();
        const blocks = try allocator.alloc(u16, size.volume());
        defer allocator.free(blocks);
        const expected = try allocator.alloc(u8, blocks.len);
        defer allocator.free(expected);
        for ([_]bool{ false, true }) |skylight| {
            @memset(blocks, 0);
            try engine.load(.{ .dense = blocks });
            engine.relight(skylight);
            const edits = [_]Edit{
                .{ .index = 0, .state = 2 },
                .{ .index = blocks.len / 2, .state = 2 },
                .{ .index = blocks.len - 1, .state = 2 },
                .{ .index = 0, .state = 1 },
                .{ .index = blocks.len / 2, .state = 1 },
                .{ .index = blocks.len - 1, .state = 0 },
            };
            for (edits) |edit| {
                blocks[edit.index] = edit.state;
                try engine.update(&.{edit});
                for ([_]Layer{ .block, .sky }) |layer| {
                    reference(size, registry, blocks, layer, skylight, expected);
                    for (expected, 0..) |value, index| try std.testing.expectEqual(value, engine.get(layer, index));
                }
            }
        }
    }
}

test "an edit below a sealed roof stops after the first unchanged downstream row" {
    const allocator = std.testing.allocator;
    const properties = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 14, .faces = @splat(0) },
    };
    const dimensions: Dimensions = .{ .x = 16, .y = 64, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, .{ .states = &properties, .faces = 1, .occlusion = &.{0} });
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    @memset(blocks, 0);
    @memset(blocks[32 * 256 ..][0..256], 1);
    try engine.load(.{ .dense = blocks });
    engine.relight(true);
    const index = (8 * 16 + 8) * 16 + 8;
    try engine.update(&.{.{ .index = index, .state = 2 }});
    try std.testing.expectEqual(@as(u64, 2), engine.work.source_rows);
    try std.testing.expectEqual(@as(u64, 0), engine.work.propagated_rows);
    try std.testing.expectEqual(@as(u4, 0), engine.get(.sky, index));
    try engine.update(&.{.{ .index = index, .state = 3 }});
    try std.testing.expectEqual(@as(u4, 14), engine.get(.block, index));
    try engine.update(&.{.{ .index = index, .state = 0 }});
    try std.testing.expectEqual(@as(u64, 0), engine.work.source_rows);
    for (0..blocks.len) |at| try std.testing.expectEqual(@as(u4, 0), engine.get(.block, at));
}

test "row scans agree with scalar paths for attenuation occlusion and decreases" {
    var random: u64 = 20261028;
    for (0..256) |_| {
        var light: [lanes]u8 = undefined;
        var cost: [lanes]u8 = undefined;
        var pending: [lanes]u8 = undefined;
        var remaining: [lanes]u8 = undefined;
        for (0..lanes) |x| {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            light[x] = if (random & 3 == 0) @intCast((random >> 2) & 15) else 0;
            cost[x] = @intCast(1 + (random >> 8) % 15);
            pending[x] = if (random & 16 != 0) light[x] else 0;
            remaining[x] = if (random & 16 == 0) light[x] else 0;
        }
        const blocked: [2]u16 = .{ @truncate(random), @truncate(random >> 32) };
        var expected = light;
        var reached: u16 = @bitCast(@as(Levels, pending) > @as(Levels, @splat(0)));
        for (0..lanes) |_| {
            for (0..lanes) |x| {
                if (x != 0 and blocked[1] & (@as(u16, 1) << @intCast(x)) == 0) expected[x] = @max(expected[x], expected[x - 1] -| cost[x]);
                if (x + 1 < lanes and blocked[0] & (@as(u16, 1) << @intCast(x)) == 0) expected[x] = @max(expected[x], expected[x + 1] -| cost[x]);
                if (light[x] == 0) continue;
                if ((x != 0 and reached & (@as(u16, 1) << @intCast(x - 1)) != 0 and light[x - 1] > light[x]) or
                    (x + 1 < lanes and reached & (@as(u16, 1) << @intCast(x + 1)) != 0 and light[x + 1] > light[x])) reached |= @as(u16, 1) << @intCast(x);
            }
        }
        try std.testing.expectEqual(expected, @as([lanes]u8, horizontalIncrease(light, cost, blocked)));
        try std.testing.expectEqual(reached, horizontalRemoval(pending, remaining));
    }
}

test "SIMD propagation agrees with scalar fixed point across edits and partial faces" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 14, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 1, 1, 1, 2, 0 } },
        .{ .opacity = 0, .emission = 0, .faces = .{ 3, 3, 3, 3, 0, 2 } },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 1, 1, 1, 0, 0 } },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
    };
    const faces = [_]u8{
        0, 0, 1, 0,
        0, 0, 1, 1,
        1, 1, 1, 1,
        0, 1, 1, 0,
    };
    const registry: Registry = .{ .states = &states, .faces = 4, .occlusion = &faces };
    const dimensions: Dimensions = .{ .x = 32, .y = 16, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, registry);
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    const expected = try allocator.alloc(u8, blocks.len);
    defer allocator.free(expected);
    const packed_light = try allocator.alloc(u8, blocks.len / 2);
    defer allocator.free(packed_light);
    var random: u64 = 20261027;
    for (0..states.len + 5) |map| {
        const edit = map -| states.len;
        for (blocks, 0..) |*state, at| {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            state.* = if (map < states.len) @intCast(map) else if (edit == 0) 0 else if (random % 32 < states.len) @intCast(random % 32) else 0;
            if (map >= states.len and at % dimensions.x == 15 and at / (dimensions.x * dimensions.z) == 8) state.* = if (edit % 2 == 0) 2 else 1;
        }
        try engine.load(if (map < states.len) .{ .uniform = @intCast(map) } else .{ .dense = blocks });
        engine.relight(edit != 3);
        for ([_]Layer{ .block, .sky }) |layer| {
            reference(dimensions, registry, blocks, layer, edit != 3, expected);
            engine.pack(layer, packed_light);
            for (expected, 0..) |value, index| {
                try std.testing.expectEqual(value, engine.get(layer, index));
                try std.testing.expectEqual(value, (packed_light[index / 2] >> @as(u3, @intCast(index % 2 * 4))) & 15);
            }
            var section_light: [2048]u8 = undefined;
            for (0..2) |section_x| {
                engine.packSection(layer, .{ section_x, 0, 0 }, &section_light);
                for (0..4096) |index| {
                    const global = ((index / 256) * dimensions.z + (index / 16) % 16) * dimensions.x + section_x * 16 + index % 16;
                    const actual = (section_light[index / 2] >> @as(u3, @intCast(index % 2 * 4))) & 15;
                    try std.testing.expectEqual(expected[global], actual);
                }
            }
        }
        for (0..8) |_| {
            var edits: [32]Edit = undefined;
            for (&edits) |*change| {
                random ^= random << 13;
                random ^= random >> 7;
                random ^= random << 17;
                const index = random % blocks.len;
                const state: u16 = @intCast((random >> 32) % states.len);
                change.* = .{ .index = index, .state = state };
                blocks[index] = state;
            }
            try engine.update(&edits);
            for ([_]Layer{ .block, .sky }) |layer| {
                reference(dimensions, registry, blocks, layer, edit != 3, expected);
                for (expected, 0..) |value, index| try std.testing.expectEqual(value, engine.get(layer, index));
            }
        }
    }
}

test "implicit air and opaque planes materialize correctly before the first edit" {
    const allocator = std.testing.allocator;
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 1, .occlusion = &.{0} };
    const dimensions: Dimensions = .{ .x = 16, .y = 64, .z = 16 };
    var engine = try Engine.init(allocator, dimensions, registry);
    defer engine.deinit();
    const blocks = try allocator.alloc(u16, dimensions.volume());
    defer allocator.free(blocks);
    const expected = try allocator.alloc(u8, blocks.len);
    defer allocator.free(expected);
    const packed_levels = try allocator.alloc(u8, blocks.len / 2);
    defer allocator.free(packed_levels);
    for ([_]bool{ false, true }) |skylight| {
        for (0..4) |initial| {
            @memset(blocks, 0);
            if (initial == 1 or initial == 2) @memset(blocks[16 * 256 ..][0..256], 1);
            if (initial >= 2) blocks[8 * 256 + 8 * 16 + 8] = 2;
            try engine.load(.{ .dense = blocks });
            engine.relight(skylight);
            for (0..5) |step| {
                if (step != 0) {
                    const edit: Edit = switch (step) {
                        1 => .{ .index = 16 * 256 + 8 * 16 + 8, .state = 0 },
                        2 => .{ .index = 8 * 256 + 8 * 16 + 8, .state = 2 },
                        3 => .{ .index = 16 * 256 + 8 * 16 + 8, .state = 1 },
                        4 => .{ .index = 8 * 256 + 8 * 16 + 8, .state = 0 },
                        else => unreachable,
                    };
                    blocks[edit.index] = edit.state;
                    try engine.update(&.{edit});
                }
                for ([_]Layer{ .block, .sky }) |layer| {
                    reference(dimensions, registry, blocks, layer, skylight, expected);
                    engine.pack(layer, packed_levels);
                    for (expected, 0..) |value, index| {
                        try std.testing.expectEqual(value, engine.get(layer, index));
                        try std.testing.expectEqual(blocks[index], engine.blockState(index));
                        try std.testing.expectEqual(value, (packed_levels[index / 2] >> @as(u3, @intCast(index % 2 * 4))) & 15);
                    }
                    for (0..dimensions.y / 16) |section| {
                        var buffer: [2048]u8 = undefined;
                        engine.packSection(layer, .{ 0, section, 0 }, &buffer);
                        if (engine.sectionUniform(layer, .{ 0, section, 0 })) |level|
                            try std.testing.expect(std.mem.allEqual(u8, &buffer, @as(u8, level) * 17));
                        try std.testing.expectEqualSlices(u8, packed_levels[section * 2048 ..][0..2048], &buffer);
                        try std.testing.expectEqual(!std.mem.allEqual(u8, &buffer, 0), engine.sectionNonempty(layer, .{ 0, section, 0 }));
                    }
                }
            }
        }
    }
}

test "section descriptors match dense lighting without reading uniform backing storage" {
    const states = [_]Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
    };
    const registry: Registry = .{ .states = &states, .faces = 1, .occlusion = &.{0} };
    const dimensions: Dimensions = .{ .x = 32, .y = 64, .z = 32 };
    const dense = try std.testing.allocator.alloc(u16, dimensions.volume());
    defer std.testing.allocator.free(dense);
    const sparse = try std.testing.allocator.alloc(u16, dimensions.x * 32 * dimensions.z);
    defer std.testing.allocator.free(sparse);
    var actual = try Engine.init(std.testing.allocator, dimensions, registry);
    defer actual.deinit();
    var expected = try Engine.init(std.testing.allocator, dimensions, registry);
    defer expected.deinit();
    const mixed: [8]?u16 = .{ 1, null, 0, 2, null, 0, 1, 2 };
    for ([_]bool{ false, true }) |air| for ([_]bool{ false, true }) |sky| for ([_]usize{ 0, 16, 48 }) |minimum| for ([_][2]usize{ .{ 0, 0 }, .{ 1, 16 } }) |origin| {
        const uniforms: [8]?u16 = if (air) @splat(0) else mixed;
        @memset(sparse, std.math.maxInt(u16));
        for (dense, 0..) |*state, index| {
            const x = index % 32;
            const z = index / 32 % 32;
            const y = index / (32 * 32);
            const section = y / 16;
            if (section < 1 or section >= 3) {
                state.* = 0;
                continue;
            }
            const uniform = uniforms[(z / 16 * 2 + x / 16) * 2 + section - 1];
            state.* = uniform orelse @intCast((x + y + z) % 3);
            if (uniform == null) sparse[((y - 16) * 32 + (z + origin[1]) % 32) * 32 + (x + origin[0] * 16) % 32] = state.*;
        }
        try actual.load(.{ .ring = .{ .states = sparse, .origin = origin, .minimum_y = minimum, .sections = .{ .uniforms = &uniforms, .first = 1, .count = 2, .stride = 2 } } });
        actual.relight(sky);
        try expected.load(.{ .ring = .{ .states = dense, .origin = .{ 0, 0 }, .minimum_y = minimum } });
        expected.relight(sky);
        try std.testing.expectEqual(expected.uniform_air, actual.uniform_air);
        for (minimum * 32 * 32..dimensions.volume()) |index| {
            try std.testing.expectEqual(expected.blockState(index), actual.blockState(index));
            try std.testing.expectEqual(expected.get(.block, index), actual.get(.block, index));
            try std.testing.expectEqual(expected.get(.sky, index), actual.get(.sky, index));
        }
    };
}

test {
    _ = patch;
}
