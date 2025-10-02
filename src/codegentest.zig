const protocol = @import("codegen.zig");
const std = @import("std");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

test {
    const actual = @sizeOf(protocol.vec3f);
    try std.testing.expectEqual(12, actual);
}
