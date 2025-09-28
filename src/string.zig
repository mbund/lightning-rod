const std = @import("std");
const VarInt = @import("varint.zig").VarInt;

pub const String = struct {
    pub fn read(reader: *std.Io.Reader) ![]const u8 {
        const size = try VarInt.read(reader);
        std.debug.print("size: {}\n", .{size});
        const s = try reader.take(@intCast(size));

        return s;
    }

    pub fn write(writer: *std.Io.Writer, value: []const u8) !usize {
        std.debug.print("wr: {s}\n", .{value});
        var total = try VarInt.write(writer, @intCast(value.len));
        try writer.writeAll(value);
        total += value.len;
        return total;
    }
};
