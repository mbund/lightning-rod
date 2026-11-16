//! Layers: which cells of a section can act, decided by the states of the cells around them.
//!
//! A rule selects a set of states and ANDs it with an expression over state sets: membership,
//! the value at an offset, whether any cell in a box has a value, and, or, not. A layer is up
//! to `rules_max` rules over up to `sets_max` sets, and a cell acts when any rule holds for it.
//!
//! Evaluation works on bit volumes that cover the section and a halo from its neighbours, one
//! row of x bits per y and z. Expressions may reach `halo` cells past the section on each axis,
//! which keeps every read inside the 27 sections around it.

const std = @import("std");
const encoding = @import("encoding.zig");
const assert = std.debug.assert;

pub const sets_max = 8;
pub const nodes_max = 16;
pub const rules_max = 8;
/// Cells past the section an expression may read, per side, as x, y and z.
pub const halo = [3]u8{ 8, 4, 4 };

pub const Set = u3;
pub const Node = union(enum) {
    /// Cells whose state is in the set.
    set: Set,
    /// The value of node `of` at the cell `by` away.
    offset: struct { of: u8, by: [3]i8 },
    /// Whether node `of` holds in any cell from `low` to `high` away, bounds included.
    any: struct { of: u8, low: [3]i8, high: [3]i8 },
    both: [2]u8,
    either: [2]u8,
    not: u8,
};

/// Cells in `selected` act where the last node holds, or everywhere without nodes.
pub const Rule = struct { selected: Set, nodes: []const Node = &.{} };

/// The sections around the one evaluated, by `neighbour`. A null section holds air, state 0.
pub const Neighbourhood = [27]?[]const u8;

pub fn neighbour(x: i2, y: i2, z: i2) usize {
    return @as(usize, @intCast(@as(i8, y) + 1)) * 9 + @as(usize, @intCast(@as(i8, z) + 1)) * 3 + @as(usize, @intCast(@as(i8, x) + 1));
}

const Reach = struct { low: [3]i16 = @splat(0), high: [3]i16 = @splat(0) };

const width_z = 16 + 2 * @as(usize, halo[2]);
const width_y = 16 + 2 * @as(usize, halo[1]);
const rows = width_y * width_z;
const Volume = [rows]u32;

pub const Layer = struct {
    /// The sets each block state is in, one bit per set.
    properties: []const u8,
    selected: [rules_max]Set = undefined,
    lengths: [rules_max]u8 = undefined,
    nodes: [rules_max][nodes_max]Node = undefined,
    count: u8 = 0,
    /// Sets some rule reads.
    used: u8 = 0,
    /// Rules whose expression reads past the cell itself.
    spread: u8 = 0,
    reach: [rules_max]Reach = @splat(.{}),
    /// How far an edit changes what acts, the union of every rule's reach.
    influence: Reach = .{},

    pub fn init(properties: []const u8) Layer {
        assert(properties.len > 0);
        return .{ .properties = properties };
    }

    pub fn add(self: *Layer, rule: Rule) !void {
        if (self.count == rules_max) return error.LayerCapacity;
        if (rule.nodes.len > nodes_max) return error.LayerCapacity;
        var reaches: [nodes_max]Reach = undefined;
        var used: u8 = @as(u8, 1) << rule.selected;
        for (rule.nodes, 0..) |node, index| {
            const reach: Reach = switch (node) {
                .set => |set| set: {
                    used |= @as(u8, 1) << set;
                    break :set .{};
                },
                .offset => |offset| offset: {
                    if (offset.of >= index) return error.InvalidLayer;
                    var reach = reaches[offset.of];
                    for (0..3) |axis| {
                        reach.low[axis] += offset.by[axis];
                        reach.high[axis] += offset.by[axis];
                    }
                    break :offset reach;
                },
                .any => |box| box: {
                    if (box.of >= index) return error.InvalidLayer;
                    var reach = reaches[box.of];
                    for (0..3) |axis| {
                        if (box.low[axis] > box.high[axis]) return error.InvalidLayer;
                        reach.low[axis] += box.low[axis];
                        reach.high[axis] += box.high[axis];
                    }
                    break :box reach;
                },
                .both, .either => |pair| pair: {
                    if (pair[0] >= index or pair[1] >= index) return error.InvalidLayer;
                    break :pair merge(reaches[pair[0]], reaches[pair[1]]);
                },
                .not => |of| not: {
                    if (of >= index) return error.InvalidLayer;
                    break :not reaches[of];
                },
            };
            for (0..3) |axis| {
                if (-reach.low[axis] > halo[axis] or reach.high[axis] > halo[axis]) return error.LayerReach;
            }
            reaches[index] = reach;
        }
        const index = self.count;
        @memcpy(self.nodes[index][0..rule.nodes.len], rule.nodes);
        self.selected[index] = rule.selected;
        self.lengths[index] = @intCast(rule.nodes.len);
        if (rule.nodes.len != 0) {
            self.reach[index] = reaches[rule.nodes.len - 1];
            self.influence = merge(self.influence, self.reach[index]);
            if (!std.meta.eql(self.reach[index], Reach{})) self.spread |= @as(u8, 1) << @intCast(index);
        }
        self.used |= used;
        self.count += 1;
    }

    /// The rule added at `index`. Its nodes borrow the layer.
    pub fn ruleAt(self: *const Layer, index: usize) Rule {
        assert(index < self.count);
        return .{ .selected = self.selected[index], .nodes = self.nodes[index][0..self.lengths[index]] };
    }

    fn merge(a: Reach, b: Reach) Reach {
        var result: Reach = undefined;
        for (0..3) |axis| {
            result.low[axis] = @min(a.low[axis], b.low[axis]);
            result.high[axis] = @max(a.high[axis], b.high[axis]);
        }
        return result;
    }

    /// Identifies what the layer computes, for records derived from it.
    pub fn fingerprint(self: *const Layer, identity: []const u8) [32]u8 {
        var hash = std.crypto.hash.Blake3.init(.{});
        hash.update("lightning_rod:layer:1");
        hash.update(identity);
        hash.update(self.properties);
        for (0..self.count) |index| {
            const rule = self.ruleAt(index);
            hash.update(&.{ rule.selected, @intCast(rule.nodes.len) });
            for (rule.nodes) |node| {
                var bytes: [8]u8 = @splat(0);
                bytes[0] = @backingInt(std.meta.activeTag(node));
                switch (node) {
                    .set => |set| bytes[1] = set,
                    .offset => |offset| {
                        bytes[1] = offset.of;
                        for (offset.by, 0..) |value, axis| bytes[2 + axis] = @bitCast(value);
                    },
                    .any => |box| {
                        bytes[1] = box.of;
                        for (box.low, box.high, 0..) |low, high, axis| {
                            bytes[2 + axis] = @bitCast(low);
                            bytes[5 + axis] = @bitCast(high);
                        }
                    },
                    .both, .either => |pair| bytes[1..3].* = pair,
                    .not => |of| bytes[1] = of,
                }
                hash.update(&bytes);
            }
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }

    /// Which rules have selected cells in the section, and whether any of them needs the
    /// sections around it. Sections without candidates act nowhere.
    pub fn candidates(self: *const Layer, center: ?[]const u8) !Candidates {
        var result: Candidates = .{};
        for (0..self.count) |index| {
            const rule = self.ruleAt(index);
            const bit = @as(u8, 1) << rule.selected;
            const present = if (center) |bytes| present: {
                const known = try encoding.classify(bytes, self.properties, bit);
                break :present known.common & bit != 0 or !std.mem.allEqual(u64, &known.selected, 0);
            } else self.properties[0] & bit != 0;
            if (!present) continue;
            result.rules |= @as(u8, 1) << @intCast(index);
            if (self.spread & (@as(u8, 1) << @intCast(index)) != 0) result.neighbours = true;
        }
        return result;
    }

    /// The cells of the center section that act, and how many. Neighbours are read only for
    /// rules that reach past the cell, so they may be null when `candidates` said none are.
    pub fn evaluate(self: *const Layer, workspace: *Workspace, sections: *const Neighbourhood, output: *[64]u64) !u16 {
        @memset(output, 0);
        const wanted = try self.candidates(sections[13]);
        if (wanted.rules == 0) return 0;
        if (wanted.neighbours) try workspace.fill(self, sections) else try workspace.fillCenter(self, sections[13]);
        for (0..self.count) |index| {
            const rule = self.ruleAt(index);
            if (wanted.rules & (@as(u8, 1) << @intCast(index)) == 0) continue;
            const result = workspace.run(rule);
            const selected = &workspace.sets[rule.selected];
            for (0..16) |y| for (0..16) |z| {
                const row = rowIndex(@intCast(y), @intCast(z));
                const bits: u16 = @truncate((selected[row] & result[row]) >> halo[0]);
                output[y * 4 + z / 4] |= @as(u64, bits) << @intCast((z % 4) * 16);
            };
        }
        var count: u16 = 0;
        for (output) |word| count += @popCount(word);
        return count;
    }
};

pub const Candidates = struct { rules: u8 = 0, neighbours: bool = false };

fn rowIndex(y: i32, z: i32) usize {
    assert(y >= -@as(i32, halo[1]) and y < 16 + @as(i32, halo[1]));
    assert(z >= -@as(i32, halo[2]) and z < 16 + @as(i32, halo[2]));
    return @as(usize, @intCast(y + halo[1])) * width_z + @as(usize, @intCast(z + halo[2]));
}

fn shiftX(row: u32, by: i32) u32 {
    // A cell `by` away along x is `by` bits up the row, so reading it moves bits down.
    if (by >= 32 or by <= -32) return 0;
    return if (by >= 0) row >> @intCast(by) else row << @intCast(-by);
}

/// Scratch volumes for one evaluation at a time. About 50 KiB.
pub const Workspace = struct {
    sets: [sets_max]Volume = undefined,
    nodes: [nodes_max]Volume = undefined,
    scratch: [2]Volume = undefined,
    masks: [27][64]u64 = undefined,

    fn fillCenter(self: *Workspace, layer: *const Layer, center: ?[]const u8) !void {
        for (0..sets_max) |set| {
            if (layer.used & (@as(u8, 1) << @intCast(set)) == 0) continue;
            const mask = try sectionMask(layer, center, @intCast(set));
            @memset(&self.sets[set], 0);
            for (0..16) |y| for (0..16) |z| {
                self.sets[set][rowIndex(@intCast(y), @intCast(z))] = @as(u32, maskRow(&mask, @intCast(y), @intCast(z))) << halo[0];
            };
        }
    }

    fn fill(self: *Workspace, layer: *const Layer, sections: *const Neighbourhood) !void {
        for (0..sets_max) |set| {
            if (layer.used & (@as(u8, 1) << @intCast(set)) == 0) continue;
            for (sections, &self.masks) |section, *mask| mask.* = try sectionMask(layer, section, @intCast(set));
            const volume = &self.sets[set];
            var y: i32 = -@as(i32, halo[1]);
            while (y < 16 + @as(i32, halo[1])) : (y += 1) {
                var z: i32 = -@as(i32, halo[2]);
                while (z < 16 + @as(i32, halo[2])) : (z += 1) {
                    const sy: i2 = @intCast(@divFloor(y, 16));
                    const sz: i2 = @intCast(@divFloor(z, 16));
                    const ly: u4 = @intCast(@mod(y, 16));
                    const lz: u4 = @intCast(@mod(z, 16));
                    const left: u32 = maskRow(&self.masks[neighbour(-1, sy, sz)], ly, lz);
                    const middle: u32 = maskRow(&self.masks[neighbour(0, sy, sz)], ly, lz);
                    const right: u32 = maskRow(&self.masks[neighbour(1, sy, sz)], ly, lz);
                    comptime assert(halo[0] == 8);
                    volume[rowIndex(y, z)] = (left >> 8) | (middle << 8) | ((right & 0xff) << 24);
                }
            }
        }
    }

    fn run(self: *Workspace, rule: Rule) *const Volume {
        if (rule.nodes.len == 0) {
            @memset(&self.scratch[0], std.math.maxInt(u32));
            return &self.scratch[0];
        }
        for (rule.nodes, 0..) |node, index| {
            const out = &self.nodes[index];
            switch (node) {
                .set => |set| out.* = self.sets[set],
                .offset => |offset| shift(out, &self.nodes[offset.of], offset.by[0], offset.by[1], offset.by[2]),
                .any => |box| self.dilate(out, &self.nodes[box.of], box.low, box.high),
                .both => |pair| for (out, self.nodes[pair[0]], self.nodes[pair[1]]) |*row, a, b| {
                    row.* = a & b;
                },
                .either => |pair| for (out, self.nodes[pair[0]], self.nodes[pair[1]]) |*row, a, b| {
                    row.* = a | b;
                },
                .not => |of| for (out, self.nodes[of]) |*row, a| {
                    row.* = ~a;
                },
            }
        }
        return &self.nodes[rule.nodes.len - 1];
    }

    /// Each cell takes the value of `input` at the cell `x`, `y` and `z` away. Values from
    /// past the volume are false.
    fn shift(out: *Volume, input: *const Volume, x: i32, y: i32, z: i32) void {
        var row_y: i32 = -@as(i32, halo[1]);
        while (row_y < 16 + @as(i32, halo[1])) : (row_y += 1) {
            var row_z: i32 = -@as(i32, halo[2]);
            while (row_z < 16 + @as(i32, halo[2])) : (row_z += 1) {
                const from_y = row_y + y;
                const from_z = row_z + z;
                const inside = from_y >= -@as(i32, halo[1]) and from_y < 16 + @as(i32, halo[1]) and from_z >= -@as(i32, halo[2]) and from_z < 16 + @as(i32, halo[2]);
                out[rowIndex(row_y, row_z)] = if (inside) shiftX(input[rowIndex(from_y, from_z)], x) else 0;
            }
        }
    }

    /// Each cell holds when `input` holds anywhere in the box around it, one axis at a time.
    fn dilate(self: *Workspace, out: *Volume, input: *const Volume, low: [3]i8, high: [3]i8) void {
        const along_x = &self.scratch[0];
        for (along_x, input) |*row, value| {
            var merged: u32 = 0;
            var x: i32 = low[0];
            while (x <= high[0]) : (x += 1) merged |= shiftX(value, x);
            row.* = merged;
        }
        const along_z = &self.scratch[1];
        @memset(along_z, 0);
        var z: i32 = low[2];
        while (z <= high[2]) : (z += 1) {
            shift(out, along_x, 0, 0, z);
            for (along_z, out) |*row, value| row.* |= value;
        }
        @memset(out, 0);
        var y: i32 = low[1];
        while (y <= high[1]) : (y += 1) {
            shift(along_x, along_z, 0, y, 0);
            for (out, along_x) |*row, value| row.* |= value;
        }
    }
};

fn sectionMask(layer: *const Layer, section: ?[]const u8, set: Set) ![64]u64 {
    const bit = @as(u8, 1) << set;
    const bytes = section orelse return if (layer.properties[0] & bit != 0) @splat(std.math.maxInt(u64)) else @splat(0);
    const known = try encoding.classify(bytes, layer.properties, bit);
    return known.selected;
}

fn maskRow(mask: *const [64]u64, y: u4, z: u4) u16 {
    return @truncate(mask[@as(usize, y) * 4 + z / 4] >> @intCast(@as(u6, z % 4) * 16));
}

// Tests build sections in the dense encoding: a 1 and then every cell's state.

const air: u16 = 0;
const grass: u16 = 1;
const dirt: u16 = 2;
const stone: u16 = 3;

const Section = struct {
    bytes: [encoding.dense_block_bytes]u8 = undefined,

    fn filled(state: u16) Section {
        var section: Section = .{};
        section.bytes[0] = 1;
        for (0..4096) |cell| section.set(@intCast(cell), state);
        return section;
    }

    fn set(self: *Section, cell: u12, state: u16) void {
        std.mem.writeInt(u16, self.bytes[1 + @as(usize, cell) * 2 ..][0..2], state, .little);
    }

    fn put(self: *Section, x: u4, y: u4, z: u4, state: u16) void {
        self.set(@as(u12, y) * 256 + @as(u12, z) * 16 + x, state);
    }
};

/// Sets: 0 grass, 1 dirt, 2 blocks that cover what is below them, which grass and dirt do.
const test_properties = [_]u8{ 0, 1 | 4, 2 | 4, 4 };

/// Grass acts when covered, or when dirt it could spread to is in its box.
const grass_nodes = [_]Node{
    .{ .set = 1 },
    .{ .set = 2 },
    .{ .offset = .{ .of = 1, .by = .{ 0, 1, 0 } } },
    .{ .not = 2 },
    .{ .both = .{ 0, 3 } },
    .{ .any = .{ .of = 4, .low = .{ -1, -3, -1 }, .high = .{ 1, 1, 1 } } },
    .{ .either = .{ 5, 2 } },
};

fn flat() Section {
    var section: Section = .filled(air);
    for (0..16) |x| for (0..16) |z| {
        for (0..4) |y| section.put(@intCast(x), @intCast(y), @intCast(z), dirt);
        section.put(@intCast(x), 4, @intCast(z), grass);
    };
    return section;
}

fn testLayer() !Layer {
    var layer: Layer = .init(&test_properties);
    try layer.add(.{ .selected = 0, .nodes = &grass_nodes });
    return layer;
}

test "a grass field acts nowhere, and exposed dirt and cover wake only the grass they reach" {
    const layer = try testLayer();
    var workspace: Workspace = .{};
    var mask: [64]u64 = undefined;
    var field = flat();
    var around: Neighbourhood = undefined;
    // Every neighbour is a grass field too, so no edge looks like exposed dirt.
    var neighbours: [27]Section = undefined;
    for (&neighbours, &around, 0..) |*section, *slot, index| {
        section.* = if (index / 9 == 1) flat() else .filled(if (index / 9 == 0) dirt else air);
        slot.* = &section.bytes;
    }
    around[13] = &field.bytes;
    try std.testing.expectEqual(@as(u16, 0), try layer.evaluate(&workspace, &around, &mask));

    // Dirt at the surface wakes the eight grass cells around it.
    field.put(5, 4, 5, dirt);
    try std.testing.expectEqual(@as(u16, 8), try layer.evaluate(&workspace, &around, &mask));
    try std.testing.expect(mask[4 * 4 + 1] & (@as(u64, 1) << 4) != 0);

    // Stone on one grass cell far away makes it die, so it acts too.
    field.put(12, 5, 12, stone);
    try std.testing.expectEqual(@as(u16, 9), try layer.evaluate(&workspace, &around, &mask));

    // Covered dirt is no target: grass only acts by dying where it is covered.
    field.put(5, 5, 5, stone);
    try std.testing.expectEqual(@as(u16, 1), try layer.evaluate(&workspace, &around, &mask));
}

test "rules read across section borders" {
    const layer = try testLayer();
    var workspace: Workspace = .{};
    var mask: [64]u64 = undefined;
    var neighbours: [27]Section = undefined;
    var around: Neighbourhood = undefined;
    for (&neighbours, &around, 0..) |*section, *slot, index| {
        section.* = if (index / 9 == 1) flat() else .filled(if (index / 9 == 0) dirt else air);
        slot.* = &section.bytes;
    }
    // Exposed dirt at x 0 of the section to the east wakes the grass at x 15 here.
    neighbours[neighbour(1, 0, 0)].put(0, 4, 7, dirt);
    try std.testing.expectEqual(@as(u16, 3), try layer.evaluate(&workspace, &around, &mask));
    // A trench along z at x 6 leaves dirt at y 1, three below the grass and one across, open
    // to the sky. Dirt in its walls is open only sideways, which grass cannot spread onto.
    var step = flat();
    for (0..16) |z| for (2..5) |y| step.put(6, @intCast(y), @intCast(z), air);
    around[13] = &step.bytes;
    neighbours[neighbour(1, 0, 0)] = flat();
    try std.testing.expectEqual(@as(u16, 32), try layer.evaluate(&workspace, &around, &mask));
}

test "rules without nodes act on every selected cell and need no neighbours" {
    var layer: Layer = .init(&test_properties);
    try layer.add(.{ .selected = 1 });
    var workspace: Workspace = .{};
    var mask: [64]u64 = undefined;
    var field = flat();
    var around: Neighbourhood = @splat(null);
    around[13] = &field.bytes;
    try std.testing.expect(!(try layer.candidates(&field.bytes)).neighbours);
    try std.testing.expectEqual(@as(u16, 4 * 256), try layer.evaluate(&workspace, &around, &mask));
    try std.testing.expectError(error.LayerReach, layer.add(.{ .selected = 0, .nodes = &.{ .{ .set = 1 }, .{ .offset = .{ .of = 0, .by = .{ 0, 5, 0 } } } } }));
}
