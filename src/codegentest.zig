const std = @import("std");
const builtin = @import("builtin");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

pub fn read_f32(data: []const u8) !struct { value: f32, remaining: []const u8 } {
    const size = 4;
    const value: f32 = @bitCast(std.mem.readInt(u32, data[0..size], builtin.cpu.arch.endian()));
    const remaining = data[size..];
    return .{ .value = value, .remaining = remaining };
}

const Cursor0 = struct {
    data: []const u8,

    pub fn next(self: @This()) !Cursor1 {
        const read = try read_f32(self.data);
        return Cursor1{
            .data = read.remaining,
            .x = read.value,
        };
    }
};

const Cursor1 = struct {
    x: f32,
    data: []const u8,

    pub fn next(self: @This()) !Cursor1 {
        const read = try read_f32(self.data);
        return Cursor1{
            .data = read.remaining,
            .x = read.value,
        };
    }
};

test {
    const input = bytes("00409a44b81e634200409a44");
    const c0 = Cursor0{ .data = &input };

    const c1 = try c0.next();
    try std.testing.expectEqual(1234, c1.x);

    // const T = protocol.vec3f;
    // const expected =
    //     \\.{ .x = 1234, .y = 56.78, .z = 1234 }
    // ;

    // var reader = protocol_support.Reader{ .buffer = &input };
    // var actual: T = undefined;
    // try actual.read(&reader, std.testing.allocator);
    // try std.testing.expectFmt(expected, "{any}", .{actual});
}
