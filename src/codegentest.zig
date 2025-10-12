const protocol_support = @import("protocol_support.zig");
const protocol = @import("codegen.zig");
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

    try std.testing.expectEqual(0x00409a44, int);
    try std.testing.expectEqualSlices(u8, rest, &bytes("b81e634200409a44"));
}

test {
    const buffer = &bytes("008406093132372e302e302e3163dd01");
    const c1 = protocol.handshaking.toServer.read(buffer);
    switch (try c1.name()) {
        .set_protocol => |c2| {
            const version, const c3 = try c2.protocolVersion();
            const host, const c4 = try c3.serverHost();
            const port, const c5 = try c4.serverPort();
            const nextState, const c6 = try c5.nextState();
            try c6.finish();

            try std.testing.expectEqual(772, version);
            try std.testing.expectEqualSlices(u8, "127.0.0.1", host);
            try std.testing.expectEqual(25565, port);
            try std.testing.expectEqual(1, nextState);
        },
        .legacy_server_list_ping => |_| {
            return error.No;
        },
        .default => |_| {
            return error.No;
        },
    }
}
