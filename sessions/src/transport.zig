const std = @import("std");
const network = @import("networking");
const ring = @import("transport_ring.zig");
const linux = std.os.linux;
const assert = std.debug.assert;

pub const Configuration = ring.Configuration;

pub const Transport = struct {
    allocator: std.mem.Allocator,
    rings: []ring.Ring,
    coordinator: ?linux.IoUring = null,
    capacity: usize,
    connections_per_ring: usize,
    next_ring: usize = 0,
    aborted: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) !Transport {
        const group_capacity = @as(usize, std.math.maxInt(u16)) + 1;
        if (config.connections == 0) return error.InvalidSessionCapacity;
        if (config.connections_per_ring == 0 or config.connections_per_ring > group_capacity) return error.InvalidConfiguration;
        const count = config.connections / config.connections_per_ring + @intFromBool(config.connections % config.connections_per_ring != 0);
        const rings = try allocator.alloc(ring.Ring, count);
        errdefer allocator.free(rings);
        var initialized: usize = 0;
        errdefer for (rings[0..initialized]) |*instance| instance.deinit(io);
        for (rings, 0..) |*instance, index| {
            var selected = config;
            selected.connections = @min(config.connections_per_ring, config.connections - index * config.connections_per_ring);
            if (index != 0) selected.inherited_listener = try duplicate(rings[0].listenerDescriptor());
            instance.* = ring.Ring.init(allocator, io, selected) catch |err| {
                if (index != 0) _ = linux.close(selected.inherited_listener.?);
                return err;
            };
            initialized += 1;
        }
        var self: Transport = .{ .allocator = allocator, .rings = rings, .capacity = config.connections, .connections_per_ring = config.connections_per_ring };
        if (count > 1) {
            self.coordinator = try linux.IoUring.init(config.ring_entries, 0);
            errdefer self.coordinator.?.deinit();
            for (0..count) |index| try self.arm(index);
        }
        return self;
    }

    pub fn deinit(self: *Transport, io: std.Io) void {
        if (!self.aborted) if (self.coordinator) |*coordinator| coordinator.deinit();
        for (self.rings) |*instance| instance.deinit(io);
        self.allocator.free(self.rings);
        self.* = undefined;
    }

    pub fn abort(self: *Transport) void {
        assert(!self.aborted);
        if (self.coordinator) |*coordinator| coordinator.deinit();
        for (self.rings) |*instance| instance.abort();
        self.aborted = true;
    }

    pub fn transport(self: *Transport) network.Transport {
        return .{ .context = self, .vtable = network.Transport.adapter(Transport), .inheritance = network.Inheritance.init(Transport, self) };
    }

    pub fn pause(self: *Transport, io: std.Io, enabled: bool) void {
        for (self.rings) |*instance| instance.pause(io, enabled);
    }

    pub fn paused(self: *Transport) bool {
        for (self.rings) |*instance| if (!instance.paused()) return false;
        return true;
    }

    pub fn listenerDescriptor(self: *Transport) i32 {
        return self.rings[0].listenerDescriptor();
    }

    pub fn descriptor(self: *Transport, handle: network.Handle) i32 {
        const selected = self.locate(handle);
        return self.rings[selected.ring].descriptor(selected.handle);
    }

    pub fn adopt(self: *Transport, fd: i32) !network.Handle {
        if (fd < 0) return error.InvalidDescriptor;
        for (self.rings) |*instance| {
            if (fd == instance.listenerDescriptor()) return error.InvalidDescriptor;
            if (instance.descriptors.contains(fd)) return error.InvalidDescriptor;
        }
        for (self.rings, 0..) |*instance, index| {
            if (instance.free_connection == null) continue;
            var handle = try instance.adopt(fd);
            handle.index += index * self.connections_per_ring;
            assert(handle.index < self.capacity);
            return handle;
        }
        return error.Full;
    }

    pub fn queueReceive(self: *Transport, io: std.Io, handle: network.Handle, bytes: []u8) network.QueueError!void {
        if (handle.index >= self.capacity) return error.InvalidHandle;
        const selected = self.locate(handle);
        return self.rings[selected.ring].queueReceive(io, selected.handle, bytes);
    }

    pub fn queueSend(self: *Transport, io: std.Io, handle: network.Handle, vectors: []const std.posix.iovec_const) network.QueueError!void {
        if (handle.index >= self.capacity) return error.InvalidHandle;
        const selected = self.locate(handle);
        return self.rings[selected.ring].queueSend(io, selected.handle, vectors);
    }

    pub fn close(self: *Transport, io: std.Io, handle: network.Handle, reason: network.CloseReason) void {
        if (handle.index >= self.capacity) return;
        const selected = self.locate(handle);
        self.rings[selected.ring].close(io, selected.handle, reason);
    }

    pub fn releaseConnection(self: *Transport, io: std.Io, handle: network.Handle) void {
        const selected = self.locate(handle);
        self.rings[selected.ring].releaseConnection(io, selected.handle);
    }

    pub fn notify(self: *Transport, io: std.Io) void {
        self.rings[0].notify(io);
    }

    pub fn submit(self: *Transport, io: std.Io) !void {
        for (self.rings) |*instance| try instance.submit(io);
        if (self.coordinator) |*coordinator| if (coordinator.sq_ready() != 0) {
            _ = try coordinator.submit();
        };
    }

    pub fn poll(self: *Transport, io: std.Io, deadline: ?std.Io.Timeout, output: []network.Event) !usize {
        assert(output.len != 0);
        if (self.coordinator == null) return self.rings[0].poll(io, deadline, output);
        const notices = try self.reap();
        const ready = try self.pollReady(io, output);
        if (ready.count != 0 or ready.completed or notices != 0 or self.paused()) return ready.count;
        try self.wait(io, deadline);
        _ = try self.reap();
        return (try self.pollReady(io, output)).count;
    }

    fn locate(self: *const Transport, handle: network.Handle) struct { ring: usize, handle: network.Handle } {
        assert(handle.index < self.capacity);
        return .{ .ring = handle.index / self.connections_per_ring, .handle = .{ .index = handle.index % self.connections_per_ring, .generation = handle.generation } };
    }

    fn pollReady(self: *Transport, io: std.Io, output: []network.Event) !struct { count: usize, completed: bool } {
        var count: usize = 0;
        var completed = false;
        var visited: usize = 0;
        while (visited < self.rings.len) : (visited += 1) {
            const index = self.next_ring;
            self.next_ring = if (index + 1 == self.rings.len) 0 else index + 1;
            const instance = &self.rings[index];
            const batch = try instance.pollReady(io, output[count..]);
            const offset = index * self.connections_per_ring;
            for (output[count..][0..batch.count]) |*event| switch (event.*) {
                .accepted => |*handle| handle.index += offset,
                .received, .sent => |*completion| completion.handle.index += offset,
                .closed => |*closure| closure.handle.index += offset,
            };
            count += batch.count;
            completed = completed or batch.completed != 0;
            if (count == output.len) break;
        }
        return .{ .count = count, .completed = completed };
    }

    fn arm(self: *Transport, index: usize) !void {
        const coordinator = &self.coordinator.?;
        const sqe = coordinator.poll_add(index, self.rings[index].ring.fd, linux.POLL.IN) catch blk: {
            _ = try coordinator.submit();
            break :blk try coordinator.poll_add(index, self.rings[index].ring.fd, linux.POLL.IN);
        };
        sqe.len = linux.IORING_POLL_ADD_MULTI;
    }

    fn reap(self: *Transport) !usize {
        var entries: [64]linux.io_uring_cqe = undefined;
        const count = try self.coordinator.?.copy_cqes(&entries, 0);
        for (entries[0..count]) |entry| {
            if (entry.res < 0) return error.RingFailure;
            assert(entry.user_data < self.rings.len);
            if (entry.flags & linux.IORING_CQE_F_MORE == 0) try self.arm(@intCast(entry.user_data));
        }
        return count;
    }

    fn wait(self: *Transport, io: std.Io, deadline: ?std.Io.Timeout) !void {
        var timeout: linux.kernel_timespec = undefined;
        var arguments: linux.io_uring_getevents_arg = .{ .sigmask = 0, .sigmask_sz = 0, .pad = 0, .ts = 0 };
        if (deadline) |value| if (value.toDurationFromNow(io)) |duration| {
            const ns = @max(@as(i96, 0), duration.raw.nanoseconds);
            timeout = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
            arguments.ts = @intFromPtr(&timeout);
        };
        const coordinator = &self.coordinator.?;
        const submitted = coordinator.flush_sq();
        const result = linux.syscall6(.io_uring_enter, @intCast(coordinator.fd), submitted, 1, linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG, @intFromPtr(&arguments), @sizeOf(linux.io_uring_getevents_arg));
        switch (linux.errno(result)) {
            .SUCCESS, .TIME, .INTR => {},
            else => return error.RingFailure,
        }
    }
};

fn duplicate(fd: i32) !i32 {
    while (true) {
        const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
        switch (linux.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            else => return error.DescriptorUnavailable,
        }
    }
}
