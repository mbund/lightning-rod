const PartitionedTransport = @import("transport.zig").Transport;
const std = @import("std");
const network = @import("networking");
const SocketTransport = @import("transport_ring.zig").Ring;

test "transport capacity follows configuration beyond 256 players" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    try std.testing.expectError(error.InvalidSessionCapacity, SocketTransport.init(std.testing.allocator, io, .{ .address = address, .connections = 0 }));
    try std.testing.expectError(error.InvalidSessionCapacity, SocketTransport.init(std.testing.allocator, io, .{ .address = address, .connections = 65537 }));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var transport = try SocketTransport.init(failing.allocator(), io, .{ .address = address, .connections = 512 });
    defer transport.deinit(io);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectEqual(@as(usize, 512), transport.connections.len);
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &sockets)));
    defer _ = std.os.linux.close(sockets[1]);
    _ = try transport.adopt(sockets[0]);
    try std.testing.expectError(error.InvalidDescriptor, transport.adopt(sockets[0]));
}

test "notifications before polling wake an indefinite wait" {
    const io = std.testing.io;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 2, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    var events: [16]network.Event = undefined;
    for (0..3) |_| {
        for (0..100) |_| transport.notify(io);
        try std.testing.expectEqual(@as(usize, 0), try transport.poll(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(1) } }, &events));
        try std.testing.expectEqual(@as(u64, 1), std.mem.bytesToValue(u64, &transport.wake_bytes));
        try std.testing.expect(!transport.wake_notified.load(.acquire));
    }
}

test "owner socket operations return every loan before descriptor handoff" {
    try pauseAndResume(std.testing.io);
}

fn pauseAndResume(io: std.Io) !void {
    for ([_]bool{ false, true }) |submitted| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
        defer _ = std.os.linux.close(sockets[1]);
        const capacity: c_int = 4096;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity), @sizeOf(c_int))));
        var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 2, .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } } });
        defer transport.deinit(io);
        const handle = try transport.adopt(sockets[0]);
        try std.testing.expectError(error.InvalidDescriptor, transport.adopt(transport.listenerDescriptor()));
        try std.testing.expectError(error.InvalidDescriptor, transport.adopt(sockets[0]));
        const descriptor_flags = std.posix.system.fcntl(sockets[0], std.posix.F.GETFD, @as(usize, 0));
        try std.testing.expectEqual(.SUCCESS, std.posix.errno(descriptor_flags));
        try std.testing.expect(descriptor_flags & std.posix.FD_CLOEXEC != 0);
        var input: [32]u8 = undefined;
        var output: [256 * 1024]u8 = @splat(23);
        try transport.queueReceive(io, handle, &input);
        try transport.queueSend(io, handle, &.{.{ .base = &output, .len = output.len }});
        if (submitted) {
            try transport.submit(io);
        }
        transport.pause(io, true);
        var receives: usize = 0;
        var sends: usize = 0;
        var sent: usize = 0;
        var events: [16]network.Event = undefined;
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(2) });
        while (!transport.paused()) {
            const count = try transport.poll(io, .{ .deadline = deadline }, &events);
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
        try std.testing.expect(sent < output.len);
        try std.testing.expectEqual(sockets[0], transport.descriptor(handle));
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
        transport.pause(io, false);
        try transport.queueReceive(io, handle, &input);
        try std.testing.expectEqual(@as(usize, 6), std.os.linux.write(sockets[1], "resume", 6));
        try transport.submit(io);
        var received = false;
        while (!received) {
            const count = try transport.poll(io, .{ .deadline = deadline }, &events);
            for (events[0..count]) |event| switch (event) {
                .received => |completion| {
                    try std.testing.expectEqual(@as(?i32, null), completion.result.errno);
                    try std.testing.expectEqualStrings("resume", input[0..completion.result.bytes]);
                    received = true;
                },
                else => return error.UnexpectedConnectionEvent,
            };
        }
        // Engine shutdown may repeat close until its queued notification is read.
        transport.close(io, handle, .local_close);
        transport.close(io, handle, .local_close);
        try transport.submit(io);
        transport.close(io, handle, .local_close);
        try transport.submit(io);
        var closed = false;
        while (!closed) {
            const count = try transport.poll(io, .{ .deadline = deadline }, &events);
            for (events[0..count]) |event| switch (event) {
                .received => |completion| {
                    try std.testing.expect(!completion.result.more);
                    try std.testing.expectEqual(@as(?i32, @intFromEnum(std.posix.E.CANCELED)), completion.result.errno);
                },
                .closed => closed = true,
                else => return error.UnexpectedConnectionEvent,
            };
        }
        // A new socket may reuse the descriptor before the engine releases the
        // old closed handle. Only live descriptor ownership prevents adoption.
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.dup3(sockets[1], sockets[0], 0)));
        const replacement = try transport.adopt(sockets[0]);
        try std.testing.expect(replacement.index != handle.index);
        transport.releaseConnection(io, handle);
    }
}

test "handoff preserves a successful kernel completion before transport collection" {
    const io = std.testing.io;
    const Direction = enum { receive, send };
    for ([_]Direction{ .receive, .send }) |direction| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
        defer _ = std.os.linux.close(sockets[1]);
        const capacity: c_int = 4096;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.setsockopt(sockets[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, std.mem.asBytes(&capacity), @sizeOf(c_int))));
        var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 2, .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } } });
        defer transport.deinit(io);
        transport.accepting = false;
        const handle = try transport.adopt(sockets[0]);
        var input: [32]u8 = undefined;
        var output: [16 * 1024]u8 = @splat(23);
        var fill: [4096]u8 = @splat(7);
        var filled: usize = 0;
        if (direction == .send) {
            while (true) {
                const count = std.os.linux.sendto(sockets[0], &fill, fill.len, std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL, null, 0);
                switch (std.os.linux.errno(count)) {
                    .SUCCESS => filled += count,
                    .AGAIN => break,
                    .INTR => continue,
                    else => return error.FillSocket,
                }
            }
            try transport.queueSend(io, handle, &.{.{ .base = &output, .len = output.len }});
        } else try transport.queueReceive(io, handle, &input);
        try transport.submit(io);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(2) });
        if (direction == .receive) {
            try std.testing.expectEqual(@as(usize, 12), std.os.linux.write(sockets[1], "handoff-recv", 12));
        } else {
            var remaining = filled;
            while (remaining != 0) {
                const count = std.os.linux.recvfrom(sockets[1], &fill, @min(fill.len, remaining), std.posix.MSG.DONTWAIT, null, null);
                if (std.os.linux.errno(count) == .INTR) continue;
                try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(count));
                try std.testing.expect(count != 0);
                remaining -= count;
            }
        }
        var descriptors = [_]std.posix.pollfd{.{ .fd = transport.ring.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        try std.testing.expectEqual(@as(usize, 1), std.os.linux.poll(&descriptors, descriptors.len, 2000));
        try std.testing.expect(transport.ring.cq_ready() != 0);
        transport.pause(io, true);
        var events: [16]network.Event = undefined;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        try std.testing.expectEqual(@as(usize, 1), count);
        const completion = switch (events[0]) {
            .received, .sent => |value| value,
            else => return error.UnexpectedConnectionEvent,
        };
        try std.testing.expectEqual(@as(?i32, null), completion.result.errno);
        try std.testing.expect(completion.result.bytes > 0);
        if (direction == .receive) {
            try std.testing.expectEqualStrings("handoff-recv", input[0..completion.result.bytes]);
        } else {
            var observed: usize = 0;
            while (true) {
                const received = std.os.linux.recvfrom(sockets[1], &fill, fill.len, std.posix.MSG.DONTWAIT, null, null);
                switch (std.os.linux.errno(received)) {
                    .SUCCESS => {},
                    .AGAIN => break,
                    .INTR => continue,
                    else => return error.ReadSocket,
                }
                try std.testing.expect(received != 0);
                try std.testing.expect(std.mem.allEqual(u8, fill[0..received], 23));
                observed += received;
            }
            try std.testing.expectEqual(completion.result.bytes, observed);
        }
    }
}

test "vectored send retains descriptor and payload addresses and preserves their order" {
    const io = std.testing.io;
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
    defer _ = std.os.linux.close(sockets[1]);
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 1, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    const handle = try transport.adopt(sockets[0]);
    const first = "first";
    const second = "second";
    const vectors = [_]std.posix.iovec_const{
        .{ .base = first.ptr, .len = first.len },
        .{ .base = second.ptr, .len = second.len },
    };
    try transport.queueSend(io, handle, &vectors);
    const operation = &transport.operations[transport.connections[handle.index].send.?];
    try std.testing.expect(operation.message.iov == vectors[0..].ptr);
    try std.testing.expect(operation.message.iov[0].base == first.ptr);
    try std.testing.expect(operation.message.iov[1].base == second.ptr);
    try transport.submit(io);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(2) });
    var events: [4]network.Event = undefined;
    const count = try transport.poll(io, .{ .deadline = deadline }, &events);
    try std.testing.expectEqual(@as(usize, 1), count);
    const completion = events[0].sent;
    try std.testing.expectEqual(@as(?i32, null), completion.result.errno);
    try std.testing.expectEqual(first.len + second.len, completion.result.bytes);
    var received: [11]u8 = undefined;
    const length = std.os.linux.read(sockets[1], &received, received.len);
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(length));
    try std.testing.expectEqualStrings("firstsecond", received[0..length]);
}

test "ready completions do not postpone submission of prepared operations" {
    const io = std.testing.io;
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
    defer _ = std.os.linux.close(sockets[1]);
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 1, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    const handle = try transport.adopt(sockets[0]);
    const vectors = [_]std.posix.iovec_const{.{ .base = "ready".ptr, .len = 5 }};
    try transport.queueSend(io, handle, &vectors);
    try transport.submit(io);
    _ = try transport.ring.submit_and_wait(1);
    var input: [16]u8 = undefined;
    try transport.queueReceive(io, handle, &input);
    var events: [4]network.Event = undefined;
    const count = try transport.poll(io, null, &events);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 5), events[0].sent.result.bytes);
    try std.testing.expect(transport.operations[transport.connections[handle.index].recv.?].submitted);
}

test "fatal transport cleanup cancels submitted loans without polling" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |submitted| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
        defer _ = std.os.linux.close(sockets[1]);
        var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 2, .address = .{ .ip4 = .loopback(0) } });
        defer transport.deinit(io);
        const handle = try transport.adopt(sockets[0]);
        var input: [32]u8 = @splat(0);
        var output: [256 * 1024]u8 = @splat(7);
        try transport.queueReceive(io, handle, &input);
        try transport.queueSend(io, handle, &.{.{ .base = &output, .len = output.len }});
        if (submitted) try transport.submit(io);
        transport.abort();
        @memset(&input, 23);
        @memset(&output, 42);
        try std.testing.expect(transport.aborted);
    }
}

test "accepted sockets inherit the listener batching policy" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 2, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    var address: std.posix.sockaddr.in = undefined;
    var address_size: std.posix.socklen_t = @sizeOf(@TypeOf(address));
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.getsockname(transport.listenerDescriptor(), @ptrCast(&address), &address_size)));
    const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(.SUCCESS, linux.errno(raw));
    const fd: std.posix.fd_t = @intCast(raw);
    defer _ = linux.close(fd);
    const result = linux.errno(linux.connect(fd, @ptrCast(&address), address_size));
    try std.testing.expect(result == .SUCCESS or result == .INPROGRESS);
    var events: [8]network.Event = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    var accepted: ?network.Handle = null;
    while (accepted == null) {
        if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| switch (event) {
            .accepted => |handle| accepted = handle,
            else => return error.UnexpectedEvent,
        };
    }
    var enabled: c_int = 0;
    var size: std.posix.socklen_t = @sizeOf(c_int);
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.getsockopt(transport.descriptor(accepted.?), linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&enabled), &size)));
    try std.testing.expectEqual(@as(c_int, 1), enabled);
}

test "a small submission ring progresses past continuously rearmed peers" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 12, .ring_entries = 4, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    var peers: [12]std.posix.fd_t = undefined;
    var handles: [12]network.Handle = undefined;
    var bytes: [12][1]u8 = undefined;
    var initialized: usize = 0;
    defer for (peers[0..initialized]) |peer| {
        _ = linux.close(peer);
    };
    defer transport.abort();
    for (&peers, &handles, &bytes) |*peer, *handle, *buffer| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sockets)));
        peer.* = sockets[1];
        initialized += 1;
        handle.* = transport.adopt(sockets[0]) catch |err| {
            _ = linux.close(sockets[0]);
            return err;
        };
        try transport.queueReceive(io, handle.*, buffer);
        try std.testing.expectEqual(@as(usize, 1), linux.write(peer.*, "x", 1));
    }
    var seen: [12]bool = @splat(false);
    var events: [32]network.Event = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    while (!std.mem.allEqual(bool, &seen, true)) {
        if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| switch (event) {
            .received => |received| {
                const index = received.handle.index;
                if (received.result.errno) |errno| {
                    try std.testing.expectEqual(@as(i32, @intFromEnum(linux.E.NOBUFS)), errno);
                    try std.testing.expect(!received.result.more);
                } else {
                    try std.testing.expectEqual(@as(usize, 1), received.result.bytes);
                    seen[index] = true;
                }
                if (index < 4 and !received.result.more) {
                    try transport.queueReceive(io, handles[index], &bytes[index]);
                    try std.testing.expectEqual(@as(usize, 1), linux.write(peers[index], "x", 1));
                }
            },
            else => return error.UnexpectedEvent,
        };
    }
}

test "inherited listeners are validated before ownership and memory are acquired" {
    const io = std.testing.io;
    const raw = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(raw));
    const file: std.Io.File = .{ .handle = @intCast(raw), .flags = .{ .nonblocking = false } };
    defer file.close(io);
    try std.testing.expectError(error.InvalidListener, SocketTransport.init(std.testing.failing_allocator, io, .{
        .address = .{ .ip4 = .loopback(0) },
        .connections = 1,
        .inherited_listener = file.handle,
    }));
    var size: std.posix.socklen_t = @sizeOf(c_int);
    var kind: c_int = 0;
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.getsockopt(file.handle, std.os.linux.SOL.SOCKET, std.os.linux.SO.TYPE, std.mem.asBytes(&kind), &size)));
    try std.testing.expectEqual(std.os.linux.SOCK.STREAM, kind);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener: ?std.Io.net.Server = try address.listen(io, .{});
    defer if (listener) |*reserved| reserved.deinit(io);
    const fd = listener.?.socket.handle;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .address = address, .connections = 1, .inherited_listener = fd });
    listener = null;
    defer transport.deinit(io);
    try std.testing.expectEqual(fd, transport.listenerDescriptor());
}

test "a small submission ring drains a larger batch without losing canceled loans" {
    const io = std.testing.io;
    const count = 8;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = count, .ring_entries = 4, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    var peers: [count]std.posix.fd_t = @splat(-1);
    defer for (peers) |peer| if (peer >= 0) {
        _ = std.os.linux.close(peer);
    };
    var input: [count][1]u8 = undefined;
    var vectors: [count]std.posix.iovec_const = undefined;
    var handles: [count]network.Handle = undefined;
    const output = "x";
    for (&peers, &input, &vectors, &handles, 0..) |*peer, *bytes, *vector, *handle, index| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM | std.os.linux.SOCK.NONBLOCK | std.os.linux.SOCK.CLOEXEC, 0, &sockets)));
        peer.* = sockets[1];
        handle.* = try transport.adopt(sockets[0]);
        vector.* = .{ .base = output.ptr, .len = output.len };
        try transport.queueReceive(io, handle.*, bytes);
        try transport.queueSend(io, handle.*, vectors[index..][0..1]);
    }
    try transport.submit(io);
    transport.pause(io, true);
    var received: [count]bool = @splat(false);
    var sent: [count]bool = @splat(false);
    var events: [count * 2]network.Event = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(2) });
    while (!transport.paused()) {
        const ready = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..ready]) |event| switch (event) {
            .received => |completion| {
                try std.testing.expect(!received[completion.handle.index]);
                received[completion.handle.index] = true;
            },
            .sent => |completion| {
                try std.testing.expect(!sent[completion.handle.index]);
                sent[completion.handle.index] = true;
            },
            else => return error.UnexpectedEvent,
        };
    }
    for (received, sent, handles) |read, write, handle| {
        try std.testing.expect(read and write);
        try std.testing.expect(transport.descriptor(handle) >= 0);
    }
}

test "multishot receives append without rearming and return the span on exhaustion" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var sockets: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sockets)));
    defer _ = linux.close(sockets[1]);
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 1, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    defer transport.abort();
    transport.accepting = false;
    const handle = try transport.adopt(sockets[0]);
    var input: [8]u8 = @splat(0);
    var events: [8]network.Event = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
    try transport.queueReceive(io, handle, &input);
    try transport.submit(io);
    const submitted = transport.ring.sq.sqe_tail;
    var ended = false;
    for (0..input.len) |index| {
        const byte: u8 = @intCast(index + 1);
        try std.testing.expectEqual(@as(usize, 1), linux.write(sockets[1], &.{byte}, 1));
        var received = false;
        while (!received) {
            if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
            const count = try transport.poll(io, .{ .deadline = deadline }, &events);
            for (events[0..count]) |event| {
                try std.testing.expect(event == .received);
                const result = event.received.result;
                if (result.errno) |errno| {
                    try std.testing.expectEqual(@as(i32, @intFromEnum(linux.E.NOBUFS)), errno);
                    try std.testing.expect(!result.more);
                    try std.testing.expectEqual(input.len - 1, index);
                    ended = true;
                } else {
                    try std.testing.expectEqual(@as(usize, 1), result.bytes);
                    try std.testing.expectEqual(byte, input[index]);
                    received = true;
                    ended = !result.more;
                }
            }
        }
        try std.testing.expectEqual(submitted, transport.ring.sq.sqe_tail);
        for (input[0 .. index + 1], 0..) |value, prefix| try std.testing.expectEqual(@as(u8, @intCast(prefix + 1)), value);
    }
    try std.testing.expectEqual(@as(usize, 1), linux.write(sockets[1], "z", 1));
    while (!ended) {
        if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| {
            try std.testing.expect(event == .received);
            try std.testing.expectEqual(@as(?i32, @intFromEnum(linux.E.NOBUFS)), event.received.result.errno);
            try std.testing.expect(!event.received.result.more);
            ended = true;
        }
    }
    var next: [8]u8 = @splat(0);
    try transport.queueReceive(io, handle, &next);
    var received = false;
    while (!received) {
        if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| {
            try std.testing.expect(event == .received);
            try std.testing.expectEqual(@as(?i32, null), event.received.result.errno);
            try std.testing.expectEqual(@as(usize, 1), event.received.result.bytes);
            try std.testing.expectEqual(@as(u8, 'z'), next[0]);
            received = true;
        }
    }
    try std.testing.expectEqual(submitted + 1, transport.ring.sq.sqe_tail);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &input);
}

test "one multishot accept submission admits several connections" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var transport = try SocketTransport.init(std.testing.allocator, io, .{ .connections = 4, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(io);
    defer transport.abort();
    var address: std.posix.sockaddr.in = undefined;
    var address_size: std.posix.socklen_t = @sizeOf(@TypeOf(address));
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.getsockname(transport.listenerDescriptor(), @ptrCast(&address), &address_size)));
    try transport.submit(io);
    const submitted = transport.ring.sq.sqe_tail;
    for (0..3) |index| {
        const raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        try std.testing.expectEqual(.SUCCESS, linux.errno(raw));
        const fd: std.posix.fd_t = @intCast(raw);
        defer _ = linux.close(fd);
        const result = linux.errno(linux.connect(fd, @ptrCast(&address), address_size));
        try std.testing.expect(result == .SUCCESS or result == .INPROGRESS);
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(5) });
        var events: [8]network.Event = undefined;
        var accepted = false;
        while (!accepted) {
            if (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
            const count = try transport.poll(io, .{ .deadline = deadline }, &events);
            for (events[0..count]) |event| {
                try std.testing.expect(event == .accepted);
                try std.testing.expectEqual(index, event.accepted.index);
                accepted = true;
            }
        }
        try std.testing.expect(transport.accept_pending);
        try std.testing.expectEqual(submitted, transport.ring.sq.sqe_tail);
    }
}

test "partitioned transport preserves global handles across receive send and pause" {
    const linux = std.os.linux;
    const io = std.testing.io;
    var transport = try PartitionedTransport.init(std.testing.allocator, io, .{ .address = .{ .ip4 = .loopback(0) }, .connections = 4, .connections_per_ring = 2 });
    defer transport.deinit(io);
    var peers: [4]std.posix.fd_t = undefined;
    var handles: [4]network.Handle = undefined;
    var buffers: [4][16]u8 = undefined;
    var initialized: usize = 0;
    defer for (peers[0..initialized]) |peer| {
        _ = linux.close(peer);
    };
    defer transport.abort();
    for (&peers, &handles, &buffers, 0..) |*peer, *handle, *buffer, index| {
        var sockets: [2]std.posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sockets)));
        peer.* = sockets[1];
        initialized += 1;
        handle.* = transport.adopt(sockets[0]) catch |err| {
            _ = linux.close(sockets[0]);
            return err;
        };
        try std.testing.expectEqual(index, handle.index);
        try std.testing.expectError(error.InvalidDescriptor, transport.adopt(sockets[0]));
        try transport.queueReceive(io, handle.*, buffer);
        const byte = [_]u8{@intCast(index + 1)};
        try std.testing.expectEqual(@as(usize, 1), linux.write(peer.*, &byte, 1));
    }
    try transport.submit(io);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromSeconds(2) });
    var received: [4]bool = @splat(false);
    var received_count: usize = 0;
    var events: [1]network.Event = undefined;
    while (received_count < received.len) {
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| switch (event) {
            .received => |completion| {
                const index = completion.handle.index;
                try std.testing.expect(std.meta.eql(handles[index], completion.handle));
                try std.testing.expectEqual(@as(usize, 1), completion.result.bytes);
                try std.testing.expect(!received[index]);
                try std.testing.expectEqual(@as(u8, @intCast(index + 1)), buffers[index][0]);
                received[index] = true;
                received_count += 1;
            },
            else => return error.UnexpectedConnectionEvent,
        };
    }
    var bytes = [_]u8{ 5, 6, 7, 8 };
    var vectors: [4][1]std.posix.iovec_const = undefined;
    for (handles, &vectors, 0..) |handle, *vector, index| {
        vector[0] = .{ .base = bytes[index..].ptr, .len = 1 };
        try transport.queueSend(io, handle, vector);
    }
    try transport.submit(io);
    var sent: [4]bool = @splat(false);
    var sent_count: usize = 0;
    while (sent_count < sent.len) {
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        const count = try transport.poll(io, .{ .deadline = deadline }, &events);
        for (events[0..count]) |event| switch (event) {
            .sent => |completion| {
                const index = completion.handle.index;
                try std.testing.expect(std.meta.eql(handles[index], completion.handle));
                try std.testing.expectEqual(@as(usize, 1), completion.result.bytes);
                try std.testing.expect(!sent[index]);
                var byte: [1]u8 = undefined;
                try std.testing.expectEqual(@as(usize, 1), linux.read(peers[index], &byte, 1));
                try std.testing.expectEqual(bytes[index], byte[0]);
                sent[index] = true;
                sent_count += 1;
            },
            else => return error.UnexpectedConnectionEvent,
        };
    }
    transport.pause(io, true);
    while (!transport.paused()) {
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline.raw.nanoseconds) return error.Timeout;
        _ = try transport.poll(io, .{ .deadline = deadline }, &events);
    }
    for (handles) |handle| try std.testing.expect(transport.descriptor(handle) >= 0);
}
