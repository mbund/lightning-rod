const std = @import("std");
const network = @import("networking");

const linux = std.os.linux;
const posix = std.posix;

const assert = std.debug.assert;

pub const Configuration = struct {
    address: std.Io.net.IpAddress,
    connections: usize,
    connections_per_ring: usize = @as(usize, std.math.maxInt(u16)) + 1,
    backlog: u32 = 128,
    ring_entries: u16 = 256,
    inherited_listener: ?i32 = null,
};

pub const Ring = struct {
    const Self = @This();

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
        next_free: ?usize = null,
        fd: posix.socket_t = -1,
        generation: u32 = 0,
        recv: ?usize = null,
        send: ?usize = null,
        reason: ?network.CloseReason = null,
    };

    const ReceiveRing = struct {
        ring: linux.io_uring_buf_ring align(std.heap.page_size_min) = std.mem.zeroes(linux.io_uring_buf_ring),
        registered: bool = false,
        dirty: bool = false,
    };

    const Op = struct {
        used: bool = false,
        queued: bool = false,
        previous: ?usize = null,
        next: ?usize = null,
        submitted: bool = false,
        cancel_requested: bool = false,
        cancel_pending: bool = false,
        completed: bool = false,
        cancel: bool = false,
        kind: Kind = .receive,
        handle: network.Handle = undefined,
        bytes: []u8 = undefined,
        length: usize = 0,
        received: usize = 0,
        buffer_pending: bool = true,
        message: linux.msghdr_const = undefined,
    };

    ring: linux.IoUring,
    aborted: bool = false,
    listener: posix.socket_t,
    wake_fd: posix.fd_t,
    wake_bytes: [8]u8 = undefined,
    wake_pending: bool = false,
    wake_notified: std.atomic.Value(bool) = .init(false),
    accept_pending: bool = false,
    accepting: bool = true,
    accept_cancel_pending: bool = false,
    free_connection: ?usize = 0,
    free_operation: ?usize = 0,
    free_operations: usize,
    pending_head: ?usize = null,
    pending_tail: ?usize = null,
    allocator: std.mem.Allocator,
    connections: []Conn,
    descriptors: std.AutoArrayHashMapUnmanaged(i32, void),
    operations: []Op,
    receive_rings: []ReceiveRing,
    events: []network.Event,
    event_head: usize = 0,
    event_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) !Self {
        _ = io;
        if (config.connections == 0 or config.connections > @as(usize, std.math.maxInt(u16)) + 1) return error.InvalidSessionCapacity;
        if (config.inherited_listener) |fd| {
            var accepting: c_int = 0;
            var size: posix.socklen_t = @sizeOf(c_int);
            const result = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ACCEPTCONN, std.mem.asBytes(&accepting), &size);
            if (linux.errno(result) != .SUCCESS or size != @sizeOf(c_int) or accepting != 1) return error.InvalidListener;
        }
        const connections = try allocator.alloc(Conn, config.connections);
        errdefer allocator.free(connections);
        var descriptors: std.AutoArrayHashMapUnmanaged(i32, void) = .{};
        try descriptors.ensureTotalCapacity(allocator, config.connections);
        errdefer descriptors.deinit(allocator);
        for (connections, 0..) |*connection, index| connection.* = .{ .next_free = if (index + 1 < connections.len) index + 1 else null };
        const operations = try allocator.alloc(Op, config.connections * 2);
        errdefer allocator.free(operations);
        for (operations, 0..) |*operation, index| operation.* = .{ .next = if (index + 1 < operations.len) index + 1 else null };
        const receive_rings = try allocator.alloc(ReceiveRing, config.connections);
        errdefer allocator.free(receive_rings);
        for (receive_rings) |*provided| provided.* = .{};
        const events = try allocator.alloc(network.Event, config.connections * 4 + 1);
        errdefer allocator.free(events);
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
        const listening = config.inherited_listener orelse try listener(config.address, config.backlog);
        errdefer if (config.inherited_listener == null) fdClose(listening);
        // Accepted sockets inherit TCP_NODELAY. Sessions already batches sends.
        const enabled: c_int = 1;
        const configured = linux.setsockopt(listening, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&enabled), @sizeOf(c_int));
        if (linux.errno(configured) != .SUCCESS) return posix.unexpectedErrno(linux.errno(configured));
        var self: Self = .{
            .allocator = allocator,
            .connections = connections,
            .descriptors = descriptors,
            .operations = operations,
            .receive_rings = receive_rings,
            .free_operations = operations.len,
            .events = events,
            .ring = ring,
            .listener = listening,
            .wake_fd = wake_fd,
        };
        try self.prepareReceiveRing(0);
        return self;
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        _ = io;
        if (!self.aborted) self.ring.deinit();
        self.allocator.free(self.events);
        self.allocator.free(self.operations);
        self.allocator.free(self.receive_rings);
        fdClose(self.listener);
        fdClose(self.wake_fd);

        for (self.connections) |c|
            fdClose(c.fd);

        self.descriptors.deinit(self.allocator);
        self.allocator.free(self.connections);

        self.* = undefined;
    }

    /// Stop kernel access to borrowed buffers without relying on the failed event loop.
    pub fn abort(self: *Self) void {
        assert(!self.aborted);
        var cancel: linux.io_uring_sync_cancel_reg = .{
            .addr = 0,
            .fd = -1,
            .flags = linux.IORING_ASYNC_CANCEL_ANY | linux.IORING_ASYNC_CANCEL_ALL,
            .timeout = .{ .sec = -1, .nsec = -1 },
            .pad = @splat(0),
        };
        while (true) {
            const result = linux.io_uring_register(self.ring.fd, .REGISTER_SYNC_CANCEL, &cancel, 1);
            switch (linux.errno(result)) {
                .SUCCESS, .NOENT => break,
                .INTR => continue,
                else => @panic("unable to cancel failed session transport"),
            }
        }
        self.ring.deinit();
        self.aborted = true;
    }

    pub fn transport(self: *Self) network.Transport {
        return .{
            .context = self,
            .vtable = network.Transport.adapter(Self),
            .inheritance = network.Inheritance.init(Self, self),
        };
    }

    pub fn pause(self: *Self, io: std.Io, enabled: bool) void {
        self.accepting = !enabled;

        if (enabled) {
            for (self.operations, 0..) |*op, index| if (op.used and !op.completed) {
                op.cancel = true;
                if (!op.cancel_requested) self.schedule(index);
            };
            self.notify(io);
        }
    }

    pub fn paused(self: *Self) bool {
        if (self.accepting or self.accept_pending or self.accept_cancel_pending or self.wake_pending or self.event_count != 0) return false;
        return self.free_operations == self.operations.len;
    }

    pub fn listenerDescriptor(self: *Self) i32 {
        return self.listener;
    }

    pub fn descriptor(self: *Self, handle: network.Handle) i32 {
        const connection = self.conn(handle).?;
        assert(connection.recv == null and connection.send == null);
        return connection.fd;
    }

    pub fn adopt(self: *Self, fd: i32) !network.Handle {
        if (fd < 0 or fd == self.listener) return error.InvalidDescriptor;
        if (self.descriptors.contains(fd)) return error.InvalidDescriptor;
        const index = self.freeConn() orelse return error.Full;
        const generation = try std.math.add(u32, self.connections[index].generation, 1);
        const flags = linux.fcntl(fd, linux.F.SETFD, @as(usize, linux.FD_CLOEXEC));
        if (linux.errno(flags) != .SUCCESS) return error.InvalidDescriptor;
        self.free_connection = self.connections[index].next_free;
        self.connections[index] = .{ .state = .open, .fd = fd, .generation = generation };
        self.descriptors.putAssumeCapacityNoClobber(fd, {});
        return .{ .index = @intCast(index), .generation = generation };
    }

    pub fn queueReceive(self: *Self, io: std.Io, h: network.Handle, b: []u8) network.QueueError!void {
        _ = io;
        const connection = self.conn(h) orelse return error.InvalidHandle;
        if (connection.recv != null) return error.Busy;
        if (self.free_operation == null) return error.Full;
        assert(b.len > 0 and b.len <= std.math.maxInt(u32));
        self.prepareReceiveRing(h.index) catch return error.Closed;
        try self.queue(h, .receive, b);
        const provided = &self.receive_rings[h.index];
        linux.IoUring.buf_ring_add(&provided.ring, b, 0, 0, 0);
        linux.IoUring.buf_ring_advance(&provided.ring, 1);
    }

    fn prepareReceiveRing(self: *Self, index: usize) !void {
        const provided = &self.receive_rings[index];
        if (provided.registered and !provided.dirty) return;
        var registration: linux.io_uring_buf_reg = .{
            .ring_addr = @intFromPtr(&provided.ring),
            .ring_entries = 1,
            .bgid = @intCast(index),
            .flags = .{ .inc = true },
            .resv = @splat(0),
        };
        if (provided.registered) {
            var unregistration = std.mem.zeroes(linux.io_uring_buf_reg);
            unregistration.bgid = @intCast(index);
            while (true) {
                const result = linux.io_uring_register(self.ring.fd, .UNREGISTER_PBUF_RING, &unregistration, 1);
                if (linux.errno(result) == .INTR) continue;
                if (linux.errno(result) != .SUCCESS) return error.BufferRingFailure;
                break;
            }
            provided.registered = false;
        }
        provided.ring = std.mem.zeroes(linux.io_uring_buf_ring);
        while (true) {
            const result = linux.io_uring_register(self.ring.fd, .REGISTER_PBUF_RING, &registration, 1);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) == .INVAL) return error.IncrementalReceiveUnsupported;
            if (linux.errno(result) != .SUCCESS) return error.BufferRingFailure;
            break;
        }
        provided.registered = true;
        provided.dirty = false;
    }

    pub fn queueSend(self: *Self, io: std.Io, handle: network.Handle, vectors: []const posix.iovec_const) network.QueueError!void {
        _ = io;
        assert(vectors.len > 0 and vectors.len <= network.send_vectors_max);
        var length: usize = 0;
        for (vectors) |vector| length = std.math.add(usize, length, vector.len) catch return error.Full;
        assert(length > 0);
        try self.queue(handle, .send, &.{});
        const operation = &self.operations[self.connections[handle.index].send.?];
        operation.length = length;
        operation.message = .{ .name = null, .namelen = 0, .iov = vectors.ptr, .iovlen = vectors.len, .control = null, .controllen = 0, .flags = 0 };
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
        item.* = .{ .generation = item.generation, .next_free = self.free_connection };
        self.free_connection = handle.index;
    }

    pub fn notify(self: *Self, io: std.Io) void {
        _ = io;
        if (self.wake_notified.swap(true, .acq_rel)) return;
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
        var count = self.takeEvents(out);
        self.stage();
        var completed: usize = 0;
        if (count == 0) {
            completed = try self.reap();
            count = self.takeEvents(out);
        }
        const wait = count == 0 and completed == 0 and !self.paused();
        try self.exchange(io, deadline, wait);
        if (count == 0) {
            _ = try self.reap();
            count = self.takeEvents(out);
        }
        assert(count <= out.len);
        return count;
    }

    pub fn pollReady(self: *Self, io: std.Io, out: []network.Event) !struct { count: usize, completed: usize } {
        assert(out.len != 0);
        var count = self.takeEvents(out);
        self.stage();
        try self.exchange(io, null, false);
        const completed = try self.reap();
        if (count < out.len) count += self.takeEvents(out[count..]);
        return .{ .count = count, .completed = completed };
    }

    fn exchange(self: *Self, io: std.Io, deadline: ?std.Io.Timeout, wait: bool) !void {
        if (!wait and self.ring.sq_ready() == 0) return;
        var timeout: linux.kernel_timespec = undefined;
        var arguments: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = 0 };

        if (wait) if (deadline) |value| if (value.toDurationFromNow(io)) |duration| {
            const ns = @max(@as(i96, 0), duration.raw.nanoseconds);
            timeout = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
            arguments.ts = @intFromPtr(&timeout);
        };

        const submitted = self.ring.flush_sq();
        const flags: u32 = if (wait) linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG else 0;
        const result = linux.syscall6(.io_uring_enter, @intCast(self.ring.fd), submitted, @intFromBool(wait), flags, @intFromPtr(&arguments), @sizeOf(linux.io_uring_getevents_arg));

        switch (linux.errno(result)) {
            .SUCCESS, .TIME, .INTR => {},
            else => return error.RingFailure,
        }
    }

    fn reap(self: *Self) !usize {
        var cqes: [64]linux.io_uring_cqe = undefined;
        // A terminal operation can also make its connection close, costing two event slots.
        // Reserve both before consuming its CQE.
        const room = @min(cqes.len, (self.events.len - self.event_count) / 2);
        const got = if (room == 0) 0 else try self.ring.copy_cqes(cqes[0..room], 0);

        for (cqes[0..got]) |cqe| self.complete(cqe);
        return got;
    }

    pub fn submit(self: *Self, io: std.Io) !void {
        self.stage();
        try self.exchange(io, null, false);
    }

    fn stage(self: *Self) void {
        if (self.accepting and !self.wake_pending) {
            _ = self.ring.read(wake_tag, self.wake_fd, .{ .buffer = &self.wake_bytes }, 0) catch return;
            self.wake_pending = true;
        }

        if ((!self.accepting or self.freeConn() == null) and self.accept_pending and !self.accept_cancel_pending) {
            _ = self.ring.cancel(cancel_tag_base - 1, accept_tag, 0) catch return;
            self.accept_cancel_pending = true;
        }

        if (self.accepting and !self.accept_pending and !self.accept_cancel_pending and self.freeConn() != null) {
            const sqe = self.ring.get_sqe() catch return;
            sqe.prep_accept(self.listener, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
            sqe.ioprio |= linux.IORING_ACCEPT_MULTISHOT;
            sqe.user_data = accept_tag;
            self.accept_pending = true;
        }

        while (self.pending_head) |i| {
            const op = &self.operations[i];
            assert(op.used and op.queued and !op.completed);
            if (op.submitted) {
                assert(op.cancel and !op.cancel_requested);
                _ = self.ring.cancel(cancelTag(i), @intCast(i), 0) catch return;
                self.unschedule(i);
                op.cancel_requested = true;
                op.cancel_pending = true;
                continue;
            }
            if (op.cancel) {
                const completion: network.Completion = .{ .handle = op.handle, .result = .{ .bytes = 0, .errno = @intFromEnum(linux.E.CANCELED) } };
                self.push(if (op.kind == .receive) .{ .received = completion } else .{ .sent = completion });
                self.release(i);
                continue;
            }
            const c = self.conn(op.handle) orelse unreachable;
            const sqe = self.ring.get_sqe() catch return;
            switch (op.kind) {
                .receive => {
                    sqe.prep_recv(c.fd, &.{}, 0);
                    sqe.ioprio |= linux.IORING_RECV_MULTISHOT;
                    sqe.flags |= linux.IOSQE_BUFFER_SELECT;
                    sqe.buf_index = @intCast(op.handle.index);
                },
                .send => sqe.prep_sendmsg(c.fd, &op.message, linux.MSG.NOSIGNAL),
            }
            sqe.user_data = @intCast(i);
            self.unschedule(i);
            op.submitted = true;
        }
    }

    fn schedule(self: *Self, index: usize) void {
        const op = &self.operations[index];
        assert(op.used and !op.completed);
        if (op.queued) return;
        assert(op.previous == null and op.next == null);
        op.queued = true;
        op.previous = self.pending_tail;
        if (self.pending_tail) |tail| self.operations[tail].next = index else self.pending_head = index;
        self.pending_tail = index;
    }

    fn unschedule(self: *Self, index: usize) void {
        const op = &self.operations[index];
        assert(op.used and op.queued);
        if (op.previous) |previous| self.operations[previous].next = op.next else {
            assert(self.pending_head == index);
            self.pending_head = op.next;
        }
        if (op.next) |next| self.operations[next].previous = op.previous else {
            assert(self.pending_tail == index);
            self.pending_tail = op.previous;
        }
        op.queued = false;
        op.previous = null;
        op.next = null;
    }

    fn complete(self: *Self, cqe: linux.io_uring_cqe) void {
        if (cqe.user_data == cancel_tag_base - 1) {
            self.accept_cancel_pending = false;
            return;
        }

        if (cqe.user_data == wake_tag) {
            assert(cqe.res == self.wake_bytes.len);
            // Acquire publications from producers whose notifications were coalesced.
            _ = self.wake_notified.swap(false, .acq_rel);
            self.wake_pending = false;
            return;
        }

        if (cqe.user_data == accept_tag) {
            self.accept_pending = cqe.flags & linux.IORING_CQE_F_MORE != 0;
            if (cqe.res >= 0) self.admit(@intCast(cqe.res));
            return;
        }

        if (cqe.user_data >= cancel_tag_base) {
            const index: usize = @intCast(cqe.user_data - cancel_tag_base);
            const op = &self.operations[index];
            assert(op.cancel_pending);
            op.cancel_pending = false;
            if (op.completed) self.freeOp(index);
            return;
        }

        if (cqe.user_data >= self.operations.len)
            return;

        const i: usize = @intCast(cqe.user_data);
        const op = &self.operations[i];
        if (!op.used)
            return;

        const more = cqe.flags & linux.IORING_CQE_F_MORE != 0;
        assert(!more or op.kind == .receive);
        op.submitted = more;
        const bytes: usize = if (cqe.res > 0) @intCast(cqe.res) else 0;
        assert(bytes <= op.length - op.received);
        if (op.kind == .receive) {
            op.received += bytes;
            if (cqe.flags & linux.IORING_CQE_F_BUFFER != 0) {
                assert(cqe.flags >> linux.IORING_CQE_BUFFER_SHIFT == 0);
                op.buffer_pending = cqe.flags & linux.IORING_CQE_F_BUF_MORE != 0;
            }
            if (!more) self.receive_rings[op.handle.index].dirty = op.buffer_pending;
        }
        const result: network.Result = .{ .bytes = bytes, .errno = if (cqe.res < 0) -cqe.res else null, .more = more };
        const h = op.handle;
        const canceled = op.cancel and cqe.res == -@as(i32, @intFromEnum(linux.E.CANCELED));
        self.push(switch (op.kind) {
            .receive => .{ .received = .{ .handle = h, .result = result } },
            .send => .{ .sent = .{ .handle = h, .result = result } },
        });
        const exhausted = op.kind == .receive and cqe.res == -@as(i32, @intFromEnum(linux.E.NOBUFS));
        if (!more) self.release(i);

        if (cqe.res <= 0 and !canceled and !exhausted)
            self.beginClose(h, if (cqe.res == 0) .peer_closed else .io_failure);
    }

    fn queue(self: *Self, h: network.Handle, k: Kind, b: []u8) network.QueueError!void {
        const c = self.conn(h) orelse return error.InvalidHandle;
        if ((k == .receive and c.recv != null) or (k == .send and c.send != null))
            return error.Busy;

        assert((self.free_operation == null) == (self.free_operations == 0));
        const i = self.free_operation orelse return error.Full;
        assert(self.free_operations > 0 and !self.operations[i].used);
        self.free_operation = self.operations[i].next;
        self.free_operations -= 1;
        self.operations[i] = .{ .used = true, .kind = k, .handle = h, .bytes = b, .length = b.len };

        if (k == .receive) c.recv = i else c.send = i;
        self.schedule(i);
    }

    fn release(self: *Self, i: usize) void {
        const op = &self.operations[i];
        assert(op.used and !op.submitted and !op.completed);
        if (op.queued) self.unschedule(i);
        const handle = op.handle;
        const c = self.owner(handle) orelse unreachable;
        if (op.kind == .receive) {
            self.receive_rings[handle.index].dirty = self.receive_rings[handle.index].dirty or op.buffer_pending;
            assert(c.recv == i);
            c.recv = null;
        } else {
            assert(c.send == i);
            c.send = null;
        }
        op.completed = true;
        // The cancellation CQE must arrive before this operation slot can be reused.
        if (!op.cancel_pending) self.freeOp(i);
        self.finishClose(handle.index);
    }

    fn freeOp(self: *Self, index: usize) void {
        const op = &self.operations[index];
        assert(op.used and op.completed and !op.queued and !op.submitted and !op.cancel_pending);
        assert(op.next == null and op.previous == null and self.free_operations < self.operations.len);
        op.used = false;
        op.next = self.free_operation;
        self.free_operation = index;
        self.free_operations += 1;
    }

    fn beginClose(self: *Self, h: network.Handle, reason: network.CloseReason) void {
        const c = self.conn(h) orelse return;
        c.state = .closing;
        c.reason = reason;
        for ([_]?usize{ c.recv, c.send }) |maybe_index| {
            const index = maybe_index orelse continue;
            const op = &self.operations[index];
            assert(op.used and !op.completed and std.meta.eql(op.handle, h));
            op.cancel = true;
            if (op.submitted) {
                if (!op.cancel_requested) self.schedule(index);
                continue;
            }
            self.push(switch (op.kind) {
                .receive => .{ .received = .{ .handle = h, .result = .{ .bytes = 0, .errno = @intFromEnum(linux.E.CANCELED) } } },
                .send => .{ .sent = .{ .handle = h, .result = .{ .bytes = 0, .errno = @intFromEnum(linux.E.CANCELED) } } },
            });
            self.release(index);
        }
        self.finishClose(h.index);
    }

    fn finishClose(self: *Self, index: usize) void {
        const c = &self.connections[index];
        if (c.state != .closing or c.recv != null or c.send != null) return;
        self.push(.{ .closed = .{ .handle = .{ .index = @intCast(index), .generation = c.generation }, .reason = c.reason.? } });
        const removed = self.descriptors.swapRemove(c.fd);
        assert(removed);
        fdClose(c.fd);
        c.fd = -1;
        c.state = .closed;
    }

    fn admit(self: *Self, fd: posix.socket_t) void {
        const i = self.freeConn() orelse {
            fdClose(fd);
            return;
        };
        var g = self.connections[i].generation +% 1;

        if (g == 0) g = 1;
        self.free_connection = self.connections[i].next_free;
        self.connections[i] = .{ .state = .open, .fd = fd, .generation = g };
        assert(!self.descriptors.contains(fd));
        self.descriptors.putAssumeCapacityNoClobber(fd, {});
        self.push(.{ .accepted = .{ .index = @intCast(i), .generation = g } });
    }

    fn conn(self: *Self, h: network.Handle) ?*Conn {
        if (h.index >= self.connections.len)
            return null;

        const c = &self.connections[h.index];
        return if (c.state == .open and c.generation == h.generation) c else null;
    }

    fn owner(self: *Self, h: network.Handle) ?*Conn {
        if (h.index >= self.connections.len)
            return null;

        const c = &self.connections[h.index];
        return if (c.state != .free and c.generation == h.generation) c else null;
    }

    fn freeConn(self: *Self) ?usize {
        const index = self.free_connection orelse return null;
        assert(self.connections[index].state == .free);
        return index;
    }

    fn push(self: *Self, event: network.Event) void {
        assert(self.event_count < self.events.len);
        self.events[(self.event_head + self.event_count) % self.events.len] = event;
        self.event_count += 1;
    }

    fn takeEvents(self: *Self, out: []network.Event) usize {
        const n = @min(out.len, self.event_count);

        for (out[0..n]) |*event| {
            event.* = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len;
        }

        self.event_count -= n;
        assert(n <= out.len);
        assert(self.event_count <= self.events.len);
        return n;
    }

    const accept_tag = std.math.maxInt(u64);
    const wake_tag = accept_tag - 1;
    const cancel_tag_base = wake_tag - std.math.maxInt(u32);

    fn cancelTag(i: usize) u64 {
        return cancel_tag_base + i;
    }
};

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

test "operation reuse waits for cancellation in either completion order" {
    for ([_]bool{ false, true }) |cancel_first| {
        var sockets: [2]posix.fd_t = undefined;
        try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sockets)));
        defer fdClose(sockets[1]);
        var transport = try Ring.init(std.testing.allocator, std.testing.io, .{ .connections = 1, .address = .{ .ip4 = .loopback(0) } });
        defer transport.deinit(std.testing.io);
        const handle = try transport.adopt(sockets[0]);
        var bytes: [2]u8 = undefined;
        try transport.queueReceive(std.testing.io, handle, bytes[0..1]);
        const first = transport.connections[handle.index].recv.?;
        const op = &transport.operations[first];
        transport.unschedule(first);
        op.submitted = true;
        transport.pause(std.testing.io, true);
        try std.testing.expectEqual(@as(?usize, first), transport.pending_head);
        transport.unschedule(first);
        op.cancel_requested = true;
        op.cancel_pending = true;
        const cancel: linux.io_uring_cqe = .{ .user_data = Ring.cancelTag(first), .res = 0, .flags = 0 };
        const receive: linux.io_uring_cqe = .{ .user_data = first, .res = -@as(i32, @intFromEnum(linux.E.CANCELED)), .flags = 0 };
        transport.complete(if (cancel_first) cancel else receive);
        try std.testing.expectEqual(transport.operations.len - 1, transport.free_operations);
        if (!cancel_first) {
            try transport.queueReceive(std.testing.io, handle, bytes[1..]);
            const next = transport.connections[handle.index].recv.?;
            try std.testing.expect(next != first);
            transport.complete(cancel);
            try std.testing.expectEqual(@as(?usize, next), transport.connections[handle.index].recv);
            try std.testing.expectEqual(bytes[1..].ptr, transport.operations[next].bytes.ptr);
            transport.close(std.testing.io, handle, .peer_closed);
        } else {
            transport.complete(receive);
            try std.testing.expectEqual(transport.operations.len, transport.free_operations);
            try transport.queueReceive(std.testing.io, handle, bytes[1..]);
            try std.testing.expectEqual(@as(?usize, first), transport.connections[handle.index].recv);
            transport.close(std.testing.io, handle, .peer_closed);
        }
        try std.testing.expectEqual(transport.operations.len, transport.free_operations);
        try std.testing.expect(transport.pending_head == null and transport.pending_tail == null);
    }
}

test "completion removes a cancellation that has not been submitted" {
    var sockets: [2]posix.fd_t = undefined;
    try std.testing.expectEqual(.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0, &sockets)));
    defer fdClose(sockets[1]);
    var transport = try Ring.init(std.testing.allocator, std.testing.io, .{ .connections = 1, .address = .{ .ip4 = .loopback(0) } });
    defer transport.deinit(std.testing.io);
    const handle = try transport.adopt(sockets[0]);
    var input: [1]u8 = undefined;
    const output = "x";
    const vectors = [_]posix.iovec_const{.{ .base = output.ptr, .len = output.len }};
    try transport.queueReceive(std.testing.io, handle, &input);
    try transport.queueSend(std.testing.io, handle, &vectors);
    const receiving = transport.connections[handle.index].recv.?;
    transport.unschedule(receiving);
    transport.operations[receiving].submitted = true;
    transport.pause(std.testing.io, true);
    try std.testing.expectEqual(@as(?usize, receiving), transport.pending_tail);
    transport.complete(.{ .user_data = receiving, .res = 1, .flags = 0 });
    try std.testing.expectEqual(transport.operations.len - 1, transport.free_operations);
    try std.testing.expectEqual(transport.pending_head, transport.pending_tail);
    transport.close(std.testing.io, handle, .peer_closed);
    try std.testing.expectEqual(transport.operations.len, transport.free_operations);
    try std.testing.expect(transport.pending_head == null and transport.pending_tail == null);
}
