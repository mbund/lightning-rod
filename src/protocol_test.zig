const protocol = @import("protocol");
const std = @import("std");

fn bytes(comptime hex: []const u8) [hex.len / 2]u8 {
    comptime var result = std.mem.zeroes([hex.len / 2]u8);
    _ = comptime std.fmt.hexToBytes(&result, hex) catch @compileError("invalid hex: " ++ hex);
    return result;
}

test "reading integer from random bytes" {
    const buffer = &bytes("00409a44b81e634200409a44");
    const int, const rest = try protocol.protocol_support.read_int(buffer, u32);

    try std.testing.expectEqual(0x00409a44, int);
    try std.testing.expectEqualSlices(u8, rest, &bytes("b81e634200409a44"));
}

test "handshaking set_protocol" {
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

test "status ping" {
    const buffer = &bytes("01000000000000158b");
    const c1 = protocol.status.toServer.read(buffer);
    switch (try c1.name()) {
        .ping => |c2| {
            const timestamp, const c3 = try c2.time();
            try c3.finish();

            try std.testing.expectEqual(5515, timestamp);
        },
        .ping_start => {
            return error.No;
        },
        .default => {
            return error.No;
        },
    }
}

test "login login_start" {
    const buffer = &bytes("000a77617270636f726530351a13faa879e54c248997b6dd9b14e23d");
    const c1 = protocol.login.toServer.read(buffer);
    switch (try c1.name()) {
        .login_start => |c2| {
            const username, const c3 = try c2.username();
            const uuid, const c4 = try c3.playerUUID();
            try c4.finish();

            try std.testing.expectEqualStrings("warpcore05", username);
            try std.testing.expectEqual(34663665481177079509380347836620923453, uuid);
        },
        else => return error.No,
    }
}
