const protocol = @import("codegen.zig");
const protocol_support = @import("protocol_support.zig");
const std = @import("std");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

test {
    const input = bytes("00409a44b81e634200409a44");
    const T = protocol.vec3f;
    const expected =
        \\.{ .x = 1234, .y = 56.78, .z = 1234 }
    ;

    var reader = protocol_support.Reader{ .buffer = &input };
    var actual: T = undefined;
    try actual.read(&reader, std.testing.allocator);
    try std.testing.expectFmt(expected, "{any}", .{actual});
}
