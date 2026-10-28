const std = @import("std");
const assert = std.debug.assert;
pub const testing = @import("testing.zig");
const reference = testing.reference;

pub const lanes = 16;
pub const Levels = @Vector(lanes, u8);
pub const Layer = enum { block, sky };
pub const Blocks = union(enum) { uniform: u16, dense: []const u16 };
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
        const face = @intFromEnum(direction);
        const a = self.states[from].faces[face];
        const b = self.states[to].faces[face ^ 1];
        return self.occlusion[@as(usize, a) * self.faces + b] != 0;
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
    restore_queued: bool,
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
            row.restore_queued = false;
        }
        return .{ .allocator = allocator, .dimensions = dimensions, .registry = registry, .materials = materials, .rows = rows, .blocks = blocks, .stride = @intCast(stride), .plane = @intCast(plane), .links = links, .decreases = decreases, .decrease_queue = decrease_queue, .decrease_queued = decrease_queued, .restore_rows = restore_rows, .source_bounds = source_bounds };
    }

    pub fn deinit(self: *Engine) void {
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
        self.loaded = false;
        self.lit = false;
        var remaining = self.dimensions.volume();
        switch (input) {
            .uniform => |state| {
                if (state >= self.materials.len) return error.InvalidState;
                if (state == 0) remaining = 0;
            },
            .dense => |blocks| {
                if (blocks.len != remaining) return error.InvalidBlockCount;
                const scan_lanes = 64;
                while (remaining >= scan_lanes) : (remaining -= scan_lanes) {
                    const values: @Vector(scan_lanes, u16) = blocks[remaining - scan_lanes ..][0..scan_lanes].*;
                    if (@reduce(.Or, values != @as(@Vector(scan_lanes, u16), @splat(0)))) break;
                }
                while (remaining != 0 and blocks[remaining - 1] == 0) remaining -= 1;
            },
        }
        self.uniform_air = remaining == 0;
        // Above the last material, sixteen air layers also contain every block light ray.
        const plane_cells = @as(usize, self.plane) * lanes;
        self.air_start = if (self.uniform_air) 0 else @min(self.dimensions.y, (remaining - 1) / plane_cells + 17) * self.plane;
        self.emitter_count = 0;
        self.sky_start = 0;
        if (self.uniform_air) {
            self.loaded = true;
            return;
        }
        var opaque_plane = true;
        var plane_end: usize = self.plane;
        for (self.rows[0..self.air_start], self.blocks[0..self.air_start], 0..) |*row, *block, r| {
            const states: @Vector(lanes, u16) = switch (input) {
                .uniform => |state| @splat(state),
                .dense => |blocks| blocks[r * lanes ..][0..lanes].*,
            };
            block.state = states;
            var row_opaque: bool = undefined;
            if (@reduce(.And, states == @as(@Vector(lanes, u16), @splat(states[0])))) {
                if (states[0] >= self.materials.len) return error.InvalidState;
                const material = self.materials[states[0]];
                row.attenuation = @splat(@max(@as(u8, material.opacity), 1));
                block.emission = @splat(material.emission);
                row.emitters = if (material.emission != 0) std.math.maxInt(u16) else 0;
                row.transparent = if (material.opacity == 0) std.math.maxInt(u16) else 0;
                row.shaped = if (material.shaped) std.math.maxInt(u16) else 0;
                row_opaque = material.opacity == 15;
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
                row_opaque = @reduce(.And, opacity == @as(Levels, @splat(15)));
            }
            if (row.emitters != 0) self.emitter_count += @popCount(row.emitters);
            opaque_plane = opaque_plane and row_opaque;
            if (r + 1 == plane_end) {
                if (opaque_plane) self.sky_start = r + 1 - self.plane;
                opaque_plane = true;
                plane_end += self.plane;
            }
            self.prepareEdges(r);
        }
        self.loaded = true;
    }

    /// Horizontal boundaries are opaque. All columns above the top boundary see the sky.
    pub fn relight(self: *Engine, skylight: bool) void {
        assert(self.highest == 0 and self.loaded);
        assert(self.decrease_count == 0 and self.restore_count == 0);
        self.skylight = skylight;
        self.lit = true;
        self.work = .{};
        self.block_zero = self.emitter_count == 0;
        if (self.uniform_air) return;
        // The empty decrease queue holds emitting rows until skylight propagation finishes.
        var sources: usize = 0;
        var at = self.air_start;
        const bottom = if (self.block_zero) (if (skylight) self.sky_start else self.air_start) else 0;
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

    fn materialize(self: *Engine) void {
        if (!self.uniform_air and !self.block_zero and self.sky_start == 0 and self.air_start == self.rows.len) return;
        for (self.rows, self.blocks, 0..) |*row, *block, index| {
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
        self.sky_start = 0;
        self.air_start = self.rows.len;
    }

    inline fn directSource(self: *Engine, at: usize, upstream: u16) u16 {
        self.work.source_rows += 1;
        const row = &self.rows[at];
        var source = upstream & row.transparent;
        const above = self.neighbours(at)[5];
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
            if (at < plane) break;
            at -= plane;
        }
    }

    /// Applies the final state of each cell against a settled light field.
    /// The batch is bounded by batch_max. No allocation or IO occurs.
    pub fn update(self: *Engine, edits: []const Edit) !void {
        assert(self.lit and self.highest == 0 and self.source_count == 0 and self.restore_count == 0);
        if (edits.len > batch_max) return error.BatchTooLarge;
        if (edits.len <= 1) {
            for (edits) |edit| {
                if (edit.index >= self.dimensions.volume() or edit.state >= self.registry.states.len) return error.InvalidEdit;
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
            const light = self.get(.block, edit.index);
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
            if (edit.index >= self.dimensions.volume() or edit.state >= self.registry.states.len) return error.InvalidEdit;
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

    inline fn neighbours(self: *const Engine, index: usize) [6]u32 {
        const at: u32 = @intCast(index);
        const boundary = self.rows[index].boundary;
        return .{
            if (boundary & 1 == 0) at - 1 else none,
            if (boundary & 2 == 0) at + 1 else none,
            if (boundary & 4 == 0) at - self.stride else none,
            if (boundary & 8 == 0) at + self.stride else none,
            if (boundary & 16 == 0) at - self.plane else none,
            if (boundary & 32 == 0 and at + self.plane < self.air_start) at + self.plane else none,
        };
    }

    fn seedRow(self: *Engine, comptime layer: Layer, row: usize) void {
        const value = self.rows[row].light[@intFromEnum(layer)];
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
        const value = row.light[@intFromEnum(layer)];
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
        row.light[@intFromEnum(layer)] = @select(u8, selected, @as(Levels, @splat(0)), value);
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
            const reached = horizontalRemoval(self.decreases[at], row.light[@intFromEnum(layer)]);
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
        const value = self.rows[at].light[@intFromEnum(layer)];
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
        row.light[@intFromEnum(layer)] = @max(row.light[@intFromEnum(layer)], source);
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
        var light: [lanes]u8 = row.light[@intFromEnum(layer)];
        if (light[x] >= source) return;
        light[x] = @max(light[x], source);
        row.light[@intFromEnum(layer)] = light;
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
            const live = mask & @as(u16, @bitCast(self.rows[index].light[@intFromEnum(layer)] > @as(Levels, @splat(1))));
            if (live == 0) continue;
            self.work.propagated_rows += 1;
            const at: usize = index;
            const adjacent = self.neighbours(at);
            const row = &self.rows[at];
            const old = row.light[@intFromEnum(layer)];
            const value = horizontalIncrease(old, row.attenuation, row.blocked_horizontal);
            const changed: u16 = @bitCast(value > old);
            self.work.changed_cells += @popCount(changed);
            row.light[@intFromEnum(layer)] = value;
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
                self.spread(layer, at, adjacent[direction], @enumFromInt(direction), light);
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
            if (next <= target.light[@intFromEnum(layer)][x]) return;
            const mask = @as(u16, 1) << x;
            if ((self.rows[from].shaped & (@as(u16, 1) << source_x)) != 0 or (target.shaped & mask) != 0) {
                self.work.shape_checks += 1;
                if (self.registry.blocked(self.blocks[from].state[source_x], self.blocks[to].state[x], direction)) return;
            }
            self.work.changed_cells += 1;
            target.light[@intFromEnum(layer)][x] = next;
            if (next > 1) self.enqueue(@intCast(to), next, mask);
            return;
        }
        const old = target.light[@intFromEnum(layer)];
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
        target.light[@intFromEnum(layer)] = @max(admitted, old);
        const maximum = @reduce(.Max, admitted);
        if (maximum > 1) self.enqueue(@intCast(to), maximum, improved);
    }

    pub fn get(self: *const Engine, layer: Layer, index: usize) u4 {
        assert(self.lit and index < self.dimensions.volume());
        if (layer == .block and self.block_zero) return 0;
        if (layer == .sky and (!self.skylight or index / lanes < self.sky_start)) return 0;
        if (self.uniform_air or index / lanes >= self.air_start) return if (layer == .sky and self.skylight) 15 else 0;
        const values: [lanes]u8 = self.rows[index / lanes].light[@intFromEnum(layer)];
        return @intCast(values[index % lanes]);
    }

    pub fn blockState(self: *const Engine, index: usize) u16 {
        assert(self.loaded and index < self.dimensions.volume());
        if (self.uniform_air or index / lanes >= self.air_start) return 0;
        return self.blocks[index / lanes].state[index % lanes];
    }

    pub fn pack(self: *const Engine, layer: Layer, output: []u8) void {
        assert(self.lit and output.len == self.dimensions.volume() / 2);
        if (self.uniform_air or (layer == .block and self.block_zero) or (layer == .sky and !self.skylight)) {
            @memset(output, if (self.uniform_air and layer == .sky and self.skylight) 255 else 0);
            return;
        }
        const even = [8]i32{ 0, 2, 4, 6, 8, 10, 12, 14 };
        const odd = [8]i32{ 1, 3, 5, 7, 9, 11, 13, 15 };
        const begin = if (layer == .sky) self.sky_start else 0;
        @memset(output[0 .. begin * 8], 0);
        @memset(output[self.air_start * 8 ..], if (layer == .sky) 255 else 0);
        for (self.rows[begin..self.air_start], begin..) |*row, index| {
            const value = row.light[@intFromEnum(layer)];
            const low = @shuffle(u8, value, undefined, even);
            const high = @shuffle(u8, value, undefined, odd);
            output[index * 8 ..][0..8].* = low | (high << @splat(4));
        }
    }

    pub fn sectionNonempty(self: *const Engine, layer: Layer, section: [3]usize) bool {
        assert(self.lit);
        assert(section[0] < self.dimensions.x / 16 and section[1] < self.dimensions.y / 16 and section[2] < self.dimensions.z / 16);
        if (layer == .block and self.block_zero) return false;
        if (layer == .sky and !self.skylight) return false;
        if (self.uniform_air) return layer == .sky and self.skylight;
        if (section[1] * 16 * self.plane >= self.air_start) return layer == .sky;
        if (layer == .sky and (section[1] + 1) * 16 * self.plane <= self.sky_start) return false;
        const stride = self.dimensions.x / lanes;
        const plane = stride * self.dimensions.z;
        for (0..16) |y| for (0..16) |z| {
            const index = (section[1] * 16 + y) * plane + (section[2] * 16 + z) * stride + section[0];
            if (layer == .sky and index < self.sky_start) continue;
            if (index >= self.air_start) {
                if (layer == .sky) return true;
                continue;
            }
            if (@reduce(.Or, self.rows[index].light[@intFromEnum(layer)] != @as(Levels, @splat(0)))) return true;
        };
        return false;
    }

    pub fn packSection(self: *const Engine, layer: Layer, section: [3]usize, output: *[2048]u8) void {
        assert(self.lit);
        assert(section[0] < self.dimensions.x / 16 and section[1] < self.dimensions.y / 16 and section[2] < self.dimensions.z / 16);
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
        for (0..16) |y| for (0..16) |z| {
            const index = (section[1] * 16 + y) * plane + (section[2] * 16 + z) * stride + section[0];
            const value = if (layer == .sky and index < self.sky_start) @as(Levels, @splat(0)) else if (index >= self.air_start) @as(Levels, @splat(if (layer == .sky) 15 else 0)) else self.rows[index].light[@intFromEnum(layer)];
            output[(y * 16 + z) * 8 ..][0..8].* = @shuffle(u8, value, undefined, even) | (@shuffle(u8, value, undefined, odd) << @splat(4));
        };
    }
};

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
                        try std.testing.expectEqualSlices(u8, packed_levels[section * 2048 ..][0..2048], &buffer);
                        try std.testing.expectEqual(!std.mem.allEqual(u8, &buffer, 0), engine.sectionNonempty(layer, .{ 0, section, 0 }));
                    }
                }
            }
        }
    }
}
