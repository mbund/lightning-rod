const protocol_support = @import("protocol_support.zig");
const std = @import("std");
const builtin = @import("builtin");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

test {
    const buffer = &bytes("00409a44b81e634200409a44");
    const int, const rest = try protocol_support.read_int(buffer, u32);

    try std.testing.expectEqual(0x449a4000, int);
    try std.testing.expectEqualSlices(u8, rest, &bytes("b81e634200409a44"));
}
