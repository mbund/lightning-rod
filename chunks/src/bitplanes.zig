const std = @import("std");
const lanes = 32;
const Row = @Vector(lanes, u16);
pub fn encode(comptime cells: usize, values: *const [cells]u16, count: usize, writer: *std.Io.Writer) !void {
    std.debug.assert(count > 0 and count <= cells);
    const bits: usize = std.math.log2_int_ceil(usize, count);
    const bytes = try writer.writableSlice(bits * cells / 8);
    for (0..cells / lanes) |row| {
        const value: Row = values[row * lanes ..][0..lanes].*;
        for (0..bits) |bit| {
            const mask: Row = @splat(@as(u16, 1) << @intCast(bit));
            const present = value & mask != @as(Row, @splat(0));
            const word: u32 = @bitCast(present);
            std.mem.writeInt(u32, bytes[bit * cells / 8 + row * 4 ..][0..4], word, .little);
        }
    }
}
pub fn decode(comptime cells: usize, reader: *std.Io.Reader, output: *[cells]u16, count: usize) !void {
    std.debug.assert(count > 0 and count <= cells);
    const bits: usize = std.math.log2_int_ceil(usize, count);
    const bytes = try reader.take(bits * cells / 8);
    for (0..cells / lanes) |row| {
        var value: Row = @splat(0);
        for (0..bits) |bit| {
            const word = std.mem.readInt(u32, bytes[bit * cells / 8 + row * 4 ..][0..4], .little);
            const present: @Vector(lanes, bool) = @bitCast(word);
            value |= @select(u16, present, @as(Row, @splat(@as(u16, 1) << @intCast(bit))), @as(Row, @splat(0)));
        }
        output[row * lanes ..][0..lanes].* = value;
    }
}
