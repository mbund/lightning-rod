const std = @import("std");
const builtin = @import("builtin");

pub fn maybe_unused(x: anytype) void {
    _ = x;
}

pub const Reader = struct {
    buffer: []const u8,

    pub fn read_int(self: *Reader, comptime T: type, out: *T) !void {
        const size = @divExact(@typeInfo(T).int.bits, 8);
        out.* = std.mem.readInt(T, self.buffer[0..size], .little);
        self.buffer = self.buffer[size..];
    }

    pub fn read_u8(self: *Reader, out: *u8) !void {
        try self.read_int(u8, out);
    }
    pub fn read_u16(self: *Reader, out: *u16) !void {
        try self.read_int(u16, out);
    }
    pub fn read_u32(self: *Reader, out: *u32) !void {
        try self.read_int(u32, out);
    }
    pub fn read_u64(self: *Reader, out: *u64) !void {
        try self.read_int(u64, out);
    }
    pub fn read_i8(self: *Reader, out: *i8) !void {
        try self.read_int(i8, out);
    }
    pub fn read_i16(self: *Reader, out: *i16) !void {
        try self.read_int(i16, out);
    }
    pub fn read_i32(self: *Reader, out: *i32) !void {
        try self.read_int(i32, out);
    }
    pub fn read_i64(self: *Reader, out: *i64) !void {
        try self.read_int(i64, out);
    }
    // pub fn read_bool(self: *Reader, out: *bool) !void {
    //     try self.read(bool, out);
    // }
    pub fn read_f32(self: *Reader, out: *f32) !void {
        const size = 4;
        out.* = @bitCast(std.mem.readInt(u32, self.buffer[0..size], builtin.cpu.arch.endian()));
        self.buffer = self.buffer[size..];
    }
    pub fn read_f64(self: *Reader, out: *f64) !void {
        const size = 8;
        out.* = @bitCast(std.mem.readInt(u64, self.buffer[0..size], builtin.cpu.arch.endian()));
        self.buffer = self.buffer[size..];
    }
};
