const std = @import("std");
const section_views = @import("lighting").section_views;
const storage = @import("storage");
const records = @import("records");
const chunks = @import("chunks");
const game_data = @import("game_data");
const geometry = @import("bounds.zig");
const visibility = @import("section_visibility.zig");
const chunk_horizon = @import("chunk_horizon.zig");
const disclosure = @import("section_disclosure.zig");
const section_visibility_source = @import("section_visibility_source.zig");
const assert = std.debug.assert;
pub const occluder_property: u8 = 1;
const column_metadata_bytes = (5 + 36) * @sizeOf(u32);
pub const prepared_codec: chunks.classification.Codec = .{
    .identity = "lightning_rod:section_visibility:7",
    .maximum = visibility.Section.prepared_bytes,
    .prefix_bytes = visibility.Section.prefix_bytes,
    .encode = prepareSection,
    .column = .{ .identity = "lightning_rod:column_visibility:4", .maximum = column_metadata_bytes, .encode = prepareColumn },
};

fn prepareColumn(summary_: *const chunks.classification.ColumnSummary, output: []u8) storage.Error!usize {
    assert(output.len >= column_metadata_bytes and summary_.prefix_bytes == prepared_codec.prefix_bytes);
    var known: u32 = 0;
    var open: u32 = 0;
    var closed: u32 = 0;
    var air: u32 = 0;
    var stone: u32 = 0;
    var topology: disclosure.Column = .{};
    var pending = summary_.known;
    while (pending != 0) : (pending &= pending - 1) {
        const offset = @ctz(pending);
        const bit = @as(u32, 1) << @intCast(offset);
        const common = summary_.common[offset];
        const section: disclosure.Topology = if (common & occluder_property != 0) .closed else if (common & open_property != 0) .open else if (summary_.prefixed & bit != 0) try visibility.Section.prefixTopology(summary_.prefixes[offset][0..summary_.prefix_bytes]) else continue;
        topology.set(offset, section);
        known |= bit;
        open |= bit * @intFromBool(common & open_property != 0);
        closed |= bit * @intFromBool(common & occluder_property != 0);
        air |= bit * @intFromBool(common & air_property != 0);
        stone |= bit * @intFromBool(common & stone_property != 0);
    }
    for ([_]u32{ known, open, closed, air, stone }, 0..) |value, index| std.mem.writeInt(u32, output[index * 4 ..][0..4], value, .little);
    for (topology.paths, 0..) |value, index| std.mem.writeInt(u32, output[20 + index * 4 ..][0..4], value, .little);
    return column_metadata_bytes;
}

fn prepareSection(classified: *const chunks.encoding.Classification.Known, output: []u8) storage.Error!usize {
    assert(classified.property == occluder_property);
    const bits: @Vector(64, u64) = classified.selected;
    if (@reduce(.Or, bits) == 0 or @reduce(.And, bits) == std.math.maxInt(u64)) return 0;
    var data: visibility.Section = .{};
    var workspace: visibility.Workspace = undefined;
    data.build(&classified.selected, &workspace, output);
    return data.writePrepared(output);
}
const open_property: u8 = 2;
const air_property: u8 = 4;
const stone_property: u8 = 8;
const no_section = std.math.maxInt(u32);

pub const Column = struct { world: u32, x: i32, z: i32, minimum: i32 };
pub const camera_margin = 5;
const source_side = 16 + 2 * camera_margin;
const source_volume = source_side * source_side * source_side;
const open_section: visibility.Section = .{};
const closed_section: visibility.Section = .{
    .solid = @splat(std.math.maxInt(u64)),
    .connections = @splat(0),
    .faces = 0,
    .components = 0,
    .boundary_components = 0,
    .kind = .solid,
    .topology = .closed,
    .boundary_open = false,
};
comptime {
    assert(camera_margin > 0 and camera_margin < 16 and source_side <= 32);
}
/// Tells fast heads from slow ones by how long they stay in a section.
/// Fast heads keep the octant flood and its section-wide reuse: rebuilding direction cones
/// every few blocks costs far more than the few sections they hide at flight speed.
pub const Pace = struct {
    /// Moving updates a head must spend in one section to count as slow, about a second.
    pub const slow_updates = 20;

    section: ?[3]i32 = null,
    updates: u32 = 0,
    fast: bool = false,

    pub fn observe(self: *Pace, point: [3]i32) void {
        const section = [3]i32{ @divFloor(point[0], 16), @divFloor(point[1], 16), @divFloor(point[2], 16) };
        if (self.section) |previous| {
            if (std.meta.eql(previous, section)) {
                self.updates +|= 1;
                if (self.updates >= slow_updates) self.fast = false;
                return;
            }
            self.fast = self.updates < slow_updates;
        }
        self.section = section;
        self.updates = 0;
    }

    pub fn precision(self: *const Pace) Source.Precision {
        return if (self.fast) .octant else .head;
    }
};

test "pace treats quick section crossings as fast and lingering as slow" {
    var pace: Pace = .{};
    try std.testing.expectEqual(Source.Precision.head, pace.precision());
    for (0..4) |step| pace.observe(.{ @as(i32, @intCast(step)) * 16, 70, 0 });
    try std.testing.expectEqual(Source.Precision.octant, pace.precision());
    for (0..Pace.slow_updates) |_| pace.observe(.{ 50, 70, 0 });
    try std.testing.expectEqual(Source.Precision.head, pace.precision());
    pace.observe(.{ 70, 70, 0 });
    try std.testing.expectEqual(Source.Precision.head, pace.precision());
}

pub const Source = struct {
    // A captured component can extend one section along both horizontal axes.
    pub const horizon_padding = 2;
    section: chunks.Section,
    component: u12,
    point: [3]i32,
    camera_bounds: visibility.Bounds,
    // Heads that may reuse this source, and the box their eyes (or cameras) stay within.
    // Flood rays start inside `eye`; null keeps every direction of each octant.
    reach: visibility.Bounds = undefined,
    eye: ?visibility.Bounds = null,
    precision: Precision = .octant,
    cells: u32 = 0,
    open_cells: u27 = 0,
    starts: [27]u6 = @splat(0),
    membership: [64]u64 = @splat(0),

    pub fn bounds(self: *const Source) geometry.Box {
        return .{ .minimum = .{ self.section.x * 16 - 16, self.section.y * 16 - 16, self.section.z * 16 - 16 }, .maximum = .{ self.section.x * 16 + 32, self.section.y * 16 + 32, self.section.z * 16 + 32 } };
    }

    /// How tightly flood rays are tied to the head. Head cells are aligned and divide
    /// sections, so a cell never spans two sources. Larger cells reuse a flood longer
    /// but widen the eye box and so disclose more.
    pub const Precision = enum {
        /// Every direction of each octant; reused across the section and its open neighbors.
        octant,
        /// Rays start in the head cell widened by the third-person camera margin.
        cell,
        /// Rays start in the head cell alone, ignoring the third-person camera.
        head,

        /// Head cells are aligned and divide sections, so a cell never spans two sources.
        pub const cell_size = 4;
        comptime {
            assert(16 % cell_size == 0);
        }

        fn margin(self: Precision) i32 {
            return if (self == .cell) camera_margin else 0;
        }
    };
    /// Blocks the eye can sit below the standing eye that callers pass as the point.
    pub const pose_drop = 2;

    /// Limits where flood rays start; the head stays inside `reach` while this source is reused.
    /// Head precision ignores the third-person camera: its cameras sit within four blocks of
    /// the eye and the cones are coarse, so it disclosed nothing more for any sampled F5
    /// camera in the cave benchmarks, while hiding about half of what the margin let through.
    pub fn limitEye(self: *Source, precision: Precision) void {
        if (precision == .octant) return;
        const cell_size = Precision.cell_size;
        const margin = precision.margin();
        // A sealed source discloses only its own section, so directions cannot matter.
        if (self.cells == 1 << 13 and self.starts[13] == 0) return;
        // Open air is reused across the whole neighborhood, which keeps fast flight cheap.
        // Its flood seeds all 27 sections, so rays start anywhere in them and nowhere else.
        const open = self.open_cells == std.math.maxInt(u27);
        const origin = [3]i32{ self.section.x * 16, self.section.y * 16, self.section.z * 16 };
        var eye: visibility.Bounds = undefined;
        for (0..3) |axis| {
            const cell = @divFloor(self.point[axis], cell_size) * cell_size;
            self.reach.minimum[axis] = if (open) origin[axis] - 16 else cell;
            self.reach.maximum[axis] = if (open) origin[axis] + 32 else cell + cell_size;
            eye.minimum[axis] = if (open) self.reach.minimum[axis] else self.reach.minimum[axis] - margin;
            eye.maximum[axis] = if (open) self.reach.maximum[axis] else self.reach.maximum[axis] + margin;
            // The reused point is the standing eye; crouching, swimming and crawling lower it.
            if (axis == 1 and !open) eye.minimum[axis] -= pose_drop;
            // Outside open air the camera stays in the head's component, which the camera bounds hold.
            if (!open) {
                eye.minimum[axis] = @max(eye.minimum[axis], self.camera_bounds.minimum[axis]);
                eye.maximum[axis] = @min(eye.maximum[axis], self.camera_bounds.maximum[axis]);
            }
            assert(self.reach.minimum[axis] <= self.point[axis] and self.point[axis] < self.reach.maximum[axis]);
            assert(eye.minimum[axis] < eye.maximum[axis]);
        }
        self.eye = eye;
        self.precision = precision;
    }

    pub fn supports(self: *const Source, world: u32, point: [3]i32) bool {
        if (world != self.section.world) return false;
        if (std.meta.eql(self.point, point)) return true;
        if (self.eye != null) {
            for (point, self.reach.minimum, self.reach.maximum) |value, minimum, maximum| {
                if (value < minimum or value >= maximum) return false;
            }
        }
        const x = @as(i64, @divFloor(point[0], 16)) - self.section.x;
        const y = @as(i64, @divFloor(point[1], 16)) - self.section.y;
        const z = @as(i64, @divFloor(point[2], 16)) - self.section.z;
        if (@abs(x) > 1 or @abs(y) > 1 or @abs(z) > 1) return false;
        if (x != 0 or y != 0 or z != 0) {
            const cell: u5 = @intCast((z + 1) * 9 + (y + 1) * 3 + x + 1);
            return self.open_cells & (@as(u27, 1) << cell) != 0;
        }
        const bits = &self.membership;
        const index: usize = @intCast(@mod(point[1], 16) * 256 + @mod(point[2], 16) * 16 + @mod(point[0], 16));
        return bits[index / 64] & (@as(u64, 1) << @as(u6, @intCast(index % 64))) != 0;
    }
};

const Tile = struct {
    index: usize = 0,
    column: ?Column = null,
    count: usize = 0,
    known: u32 = 0,
    classified: u32 = 0,
    initialized: u32 = 0,
    air: u32 = 0,
    stone: u32 = 0,
    open: u32 = 0,
    closed: u32 = 0,
    previous: ?usize = null,
    next: ?usize = null,
    sections: [section_views.maximum_sections]u32 = @splat(no_section),
    topology: disclosure.Column = .{},
    topology_known: u32 = 0,
};

const MixedSection = struct {
    data: *visibility.Section = undefined,
    tile: ?usize = null,
    offset: usize = 0,
    previous: ?usize = null,
    next: ?usize = null,
};

const Summary = struct {
    classified: u32 = 0,
    topology: disclosure.Column = .{},
    topology_known: u32 = 0,
    open: u32,
    closed: u32,
    air: u32,
    stone: u32,
    count: u8,

    fn section(self: *const Summary, offset: usize) ?*const visibility.Section {
        assert(offset < self.count);
        const bit = @as(u32, 1) << @intCast(offset);
        if (self.open & bit != 0) return &open_section;
        if (self.closed & bit != 0) return &closed_section;
        return null;
    }
};

const Key = struct { section: chunks.Section, component: u12, minimum: i32, count: usize, radius: i32 };

// The flood and its direction bounds are tested with the world that drives them.
test {
    _ = disclosure;
    _ = @import("section_cone.zig");
}

test "column batches acquire topology once and preserve scalar classifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var scalar = try World.init(bounded.allocator(), .{ .columns = 2, .views = 1, .radius = 0 });
    var batched = try World.init(bounded.allocator(), .{ .columns = 2, .views = 1, .radius = 0 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const count = 24;
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = -4 };
    var sections: [count]section_views.Section = undefined;
    for (&sections, 0..) |*section, index| section.* = .{ .stamp = .{}, .view = .{ .uniform = if (index < 12) game_data.registry.block_stone_default_state else 0 } };
    for (0..2) |pass| {
        for (sections, 0..) |section, offset| scalar.learnSection(column, count, offset, section.view);
        batched.learn(column, &sections);
        try std.testing.expectEqual(@as(u64, count * (pass + 1)), scalar.acquisitions);
        try std.testing.expectEqual(@as(u64, pass + 1), batched.acquisitions);
    }
    var classifications: [count]chunks.encoding.Classification = undefined;
    var reads: [count]chunks.Chunks.ClassificationRequest = undefined;
    for (&classifications, &reads, 0..) |*classification, *read, index| {
        const solid = index < 12;
        classification.* = .{ .known = .{
            .common = if (solid) occluder_property | stone_property else open_property | air_property,
            .property = occluder_property,
            .selected = @splat(if (solid) std.math.maxInt(u64) else 0),
        } };
        read.* = .{ .section = .{ .world = 0, .x = 1, .y = @as(i32, @intCast(index)) - 4, .z = 0 }, .result = classification };
        try std.testing.expect(scalar.learnClassification(.{ .world = 0, .x = 1, .z = 0, .minimum = -4 }, count, index, classification));
    }
    try std.testing.expect(try batched.learnClassifications(&reads, -4, count, .source));
    try std.testing.expectEqual(@as(u64, 3 * count), scalar.acquisitions);
    try std.testing.expectEqual(@as(u64, 3), batched.acquisitions);
    for ([_]Column{ column, .{ .world = 0, .x = 1, .z = 0, .minimum = -4 } }) |at| {
        const expected = scalar.tiles[scalar.lookup.get(at).?];
        const actual = batched.tiles[batched.lookup.get(at).?];
        try std.testing.expectEqual(expected.known, actual.known);
        try std.testing.expectEqual(expected.open, actual.open);
        try std.testing.expectEqual(expected.closed, actual.closed);
        try std.testing.expectEqual(expected.air, actual.air);
        try std.testing.expectEqual(expected.stone, actual.stone);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

const View = struct {
    key: ?Key = null,
    masks: []u32,
    outgoing: []u32,
    capture_frontier: bool = false,
    masks_key: ?Key = null,
    mask_changes: std.DynamicBitSetUnmanaged,
    topology_slots: []u32,
    topology_cached: std.DynamicBitSetUnmanaged,

    origin: Source = undefined,
    source_dirty: bool = false,

    ready: bool = false,
    revision: u64 = 0,
};

test "retained topology survives cache churn and releases replaced windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 1, .views = 1, .radius = 0, .summary_columns = 2 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    world.learnSection(column, 2, 0, .{ .uniform = 0 });
    world.learnSection(column, 2, 1, .{ .uniform = 0 });
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 2, 0, .{ .uniform = 0 });
    try std.testing.expectEqual(@as(u32, 3), world.cachedTopology(0, column, 2).?.known);
    const lookups = world.topology_lookups;
    for (0..64) |_| try std.testing.expectEqual(@as(u32, 3), world.cachedTopology(0, column, 2).?.known);
    try std.testing.expectEqual(lookups, world.topology_lookups);
    try std.testing.expectEqual(@as(u64, 64), world.topology_reuses);
    world.changed(0, 0, .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 1, 1, 1 } }, false);
    try std.testing.expectEqual(@as(u32, 2), world.cachedTopology(0, column, 2).?.known);
    world.learnSection(column, 2, 0, .{ .uniform = game_data.registry.block_stone_default_state });
    const updated = world.cachedTopology(0, column, 2).?;
    try std.testing.expectEqual(@as(u32, 3), updated.known);
    try std.testing.expectEqualDeep(disclosure.Topology.closed, updated.topology.get(0));
    for (2..6) |x| world.learnSection(.{ .world = 0, .x = @intCast(x), .z = 0, .minimum = 0 }, 2, 0, .{ .uniform = 0 });
    try std.testing.expectEqual(@as(u32, 3), world.cachedTopology(0, column, 2).?.known);
    const replacement: Column = .{ .world = 0, .x = 5, .z = 0, .minimum = 0 };
    try std.testing.expectEqual(@as(u32, 1), world.cachedTopology(0, replacement, 2).?.known);
    for (6..10) |x| world.learnSection(.{ .world = 0, .x = @intCast(x), .z = 0, .minimum = 0 }, 2, 0, .{ .uniform = 0 });
    try std.testing.expect(world.cachedTopology(0, column, 2) == null);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "fully retained topology pools decline optional entries without recycling leases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 1, .views = 2, .radius = 0, .summary_columns = 2 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const a: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const b: Column = .{ .world = 0, .x = 1, .z = 0, .minimum = 0 };
    const c: Column = .{ .world = 0, .x = 2, .z = 0, .minimum = 0 };
    world.learnSection(a, 1, 0, .{ .uniform = 0 });
    _ = world.cachedTopology(0, a, 1).?;
    world.learnSection(b, 1, 0, .{ .uniform = 0 });
    _ = world.cachedTopology(1, b, 1).?;
    try std.testing.expect(world.reserveSummary(c, 1) == null);
    try std.testing.expectEqual(@as(u32, 1), world.cachedTopology(0, a, 1).?.known);
    try std.testing.expectEqual(@as(u32, 1), world.cachedTopology(1, b, 1).?.known);
    world.releaseTopology(0, 0);
    try std.testing.expect(world.reserveSummary(c, 1) != null);
    try std.testing.expectEqual(@as(u32, 1), world.cachedTopology(1, b, 1).?.known);
    world.invalidate();
    for (world.summary_references) |references| try std.testing.expectEqual(@as(usize, 0), references);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "summary leases and eviction capacity match independent observer ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 1, .views = 8, .radius = 0, .summary_columns = 12 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var expected: [8]?Column = @splat(null);
    var random = std.Random.DefaultPrng.init(0x4bd17e);
    const none = std.math.maxInt(u32);
    for (0..4096) |step| {
        const owner = random.random().uintLessThan(usize, expected.len);
        if (step % 19 == 0) {
            world.invalidate();
            expected = @splat(null);
        } else if (step % 5 == 0) {
            world.releaseTopology(owner, 0);
            expected[owner] = null;
        } else {
            const column: Column = .{ .world = random.random().uintLessThan(u32, 3), .x = random.random().intRangeAtMost(i32, -16, 16), .z = random.random().intRangeAtMost(i32, -16, 16), .minimum = 0 };
            const summary_ = world.reserveSummary(column, 1).?;
            summary_.open = 1;
            summary_.topology.set(0, .open);
            summary_.topology_known = 1;
            try std.testing.expectEqual(@as(u32, 1), world.cachedTopology(owner, column, 1).?.known);
            expected[owner] = column;
        }
        var references: [12]usize = @splat(0);
        for (expected, 0..) |column, owner_| {
            const slot = world.views[owner_].topology_slots[0];
            if (column) |key| {
                try std.testing.expect(slot < world.summary_keys.len);
                try std.testing.expectEqualDeep(key, world.summary_keys[slot]);
                references[slot] += 1;
            } else try std.testing.expectEqual(none, slot);
        }
        try std.testing.expectEqualSlices(usize, &references, world.summary_references);
        var queued: [12]bool = @splat(false);
        var cursor = world.summary_oldest;
        var previous: u32 = none;
        while (cursor != none) {
            try std.testing.expect(cursor < queued.len and !queued[cursor]);
            try std.testing.expectEqual(previous, world.summary_previous[cursor]);
            queued[cursor] = true;
            previous = cursor;
            cursor = world.summary_next[cursor];
        }
        try std.testing.expectEqual(previous, world.summary_newest);
        for (queued, references) |available, count| try std.testing.expectEqual(count == 0, available);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "prepared column metadata equals section prefixes and rejects malformed masks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var reference = try World.init(bounded.allocator(), .{ .columns = 1, .views = 1, .radius = 0, .summary_columns = 4 });
    var prepared = try World.init(bounded.allocator(), .{ .columns = 1, .views = 1, .radius = 0, .summary_columns = 4 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const column: chunks.classification.Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0, .count = 8 };
    const key: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    var input: chunks.classification.ColumnSummary = .{ .known = 255, .prefixed = 0, .prefix_bytes = prepared_codec.prefix_bytes };
    for (0..8) |offset| {
        if (offset % 3 == 0) {
            input.common[offset] = open_property | air_property;
        } else if (offset % 3 == 1) {
            input.common[offset] = occluder_property | stone_property;
        } else {
            input.prefixed |= @as(u32, 1) << @intCast(offset);
            std.mem.writeInt(u40, input.prefixes[offset][0..visibility.Section.prefix_bytes], disclosure.Topology.open.paths, .little);
        }
    }
    _ = try reference.learnColumnTopology(&.{column}, &.{input});
    var bytes: [column_metadata_bytes]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try prepareColumn(&input, &bytes));
    try std.testing.expect(try prepared.learnPreparedColumn(key, 8, &bytes));
    try std.testing.expectEqualDeep(reference.summary(key, 8).?.*, prepared.summary(key, 8).?.*);
    const original = bytes;
    bytes[3] = 128;
    try std.testing.expectError(error.Corrupt, prepared.learnPreparedColumn(key, 8, &bytes));
    bytes = original;
    bytes[4] |= 2;
    try std.testing.expectError(error.Corrupt, prepared.learnPreparedColumn(key, 8, &bytes));
    bytes = original;
    bytes[20] |= 2;
    try std.testing.expectError(error.Corrupt, prepared.learnPreparedColumn(key, 8, &bytes));
    try std.testing.expectError(error.Corrupt, prepared.learnPreparedColumn(key, 8, bytes[0 .. bytes.len - 1]));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "delivery constants fill summaries without admitting or evicting voxel tiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 1, .views = 1, .radius = 0, .summary_columns = 4 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var sections = [_]section_views.Section{
        .{ .stamp = .{ .constant = 0 }, .view = .{ .uniform = 0 } },
        .{ .stamp = .{ .constant = stone }, .view = .{ .uniform = stone } },
    };
    world.learnConstants(column, &sections);
    world.learnConstants(column, &sections);
    try std.testing.expectEqual(@as(usize, 0), world.lookup.count());
    try std.testing.expectEqual(@as(u64, 0), world.acquisitions);
    try std.testing.expectEqual(@as(u32, 3), world.knownTopology(column, 2));
    try std.testing.expectEqual(@as(u32, 2), world.stoneMask(column, 2));
    world.changed(0, 0, .{ .minimum = .{ 0, 16, 0 }, .maximum = .{ 16, 32, 16 } }, false);
    sections[1] = sections[0];
    world.learnConstants(column, &sections);
    try std.testing.expectEqual(@as(u32, 3), world.knownTopology(column, 2));
    try std.testing.expectEqual(@as(u32, 0), world.stoneMask(column, 2));
    try std.testing.expectEqual(@as(usize, 0), world.lookup.count());
    try std.testing.expectEqual(@as(u64, 0), world.acquisitions);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "resident topology supplies complete traversals without section frontiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = 1, .summary_columns = 16 });
    for (0..9) |column| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(column % 3)) - 1, .z = @as(i32, @intCast(column / 3)) - 1, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    var origin: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 8, 8 }, &origin).?;
    world.begin(0, source, 0, 1, 1);
    try finishView(&world, 0);
    const lookups = world.topology_lookups;
    const reuses = world.topology_reuses;
    for (0..32) |_| {
        world.begin(0, source, 0, 1, 1);
        const result = world.advance();
        try std.testing.expect(world.ready(0));
        try std.testing.expectEqual(@as(usize, 0), result.requests.len);
        try std.testing.expectEqual(lookups, world.topology_lookups);
    }
    try std.testing.expectEqual(@as(u64, 32 * 9), world.topology_reuses - reuses);
}

test "debug frontier capture cannot reuse a snapshot without its stopping metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 2, .radius = 1 });
    for (0..9) |column| {
        const at: Column = .{ .world = 0, .x = @as(i32, @intCast(column % 3)) - 1, .z = @as(i32, @intCast(column / 3)) - 1, .minimum = 0 };
        for (0..3) |y| world.learnSection(at, 3, y, .{ .uniform = if (column == 4 and y == 1) 0 else game_data.registry.block_stone_default_state });
    }
    var origin: Source = undefined;
    const source = world.source(0, 0, 3, .{ 8, 24, 8 }, &origin).?;
    world.begin(0, source, 0, 3, 1);
    try finishView(&world, 0);
    world.captureFrontier(1, true);
    try std.testing.expect(!world.reuse(1, 0, .{ 8, 24, 8 }, 0, 3, 1, .octant));
    world.begin(1, source, 0, 3, 1);
    try finishView(&world, 1);
    for ([_][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } }) |at| {
        try std.testing.expectEqual(@as(u32, 2), world.stoppingMask(1, at[0], at[1]));
    }
    try std.testing.expectEqual(@as(u32, 5), world.stoppingMask(1, 0, 0));
    world.captureFrontier(0, true);
    try std.testing.expect(world.reuse(0, 0, .{ 8, 24, 8 }, 0, 3, 1, .octant));
    try std.testing.expectEqualSlices(u32, world.views[0].outgoing, world.views[1].outgoing);
}

test "column changes exactly describe overlapping shifted snapshots and domain changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const side = 17;
    var world = try World.init(arena.allocator(), .{ .columns = side * side, .views = 2, .radius = side / 2 });
    var random = std.Random.DefaultPrng.init(0x77182);
    var masks: [side * side]u32 = undefined;
    var previous: ?Key = null;
    var before: [side * side]u32 = undefined;
    for (0..64) |step| {
        const key: Key = .{
            .section = .{ .world = @intCast(step / 19), .x = @as(i32, @intCast(step / 3)) - 7, .y = 0, .z = @as(i32, @intCast(step / 7)) - 5 },
            .component = 0,
            .minimum = if (step % 13 == 0) -2 else -4,
            .count = 24,
            .radius = side / 2,
        };
        var expected: [side * side]bool = @splat(true);
        const compatible = if (previous) |old| old.section.world == key.section.world and old.minimum == key.minimum else false;
        for (&masks, 0..) |*mask, column| {
            mask.* = random.random().int(u24);
            if (!compatible) continue;
            const old = previous.?;
            const x = @as(i32, @intCast(column % side)) + key.section.x - old.section.x;
            const z = @as(i32, @intCast(column / side)) + key.section.z - old.section.z;
            if (x < 0 or x >= side or z < 0 or z >= side) continue;
            const prior = before[@as(usize, @intCast(z)) * side + @as(usize, @intCast(x))];
            if (column % 3 != 0) mask.* = prior;
            expected[column] = prior != mask.*;
        }
        world.views[0].key = key;
        world.recordMasks(0, &masks);
        world.views[0].ready = true;
        var changes = world.changes(0);
        var found: [side * side]bool = @splat(false);
        while (changes.next()) |at| {
            const column: usize = @intCast((at.z - key.section.z + key.radius) * side + at.x - key.section.x + key.radius);
            try std.testing.expect(!found[column]);
            found[column] = true;
        }
        try std.testing.expectEqual(expected, found);
        try std.testing.expectEqualSlices(u32, &masks, world.views[0].masks);
        before = masks;
        previous = key;
    }
    world.copyView(1, 0);
    var first = world.changes(1);
    var count: usize = 0;
    while (first.next() != null) count += 1;
    try std.testing.expectEqual(@as(usize, side * side), count);
    world.copyView(1, 0);
    var second = world.changes(1);
    try std.testing.expect(second.next() == null);
}

test "active visibility working set survives unrelated bursts with and without spare columns" {
    for ([_]usize{ 9, 10 }) |capacity| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var world = try World.init(arena.allocator(), .{ .columns = capacity, .views = 1, .radius = 1 });
        world.views[0].key = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .component = 0, .minimum = 0, .count = 1, .radius = 1 };
        world.active = 0;
        for (0..9) |index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        for (0..64) |index| world.learnSection(.{ .world = 0, .x = @intCast(100 + index), .z = 0, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        for (0..9) |index| try std.testing.expect(world.known(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .y = 0 }, 0, 1));
        try std.testing.expectEqual(@as(u64, 0), world.working_evictions);
        try std.testing.expectEqual(@as(u64, if (capacity == 9) 0 else 63), world.evictions);
        world.active = null;
        world.learnSection(.{ .world = 0, .x = 200, .z = 0, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        try std.testing.expect(world.known(.{ .world = 0, .x = 200, .z = 0, .y = 0 }, 0, 1));
    }
}

test "visibility snapshot completes while unrelated columns compete for the shared cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    for (0..9) |index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 8, 8 }, &source_storage) orelse return error.TestUnexpectedResult;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 1, 2);
    var rounds: usize = 0;
    while (!world.ready(view_index)) : (rounds += 1) {
        try std.testing.expect(rounds < 8 * 25);
        const result = world.advance();
        for (result.requests) |section| world.learnSection(.{ .world = section.world, .x = section.x, .z = section.z, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        for (0..32) |index| world.learnSection(.{ .world = 0, .x = @intCast(100 + rounds * 32 + index), .z = 0, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        for (result.requests) |at| try std.testing.expect(world.known(.{ .world = at.world, .x = at.x, .y = at.minimum, .z = at.z }, 0, 1));
    }
    try std.testing.expectEqual(@as(u64, 1), world.completed);
}

test "mixed topology eviction preserves exact disclosure and invalidates edits to evicted geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var worlds = [_]World{
        try World.init(bounded.allocator(), .{ .columns = 49, .views = 1, .radius = 3, .mixed_sections = 219 }),
        try World.init(bounded.allocator(), .{ .columns = 49, .views = 1, .radius = 3, .mixed_sections = 49 * section_views.maximum_sections }),
    };
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var states: [4096]u16 = @splat(0);
    states[0] = game_data.registry.block_stone_default_state;
    var sources: [2]Source = undefined;
    var handles: [2]usize = undefined;
    for (&worlds, &sources, &handles) |*world, *source, *handle| {
        for (0..49) |index| for (0..8) |y| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 7)) - 3, .z = @as(i32, @intCast(index / 7)) - 3, .minimum = 0 }, 8, y, .{ .dense = &states });
        var neighborhood: [27]chunks.Section = undefined;
        for (World.sourceRequirements(0, 0, 8, .{ 8, 24, 8 }, &neighborhood)) |section|
            world.learnSection(.{ .world = 0, .x = section.x, .z = section.z, .minimum = 0 }, 8, @intCast(section.y), .{ .dense = &states });
        _ = world.source(0, 0, 8, .{ 8, 24, 8 }, source) orelse return error.SourceUnavailable;
        handle.* = @as(usize, 0);
        world.begin(handle.*, source, 0, 8, 3);
        var calls: usize = 0;
        while (!world.ready(handle.*)) : (calls += 1) {
            try std.testing.expect(calls < 4096);
            const advance = world.advance();
            for (advance.requests) |column| for (0..column.count) |offset|
                world.learnSection(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum }, column.count, offset, .{ .dense = &states });
        }
        try std.testing.expect(world.mixed_used <= world.mixed.len);
    }
    try std.testing.expect(worlds[0].mixed_evictions > 0);
    try std.testing.expectEqual(@as(u64, 0), worlds[1].mixed_evictions);
    for (0..49) |index| {
        const x = @as(i32, @intCast(index % 7)) - 3;
        const z = @as(i32, @intCast(index / 7)) - 3;
        try std.testing.expectEqual(worlds[1].mask(handles[1], x, z), worlds[0].mask(handles[0], x, z));
    }
    const world = &worlds[0];
    const victim = world.mixed[world.oldest_mixed.?];
    const column = world.tiles[victim.tile.?].column.?;
    refill: for (0..49) |index| for (0..8) |y| {
        if (world.tiles[index].known & (@as(u32, 1) << @intCast(y)) != 0) continue;
        world.learnSection(world.tiles[index].column.?, 8, y, .{ .dense = &states });
        break :refill;
    };
    try std.testing.expect(world.ready(handles[0]));
    try std.testing.expect(!world.known(.{ .world = 0, .x = column.x, .z = column.z, .y = @intCast(victim.offset) }, 0, 8));
    world.changed(0, 0, .{ .minimum = .{ column.x * 16, @as(i32, @intCast(victim.offset)) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 1, @as(i32, @intCast(victim.offset)) * 16 + 1, column.z * 16 + 1 } }, false);
    try std.testing.expect(!world.ready(handles[0]));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "mixed topology slots return to the pool after homogeneous edits and column replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 1, .views = 1, .radius = 0 });
    var states: [4096]u16 = @splat(0);
    states[0] = game_data.registry.block_stone_default_state;
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const bounds: geometry.Box = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } };
    for (0..world.mixed.len * 2) |_| {
        world.learnSection(column, 1, 0, .{ .dense = &states });
        try std.testing.expectEqual(@as(usize, 1), world.mixed_used);
        world.changed(0, 0, bounds, false);
        world.learnSection(column, 1, 0, .{ .uniform = 0 });
        try std.testing.expectEqual(@as(usize, 0), world.mixed_used);
        try std.testing.expectEqual(&open_section, world.section(.{ .world = 0, .x = 0, .y = 0, .z = 0 }, 0, 1).?);
        world.changed(0, 0, bounds, false);
    }
    world.learnSection(column, 1, 0, .{ .dense = &states });
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    try std.testing.expectEqual(@as(usize, 0), world.mixed_used);
    try std.testing.expectEqual(@as(usize, 1), world.mixed_peak);
    try std.testing.expectEqual(@as(u64, 0), world.mixed_evictions);
}

test "homogeneous summaries survive topology eviction without reclassifying unchanged terrain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 1, .views = 1, .radius = 0, .summary_columns = 4 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const count = section_views.maximum_sections;
    const all = (@as(u32, 1) << count) - 1;
    for (0..4) |x| for (0..count) |y| {
        world.learnSection(.{ .world = 0, .x = @intCast(x), .z = 0, .minimum = -4 }, count, y, .{ .uniform = if (y < count / 2) game_data.registry.block_stone_default_state else 0 });
    };
    const builds = world.builds;
    for (0..8) |_| for (0..4) |x| {
        const column: Column = .{ .world = 0, .x = @intCast(x), .z = 0, .minimum = -4 };
        for (0..count) |y| {
            const at: chunks.Section = .{ .world = 0, .x = @intCast(x), .y = @as(i32, @intCast(y)) - 4, .z = 0 };
            try std.testing.expect(world.known(at, -4, count));
            world.learnSection(column, count, y, .{ .uniform = if (y < count / 2) game_data.registry.block_stone_default_state else 0 });
        }
        const stone = (@as(u32, 1) << (count / 2)) - 1;
        try std.testing.expectEqual(stone, world.stoneMask(column, count));
        try std.testing.expectEqual(all & ~stone, world.skyAir(column, count));
    };
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expect(world.evictions > 4);
    try std.testing.expectEqual(@as(usize, 0), world.mixed_used);

    const at: chunks.Section = .{ .world = 0, .x = 0, .y = -3, .z = 0 };
    world.changed(0, -4, .{ .minimum = .{ 0, -48, 0 }, .maximum = .{ 1, -47, 1 } }, false);
    try std.testing.expect(!world.known(at, -4, count));
    try std.testing.expect(world.known(.{ .world = 0, .x = 0, .y = -4, .z = 0 }, -4, count));
    world.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = -4 }, count, 1, .{ .uniform = 0 });
    try std.testing.expectEqual(&open_section, world.section(at, -4, count).?);
    world.invalidate();
    try std.testing.expect(!world.known(at, -4, count));
    try std.testing.expectEqual(@as(usize, 0), world.summaries.count());
    try std.testing.expect(!bounded.has_induced_failure);
}

test "separated observers reuse homogeneous summaries with the same disclosure as resident topology" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const side = 7;
    const observers = 4;
    const height = 8;
    var worlds = [_]World{
        try World.init(bounded.allocator(), .{ .columns = side * side * observers, .views = 1, .radius = side / 2 }),
        try World.init(bounded.allocator(), .{ .columns = side * side, .views = 1, .radius = side / 2, .summary_columns = side * side * observers }),
    };
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for (&worlds) |*world| for (0..observers) |observer| for (0..side * side) |column| {
        const x = @as(i32, @intCast(observer * 16 + column % side)) - side / 2;
        const z = @as(i32, @intCast(column / side)) - side / 2;
        const floor = 2 + @mod(x * z + x + z, 3);
        for (0..height) |y| world.learnSection(.{ .world = 0, .x = x, .z = z, .minimum = 0 }, height, y, .{ .uniform = if (y < floor) game_data.registry.block_stone_default_state else 0 });
    };
    var sources: [2]Source = undefined;
    for (0..3) |_| for (0..observers) |observer| {
        const x: i32 = @intCast(observer * 16);
        var handles: [2]usize = undefined;
        for (&worlds, &sources, &handles) |*world, *source, *handle| {
            _ = world.source(0, 0, height, .{ x * 16 + 8, 104, 8 }, source) orelse return error.SourceUnavailable;
            handle.* = @as(usize, 0);
            world.begin(handle.*, source, 0, height, side / 2);
            var turns: usize = 0;
            while (!world.ready(handle.*)) : (turns += 1) {
                try std.testing.expect(turns < 256);
                try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
            }
        }
        for (0..side * side) |column| {
            const cx = x + @as(i32, @intCast(column % side)) - side / 2;
            const cz = @as(i32, @intCast(column / side)) - side / 2;
            try std.testing.expectEqual(worlds[0].mask(handles[0], cx, cz), worlds[1].mask(handles[1], cx, cz));
        }
    };
    try std.testing.expectEqual(@as(u64, side * side * observers * height), worlds[1].builds);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "removing a room floor reveals its opaque neighboring section after cached disclosure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .views = 2, .radius = 2 });
    const stone: u16 = game_data.registry.block_stone_default_state;
    for (0..25) |index| for (0..9) |offset| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 1, .z = @as(i32, @intCast(index / 5)) - 1, .minimum = -4 }, 9, offset, .{ .uniform = if (offset < 8) stone else 0 });
    const column: Column = .{ .world = 0, .x = 1, .z = 1, .minimum = -4 };
    const box: geometry.Box = .{ .minimum = .{ 16, 16, 16 }, .maximum = .{ 32, 17, 32 } };
    var room: [4096]u16 = @splat(0);
    @memset(room[0..256], stone);
    var shaft: [4096]u16 = @splat(stone);
    for (0..16) |y| shaft[y * 256 + 4 * 16 + 4] = 0;
    for (6..8) |y| {
        const changed: geometry.Box = .{ .minimum = .{ 16, (@as(i32, @intCast(y)) - 4) * 16, 16 }, .maximum = .{ 32, (@as(i32, @intCast(y)) - 3) * 16, 32 } };
        world.changed(0, -4, changed, false);
        world.learnSection(column, 9, y, .{ .dense = &shaft });
    }
    world.changed(0, -4, box, false);
    world.learnSection(column, 9, 5, .{ .dense = &room });
    for (0..2) |phase| {
        if (phase != 0) {
            world.changed(0, -4, box, false);
            world.learnSection(column, 9, 5, .{ .uniform = 0 });
        }
        for ([_][3]i32{ .{ 20, 18, 20 }, .{ 21, 66, 20 } }) |point| {
            var source_storage: Source = undefined;
            const source = world.source(0, -4, 9, point, &source_storage).?;
            const view_index = @as(usize, 0);
            world.begin(view_index, source, -4, 9, 2);
            for (0..128) |_| {
                const advance = world.advance();
                try std.testing.expectEqual(@as(usize, 0), advance.requests.len);
                if (world.ready(view_index)) break;
            } else return error.VisibilityDidNotComplete;
            try std.testing.expectEqual(phase != 0, world.mask(view_index, 1, 1) & (1 << 4) != 0);
        }
    }
}

pub const World = struct {
    pub const Configuration = struct { columns: usize, views: usize, radius: i32, mixed_sections: ?usize = null, summary_columns: usize = 0, properties: ?[]const u8 = null };
    pub const batch_max = 192;
    pub const source_batch_max = 9;
    pub const Metadata = enum { source, topology };
    pub const Advance = struct { requests: []const chunks.classification.Column, progressed: bool };

    tiles: []Tile,
    mixed: []MixedSection,
    prepared_records: []u8,
    prepared_pool: records.PooledValues,
    prepared_scratch: [visibility.Section.prepared_bytes]u8 = undefined,
    free_mixed: ?usize = null,
    oldest_mixed: ?usize = null,
    newest_mixed: ?usize = null,
    mixed_used: usize = 0,
    mixed_peak: usize = 0,
    mixed_evictions: u64 = 0,
    properties: []const u8,
    lookup: std.AutoArrayHashMapUnmanaged(Column, usize) = .{},
    summaries: std.AutoArrayHashMapUnmanaged(Column, usize) = .{},
    summary_keys: []Column,
    summary_values: []Summary,
    summary_references: []usize,
    summary_previous: []u32,
    summary_next: []u32,
    summary_oldest: u32 = std.math.maxInt(u32),
    summary_newest: u32 = std.math.maxInt(u32),
    oldest: ?usize = null,
    newest: ?usize = null,
    views: []View,
    source_views: std.AutoArrayHashMapUnmanaged(chunks.Section, usize) = .{},
    query: disclosure.Query,
    outdated: bool = false,
    workspace: visibility.Workspace = undefined,
    source_components: section_visibility_source.Components = .{},
    frontier: std.DynamicBitSetUnmanaged,
    missing: [chunks.classification.column_batch_max]chunks.classification.Column = undefined,
    missing_count: usize = 0,
    flags_learned: u64 = 0,
    active: ?usize = null,
    steps: u64 = 0,
    builds: u64 = 0,
    rebuilds: u64 = 0,
    unchanged: u64 = 0,
    evictions: u64 = 0,
    working_evictions: u64 = 0,
    visits: u64 = 0,
    change_lookups: u64 = 0,
    acquisitions: u64 = 0,
    section_resolutions: u64 = 0,
    topology_reuses: u64 = 0,
    topology_lookups: u64 = 0,
    traversal_batches: u64 = 0,
    restored: u64 = 0,
    /// Sections forgotten by `changed` that the caller learns again. A relearn compares
    /// what changed. One that cannot compare, its tile or record having gone in between,
    /// or that is never learned again, invalidates as an eager change would.
    awaiting: [awaiting_max]Awaiting = undefined,
    awaiting_count: usize = 0,
    started: u64 = 0,
    completed: u64 = 0,
    shared: u64 = 0,
    radius: i32,
    grid: chunk_horizon.Index,

    pub fn init(allocator: std.mem.Allocator, config: Configuration) !World {
        if (config.columns == 0 or config.views == 0 or config.radius < 0) return error.InvalidVisibilityCapacity;
        const side: usize = @intCast(config.radius * 2 + 1);
        if (config.columns < side * side) return error.VisibilityCacheTooSmall;
        const sections = try std.math.mul(usize, config.columns, section_views.maximum_sections);
        // Only source neighborhoods retain component records. Frontier metadata is six bytes per section.
        const minimum = @min(sections, 27);
        const requested = config.mixed_sections orelse @min(sections, @max(minimum, try std.math.mul(usize, config.views, 27)));
        if (requested < minimum or requested > sections or requested > no_section) return error.InvalidVisibilityCapacity;
        const tiles = try allocator.alloc(Tile, config.columns);
        const value_maximum = @sizeOf(visibility.Section) + visibility.Section.prepared_bytes;
        const headers = try std.math.mul(usize, requested, @sizeOf(visibility.Section));
        const payloads = try std.math.mul(usize, minimum, visibility.Section.prepared_bytes);
        const budget = try std.math.add(usize, headers, payloads);
        const root_bytes = try records.PooledValues.bytes(1, value_maximum);
        const roots = @max(minimum, std.math.divCeil(usize, budget, root_bytes) catch return error.InvalidVisibilityCapacity);
        const mixed_count = @min(requested, try records.PooledValues.slots(roots));
        const mixed = try allocator.alloc(MixedSection, mixed_count);
        for (mixed, 0..) |*entry, index| entry.* = .{ .next = if (index + 1 < mixed.len) index + 1 else null };
        const properties = config.properties orelse try createProperties(allocator);
        for (tiles, 0..) |*tile, index| tile.* = .{ .index = index };
        const views = try allocator.alloc(View, config.views);
        for (views) |*view| {
            view.* = .{
                .masks = try allocator.alloc(u32, side * side),
                .outgoing = try allocator.alloc(u32, side * side),
                .mask_changes = try .initEmpty(allocator, side * side),
                .topology_slots = try allocator.alloc(u32, if (config.summary_columns == 0) 0 else side * side),
                .topology_cached = try .initEmpty(allocator, if (config.summary_columns == 0) 0 else side * side),
            };
            @memset(view.topology_slots, std.math.maxInt(u32));
        }
        var world: World = .{
            .tiles = tiles,
            .prepared_records = try allocator.alignedAlloc(u8, .@"64", try records.PooledValues.bytes(roots, value_maximum)),
            .prepared_pool = try records.PooledValues.init(allocator, roots, value_maximum),
            .summary_keys = try allocator.alloc(Column, config.summary_columns),
            .summary_values = try allocator.alloc(Summary, config.summary_columns),
            .summary_references = try allocator.alloc(usize, config.summary_columns),
            .summary_previous = try allocator.alloc(u32, config.summary_columns),
            .summary_next = try allocator.alloc(u32, config.summary_columns),
            .mixed = mixed,
            .free_mixed = 0,
            .properties = properties,
            .views = views,
            .frontier = try .initEmpty(allocator, side * side),
            .query = try disclosure.Query.init(allocator, .{ side, section_views.maximum_sections, side }),
            .radius = config.radius,
            .grid = .init(@intCast(side)),
        };
        try world.lookup.ensureTotalCapacity(allocator, @intCast(config.columns));
        try world.source_views.ensureTotalCapacity(allocator, @intCast(config.views));
        @memset(world.summary_references, 0);
        world.resetSummaryQueue();
        try world.summaries.ensureTotalCapacity(allocator, @intCast(config.summary_columns));
        return world;
    }

    pub fn createProperties(allocator: std.mem.Allocator) ![]const u8 {
        const properties = try allocator.alloc(u8, game_data.registry.block_state_to_block.len);
        for (properties, 0..) |*value, state| value.* =
            (if (game_data.physics.rendering(@intCast(state)).occluder) occluder_property else open_property) |
            (if (game_data.physics.get(@intCast(state)).air) air_property else 0) |
            (if (state == game_data.registry.block_stone_default_state) stone_property else 0);
        return properties;
    }

    fn reserveSummary(self: *World, column: Column, count: usize) ?*Summary {
        if (self.summary_keys.len == 0) return null;
        const slot = self.summaries.get(column) orelse create: {
            const index = self.summary_oldest;
            if (index == std.math.maxInt(u32)) return null;
            if (index < self.summaries.count()) {
                const removed = self.summaries.swapRemove(self.summary_keys[index]);
                assert(removed);
            }
            assert(self.summary_references[index] == 0);
            self.summary_keys[index] = column;
            self.summary_values[index] = .{ .open = 0, .closed = 0, .air = 0, .stone = 0, .count = @intCast(count) };
            self.summaries.putAssumeCapacityNoClobber(column, index);
            self.removeSummary(index);
            self.appendSummary(index);
            break :create index;
        };
        return &self.summary_values[slot];
    }

    fn resetSummaryQueue(self: *World) void {
        const none = std.math.maxInt(u32);
        for (self.summary_previous, self.summary_next, 0..) |*previous, *next, index| {
            previous.* = if (index == 0) none else @intCast(index - 1);
            next.* = if (index + 1 == self.summary_keys.len) none else @intCast(index + 1);
        }
        self.summary_oldest = if (self.summary_keys.len == 0) none else 0;
        self.summary_newest = if (self.summary_keys.len == 0) none else @intCast(self.summary_keys.len - 1);
    }

    fn removeSummary(self: *World, slot: usize) void {
        const none = std.math.maxInt(u32);
        assert(self.summary_references[slot] == 0);
        const previous = self.summary_previous[slot];
        const next = self.summary_next[slot];
        if (previous == none) self.summary_oldest = next else self.summary_next[previous] = next;
        if (next == none) self.summary_newest = previous else self.summary_previous[next] = previous;
        self.summary_previous[slot] = none;
        self.summary_next[slot] = none;
    }

    fn appendSummary(self: *World, slot: usize) void {
        const none = std.math.maxInt(u32);
        assert(self.summary_references[slot] == 0 and self.summary_previous[slot] == none and self.summary_next[slot] == none);
        if (self.summary_newest == none) self.summary_oldest = @intCast(slot) else self.summary_next[self.summary_newest] = @intCast(slot);
        self.summary_previous[slot] = self.summary_newest;
        self.summary_newest = @intCast(slot);
    }

    fn remember(self: *World, tile: *const Tile) void {
        const known_bits = tile.known & (tile.open | tile.closed);
        if (tile.classified == 0) return;
        const column = tile.column.?;
        const target = self.reserveSummary(column, tile.count) orelse return;
        const classified = target.classified;
        target.* = .{
            .classified = classified | tile.classified,
            .topology = tile.topology,
            .topology_known = tile.topology_known,
            .open = tile.open & known_bits,
            .closed = tile.closed & known_bits,
            .air = tile.air & known_bits,
            .stone = tile.stone & known_bits,
            .count = @intCast(tile.count),
        };
    }

    fn summary(self: *const World, column: Column, count: usize) ?*const Summary {
        const slot = self.summaries.get(column) orelse return null;
        const value = &self.summary_values[slot];
        assert(value.count == count and value.open & value.closed == 0);
        return value;
    }

    fn touchMixed(self: *World, index: usize) void {
        const entry = &self.mixed[index];
        assert(entry.tile != null);
        if (self.newest_mixed == index) return;
        if (entry.previous) |previous| self.mixed[previous].next = entry.next else self.oldest_mixed = entry.next;
        if (entry.next) |next| self.mixed[next].previous = entry.previous;
        entry.previous = self.newest_mixed;
        entry.next = null;
        if (self.newest_mixed) |newest| self.mixed[newest].next = index;
        self.newest_mixed = index;
        if (self.oldest_mixed == null) self.oldest_mixed = index;
    }

    fn releaseMixed(self: *World, index: usize) void {
        const entry = &self.mixed[index];
        const tile = &self.tiles[entry.tile.?];
        assert(tile.sections[entry.offset] == index and self.mixed_used > 0);
        const bit = @as(u32, 1) << @intCast(entry.offset);
        tile.sections[entry.offset] = no_section;
        tile.known &= ~bit;
        tile.initialized &= ~bit;
        if (entry.previous) |previous| self.mixed[previous].next = entry.next else self.oldest_mixed = entry.next;
        if (entry.next) |next| self.mixed[next].previous = entry.previous else self.newest_mixed = entry.previous;
        entry.tile = null;
        self.prepared_pool.release(index);
        entry.previous = null;
        entry.next = self.free_mixed;
        self.free_mixed = index;
        self.mixed_used -= 1;
    }

    fn acquireMixed(self: *World, tile: *Tile, offset: usize) usize {
        if (tile.sections[offset] != no_section) {
            const index = tile.sections[offset];
            self.touchMixed(index);
            return index;
        }
        if (self.free_mixed == null) {
            self.releaseMixed(self.oldest_mixed.?);
            self.mixed_evictions += 1;
        }
        const index = self.free_mixed.?;
        const entry = &self.mixed[index];
        assert(entry.tile == null and entry.previous == null);
        self.free_mixed = entry.next;
        entry.tile = tile.index;
        entry.offset = offset;
        entry.previous = self.newest_mixed;
        entry.next = null;
        if (self.newest_mixed) |newest| self.mixed[newest].next = index else self.oldest_mixed = index;
        self.newest_mixed = index;
        tile.sections[offset] = @intCast(index);
        self.mixed_used += 1;
        self.mixed_peak = @max(self.mixed_peak, self.mixed_used);
        assert(self.mixed_used <= self.mixed.len);
        return index;
    }

    fn storeMetadata(self: *World, index: usize, input: *const visibility.Section) *const visibility.Section {
        const length = @sizeOf(visibility.Section) + input.prepared_data.len;
        while (!self.prepared_pool.reserve(index, length)) {
            const victim = self.oldest_mixed.?;
            assert(victim != index);
            self.releaseMixed(victim);
            self.mixed_evictions += 1;
        }
        self.prepared_pool.shrink(index, length);
        const bytes = self.prepared_pool.buffer(self.prepared_records, 0, index);
        assert(bytes.len >= length);
        const target: *visibility.Section = @alignCast(std.mem.bytesAsValue(visibility.Section, bytes[0..@sizeOf(visibility.Section)]));
        target.* = input.*;
        target.retainPrepared(bytes[@sizeOf(visibility.Section)..length]);
        self.mixed[index].data = target;
        return self.mixed[index].data;
    }

    fn sectionPointer(self: *const World, tile: *const Tile, offset: usize) *const visibility.Section {
        const bit = @as(u32, 1) << @intCast(offset);
        assert(tile.initialized & bit != 0);
        if (tile.open & bit != 0) return &open_section;
        if (tile.closed & bit != 0) return &closed_section;
        const index = tile.sections[offset];
        assert(index != no_section and self.mixed[index].tile == tile.index and self.mixed[index].offset == offset);
        return self.mixed[index].data;
    }

    fn sectionData(self: *World, tile: *const Tile, offset: usize) *const visibility.Section {
        const result = self.sectionPointer(tile, offset);
        if (tile.sections[offset] != no_section) self.touchMixed(tile.sections[offset]);
        return result;
    }

    fn touch(self: *World, slot: usize) void {
        if (self.newest == slot) return;
        const tile = &self.tiles[slot];
        if (tile.previous) |previous| self.tiles[previous].next = tile.next else self.oldest = tile.next;
        if (tile.next) |next| self.tiles[next].previous = tile.previous;
        tile.previous = self.newest;
        tile.next = null;
        if (self.newest) |newest| self.tiles[newest].next = slot;
        self.newest = slot;
        if (self.oldest == null) self.oldest = slot;
    }

    fn protected(self: *const World, column: Column) bool {
        const index = self.active orelse return false;
        const key = self.views[index].key.?;
        return column.world == key.section.world and column.minimum == key.minimum and chunk_horizon.contains(key.radius, .{ .x = key.section.x, .z = key.section.z }, .{ .x = column.x, .z = column.z });
    }

    fn acquire(self: *World, column: Column, count: usize) ?*Tile {
        self.acquisitions += 1;
        assert(count > 0 and count <= section_views.maximum_sections);
        const slot = self.lookup.get(column) orelse new: {
            if (self.lookup.count() == self.tiles.len) {
                var skipped: usize = 0;
                while (self.protected(self.tiles[self.oldest.?].column.?)) : (skipped += 1) {
                    if (skipped == self.tiles.len - 1) return null;
                    self.touch(self.oldest.?);
                }
            }
            const slot = if (self.lookup.count() < self.tiles.len) self.lookup.count() else self.oldest.?;
            if (self.tiles[slot].column) |previous| {
                assert(!self.protected(previous));
                self.remember(&self.tiles[slot]);
                self.evictions += 1;
                if (self.active) |active| {
                    const key = self.views[active].key.?;
                    self.working_evictions += @intFromBool(previous.world == key.section.world and previous.minimum == key.minimum and
                        @abs(@as(i64, previous.x) - key.section.x) <= key.radius and @abs(@as(i64, previous.z) - key.section.z) <= key.radius);
                }
                const removed = self.lookup.swapRemove(previous);
                assert(removed);
                for (self.tiles[slot].sections) |index| if (index != no_section) self.releaseMixed(index);
            } else {
                self.tiles[slot].previous = self.newest;
                if (self.newest) |newest| self.tiles[newest].next = slot;
                self.newest = slot;
                if (self.oldest == null) self.oldest = slot;
            }
            self.lookup.putAssumeCapacityNoClobber(column, slot);
            self.tiles[slot].column = column;
            self.tiles[slot].count = count;
            self.tiles[slot].known = 0;
            self.tiles[slot].classified = 0;
            self.tiles[slot].initialized = 0;
            self.tiles[slot].topology_known = 0;
            self.tiles[slot].air = 0;
            self.tiles[slot].stone = 0;
            self.tiles[slot].open = 0;
            self.tiles[slot].closed = 0;
            if (self.summary(column, count)) |value| {
                const tile = &self.tiles[slot];
                tile.classified = value.classified;
                tile.topology_known = value.topology_known;
                tile.topology = value.topology;
                tile.known = value.open | value.closed;
                tile.initialized = tile.known;
                tile.open = value.open;
                tile.closed = value.closed;
                tile.air = value.air;
                tile.stone = value.stone;
            }
            break :new slot;
        };
        assert(self.tiles[slot].count == count);
        self.touch(slot);
        return &self.tiles[slot];
    }

    pub fn learnSection(self: *World, column: Column, count: usize, offset: usize, view: section_views.Section.View) void {
        assert(offset < count and view != .unavailable);
        const tile = self.acquire(column, count) orelse return;
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        if (tile.known & bit != 0) return;
        self.learnView(tile, offset, view);
    }

    fn learnView(self: *World, tile: *Tile, offset: usize, view: section_views.Section.View) void {
        const column = tile.column.?;
        assert(offset < tile.count and view != .unavailable);
        assert(tile.known & (@as(u32, 1) << @as(u5, @intCast(offset))) == 0);
        if (view == .encoded) {
            const classified = view.encoded.classify(self.properties, occluder_property) catch unreachable;
            const properties = classified.common;
            self.learnClassified(tile, column, offset, &classified.selected, properties & stone_property != 0, properties & air_property != 0);
            return;
        }
        var solid: [64]u64 = @splat(0);
        var stone = true;
        var air = true;
        if (view == .uniform) {
            const properties = self.properties[view.uniform];
            if (properties & occluder_property != 0) solid = @splat(std.math.maxInt(u64));
            stone = properties & stone_property != 0;
            air = properties & air_property != 0;
        } else for (0..256) |row| {
            const states = view.row(@intCast(row));
            const lanes: @Vector(16, u16) = states;
            var bits: u16 = 0;
            if (@reduce(.And, lanes == @as(@Vector(16, u16), @splat(states[0])))) {
                const state = states[0];
                const properties = self.properties[state];
                if (properties & occluder_property != 0) bits = 0xffff;
                stone = stone and properties & stone_property != 0;
                air = air and properties & air_property != 0;
            } else for (0..16) |index| {
                const state = states[index];
                const properties = self.properties[state];
                if (properties & occluder_property != 0) bits |= @as(u16, 1) << @intCast(index);
                stone = stone and properties & stone_property != 0;
                air = air and properties & air_property != 0;
            }
            solid[row / 4] |= @as(u64, bits) << @intCast(row % 4 * 16);
        }
        self.learnClassified(tile, column, offset, &solid, stone, air);
    }

    pub fn learnClassification(self: *World, column: Column, count: usize, offset: usize, classification: *const chunks.encoding.Classification) bool {
        if (classification.* == .unavailable) return false;
        assert(offset < count);
        const tile = self.acquire(column, count) orelse return false;
        if (tile.known & (@as(u32, 1) << @intCast(offset)) != 0) return true;
        if (classification.* == .summary) self.applySummary(tile, offset, classification.summary.common) else self.applyClassification(tile, offset, &classification.known, null, .source) catch unreachable;
        return true;
    }

    pub fn learnColumnTopology(self: *World, columns: []const chunks.classification.Column, summaries: []const chunks.classification.ColumnSummary) !bool {
        assert(columns.len == summaries.len and columns.len <= chunks.classification.column_batch_max);
        var learned = false;
        for (columns, summaries) |column, *summary_| {
            const key: Column = .{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum };
            defer if (self.active) |owner| {
                const query_key = self.views[owner].key.?;
                if (column.world == query_key.section.world and column.minimum == query_key.minimum and column.count == query_key.count and
                    chunk_horizon.contains(query_key.radius, .{ .x = query_key.section.x, .z = query_key.section.z }, .{ .x = column.x, .z = column.z }))
                {
                    _ = self.cachedTopology(owner, key, column.count);
                }
            };
            const tile: ?*Tile = if (self.lookup.get(key)) |slot| &self.tiles[slot] else if (self.summary_values.len == 0) self.acquire(key, column.count) else null;
            if (tile) |value| {
                var selected = summary_.known & ~value.topology_known;
                while (selected != 0) : (selected &= selected - 1) {
                    const offset = @ctz(selected);
                    const common = summary_.common[offset];
                    const bit = @as(u32, 1) << @intCast(offset);
                    if (common & (open_property | occluder_property) != 0) {
                        self.applySummary(value, offset, common);
                    } else if (summary_.prefixed & bit != 0) {
                        value.topology.set(offset, try visibility.Section.prefixTopology(summary_.prefixes[offset][0..summary_.prefix_bytes]));
                        value.topology_known |= bit;
                        value.classified |= bit;
                        self.restored += 1;
                    }
                }
                self.remember(value);
                learned = learned or value.topology_known != 0;
                continue;
            }
            const target = self.reserveSummary(key, column.count) orelse unreachable;
            var selected = summary_.known & ~target.topology_known;
            while (selected != 0) : (selected &= selected - 1) {
                const offset = @ctz(selected);
                const common = summary_.common[offset];
                const bit = @as(u32, 1) << @intCast(offset);
                if (common & (open_property | occluder_property) != 0) {
                    const open = common & open_property != 0;
                    target.topology.set(offset, if (open) .open else .closed);
                    target.open |= bit * @intFromBool(open);
                    target.closed |= bit * @intFromBool(!open);
                    target.air |= bit * @intFromBool(common & air_property != 0);
                    target.stone |= bit * @intFromBool(common & stone_property != 0);
                    self.flags_learned += 1;
                } else if (summary_.prefixed & bit != 0) {
                    target.topology.set(offset, try visibility.Section.prefixTopology(summary_.prefixes[offset][0..summary_.prefix_bytes]));
                    self.restored += 1;
                } else continue;
                target.topology_known |= bit;
                target.classified |= bit;
                learned = true;
            }
            assert(target.open & target.closed == 0);
        }
        return learned;
    }

    pub fn learnPreparedColumn(self: *World, column: Column, count: usize, bytes: []const u8) !bool {
        assert(count > 0 and count <= section_views.maximum_sections);
        if (bytes.len != column_metadata_bytes) return error.Corrupt;
        const all = @as(u32, std.math.maxInt(u32)) >> @intCast(32 - count);
        const known_bits = std.mem.readInt(u32, bytes[0..4], .little);
        const open = std.mem.readInt(u32, bytes[4..8], .little);
        const closed = std.mem.readInt(u32, bytes[8..12], .little);
        const air = std.mem.readInt(u32, bytes[12..16], .little);
        const stone = std.mem.readInt(u32, bytes[16..20], .little);
        if (known_bits & ~all != 0 or (open | closed) & ~known_bits != 0 or open & closed != 0 or air & ~open != 0 or stone & ~closed != 0) return error.Corrupt;
        var value: Summary = .{ .count = @intCast(count), .classified = known_bits, .topology_known = known_bits, .open = open, .closed = closed, .air = air, .stone = stone };
        for (&value.topology.paths, 0..) |*pair, index| {
            pair.* = std.mem.readInt(u32, bytes[20 + index * 4 ..][0..4], .little);
            if (pair.* & ~known_bits != 0 or pair.* & closed != 0 or open & ~pair.* != 0) return error.Corrupt;
        }
        if (known_bits != all) return false;
        defer if (self.active) |owner| {
            const key = self.views[owner].key.?;
            if (column.world == key.section.world and column.minimum == key.minimum and count == key.count and
                chunk_horizon.contains(key.radius, .{ .x = key.section.x, .z = key.section.z }, .{ .x = column.x, .z = column.z }))
            {
                _ = self.cachedTopology(owner, column, count);
            }
        };
        if (self.lookup.get(column)) |slot| {
            const tile = &self.tiles[slot];
            assert(tile.count == count);
            for (tile.topology.paths, value.topology.paths) |before, after| assert((before ^ after) & tile.topology_known == 0);
            const uniform = open | closed;
            var pending = uniform;
            while (pending != 0) : (pending &= pending - 1) {
                const index = tile.sections[@ctz(pending)];
                if (index != no_section) self.releaseMixed(index);
            }
            self.restored += @popCount(all & ~tile.topology_known);
            tile.topology = value.topology;
            tile.topology_known = all;
            tile.classified = all;
            tile.known |= uniform;
            tile.initialized |= uniform;
            tile.open = open;
            tile.closed = closed;
            tile.air = air;
            tile.stone = stone;
            self.remember(tile);
            return true;
        }
        const target = self.reserveSummary(column, count) orelse return false;
        for (target.topology.paths, value.topology.paths) |before, after| assert((before ^ after) & target.topology_known == 0);
        self.restored += @popCount(all & ~target.topology_known);
        target.* = value;
        return true;
    }

    pub fn knownTopology(self: *const World, column: Column, count: usize) u32 {
        const topology = self.findTopology(column, count) orelse return 0;
        return topology.known;
    }

    pub fn learnClassifications(self: *World, reads: []const chunks.Chunks.ClassificationRequest, minimum: i32, count: usize, kind: Metadata) !bool {
        assert(reads.len <= batch_max and count > 0 and count <= section_views.maximum_sections);
        var previous: ?Column = null;
        var retained: ?*Tile = null;
        var learned = false;
        for (reads) |read| {
            if (read.result.* == .unavailable) continue;
            const position = read.section;
            const column: Column = .{ .world = position.world, .x = position.x, .z = position.z, .minimum = minimum };
            if (previous == null or !std.meta.eql(previous.?, column)) {
                retained = self.acquire(column, count);
                previous = column;
            }
            const tile = retained orelse continue;
            const offset: usize = @intCast(position.y - minimum);
            assert(offset < count);
            learned = true;
            if (tile.known & (@as(u32, 1) << @intCast(offset)) != 0) continue;
            if (read.result.* == .summary) {
                const summary_ = &read.result.summary;
                if (kind == .topology and summary_.prefix_len != 0 and summary_.common & (occluder_property | open_property) == 0) {
                    tile.topology.set(offset, try visibility.Section.prefixTopology(summary_.prefix[0..summary_.prefix_len]));
                    tile.topology_known |= @as(u32, 1) << @intCast(offset);
                    tile.classified |= @as(u32, 1) << @intCast(offset);
                    self.restored += 1;
                } else self.applySummary(tile, offset, summary_.common);
                continue;
            }
            const prepared = if (read.prepared) |data| if (data.length != 0) data.bytes[0..data.length] else null else null;
            try self.applyClassification(tile, offset, &read.result.known, prepared, kind);
        }
        return learned;
    }

    fn applySummary(self: *World, tile: *Tile, offset: usize, common: u8) void {
        const bit = @as(u32, 1) << @intCast(offset);
        if (tile.classified & bit != 0) return;
        if (common & (open_property | occluder_property) != 0) {
            const solid: [64]u64 = @splat(if (common & occluder_property != 0) std.math.maxInt(u64) else 0);
            self.learnClassified(tile, tile.column.?, offset, &solid, common & stone_property != 0, common & air_property != 0);
        } else tile.classified |= bit;
        self.flags_learned += 1;
    }

    fn applyClassification(self: *World, tile: *Tile, offset: usize, classification: *const chunks.encoding.Classification.Known, prepared: ?[]const u8, kind: Metadata) !void {
        const properties = classification.common;
        assert(classification.property == occluder_property);
        assert(offset < tile.count and properties & (occluder_property | open_property) != (occluder_property | open_property));
        assert(properties & air_property == 0 or properties & open_property != 0);
        assert(properties & stone_property == 0 or properties & occluder_property != 0);
        if (kind == .topology) {
            if (prepared) |bytes| {
                const topology: disclosure.Topology = try visibility.Section.preparedTopology(bytes);
                tile.topology.set(offset, topology);
                tile.topology_known |= @as(u32, 1) << @intCast(offset);
                tile.classified |= @as(u32, 1) << @intCast(offset);
                self.restored += 1;
                return;
            }
        }
        try self.learnMetadata(tile, tile.column.?, offset, &classification.selected, properties & stone_property != 0, properties & air_property != 0, prepared);
    }

    fn learnClassified(self: *World, tile: *Tile, column: Column, offset: usize, solid: *const [64]u64, stone: bool, air: bool) void {
        self.learnMetadata(tile, column, offset, solid, stone, air, null) catch unreachable;
    }

    fn learnMetadata(self: *World, tile: *Tile, column: Column, offset: usize, solid: *const [64]u64, stone: bool, air: bool, prepared: ?[]const u8) !void {
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        assert(tile.known & bit == 0);
        const initialized = tile.initialized & bit != 0;
        // Relearned after a change, yet with nothing left to compare against.
        const uncompared = self.arrived(column, offset) and !initialized;
        if (uncompared) {
            self.invalidateAround(column.world, sectionBox(column, offset));
        }
        const previous = if (initialized) self.sectionData(tile, offset) else null;
        const occupancy_changed = if (previous) |data| !std.mem.eql(u64, &data.solid, solid) else false;
        // Views also read whether a section is all air or all stone.
        const flags_changed = initialized and ((tile.air & bit != 0) != air or (tile.stone & bit != 0) != stone);
        const bits: @Vector(64, u64) = solid.*;
        const open = @reduce(.Or, bits) == 0;
        const closed = @reduce(.And, bits) == std.math.maxInt(u64);
        var notified = false;
        const data: *const visibility.Section = if (open) &open_section else if (closed) &closed_section else mixed: {
            if (initialized and !occupancy_changed) {
                self.touchMixed(tile.sections[offset]);
                break :mixed previous.?;
            }
            var decoded: visibility.Section = .{};
            if (prepared) |bytes| {
                try decoded.readPrepared(solid, bytes);
                self.restored += 1;
            } else decoded.build(solid, &self.workspace, &self.prepared_scratch);
            if (occupancy_changed or flags_changed) {
                self.invalidateViews(column.world, .{ .minimum = .{ column.x * 16, (column.minimum + @as(i32, @intCast(offset))) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, (column.minimum + @as(i32, @intCast(offset)) + 1) * 16, column.z * 16 + 16 } });
                self.refreshSources(column.world, .{ .minimum = .{ column.x * 16, (column.minimum + @as(i32, @intCast(offset))) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, (column.minimum + @as(i32, @intCast(offset)) + 1) * 16, column.z * 16 + 16 } });
                notified = true;
            }
            const index = self.acquireMixed(tile, offset);
            break :mixed self.storeMetadata(index, &decoded);
        };
        if ((occupancy_changed or flags_changed) and !notified) {
            self.invalidateViews(column.world, .{ .minimum = .{ column.x * 16, (column.minimum + @as(i32, @intCast(offset))) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, (column.minimum + @as(i32, @intCast(offset)) + 1) * 16, column.z * 16 + 16 } });
            self.refreshSources(column.world, .{ .minimum = .{ column.x * 16, (column.minimum + @as(i32, @intCast(offset))) * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, (column.minimum + @as(i32, @intCast(offset)) + 1) * 16, column.z * 16 + 16 } });
        }
        if (!initialized or occupancy_changed) {
            self.builds += 1;
            self.rebuilds += @intFromBool(initialized);
        } else self.unchanged += 1;
        if ((open or closed) and tile.sections[offset] != no_section) self.releaseMixed(tile.sections[offset]);
        tile.topology.set(offset, data.topology);
        tile.topology_known |= bit;
        tile.known |= bit;
        tile.classified |= bit;
        tile.initialized |= bit;
        tile.air = (tile.air & ~bit) | (bit * @intFromBool(air));
        tile.stone = (tile.stone & ~bit) | (bit * @intFromBool(stone));
        tile.open = (tile.open & ~bit) | (bit * @intFromBool(open));
        tile.closed = (tile.closed & ~bit) | (bit * @intFromBool(closed));
        assert(tile.open & tile.closed == 0);
    }

    pub fn learn(self: *World, column: Column, sections: []const section_views.Section) void {
        var retained: ?*Tile = null;
        for (sections, 0..) |data, offset| {
            if (data.view == .unavailable) continue;
            if (retained == null) retained = self.acquire(column, sections.len) orelse return;
            const tile = retained.?;
            if (tile.known & (@as(u32, 1) << @intCast(offset)) != 0) continue;
            self.learnView(tile, offset, data.view);
        }
    }

    pub fn learnConstants(self: *World, column: Column, sections: []const section_views.Section) void {
        assert(sections.len <= section_views.maximum_sections);
        var constants: u32 = 0;
        for (sections, 0..) |section_, offset| if (section_.view == .uniform) {
            constants |= @as(u32, 1) << @intCast(offset);
        };
        if (constants == 0) return;
        const retained = if (self.lookup.get(column)) |slot| &self.tiles[slot] else if (self.summary_values.len == 0) self.acquire(column, sections.len) else null;
        if (retained) |tile| {
            assert(tile.count == sections.len);
            constants &= ~tile.known;
            while (constants != 0) : (constants &= constants - 1) {
                const offset = @ctz(constants);
                self.learnView(tile, offset, sections[offset].view);
            }
            return;
        }
        const target = self.reserveSummary(column, sections.len) orelse return;
        constants &= ~(target.open | target.closed);
        while (constants != 0) : (constants &= constants - 1) {
            const offset = @ctz(constants);
            const bit = @as(u32, 1) << @intCast(offset);
            const state = sections[offset].view.uniform;
            assert(state < self.properties.len);
            const properties = self.properties[state];
            const closed = properties & occluder_property != 0;
            target.classified |= bit;
            target.topology.set(offset, if (closed) .closed else .open);
            target.topology_known |= bit;
            target.open = (target.open & ~bit) | (bit * @intFromBool(!closed));
            target.closed = (target.closed & ~bit) | (bit * @intFromBool(closed));
            target.air = (target.air & ~bit) | (bit * @intFromBool(properties & air_property != 0));
            target.stone = (target.stone & ~bit) | (bit * @intFromBool(properties & stone_property != 0));
        }
    }

    pub fn learnNeighborhood(self: *World, column: Column, count: usize, sections: []const section_views.Section) void {
        assert(sections.len == 9 * count);
        for (0..9) |neighbor| self.learn(.{ .world = column.world, .x = column.x + @as(i32, @intCast(neighbor % 3)) - 1, .z = column.z + @as(i32, @intCast(neighbor / 3)) - 1, .minimum = column.minimum }, sections[neighbor * count ..][0..count]);
    }

    fn section(self: *World, key: chunks.Section, minimum: i32, count: usize) ?*const visibility.Section {
        const offset = @as(i64, key.y) - minimum;
        if (offset < 0 or offset >= count) return null;
        const column: Column = .{ .world = key.world, .x = key.x, .z = key.z, .minimum = minimum };
        const slot = self.lookup.get(column) orelse {
            const value = self.summary(column, count) orelse return null;
            return value.section(@intCast(offset));
        };
        const tile = &self.tiles[slot];
        const bit = @as(u32, 1) << @as(u5, @intCast(offset));
        if (tile.known & bit == 0) return null;
        self.touch(slot);
        return self.sectionData(tile, @intCast(offset));
    }

    pub fn sourceRequirements(world: u32, minimum: i32, count: usize, point: [3]i32, output: *[27]chunks.Section) []const chunks.Section {
        const y = @divFloor(point[1], 16);
        if (y < minimum or y >= minimum + @as(i32, @intCast(count))) return &.{};
        var length: usize = 0;
        for (0..27) |index| {
            const at: chunks.Section = .{ .world = world, .x = @divFloor(point[0], 16) + @as(i32, @intCast(index % 3)) - 1, .y = y + @as(i32, @intCast(index / 3 % 3)) - 1, .z = @divFloor(point[2], 16) + @as(i32, @intCast(index / 9)) - 1 };
            if (at.y < minimum or at.y >= minimum + @as(i32, @intCast(count))) continue;
            output[length] = at;
            length += 1;
        }
        return output[0..length];
    }

    pub fn known(self: *World, key: chunks.Section, minimum: i32, count: usize) bool {
        return self.section(key, minimum, count) != null;
    }

    pub fn hasTopology(self: *const World, key: chunks.Section, minimum: i32, count: usize) bool {
        assert(key.y >= minimum and key.y < minimum + @as(i32, @intCast(count)));
        const flags = self.findTopology(.{ .world = key.world, .x = key.x, .z = key.z, .minimum = minimum }, count) orelse return false;
        return flags.known & (@as(u32, 1) << @intCast(key.y - minimum)) != 0;
    }

    /// Like `source`, with flood rays limited to start near the head. Finer precision
    /// hides more, but its view is reused only while the head stays in its cell.
    pub fn narrowSource(self: *World, world: u32, minimum: i32, count: usize, point: [3]i32, precision: Source.Precision, output: *Source) ?*const Source {
        const result = self.source(world, minimum, count, point, output) orelse return null;
        output.limitEye(precision);
        return result;
    }

    pub fn source(self: *World, world: u32, minimum: i32, count: usize, point: [3]i32, output: *Source) ?*const Source {
        const key: chunks.Section = .{ .world = world, .x = @divFloor(point[0], 16), .y = @divFloor(point[1], 16), .z = @divFloor(point[2], 16) };
        output.* = .{ .section = key, .component = 0, .point = point, .camera_bounds = .{
            .minimum = .{ key.x * 16 - camera_margin, key.y * 16 - camera_margin, key.z * 16 - camera_margin },
            .maximum = .{ key.x * 16 + 16 + camera_margin, key.y * 16 + 16 + camera_margin, key.z * 16 + 16 + camera_margin },
        } };
        const result = output;
        if (key.y < minimum or key.y >= minimum + @as(i32, @intCast(count))) {
            result.membership = @splat(std.math.maxInt(u64));
            return result;
        }
        const center = self.section(key, minimum, count) orelse {
            return null;
        };
        const source_voxel: u12 = @intCast(@mod(point[1], 16) * 256 + @mod(point[2], 16) * 16 + @mod(point[0], 16));
        const source_component = center.component(source_voxel, &self.workspace) orelse return result;
        if (source_component.faces == 0) {
            result.component = source_component.seed;
            result.cells = 1 << 13;
            if (center.components == 1) {
                for (&result.membership, center.solid) |*bits, solid| bits.* = ~solid;
            } else result.membership = self.workspace.component_bits;
            result.camera_bounds = visibility.Bounds.fromBits(&result.membership);
            const section_origin: [3]i32 = .{ key.x * 16, key.y * 16, key.z * 16 };
            for (0..3) |axis| {
                result.camera_bounds.minimum[axis] += section_origin[axis];
                result.camera_bounds.maximum[axis] += section_origin[axis];
            }
            return result;
        }
        const air: visibility.Section = .{};
        var materials: [27]*const visibility.Section = undefined;
        var all_air = true;
        for (&materials, 0..) |*data, index| {
            const at: chunks.Section = .{ .world = world, .x = key.x + @as(i32, @intCast(index % 3)) - 1, .y = key.y + @as(i32, @intCast(index / 3 % 3)) - 1, .z = key.z + @as(i32, @intCast(index / 9)) - 1 };
            data.* = if (at.y < minimum or at.y >= minimum + @as(i32, @intCast(count))) &air else self.section(at, minimum, count) orelse {
                return null;
            };
            all_air = all_air and data.*.kind == .air;
        }
        if (all_air) {
            result.cells = (1 << 27) - 1;
            result.open_cells = (1 << 27) - 1;
            result.camera_bounds = .{ .minimum = .{ key.x * 16 - 16, key.y * 16 - 16, key.z * 16 - 16 }, .maximum = .{ key.x * 16 + 32, key.y * 16 + 32, key.z * 16 + 32 } };
            result.starts = @splat(63);
            result.membership = @splat(std.math.maxInt(u64));
            return result;
        }
        self.source_components.solve(&materials, source_voxel, camera_margin, &self.workspace);
        result.cells = self.source_components.cells;
        result.starts = self.source_components.faces;
        result.membership = self.source_components.reached[13];
        result.camera_bounds = .{ .minimum = point, .maximum = .{ point[0] + 1, point[1] + 1, point[2] + 1 } };
        var captured = self.source_components.cells;
        while (captured != 0) : (captured &= captured - 1) {
            const cell = @ctz(captured);
            const open = materials[cell].kind == .air;
            const bounds = if (open) visibility.Bounds{ .minimum = @splat(0), .maximum = @splat(16) } else visibility.Bounds.fromBits(&self.source_components.reached[cell]);
            const origin = [_]i32{ (key.x + @as(i32, @intCast(cell % 3)) - 1) * 16, (key.y + @as(i32, @intCast(cell / 3 % 3)) - 1) * 16, (key.z + @as(i32, @intCast(cell / 9)) - 1) * 16 };
            for (0..3) |axis| {
                result.camera_bounds.minimum[axis] = @min(result.camera_bounds.minimum[axis], origin[axis] + bounds.minimum[axis]);
                result.camera_bounds.maximum[axis] = @max(result.camera_bounds.maximum[axis], origin[axis] + bounds.maximum[axis]);
            }
        }
        for (result.membership, 0..) |bits, word| if (bits != 0) {
            result.component = @intCast(word * 64 + @ctz(bits));
            break;
        };
        return result;
    }

    pub fn begin(self: *World, index: usize, origin: *const Source, minimum: i32, count: usize, radius: i32) void {
        assert(self.active == null and index < self.views.len);
        assert(count > 0 and count <= section_views.maximum_sections and radius >= 0 and radius <= self.radius);
        self.forgetSource(index);
        const view = &self.views[index];
        view.key = .{ .section = origin.section, .component = origin.component, .minimum = minimum, .count = count, .radius = radius };
        if (origin != &view.origin) view.origin = origin.*;
        view.source_dirty = false;
        self.active = index;
        self.started += 1;
        self.startFull(index);
    }

    fn startFull(self: *World, index: usize) void {
        assert(self.active == index);
        const view = &self.views[index];
        self.query.capture_frontier = view.capture_frontier;
        const key = view.key.?;
        view.ready = false;
        self.outdated = false;
        const side: usize = @intCast(key.radius * 2 + 1);
        if (view.origin.cells == 1 << 13 and view.origin.starts[13] == 0 and key.section.y >= key.minimum and key.section.y < key.minimum + @as(i32, @intCast(key.count))) {
            @memset(self.query.masks, 0);
            if (view.capture_frontier) @memset(self.query.outgoing, 0);
            self.query.masks[@as(usize, @intCast(key.radius)) * side + @as(usize, @intCast(key.radius))] = @as(u32, 1) << @intCast(key.section.y - key.minimum);
            self.recordMasks(index, self.query.masks[0..view.masks.len]);
            if (view.capture_frontier) self.recordOutgoing(index, self.query.outgoing[0..view.outgoing.len]);
            self.finish();
            return;
        }
        self.frontier.setRangeValue(.{ .start = 0, .end = self.frontier.bit_length }, false);
        self.query.begin(.{ .minimum = .{ key.section.x - key.radius, key.minimum, key.section.z - key.radius }, .size = .{ side, key.count, side } }, .{ key.section.x, key.section.y, key.section.z }, key.radius, view.origin.cells, &view.origin.starts, view.origin.eye);
        var cached = view.topology_cached.iterator(.{});
        while (cached.next()) |at| {
            const slot = view.topology_slots[at];
            assert(slot < self.summary_values.len and self.summary_references[slot] != 0);
            const column = self.summary_keys[slot];
            const value = &self.summary_values[slot];
            const x = @as(i64, column.x) - self.query.grid.minimum[0];
            const z = @as(i64, column.z) - self.query.grid.minimum[2];
            if (column.world != key.section.world or column.minimum != key.minimum or value.count != key.count or x < 0 or z < 0 or x >= side or z >= side) {
                self.releaseTopology(index, at);
                continue;
            }
            // Retained slots keep their keys until this view releases them.
            const target = @as(usize, @intCast(z)) * side + @as(usize, @intCast(x));
            self.query.supplyBorrowed(target, &value.topology, value.topology_known);
            self.topology_reuses += 1;
            self.section_resolutions += @popCount(value.topology_known);
        }
        const previous = view.masks_key orelse return;
        if (previous.section.world != key.section.world or previous.minimum != key.minimum or previous.count != key.count or previous.radius != key.radius or
            (previous.section.x == key.section.x and previous.section.z == key.section.z)) return;
        const all = (@as(u32, 1) << @intCast(key.count)) - 1;
        for (self.query.known[0 .. side * side], 0..) |present, at| {
            if (present == all) continue;
            const x = at % side;
            const z = at / side;
            if ((x != 0 and self.query.known[at - 1] == all) or (x + 1 < side and self.query.known[at + 1] == all) or
                (z != 0 and self.query.known[at - side] == all) or (z + 1 < side and self.query.known[at + side] == all))
            {
                const column: chunk_horizon.Position = .{ .x = self.query.grid.minimum[0] + @as(i32, @intCast(x)), .z = self.query.grid.minimum[2] + @as(i32, @intCast(z)) };
                if (chunk_horizon.contains(key.radius, .{ .x = key.section.x, .z = key.section.z }, column)) self.frontier.set(at);
            }
        }
    }

    pub fn ready(self: *const World, index: usize) bool {
        return self.views[index].ready;
    }

    pub fn sourceInvalidated(self: *const World, index: usize) bool {
        return self.views[index].source_dirty;
    }

    /// Borrowed until this view begins another query or receives a copied snapshot.
    pub fn sourceSnapshot(self: *const World, index: usize) *const Source {
        assert(self.views[index].key != null);
        return &self.views[index].origin;
    }

    pub fn revision(self: *const World, index: usize) u64 {
        return self.views[index].revision;
    }

    pub fn copyView(self: *World, destination: usize, source_index: usize) void {
        assert(self.active == null and destination != source_index and self.views[source_index].ready);
        self.forgetSource(destination);
        const target = &self.views[destination];
        const input = &self.views[source_index];
        assert(target.masks.len == input.masks.len and target.masks.ptr != input.masks.ptr);
        assert(!target.capture_frontier or input.capture_frontier);
        const unchanged = target.masks_key != null and std.meta.eql(target.masks_key.?, input.key.?) and std.mem.eql(u32, target.masks, input.masks) and
            (!target.capture_frontier or std.mem.eql(u32, target.outgoing, input.outgoing));
        target.source_dirty = false;
        target.origin = input.origin;
        target.key = input.key;
        self.recordMasks(destination, input.masks);
        if (target.capture_frontier) self.recordOutgoing(destination, input.outgoing);
        target.ready = true;
        target.revision += @intFromBool(!unchanged);
        self.shared += 1;
        self.rememberSource(destination);
    }

    /// A view from another head is shared only at the same precision, so a slow head never
    /// inherits the wide disclosure of a fast one and a fast head never inherits a short reuse.
    pub fn reuse(self: *World, index: usize, world: u32, point: [3]i32, minimum: i32, count: usize, radius: i32, precision: Source.Precision) bool {
        assert(self.active == null and index < self.views.len);
        const section_: chunks.Section = .{ .world = world, .x = @divFloor(point[0], 16), .y = @divFloor(point[1], 16), .z = @divFloor(point[2], 16) };
        const candidates = [_]usize{ index, self.source_views.get(section_) orelse index };
        for (candidates, 0..) |other, attempt| {
            if (attempt == 1 and other == index) break;
            const view = &self.views[other];
            if (self.views[index].capture_frontier and !view.capture_frontier) continue;
            if (other != index and view.origin.precision != precision) continue;
            const key = view.key orelse continue;
            if (!view.ready or !std.meta.eql(key.section, section_) or key.minimum != minimum or key.count != count or key.radius != radius or !view.origin.supports(world, point)) continue;
            if (other != index) self.copyView(index, other);
            assert(self.views[index].ready and self.views[index].origin.supports(world, point));
            return true;
        }
        return false;
    }

    fn forgetSource(self: *World, index: usize) void {
        const key = self.views[index].key orelse return;
        if (self.source_views.get(key.section) == index) {
            const removed = self.source_views.swapRemove(key.section);
            assert(removed);
        }
    }

    fn rememberSource(self: *World, index: usize) void {
        const view = &self.views[index];
        assert(view.ready and !view.source_dirty);
        self.source_views.putAssumeCapacity(view.key.?.section, index);
        assert(self.source_views.count() <= self.views.len);
    }

    // Manhattan displacement bounds the padded circular horizon along both axes.
    pub fn covers(self: *const World, index: usize, world: u32, center: chunk_horizon.Position, radius: i32) bool {
        assert(index < self.views.len and radius >= 0);
        const key = self.views[index].key orelse return false;
        if (key.section.world != world) return false;
        const x = @abs(@as(i64, center.x) - key.section.x);
        const z = @abs(@as(i64, center.z) - key.section.z);
        return @as(u64, @intCast(radius)) + x + z <= @as(u64, @intCast(key.radius));
    }

    pub fn readyColumn(self: *const World, index: usize, x: i32, z: i32) bool {
        const view = &self.views[index];
        const key = view.key orelse return false;
        return view.ready and chunk_horizon.contains(key.radius, .{ .x = key.section.x, .z = key.section.z }, .{ .x = x, .z = z });
    }

    pub fn mask(self: *const World, index: usize, x: i32, z: i32) u32 {
        assert(self.ready(index));
        if (!self.readyColumn(index, x, z)) return 0;
        const key = self.views[index].key.?;
        const side: usize = @intCast(2 * key.radius + 1);
        return self.views[index].masks[@as(usize, @intCast(z - key.section.z + key.radius)) * side + @as(usize, @intCast(x - key.section.x + key.radius))];
    }

    pub fn stoppingMask(self: *const World, index: usize, x: i32, z: i32) u32 {
        assert(self.views[index].capture_frontier);
        const reached = self.mask(index, x, z);
        if (reached == 0) return 0;
        const view = &self.views[index];
        const key = view.key.?;
        const side: usize = @intCast(2 * key.radius + 1);
        const at = @as(usize, @intCast(z - key.section.z + key.radius)) * side + @as(usize, @intCast(x - key.section.x + key.radius));
        return reached & ~view.outgoing[at];
    }

    const TopologyView = struct {
        topology: *const disclosure.Column,
        known: u32,
        retained: bool = false,

        fn supply(self: TopologyView, query: *disclosure.Query, index: usize) void {
            if (self.retained) query.supplyBorrowed(index, self.topology, self.known) else query.supply(index, self.topology, self.known);
        }
    };

    fn findTopology(self: *const World, column: Column, count: usize) ?TopologyView {
        if (self.lookup.get(column)) |slot| {
            const tile = &self.tiles[slot];
            assert(tile.count == count);
            return .{ .topology = &tile.topology, .known = tile.topology_known };
        }
        const slot = self.summaries.get(column) orelse return null;
        const value = &self.summary_values[slot];
        assert(value.count == count);
        return .{ .topology = &value.topology, .known = value.topology_known };
    }

    fn cachedTopology(self: *World, index: usize, column: Column, count: usize) ?TopologyView {
        const slots = self.views[index].topology_slots;
        const at = self.grid.at(.{ .x = column.x, .z = column.z });
        const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
        if (slots.len != 0 and slots[at] != std.math.maxInt(u32)) {
            const slot = slots[at];
            assert(slot < self.summary_values.len and self.summary_references[slot] != 0);
            const value = &self.summary_values[slot];
            if (std.meta.eql(self.summary_keys[slot], column) and value.count == count and value.topology_known == all) {
                self.topology_reuses += 1;
                return .{ .topology = &value.topology, .known = value.topology_known, .retained = true };
            }
            if (!std.meta.eql(self.summary_keys[slot], column)) self.releaseTopology(index, at);
        }
        self.topology_lookups += 1;
        const result = self.findTopology(column, count) orelse return null;
        if (slots.len != 0) {
            if (self.lookup.get(column)) |slot| self.remember(&self.tiles[slot]);
            if (self.summaries.get(column)) |slot| {
                if (slots[at] != slot) {
                    self.releaseTopology(index, at);
                    if (self.summary_references[slot] == 0) self.removeSummary(slot);
                    self.summary_references[slot] += 1;
                }
                slots[at] = @intCast(slot);
                self.views[index].topology_cached.set(at);
                const value = &self.summary_values[slot];
                return .{ .topology = &value.topology, .known = value.topology_known, .retained = true };
            }
        }
        return result;
    }

    fn releaseTopology(self: *World, index: usize, at: usize) void {
        const view = &self.views[index];
        const slot = view.topology_slots[at];
        if (slot == std.math.maxInt(u32)) return;
        assert(self.summary_references[slot] != 0 and view.topology_cached.isSet(at));
        self.summary_references[slot] -= 1;
        if (self.summary_references[slot] == 0) self.appendSummary(slot);
        view.topology_slots[at] = std.math.maxInt(u32);
        view.topology_cached.unset(at);
    }

    fn summaryForView(self: *const World, index: usize, column: Column, count: usize) ?*const Summary {
        const slots = self.views[index].topology_slots;
        if (slots.len == 0) return null;
        const at = self.grid.at(.{ .x = column.x, .z = column.z });
        const slot = slots[at];
        if (slot == std.math.maxInt(u32) or !std.meta.eql(self.summary_keys[slot], column)) return null;
        const value = &self.summary_values[slot];
        assert(value.count == count);
        return value;
    }

    pub fn advance(self: *World) Advance {
        assert(self.started == self.completed + @intFromBool(self.active != null));
        self.missing_count = 0;
        const index = self.active orelse return .{ .requests = &.{}, .progressed = false };
        const view = &self.views[index];
        const key = view.key.?;
        if (self.outdated) {
            self.finish();
            return .{ .requests = &.{}, .progressed = true };
        }
        var frontier = self.frontier.iterator(.{});
        while (frontier.next()) |at| {
            self.frontier.unset(at);
            const position = self.query.grid.position(at * key.count);
            self.missing[self.missing_count] = .{ .world = key.section.world, .x = position[0], .z = position[2], .minimum = key.minimum, .count = @intCast(key.count) };
            self.missing_count += 1;
            if (self.missing_count == self.missing.len) break;
        }
        if (self.missing_count != 0) return .{ .requests = self.missing[0..self.missing_count], .progressed = true };
        while (!self.query.done) {
            const pending = self.query.advance();
            for (pending) |request| {
                const column_index = request.index;
                if (self.query.known[column_index] == @as(u32, @truncate((@as(u64, 1) << @intCast(key.count)) - 1))) continue;
                const at = self.query.grid.position(column_index * key.count);
                const column: Column = .{ .world = key.section.world, .x = at[0], .z = at[2], .minimum = key.minimum };
                if (self.cachedTopology(index, column, key.count)) |flags| {
                    assert(self.query.known[column_index] & ~flags.known == 0);
                    flags.supply(&self.query, column_index);
                    self.section_resolutions += @popCount(flags.known);
                } else assert(self.query.known[column_index] == 0);
                if (self.query.known[column_index] == @as(u32, @truncate((@as(u64, 1) << @intCast(key.count)) - 1))) continue;
                self.missing[self.missing_count] = .{ .world = key.section.world, .x = at[0], .z = at[2], .minimum = key.minimum, .count = @intCast(key.count) };
                self.missing_count += 1;
            }
            if (self.missing_count != 0) {
                assert(self.frontier.count() == 0);
                for (self.missing[0..self.missing_count]) |column| {
                    const x: usize = @intCast(column.x - self.query.grid.minimum[0]);
                    const z: usize = @intCast(column.z - self.query.grid.minimum[2]);
                    self.frontier.set(z * self.query.grid.size[0] + x);
                }
                var upcoming = self.query.upcoming(self.missing.len);
                while (self.missing_count < self.missing.len) {
                    const request = upcoming.next() orelse break;
                    if (self.frontier.isSet(request.index)) continue;
                    const at = self.query.grid.position(@as(usize, request.index) * key.count);
                    const column: Column = .{ .world = key.section.world, .x = at[0], .z = at[2], .minimum = key.minimum };
                    if (self.cachedTopology(index, column, key.count)) |flags| {
                        flags.supply(&self.query, request.index);
                        self.section_resolutions += @popCount(flags.known);
                        if (self.query.known[request.index] == @as(u32, @truncate((@as(u64, 1) << @intCast(key.count)) - 1))) continue;
                    }
                    self.frontier.set(request.index);
                    self.missing[self.missing_count] = .{ .world = key.section.world, .x = at[0], .z = at[2], .minimum = key.minimum, .count = @intCast(key.count) };
                    self.missing_count += 1;
                }
                self.frontier.setRangeValue(.{ .start = 0, .end = self.frontier.bit_length }, false);
                return .{ .requests = self.missing[0..self.missing_count], .progressed = true };
            }
        }
        self.recordMasks(index, self.query.masks[0..view.masks.len]);
        if (view.capture_frontier and self.query.capture_frontier) self.recordOutgoing(index, self.query.outgoing[0..view.outgoing.len]);
        self.visits += self.query.statistics.visits;
        self.traversal_batches += 1;
        self.steps += 1;
        self.finish();
        return .{ .requests = &.{}, .progressed = true };
    }

    pub const Changes = struct {
        minimum: [2]i32,
        side: usize,
        bits: std.DynamicBitSetUnmanaged.Iterator(.{}),

        pub fn next(self: *Changes) ?chunk_horizon.Position {
            const at = self.bits.next() orelse return null;
            return .{ .x = self.minimum[0] + @as(i32, @intCast(at % self.side)), .z = self.minimum[1] + @as(i32, @intCast(at / self.side)) };
        }
    };

    /// Borrowed until this view receives another snapshot.
    pub fn changes(self: *const World, index: usize) Changes {
        const view = &self.views[index];
        assert(view.ready);
        const key = view.key.?;
        return .{ .minimum = .{ key.section.x - key.radius, key.section.z - key.radius }, .side = @intCast(2 * key.radius + 1), .bits = view.mask_changes.iterator(.{}) };
    }

    fn recordMasks(self: *World, index: usize, masks: []const u32) void {
        const view = &self.views[index];
        const key = view.key.?;
        const previous = view.masks_key;
        assert(view.masks.len == masks.len and view.masks.ptr != masks.ptr);
        const side: usize = @intCast(2 * key.radius + 1);
        const side_signed: i64 = @intCast(side);
        view.mask_changes.setRangeValue(.{ .start = 0, .end = view.mask_changes.bit_length }, false);
        const compatible = if (previous) |old| old.section.world == key.section.world and old.radius == key.radius and old.minimum == key.minimum and old.count == key.count else false;
        if (!compatible) {
            view.mask_changes.setRangeValue(.{ .start = 0, .end = side * side }, true);
        } else {
            const dx = @as(i64, key.section.x) - previous.?.section.x;
            const dz = @as(i64, key.section.z) - previous.?.section.z;
            const first: usize = @intCast(std.math.clamp(-dx, 0, side_signed));
            const last: usize = @intCast(std.math.clamp(side_signed - dx, 0, side_signed));
            for (0..side) |z| {
                const row = z * side;
                const old_z = @as(i64, @intCast(z)) + dz;
                if (old_z < 0 or old_z >= side_signed) {
                    view.mask_changes.setRangeValue(.{ .start = row, .end = row + side }, true);
                    continue;
                }
                view.mask_changes.setRangeValue(.{ .start = row, .end = row + first }, true);
                view.mask_changes.setRangeValue(.{ .start = row + last, .end = row + side }, true);
                var x = first;
                while (last - x >= 8) : (x += 8) {
                    const old_at = @as(usize, @intCast(old_z)) * side + @as(usize, @intCast(@as(i64, @intCast(x)) + dx));
                    const before: @Vector(8, u32) = view.masks[old_at..][0..8].*;
                    const after: @Vector(8, u32) = masks[row + x ..][0..8].*;
                    var different: u8 = @bitCast(before != after);
                    while (different != 0) : (different &= different - 1) view.mask_changes.set(row + x + @as(usize, @ctz(different)));
                }
                while (x < last) : (x += 1) {
                    const old_at = @as(usize, @intCast(old_z)) * side + @as(usize, @intCast(@as(i64, @intCast(x)) + dx));
                    if (view.masks[old_at] != masks[row + x]) view.mask_changes.set(row + x);
                }
            }
        }
        @memcpy(view.masks, masks);
        view.masks_key = key;
    }

    fn recordOutgoing(self: *World, index: usize, outgoing: []const u32) void {
        const view = &self.views[index];
        assert(view.capture_frontier and view.outgoing.len == outgoing.len);
        for (view.outgoing, outgoing, 0..) |before, after, at| {
            if (before != after) view.mask_changes.set(at);
        }
        @memcpy(view.outgoing, outgoing);
    }

    pub fn captureFrontier(self: *World, index: usize, enabled: bool) void {
        const view = &self.views[index];
        if (view.capture_frontier == enabled) return;
        view.capture_frontier = enabled;
        if (enabled) {
            @memset(view.outgoing, 0);
            view.ready = false;
            if (self.active == index) self.outdated = true;
        }
    }

    fn finish(self: *World) void {
        const index = self.active.?;
        self.views[index].ready = !self.outdated;
        self.views[index].revision += 1;
        self.completed += 1;
        self.active = null;
        if (self.views[index].ready) self.rememberSource(index);
        assert(self.started == self.completed);
    }

    pub fn invalidateView(self: *World, index: usize) void {
        self.views[index].ready = false;
        if (self.active == index) self.outdated = true;
    }

    pub fn refreshSource(self: *World, index: usize) void {
        self.views[index].source_dirty = true;
        self.views[index].ready = false;
        if (self.active == index) self.outdated = true;
    }

    /// Forgets what the sections in `box` are like. With `relearned`, the caller learns
    /// them again at once, and only a section that turned out different invalidates the
    /// views that may see it. An edit that changes no occlusion then costs no sweep.
    pub fn changed(self: *World, world: u32, minimum: i32, box: geometry.Box, relearned: bool) void {
        box.validate();
        if (!relearned or !self.awaitRelearn(world, minimum, box)) self.invalidateAround(world, box);
        self.forgetSections(world, minimum, box);
    }

    const Awaiting = struct { column: Column, offset: u5 };
    const awaiting_max = 512;

    /// Notes the initialized sections of `box` as awaiting their relearn. False when there
    /// is no room, and the change must invalidate at once.
    fn awaitRelearn(self: *World, world: u32, minimum: i32, box: geometry.Box) bool {
        const restore = self.awaiting_count;
        var z = @divFloor(box.minimum[2], 16);
        while (z <= @divFloor(box.maximum[2] - 1, 16)) : (z += 1) {
            var x = @divFloor(box.minimum[0], 16);
            while (x <= @divFloor(box.maximum[0] - 1, 16)) : (x += 1) {
                const column: Column = .{ .world = world, .x = x, .z = z, .minimum = minimum };
                const slot = self.lookup.get(column) orelse continue;
                const tile = &self.tiles[slot];
                var y = @max(0, @divFloor(box.minimum[1], 16) - minimum);
                while (y < tile.count and y <= @divFloor(box.maximum[1] - 1, 16) - minimum) : (y += 1) {
                    if (tile.initialized & (@as(u32, 1) << @as(u5, @intCast(y))) == 0) continue;
                    if (self.awaiting_count == self.awaiting.len) {
                        self.awaiting_count = restore;
                        return false;
                    }
                    self.awaiting[self.awaiting_count] = .{ .column = column, .offset = @intCast(y) };
                    self.awaiting_count += 1;
                }
            }
        }
        return true;
    }

    /// Takes a section off the awaiting list. True when it was on it.
    fn arrived(self: *World, column: Column, offset: usize) bool {
        for (self.awaiting[0..self.awaiting_count], 0..) |entry, index| {
            if (entry.offset != offset or !std.meta.eql(entry.column, column)) continue;
            self.awaiting[index] = self.awaiting[self.awaiting_count - 1];
            self.awaiting_count -= 1;
            return true;
        }
        return false;
    }

    /// Call after learning again what `changed` forgot. Sections that were not learned
    /// invalidate the views that may see them.
    pub fn settleChanges(self: *World) void {
        for (self.awaiting[0..self.awaiting_count]) |entry| self.invalidateAround(entry.column.world, sectionBox(entry.column, entry.offset));
        self.awaiting_count = 0;
    }

    fn sectionBox(column: Column, offset: usize) geometry.Box {
        const y = column.minimum + @as(i32, @intCast(offset));
        return .{ .minimum = .{ column.x * 16, y * 16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, y * 16 + 16, column.z * 16 + 16 } };
    }

    /// Views that see `box`, and those whose source lies beside it, are out of date.
    fn invalidateAround(self: *World, world: u32, box: geometry.Box) void {
        if (self.active) |index| {
            const key = self.views[index].key.?;
            if (key.section.world == world and @divFloor(box.minimum[0], 16) <= key.section.x + key.radius and @divFloor(box.maximum[0] - 1, 16) >= key.section.x - key.radius and @divFloor(box.minimum[2], 16) <= key.section.z + key.radius and @divFloor(box.maximum[2] - 1, 16) >= key.section.z - key.radius) self.outdated = true;
        }
        for (self.views, 0..) |*entry, index| {
            const key = entry.key orelse continue;
            if (key.section.world != world) continue;
            if (@divFloor(box.minimum[0], 16) <= key.section.x + 1 and @divFloor(box.maximum[0] - 1, 16) >= key.section.x - 1 and
                @divFloor(box.minimum[1], 16) <= key.section.y + 1 and @divFloor(box.maximum[1] - 1, 16) >= key.section.y - 1 and
                @divFloor(box.minimum[2], 16) <= key.section.z + 1 and @divFloor(box.maximum[2] - 1, 16) >= key.section.z - 1) self.refreshSource(index);
            const side: usize = @intCast(2 * key.radius + 1);
            const left = key.section.x - key.radius;
            const back = key.section.z - key.radius;
            const x0: usize = @intCast(std.math.clamp(@as(i64, @divFloor(box.minimum[0], 16)) - left, 0, side));
            const x1: usize = @intCast(std.math.clamp(@as(i64, @divFloor(box.maximum[0] - 1, 16)) - left + 1, 0, side));
            const z0: usize = @intCast(std.math.clamp(@as(i64, @divFloor(box.minimum[2], 16)) - back, 0, side));
            const z1: usize = @intCast(std.math.clamp(@as(i64, @divFloor(box.maximum[2] - 1, 16)) - back + 1, 0, side));
            if (x0 == x1 or z0 == z1) continue;
            self.invalidateView(index);
        }
    }

    /// Views whose source lies beside `box` prepare it again.
    fn refreshSources(self: *World, world: u32, box: geometry.Box) void {
        for (self.views, 0..) |*entry, index| {
            const key = entry.key orelse continue;
            if (key.section.world != world) continue;
            if (@divFloor(box.minimum[0], 16) <= key.section.x + 1 and @divFloor(box.maximum[0] - 1, 16) >= key.section.x - 1 and
                @divFloor(box.minimum[1], 16) <= key.section.y + 1 and @divFloor(box.maximum[1] - 1, 16) >= key.section.y - 1 and
                @divFloor(box.minimum[2], 16) <= key.section.z + 1 and @divFloor(box.maximum[2] - 1, 16) >= key.section.z - 1) self.refreshSource(index);
        }
    }

    fn forgetSections(self: *World, world: u32, minimum: i32, box: geometry.Box) void {
        var unresolved = false;
        var z = @divFloor(box.minimum[2], 16);
        while (z <= @divFloor(box.maximum[2] - 1, 16)) : (z += 1) {
            var x = @divFloor(box.minimum[0], 16);
            while (x <= @divFloor(box.maximum[0] - 1, 16)) : (x += 1) {
                self.change_lookups += 1;
                const column: Column = .{ .world = world, .x = x, .z = z, .minimum = minimum };
                if (self.summaries.get(column)) |slot| {
                    const value = &self.summary_values[slot];
                    const low: u5 = @intCast(std.math.clamp(@divFloor(box.minimum[1], 16) - minimum, 0, value.count));
                    const high: u5 = @intCast(std.math.clamp(@divFloor(box.maximum[1] - 1, 16) - minimum + 1, 0, value.count));
                    const changed_bits = ((@as(u32, 1) << high) - 1) & ~((@as(u32, 1) << low) - 1);
                    value.classified &= ~changed_bits;
                    value.topology_known &= ~changed_bits;
                    value.open &= ~changed_bits;
                    value.closed &= ~changed_bits;
                    value.air &= ~changed_bits;
                    value.stone &= ~changed_bits;
                }
                const slot = self.lookup.get(column) orelse {
                    unresolved = true;
                    continue;
                };
                const tile = &self.tiles[slot];
                var y = @max(0, @divFloor(box.minimum[1], 16) - minimum);
                while (y < tile.count and y <= @divFloor(box.maximum[1] - 1, 16) - minimum) : (y += 1) {
                    const bit = @as(u32, 1) << @as(u5, @intCast(y));
                    unresolved = unresolved or tile.initialized & bit == 0;
                    tile.known &= ~bit;
                    tile.classified &= ~bit;
                    tile.topology_known &= ~bit;
                }
            }
        }
        if (unresolved) {
            self.invalidateViews(world, box);
            self.refreshSources(world, box);
        }
    }

    fn invalidateViews(self: *World, world: u32, box: geometry.Box) void {
        for (self.views, 0..) |*entry, index| {
            const key = entry.key orelse continue;
            if (key.section.world != world) continue;
            const at = key.section;
            if (@divFloor(box.minimum[0], 16) > at.x + key.radius + 1 or @divFloor(box.maximum[0] - 1, 16) < at.x - key.radius - 1 or
                @divFloor(box.minimum[2], 16) > at.z + key.radius + 1 or @divFloor(box.maximum[2] - 1, 16) < at.z - key.radius - 1) continue;
            self.invalidateView(index);
        }
    }

    pub fn invalidate(self: *World) void {
        for (self.tiles) |*tile| {
            tile.known = 0;
            tile.classified = 0;
            tile.topology_known = 0;
        }
        self.summaries.clearRetainingCapacity();
        @memset(self.summary_references, 0);
        self.resetSummaryQueue();
        for (self.views) |*view| {
            @memset(view.topology_slots, std.math.maxInt(u32));
            view.topology_cached.setRangeValue(.{ .start = 0, .end = view.topology_slots.len }, false);
        }
        self.invalidateResults();
    }

    pub fn invalidateResults(self: *World) void {
        for (self.views, 0..) |_, index| self.invalidateView(index);
    }

    pub fn stoneMask(self: *const World, column: Column, count: usize) u32 {
        const slot = self.lookup.get(column) orelse {
            const value = self.summary(column, count) orelse return 0;
            return value.stone;
        };
        const tile = &self.tiles[slot];
        assert(tile.count == count);
        return tile.stone & tile.known;
    }

    pub fn skyAir(self: *const World, column: Column, count: usize) u32 {
        const air = if (self.lookup.get(column)) |slot| air: {
            const tile = &self.tiles[slot];
            assert(tile.count == count);
            break :air tile.air & tile.known;
        } else if (self.summary(column, count)) |value| value.air else return 0;
        return skyAirMask(air, count);
    }

    pub fn skyAirForView(self: *const World, index: usize, column: Column, count: usize) u32 {
        if (self.summaryForView(index, column, count)) |value| {
            const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
            if (value.classified == all) return skyAirMask(value.air, count);
        }
        return self.skyAir(column, count);
    }

    fn skyAirMask(air: u32, count: usize) u32 {
        assert(count > 0 and count <= 32);
        const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
        const blocked = all & ~air;
        return all & ~@as(u32, @truncate((@as(u64, 1) << @intCast(32 - @clz(blocked))) - 1));
    }
};

test "uniform source snapshots bound traversal and invalidate on interior edits" {
    for ([_]i32{ 1, 8, 32 }) |radius| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const side: usize = @intCast(2 * radius + 1);
        var world = try World.init(bounded.allocator(), .{ .columns = side * side, .views = 1, .radius = radius, .mixed_sections = @min(side * side * section_views.maximum_sections, World.batch_max + 27) });
        const sections: [24]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
        for (0..side * side) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % side)) - radius, .z = @as(i32, @intCast(index / side)) - radius, .minimum = -4 }, &sections);
        var source_storage: Source = undefined;
        const source = world.source(0, -4, 24, .{ 8, 72, 8 }, &source_storage).?;
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        const samples = 8;
        var handle: usize = undefined;
        for (0..samples) |_| {
            world.invalidateResults();
            handle = @as(usize, 0);
            world.begin(handle, source, -4, 24, radius);
            try finishView(&world, handle);
        }
        try std.testing.expect(world.visits <= samples * 8 * side * side * 24);
        for (0..side * side) |index| {
            const at: chunk_horizon.Position = .{ .x = @as(i32, @intCast(index % side)) - radius, .z = @as(i32, @intCast(index / side)) - radius };
            if (!chunk_horizon.contains(radius, .{ .x = 0, .z = 0 }, at)) continue;
            try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(handle, at.x, at.z));
        }
        world.changed(0, -4, .{ .minimum = .{ 1, 65, 1 }, .maximum = .{ 2, 66, 2 } }, false);
        try std.testing.expect(!world.ready(handle));
        var states: [4096]u16 = @splat(0);
        states[273] = game_data.registry.block_stone_default_state;
        world.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = -4 }, 24, 8, .{ .dense = &states });
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        try finishView(&world, handle);
        try std.testing.expect(world.views[handle].masks[@as(usize, @intCast(radius)) * side + @as(usize, @intCast(radius))] != 0);
        try std.testing.expect(!bounded.has_induced_failure);
    }
}

test "homogeneous topology is shared and material-only edits retain connectivity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = 1 });
    const a: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const b: Column = .{ .world = 0, .x = 1, .z = 0, .minimum = 0 };
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const dirt: u16 = @intCast(game_data.registry.block_dirt_default_state);
    world.learnSection(a, 1, 0, .{ .uniform = stone });
    world.learnSection(b, 1, 0, .{ .uniform = stone });
    const at: chunks.Section = .{ .world = 0, .x = 0, .z = 0, .y = 0 };
    try std.testing.expectEqual(world.section(at, 0, 1).?, world.section(.{ .world = 0, .x = 1, .z = 0, .y = 0 }, 0, 1).?);
    const builds = world.builds;
    const bounds: geometry.Box = .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 16, 16, 16 } };
    world.changed(0, 0, bounds, false);
    try std.testing.expect(world.section(at, 0, 1) == null);
    world.learnSection(a, 1, 0, .{ .uniform = dirt });
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expectEqual(@as(u64, 1), world.unchanged);
    try std.testing.expectEqual(@as(u32, 0), world.stoneMask(a, 1));
    world.changed(0, 0, bounds, false);
    world.learnSection(a, 1, 0, .{ .uniform = 0 });
    try std.testing.expectEqual(builds + 1, world.builds);
    try std.testing.expectEqual(@as(u64, 1), world.rebuilds);
    try std.testing.expectEqual(&open_section, world.section(at, 0, 1).?);
    try std.testing.expectEqual(@as(u32, 1), world.skyAir(a, 1));
}

test "bounded outside-world seeding retains sparse missing metadata at a yield" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const radius = 16;
    const side_length = 2 * radius + 1;
    const columns = side_length * side_length;
    var world = try World.init(arena.allocator(), .{ .columns = columns, .views = 1, .radius = radius });
    const absent = radius * side_length;
    for (0..columns) |index| {
        if (index == absent) continue;
        world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % side_length)) - radius, .z = @as(i32, @intCast(index / side_length)) - radius, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 40, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 1, radius);
    var requested: usize = 0;
    var attempts: usize = 0;
    while (!world.ready(view_index)) : (attempts += 1) {
        try std.testing.expect(attempts < 8 * columns);
        const advanced = world.advance();
        try std.testing.expect(advanced.progressed or advanced.requests.len != 0);
        for (advanced.requests) |position| {
            try std.testing.expectEqual(chunks.classification.Column{ .world = 0, .x = absent % side_length - radius, .z = absent / side_length - radius, .minimum = 0, .count = 1 }, position);
            requested += 1;
            world.learnSection(.{ .world = 0, .x = position.x, .z = position.z, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
        }
    }
    try std.testing.expectEqual(@as(usize, 1), requested);
    for (0..columns) |index| {
        const at: chunk_horizon.Position = .{ .x = @as(i32, @intCast(index % side_length)) - radius, .z = @as(i32, @intCast(index / side_length)) - radius };
        if (chunk_horizon.contains(radius, .{ .x = 0, .z = 0 }, at)) try std.testing.expectEqual(@as(u32, 1), world.mask(view_index, at.x, at.z));
    }
}

test "face connectivity conservatively retains disconnected openings on a shared face" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .views = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (0..49) |column| {
        const cx = @as(i32, @intCast(column % 7)) - 3;
        const cz = @as(i32, @intCast(column / 7)) - 3;
        for (0..4) |sy| {
            for (&states, 0..) |*state, local| {
                const x = cx * 16 + @as(i32, @intCast(local % 16));
                const y = @as(i32, @intCast(sy * 16 + local / 256));
                const z = cz * 16 + @as(i32, @intCast(local / 16 % 16));
                const chamber = x >= 0 and x < 15 and y >= 20 and y < 31 and z >= 4 and z < 13;
                const opening = x >= 0 and x < 32 and y >= 20 and y < 23 and z >= 4 and z < 7;
                const hidden = x >= 16 and x < 64 and y >= 27 and y < 29 and z >= 10 and z < 12;
                state.* = if (chamber or opening or hidden) 0 else stone;
            }
            world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = 0 }, 4, sy, .{ .dense = &states });
        }
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 21, 5 }, &source_storage).?;
    try std.testing.expect(source.cells & (1 << 14) != 0);
    try std.testing.expect(source.starts[14] != 0);
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 4, 3);
    try finishView(&world, view_index);
    try std.testing.expect(world.mask(view_index, 2, 0) & 2 != 0);
    try std.testing.expect(world.mask(view_index, 3, 0) & 2 != 0);
}

test "section queries remain pending on missing metadata and sealed sources cannot disclose distant loaded sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 3, .radius = 2 });
    var unavailable: Source = undefined;
    try std.testing.expect(world.source(0, 0, 4, .{ 8, 24, 8 }, &unavailable) == null);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const states = try arena.allocator().alloc(u16, 48 * 48 * 48);
    @memset(states, stone);
    for (4..12) |y| for (4..12) |z| for (4..12) |x| {
        states[y * 48 * 48 + z * 48 + x] = 0;
    };
    var sections: [4]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = stone } });
    for (0..25) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 2, .z = @as(i32, @intCast(index / 5)) - 2, .minimum = 0 }, &sections);
    world.changed(0, 0, .{ .minimum = .{ 0, 16, 0 }, .maximum = .{ 16, 32, 16 } }, false);
    sections[1].view = .{ .rows = states };
    world.learn(.{ .world = 0, .x = 0, .z = 0, .minimum = 0 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    try std.testing.expectEqual(visibility.Bounds{ .minimum = .{ 4, 20, 4 }, .maximum = .{ 12, 28, 12 } }, source.camera_bounds);
    const handle = @as(usize, 0);
    world.begin(handle, source, 0, 4, 2);
    try std.testing.expect(world.ready(handle));
    try finishView(&world, handle);
    try std.testing.expectEqual(@as(u32, 2), world.mask(handle, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), world.visits);
    const air: [4]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    world.changed(0, 0, .{ .minimum = .{ -32, 0, 32 }, .maximum = .{ -16, 64, 48 } }, false);
    world.learn(.{ .world = 0, .x = -2, .z = 2, .minimum = 0 }, &air);
    world.begin(handle, source, 0, 4, 2);
    try finishView(&world, handle);
    try std.testing.expectEqual(@as(u32, 0), world.mask(handle, -2, 2));
}

test "pending section metadata is batched and warmup cannot change a completed visibility set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 2, .radius = 2 });
    const sections: [4]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| world.learn(.{ .world = 7, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    var source_storage: Source = undefined;
    const source = world.source(7, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    try std.testing.expect(source.cells & 1 != 0);
    try std.testing.expect(source.supports(7, .{ 14, 20, 1 }));
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 4, 2);
    var missing: []const chunks.classification.Column = &.{};
    for (0..128) |_| {
        missing = world.advance().requests;
        if (missing.len != 0) break;
    }
    try std.testing.expect(missing.len > 1);
    try std.testing.expect(!world.ready(view_index));
    var attempts: usize = 0;
    while (!world.ready(view_index)) : (attempts += 1) {
        try std.testing.expect(attempts < 8 * 25);
        for (world.missing[0..world.missing_count]) |column| for (0..column.count) |offset| world.learnSection(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum }, column.count, offset, .{ .uniform = 0 });
        _ = world.advance();
    }
    for (0..25) |index| try std.testing.expectEqual(@as(u32, 15), world.mask(view_index, @as(i32, @intCast(index % 5)) - 2, @as(i32, @intCast(index / 5)) - 2));
    const builds = world.builds;
    const first_revision = world.revision(view_index);
    world.invalidateResults();
    world.begin(view_index, source, 0, 4, 2);
    try finishView(&world, view_index);
    try std.testing.expectEqual(builds, world.builds);
    try std.testing.expect(world.revision(view_index) > first_revision);
    const revision = world.revision(view_index);
    for (0..25) |index| world.learn(.{ .world = 7, .x = 100 + @as(i32, @intCast(index)), .z = 100, .minimum = 0 }, &sections);
    try std.testing.expect(world.ready(view_index));
    try std.testing.expectEqual(revision, world.revision(view_index));
    try std.testing.expectEqual(@as(u32, 15), world.mask(view_index, 2, 2));
}

test "row classification preserves scalar opacity air and stone flags for every input layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 1, .views = 1, .radius = 0 });
    var states: [4096]u16 = undefined;
    var bytes: [8193]u8 = undefined;
    const side = 3 * 16;
    const strided = try arena.allocator().alloc(u16, side * side * 16);
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const air: u16 = @intCast(game_data.registry.block_cave_air_default_state);
    const glass: u16 = @intCast(game_data.registry.block_glass_default_state);
    const water: u16 = @intCast(game_data.registry.block_water_default_state);
    for (0..5) |pattern| {
        var expected_solid: [64]u64 = @splat(0);
        var expected_stone = true;
        var expected_air = true;
        for (&states, 0..) |*state, index| {
            state.* = switch (pattern) {
                0 => stone,
                1 => air,
                2 => if (index < 2048) stone else air,
                3 => ([_]u16{ stone, air, glass, water })[index % 4],
                4 => glass,
                else => unreachable,
            };
            if (game_data.physics.rendering(state.*).occluder) expected_solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
            expected_stone = expected_stone and state.* == stone;
            expected_air = expected_air and game_data.physics.get(state.*).air;
            std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], state.*, .little);
            strided[index / 256 * side * side + index / 16 % 16 * side + index % 16] = state.*;
        }
        const views = [_]section_views.Section.View{ .{ .dense = &states }, .{ .rows = strided }, .{ .chunk = .{ .dense = bytes[1..] } } };
        const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
        for (views) |view| {
            world.changed(0, 0, .{ .minimum = @splat(0), .maximum = @splat(16) }, false);
            world.learnSection(column, 1, 0, view);
            try std.testing.expectEqualSlices(u64, &expected_solid, &world.section(.{ .world = 0, .x = 0, .y = 0, .z = 0 }, 0, 1).?.solid);
            try std.testing.expectEqual(@as(u32, @intFromBool(expected_stone)), world.stoneMask(column, 1));
            try std.testing.expectEqual(@as(u32, @intFromBool(expected_air)), world.skyAir(column, 1));
        }
    }
}

test "palette properties preserve opacity without treating transparent blocks as air" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var projected = try World.init(arena.allocator(), .{ .columns = 1, .views = 1, .radius = 0 });
    var decoded = try World.init(arena.allocator(), .{ .columns = 1, .views = 1, .radius = 0 });
    const column: Column = .{ .world = 0, .x = 0, .z = 0, .minimum = 0 };
    const pairs = [_][2]u16{
        .{ game_data.registry.block_air_default_state, game_data.registry.block_cave_air_default_state },
        .{ game_data.registry.block_water_default_state, game_data.registry.block_glass_default_state },
        .{ game_data.registry.block_stone_default_state, game_data.registry.block_bedrock_default_state },
        .{ game_data.registry.block_stone_default_state, game_data.registry.block_stone_default_state },
        .{ game_data.registry.block_void_air_default_state, game_data.registry.block_void_air_default_state },
    };
    var raw: [chunks.encoding.dense_block_bytes]u8 = undefined;
    var encoded: [raw.len]u8 = undefined;
    raw[0] = 1;
    for (pairs, 0..) |pair, offset| {
        for (0..4096) |index| std.mem.writeInt(u16, raw[1 + index * 2 ..][0..2], pair[index % pair.len], .little);
        const bytes = try chunks.encoding.encode(&raw, &encoded);
        const classification: chunks.encoding.Classification = .{ .known = try chunks.encoding.classify(bytes, projected.properties, occluder_property) };
        try std.testing.expect(projected.learnClassification(column, pairs.len, offset, &classification));
        decoded.learnSection(column, pairs.len, offset, .{ .chunk = .{ .dense = raw[1..] } });
        const first = decoded.sectionData(&decoded.tiles[0], offset);
        const second = projected.sectionData(&projected.tiles[0], offset);
        try std.testing.expectEqualSlices(u64, &first.solid, &second.solid);
        try std.testing.expectEqual(first.kind, second.kind);
    }
    try std.testing.expectEqual(decoded.tiles[0].air, projected.tiles[0].air);
    try std.testing.expectEqual(decoded.tiles[0].stone, projected.tiles[0].stone);
    try std.testing.expectEqual(@as(u32, 17), projected.tiles[0].air);
    try std.testing.expectEqual(@as(u32, 8), projected.tiles[0].stone);
}

test "active column bindings follow metadata eviction and refilling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    const air: [24]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..24) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 2, .z = @as(i32, @intCast(index / 5)) - 2, .minimum = 0 }, &air);
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 24, .{ 8, 24, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 24, 2);
    for (0..128) |_| {
        const advanced = world.advance();
        if (advanced.requests.len != 0) break;
        try std.testing.expect(advanced.progressed and !world.ready(view_index));
    }
    try std.testing.expect(world.missing_count != 0);
    try std.testing.expect(!world.ready(view_index));
    const stone: [24]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = @intCast(game_data.registry.block_stone_default_state) } });
    for (0..25) |index| world.learn(.{ .world = 0, .x = 100 + @as(i32, @intCast(index)), .z = 100, .minimum = 0 }, &stone);
    for (0..128) |_| {
        const advanced = world.advance();
        if (advanced.requests.len != 0) break;
        try std.testing.expect(advanced.progressed and !world.ready(view_index));
    }
    try std.testing.expect(world.missing_count != 0);
    try std.testing.expect(!world.ready(view_index));
    var attempts: usize = 0;
    while (!world.ready(view_index)) : (attempts += 1) {
        try std.testing.expect(attempts < 8 * 25);
        for (world.missing[0..world.missing_count]) |column| for (0..column.count) |offset| world.learnSection(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum }, column.count, offset, .{ .uniform = 0 });
        _ = world.advance();
    }
    for (0..25) |index| try std.testing.expectEqual(@as(u32, (1 << 24) - 1), world.mask(view_index, @as(i32, @intCast(index % 5)) - 2, @as(i32, @intCast(index / 5)) - 2));
}

test "packed source rows preserve a winding path across section and word boundaries" {
    const Reference = struct {
        blocked: [source_volume]bool = @splat(false),
        visited: [source_volume]bool = @splat(false),
        queue: [source_volume]u16 = undefined,
        count: usize = 0,

        fn visit(self: *@This(), index: usize) void {
            if (self.blocked[index] or self.visited[index]) return;
            self.visited[index] = true;
            self.queue[self.count] = @intCast(index);
            self.count += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = 1 });
    const states = try arena.allocator().alloc([4096]u16, 27);
    for (states) |*section_states| @memset(section_states, @intCast(game_data.registry.block_stone_default_state));
    const point: [3]i32 = .{ -8, 24, -8 };
    const origin: [3]i32 = .{ -21, 11, -21 };
    var reference: Reference = .{};
    @memset(&reference.blocked, true);
    const path = [_][3]i32{ .{ 13, 13, 13 }, .{ 0, 13, 13 }, .{ 0, 25, 13 }, .{ 0, 25, 25 }, .{ 25, 25, 25 }, .{ 25, 0, 25 }, .{ 25, 0, 0 }, .{ 0, 0, 0 } };
    for (path[1..], 0..) |target, segment| {
        var at = path[segment];
        while (true) {
            const index: usize = @intCast((at[1] * source_side + at[2]) * source_side + at[0]);
            reference.blocked[index] = false;
            const position = [3]i32{ at[0] + origin[0], at[1] + origin[1], at[2] + origin[2] };
            const section: usize = @intCast((@divFloor(position[2], 16) + 2) * 9 + @divFloor(position[1], 16) * 3 + @divFloor(position[0], 16) + 2);
            const voxel: usize = @intCast(@mod(position[1], 16) * 256 + @mod(position[2], 16) * 16 + @mod(position[0], 16));
            states[section][voxel] = 0;
            if (std.meta.eql(at, target)) break;
            for (0..3) |axis| if (at[axis] != target[axis]) {
                at[axis] += if (at[axis] < target[axis]) @as(i32, 1) else -1;
            };
        }
    }
    for (states, 0..) |*section_states, index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 2, .z = @as(i32, @intCast(index / 9)) - 2, .minimum = 0 }, 3, index / 3 % 3, .{ .dense = section_states });
    reference.visit((13 * source_side + 13) * source_side + 13);
    var head: usize = 0;
    while (head < reference.count) : (head += 1) {
        const index = reference.queue[head];
        const local: [3]usize = .{ index % source_side, index / (source_side * source_side), index / source_side % source_side };
        for (0..3) |axis| {
            const stride = [_]usize{ 1, source_side * source_side, source_side };
            if (local[axis] != 0) reference.visit(index - stride[axis]);
            if (local[axis] + 1 < source_side) reference.visit(index + stride[axis]);
        }
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 3, point, &source_storage).?;
    var expected_bounds: visibility.Bounds = .{ .minimum = point, .maximum = point };
    var expected_cells: u32 = 0;
    var expected_membership: [64]u64 = @splat(0);
    for (reference.visited, 0..) |visited, index| {
        if (!visited) continue;
        const position: [3]i32 = .{ origin[0] + @as(i32, @intCast(index % source_side)), origin[1] + @as(i32, @intCast(index / (source_side * source_side))), origin[2] + @as(i32, @intCast(index / source_side % source_side)) };
        for (0..3) |axis| {
            expected_bounds.minimum[axis] = @min(expected_bounds.minimum[axis], position[axis]);
            expected_bounds.maximum[axis] = @max(expected_bounds.maximum[axis], position[axis] + 1);
        }
        const cell: usize = @intCast((@divFloor(position[2], 16) + 2) * 9 + @divFloor(position[1], 16) * 3 + @divFloor(position[0], 16) + 2);
        expected_cells |= @as(u32, 1) << @intCast(cell);
        if (cell != 13) continue;
        const voxel: usize = @intCast(@mod(position[1], 16) * 256 + @mod(position[2], 16) * 16 + @mod(position[0], 16));
        expected_membership[voxel / 64] |= @as(u64, 1) << @intCast(voxel % 64);
    }
    try std.testing.expectEqualDeep(expected_bounds, source.camera_bounds);
    try std.testing.expectEqual(expected_cells, source.cells);
    try std.testing.expectEqualSlices(u64, &expected_membership, &source.membership);
}

test "observers outside the world see its boundary without exposing buried sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 3, .radius = 1 });
    const sections: [2]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = @intCast(game_data.registry.block_stone_default_state) } });
    for (0..9) |index| world.learn(.{ .world = 7, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    for ([_]i32{ -32, 64 }) |y| {
        var source_storage: Source = undefined;
        const source = world.source(7, 0, 2, .{ 8, y, 8 }, &source_storage).?;
        const view_index = @as(usize, 0);
        world.begin(view_index, source, 0, 2, 1);
        try finishView(&world, view_index);
        for (0..9) |index| try std.testing.expectEqual(@as(u32, if (y < 0) 1 else 2), world.mask(view_index, @as(i32, @intCast(index % 3)) - 1, @as(i32, @intCast(index / 3)) - 1));
    }
}

test "a diagonal tunnel can cross a source-aligned column beyond the camera margin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -2, -6, -2 }, .size = .{ 5, 8, 5 } };
    const states = try arena.allocator().alloc([4096]u16, grid.count());
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    for (states) |*section_states| @memset(section_states, stone);
    var y: i32 = -80;
    while (y <= 8) : (y += 1) {
        const x = 8 + @divFloor((8 - y) * 16, 88);
        for ([_]i32{ x, x + 1 }) |column| {
            const index = grid.index(.{ @divFloor(column, 16), @divFloor(y, 16), 0 }).?;
            states[index][@intCast(@mod(y, 16) * 256 + 8 * 16 + @mod(column, 16))] = 0;
        }
    }
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    for (states, 0..) |*section_states, index| {
        const at = grid.position(index);
        world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = -6 }, 8, @intCast(at[1] + 6), .{ .dense = section_states });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, -6, 8, .{ 8, 8, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, -6, 8, 2);
    try finishView(&world, view_index);
    try std.testing.expect(world.mask(view_index, 1, 0) & 2 != 0);
}

test "interior and boundary edits preserve conservative disclosure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 2, .radius = 1 });
    const sections: [4]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    var source_states: [4096]u16 = @splat(0);
    source_states[0] = game_data.registry.block_stone_default_state;
    world.changed(0, 0, .{ .minimum = .{ 0, 16, 0 }, .maximum = .{ 1, 17, 1 } }, false);
    world.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &source_states });
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 4, 1);
    try finishView(&world, view_index);
    const expected = try arena.allocator().dupe(u32, world.views[view_index].masks);
    var states: [4096]u16 = @splat(0);
    const column: Column = .{ .world = 0, .x = 1, .z = 1, .minimum = 0 };
    for ([_]u16{ @intCast(game_data.registry.block_stone_default_state), 0 }) |state| {
        world.changed(0, 0, .{ .minimum = .{ 30, 56, 30 }, .maximum = .{ 31, 57, 31 } }, false);
        states[8 * 256 + 14 * 16 + 14] = state;
        world.learnSection(column, 4, 3, .{ .dense = &states });
        try finishView(&world, view_index);
        try std.testing.expectEqualSlices(u32, expected, world.views[view_index].masks);
    }
    world.changed(0, 0, .{ .minimum = .{ 31, 56, 30 }, .maximum = .{ 32, 57, 31 } }, false);
    states[8 * 256 + 14 * 16 + 15] = @intCast(game_data.registry.block_stone_default_state);
    world.learnSection(column, 4, 3, .{ .dense = &states });
    try finishView(&world, view_index);
    const current = world.source(0, 0, 4, .{ 8, 24, 8 }, &source_storage).?;
    world.begin(1, current, 0, 4, 1);
    try finishView(&world, 1);
    try std.testing.expectEqualSlices(u32, world.views[1].masks, world.views[view_index].masks);
}

test "face connectivity retains in-section bends and interior edits invalidate snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    const Shape = struct {
        fn open(x: i32, y: i32, z: i32) bool {
            const room = ((x >= 0 and x < 16) or (x >= 32 and x < 48)) and y >= 4 and y < 12 and z >= 0 and z < 16;
            const local = x - 16;
            const first = local >= 0 and local < 13 and z >= 3 and z < 5;
            const turn = local >= 11 and local < 13 and z >= 3 and z < 11;
            const returning = local >= 7 and local < 13 and z >= 9 and z < 11;
            const bend = local >= 7 and local < 9 and z >= 9 and z < 15;
            const exit = local >= 7 and local < 16 and z >= 13 and z < 15;
            const passage = y >= 8 and y < 10 and (first or turn or returning or bend or exit);
            const straight = local >= 0 and local < 16 and y >= 12 and y < 14 and z >= 3 and z < 5;
            const bridge = local >= 7 and local < 9 and y >= 12 and y < 14 and z >= 3 and z < 11;
            const connector = local >= 7 and local < 9 and y >= 10 and y < 14 and z >= 9 and z < 11;
            return room or passage or straight or bridge or connector;
        }
    };
    for (0..25) |column| for (0..3) |section| {
        const cx = @as(i32, @intCast(column % 5)) - 2;
        const cz = @as(i32, @intCast(column / 5)) - 2;
        const cy = @as(i32, @intCast(section)) - 1;
        for (&states, 0..) |*state, local| {
            state.* = if (Shape.open(cx * 16 + @as(i32, @intCast(local % 16)), cy * 16 + @as(i32, @intCast(local / 256)), cz * 16 + @as(i32, @intCast(local / 16 % 16)))) 0 else stone;
        }
        world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = -1 }, 3, section, .{ .dense = &states });
    };
    var source_storage: Source = undefined;
    const source = world.source(0, -1, 3, .{ 8, 8, 4 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, -1, 3, 2);
    try finishView(&world, view_index);
    try std.testing.expect(world.mask(view_index, 2, 0) & 2 != 0);
    for ([_]bool{ true, false }) |shortcut| {
        const before = world.section(.{ .world = 0, .x = 1, .y = 0, .z = 0 }, -1, 3).?;
        const connections = before.connections;
        const blocked_pairs = before.blocked_pairs;
        const solid = before.solid;
        const revision = world.revision(view_index);
        for (&states, 0..) |*state, local| {
            const x = @as(i32, @intCast(local % 16));
            const y = @as(i32, @intCast(local / 256));
            const z = @as(i32, @intCast(local / 16 % 16));
            const opened = shortcut and x >= 5 and x < 15 and y >= 8 and y < 10 and z >= 3 and z < 15;
            state.* = if (opened or Shape.open(16 + x, y, z)) 0 else stone;
        }
        world.changed(0, -1, .{ .minimum = .{ 21, 8, 3 }, .maximum = .{ 31, 10, 15 } }, false);
        world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = -1 }, 3, 1, .{ .dense = &states });
        const after = world.section(.{ .world = 0, .x = 1, .y = 0, .z = 0 }, -1, 3).?;
        try std.testing.expectEqual(@as(u16, 1), after.components);
        try std.testing.expectEqual(connections, after.connections);
        try std.testing.expectEqual(blocked_pairs, after.blocked_pairs);
        try std.testing.expect(!after.boundaryChanged(&solid));
        try std.testing.expect(!world.ready(view_index));
        try finishView(&world, view_index);
        try std.testing.expectEqual(revision + 1, world.revision(view_index));
        try std.testing.expect(world.mask(view_index, 2, 0) & 2 != 0);
    }
}

test "interior sightline changes invalidate disclosure while boundary openings stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .views = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (0..49) |column| for (0..4) |section| {
        const cx = @as(i32, @intCast(column % 7)) - 4;
        const cz = @as(i32, @intCast(column / 7)) - 3;
        for (&states, 0..) |*state, index| {
            const x = cx * 16 + @as(i32, @intCast(index % 16));
            const y = @as(i32, @intCast(section * 16 + index / 256));
            const z = cz * 16 + @as(i32, @intCast(index / 16 % 16));
            const room = ((x >= -16 and x < 0) or (x >= 32 and x < 48)) and y >= 16 and y < 32 and z >= 0 and z < 16;
            const passage = x >= 0 and x < 32 and y >= 24 and y < 26;
            const tunnel = if (x < 19 or x >= 29) z >= 7 and z < 9 else if (x < 22 or x >= 26) z >= 7 and z < 15 else z >= 13 and z < 15;
            state.* = if (room or (passage and tunnel)) 0 else stone;
        }
        world.learnSection(.{ .world = 0, .x = cx, .z = cz, .minimum = 0 }, 4, section, .{ .dense = &states });
    };
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ -8, 24, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 4, 3);
    try finishView(&world, view_index);
    try std.testing.expectEqual(@as(u32, 0), world.mask(view_index, 2, 0) & 2);
    const tunnel_section: chunks.Section = .{ .world = 0, .x = 1, .y = 1, .z = 0 };
    for ([_]bool{ true, false }) |straight| {
        const previous = world.section(tunnel_section, 0, 4).?.*;
        const revision = world.revision(view_index);
        var solid: [64]u64 = @splat(0);
        for (&states, 0..) |*state, index| {
            const x = index % 16;
            const y = index / 256;
            const z = index / 16 % 16;
            const tunnel = if (straight or x < 3 or x >= 13) z >= 7 and z < 9 else if (x < 6 or x >= 10) z >= 7 and z < 15 else z >= 13 and z < 15;
            const air = y >= 8 and y < 10 and tunnel;
            state.* = if (air) 0 else stone;
            if (!air) solid[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        try std.testing.expect(!previous.boundaryChanged(&solid));
        world.changed(0, 0, .{ .minimum = .{ 16, 16, 0 }, .maximum = .{ 32, 32, 16 } }, false);
        world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &states });
        try std.testing.expectEqual(previous.connections, world.section(tunnel_section, 0, 4).?.connections);
        try std.testing.expect(!world.ready(view_index));
        try finishView(&world, view_index);
        try std.testing.expectEqual(revision + 1, world.revision(view_index));
        try std.testing.expectEqual(if (straight) @as(u32, 2) else 0, world.mask(view_index, 2, 0) & 2);
    }
}

test "coarse shared faces conservatively retain stacked tunnels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const grid: visibility.Grid = .{ .minimum = .{ -4, 0, -4 }, .size = .{ 9, 4, 9 } };
    var world = try World.init(arena.allocator(), .{ .columns = 81, .views = 1, .radius = 4, .mixed_sections = grid.count() });
    var states: [4096]u16 = undefined;
    for (0..grid.count()) |index| {
        const at = grid.position(index);
        for (&states, 0..) |*state, local| {
            const x = at[0] * 16 + @as(i32, @intCast(local % 16));
            const y = at[1] * 16 + @as(i32, @intCast(local / 256));
            const z = at[2] * 16 + @as(i32, @intCast(local / 16 % 16));
            const tunnel = x >= 4 and z >= 4 and z < 12 and ((y >= 20 and y < 24) or (y >= 28 and y < 32) or (x >= 48 and x < 56 and y >= 28));
            state.* = if (y >= 40 or tunnel) 0 else @intCast(game_data.registry.block_stone_default_state);
        }
        world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = 0 }, 4, @intCast(at[1]), .{ .dense = &states });
    }
    var source_storage: Source = undefined;
    const source = world.source(0, 0, 4, .{ 8, 21, 8 }, &source_storage).?;
    try std.testing.expectEqual(@as(i32, 24), source.camera_bounds.maximum[1]);
    const view_index = @as(usize, 0);
    world.begin(view_index, source, 0, 4, 4);
    try finishView(&world, view_index);
    try std.testing.expect(world.mask(view_index, 3, 0) & 2 != 0);
    try std.testing.expect(world.mask(view_index, 3, 0) & 12 != 0);
    const connections = world.section(.{ .world = 0, .x = 3, .y = 1, .z = 0 }, 0, 4).?.connections;
    const revision = world.revision(view_index);
    for (&states, 0..) |*state, local| {
        const x = local % 16;
        const y = local / 256 + 16;
        const z = local / 16 % 16;
        const tunnel = z >= 4 and z < 12 and ((y >= 20 and y < 24) or y >= 28);
        const opening = x == 4 and z == 8 and y >= 24 and y < 28;
        state.* = if (tunnel or opening) 0 else @intCast(game_data.registry.block_stone_default_state);
    }
    world.changed(0, 0, .{ .minimum = .{ 52, 24, 8 }, .maximum = .{ 53, 28, 9 } }, false);
    world.learnSection(.{ .world = 0, .x = 3, .z = 0, .minimum = 0 }, 4, 1, .{ .dense = &states });
    try std.testing.expectEqual(connections, world.section(.{ .world = 0, .x = 3, .y = 1, .z = 0 }, 0, 4).?.connections);
    try std.testing.expect(!world.ready(view_index));
    try finishView(&world, view_index);
    try std.testing.expectEqual(revision + 1, world.revision(view_index));
}

test "a proven tunnel bend needs no topology beyond its blocked exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    const stone = game_data.registry.block_stone_default_state;
    var states: [4096]u16 = undefined;
    for (0..4096) |local| {
        const x = local % 16;
        const y = local / 256;
        const z = local / 16 % 16;
        states[local] = if (y >= 8 and y < 10 and x < 13 and z < 10 and (z >= 8 or x >= 11)) 0 else stone;
    }
    for (0..5) |x| for (0..5) |z| {
        const cx = @as(i32, @intCast(x)) - 4;
        const cz = @as(i32, @intCast(z)) - 2;
        if (cx == 0 and cz == -1) continue;
        const column: Column = .{ .world = 0, .x = cx, .z = cz, .minimum = 0 };
        world.learnSection(column, 1, 0, if (cx == 0 and cz == 0) .{ .dense = &states } else .{ .uniform = if ((cx == -2 or cx == -1) and cz == 0) 0 else stone });
    };
    var source_storage: Source = undefined;
    const origin = world.source(0, 0, 1, .{ -24, 8, 8 }, &source_storage).?;
    const view_index = @as(usize, 0);
    world.begin(view_index, origin, 0, 1, 2);
    for (0..2048) |_| {
        try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
        if (world.ready(view_index)) break;
    } else return error.VisibilityDidNotComplete;
    try std.testing.expectEqual(@as(u32, 0), world.mask(view_index, 0, -1));
    try std.testing.expect(!world.known(.{ .world = 0, .x = 0, .y = 0, .z = -1 }, 0, 1));
}

test "baked metadata follows entry eviction and survives pooled value reuse under byte pressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(allocator.allocator(), .{ .columns = 64, .views = 1, .radius = 3, .mixed_sections = 256 });
    var solid: [64]u64 = @splat(0);
    for (0..4096) |voxel| if ((voxel % 16 + voxel / 16 % 16 + voxel / 256) % 2 == 0) {
        solid[voxel / 64] |= @as(u64, 1) << @intCast(voxel % 64);
    };
    var data: visibility.Section = .{};
    var workspace: visibility.Workspace = undefined;
    var backing: [visibility.Section.prepared_bytes]u8 = undefined;
    data.build(&solid, &workspace, &backing);
    var encoded: [visibility.Section.prepared_bytes]u8 = undefined;
    const length = try data.writePrepared(&encoded);
    var prepared: chunks.classification.Prepared = .{ .bytes = &encoded, .length = length };
    var classified: chunks.encoding.Classification = .{ .known = .{ .common = 0, .property = occluder_property, .selected = solid } };
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    for (0..3) |_| for (0..256) |record| {
        const position: chunks.Section = .{ .world = 0, .x = @intCast(record / 4), .y = @intCast(record % 4), .z = 0 };
        const reads = [_]chunks.Chunks.ClassificationRequest{.{ .section = position, .result = &classified, .prepared = &prepared }};
        _ = try world.learnClassifications(&reads, 0, 4, .source);
        const actual = world.section(position, 0, 4).?;
        try std.testing.expectEqualDeep(data.connections, actual.connections);
        try std.testing.expectEqualDeep(data.solid, actual.solid);
        try std.testing.expectEqualSlices(u8, data.component_data, actual.component_data);
        const hot = world.section(.{ .world = 0, .x = 0, .y = 0, .z = 0 }, 0, 4).?;
        try std.testing.expectEqualSlices(u8, data.component_data, hot.component_data);
    };
    try std.testing.expect(world.mixed_evictions > 0);
    try std.testing.expect(world.prepared_pool.used_bytes <= world.prepared_records.len);
    try std.testing.expect(!allocator.has_induced_failure);
}

fn finishView(world: *World, index: usize) !void {
    var attempts: usize = 0;
    while (!world.ready(index)) : (attempts += 1) {
        try std.testing.expect(attempts < 8 * world.query.topology.len + 1);
        if (world.active == null) {
            const key = world.views[index].key.?;
            var origin: Source = undefined;
            const source = world.source(key.section.world, key.minimum, key.count, world.views[index].origin.point, &origin) orelse return error.MissingSource;
            world.begin(index, source, key.minimum, key.count, key.radius);
        }
        if (!world.ready(index)) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    }
}

test "one traversal workspace preserves completed views and finishes obsolete snapshots without publishing them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 25, .views = 2, .radius = 1 });
    var states: [4096]u16 = @splat(0);
    states[0] = game_data.registry.block_stone_default_state;
    for (0..25) |column| for (0..2) |y| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(column % 5)) - 2, .z = @as(i32, @intCast(column / 5)) - 2, .minimum = 0 }, 2, y, .{ .dense = &states });
    var first: Source = undefined;
    var second: Source = undefined;
    _ = world.source(0, 0, 2, .{ 8, 24, 8 }, &first).?;
    _ = world.source(0, 0, 2, .{ 24, 24, 8 }, &second).?;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    world.begin(0, &first, 0, 2, 1);
    world.invalidateView(0);
    _ = world.advance();
    try std.testing.expect(!world.ready(0));
    while (world.active != null) try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(!world.ready(0));
    try std.testing.expectEqual(@as(u64, 1), world.completed);
    world.begin(1, &second, 0, 2, 1);
    try finishView(&world, 1);
    const snapshot: [9]u32 = world.views[1].masks[0..9].*;
    world.begin(0, &second, 0, 2, 1);
    try finishView(&world, 0);
    try std.testing.expectEqualSlices(u32, &snapshot, world.views[1].masks);
    try std.testing.expectEqualSlices(u32, world.views[0].masks, world.views[1].masks);
    const completed = world.completed;
    const revision = world.revision(0);
    world.copyView(0, 1);
    try std.testing.expectEqual(revision, world.revision(0));
    try std.testing.expectEqual(completed, world.completed);
    try std.testing.expectEqual(@as(u64, 1), world.shared);
    world.begin(1, &first, 0, 2, 1);
    try std.testing.expectEqualSlices(u32, &snapshot, world.views[0].masks);
    try finishView(&world, 1);
    try std.testing.expect(world.visits <= world.completed * 8 * 9 * 2);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "moving observers reuse completed source proofs and reject changed geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var world = try World.init(bounded.allocator(), .{ .columns = 25, .views = 2, .radius = 1 });
    for (0..25) |column| for (0..2) |y| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(column % 5)) - 2, .z = @as(i32, @intCast(column / 5)) - 2, .minimum = 0 }, 2, y, .{ .uniform = 0 });
    var first: Source = undefined;
    var second: Source = undefined;
    _ = world.source(0, 0, 2, .{ 8, 24, 8 }, &first).?;
    _ = world.source(0, 0, 2, .{ 24, 24, 8 }, &second).?;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    world.begin(0, &first, 0, 2, 1);
    try finishView(&world, 0);
    world.begin(1, &second, 0, 2, 1);
    try finishView(&world, 1);
    const visits = world.visits;
    const queries = world.started;
    try std.testing.expect(world.reuse(0, 0, .{ 24, 24, 8 }, 0, 2, 1, .octant));
    try std.testing.expectEqualSlices(u32, world.views[0].masks, world.views[1].masks);
    world.begin(1, &first, 0, 2, 1);
    try std.testing.expect(world.source_views.get(second.section) == 0);
    try finishView(&world, 1);
    const after_replacement = world.visits;
    try std.testing.expect(world.reuse(0, 0, .{ 25, 24, 8 }, 0, 2, 1, .octant));
    try std.testing.expectEqual(after_replacement, world.visits);
    try std.testing.expectEqual(queries + 1, world.started);
    try std.testing.expect(after_replacement >= visits);
    try std.testing.expect(!world.reuse(0, 1, .{ 25, 24, 8 }, 0, 2, 1, .octant));
    try std.testing.expect(!world.reuse(0, 0, .{ 25, 24, 8 }, 0, 1, 1, .octant));
    try std.testing.expect(!world.reuse(0, 0, .{ 25, 24, 8 }, 0, 2, 0, .octant));
    world.changed(0, 0, .{ .minimum = .{ 24, 24, 8 }, .maximum = .{ 25, 25, 9 } }, false);
    try std.testing.expect(!world.reuse(0, 0, .{ 25, 24, 8 }, 0, 2, 1, .octant));
    try std.testing.expect(!bounded.has_induced_failure);
}

test "incremental edits and cache eviction match fresh visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const radius = 4;
    const height = 4;
    const area: visibility.Grid = .{ .minimum = .{ -radius, 0, -radius }, .size = .{ 9, height, 9 } };
    const states = try allocator.alloc([4096]u16, area.count());
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    for (states, 0..) |*blocks, node| {
        const at = area.position(node);
        for (blocks, 0..) |*block, local| {
            const x = at[0] * 16 + @as(i32, @intCast(local % 16));
            const y = at[1] * 16 + @as(i32, @intCast(local / 256));
            const z = at[2] * 16 + @as(i32, @intCast(local / 16 % 16));
            const room = (x >= 0 and x < 16 and y >= 16 and y < 32 and z >= 0 and z < 16) or
                (x >= 49 and x < 64 and y >= 17 and y < 31 and z >= 1 and z < 15);
            const passage = x >= 16 and x < 50 and y >= 24 and y < 27 and z >= 7 and z < 9;
            block.* = if (room or passage) 0 else stone;
        }
    }
    var incremental = try World.init(allocator, .{ .columns = 81, .views = 1, .radius = radius });
    var fresh = try World.init(allocator, .{ .columns = 81, .views = 1, .radius = radius });
    for ([_]*World{ &incremental, &fresh }) |world| {
        for (states, 0..) |*blocks, node| {
            const at = area.position(node);
            world.learnSection(.{ .world = 0, .x = at[0], .z = at[2], .minimum = 0 }, height, @intCast(at[1]), .{ .dense = blocks });
        }
        var origin: Source = undefined;
        const source = world.source(0, 0, height, .{ 8, 24, 8 }, &origin).?;
        world.begin(0, source, 0, height, radius);
        try finishView(world, 0);
    }
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for (0..16) |phase| {
        const gate: i32 = if (phase >= 10) 2 else if (phase >= 8 and phase < 10) 0 else if (phase >= 6) 1 else 2;
        const node = area.index(.{ gate, 1, 0 }).?;
        const bounds: geometry.Box = if (phase >= 8 and phase < 10) .{ .minimum = .{ 8, 25, 8 }, .maximum = .{ 9, 26, 9 } } else .{ .minimum = .{ gate * 16, 24, 7 }, .maximum = .{ gate * 16 + 1, 27, 9 } };
        if (phase >= 8 and phase < 10) {
            states[node][9 * 256 + 8 * 16 + 8] = if (phase == 8) stone else 0;
        } else {
            for (24..27) |y| for (7..9) |z| {
                const local = (y - 16) * 256 + z * 16;
                states[node][local] = if (phase == 0 and z == 7 or phase == 1 or phase == 4 or phase == 6 or phase == 10 or phase == 12 or phase == 15) stone else 0;
            };
        }
        if (phase >= 10) {
            const other = area.index(.{ 3, 1, 0 }).?;
            for (24..27) |y| for (7..9) |z| {
                states[other][(y - 16) * 256 + z * 16] = if (phase == 10 or phase == 13) stone else 0;
            };
        }
        if (phase == 15) {
            const source_section = area.index(.{ 1, 1, 0 }).?;
            for (24..27) |y| for (7..9) |z| {
                states[source_section][(y - 16) * 256 + z * 16] = stone;
            };
        }
        for ([_]*World{ &incremental, &fresh }) |world| {
            // The incremental world learns each changed section at once and is told so.
            world.changed(0, 0, bounds, world == &incremental);
            world.learnSection(.{ .world = 0, .x = gate, .z = 0, .minimum = 0 }, height, 1, .{ .dense = &states[node] });
            if (phase >= 10 and world == &incremental and !world.ready(0) and world.active == null) {
                var origin: Source = undefined;
                const source = world.source(0, 0, height, .{ 8, 24, 8 }, &origin).?;
                world.begin(0, source, 0, height, radius);
            }
            if (phase >= 10) {
                const other = area.index(.{ 3, 1, 0 }).?;
                world.changed(0, 0, .{ .minimum = .{ 48, 24, 7 }, .maximum = .{ 49, 27, 9 } }, world == &incremental);
                world.learnSection(.{ .world = 0, .x = 3, .z = 0, .minimum = 0 }, height, 1, .{ .dense = &states[other] });
            }
        }
        if (phase == 15) for ([_]*World{ &incremental, &fresh }) |world| {
            const source_section = area.index(.{ 1, 1, 0 }).?;
            world.changed(0, 0, .{ .minimum = .{ 16, 24, 7 }, .maximum = .{ 17, 27, 9 } }, world == &incremental);
            world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, height, 1, .{ .dense = &states[source_section] });
        };
        fresh.invalidateView(0);
        try finishView(&incremental, 0);
        try finishView(&fresh, 0);
        try std.testing.expectEqualSlices(u32, fresh.views[0].masks, incremental.views[0].masks);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "column topology batches match voxel construction before and after a portal edit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var reference = try World.init(allocator, .{ .columns = 9, .views = 1, .radius = 1 });
    var batched = try World.init(allocator, .{ .columns = 9, .views = 1, .radius = 1, .summary_columns = 18 });
    const prepared = try allocator.alloc(u8, prepared_codec.maximum);
    const states = try allocator.create([4096]u16);
    var columns: [9]chunks.classification.Column = undefined;
    var summaries: [9]chunks.classification.ColumnSummary = undefined;
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for (0..2) |phase| {
        for (&columns, &summaries, 0..) |*column, *summary_, index| {
            if (phase == 1 and index != 4) continue;
            column.* = .{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = -1, .count = 3 };
            const key: Column = .{ .world = 0, .x = column.x, .z = column.z, .minimum = -1 };
            if (phase == 1) {
                const box: geometry.Box = .{ .minimum = .{ column.x * 16, -16, column.z * 16 }, .maximum = .{ column.x * 16 + 16, 32, column.z * 16 + 16 } };
                reference.changed(0, -1, box, false);
                batched.changed(0, -1, box, false);
            }
            summary_.* = .{ .known = 7, .prefix_bytes = prepared_codec.prefix_bytes };
            for (0..3) |offset| {
                var classified: chunks.encoding.Classification.Known = .{ .property = occluder_property, .common = 255, .selected = @splat(0) };
                for (states, 0..) |*state, cell| {
                    const occupied = offset == 0 or (offset == 2 and index % 3 == 0) or (offset == 1 and cell % 16 == 8 and (phase == 1 or cell / 256 != 8));
                    state.* = if (occupied) game_data.registry.block_stone_default_state else 0;
                    classified.common &= reference.properties[state.*];
                    if (occupied) classified.selected[cell / 64] |= @as(u64, 1) << @intCast(cell % 64);
                }
                reference.learnSection(key, 3, offset, .{ .dense = states });
                summary_.common[offset] = classified.common;
                const length = try prepared_codec.encode(&classified, prepared);
                if (length != 0) {
                    summary_.prefixed |= @as(u32, 1) << @intCast(offset);
                    @memcpy(summary_.prefixes[offset][0..summary_.prefix_bytes], prepared[0..summary_.prefix_bytes]);
                }
            }
        }
        if (phase == 0) {
            _ = try batched.learnColumnTopology(columns[0..6], summaries[0..6]);
            _ = try batched.learnColumnTopology(columns[6..], summaries[6..]);
        } else _ = try batched.learnColumnTopology(columns[4..5], summaries[4..5]);
        for (columns) |column| {
            const key: Column = .{ .world = column.world, .x = column.x, .z = column.z, .minimum = column.minimum };
            const expected = reference.findTopology(key, 3).?;
            const actual = batched.findTopology(key, 3).?;
            try std.testing.expectEqual(expected.known, actual.known);
            try std.testing.expectEqualDeep(expected.topology.*, actual.topology.*);
        }
        var origin: Source = undefined;
        const source = reference.source(0, -1, 3, .{ 8, 48, 8 }, &origin).?;
        reference.begin(0, source, -1, 3, 1);
        batched.begin(0, source, -1, 3, 1);
        try finishView(&reference, 0);
        try finishView(&batched, 0);
        try std.testing.expectEqualSlices(u32, reference.views[0].masks, batched.views[0].masks);
        try std.testing.expectEqual(@as(usize, 0), batched.lookup.count());
        try std.testing.expectEqual(@as(u64, 0), batched.acquisitions);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "moving horizons batch new topology without changing disclosure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const radius = 8;
    const side = 2 * radius + 1;
    var world = try World.init(bounded.allocator(), .{ .columns = side * side, .views = 1, .radius = radius, .summary_columns = side * side });
    for (0..side * side) |index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % side)) - radius, .z = @as(i32, @intCast(index / side)) - radius, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var origin: Source = undefined;
    const initial = world.source(0, 0, 1, .{ 8, 8, 8 }, &origin).?;
    world.begin(0, initial, 0, 1, radius);
    try finishView(&world, 0);
    const moved = world.source(0, 0, 1, .{ 24, 8, 8 }, &origin).?;
    world.begin(0, moved, 0, 1, radius);
    const advanced = world.advance();
    try std.testing.expect(advanced.requests.len > 4);
    try std.testing.expect(advanced.requests.len <= chunks.classification.column_batch_max);
    for (advanced.requests) |column| {
        try std.testing.expect(chunk_horizon.contains(radius, .{ .x = 1, .z = 0 }, .{ .x = column.x, .z = column.z }));
        world.learnSection(.{ .world = column.world, .x = column.x, .z = column.z, .minimum = 0 }, 1, 0, .{ .uniform = 0 });
    }
    try finishView(&world, 0);
    for (0..side * side) |index| {
        const x = 1 - radius + @as(i32, @intCast(index % side));
        const z = -radius + @as(i32, @intCast(index / side));
        const visible = chunk_horizon.contains(radius, .{ .x = 1, .z = 0 }, .{ .x = x, .z = z });
        try std.testing.expectEqual(@as(u32, @intFromBool(visible)), world.mask(0, x, z));
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "source reuse remains within its baked source section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 49, .views = 1, .radius = 3 });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    for (0..49) |column| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(column % 7)) - 3, .z = @as(i32, @intCast(column / 7)) - 3, .minimum = 0 }, 1, 0, .{ .uniform = stone });
    var center: [4096]u16 = @splat(stone);
    var neighbor: [4096]u16 = @splat(stone);
    for (8..16) |x| center[8 * 256 + 8 * 16 + x] = 0;
    for (0..16) |x| neighbor[8 * 256 + 8 * 16 + x] = 0;
    neighbor[12 * 256 + 12 * 16 + 12] = 0;
    world.changed(0, 0, .{ .minimum = .{ 0, 0, 0 }, .maximum = .{ 32, 16, 16 } }, false);
    world.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = 0 }, 1, 0, .{ .dense = &center });
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 1, 0, .{ .dense = &neighbor });
    var proof: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 8, 8 }, &proof).?;
    try std.testing.expect(source.supports(0, .{ 8, 8, 8 }));
    try std.testing.expect(!source.supports(0, .{ 28, 8, 8 }));
    try std.testing.expect(!source.supports(0, .{ 28, 12, 12 }));
    try std.testing.expect(!source.supports(0, .{ 28, 8, 9 }));
    try std.testing.expect(!source.supports(0, .{ 40, 8, 8 }));
    try std.testing.expect(!source.supports(1, .{ 28, 8, 8 }));
    world.begin(0, source, 0, 1, 3);
    try finishView(&world, 0);
    try std.testing.expectEqual(@as(u32, 1), world.mask(0, 2, 0));
    try std.testing.expect(world.covers(0, 0, .{ .x = 1, .z = 1 }, 1));
    try std.testing.expect(!world.covers(0, 0, .{ .x = 2, .z = 1 }, 1));
}

test "reusable source horizon covers every circular recipient horizon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = (65 + 2 * Source.horizon_padding) * (65 + 2 * Source.horizon_padding), .views = 1, .radius = 32 + Source.horizon_padding });
    for ([_]i32{ 0, 1, 8, 32 }) |radius| {
        world.views[0].key = .{ .section = .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .component = 0, .minimum = 0, .count = 1, .radius = radius + Source.horizon_padding };
        world.views[0].ready = true;
        for (0..9) |neighbor| {
            const center: chunk_horizon.Position = .{ .x = @as(i32, @intCast(neighbor % 3)) - 1, .z = @as(i32, @intCast(neighbor / 3)) - 1 };
            try std.testing.expect(world.covers(0, 0, center, radius));
            for (0..@as(usize, @intCast(2 * radius + 1))) |z| for (0..@as(usize, @intCast(2 * radius + 1))) |x| {
                const at: chunk_horizon.Position = .{ .x = center.x - radius + @as(i32, @intCast(x)), .z = center.z - radius + @as(i32, @intCast(z)) };
                if (chunk_horizon.contains(radius, center, at)) try std.testing.expect(world.readyColumn(0, at.x, at.z));
            };
        }
    }
}

test "fully open neighbor proofs reuse the whole section and invalidate on distant edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 25, .views = 1, .radius = 2 });
    const sections: [3]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..25) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 5)) - 2, .z = @as(i32, @intCast(index / 5)) - 2, .minimum = 0 }, &sections);
    var storage_: Source = undefined;
    const source = world.source(0, 0, 3, .{ 8, 24, 8 }, &storage_).?;
    try std.testing.expect(source.supports(0, .{ 31, 24, 8 }));
    try std.testing.expect(source.supports(0, .{ -16, 24, 8 }));
    try std.testing.expect(!source.supports(0, .{ 32, 24, 8 }));
    world.begin(0, source, 0, 3, 2);
    try finishView(&world, 0);
    try std.testing.expect(world.ready(0));
    world.changed(0, 0, .{ .minimum = .{ 30, 24, 8 }, .maximum = .{ 31, 25, 9 } }, false);
    try std.testing.expect(!world.ready(0));
}

test "edits cancel a query before borrowed retained topology can be traversed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var world = try World.init(arena.allocator(), .{ .columns = 9, .summary_columns = 9, .views = 1, .radius = 1 });
    const sections: [3]section_views.Section = @splat(.{ .stamp = .{}, .view = .{ .uniform = 0 } });
    for (0..9) |index| world.learn(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, &sections);
    var proof: Source = undefined;
    const source = world.source(0, 0, 3, .{ 8, 24, 8 }, &proof).?;
    world.begin(0, source, 0, 3, 1);
    try finishView(&world, 0);
    world.begin(0, source, 0, 3, 1);
    var borrowed: usize = 0;
    for (world.query.borrowed) |column| borrowed += @intFromBool(column != null);
    try std.testing.expect(borrowed != 0);
    world.changed(0, 0, .{ .minimum = .{ 17, 24, 8 }, .maximum = .{ 18, 25, 9 } }, false);
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 3, 1, .{ .uniform = @intCast(game_data.registry.block_stone_default_state) });
    try std.testing.expect(world.outdated);
    try std.testing.expectEqual(@as(usize, 0), world.advance().requests.len);
    try std.testing.expect(world.active == null and !world.ready(0));
}

test "an edit that changes no occlusion leaves completed views ready" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const radius = 1;
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = radius });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    const glass: u16 = @intCast(game_data.registry.block_glass_default_state);
    // Stone below, air above, in every section of every column.
    var states: [4096]u16 = undefined;
    for (&states, 0..) |*state, local| state.* = if (local / 256 < 4) stone else 0;
    for (0..9) |index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, 1, 0, .{ .dense = &states });
    var origin: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 10, 8 }, &origin).?;
    world.begin(0, source, 0, 1, radius);
    try finishView(&world, 0);
    try std.testing.expect(world.ready(0));
    const cell: geometry.Box = .{ .minimum = .{ 20, 12, 4 }, .maximum = .{ 21, 13, 5 } };
    const local = 12 * 256 + 4 * 16 + 4;
    // Glass occludes nothing and the section was not all air, so nobody sweeps again.
    states[local] = glass;
    world.changed(0, 0, cell, true);
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 1, 0, .{ .dense = &states });
    try std.testing.expect(world.ready(0));
    // Stone does, and every view that may see it is out of date.
    states[local] = stone;
    world.changed(0, 0, cell, true);
    world.learnSection(.{ .world = 0, .x = 1, .z = 0, .minimum = 0 }, 1, 0, .{ .dense = &states });
    try std.testing.expect(!world.ready(0));
    try finishView(&world, 0);
    // An edit beside the source prepares the source again when it changes occlusion.
    states[10 * 256 + 8 * 16 + 9] = stone;
    world.changed(0, 0, .{ .minimum = .{ 9, 10, 8 }, .maximum = .{ 10, 11, 9 } }, true);
    try std.testing.expect(world.ready(0));
    world.learnSection(.{ .world = 0, .x = 0, .z = 0, .minimum = 0 }, 1, 0, .{ .dense = &states });
    try std.testing.expect(world.sourceInvalidated(0) or !world.ready(0));
}

test "a section whose tile goes before it is learned again still invalidates the views that see it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const radius = 1;
    var world = try World.init(arena.allocator(), .{ .columns = 9, .views = 1, .radius = radius });
    const stone: u16 = @intCast(game_data.registry.block_stone_default_state);
    var states: [4096]u16 = undefined;
    for (&states, 0..) |*state, local| state.* = if (local / 256 < 4) stone else 0;
    for (0..9) |index| world.learnSection(.{ .world = 0, .x = @as(i32, @intCast(index % 3)) - 1, .z = @as(i32, @intCast(index / 3)) - 1, .minimum = 0 }, 1, 0, .{ .dense = &states });
    var origin: Source = undefined;
    const source = world.source(0, 0, 1, .{ 8, 10, 8 }, &origin).?;
    world.begin(0, source, 0, 1, radius);
    try finishView(&world, 0);
    try std.testing.expect(world.ready(0));
    const column: Column = .{ .world = 0, .x = 1, .z = 0, .minimum = 0 };
    const cell: geometry.Box = .{ .minimum = .{ 20, 12, 4 }, .maximum = .{ 21, 13, 5 } };
    // The section is forgotten, then never learned again: the change invalidates when
    // the caller says it is done.
    world.changed(0, 0, cell, true);
    try std.testing.expect(world.ready(0));
    world.settleChanges();
    try std.testing.expect(!world.ready(0));
    world.learnSection(column, 1, 0, .{ .dense = &states });
    try finishView(&world, 0);
    // Its tile is dropped before the relearn, so nothing is left to compare against.
    states[12 * 256 + 4 * 16 + 4] = stone;
    world.changed(0, 0, cell, true);
    const slot = world.lookup.get(column).?;
    world.tiles[slot].initialized = 0;
    world.learnSection(column, 1, 0, .{ .dense = &states });
    world.settleChanges();
    try std.testing.expect(!world.ready(0));
    try std.testing.expectEqual(@as(usize, 0), world.awaiting_count);
}
