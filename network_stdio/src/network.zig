const std = @import("std");
const builtin = @import("builtin");
const network = @import("networking");

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
        mutex: std.Io.Mutex = .init,
        tasks: std.Io.Group = .init,
        accept_tasks: std.Io.Group = .init,
        accepting: bool = true,
        wake: std.Io.Event = .unset,
        accept_pending: bool = false,
        notified: bool = false,

        pub fn init(io: std.Io, configuration: Configuration) !Self {
            var address = configuration.address;
            if (builtin.os.tag == .linux)
                if (configuration.inherited_listener) |fd|
                    return .{ .listener = .{ .socket = .{ .handle = fd, .address = address }, .options = {} } };

            return .{ .listener = try address.listen(io, .{ .kernel_backlog = configuration.backlog, .reuse_address = true }) };
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.tasks.cancel(io);
            self.accept_tasks.cancel(io);

            if (self.listener) |*listener|
                listener.deinit(io);

            for (&self.connections) |*item|
                if (item.state != .free and !item.stream_closed)
                    item.stream.close(io);

            self.* = undefined;
        }

        pub fn transport(self: *Self) network.Transport {
            return .{
                .context = self,
                .vtable = network.Transport.adapter(Self),
                .inheritance = if (builtin.os.tag == .linux) .{
                    .context = self,
                    .pause = pauseAccept,
                    .ready = paused,
                    .listener = listenerDescriptor,
                    .descriptor = descriptor,
                    .adopt = adopt,
                } else null,
            };
        }

        fn pauseAccept(context: *anyopaque, io: std.Io, pause: bool) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.mutex.lockUncancelable(io);
            self.accepting = !pause;
            self.mutex.unlock(io);

            if (pause)
                self.accept_tasks.cancel(io);
        }

        fn paused(context: *anyopaque) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return !self.accepting and !self.accept_pending;
        }

        fn listenerDescriptor(context: *anyopaque) i32 {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.listener.?.socket.handle;
        }

        fn descriptor(context: *anyopaque, handle: network.Handle) i32 {
            const self: *Self = @ptrCast(@alignCast(context));
            const item = self.connection(handle).?;
            assert(item.receive == null and item.send == null);
            return item.stream.socket.handle;
        }

        fn adopt(context: *anyopaque, fd: i32) !network.Handle {
            const self: *Self = @ptrCast(@alignCast(context));
            const index = self.freeConnection() orelse return error.Full;
            assert(fd >= 0 and self.connections[index].generation == 0);
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

        pub fn close(self: *Self, io: std.Io, handle: network.Handle, reason: network.CloseReason) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            if (self.connection(handle)) |item| {
                item.close = reason;
                item.state = .closing;
                item.stream.shutdown(io, .both) catch {};
                self.wake.set(io);
            }
        }

        pub fn releaseConnection(self: *Self, io: std.Io, handle: network.Handle) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const item = &self.connections[handle.index];
            assert(item.state == .closed and item.generation == handle.generation);
            assert(item.receive == null and item.send == null and item.stream_closed);
            item.* = .{ .generation = item.generation };
        }

        pub fn notify(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.notified = true;
            self.wake.set(io);
        }

        pub fn poll(self: *Self, io: std.Io, timeout: ?std.Io.Timeout, destination: []network.Event) !usize {
            assert(destination.len != 0);
            const deadline = (timeout orelse @as(std.Io.Timeout, .none)).toDeadline(io);

            while (true) {
                self.scheduleAccept(io);
                self.mutex.lockUncancelable(io);
                self.finishCloses(io);

                const count = @min(destination.len, self.event_count);

                for (destination[0..count]) |*event| {
                    event.* = self.events[self.event_head];
                    self.event_head = (self.event_head + 1) % limits.events;
                }

                self.event_count -= count;
                const notified = self.notified;
                self.notified = false;

                if (self.event_count == 0)
                    self.wake.reset();

                self.mutex.unlock(io);

                if (count != 0 or notified)
                    return count;

                self.wake.waitTimeout(io, deadline) catch |err| switch (err) {
                    error.Timeout => return 0,
                    else => return err,
                };
            }
        }

        fn start(self: *Self, io: std.Io, handle: network.Handle, kind: Kind, bytes: []u8) network.QueueError!void {
            self.mutex.lockUncancelable(io);
            const index = self.queue(handle, kind, bytes) catch |err| {
                self.mutex.unlock(io);
                return err;
            };
            self.mutex.unlock(io);

            self.tasks.concurrent(io, operationTask, .{ self, io, index }) catch {
                self.mutex.lockUncancelable(io);
                self.release(index);
                self.mutex.unlock(io);
                return error.Full;
            };
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

        fn operationTask(self: *Self, io: std.Io, index: usize) std.Io.Cancelable!void {
            self.mutex.lockUncancelable(io);
            const operation = &self.operations[index];
            const item = self.owner(operation.handle).?;
            const stream = item.stream;
            const handle = operation.handle;
            const kind = operation.kind;
            const bytes = operation.bytes;
            self.mutex.unlock(io);

            var result: network.Result = .{ .bytes = 0 };
            var failed = false;

            switch (kind) {
                .receive => {
                    var buffers: [1][]u8 = .{bytes};
                    const count = blk: {
                        break :blk io.vtable.netRead(io.userdata, stream.socket.handle, &buffers) catch {
                            failed = true;
                            break :blk 0;
                        };
                    };
                    result = .{
                        .bytes = count,
                        .errno = if (failed or count == 0) 1 else null,
                    };
                },
                .send => {
                    const data: [1][]const u8 = .{bytes};
                    const count = io.vtable.netWrite(io.userdata, stream.socket.handle, &.{}, &data, 1) catch blk: {
                        failed = true;
                        break :blk 0;
                    };
                    assert(count <= bytes.len);
                    result = .{
                        .bytes = count,
                        .errno = if (failed or count == 0) 1 else null,
                    };
                },
            }

            self.mutex.lockUncancelable(io);
            if (!self.operations[index].used) {
                self.mutex.unlock(io);
                return;
            }

            self.push(switch (kind) {
                .receive => .{ .received = .{ .handle = handle, .result = result } },
                .send => .{ .sent = .{ .handle = handle, .result = result } },
            });
            self.wake.set(io);
            self.release(index);

            if (result.errno != null) {
                if (self.connection(handle)) |live| {
                    live.state = .closing;
                    live.close = if (kind == .receive) .peer_closed else .io_failure;
                    live.stream.shutdown(io, .both) catch {};
                }
            }

            self.mutex.unlock(io);
        }

        fn scheduleAccept(self: *Self, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            if (!self.accepting or self.accept_pending or self.listener == null or self.freeConnection() == null) {
                self.mutex.unlock(io);
                return;
            }

            self.accept_pending = true;
            self.mutex.unlock(io);
            self.accept_tasks.concurrent(io, acceptTask, .{ self, io }) catch {
                self.mutex.lockUncancelable(io);
                self.accept_pending = false;
                self.mutex.unlock(io);
            };
        }

        fn acceptTask(self: *Self, io: std.Io) std.Io.Cancelable!void {
            self.mutex.lockUncancelable(io);
            var server = self.listener orelse {
                self.accept_pending = false;
                self.mutex.unlock(io);
                return;
            };
            self.mutex.unlock(io);
            const stream = server.accept(io) catch {
                self.mutex.lockUncancelable(io);
                self.accept_pending = false;
                self.mutex.unlock(io);
                return;
            };
            self.mutex.lockUncancelable(io);
            self.accept_pending = false;

            if (self.freeConnection()) |index| {
                var generation = self.connections[index].generation +% 1;
                if (generation == 0)
                    generation = 1;

                self.connections[index] = .{ .state = .open, .stream = stream, .generation = generation };
                self.push(.{ .accepted = .{ .index = @intCast(index), .generation = generation } });
                self.wake.set(io);
            } else stream.close(io);
            self.mutex.unlock(io);
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
                if (item.state != .closing or item.receive != null or item.send != null)
                    continue;

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

        pub fn submit(_: *Self, _: std.Io) !void {}
    };
}
