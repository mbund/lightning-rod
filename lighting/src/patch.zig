//! Patches settled light in place after block edits.
//!
//! The engine derives light from blocks by solving a whole neighbourhood. A patch starts
//! from light that is already exact for the nine columns around an edit and visits only
//! the cells the edit can reach. Light fades by at least one level per step, so nothing an
//! edit to the centre column changes lies outside those nine columns. The result is exact
//! for all of them, which a solve of the same window is not.
//!
//! Light is always read before the blocks of the same cell. A patch therefore asks for
//! block states only where it was given light, and never for a column nobody has lit.
const std = @import("std");
const assert = std.debug.assert;
const lighting = @import("lighting.zig");

/// Light sections a column may have, one beyond each end of its world sections.
pub const sections_max = 26;
const width = 48;
const level_cells = width * width;
const cells_max = level_cells * sections_max * 16;

comptime {
    assert(cells_max <= 1 << 20);
}

/// One layer of one section. Dense light holds 4096 levels in YZX order, the low nibble first.
pub const Light = union(enum) {
    uniform: u4,
    dense: *[2048]u8,
};

/// Block states of one section in YZX order.
pub const States = union(enum) {
    uniform: u16,
    dense: *const [4096]u16,
};

/// An edited cell of the centre column, by world section.
pub const Edit = struct { section: u8, local: u12 };

/// The nine columns around an edit. Columns are numbered z * 3 + x, the centre is 4.
pub const Region = struct {
    /// World sections per column. Light has one more section below and one above.
    count: usize,
    skylight: bool,
    /// By layer, column and light section. Null is not loaded.
    light: [2][9][sections_max]?Light = @splat(@splat(@splat(null))),
    /// By column and world section, as they are after the edits. Null is not loaded.
    states: [9][sections_max - 2]?States = @splat(@splat(null)),
    /// Buffers for sections that stop being uniform, taken from the end. A section that
    /// took one keeps it. A patch that fails gives back what it took.
    spare: []*[2048]u8 = &.{},

    fn height(self: *const Region) u32 {
        return @intCast((self.count + 2) * 16);
    }
};

/// Light sections whose settled light differs after a patch, by layer and column.
pub const Changes = struct {
    sections: [2][9]u32 = @splat(@splat(0)),

    pub fn column(self: Changes, index: usize) u32 {
        return self.sections[0][index] | self.sections[1][index];
    }
};

/// The section a patch needed and did not find. Load it and apply the edits again.
pub const Missing = struct {
    kind: enum { light, states },
    layer: lighting.Layer,
    column: u8,
    /// A light section for light, a world section for states.
    section: u8,
};

pub const Error = error{ MissingSection, NoSpareSection, PatchTooLarge };

const cell_mask = (1 << 20) - 1;

const Place = struct { column: usize, section: usize, local: usize };

fn place(cell: u32) Place {
    const x = cell % width;
    const z = cell / width % width;
    const y = cell / level_cells;
    return .{ .column = z / 16 * 3 + x / 16, .section = y / 16, .local = y % 16 * 256 + z % 16 * 16 + x % 16 };
}

pub const Patcher = struct {
    registry: lighting.Registry,
    /// One bit per cell written during the current layer.
    seen: []u64,
    /// The first write of each cell, with the level it held before, for every layer so far.
    log: []u32,
    removals: []u32,
    increases: []u32,
    materialized: [2 * 9 * sections_max]Materialized = undefined,
    materialized_count: usize = 0,
    log_count: usize = 0,
    layer_start: usize = 0,
    removal_head: usize = 0,
    removal_count: usize = 0,
    increase_head: usize = 0,
    increase_count: usize = 0,
    missing: ?Missing = null,
    work: Work = .{},

    pub const Work = struct { removed: u64 = 0, raised: u64 = 0, visited: u64 = 0 };
    const Materialized = struct { layer: u8, column: u8, section: u8, level: u4 };

    /// `capacity` bounds the cells one patch may change in a layer. A larger patch fails
    /// whole and leaves the light as it was.
    pub fn init(allocator: std.mem.Allocator, registry: lighting.Registry, capacity: usize) !Patcher {
        assert(capacity != 0 and capacity <= cells_max);
        const seen = try allocator.alloc(u64, (cells_max + 63) / 64);
        errdefer allocator.free(seen);
        const log = try allocator.alloc(u32, 2 * capacity);
        errdefer allocator.free(log);
        const removals = try allocator.alloc(u32, capacity);
        errdefer allocator.free(removals);
        const increases = try allocator.alloc(u32, 4 * capacity);
        @memset(seen, 0);
        return .{ .registry = registry, .seen = seen, .log = log, .removals = removals, .increases = increases };
    }

    pub fn deinit(self: *Patcher, allocator: std.mem.Allocator) void {
        allocator.free(self.increases);
        allocator.free(self.removals);
        allocator.free(self.log);
        allocator.free(self.seen);
        self.* = undefined;
    }

    /// Settles the light of the region for edits already made to its centre column.
    /// On an error the light is exactly as it was and `missing` names what to load.
    pub fn apply(self: *Patcher, region: *Region, edits: []const Edit) Error!Changes {
        assert(region.count != 0 and region.count + 2 <= sections_max);
        assert(self.log_count == 0 and self.materialized_count == 0);
        for (edits) |edit| assert(edit.section < region.count);
        self.missing = null;
        self.work = .{};
        var changes: Changes = .{};
        const layers: usize = if (region.skylight) 2 else 1;
        for (0..layers) |index| {
            const layer: lighting.Layer = @fromBackingInt(@intCast(index));
            self.layer_start = self.log_count;
            self.patchLayer(region, layer, edits) catch |err| {
                self.undo(region);
                return err;
            };
            for (self.log[self.layer_start..self.log_count]) |entry| {
                const cell = entry & cell_mask;
                self.seen[cell / 64] &= ~(@as(u64, 1) << @intCast(cell % 64));
                const before: u4 = @truncate(entry >> 20);
                const at = place(cell);
                if (self.read(region, layer, at).? != before) changes.sections[index][at.column] |= @as(u32, 1) << @intCast(at.section);
            }
        }
        self.log_count = 0;
        self.materialized_count = 0;
        return changes;
    }

    fn patchLayer(self: *Patcher, region: *Region, layer: lighting.Layer, edits: []const Edit) Error!void {
        self.removal_head = 0;
        self.removal_count = 0;
        self.increase_head = 0;
        self.increase_count = 0;
        // Direct sky light must be settled first. It decides which cells are their own source.
        if (layer == .sky) try self.exposure(region, edits);
        for (edits) |edit| {
            const cell = centre(edit);
            const value = try self.level(region, layer, cell);
            const source: u4 = switch (layer) {
                .block => @intCast(self.registry.states[try self.state(region, cell)].emission),
                // A level of 15 is direct sky light and nothing else reaches it.
                .sky => if (value == 15) 15 else 0,
            };
            // Neighbours lit through the old block may no longer be, even if the cell keeps its level.
            if (value != 0) try self.pushRemoval(cell, value);
            if (value != source) try self.write(region, layer, cell, source);
            if (source > 1) try self.pushIncrease(cell);
        }
        while (self.removal_head != self.removal_count) {
            const entry = self.removals[self.removal_head];
            self.removal_head += 1;
            const value: u4 = @truncate(entry >> 20);
            for (0..6) |direction| {
                const next = neighbour(region, entry & cell_mask, direction) orelse continue;
                const other = try self.level(region, layer, next);
                if (other == 0) continue;
                if (other < value) {
                    // It may have been lit from the removed cell. Whatever else lights it restores it.
                    try self.write(region, layer, next, 0);
                    try self.pushRemoval(next, other);
                    self.work.removed += 1;
                } else try self.pushIncrease(next);
            }
        }
        if (layer == .block) {
            // The removal also cleared emitters that were dimmer than the wave passing them.
            var index = self.layer_start;
            while (index != self.log_count) : (index += 1) {
                const cell = self.log[index] & cell_mask;
                const emission: u4 = @intCast(self.registry.states[try self.state(region, cell)].emission);
                if (emission <= try self.level(region, layer, cell)) continue;
                try self.write(region, layer, cell, emission);
                try self.pushIncrease(cell);
            }
        }
        for (edits) |edit| {
            // An edit that opens a cell lets its neighbours light it.
            for (0..6) |direction| {
                const next = neighbour(region, centre(edit), direction) orelse continue;
                if (try self.level(region, layer, next) > 1) try self.pushIncrease(next);
            }
        }
        while (self.increase_count != 0) {
            const cell = self.increases[self.increase_head];
            self.increase_head = (self.increase_head + 1) % self.increases.len;
            self.increase_count -= 1;
            self.work.visited += 1;
            const value = try self.level(region, layer, cell);
            if (value <= 1) continue;
            const from = try self.state(region, cell);
            for (0..6) |direction| {
                const next = neighbour(region, cell, direction) orelse continue;
                const other = try self.level(region, layer, next);
                // A neighbour already this bright or one level under it cannot be raised.
                if (@as(u8, other) + 1 >= value) continue;
                const to = try self.state(region, next);
                const cost = @max(1, self.registry.states[to].opacity);
                if (value <= cost) continue;
                const candidate: u4 = @intCast(value - cost);
                if (candidate <= other) continue;
                if (self.registry.blocked(from, to, @fromBackingInt(@intCast(direction)))) continue;
                try self.write(region, layer, next, candidate);
                try self.pushIncrease(next);
                self.work.raised += 1;
            }
        }
    }

    /// Recomputes which cells under each edit see the sky directly. A cell does when the
    /// one above it does, it is fully transparent, and no face between them blocks light.
    fn exposure(self: *Patcher, region: *Region, edits: []const Edit) Error!void {
        const top = region.height();
        // One walk serves every edit that shares a cell column, from the highest down.
        // The edits are in the centre column, which has 256 cell columns.
        const none = std.math.maxInt(u16);
        assert(edits.len < none);
        var leaders: [256]u16 = @splat(none);
        var lowests: [256]u32 = undefined;
        for (edits, 0..) |edit, index| {
            const slot = edit.local % 256;
            const y = centre(edit) / level_cells;
            if (leaders[slot] == none) {
                leaders[slot] = @intCast(index);
                lowests[slot] = y;
                continue;
            }
            lowests[slot] = @min(lowests[slot], y);
            if (centre(edit) > centre(edits[leaders[slot]])) leaders[slot] = @intCast(index);
        }
        for (edits, 0..) |edit, index| {
            const slot = edit.local % 256;
            if (leaders[slot] != index) continue;
            const start = centre(edit);
            const lowest = lowests[slot];
            var y = start / level_cells;
            var exposed = true;
            var above: u16 = 0;
            if (y + 1 != top) {
                exposed = try self.level(region, .sky, start + level_cells) == 15;
                above = try self.state(region, start + level_cells);
            }
            while (true) {
                const cell = y * level_cells + start % level_cells;
                // Once the sky is shut out nothing below lets it back in, so the blocks
                // there need not be read.
                const was = try self.level(region, .sky, cell) == 15;
                var here: u16 = 0;
                if (exposed) {
                    here = try self.state(region, cell);
                    exposed = self.registry.states[here].opacity == 0 and !self.registry.blocked(above, here, .down);
                }
                // A changed face can also cover the cell under the lowest edit.
                if (y < lowest and exposed == was) break;
                if (was and !exposed) {
                    try self.write(region, .sky, cell, 0);
                    try self.pushRemoval(cell, 15);
                } else if (exposed and !was) {
                    try self.write(region, .sky, cell, 15);
                    try self.pushIncrease(cell);
                }
                above = here;
                if (y == 0) break;
                y -= 1;
            }
        }
    }

    fn centre(edit: Edit) u32 {
        const y: u32 = (@as(u32, edit.section) + 1) * 16 + edit.local / 256;
        const z: u32 = 16 + edit.local / 16 % 16;
        const x: u32 = 16 + edit.local % 16;
        return y * level_cells + z * width + x;
    }

    /// The cell one step away, or null at the edge of the nine columns. Light an edit to
    /// the centre column changes never gets that far.
    fn neighbour(region: *const Region, cell: u32, direction: usize) ?u32 {
        const x = cell % width;
        const z = cell / width % width;
        const y = cell / level_cells;
        return switch (@as(lighting.Direction, @fromBackingInt(@intCast(direction)))) {
            .west => if (x == 0) null else cell - 1,
            .east => if (x + 1 == width) null else cell + 1,
            .north => if (z == 0) null else cell - width,
            .south => if (z + 1 == width) null else cell + width,
            .down => if (y == 0) null else cell - level_cells,
            .up => if (y + 1 == region.height()) null else cell + level_cells,
        };
    }

    fn read(self: *const Patcher, region: *const Region, layer: lighting.Layer, at: Place) ?u4 {
        _ = self;
        const section = region.light[@backingInt(layer)][at.column][at.section] orelse return null;
        return switch (section) {
            .uniform => |value| value,
            .dense => |bytes| @truncate(bytes[at.local / 2] >> @as(u3, @intCast(at.local % 2 * 4))),
        };
    }

    fn level(self: *Patcher, region: *const Region, layer: lighting.Layer, cell: u32) Error!u4 {
        const at = place(cell);
        return self.read(region, layer, at) orelse {
            self.missing = .{ .kind = .light, .layer = layer, .column = @intCast(at.column), .section = @intCast(at.section) };
            return error.MissingSection;
        };
    }

    fn state(self: *Patcher, region: *const Region, cell: u32) Error!u16 {
        const at = place(cell);
        // The sections beyond the world hold air.
        if (at.section == 0 or at.section == region.count + 1) return 0;
        const states = region.states[at.column][at.section - 1] orelse {
            self.missing = .{ .kind = .states, .layer = .block, .column = @intCast(at.column), .section = @intCast(at.section - 1) };
            return error.MissingSection;
        };
        const result = switch (states) {
            .uniform => |value| value,
            .dense => |values| values[at.local],
        };
        assert(result < self.registry.states.len);
        return result;
    }

    fn write(self: *Patcher, region: *Region, layer: lighting.Layer, cell: u32, value: u4) Error!void {
        const at = place(cell);
        const slot = &region.light[@backingInt(layer)][at.column][at.section];
        const bytes: *[2048]u8 = switch (slot.* orelse {
            self.missing = .{ .kind = .light, .layer = layer, .column = @intCast(at.column), .section = @intCast(at.section) };
            return error.MissingSection;
        }) {
            .dense => |bytes| bytes,
            .uniform => |uniform| dense: {
                if (uniform == value) return;
                if (region.spare.len == 0) return error.NoSpareSection;
                const buffer = region.spare[region.spare.len - 1];
                region.spare.len -= 1;
                @memset(buffer, @as(u8, uniform) * 17);
                slot.* = .{ .dense = buffer };
                self.materialized[self.materialized_count] = .{ .layer = @backingInt(layer), .column = @intCast(at.column), .section = @intCast(at.section), .level = uniform };
                self.materialized_count += 1;
                break :dense buffer;
            },
        };
        const shift: u3 = @intCast(at.local % 2 * 4);
        const before: u4 = @truncate(bytes[at.local / 2] >> shift);
        if (before == value) return;
        const bit = @as(u64, 1) << @intCast(cell % 64);
        if (self.seen[cell / 64] & bit == 0) {
            if (self.log_count == self.log.len) return error.PatchTooLarge;
            self.seen[cell / 64] |= bit;
            self.log[self.log_count] = cell | @as(u32, before) << 20 | @as(u32, @backingInt(layer)) << 24;
            self.log_count += 1;
        }
        bytes[at.local / 2] = (bytes[at.local / 2] & ~(@as(u8, 15) << shift)) | @as(u8, value) << shift;
    }

    fn pushRemoval(self: *Patcher, cell: u32, value: u4) Error!void {
        assert(value != 0);
        if (self.removal_count == self.removals.len) return error.PatchTooLarge;
        self.removals[self.removal_count] = cell | @as(u32, value) << 20;
        self.removal_count += 1;
    }

    fn pushIncrease(self: *Patcher, cell: u32) Error!void {
        if (self.increase_count == self.increases.len) return error.PatchTooLarge;
        self.increases[(self.increase_head + self.increase_count) % self.increases.len] = cell;
        self.increase_count += 1;
    }

    /// Puts back every level this patch wrote and every section it made dense.
    fn undo(self: *Patcher, region: *Region) void {
        var index = self.log_count;
        while (index != 0) {
            index -= 1;
            const entry = self.log[index];
            const cell = entry & cell_mask;
            const at = place(cell);
            const bytes = region.light[(entry >> 24) & 1][at.column][at.section].?.dense;
            const shift: u3 = @intCast(at.local % 2 * 4);
            bytes[at.local / 2] = (bytes[at.local / 2] & ~(@as(u8, 15) << shift)) | @as(u8, @truncate((entry >> 20) & 15)) << shift;
            self.seen[cell / 64] &= ~(@as(u64, 1) << @intCast(cell % 64));
        }
        while (self.materialized_count != 0) {
            self.materialized_count -= 1;
            const entry = self.materialized[self.materialized_count];
            region.light[entry.layer][entry.column][entry.section] = .{ .uniform = entry.level };
            region.spare.len += 1;
        }
        self.log_count = 0;
    }
};

const Fixture = struct {
    const count = 3;
    const height = (count + 2) * 16;
    const volume = level_cells * height;
    const states = [_]lighting.Properties{
        .{ .opacity = 0, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 14, .faces = @splat(0) },
        .{ .opacity = 1, .emission = 0, .faces = @splat(0) },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 1, 1, 1, 2, 0 } },
        .{ .opacity = 0, .emission = 0, .faces = .{ 3, 3, 3, 3, 0, 2 } },
        .{ .opacity = 0, .emission = 0, .faces = .{ 1, 1, 1, 1, 0, 0 } },
        .{ .opacity = 0, .emission = 15, .faces = @splat(0) },
        .{ .opacity = 15, .emission = 9, .faces = @splat(0) },
    };
    const faces = [_]u8{
        0, 0, 1, 0,
        0, 0, 1, 1,
        1, 1, 1, 1,
        0, 1, 1, 0,
    };
    const registry: lighting.Registry = .{ .states = &states, .faces = 4, .occlusion = &faces };

    arena: std.heap.ArenaAllocator,
    blocks: []u16,
    engine: lighting.Engine,
    light: []([2048]u8),
    section_states: []([4096]u16),
    spares: []([2048]u8),
    spare_list: []*[2048]u8,
    region: Region,
    patcher: Patcher,
    random: u64,

    fn init(seed: u64, skylight: bool, capacity: usize) !*Fixture {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const self = try allocator.create(Fixture);
        self.* = .{
            .arena = undefined,
            .blocks = try allocator.alloc(u16, volume),
            .engine = try lighting.Engine.init(allocator, .{ .x = width, .y = height, .z = width }, registry),
            .light = try allocator.alloc([2048]u8, 2 * 9 * (count + 2)),
            .section_states = try allocator.alloc([4096]u16, 9 * count),
            .spares = try allocator.alloc([2048]u8, 2 * 9 * (count + 2)),
            .spare_list = try allocator.alloc(*[2048]u8, 2 * 9 * (count + 2)),
            .region = .{ .count = count, .skylight = skylight },
            .patcher = try Patcher.init(allocator, registry, capacity),
            .random = seed,
        };
        self.arena = arena;
        return self;
    }

    fn deinit(self: *Fixture) void {
        var arena = self.arena;
        arena.deinit();
    }

    fn next(self: *Fixture) u64 {
        self.random ^= self.random << 13;
        self.random ^= self.random >> 7;
        self.random ^= self.random << 17;
        return self.random;
    }

    /// Terrain with a floor, scattered blocks of every kind and air in the sections beyond the world.
    fn scatter(self: *Fixture, density: u64) void {
        for (self.blocks, 0..) |*block, index| {
            const y = index / level_cells;
            const value = self.next();
            block.* = if (y < 16 or y >= height - 16) 0 else if (y < 20) 1 else if (value % 100 < density) @intCast((value >> 32) % states.len) else 0;
        }
    }

    /// Solves the blocks from scratch and loads the result as stored light and states.
    /// Sections that hold one level are stored uniform, as a light store would keep them.
    fn load(self: *Fixture) !void {
        try self.engine.load(.{ .dense = self.blocks });
        self.engine.relight(self.region.skylight);
        for (0..2) |layer| for (0..9) |column| for (0..count + 2) |section| {
            const buffer = &self.light[(layer * 9 + column) * (count + 2) + section];
            self.engine.packSection(@fromBackingInt(@intCast(layer)), .{ column % 3, section, column / 3 }, buffer);
            self.region.light[layer][column][section] = if (std.mem.allEqual(u8, buffer, buffer[0]) and buffer[0] >> 4 == buffer[0] & 15) .{ .uniform = @truncate(buffer[0]) } else .{ .dense = buffer };
        };
        for (0..9) |column| for (0..count) |section| {
            const buffer = &self.section_states[column * count + section];
            for (buffer, 0..) |*value, local| value.* = self.blocks[cellOf(column, section + 1, local)];
            self.region.states[column][section] = if (std.mem.allEqual(u16, buffer, buffer[0])) .{ .uniform = buffer[0] } else .{ .dense = buffer };
        };
        for (self.spares, self.spare_list) |*buffer, *entry| entry.* = buffer;
        self.region.spare = self.spare_list;
    }

    fn cellOf(column: usize, section: usize, local: usize) usize {
        return (section * 16 + local / 256) * level_cells + (column / 3 * 16 + local / 16 % 16) * width + column % 3 * 16 + local % 16;
    }

    /// Writes one edit into the blocks and the stored states of the centre column.
    fn set(self: *Fixture, edit: Edit, value: u16) void {
        self.blocks[cellOf(4, @as(usize, edit.section) + 1, edit.local)] = value;
        const buffer = &self.section_states[4 * count + edit.section];
        buffer[edit.local] = value;
        self.region.states[4][edit.section] = .{ .dense = buffer };
    }

    /// A section that is not loaded reads as dark, which the tests only unload dark ones for.
    fn stored(self: *const Fixture, layer: usize, cell: usize) u4 {
        const at = place(@intCast(cell));
        return switch (self.region.light[layer][at.column][at.section] orelse return 0) {
            .uniform => |value| value,
            .dense => |bytes| @truncate(bytes[at.local / 2] >> @as(u3, @intCast(at.local % 2 * 4))),
        };
    }

    fn snapshot(self: *const Fixture, output: []u8) void {
        for (0..2) |layer| for (0..volume) |cell| {
            output[layer * volume + cell] = self.stored(layer, cell);
        };
    }

    /// The stored light must equal a solve of the current blocks from scratch.
    fn expectSettled(self: *Fixture, fresh: *lighting.Engine) !void {
        try fresh.load(.{ .dense = self.blocks });
        fresh.relight(self.region.skylight);
        for (0..2) |layer| for (0..volume) |cell| {
            const expected = fresh.get(@fromBackingInt(@intCast(layer)), cell);
            const actual = self.stored(layer, cell);
            if (expected == actual) continue;
            std.debug.print("layer={d} cell x={d} y={d} z={d} expected={d} actual={d}\n", .{ layer, cell % width, cell / level_cells, cell / width % width, expected, actual });
            return error.TestUnexpectedResult;
        };
    }
};

test "patched light equals a fresh solve of the nine columns after random edits" {
    for ([_]bool{ true, false }) |skylight| for ([_]u64{ 6, 30 }) |density| {
        const fixture = try Fixture.init(0x9e3779b97f4a7c15 + density, skylight, 1 << 16);
        defer fixture.deinit();
        var fresh = try lighting.Engine.init(fixture.arena.allocator(), .{ .x = width, .y = Fixture.height, .z = width }, Fixture.registry);
        const before = try fixture.arena.allocator().alloc(u8, 2 * Fixture.volume);
        const after = try fixture.arena.allocator().alloc(u8, 2 * Fixture.volume);
        fixture.scatter(density);
        try fixture.load();
        try fixture.expectSettled(&fresh);
        var changed_total: usize = 0;
        for (0..48) |round| {
            var edits: [8]Edit = undefined;
            const batch = 1 + fixture.next() % edits.len;
            for (edits[0..batch]) |*edit| {
                const value = fixture.next();
                // Half the edits stack in one cell column so that sky walks overlap.
                const local: u12 = if (round % 2 == 0) @truncate(value) else @intCast(((value >> 20) % 16) * 256 + 5 * 16 + 7);
                edit.* = .{ .section = @intCast((value >> 12) % Fixture.count), .local = local };
                fixture.set(edit.*, @intCast((value >> 40) % Fixture.states.len));
            }
            fixture.snapshot(before);
            const changes = try fixture.patcher.apply(&fixture.region, edits[0..batch]);
            try fixture.expectSettled(&fresh);
            // The report names exactly the sections whose light differs.
            fixture.snapshot(after);
            var expected: Changes = .{};
            for (0..2) |layer| for (0..Fixture.volume) |cell| {
                if (before[layer * Fixture.volume + cell] == after[layer * Fixture.volume + cell]) continue;
                const at = place(@intCast(cell));
                expected.sections[layer][at.column] |= @as(u32, 1) << @intCast(at.section);
            };
            try std.testing.expectEqual(expected, changes);
            for (0..9) |column| changed_total += @popCount(changes.column(column));
            for (fixture.patcher.seen) |word| assert(word == 0);
        }
        try std.testing.expect(changed_total != 0);
    };
}

test "a patch that cannot finish leaves the light as it was and names what it needs" {
    const fixture = try Fixture.init(0x1234567887654321, true, 1 << 16);
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var fresh = try lighting.Engine.init(allocator, .{ .x = width, .y = Fixture.height, .z = width }, Fixture.registry);
    const before = try allocator.alloc(u8, 2 * Fixture.volume);
    const after = try allocator.alloc(u8, 2 * Fixture.volume);
    // A dark sealed hall over a floor, so that one emitter changes many uniform sections.
    for (fixture.blocks, 0..) |*block, index| {
        const y = index / level_cells;
        block.* = if (y >= 16 and y < 20) 1 else if (y == 60) 1 else 0;
    }
    try fixture.load();
    const emitter: Edit = .{ .section = 1, .local = 8 * 256 + 2 * 16 + 1 };
    fixture.set(emitter, 7);
    fixture.snapshot(before);
    const region = &fixture.region;

    // Without spare buffers the uniform dark sections cannot take the new light.
    const spares = region.spare;
    region.spare = spares[0..0];
    try std.testing.expectError(error.NoSpareSection, fixture.patcher.apply(region, &.{emitter}));
    try std.testing.expectEqual(@as(usize, 0), region.spare.len);
    fixture.snapshot(after);
    try std.testing.expectEqualSlices(u8, before, after);
    try std.testing.expect(region.light[0][4][2].? == .uniform);

    // A patcher too small for the patch gives every buffer back.
    var small = try Patcher.init(allocator, Fixture.registry, 64);
    region.spare = spares;
    try std.testing.expectError(error.PatchTooLarge, small.apply(region, &.{emitter}));
    try std.testing.expectEqual(spares.len, region.spare.len);
    fixture.snapshot(after);
    try std.testing.expectEqualSlices(u8, before, after);
    for (small.seen) |word| assert(word == 0);

    // Missing light and missing states are reported one section at a time until it fits.
    const west_light = region.light[0][3][2];
    const west_states = region.states[3][1];
    try std.testing.expectEqual(Light{ .uniform = 0 }, west_light.?);
    region.light[0][3][2] = null;
    region.states[3][1] = null;
    var loads: usize = 0;
    const changes = while (true) {
        break fixture.patcher.apply(region, &.{emitter}) catch |err| {
            try std.testing.expectEqual(error.MissingSection, err);
            const missing = fixture.patcher.missing.?;
            try std.testing.expectEqual(@as(u8, 3), missing.column);
            fixture.snapshot(after);
            try std.testing.expectEqualSlices(u8, before, after);
            try std.testing.expectEqual(spares.len, region.spare.len);
            switch (missing.kind) {
                .light => {
                    try std.testing.expectEqual(@as(u8, 2), missing.section);
                    region.light[0][3][2] = west_light;
                },
                .states => {
                    try std.testing.expectEqual(@as(u8, 1), missing.section);
                    region.states[3][1] = west_states;
                },
            }
            loads += 1;
            try std.testing.expect(loads <= 2);
            continue;
        };
    };
    try std.testing.expectEqual(@as(usize, 2), loads);
    // The emitter sits one cell from the west column and lights it.
    try std.testing.expect(changes.sections[0][3] != 0 and changes.sections[0][4] != 0);
    try std.testing.expectEqual(@as(u32, 0), changes.sections[0][5]);
    try std.testing.expect(region.spare.len < spares.len);
    try fixture.expectSettled(&fresh);
}

test "a patch visits only what an edit can reach" {
    const fixture = try Fixture.init(0x0f0e0d0c0b0a0908, true, 1 << 16);
    defer fixture.deinit();
    for (fixture.blocks, 0..) |*block, index| {
        const y = index / level_cells;
        block.* = if (y >= 16 and y < 20) 1 else 0;
    }
    try fixture.load();
    // An opaque block under open sky dims the cells below it and nothing else.
    const roof: Edit = .{ .section = 2, .local = 4 * 256 + 8 * 16 + 8 };
    fixture.set(roof, 1);
    var changes = try fixture.patcher.apply(&fixture.region, &.{roof});
    try std.testing.expectEqual(@as(u32, 0), changes.sections[0][4]);
    try std.testing.expectEqual(@as(u32, 0b1110), changes.sections[1][4]);
    for (0..9) |column| if (column != 4) try std.testing.expectEqual(@as(u32, 0), changes.column(column));
    try std.testing.expect(fixture.patcher.work.visited < 512);
    // A block that lights like the one it replaces changes nothing and visits almost nothing.
    const glass: Edit = .{ .section = 1, .local = 9 * 256 + 3 * 16 + 3 };
    fixture.set(glass, 0);
    changes = try fixture.patcher.apply(&fixture.region, &.{glass});
    for (0..9) |column| try std.testing.expectEqual(@as(u32, 0), changes.column(column));
    try std.testing.expect(fixture.patcher.work.visited <= 16);
}

test "a cell that keeps its own light can still stop lighting its neighbour" {
    const fixture = try Fixture.init(0x0102030405060708, true, 1 << 16);
    defer fixture.deinit();
    var fresh = try lighting.Engine.init(fixture.arena.allocator(), .{ .x = width, .y = Fixture.height, .z = width }, Fixture.registry);
    for (fixture.blocks, 0..) |*block, index| {
        const y = index / level_cells;
        block.* = if (y >= 16 and y < 20) 1 else 0;
    }
    // A shaped cell walled in on every side but the west, where an open cell under the
    // sky is its only light.
    const local = struct {
        fn at(x: usize, y: usize, z: usize) u12 {
            return @intCast(y * 256 + z * 16 + x);
        }
    }.at;
    const lit = local(4, 8, 4);
    fixture.blocks[Fixture.cellOf(4, 2, lit)] = 5;
    for ([_]u12{ local(5, 8, 4), local(4, 8, 3), local(4, 8, 5), local(4, 7, 4) }) |wall| fixture.blocks[Fixture.cellOf(4, 2, wall)] = 1;
    try fixture.load();
    const lit_cell = Fixture.cellOf(4, 2, lit);
    const open: Edit = .{ .section = 1, .local = local(3, 8, 4) };
    try std.testing.expectEqual(@as(u4, 15), fixture.stored(1, Fixture.cellOf(4, 2, open.local)));
    try std.testing.expectEqual(@as(u4, 14), fixture.stored(1, lit_cell));
    // The new block still sees the sky, and its side faces close against the shaped cell.
    fixture.set(open, 6);
    const changes = try fixture.patcher.apply(&fixture.region, &.{open});
    try std.testing.expectEqual(@as(u4, 15), fixture.stored(1, Fixture.cellOf(4, 2, open.local)));
    try std.testing.expectEqual(@as(u4, 0), fixture.stored(1, lit_cell));
    try std.testing.expectEqual(@as(u32, 0b100), changes.sections[1][4]);
    try fixture.expectSettled(&fresh);
}
