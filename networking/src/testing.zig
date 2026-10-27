const std = @import("std");
const builtin = @import("builtin");
const network = @import("networking");

pub fn pause(comptime Transport: type) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |submit| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
        defer _ = std.os.linux.close(sockets[1]);
        const capacity: c_int = 4096;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity), @sizeOf(c_int))));
        var transport = try Transport.init(io, .{ .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } } });
        defer transport.deinit(io);
        const handle = try transport.adopt(sockets[0]);
        const native = transport.transport().inheritance.?;
        var input: [32]u8 = undefined;
        var output: [256 * 1024]u8 = @splat(23);
        try transport.queueReceive(io, handle, &input);
        try transport.queueSend(io, handle, &.{.{ .base = &output, .len = output.len }});
        if (submit) try transport.submit(io);
        native.pause(io, true);
        const deadline = std.Io.Clock.now(.awake, io).addDuration(.fromSeconds(2));
        var receives: usize = 0;
        var sends: usize = 0;
        var sent: usize = 0;
        var events: [16]network.Event = undefined;
        while (!native.ready()) {
            try std.testing.expect(std.Io.Clock.now(.awake, io).nanoseconds < deadline.nanoseconds);
            const count = try transport.poll(io, .{ .deadline = .{ .clock = .awake, .raw = deadline } }, &events);
            for (events[0..count]) |event| switch (event) {
                .received => |completion| {
                    receives += 1;
                    try std.testing.expectEqual(@as(?i32, @intFromEnum(std.posix.E.CANCELED)), completion.result.errno);
                },
                .sent => |completion| {
                    sends += 1;
                    sent += completion.result.bytes;
                    if (completion.result.errno) |err| try std.testing.expectEqual(@intFromEnum(std.posix.E.CANCELED), err);
                },
                else => return error.UnexpectedConnectionEvent,
            };
        }
        try std.testing.expectEqual(@as(usize, 1), receives);
        try std.testing.expectEqual(@as(usize, 1), sends);
        try std.testing.expectEqual(@as(usize, 0), try transport.poll(io, null, &events));
        try std.testing.expect(sent < output.len);
        try std.testing.expectEqual(sockets[0], native.descriptor(handle));
        var observed: usize = 0;
        var bytes: [16 * 1024]u8 = undefined;
        while (true) {
            const count = std.os.linux.read(sockets[1], &bytes, bytes.len);
            switch (std.os.linux.errno(count)) {
                .AGAIN => break,
                .INTR => continue,
                .SUCCESS => {},
                else => return error.ReadFailure,
            }
            try std.testing.expect(count != 0);
            try std.testing.expect(std.mem.allEqual(u8, bytes[0..count], 23));
            observed += count;
        }
        try std.testing.expectEqual(sent, observed);
        native.pause(io, false);
        try transport.queueReceive(io, handle, &input);
        try std.testing.expectEqual(@as(usize, 6), std.os.linux.write(sockets[1], "resume", 6));
        try transport.submit(io);
        var received = false;
        while (!received) {
            try std.testing.expect(std.Io.Clock.now(.awake, io).nanoseconds < deadline.nanoseconds);
            const count = try transport.poll(io, .{ .deadline = .{ .clock = .awake, .raw = deadline } }, &events);
            for (events[0..count]) |event| switch (event) {
                .received => |completion| {
                    try std.testing.expectEqual(@as(?i32, null), completion.result.errno);
                    try std.testing.expectEqualStrings("resume", input[0..completion.result.bytes]);
                    received = true;
                },
                else => return error.UnexpectedConnectionEvent,
            };
        }
    }
}
