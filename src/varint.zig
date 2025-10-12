const std = @import("std");

pub const SEGMENT_BITS = 0x7F;
pub const CONTINUE_BIT = 0x80;

pub const VarInt = struct {
    pub fn read(reader: *std.Io.Reader) !i32 {
        var value: i32 = 0;

        for (0..5) |i| {
            const b = @as(i32, try reader.takeByte());
            value |= (b & SEGMENT_BITS) << (@as(u5, @intCast(i)) * 7);
            if (b & CONTINUE_BIT == 0) return value;
        }

        return error.TooManyBytes;
    }

    pub fn write(writer: *std.Io.Writer, value: i32) !usize {
        var v = value;
        for (0..5) |i| {
            if ((v & ~@as(i32, SEGMENT_BITS)) == 0) {
                try writer.writeByte(@intCast(v));
                return i + 1;
            }

            try writer.writeByte(@intCast((v & SEGMENT_BITS) | CONTINUE_BIT));

            v >>= 7;
        }

        unreachable;
    }
};

test {
    const buf = &[_]u8{16};
    var stream = std.io.Reader.fixed(buf);
    const actual = try VarInt.read(&stream);
    try std.testing.expectEqual(16, actual);
}

test {
    const buf = &[_]u8{ 254, 1 };
    var stream = std.io.Reader.fixed(buf);
    const actual = try VarInt.read(&stream);
    try std.testing.expectEqual(254, actual);
}

test {
    const buf = &[_]u8{ 254, 2 };
    var stream = std.io.Reader.fixed(buf);
    const actual = try VarInt.read(&stream);
    try std.testing.expectEqual(382, actual);
}

test {
    const buf = &[_]u8{ 128, 128, 128, 128, 8 };
    var stream = std.io.Reader.fixed(buf);
    const actual = try VarInt.read(&stream);
    try std.testing.expectEqual(-2147483648, actual);
}

test {
    const buf = &[_]u8{ 128, 128, 128, 128, 128, 8 };
    var stream = std.io.Reader.fixed(buf);
    const actual = VarInt.read(&stream);
    try std.testing.expectError(error.TooManyBytes, actual);
}

test {
    const buf = &[_]u8{ 132, 6 };
    var stream = std.io.Reader.fixed(buf);
    const actual = try VarInt.read(&stream);
    try std.testing.expectEqual(772, actual);
}
