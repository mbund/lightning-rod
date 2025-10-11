const std = @import("std");
const builtin = @import("builtin");

pub fn read_int(buffer: []const u8, comptime T: type) !struct { T, []const u8 } {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    const value = std.mem.readInt(T, buffer[0..size], .little);
    const rest = buffer[size..];
    return .{ value, rest };
}
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
