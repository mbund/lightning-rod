const std = @import("std");
const chunks = @import("chunks");

/// Sections in the tallest dimension a column holds.
pub const maximum_sections = 24;
/// Width of the lighting workspace in blocks, a column and its neighbours on each side.
/// Row views stride by it.
pub const side = 48;

pub const Stamp = struct { generation: u64 = 0, revision: u64 = 0, index: usize = 0, constant: ?u16 = null, storage: enum { decoded, encoded, baked, hulled } = .decoded };

pub const Section = struct {
    pub const View = union(enum) {
        unavailable,
        uniform: u16,
        dense: *const [4096]u16,
        rows: []const u16,
        chunk: chunks.View,
        encoded: chunks.encoding.Packed,

        pub fn fromChunk(view: chunks.View) View {
            return switch (view) {
                .uniform => |state| .{ .uniform = state },
                .dense => .{ .chunk = view },
                .palette => |palette| .{ .encoded = palette },
            };
        }

        pub fn get(self: View, index: u12) u16 {
            return switch (self) {
                .unavailable => unreachable,
                .uniform => |state| state,
                .dense => |states| states[index],
                .rows => |states| states[@as(usize, index / 256) * side * side + @as(usize, index / 16 % 16) * side + index % 16],
                .chunk => |view| view.get(index),
                .encoded => |view| view.get(index),
            };
        }

        pub inline fn row(self: View, index: u8) [16]u16 {
            const start = @as(usize, index) * 16;
            return switch (self) {
                .unavailable => unreachable,
                .uniform => |state| @splat(state),
                .dense => |states| states[start..][0..16].*,
                .rows => |states| states[@as(usize, index / 16) * side * side + @as(usize, index % 16) * side ..][0..16].*,
                .chunk => |view| view.row(index),
                .encoded => |view| view.row(index),
            };
        }
    };
    stamp: Stamp,
    view: View,
    biomes: ?Biomes = null,
};

/// Views borrow either the lighting workspace or the retained frame for this delivery.
pub const Biomes = union(enum) {
    constant: u16,
    values: *const [64]u16,
    /// A horizontal 4 by 4 plane repeated along the vertical axis.
    plane: *const [16]u16,
    encoded: chunks.BiomeView,
    palette: chunks.Light.Biome.Palette,

    pub inline fn row(self: Biomes, index: u2) [16]u16 {
        return switch (self) {
            .constant => |value| @splat(value),
            .values => |values| values[@as(usize, index) * 16 ..][0..16].*,
            .plane => |values| values.*,
            .encoded => |view| view.row(index),
            .palette => |values| values.row(index),
        };
    }

    pub fn get(self: Biomes, index: u6) u16 {
        return switch (self) {
            .constant => |value| value,
            .values => |values| values[index],
            .plane => |values| values[index % 16],
            .encoded => |view| view.get(index),
            .palette => |values| values.get(index),
        };
    }

    pub fn uniform(self: Biomes) ?u16 {
        const cells: @Vector(64, u16) = switch (self) {
            .constant => |value| return value,
            .values => |values| values.*,
            .encoded => |view| return view.uniform(),
            .palette => return null,
            .plane => |values| {
                const plane: @Vector(16, u16) = values.*;
                return if (@reduce(.And, plane == @as(@Vector(16, u16), @splat(plane[0])))) plane[0] else null;
            },
        };
        return if (@reduce(.And, cells == @as(@Vector(64, u16), @splat(cells[0])))) self.get(0) else null;
    }
};

test "biome rows preserve native and encoded cell order" {
    var values: [64]u16 = undefined;
    var bytes: [128]u8 = undefined;
    for (&values, 0..) |*value, cell| {
        value.* = @intCast(cell * 997 + 521);
        std.mem.writeInt(u16, bytes[cell * 2 ..][0..2], value.*, .little);
    }
    for ([_]Biomes{ .{ .constant = 300 }, .{ .values = &values }, .{ .encoded = .{ .bytes = &bytes } }, .{ .plane = values[0..16] } }) |source| {
        for (0..4) |row_index| {
            const row = source.row(@intCast(row_index));
            for (row, 0..) |value, cell| try std.testing.expectEqual(if (source == .constant) @as(u16, 300) else values[(if (source == .plane) @as(usize, 0) else row_index * 16) + cell], value);
        }
    }
}
