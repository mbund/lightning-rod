//! Occupancy: which four by four by four blocks of a section hold a state with a property, one
//! bit each, so a section is one word. Bit `y * 16 + z * 4 + x` stands for the block at
//! (4x, 4y, 4z) within the section.
//!
//! A word is worked out from the section as it is read and kept until an edit of the section
//! forgets it. It is derived: what the table forgets is worked out again on the next read, so the
//! table is bounded and evicts freely.

const std = @import("std");
const chunks = @import("chunks.zig");

const assert = std.debug.assert;

/// The occupancy of a section as read: which of its blocks of 4x4x4 cells hold a state whose
/// property byte has `property` set.
pub fn of(view: chunks.View, properties: []const u8, property: u8) !u64 {
    assert(std.math.isPowerOfTwo(property));
    switch (view) {
        .uniform => |state| {
            if (state >= properties.len) return error.Corrupt;
            return if (properties[state] & property != 0) std.math.maxInt(u64) else 0;
        },
        .palette => |palette| {
            const known = try palette.classify(properties, property);
            return fold(&known.selected);
        },
        .dense => {
            var cells: [64]u64 = @splat(0);
            for (0..256) |row| {
                const states = view.row(@intCast(row));
                var bits: u16 = 0;
                for (states, 0..) |state, x| {
                    if (state >= properties.len) return error.Corrupt;
                    bits |= @as(u16, @intFromBool(properties[state] & property != 0)) << @intCast(x);
                }
                cells[row / 4] |= @as(u64, bits) << @intCast((row % 4) * 16);
            }
            return fold(&cells);
        },
    }
}

/// Cell bits, index `y * 256 + z * 16 + x`, folded into the blocks of 4x4x4 they lie in.
fn fold(cells: *const [64]u64) u64 {
    var result: u64 = 0;
    // A word is four rows of x at one y: z from (word % 4) * 4 to three more.
    for (cells, 0..) |word, index| {
        if (word == 0) continue;
        const y = index / 4;
        const z = (index % 4) * 4;
        // Each 16 bit row splits into four nibbles of x; any bit in a nibble marks its block.
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            const bits: u16 = @truncate(word >> @intCast(row * 16));
            if (bits == 0) continue;
            for (0..4) |x| {
                if ((bits >> @intCast(x * 4)) & 0xf != 0) result |= @as(u64, 1) << @intCast((y / 4) * 16 + ((z + row) / 4) * 4 + x);
            }
        }
    }
    return result;
}

/// The block of 4x4x4 cells a local cell lies in, as an occupancy bit.
pub fn bit(x: u4, y: u4, z: u4) u6 {
    return @intCast(@as(u6, y / 4) * 16 + @as(u6, z / 4) * 4 + x / 4);
}

/// Occupancy words of sections read lately, in buckets of four with a clock in each.
pub const Table = struct {
    const ways = 4;
    entries: []Entry,
    hand: []u8,

    const Entry = struct {
        section: chunks.Section = undefined,
        mask: u64 = 0,
        used: bool = false,
        referenced: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Table {
        if (capacity < ways or !std.math.isPowerOfTwo(capacity)) return error.InvalidConfiguration;
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        @memset(entries, .{});
        const hand = try allocator.alloc(u8, capacity / ways);
        @memset(hand, 0);
        return .{ .entries = entries, .hand = hand };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.free(self.hand);
        self.* = undefined;
    }

    fn bucket(self: *const Table, section: chunks.Section) usize {
        var hasher = std.hash.Wyhash.init(0);
        std.hash.autoHash(&hasher, section);
        return @as(usize, @truncate(hasher.final())) & (self.entries.len / ways - 1);
    }

    pub fn get(self: *Table, section: chunks.Section) ?u64 {
        const at = self.bucket(section) * ways;
        for (self.entries[at..][0..ways]) |*entry| {
            if (!entry.used or !std.meta.eql(entry.section, section)) continue;
            entry.referenced = true;
            return entry.mask;
        }
        return null;
    }

    pub fn put(self: *Table, section: chunks.Section, mask: u64) void {
        const index = self.bucket(section);
        const group = self.entries[index * ways ..][0..ways];
        for (group) |*entry| {
            if (!entry.used or !std.meta.eql(entry.section, section)) continue;
            entry.mask = mask;
            entry.referenced = true;
            return;
        }
        for (group) |*entry| if (!entry.used) {
            entry.* = .{ .section = section, .mask = mask, .used = true, .referenced = true };
            return;
        };
        // Full: the clock of the bucket picks one not read since it last passed.
        while (true) {
            const entry = &group[self.hand[index]];
            self.hand[index] = (self.hand[index] + 1) % ways;
            if (entry.referenced) {
                entry.referenced = false;
                continue;
            }
            entry.* = .{ .section = section, .mask = mask, .used = true, .referenced = true };
            return;
        }
    }

    /// A section changed: its word is worked out again when next read.
    pub fn forget(self: *Table, section: chunks.Section) void {
        const at = self.bucket(section) * ways;
        for (self.entries[at..][0..ways]) |*entry| {
            if (entry.used and std.meta.eql(entry.section, section)) entry.used = false;
        }
    }
};

test "occupancy folds cells into blocks of four" {
    var cells: [64]u64 = @splat(0);
    // Cell (5, 9, 14): y 9, z 14, x 5.
    const index: usize = 9 * 256 + 14 * 16 + 5;
    cells[index / 64] |= @as(u64, 1) << @intCast(index % 64);
    try std.testing.expectEqual(@as(u64, 1) << bit(5, 9, 14), fold(&cells));
    const properties = [_]u8{ 0, 1 };
    try std.testing.expectEqual(@as(u64, 0), try of(.{ .uniform = 0 }, &properties, 1));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try of(.{ .uniform = 1 }, &properties, 1));
    var dense: [8192]u8 = @splat(0);
    std.mem.writeInt(u16, dense[index * 2 ..][0..2], 1, .little);
    try std.testing.expectEqual(@as(u64, 1) << bit(5, 9, 14), try of(.{ .dense = &dense }, &properties, 1));
}

test "the table keeps words until forgotten or evicted" {
    var table = try Table.init(std.testing.allocator, 8);
    defer table.deinit(std.testing.allocator);
    const section: chunks.Section = .{ .world = 0, .x = 1, .y = -2, .z = 3 };
    try std.testing.expect(table.get(section) == null);
    table.put(section, 7);
    try std.testing.expectEqual(@as(?u64, 7), table.get(section));
    table.forget(section);
    try std.testing.expect(table.get(section) == null);
    for (0..64) |index| table.put(.{ .world = 0, .x = @intCast(index), .y = 0, .z = 0 }, index);
    var kept: usize = 0;
    for (0..64) |index| kept += @intFromBool(table.get(.{ .world = 0, .x = @intCast(index), .y = 0, .z = 0 }) != null);
    try std.testing.expect(kept <= 8);
}
