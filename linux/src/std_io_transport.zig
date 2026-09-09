const std = @import("std");
const lightning_rod = @import("lightning_rod");
const exchange = lightning_rod.transport;
const runtime = lightning_rod.runtime;

pub const Limits = struct {
    connections: usize,
    input_pages: usize,
    page_bytes: usize,
    output_pages: usize,
    output_page_bytes: usize,
    output_pages_per_connection: usize,
    event_capacity: usize,
    completion_batch: usize,
};

pub const Configuration = struct {
    address: std.Io.net.IpAddress,
    backlog: u31 = std.Io.net.default_kernel_backlog,
};

pub fn Transport(comptime limits: Limits) type {
    validateLimits(limits);
    return struct {
        const Self = @This();
        const ConnectionState = enum { free, open, closing };
        const InputState = enum { free, receiving, ready };
        const output_capacity = limits.output_pages_per_connection * limits.output_page_bytes;
        const Connection = struct {
            state: ConnectionState = .free,
            stream: std.Io.net.Stream = undefined,
            generation: u32 = 0,
            accepted: bool = false,
            recv_pending: bool = false,
            send_pending: bool = false,
            close_announced: bool = false,
            close_reason: exchange.DisconnectReason = .transport_error,
            input_page: ?u16 = null,
            output_head: ?u16 = null,
            output_tail: ?u16 = null,
            output_pages: u16 = 0,
            output_len: usize = 0,
        };
        const InputPage = struct {
            state: InputState = .free,
            owner: u16 = 0,
            generation: u32 = 0,
            len: u16 = 0,
        };
        const OutputPage = struct { next: ?u16 = null, start: usize = 0, end: usize = 0 };

        io: std.Io,
        listener: ?std.Io.net.Server,
        mutex: std.Io.Mutex = .init,
        tasks: std.Io.Group = .init,
        readiness: ?runtime.Wake = null,
        connections: [limits.connections]Connection = @splat(.{}),
        input: [limits.input_pages]InputPage = @splat(.{}),
        input_bytes: [limits.input_pages][limits.page_bytes]u8 = undefined,
        output: [limits.output_pages]OutputPage = @splat(.{}),
        output_bytes: [limits.output_pages][limits.output_page_bytes]u8 = undefined,
        free_output: [limits.output_pages]u16 = undefined,
        free_output_count: usize = limits.output_pages,
        next_send: u16 = 0,
        free_input: [limits.input_pages]u16 = undefined,
        free_input_count: usize = limits.input_pages,
        events: [limits.event_capacity]exchange.TransportEvent = undefined,
        event_head: usize = 0,
        event_count: usize = 0,
        accept_pending: bool = false,
        active_tasks: usize = 0,
        completed_tasks: usize = 0,
        stopping: bool = false,
        faulted: bool = false,

        pub fn init(io: std.Io, configuration: Configuration) !Self {
            var address = configuration.address;
            var self = stateOnly(io);
            self.listener = try address.listen(io, .{ .kernel_backlog = configuration.backlog });
            return self;
        }

        fn stateOnly(io: std.Io) Self {
            var self: Self = .{ .io = io, .listener = null };
            for (&self.free_input, 0..) |*slot, index| slot.* = @intCast(index);
            for (&self.free_output, 0..) |*slot, index| slot.* = @intCast(index);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.tasks.cancel(self.io);
            if (self.listener) |*listener| listener.deinit(self.io);
            self.* = undefined;
        }

        pub fn transport(self: *Self) exchange.Transport {
            return .{ .context = self, .vtable = &transport_vtable };
        }

        pub fn backend(self: *Self) runtime.Backend {
            return .{ .context = self, .vtable = &backend_vtable, .readiness = .{ .context = self, .bind_fn = bindReadiness } };
        }

        fn raw(context: *anyopaque) *Self {
            return @ptrCast(@alignCast(context));
        }

        fn bindReadiness(context: *anyopaque, wake: runtime.Wake) runtime.Outcome {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.readiness != null) return .failed;
            self.readiness = wake;
            return .ok;
        }

        fn transportComplete(context: *anyopaque, destination: []exchange.TransportEvent) usize {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const count = @min(destination.len, self.event_count);
            for (destination[0..count]) |*event| {
                event.* = self.events[self.event_head];
                self.event_head = (self.event_head + 1) % limits.event_capacity;
                switch (event.*) {
                    .accepted => |identity| self.connections[identity.index].accepted = true,
                    else => {},
                }
            }
            self.event_count -= count;
            return count;
        }

        fn inputPage(context: *anyopaque, id: exchange.Page) ?exchange.InputPage {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const index = inputIndex(id) orelse return null;
            const page = self.input[index];
            if (page.state != .ready) return null;
            return .{ .id = id, .bytes = self.input_bytes[index][0..page.len] };
        }

        fn outputCredit(context: *anyopaque, identity: exchange.Connection) usize {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.openConnection(identity) orelse return 0;
            return self.outputCreditFor(connection);
        }

        fn outputMetrics(context: *anyopaque, identity: exchange.Connection) ?exchange.OutputMetrics {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.openConnection(identity) orelse return null;
            return .{ .queued_bytes = connection.output_len, .capacity_bytes = output_capacity };
        }

        fn write(context: *anyopaque, identity: exchange.Connection, bytes: []const u8) bool {
            const self = raw(context);
            if (bytes.len == 0 or bytes.len > output_capacity) return false;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.openConnection(identity) orelse return false;
            if (bytes.len > self.outputCreditFor(connection)) return false;
            self.writeOutput(connection, bytes);
            return true;
        }

        fn releaseInput(context: *anyopaque, id: exchange.Page) void {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const index = inputIndex(id) orelse return;
            const page = self.input[index];
            if (page.state != .ready) return;
            self.input[index] = .{};
            self.free_input[self.free_input_count] = @intCast(index);
            self.free_input_count += 1;
            const connection = &self.connections[page.owner];
            if (connection.generation == page.generation and connection.input_page == index) connection.input_page = null;
            self.finishClose(@intCast(page.owner));
        }

        fn close(context: *anyopaque, identity: exchange.Connection, reason: exchange.DisconnectReason) void {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (identity.index >= limits.connections) return;
            const connection = &self.connections[identity.index];
            if (connection.state != .open or connection.generation != identity.generation) return;
            self.requestClose(@intCast(identity.index), reason);
        }

        fn transportSubmit(context: *anyopaque) void {
            _ = backendSubmit(context, raw(context).io);
        }

        fn backendComplete(context: *anyopaque, _: std.Io, budget: usize) runtime.Completion {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const count = @min(@min(budget, limits.completion_batch), self.completed_tasks);
            self.completed_tasks -= count;
            return .{ .count = count, .outcome = if (self.faulted) .failed else .ok };
        }

        fn backendSubmit(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self = raw(context);
            var start_accept = false;
            var reads: [limits.connections]Task = undefined;
            var writes: [limits.connections]Task = undefined;
            var read_count: usize = 0;
            var write_count: usize = 0;
            self.mutex.lockUncancelable(self.io);
            if (self.faulted) {
                self.mutex.unlock(self.io);
                return .failed;
            }
            if (!self.stopping and self.listener != null and !self.accept_pending and self.freeConnection() != null) {
                self.accept_pending = true;
                self.active_tasks += 1;
                start_accept = true;
            }
            for (&self.connections, 0..) |*connection, index| {
                if (connection.state != .open) continue;
                if (connection.state == .open and !connection.recv_pending and connection.input_page == null and self.free_input_count != 0) {
                    self.free_input_count -= 1;
                    const page = self.free_input[self.free_input_count];
                    self.input[page] = .{ .state = .receiving, .owner = @intCast(index), .generation = connection.generation };
                    connection.input_page = page;
                    connection.recv_pending = true;
                    self.active_tasks += 1;
                    reads[read_count] = .{ .index = @intCast(index), .generation = connection.generation, .page = page };
                    read_count += 1;
                }
            }
            const first = self.next_send;
            self.next_send +%= 1;
            if (self.next_send == limits.connections) self.next_send = 0;
            var considered: usize = 0;
            while (considered < limits.connections) : (considered += 1) {
                const index: u16 = @intCast((@as(usize, first) + considered) % limits.connections);
                const connection = &self.connections[index];
                if (connection.state != .open or connection.send_pending or connection.output_len == 0) continue;
                connection.send_pending = true;
                self.active_tasks += 1;
                writes[write_count] = .{ .index = index, .generation = connection.generation, .page = 0 };
                write_count += 1;
            }
            self.mutex.unlock(self.io);
            var launch_failed = false;
            if (start_accept) {
                self.tasks.concurrent(self.io, acceptTask, .{self}) catch {
                    launch_failed = true;
                };
            }
            for (reads[0..read_count]) |task| {
                self.tasks.concurrent(self.io, readTask, .{ self, task }) catch {
                    launch_failed = true;
                };
            }
            for (writes[0..write_count]) |task| {
                self.tasks.concurrent(self.io, writeTask, .{ self, task }) catch {
                    launch_failed = true;
                };
            }
            if (launch_failed) {
                self.mutex.lockUncancelable(self.io);
                self.faulted = true;
                self.mutex.unlock(self.io);
            }
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return if (self.faulted) .failed else .ok;
        }

        fn beginShutdown(context: *anyopaque, _: std.Io) runtime.Outcome {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            if (self.stopping) {
                self.mutex.unlock(self.io);
                return if (self.faulted) .failed else .ok;
            }
            self.stopping = true;
            if (self.listener) |*listener| listener.deinit(self.io);
            self.listener = null;
            for (0..limits.connections) |index| {
                const connection = &self.connections[index];
                if (connection.state != .open) continue;
                self.requestClose(@intCast(index), .server_shutdown);
            }
            self.mutex.unlock(self.io);
            return .ok;
        }

        fn shutdownProgress(context: *anyopaque) runtime.Progress {
            const self = raw(context);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.faulted) return .failed;
            if (!self.stopping or self.active_tasks != 0 or self.listener != null) return .pending;
            for (self.connections) |connection| if (connection.state != .free) return .pending;
            return .complete;
        }

        const Task = struct { index: u16, generation: u32, page: u16 };

        fn acceptTask(self: *Self) std.Io.Cancelable!void {
            var listener = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                break :blk self.listener orelse {
                    self.completeTask();
                    return;
                };
            };
            const stream = listener.accept(self.io) catch {
                self.mutex.lockUncancelable(self.io);
                self.accept_pending = false;
                self.completeTask();
                self.mutex.unlock(self.io);
                return;
            };
            self.mutex.lockUncancelable(self.io);
            self.accept_pending = false;
            if (self.stopping) {
                stream.close(self.io);
            } else if (self.freeConnection()) |index| {
                self.admitConnection(index, stream);
            } else {
                stream.close(self.io);
            }
            self.completeTask();
            self.mutex.unlock(self.io);
        }

        fn readTask(self: *Self, task: Task) std.Io.Cancelable!void {
            const stream = self.taskStream(task) orelse return;
            var scratch: [0]u8 = .{};
            var reader = stream.reader(self.io, &scratch);
            const result = reader.interface.readSliceShort(&self.input_bytes[task.page]);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.taskConnection(task) orelse {
                self.completeTask();
                return;
            };
            connection.recv_pending = false;
            const page = &self.input[task.page];
            if (connection.state != .open) {
                self.discardInput(task.page);
                self.finishClose(task.index);
                self.completeTask();
                return;
            }
            if (result) |count| {
                if (count == 0 or page.state != .receiving) {
                    self.discardInput(task.page);
                    self.requestClose(task.index, .peer_closed);
                } else {
                    page.len = @intCast(count);
                    page.state = .ready;
                    self.pushEvent(.{ .received = .{ .connection = self.handle(task.index), .page = .{ .id = inputId(task.page), .bytes = self.input_bytes[task.page][0..count] } } });
                }
            } else |_| {
                self.discardInput(task.page);
                self.requestClose(task.index, .peer_closed);
            }
            self.completeTask();
        }

        fn writeTask(self: *Self, task: Task) std.Io.Cancelable!void {
            const stream = self.taskStream(task) orelse return;
            const bytes = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const connection = self.taskConnection(task) orelse {
                    self.completeTask();
                    return;
                };
                break :blk self.outputHead(connection);
            };
            var scratch: [0]u8 = .{};
            var writer = stream.writer(self.io, &scratch);
            const result = writer.interface.write(bytes);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.taskConnection(task) orelse {
                self.completeTask();
                return;
            };
            connection.send_pending = false;
            if (connection.state == .closing) {
                self.releaseOutput(connection);
                self.finishClose(task.index);
                self.completeTask();
                return;
            }
            if (result) |count| {
                if (!self.consumeOutput(connection, count)) self.abandonClose(task.index, .transport_error);
            } else |_| self.abandonClose(task.index, .transport_error);
            self.completeTask();
        }

        fn taskStream(self: *Self, task: Task) ?std.Io.net.Stream {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const connection = self.taskConnection(task) orelse {
                self.completeTask();
                return null;
            };
            return connection.stream;
        }

        fn taskConnection(self: *Self, task: Task) ?*Connection {
            if (task.index >= limits.connections) return null;
            const connection = &self.connections[task.index];
            if (connection.state == .free or connection.generation != task.generation) return null;
            return connection;
        }

        fn completeTask(self: *Self) void {
            std.debug.assert(self.active_tasks != 0);
            self.active_tasks -= 1;
            self.completed_tasks += 1;
            const wake = self.readiness;
            if (wake) |value| value.signal();
        }

        fn requestClose(self: *Self, index: u16, reason: exchange.DisconnectReason) void {
            const connection = &self.connections[index];
            if (connection.state != .open) return;
            connection.state = .closing;
            connection.close_reason = reason;
            connection.stream.close(self.io);
            if (!connection.send_pending) self.releaseOutput(connection);
            self.finishClose(index);
        }

        fn abandonClose(self: *Self, index: u16, reason: exchange.DisconnectReason) void {
            const connection = &self.connections[index];
            if (connection.state == .free) return;
            if (connection.state == .open) {
                connection.state = .closing;
                connection.stream.close(self.io);
            }
            connection.close_reason = reason;
            self.releaseOutput(connection);
            self.finishClose(index);
        }

        fn finishClose(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .closing or connection.recv_pending or connection.send_pending) return;
            std.debug.assert(connection.output_len == 0);
            if (!connection.close_announced) {
                connection.close_announced = true;
                self.pushEvent(.{ .closed = .{ .connection = self.handle(index), .reason = connection.close_reason } });
            }
            if (connection.input_page != null) return;
            connection.* = .{ .generation = connection.generation };
        }

        fn admitConnection(self: *Self, index: u16, stream: std.Io.net.Stream) void {
            var generation = self.connections[index].generation +% 1;
            if (generation == 0) generation = 1;
            self.connections[index] = .{ .state = .open, .stream = stream, .generation = generation };
            self.pushEvent(.{ .accepted = self.handle(index) });
        }

        fn freeConnection(self: *const Self) ?u16 {
            for (self.connections, 0..) |connection, index| if (connection.state == .free) return @intCast(index);
            return null;
        }

        fn openConnection(self: *Self, identity: exchange.Connection) ?*Connection {
            if (identity.index >= limits.connections) return null;
            const connection = &self.connections[identity.index];
            if (connection.state != .open or connection.generation != identity.generation) return null;
            return connection;
        }

        fn handle(self: *const Self, index: u16) exchange.Connection {
            return .{ .index = index, .generation = self.connections[index].generation };
        }

        fn pushEvent(self: *Self, event: exchange.TransportEvent) void {
            if (self.event_count == limits.event_capacity) {
                self.faulted = true;
                return;
            }
            const tail = (self.event_head + self.event_count) % limits.event_capacity;
            self.events[tail] = event;
            self.event_count += 1;
        }

        fn discardInput(self: *Self, index: u16) void {
            const page = self.input[index];
            if (page.state == .free) return;
            self.input[index] = .{};
            self.free_input[self.free_input_count] = index;
            self.free_input_count += 1;
            const connection = &self.connections[page.owner];
            if (connection.generation == page.generation and connection.input_page == index) connection.input_page = null;
        }

        fn inputIndex(id: exchange.Page) ?u16 {
            const value = @intFromEnum(id);
            if (value >= limits.input_pages) return null;
            return @intCast(value);
        }

        fn inputId(index: u16) exchange.Page {
            return @enumFromInt(index);
        }

        fn outputCreditFor(self: *const Self, connection: *const Connection) usize {
            const pages = limits.output_pages_per_connection - @as(usize, connection.output_pages);
            const tail_free = if (connection.output_tail) |page| limits.output_page_bytes - self.output[page].end else 0;
            return tail_free + @min(pages, self.free_output_count) * limits.output_page_bytes;
        }

        fn outputHead(self: *const Self, connection: *const Connection) []const u8 {
            const page = connection.output_head orelse unreachable;
            const item = self.output[page];
            std.debug.assert(item.start < item.end);
            return self.output_bytes[page][item.start..item.end];
        }

        fn writeOutput(self: *Self, connection: *Connection, source: []const u8) void {
            std.debug.assert(source.len <= self.outputCreditFor(connection));
            var start: usize = 0;
            while (start < source.len) {
                const page = self.ensureOutputTail(connection);
                const item = &self.output[page];
                const end = item.end;
                const count = @min(source.len - start, limits.output_page_bytes - end);
                @memcpy(self.output_bytes[page][end..][0..count], source[start..][0..count]);
                item.end = end + count;
                connection.output_len += count;
                start += count;
            }
        }

        fn ensureOutputTail(self: *Self, connection: *Connection) u16 {
            if (connection.output_tail) |page| {
                if (self.output[page].end < limits.output_page_bytes) return page;
            }
            const page = self.takeOutputPage() orelse unreachable;
            if (connection.output_tail) |tail| self.output[tail].next = page else connection.output_head = page;
            connection.output_tail = page;
            connection.output_pages += 1;
            return page;
        }

        fn takeOutputPage(self: *Self) ?u16 {
            if (self.free_output_count == 0) return null;
            self.free_output_count -= 1;
            const page = self.free_output[self.free_output_count];
            self.output[page] = .{};
            return page;
        }

        fn returnOutputPage(self: *Self, page: u16) void {
            self.output[page] = .{};
            self.free_output[self.free_output_count] = page;
            self.free_output_count += 1;
        }

        fn consumeOutput(self: *Self, connection: *Connection, written: usize) bool {
            const page = connection.output_head orelse return false;
            const item = &self.output[page];
            const offered: usize = item.end - item.start;
            if (written == 0 or written > offered) return false;
            item.start += written;
            connection.output_len -= written;
            if (item.start != item.end) return true;
            connection.output_head = item.next;
            if (connection.output_tail != null and connection.output_tail.? == page) connection.output_tail = null;
            connection.output_pages -= 1;
            self.returnOutputPage(page);
            return true;
        }

        fn releaseOutput(self: *Self, connection: *Connection) void {
            std.debug.assert(!connection.send_pending);
            while (connection.output_head) |page| {
                connection.output_head = self.output[page].next;
                self.returnOutputPage(page);
            }
            connection.output_tail = null;
            connection.output_pages = 0;
            connection.output_len = 0;
        }

        const transport_vtable: exchange.Transport.VTable = .{
            .complete = transportComplete,
            .input_page = inputPage,
            .output_credit = outputCredit,
            .output_metrics = outputMetrics,
            .write = write,
            .release_input = releaseInput,
            .close = close,
            .submit = transportSubmit,
        };
        const backend_vtable: runtime.Backend.VTable = .{
            .complete = backendComplete,
            .submit = backendSubmit,
            .begin_shutdown = beginShutdown,
            .shutdown_progress = shutdownProgress,
        };
    };
}

fn validateLimits(comptime limits: Limits) void {
    if (limits.connections == 0 or limits.connections > std.math.maxInt(u16)) @compileError("connections must fit u16");
    if (limits.input_pages < limits.connections or limits.input_pages > std.math.maxInt(u16)) @compileError("input pages must cover connections and fit u16");
    if (limits.page_bytes == 0 or limits.page_bytes > std.math.maxInt(u16)) @compileError("page bytes must fit u16");
    if (limits.output_pages == 0 or limits.output_pages > std.math.maxInt(u16)) @compileError("output pages must fit u16");
    if (limits.output_page_bytes == 0) @compileError("output page bytes must be nonzero");
    if (limits.output_pages_per_connection == 0 or limits.output_pages_per_connection > limits.output_pages) @compileError("invalid per connection output capacity");
    const required_events = limits.connections * 2 + limits.input_pages;
    if (limits.event_capacity < required_events)
        @compileError("event capacity must retain accepted, input, and closed events");
    if (limits.completion_batch == 0) @compileError("completion batch must be nonzero");
}

const test_limits: Limits = .{
    .connections = 2,
    .input_pages = 2,
    .page_bytes = 32,
    .output_pages = 4,
    .output_page_bytes = 32,
    .output_pages_per_connection = 2,
    .event_capacity = 10,
    .completion_batch = 4,
};

const shared_pool_test_limits: Limits = .{
    .connections = 2,
    .input_pages = 2,
    .page_bytes = 32,
    .output_pages = 2,
    .output_page_bytes = 32,
    .output_pages_per_connection = 2,
    .event_capacity = 10,
    .completion_batch = 4,
};

test "portable transport has bounded exchange and backend interfaces" {
    const T = Transport(test_limits);
    _ = T.transport;
    _ = T.backend;
}

test "fragmented input remains exclusively leased until Sessions releases it" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true, .input_page = 0 };
    transport.input[0] = .{ .state = .ready, .owner = 0, .generation = 1, .len = 2 };
    @memcpy(transport.input_bytes[0][0..2], "\x01\x02");
    transport.free_input[0] = 1;
    transport.free_input_count = 1;
    const page = transport.transport().vtable.input_page(transport.transport().context, @enumFromInt(0)) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualSlices(u8, "\x01\x02", page.bytes);
    try std.testing.expect(transport.transport().vtable.input_page(transport.transport().context, page.id) != null);
    transport.transport().vtable.release_input(transport.transport().context, page.id);
    try std.testing.expectEqual(@as(usize, test_limits.input_pages), transport.free_input_count);
}

test "portable transport owns a bounded shared output stream" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const api = transport.transport();
    try std.testing.expectEqual(@as(usize, 64), api.vtable.output_credit(api.context, connection));
    try std.testing.expect(api.vtable.write(api.context, connection, "test"));
    try std.testing.expectEqual(@as(usize, 4), transport.connections[0].output_len);
    try std.testing.expectEqualSlices(u8, "test", transport.outputHead(&transport.connections[0]));
}

test "partial writes retain stream bytes until completion" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const api = transport.transport();
    try std.testing.expect(api.vtable.write(api.context, connection, "test"));
    try std.testing.expect(transport.consumeOutput(&transport.connections[0], 2));
    try std.testing.expectEqual(@as(usize, 2), transport.connections[0].output_len);
    try std.testing.expectEqualSlices(u8, "st", transport.outputHead(&transport.connections[0]));
    try std.testing.expect(transport.consumeOutput(&transport.connections[0], 2));
    try std.testing.expectEqual(@as(usize, 0), transport.connections[0].output_len);
}

test "portable transport rejects a full stream without mutation" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const api = transport.transport();
    const full = [_]u8{0xaa} ** 64;
    try std.testing.expect(api.vtable.write(api.context, connection, &full));
    try std.testing.expect(!api.vtable.write(api.context, connection, "x"));
    try std.testing.expectEqual(@as(usize, 64), transport.connections[0].output_len);
}

test "one connection cannot consume the entire shared output pool" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    transport.connections[1] = .{ .state = .open, .generation = 1, .accepted = true };
    const first = exchange.Connection{ .index = 0, .generation = 1 };
    const second = exchange.Connection{ .index = 1, .generation = 1 };
    const api = transport.transport();
    const full = [_]u8{0xaa} ** 64;
    try std.testing.expect(api.vtable.write(api.context, first, &full));
    try std.testing.expectEqual(@as(usize, 0), api.vtable.output_credit(api.context, first));
    try std.testing.expectEqual(@as(usize, 64), api.vtable.output_credit(api.context, second));
}

test "a completed output page admits another connection from the shared pool" {
    const T = Transport(shared_pool_test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    transport.connections[1] = .{ .state = .open, .generation = 1, .accepted = true };
    const first = exchange.Connection{ .index = 0, .generation = 1 };
    const second = exchange.Connection{ .index = 1, .generation = 1 };
    const api = transport.transport();
    const full = [_]u8{0xaa} ** 64;
    try std.testing.expect(api.vtable.write(api.context, first, &full));
    try std.testing.expectEqual(@as(usize, 0), api.vtable.output_credit(api.context, second));
    try std.testing.expect(transport.consumeOutput(&transport.connections[0], 32));
    try std.testing.expectEqual(@as(usize, 32), api.vtable.output_credit(api.context, second));
    try std.testing.expect(api.vtable.write(api.context, second, "page"));
}

test "abandoning an idle connection releases every queued output page" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const full = [_]u8{0xaa} ** 64;
    try std.testing.expect(transport.transport().vtable.write(transport.transport().context, connection, &full));
    transport.connections[0].state = .closing;
    transport.abandonClose(0, .kicked);
    try std.testing.expectEqual(@as(usize, 0), transport.connections[0].output_len);
    try std.testing.expectEqual(test_limits.output_pages, transport.free_output_count);
}

test "portable transport preserves FIFO order across output pages" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 1, .accepted = true };
    const connection = exchange.Connection{ .index = 0, .generation = 1 };
    const api = transport.transport();
    const first = [_]u8{0} ** 32;
    try std.testing.expect(api.vtable.write(api.context, connection, &first));
    try std.testing.expect(transport.consumeOutput(&transport.connections[0], 32));
    try std.testing.expect(api.vtable.write(api.context, connection, "wrapped"));
    try std.testing.expectEqualSlices(u8, "wrapped", transport.outputHead(&transport.connections[0]));
}

test "stale connection generations cannot write current output streams" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    transport.connections[0] = .{ .state = .open, .generation = 2, .accepted = true };
    const stale = exchange.Connection{ .index = 0, .generation = 1 };
    const current = exchange.Connection{ .index = 0, .generation = 2 };
    const api = transport.transport();
    try std.testing.expect(!api.vtable.write(api.context, stale, "x"));
    try std.testing.expect(api.vtable.write(api.context, current, "x"));
}

test "task completion wakes the continuous runtime immediately" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    var wake = WakeState{};
    transport.readiness = .{ .context = &wake, .io = io, .signal_fn = recordWake };
    transport.active_tasks = 1;

    transport.completeTask();

    try std.testing.expectEqual(@as(usize, 1), wake.signals);
    try std.testing.expectEqual(@as(usize, 1), transport.completed_tasks);
}

test "portable transport shutdown completes with no live sockets" {
    const T = Transport(test_limits);
    const io = std.Io.Threaded.global_single_threaded.io();
    var transport = T.stateOnly(io);
    try std.testing.expectEqual(runtime.Outcome.ok, transport.backend().beginShutdown(std.testing.io));
    try std.testing.expectEqual(runtime.Progress.complete, transport.backend().shutdownProgress());
}

const WakeState = struct { signals: usize = 0 };

fn recordWake(context: *anyopaque, _: std.Io) void {
    const state: *WakeState = @ptrCast(@alignCast(context));
    state.signals += 1;
}
