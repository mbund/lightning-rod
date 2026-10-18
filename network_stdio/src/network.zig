const std = @import("std");
const networking_test = @import("networking_test");
const builtin = @import("builtin");
const network = @import("networking");
const posix = std.posix;

const assert = std.debug.assert;

pub const Configuration = struct {
    address: std.Io.net.IpAddress,
    backlog: u31 = std.Io.net.default_kernel_backlog,
    inherited_listener: ?i32 = null,
};

pub fn Transport(comptime limits: network.Limits) type {
    network.validLimits(limits);
    return struct {
        const Self = @This();
        pub const capacity = limits;

        const State = enum {
            free,
            open,
            closing,
            closed,
        };

        const Kind = enum {
            receive,
            send,
        };

        const Connection = struct {
            state: State = .free,
            stream: std.Io.net.Stream = undefined,
            stream_closed: bool = false,
            generation: u32 = 0,
            receive: ?usize = null,
            send: ?usize = null,
            close: ?network.CloseReason = null,
        };

        const Operation = struct {
            used: bool = false,
            kind: Kind = .receive,
            handle: network.Handle = undefined,
            bytes: []u8 = undefined,
        };

        listener: ?std.Io.net.Server = null,
        connections: [limits.connections]Connection = @splat(.{}),
        operations: [limits.operations]Operation = @splat(.{}),
        events: [limits.events]network.Event = undefined,
        event_head: usize = 0,
        event_count: usize = 0,
        accepting: bool = true,
        wake_pipe: [2]posix.fd_t,
        notified: std.atomic.Value(bool) = .init(false),

        pub fn init(io: std.Io, configuration: Configuration) !Self {
            const address = configuration.address;
            var listener = if (builtin.os.tag == .linux and configuration.inherited_listener != null)
                std.Io.net.Server{ .socket = .{ .handle = configuration.inherited_listener.?, .address = address }, .options = {} }
            else
                try address.listen(io, .{ .kernel_backlog = configuration.backlog, .reuse_address = true });
            errdefer listener.deinit(io);
            try nonblocking(listener.socket.handle);
            var pipe: [2]posix.fd_t = undefined;
            if (posix.errno(posix.system.pipe(&pipe)) != .SUCCESS) return error.SystemResources;
            errdefer for (pipe) |fd| closeFd(fd);
            for (pipe) |fd| try nonblocking(fd);
            return .{ .listener = listener, .wake_pipe = pipe };
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            if (self.listener) |*listener| listener.deinit(io);
            for (&self.connections) |*item|
                if (item.state != .free and !item.stream_closed) item.stream.close(io);
            for (self.wake_pipe) |fd| closeFd(fd);
            self.* = undefined;
        }

        pub fn transport(self: *Self) network.Transport {
            return .{
                .context = self,
                .vtable = network.Transport.adapter(Self),
                .inheritance = if (builtin.os.tag == .linux) network.Inheritance.init(Self, self) else null,
            };
        }

        pub fn pause(self: *Self, _: std.Io, enabled: bool) void {
            self.accepting = !enabled;
            if (enabled) for (self.operations, 0..) |op, index| {
                if (!op.used) continue;
                const completion: network.Completion = .{ .handle = op.handle, .result = .{ .bytes = 0, .errno = @intFromEnum(posix.E.CANCELED) } };
                self.push(if (op.kind == .receive) .{ .received = completion } else .{ .sent = completion });
                self.release(index);
            };
        }

        pub fn paused(self: *Self) bool {
            if (self.accepting or self.event_count != 0) return false;
            for (self.operations) |op| if (op.used) return false;
            return true;
        }

        pub fn listenerDescriptor(self: *Self) i32 {
            return self.listener.?.socket.handle;
        }

        pub fn descriptor(self: *Self, handle: network.Handle) i32 {
            const item = self.connection(handle).?;
            assert(item.receive == null and item.send == null);
            return item.stream.socket.handle;
        }

        pub fn adopt(self: *Self, fd: i32) !network.Handle {
            const index = self.freeConnection() orelse return error.Full;
            assert(fd >= 0 and self.connections[index].generation == 0);
            try nonblocking(fd);
            self.connections[index] = .{
                .state = .open,
                .stream = .{ .socket = .{ .handle = fd, .address = self.listener.?.socket.address } },
                .generation = 1,
            };
            return .{ .index = @intCast(index), .generation = 1 };
        }

        pub fn queueReceive(self: *Self, io: std.Io, handle: network.Handle, bytes: []u8) network.QueueError!void {
            return self.start(io, handle, .receive, bytes);
        }

        pub fn queueSend(self: *Self, io: std.Io, handle: network.Handle, bytes: []const u8) network.QueueError!void {
            return self.start(io, handle, .send, @constCast(bytes));
        }

        pub fn close(self: *Self, _: std.Io, handle: network.Handle, reason: network.CloseReason) void {
            if (self.connection(handle)) |item| {
                item.close = reason;
                item.state = .closing;
            }
        }

        pub fn releaseConnection(self: *Self, _: std.Io, handle: network.Handle) void {
            const item = &self.connections[handle.index];
            assert(item.state == .closed and item.generation == handle.generation);
            assert(item.receive == null and item.send == null and item.stream_closed);
            item.* = .{ .generation = item.generation };
        }

        pub fn notify(self: *Self, _: std.Io) void {
            if (self.notified.swap(true, .acq_rel)) return;
            const byte = [_]u8{1};
            while (true) {
                const result = posix.system.write(self.wake_pipe[1], &byte, byte.len);
                switch (posix.errno(result)) {
                    .SUCCESS, .AGAIN => return,
                    .INTR => continue,
                    else => unreachable,
                }
            }
        }

        pub fn poll(self: *Self, io: std.Io, timeout: ?std.Io.Timeout, destination: []network.Event) !usize {
            assert(destination.len != 0);
            self.finishCloses(io);
            if (self.paused()) return 0;
            if (self.event_count == 0) {
                var fds: [limits.connections + 2]posix.pollfd = undefined;
                fds[0] = .{ .fd = if (self.accepting and self.freeConnection() != null) self.listener.?.socket.handle else -1, .events = posix.POLL.IN, .revents = 0 };
                fds[1] = .{ .fd = self.wake_pipe[0], .events = posix.POLL.IN, .revents = 0 };
                for (self.connections, fds[2..]) |item, *fd| {
                    fd.* = .{ .fd = if (item.state == .open and (item.receive != null or item.send != null)) item.stream.socket.handle else -1, .events = 0, .revents = 0 };
                    if (item.receive != null) fd.events |= posix.POLL.IN;
                    if (item.send != null) fd.events |= posix.POLL.OUT;
                }
                const duration = (timeout orelse @as(std.Io.Timeout, .none)).toDurationFromNow(io);
                const milliseconds: i32 = if (duration) |value| @intCast(@min(std.math.maxInt(i32), @max(0, @divFloor(value.raw.toNanoseconds() + std.time.ns_per_ms - 1, std.time.ns_per_ms)))) else -1;
                _ = try posix.poll(&fds, milliseconds);
                if (fds[1].revents != 0) {
                    var bytes: [128]u8 = undefined;
                    while (true) {
                        const result = posix.system.read(self.wake_pipe[0], &bytes, bytes.len);
                        switch (posix.errno(result)) {
                            .SUCCESS => if (result == 0) break,
                            .AGAIN => break,
                            .INTR => continue,
                            else => return error.Unexpected,
                        }
                    }
                    _ = self.notified.swap(false, .acq_rel);
                }
                if (fds[0].revents & posix.POLL.IN != 0) try self.acceptReady(io);
                for (self.connections, fds[2..]) |item, fd| {
                    if (fd.revents == 0 or item.state != .open) continue;
                    if (item.receive) |index| if (fd.revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) self.operationReady(index);
                    if (item.send) |index| if (fd.revents & (posix.POLL.OUT | posix.POLL.ERR | posix.POLL.HUP) != 0) self.operationReady(index);
                }
                self.finishCloses(io);
            }
            const count = @min(destination.len, self.event_count);
            for (destination[0..count]) |*event| {
                event.* = self.events[self.event_head];
                self.event_head = (self.event_head + 1) % limits.events;
            }
            self.event_count -= count;
            return count;
        }

        fn start(self: *Self, _: std.Io, handle: network.Handle, kind: Kind, bytes: []u8) network.QueueError!void {
            _ = try self.queue(handle, kind, bytes);
        }

        fn queue(self: *Self, handle: network.Handle, kind: Kind, bytes: []u8) network.QueueError!usize {
            const item = self.connection(handle) orelse return error.InvalidHandle;
            if ((kind == .receive and item.receive != null) or (kind == .send and item.send != null))
                return error.Busy;

            const index = self.freeOperation() orelse return error.Full;
            self.operations[index] = .{
                .used = true,
                .kind = kind,
                .handle = handle,
                .bytes = bytes,
            };

            if (kind == .receive) {
                item.receive = index;
            } else {
                item.send = index;
            }

            return index;
        }

        fn operationReady(self: *Self, index: usize) void {
            const operation = self.operations[index];
            const item = self.owner(operation.handle).?;
            const fd = item.stream.socket.handle;
            const bytes = operation.bytes;
            const result = switch (operation.kind) {
                .receive => posix.system.recvfrom(fd, bytes.ptr, bytes.len, 0, null, null),
                .send => posix.system.sendto(fd, bytes.ptr, bytes.len, if (@hasDecl(posix.MSG, "NOSIGNAL")) posix.MSG.NOSIGNAL else 0, null, 0),
            };
            const errno = posix.errno(result);
            if (errno == .AGAIN or errno == .INTR) return;
            const count: usize = if (errno == .SUCCESS) @intCast(result) else 0;
            const completion: network.Completion = .{ .handle = operation.handle, .result = .{ .bytes = count, .errno = if (errno == .SUCCESS and count != 0) null else 1 } };
            self.push(switch (operation.kind) {
                .receive => .{ .received = completion },
                .send => .{ .sent = completion },
            });
            self.release(index);
            if (completion.result.errno != null) {
                item.state = .closing;
                item.close = if (operation.kind == .receive) .peer_closed else .io_failure;
            }
        }

        fn acceptReady(self: *Self, io: std.Io) !void {
            while (self.freeConnection()) |index| {
                const result = posix.system.accept(self.listener.?.socket.handle, null, null);
                switch (posix.errno(result)) {
                    .SUCCESS => {},
                    .AGAIN => return,
                    .INTR, .CONNABORTED => continue,
                    else => return error.Unexpected,
                }
                const fd: posix.fd_t = @intCast(result);
                errdefer closeFd(fd);
                try nonblocking(fd);
                var generation = self.connections[index].generation +% 1;
                if (generation == 0) generation = 1;
                self.connections[index] = .{ .state = .open, .stream = .{ .socket = .{ .handle = fd, .address = self.listener.?.socket.address } }, .generation = generation };
                self.push(.{ .accepted = .{ .index = @intCast(index), .generation = generation } });
            }
            _ = io;
        }

        fn release(self: *Self, index: usize) void {
            const operation = self.operations[index];

            if (self.owner(operation.handle)) |c| {
                if (operation.kind == .receive) c.receive = null else c.send = null;
            }

            self.operations[index].used = false;
        }

        fn finishCloses(self: *Self, io: std.Io) void {
            for (&self.connections, 0..) |*item, index| {
                if (item.state != .closing) continue;
                const pending = [_]?usize{ item.receive, item.send };
                for (pending) |slot| if (slot) |at| {
                    const completion: network.Completion = .{ .handle = self.operations[at].handle, .result = .{ .bytes = 0, .errno = 1 } };
                    self.push(if (self.operations[at].kind == .receive) .{ .received = completion } else .{ .sent = completion });
                    self.release(at);
                };

                const handle: network.Handle = .{ .index = @intCast(index), .generation = item.generation };
                item.stream.close(io);
                self.push(.{ .closed = .{ .handle = handle, .reason = item.close.? } });
                item.state = .closed;
                item.stream_closed = true;
            }
        }

        fn connection(self: *Self, handle: network.Handle) ?*Connection {
            if (handle.index >= limits.connections)
                return null;

            const c = &self.connections[handle.index];
            return if (c.state == .open and c.generation == handle.generation) c else null;
        }

        fn owner(self: *Self, handle: network.Handle) ?*Connection {
            if (handle.index >= limits.connections)
                return null;

            const c = &self.connections[handle.index];
            return if (c.state != .free and c.generation == handle.generation) c else null;
        }

        fn freeConnection(self: *Self) ?usize {
            for (self.connections, 0..) |c, i|
                if (c.state == .free)
                    return i;

            return null;
        }

        fn freeOperation(self: *Self) ?usize {
            for (self.operations, 0..) |operation, i|
                if (!operation.used)
                    return i;

            return null;
        }

        fn push(self: *Self, event: network.Event) void {
            assert(self.event_count < limits.events);
            self.events[(self.event_head + self.event_count) % limits.events] = event;
            self.event_count += 1;
        }

        pub fn submit(self: *Self, _: std.Io) !void {
            for (self.operations, 0..) |op, index| if (op.used) self.operationReady(index);
        }
    };
}

fn nonblocking(fd: posix.fd_t) !void {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(flags) != .SUCCESS) return error.Unexpected;
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock)) != .SUCCESS) return error.Unexpected;
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) return error.Unexpected;
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

test "pause returns socket buffer ownership without waiting for the peer" {
    try networking_test.pause(Transport(.{ .connections = 2, .operations = 8, .events = 16 }));
}
