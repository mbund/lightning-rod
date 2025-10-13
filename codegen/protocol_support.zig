const std = @import("std");
const builtin = @import("builtin");

pub const SEGMENT_BITS = 0x7F;
pub const CONTINUE_BIT = 0x80;

pub fn read_int(buffer: []const u8, comptime T: type) !struct { T, []const u8 } {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    const value = std.mem.readInt(T, buffer[0..size], .big);
    const rest = buffer[size..];
    return .{ value, rest };
}

pub fn read_varint(buffer: []const u8) !struct { i32, []const u8 } {
    var value: i32 = 0;
    var rest = buffer;

    for (0..5) |i| {
        const b = @as(i32, rest[0]);
        rest = rest[1..];
        value |= (b & SEGMENT_BITS) << (@as(u5, @intCast(i)) * 7);
        if (b & CONTINUE_BIT == 0) return .{ value, rest };
    }

    return .{ value, rest };
}

pub fn read_u8(buffer: []const u8) !struct { u8, []const u8 } {
    return read_int(buffer, u8);
}

pub fn read_u16(buffer: []const u8) !struct { u16, []const u8 } {
    return read_int(buffer, u16);
}

pub fn read_u32(buffer: []const u8) !struct { u32, []const u8 } {
    return read_int(buffer, u32);
}

pub fn read_u64(buffer: []const u8) !struct { u64, []const u8 } {
    return read_int(buffer, u64);
}

pub fn read_i8(buffer: []const u8) !struct { i8, []const u8 } {
    return read_int(buffer, i8);
}

pub fn read_i16(buffer: []const u8) !struct { i16, []const u8 } {
    return read_int(buffer, i16);
}

pub fn read_i32(buffer: []const u8) !struct { i32, []const u8 } {
    return read_int(buffer, i32);
}

pub fn read_i64(buffer: []const u8) !struct { i64, []const u8 } {
    return read_int(buffer, i64);
}

pub const FinalCursor = struct {
    buffer: []const u8,

    pub fn finish(self: FinalCursor) !void {
        if (self.buffer.len != 0) {
            return error.TooLong;
        }
    }
};
//
// pub fn read_f32(self: *Reader, out: *f32) !void {
//     const size = 4;
//     out.* = @bitCast(std.mem.readInt(u32, self.buffer[0..size], builtin.cpu.arch.endian()));
//     self.buffer = self.buffer[size..];
// }
// pub fn read_f64(self: *Reader, out: *f64) !void {
//     const size = 8;
//     out.* = @bitCast(std.mem.readInt(u64, self.buffer[0..size], builtin.cpu.arch.endian()));
//     self.buffer = self.buffer[size..];
// }
