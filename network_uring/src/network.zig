//! Buffers are caller-owned and never registered.
const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;
const network = @import("networking");

const assert = std.debug.assert;

pub const Configuration = struct {
    address: std.Io.net.IpAddress,
    backlog: u32 = 128,
    ring_entries: u16 = 256,
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

        const Conn = struct {
            state: State = .free,
            fd: posix.socket_t = -1,
            generation: u32 = 0,
            recv: ?usize = null,
            send: ?usize = null,
            reason: ?network.CloseReason = null,
        };

        const Op = struct {
            used: bool = false,
            submitted: bool = false,
            cancel_requested: bool = false,
            kind: Kind = .receive,
            handle: network.Handle = undefined,
            bytes: []u8 = undefined,
        };

        ring: linux.IoUring,
        listener: posix.socket_t,
        wake_fd: posix.fd_t,
        wake_bytes: [8]u8 = undefined,
        wake_pending: bool = false,
        accept_pending: bool = false,
        accepting: bool = true,
        accept_cancel_pending: bool = false,
        connections: [limits.connections]Conn = @splat(.{}),
        operations: [limits.operations]Op = @splat(.{}),
        events: [limits.events]network.Event = undefined,
        event_head: usize = 0,
        event_count: usize = 0,

        pub fn init(io: std.Io, config: Configuration) !Self {
            _ = io;
            if (config.ring_entries < 4)
                return error.InvalidConfiguration;

            var ring = try linux.IoUring.init(config.ring_entries, 0);
            errdefer ring.deinit();
            if (ring.features & linux.IORING_FEAT_EXT_ARG == 0)
                return error.UnsupportedKernel;

            const wake = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
            if (linux.errno(wake) != .SUCCESS)
                return error.WakeupUnavailable;

            const wake_fd: posix.fd_t = @intCast(wake);
            errdefer fdClose(wake_fd);
            return .{
                .ring = ring,
                .listener = config.inherited_listener orelse try listener(config.address, config.backlog),
                .wake_fd = wake_fd,
            };
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            _ = io;
            self.ring.deinit();
            fdClose(self.listener);
            fdClose(self.wake_fd);

            for (self.connections) |c|
                fdClose(c.fd);

            self.* = undefined;
        }

        pub fn transport(self: *Self) network.Transport {
            return .{
                .context = self,
                .vtable = network.Transport.adapter(Self),
                .inheritance = .{
                    .context = self,
                    .pause = pauseAccept,
                    .ready = paused,
                    .listener = listenerDescriptor,
                    .descriptor = descriptor,
                    .adopt = adopt,
                },
            };
        }

        fn pauseAccept(context: *anyopaque, io: std.Io, pause: bool) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.accepting = !pause;

            if (pause)
                self.notify(io);
        }

        fn paused(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return !self.accepting and !self.accept_pending and !self.accept_cancel_pending and !self.wake_pending;
        }

        fn listenerDescriptor(context: *anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.listener;
        }

        fn descriptor(context: *anyopaque, handle: network.Handle) i32 {
            const self: *Self = @ptrCast(@alignCast(context));
            const connection = self.conn(handle).?;
            assert(connection.recv == null and connection.send == null);
            return connection.fd;
        }

        fn adopt(context: *anyopaque, fd: i32) !network.Handle {
            const self: *Self = @ptrCast(@alignCast(context));
            const index = self.freeConn() orelse return error.Full;
            assert(fd >= 0 and self.connections[index].generation == 0);
            self.connections[index] = .{ .state = .open, .fd = fd, .generation = 1 };
            return .{ .index = @intCast(index), .generation = 1 };
        }

        pub fn queueReceive(self: *Self, io: std.Io, h: network.Handle, b: []u8) network.QueueError!void {
            _ = io;
            return self.queue(h, .receive, b);
        }

        pub fn queueSend(self: *Self, io: std.Io, h: network.Handle, b: []const u8) network.QueueError!void {
            _ = io;
            return self.queue(h, .send, @constCast(b));
        }

        pub fn close(self: *Self, io: std.Io, h: network.Handle, reason: network.CloseReason) void {
            _ = io;
            self.beginClose(h, reason);
        }

        pub fn releaseConnection(self: *Self, io: std.Io, handle: network.Handle) void {
            _ = io;
            const item = &self.connections[handle.index];
            assert(item.state == .closed and item.generation == handle.generation);
            assert(item.recv == null and item.send == null and item.fd == -1);
            item.* = .{ .generation = item.generation };
        }

        pub fn notify(self: *Self, io: std.Io) void {
            _ = io;
            const value: u64 = 1;

            while (true) {
                const result = linux.write(self.wake_fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));

                switch (linux.errno(result)) {
                    .INTR => continue,
                    .AGAIN => return,
                    .SUCCESS => {
                        assert(result == @sizeOf(u64));
                        return;
                    },
                    else => unreachable,
                }
            }
        }

        pub fn poll(self: *Self, io: std.Io, deadline: ?std.Io.Timeout, out: []network.Event) !usize {
            assert(out.len != 0);
            const ready = self.takeEvents(out);
            if (ready != 0) return ready;
            self.stage();
            var timeout: linux.kernel_timespec = undefined;
            var arguments: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = 0 };

            if (deadline) |value| if (value.toDurationFromNow(io)) |duration| {
                const ns = @max(@as(i96, 0), duration.raw.nanoseconds);
                timeout = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
                arguments.ts = @intFromPtr(&timeout);
            };

            const submitted = self.ring.flush_sq();
            const result = linux.syscall6(.io_uring_enter, @intCast(self.ring.fd), submitted, 1, linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG, @intFromPtr(&arguments), @sizeOf(linux.io_uring_getevents_arg));

            switch (linux.errno(result)) {
                .SUCCESS, .TIME, .INTR => {},
                else => return error.RingFailure,
            }

            var cqes: [limits.operations + 1]linux.io_uring_cqe = undefined;
            // A terminal operation can also make its connection close, costing two event slots.
            // Reserve both before consuming its CQE.
            const room = @min(cqes.len, (limits.events - self.event_count) / 2);
            const got = if (room == 0) 0 else try self.ring.copy_cqes(cqes[0..room], 0);

            for (cqes[0..got]) |cqe| self.complete(cqe);
            self.finishClose();
            return self.takeEvents(out);
        }

        pub fn submit(self: *Self, _: std.Io) !void {
            self.stage();
            if (self.ring.sq_ready() == 0) return;
            _ = self.ring.submit() catch |err| switch (err) {
                error.SignalInterrupt => return,
                else => return err,
            };
        }

        fn stage(self: *Self) void {
            if (self.accepting and !self.wake_pending) {
                _ = self.ring.read(wake_tag, self.wake_fd, .{ .buffer = &self.wake_bytes }, 0) catch return;
                self.wake_pending = true;
            }

            if (!self.accepting and self.accept_pending and !self.accept_cancel_pending) {
                _ = self.ring.cancel(cancel_tag_base - 1, accept_tag, 0) catch return;
                self.accept_cancel_pending = true;
            }

            if (self.accepting and !self.accept_pending and self.freeConn() != null) {
                const sqe = self.ring.get_sqe() catch return;
                sqe.prep_accept(self.listener, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
                sqe.user_data = accept_tag;
                self.accept_pending = true;
            }

            for (&self.operations, 0..) |*op, i| {
                if (op.used and op.submitted and !op.cancel_requested and self.owner(op.handle).?.state == .closing) {
                    _ = self.ring.cancel(cancelTag(i), @intCast(i), 0) catch continue;
                    op.cancel_requested = true;
                }

                if (!op.used or op.submitted)
                    continue;

                const c = self.conn(op.handle) orelse {
                    self.release(i);
                    continue;
                };
                if (c.state != .open)
                    continue;

                const sqe = self.ring.get_sqe() catch return;

                switch (op.kind) {
                    .receive => sqe.prep_recv(c.fd, op.bytes, 0),
                    .send => sqe.prep_send(c.fd, op.bytes, 0),
                }

                sqe.user_data = @intCast(i);
                op.submitted = true;
            }
        }

        fn complete(self: *Self, cqe: linux.io_uring_cqe) void {
            if (cqe.user_data == cancel_tag_base - 1) {
                self.accept_cancel_pending = false;
                return;
            }

            if (cqe.user_data == wake_tag) {
                assert(cqe.res == self.wake_bytes.len);
                self.wake_pending = false;
                return;
            }

            if (cqe.user_data == accept_tag or cqe.user_data >= cancel_tag_base) {
                if (cqe.user_data == accept_tag)
                    self.accept_pending = false;

                if (cqe.res >= 0 and cqe.user_data == accept_tag)
                    self.admit(@intCast(cqe.res));

                return;
            }

            if (cqe.user_data >= limits.operations)
                return;

            const i: usize = @intCast(cqe.user_data);
            const op = &self.operations[i];
            if (!op.used)
                return;

            op.submitted = false;
            const bytes: usize = if (cqe.res > 0) @intCast(cqe.res) else 0;
            assert(bytes <= op.bytes.len);
            const result: network.Result = .{ .bytes = bytes, .errno = if (cqe.res < 0) -cqe.res else null };
            const h = op.handle;
            self.push(switch (op.kind) {
                .receive => .{ .received = .{ .handle = h, .result = result } },
                .send => .{ .sent = .{ .handle = h, .result = result } },
            });
            self.release(i);

            if (cqe.res <= 0)
                self.beginClose(h, if (cqe.res == 0) .peer_closed else .io_failure);
        }

        fn queue(self: *Self, h: network.Handle, k: Kind, b: []u8) network.QueueError!void {
            const c = self.conn(h) orelse return error.InvalidHandle;
            if ((k == .receive and c.recv != null) or (k == .send and c.send != null))
                return error.Busy;

            const i = self.freeOp() orelse return error.Full;
            self.operations[i] = .{ .used = true, .kind = k, .handle = h, .bytes = b };

            if (k == .receive) c.recv = i else c.send = i;
        }

        fn release(self: *Self, i: usize) void {
            const op = self.operations[i];

            if (self.owner(op.handle)) |c| {
                if (op.kind == .receive) c.recv = null else c.send = null;
            }

            self.operations[i].used = false;
        }

        fn beginClose(self: *Self, h: network.Handle, reason: network.CloseReason) void {
            if (self.conn(h)) |c| {
                c.state = .closing;
                c.reason = reason;

                // A staged-but-not-submitted buffer has no CQE. Return it now. Submitted buffers
                // remain pinned until their CQEs are consumed.
                for (&self.operations, 0..) |*op, i| {
                    if (!(op.used and !op.submitted and std.meta.eql(op.handle, h)))
                        continue;

                    self.push(switch (op.kind) {
                        .receive => .{ .received = .{ .handle = h, .result = .{ .bytes = 0, .errno = @intFromEnum(linux.E.CANCELED) } } },
                        .send => .{ .sent = .{ .handle = h, .result = .{ .bytes = 0, .errno = @intFromEnum(linux.E.CANCELED) } } },
                    });
                    self.release(i);
                }
            }
        }

        fn finishClose(self: *Self) void {
            for (&self.connections, 0..) |*c, i| {
                if (c.state != .closing or c.recv != null or c.send != null)
                    continue;

                self.push(.{ .closed = .{ .handle = .{ .index = @intCast(i), .generation = c.generation }, .reason = c.reason.? } });
                fdClose(c.fd);
                c.fd = -1;
                c.state = .closed;
            }
        }

        fn admit(self: *Self, fd: posix.socket_t) void {
            // Sessions already batches sends. Nagle would add a second, ACK-gated batcher.
            const enabled: c_int = 1;
            const result = linux.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&enabled), @sizeOf(c_int));
            if (linux.errno(result) != .SUCCESS) {
                std.log.err("event=tcp_configuration_failed errno={s}", .{@tagName(linux.errno(result))});
                fdClose(fd);
                return;
            }

            const i = self.freeConn() orelse {
                fdClose(fd);
                return;
            };
            var g = self.connections[i].generation +% 1;

            if (g == 0) g = 1;
            self.connections[i] = .{ .state = .open, .fd = fd, .generation = g };
            self.push(.{ .accepted = .{ .index = @intCast(i), .generation = g } });
        }

        fn conn(self: *Self, h: network.Handle) ?*Conn {
            if (h.index >= limits.connections)
                return null;

            const c = &self.connections[h.index];
            return if (c.state == .open and c.generation == h.generation) c else null;
        }

        fn owner(self: *Self, h: network.Handle) ?*Conn {
            if (h.index >= limits.connections)
                return null;

            const c = &self.connections[h.index];
            return if (c.state != .free and c.generation == h.generation) c else null;
        }

        fn freeConn(self: *Self) ?usize {
            for (self.connections, 0..) |c, i|
                if (c.state == .free)
                    return i;

            return null;
        }

        fn freeOp(self: *Self) ?usize {
            for (self.operations, 0..) |op, i|
                if (!op.used)
                    return i;

            return null;
        }

        fn push(self: *Self, event: network.Event) void {
            assert(self.event_count < limits.events);
            self.events[(self.event_head + self.event_count) % limits.events] = event;
            self.event_count += 1;
        }

        fn takeEvents(self: *Self, out: []network.Event) usize {
            const n = @min(out.len, self.event_count);

            for (out[0..n]) |*event| {
                event.* = self.events[self.event_head];
                self.event_head = (self.event_head + 1) % limits.events;
            }

            self.event_count -= n;
            return n;
        }

        const accept_tag = std.math.maxInt(u64);
        const wake_tag = accept_tag - 1;
        const cancel_tag_base = wake_tag - limits.operations;

        fn cancelTag(i: usize) u64 {
            return cancel_tag_base + i;
        }
    };
}

const Addr = extern union {
    any: posix.sockaddr,
    ip4: posix.sockaddr.in,
    ip6: posix.sockaddr.in6,
};

fn listener(a: std.Io.net.IpAddress, backlog: u32) !posix.socket_t {
    const domain: u32 = switch (a) {
        .ip4 => linux.AF.INET,
        .ip6 => linux.AF.INET6,
    };
    const raw = linux.socket(domain, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (linux.errno(raw) != .SUCCESS)
        return posix.unexpectedErrno(linux.errno(raw));

    const fd: posix.socket_t = @intCast(raw);
    errdefer fdClose(fd);
    const enabled: c_int = 1;
    const reuse = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&enabled), @sizeOf(c_int));
    if (linux.errno(reuse) != .SUCCESS)
        return posix.unexpectedErrno(linux.errno(reuse));

    var store: Addr = undefined;
    const sa: *const posix.sockaddr, const len: posix.socklen_t = switch (a) {
        .ip4 => |x| b: {
            store.ip4 = .{
                .port = std.mem.nativeToBig(u16, x.port),
                .addr = @bitCast(x.bytes),
            };
            break :b .{ &store.any, @sizeOf(posix.sockaddr.in) };
        },
        .ip6 => |x| b: {
            store.ip6 = .{
                .port = std.mem.nativeToBig(u16, x.port),
                .flowinfo = x.flow,
                .addr = x.bytes,
                .scope_id = x.interface.index,
            };
            break :b .{ &store.any, @sizeOf(posix.sockaddr.in6) };
        },
    };
    const r = linux.bind(fd, sa, len);

    switch (linux.errno(r)) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => |err| return posix.unexpectedErrno(err),
    }

    const q = linux.listen(fd, backlog);
    if (linux.errno(q) != .SUCCESS)
        return posix.unexpectedErrno(linux.errno(q));

    return fd;
}

fn fdClose(fd: posix.socket_t) void {
    if (fd >= 0) _ = linux.close(fd);
}
