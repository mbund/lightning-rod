const std = @import("std");
const lightning_rod = @import("lightning_rod");
const exchange = lightning_rod.transport;
const runtime = lightning_rod.runtime;
const sockets = @import("transport/linux_socket.zig");
const handoff_fd = @import("reexec_handoff_fd.zig");
const reload = @import("reexec_reload.zig");
const linux = std.os.linux;
const posix = std.posix;

pub const Limits = struct {
    connections: usize,
    input_pages: usize,
    page_bytes: usize,
    output_pages: usize,
    output_page_bytes: usize,
    output_pages_per_connection: usize,
    event_capacity: usize,
    completion_batch: usize,
    ring_entries: u16,
};

pub const Configuration = struct {
    address: std.Io.net.IpAddress,
    backlog: u32 = 128,
    setup_flags: u32 = 0,
};

pub fn Transport(comptime limits: Limits) type {
    validateLimits(limits);
    return struct {
        const Self = @This();
        const invalid_fd: posix.socket_t = -1;
        const accept_index = std.math.maxInt(u16);

        const ConnectionState = enum { free, open, closing };
        const InputState = enum { free, receiving, ready };
        const output_capacity = limits.output_pages_per_connection * limits.output_page_bytes;
        const ReadinessTask = std.Io.Future(std.Io.Cancelable!void);
        const Connection = struct {
            state: ConnectionState = .free,
            fd: posix.socket_t = invalid_fd,
            generation: u32 = 0,
            input_page: ?u16 = null,
            recv_pending: bool = false,
            send_pending: bool = false,
            writable_pending: bool = false,
            writable_cancel_pending: bool = false,
            recv_cancel_pending: bool = false,
            send_cancel_pending: bool = false,
            close_pending: bool = false,
            output_head: ?u16 = null,
            output_tail: ?u16 = null,
            output_pages: u16 = 0,
            output_len: usize = 0,
        };
        const InputPage = struct { state: InputState = .free, owner: u16 = 0, len: u16 = 0 };
        const OutputPage = struct { next: ?u16 = null, start: usize = 0, end: usize = 0 };

        ring: linux.IoUring,
        ring_initialized: bool,
        listener: posix.socket_t,
        connections: [limits.connections]Connection,
        input: [limits.input_pages]InputPage,
        input_bytes: [limits.input_pages][limits.page_bytes]u8,
        output: [limits.output_pages]OutputPage,
        output_bytes: [limits.output_pages][limits.output_page_bytes]u8,
        free_output: [limits.output_pages]u16,
        free_output_count: usize,
        next_send: u16,
        free_input: [limits.input_pages]u16,
        free_input_count: usize,
        events: [limits.event_capacity]exchange.TransportEvent,
        event_head: usize,
        event_count: usize,
        accept_pending: bool,
        accept_multishot: bool,
        accept_cancel_pending: bool,
        reloading: bool,
        reload_cancel_count: usize,
        reload_quiesced: bool,
        reload_unread: [limits.page_bytes]u8,
        reload_output: [output_capacity]u8,
        readiness_eventfd: posix.fd_t,
        readiness_registered: bool,
        readiness_io: ?std.Io,
        readiness_wake: ?runtime.Wake,
        readiness_task: ?ReadinessTask,
        readiness_stopping: std.atomic.Value(bool),
        readiness_failed: std.atomic.Value(bool),
        stopping: bool,
        faulted: bool,

        pub fn init(configuration: Configuration) !Self {
            var self: Self = undefined;
            try self.initialize(configuration);
            return self;
        }

        fn stateOnly() Self {
            var self: Self = undefined;
            self.reset();
            return self;
        }

        pub fn initialize(self: *Self, configuration: Configuration) !void {
            self.reset();
            self.ring = try linux.IoUring.init(limits.ring_entries, configuration.setup_flags);
            self.ring_initialized = true;
            errdefer self.ring.deinit();
            self.listener = try sockets.listen(configuration.address, configuration.backlog);
            errdefer sockets.close(self.listener);
            self.stageWork();
            if (self.faulted) return error.TransportInitializationFailed;
            _ = try self.ring.submit();
        }

        pub fn initializeResumed(self: *Self, listener: posix.socket_t, setup_flags: u32) !void {
            if (listener == invalid_fd) return error.InvalidListener;
            self.reset();
            self.ring = try linux.IoUring.init(limits.ring_entries, setup_flags);
            self.ring_initialized = true;
            errdefer self.ring.deinit();
            self.listener = invalid_fd;
            if (installResumedListener(self, listener) != .ok) return error.InvalidListener;
        }

        pub fn beginRestored(self: *Self) !void {
            if (self.listener == invalid_fd or self.reloading or self.stopping) return error.InvalidState;
            self.stageWork();
            if (self.faulted) return error.TransportInitializationFailed;
            _ = try self.ring.submit();
        }

        pub fn deinit(self: *Self) void {
            self.stopReadiness();
            if (self.ring_initialized) self.ring.deinit();
            sockets.close(self.listener);
            for (&self.connections) |*item| sockets.close(item.fd);
            self.* = undefined;
        }

        pub fn transport(self: *Self) exchange.Transport {
            return .{ .context = self, .vtable = &transport_vtable };
        }

        pub fn backend(self: *Self) runtime.Backend {
            return .{
                .context = self,
                .vtable = &backend_vtable,
                .readiness = .{ .context = self, .bind_fn = bindReadiness },
            };
        }

        pub fn reloaderTransport(self: *Self) reload.Transport {
            return .{ .context = self, .vtable = &reload_vtable };
        }

        fn reset(self: *Self) void {
            self.ring_initialized = false;
            self.listener = invalid_fd;
            @memset(&self.connections, .{});
            @memset(&self.input, .{});
            self.free_input_count = limits.input_pages;
            for (&self.free_input, 0..) |*slot, index| slot.* = @intCast(index);
            @memset(&self.output, .{});
            self.free_output_count = limits.output_pages;
            for (&self.free_output, 0..) |*slot, index| slot.* = @intCast(index);
            self.next_send = 0;
            self.event_head = 0;
            self.event_count = 0;
            self.accept_pending = false;
            self.accept_multishot = true;
            self.accept_cancel_pending = false;
            self.reloading = false;
            self.reload_cancel_count = 0;
            self.reload_quiesced = false;
            self.readiness_eventfd = invalid_fd;
            self.readiness_registered = false;
            self.readiness_io = null;
            self.readiness_wake = null;
            self.readiness_task = null;
            self.readiness_stopping = .init(false);
            self.readiness_failed = .init(false);
            self.stopping = false;
            self.faulted = false;
        }

        fn raw(raw_context: *anyopaque) *Self {
            return @ptrCast(@alignCast(raw_context));
        }

        fn transportComplete(raw_context: *anyopaque, destination: []exchange.TransportEvent) usize {
            const self = raw(raw_context);
            const count = @min(destination.len, self.event_count);
            for (destination[0..count]) |*event| {
                event.* = self.events[self.event_head];
                self.event_head = (self.event_head + 1) % limits.event_capacity;
            }
            self.event_count -= count;
            return count;
        }

        fn inputPage(raw_context: *anyopaque, id: exchange.Page) ?exchange.InputPage {
            const self = raw(raw_context);
            const index = inputIndex(id) orelse return null;
            const page = self.input[index];
            if (page.state != .ready) return null;
            return .{ .id = id, .bytes = self.input_bytes[index][0..page.len] };
        }

        fn outputCredit(raw_context: *anyopaque, identity: exchange.Connection) usize {
            const self = raw(raw_context);
            const connection = self.openConnection(identity) orelse return 0;
            if (connection.writable_pending) return 0;
            return self.outputCreditFor(connection);
        }

        fn outputMetrics(raw_context: *anyopaque, identity: exchange.Connection) ?exchange.OutputMetrics {
            const self = raw(raw_context);
            const connection = self.openConnection(identity) orelse return null;
            return .{ .queued_bytes = connection.output_len, .capacity_bytes = output_capacity };
        }

        fn write(raw_context: *anyopaque, identity: exchange.Connection, bytes: []const u8) bool {
            const self = raw(raw_context);
            if (bytes.len == 0 or bytes.len > output_capacity) return false;
            const connection = self.openConnection(identity) orelse return false;
            if (connection.writable_pending) return false;
            if (bytes.len > self.outputCreditFor(connection)) return false;
            self.writeOutput(connection, bytes);
            return true;
        }

        fn releaseInput(raw_context: *anyopaque, id: exchange.Page) void {
            const self = raw(raw_context);
            const index = inputIndex(id) orelse return;
            const page = &self.input[index];
            if (page.state != .ready) return;
            const owner = page.owner;
            page.* = .{};
            self.free_input[self.free_input_count] = @intCast(index);
            self.free_input_count += 1;
            const connection = &self.connections[owner];
            if (connection.input_page == index) connection.input_page = null;
            self.finalize(owner);
        }

        fn close(raw_context: *anyopaque, identity: exchange.Connection, reason: exchange.DisconnectReason) void {
            const self = raw(raw_context);
            if (identity.index >= limits.connections) return;
            const connection = &self.connections[identity.index];
            if (connection.generation != identity.generation) return;
            self.requestClose(@intCast(identity.index), reason);
        }

        fn transportSubmit(raw_context: *anyopaque) void {
            _ = submitNow(raw_context);
        }

        fn backendComplete(raw_context: *anyopaque, _: std.Io, budget: usize) runtime.Completion {
            const self = raw(raw_context);
            if (self.faulted or self.readiness_failed.load(.acquire)) return .{ .count = 0, .outcome = .failed };
            var cqes: [limits.completion_batch]linux.io_uring_cqe = undefined;
            const maximum = @min(budget, limits.completion_batch);
            if (maximum == 0) return .{ .count = 0 };
            const count = self.ring.copy_cqes(cqes[0..maximum], 0) catch {
                self.faulted = true;
                return .{ .count = 0, .outcome = .failed };
            };
            for (cqes[0..count]) |cqe| self.handleCompletion(cqe);
            return .{ .count = count, .outcome = if (self.faulted or self.readiness_failed.load(.acquire)) .failed else .ok };
        }

        fn backendSubmit(raw_context: *anyopaque, _: std.Io) runtime.Outcome {
            return submitNow(raw_context);
        }

        fn submitNow(raw_context: *anyopaque) runtime.Outcome {
            const self = raw(raw_context);
            if (self.faulted or self.readiness_failed.load(.acquire)) return .failed;
            self.stageWork();
            if (self.faulted) return .failed;
            _ = self.ring.submit() catch {
                self.faulted = true;
                return .failed;
            };
            return .ok;
        }

        fn beginShutdown(raw_context: *anyopaque, io: std.Io) runtime.Outcome {
            const self = raw(raw_context);
            if (self.faulted) return .failed;
            self.stopping = true;
            for (0..limits.connections) |index| {
                if (self.connections[index].state == .open) self.requestClose(@intCast(index), .server_shutdown);
            }
            _ = io;
            return submitNow(raw_context);
        }

        fn shutdownProgress(raw_context: *anyopaque) runtime.Progress {
            const self = raw(raw_context);
            if (self.faulted or self.readiness_failed.load(.acquire)) return .failed;
            if (!self.stopping or self.accept_pending or self.accept_cancel_pending) return .pending;
            if (self.listener != invalid_fd or self.event_count != 0) return .pending;
            for (self.connections) |item| if (item.state != .free) return .pending;
            return .complete;
        }

        fn bindReadiness(raw_context: *anyopaque, wake: runtime.Wake) runtime.Outcome {
            const self = raw(raw_context);
            if (self.readiness_wake != null or self.readiness_registered or !self.ring_initialized) return .failed;
            const fd = createReadinessEventfd() catch return .failed;
            self.ring.register_eventfd(fd) catch {
                sockets.close(fd);
                return .failed;
            };
            self.readiness_eventfd = fd;
            self.readiness_registered = true;
            self.readiness_io = wake.io;
            self.readiness_wake = wake;
            self.readiness_task = std.Io.concurrent(wake.io, waitReadiness, .{self}) catch {
                self.unregisterReadiness();
                return .failed;
            };
            return .ok;
        }

        fn waitReadiness(self: *Self) std.Io.Cancelable!void {
            const io = self.readiness_io orelse {
                self.failReadiness();
                return;
            };
            var counter: [@sizeOf(u64)]u8 = undefined;
            while (!self.readiness_stopping.load(.acquire)) {
                const count = readinessFile(self).readStreaming(io, &.{counter[0..]}) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    self.failReadiness();
                    return;
                };
                if (count != counter.len) {
                    self.failReadiness();
                    return;
                }
                if (self.readiness_stopping.load(.acquire)) return;
                const wake = self.readiness_wake orelse {
                    self.failReadiness();
                    return;
                };
                wake.signal();
            }
        }

        fn failReadiness(self: *Self) void {
            self.readiness_failed.store(true, .release);
            if (self.readiness_wake) |wake| wake.signal();
        }

        fn stopReadiness(self: *Self) void {
            self.readiness_stopping.store(true, .release);
            if (self.readiness_task) |*task| {
                const io = self.readiness_io orelse @panic("io_uring readiness task has no std.Io");
                _ = task.cancel(io) catch {};
                self.readiness_task = null;
            }
            self.unregisterReadiness();
        }

        fn unregisterReadiness(self: *Self) void {
            if (!self.readiness_registered) return;
            self.ring.unregister_eventfd() catch @panic("failed to unregister io_uring readiness eventfd");
            self.readiness_registered = false;
            sockets.close(self.readiness_eventfd);
            self.readiness_eventfd = invalid_fd;
            self.readiness_io = null;
            self.readiness_wake = null;
        }

        fn readinessFile(self: *const Self) std.Io.File {
            std.debug.assert(self.readiness_eventfd != invalid_fd);
            return .{ .handle = self.readiness_eventfd, .flags = .{ .nonblocking = false } };
        }

        fn createReadinessEventfd() !posix.fd_t {
            const result = linux.eventfd(0, linux.EFD.CLOEXEC);
            return switch (linux.errno(result)) {
                .SUCCESS => @intCast(result),
                else => |err| posix.unexpectedErrno(err),
            };
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

        const reload_vtable: reload.Transport.VTable = .{
            .begin_quiesce = reloadBeginQuiesce,
            .quiesce_progress = reloadQuiesceProgress,
            .abort_quiesce = reloadAbortQuiesce,
            .maximum_resume_bytes = reloadMaximumBytes,
            .listener = reloadListener,
            .connection_count = reloadConnectionCount,
            .connection = reloadConnection,
            .prepare_for_exec = reloadPrepareConnection,
            .prepare_listener_for_exec = reloadPrepareListener,
            .restore = reloadRestoreConnection,
        };

        fn reloadBeginQuiesce(raw_context: *anyopaque) runtime.Outcome {
            const self = raw(raw_context);
            if (self.faulted or self.stopping or self.reloading) return .failed;
            self.reloading = true;
            self.reload_quiesced = false;
            self.stageReloadCancellation();
            return if (self.faulted) .failed else submitNow(raw_context);
        }

        fn reloadQuiesceProgress(raw_context: *anyopaque) runtime.Progress {
            const self = raw(raw_context);
            if (self.faulted) return .failed;
            if (!self.reloading) return .failed;
            if (self.accept_pending or self.reload_cancel_count != 0) return .pending;
            for (self.connections) |item| if (item.recv_pending or item.send_pending or item.writable_pending or item.writable_cancel_pending or item.close_pending) return .pending;
            self.reload_quiesced = true;
            return .complete;
        }

        fn reloadAbortQuiesce(raw_context: *anyopaque) runtime.Outcome {
            const self = raw(raw_context);
            if (self.faulted or !self.reloading) return .failed;
            if (self.listener != invalid_fd) handoff_fd.HandoffFd.restoreCloseOnExec(self.listener) catch return .failed;
            for (self.connections) |item| {
                if (item.state != .open) continue;
                handoff_fd.HandoffFd.restoreCloseOnExec(item.fd) catch return .failed;
            }
            self.reloading = false;
            self.reload_quiesced = false;
            self.stageWork();
            return submitNow(raw_context);
        }

        fn reloadMaximumBytes(raw_context: *anyopaque) usize {
            _ = raw(raw_context);
            return @import("restart_handoff.zig").header_bytes + limits.connections *
                (@import("restart_handoff.zig").record_bytes + limits.page_bytes + output_capacity + minecraftContinuationBytes());
        }

        fn minecraftContinuationBytes() usize {
            return lightning_rod.sessions.Continuation.maximum_bytes;
        }

        fn reloadListener(raw_context: *anyopaque) ?posix.socket_t {
            const self = raw(raw_context);
            if (!self.reload_quiesced or self.listener == invalid_fd) return null;
            return self.listener;
        }

        fn reloadConnectionCount(raw_context: *anyopaque) usize {
            const self = raw(raw_context);
            if (!self.reload_quiesced) return 0;
            var count: usize = 0;
            for (self.connections) |item| {
                if (item.state == .open) count += 1;
            }
            return count;
        }

        fn reloadConnection(raw_context: *anyopaque, ordinal: usize) ?reload.TransportConnection {
            const self = raw(raw_context);
            if (!self.reload_quiesced) return null;
            var seen: usize = 0;
            for (&self.connections, 0..) |*item, index| {
                if (item.state != .open) continue;
                if (seen != ordinal) {
                    seen += 1;
                    continue;
                }
                const slot: u16 = @intCast(index);
                const unread = self.copyReloadUnread(slot);
                const output = self.copyReloadOutput(slot);
                return .{ .fd = item.fd, .handle = self.connectionHandle(slot), .unread = unread, .output = output };
            }
            return null;
        }

        fn reloadPrepareConnection(raw_context: *anyopaque, handle: exchange.Connection) runtime.Outcome {
            const self = raw(raw_context);
            const item = self.openConnection(handle) orelse return .failed;
            handoff_fd.HandoffFd.prepareForExec(item.fd) catch return .failed;
            return .ok;
        }

        fn reloadPrepareListener(raw_context: *anyopaque) runtime.Outcome {
            const self = raw(raw_context);
            if (!self.reload_quiesced or self.listener == invalid_fd) return .failed;
            handoff_fd.HandoffFd.prepareForExec(self.listener) catch return .failed;
            return .ok;
        }

        fn installResumedListener(self: *Self, listener: posix.socket_t) runtime.Outcome {
            if (self.listener != invalid_fd or listener < 0) return .failed;
            handoff_fd.HandoffFd.restoreCloseOnExec(listener) catch return .failed;
            self.listener = listener;
            return .ok;
        }

        fn reloadRestoreConnection(raw_context: *anyopaque, saved: reload.TransportConnection) runtime.Outcome {
            const self = raw(raw_context);
            if (saved.handle.index >= limits.connections or saved.fd < 0 or saved.unread.len > limits.page_bytes or saved.output.len > output_capacity) return .failed;
            handoff_fd.HandoffFd.restoreCloseOnExec(saved.fd) catch return .failed;
            const index: u16 = @intCast(saved.handle.index);
            const item = &self.connections[index];
            if (item.state != .free or item.generation != 0 and item.generation != saved.handle.generation) return .failed;
            if (saved.output.len > self.outputCreditFor(item)) return .failed;
            if (saved.unread.len != 0 and self.free_input_count == 0) return .failed;
            item.* = .{ .state = .open, .fd = saved.fd, .generation = saved.handle.generation };
            if (saved.unread.len != 0) {
                const page = self.takeInputPage() orelse return .failed;
                self.input[page] = .{ .state = .ready, .owner = index, .len = @intCast(saved.unread.len) };
                @memcpy(self.input_bytes[page][0..saved.unread.len], saved.unread);
                item.input_page = page;
                self.pushEvent(.{ .received = .{ .connection = saved.handle, .page = .{ .id = inputId(page), .bytes = self.input_bytes[page][0..saved.unread.len] } } });
            }
            self.writeOutput(item, saved.output);
            return .ok;
        }

        fn copyReloadUnread(self: *Self, index: u16) []const u8 {
            const item = &self.connections[index];
            const page = item.input_page orelse return &.{};
            if (self.input[page].state != .ready) return &.{};
            const len = self.input[page].len;
            @memcpy(self.reload_unread[0..len], self.input_bytes[page][0..len]);
            return self.reload_unread[0..len];
        }

        fn copyReloadOutput(self: *Self, index: u16) []const u8 {
            const item = &self.connections[index];
            self.copyOutput(self.reload_output[0..], item);
            return self.reload_output[0..item.output_len];
        }

        fn stageWork(self: *Self) void {
            if (self.reloading) {
                self.stageReloadCancellation();
                return;
            }
            if (self.stopping) {
                self.stageAcceptCancel();
                for (0..limits.connections) |index| self.stageClose(@intCast(index));
                self.closeListenerWhenIdle();
                return;
            }
            self.stageAccept();
            for (0..limits.connections) |index| {
                if (self.connections[index].state == .closing) {
                    self.stageClose(@intCast(index));
                    continue;
                }
                self.stageReceive(@intCast(index));
            }
            self.stageSends();
        }

        fn stageReloadCancellation(self: *Self) void {
            if (self.accept_pending and !self.accept_cancel_pending) {
                _ = self.ring.cancel(pack(.cancel_accept, accept_index, 0), pack(.accept, accept_index, 0), 0) catch |err| return self.stageError(err);
                self.accept_cancel_pending = true;
                self.reload_cancel_count += 1;
            }
            for (self.connections, 0..) |connection, index| {
                if (connection.recv_pending and !connection.recv_cancel_pending) {
                    _ = self.ring.cancel(pack(.cancel_recv, @intCast(index), connection.generation), pack(.recv, @intCast(index), connection.generation), 0) catch |err| return self.stageError(err);
                    self.connections[index].recv_cancel_pending = true;
                    self.reload_cancel_count += 1;
                }
                if (connection.send_pending and !connection.send_cancel_pending) {
                    _ = self.ring.cancel(pack(.cancel_send, @intCast(index), connection.generation), pack(.send, @intCast(index), connection.generation), 0) catch |err| return self.stageError(err);
                    self.connections[index].send_cancel_pending = true;
                    self.reload_cancel_count += 1;
                }
                if (connection.writable_pending and !connection.writable_cancel_pending) {
                    _ = self.ring.poll_remove(pack(.cancel_writable, @intCast(index), connection.generation), pack(.writable, @intCast(index), connection.generation)) catch |err| return self.stageError(err);
                    self.connections[index].writable_cancel_pending = true;
                    self.reload_cancel_count += 1;
                }
            }
        }

        fn stageAccept(self: *Self) void {
            if (self.accept_pending or self.listener == invalid_fd) return;
            const result = if (self.accept_multishot)
                self.ring.accept_multishot(pack(.accept, accept_index, 0), self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC)
            else
                self.ring.accept(pack(.accept, accept_index, 0), self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            _ = result catch |err| return self.stageError(err);
            self.accept_pending = true;
        }

        fn stageAcceptCancel(self: *Self) void {
            if (!self.accept_pending or self.accept_cancel_pending) return;
            _ = self.ring.cancel(pack(.cancel_accept, accept_index, 0), pack(.accept, accept_index, 0), 0) catch |err| return self.stageError(err);
            self.accept_cancel_pending = true;
        }

        fn stageReceive(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .open or connection.recv_pending or connection.input_page != null) return;
            const page_index = self.takeInputPage() orelse return;
            const buffer = self.input_bytes[page_index][0..];
            _ = self.ring.recv(pack(.recv, index, connection.generation), connection.fd, .{ .buffer = buffer }, linux.MSG.NOSIGNAL) catch |err| {
                self.returnInputPage(page_index);
                return self.stageError(err);
            };
            self.input[page_index] = .{ .state = .receiving, .owner = index };
            connection.input_page = page_index;
            connection.recv_pending = true;
        }

        fn stageSends(self: *Self) void {
            const first = self.next_send;
            self.next_send +%= 1;
            if (self.next_send == limits.connections) self.next_send = 0;
            var considered: usize = 0;
            while (considered < limits.connections) : (considered += 1) {
                const index: u16 = @intCast((@as(usize, first) + considered) % limits.connections);
                self.stageSend(index);
                if (self.faulted) return;
            }
        }

        fn stageSend(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .open or connection.send_pending or connection.writable_pending or connection.output_len == 0) return;
            const bytes = self.outputHead(connection);
            _ = self.ring.send(pack(.send, index, connection.generation), connection.fd, bytes, linux.MSG.NOSIGNAL) catch |err| return self.stageError(err);
            connection.send_pending = true;
        }

        fn stageWritablePoll(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .open or connection.writable_pending or connection.output_len == 0) return;
            _ = self.ring.poll_add(pack(.writable, index, connection.generation), connection.fd, linux.POLL.OUT) catch |err| return self.stageError(err);
            connection.writable_pending = true;
        }

        fn stageClose(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .closing or connection.close_pending or connection.fd == invalid_fd) return;
            _ = self.ring.close(pack(.close, index, connection.generation), connection.fd) catch |err| return self.stageError(err);
            connection.close_pending = true;
        }

        fn stageError(self: *Self, err: anyerror) void {
            if (err != error.SubmissionQueueFull) self.faulted = true;
        }

        fn handleCompletion(self: *Self, cqe: linux.io_uring_cqe) void {
            const tag = unpack(cqe.user_data) orelse {
                self.faulted = true;
                return;
            };
            switch (tag.kind) {
                .accept => self.completeAccept(cqe),
                .recv => self.completeReceive(tag, cqe),
                .send => self.completeSend(tag, cqe),
                .writable => self.completeWritable(tag, cqe),
                .close => self.completeClose(tag, cqe),
                .cancel_accept => self.completeAcceptCancel(),
                .cancel_recv => self.completeReloadCancel(tag, true),
                .cancel_send => self.completeReloadCancel(tag, false),
                .cancel_writable => {},
            }
        }

        fn completeAccept(self: *Self, cqe: linux.io_uring_cqe) void {
            if (cqe.flags & linux.IORING_CQE_F_MORE == 0) self.accept_pending = false;
            if (cqe.err() != .SUCCESS) {
                if (!self.stopping and self.accept_multishot and (cqe.err() == .INVAL or cqe.err() == .OPNOTSUPP)) self.accept_multishot = false;
                self.closeListenerWhenIdle();
                return;
            }
            const fd: posix.socket_t = @intCast(cqe.res);
            if (self.stopping or self.reloading) {
                sockets.close(fd);
                return;
            }
            const index = self.freeConnection() orelse {
                sockets.close(fd);
                return;
            };
            self.admitConnection(index, fd);
        }

        fn completeReceive(self: *Self, tag: Tag, cqe: linux.io_uring_cqe) void {
            const connection = self.taggedConnection(tag) orelse return;
            const page_index = connection.input_page orelse return self.failInvariant();
            connection.recv_pending = false;
            connection.recv_cancel_pending = false;
            if (self.reloading) {
                if (cqe.err() == .SUCCESS and cqe.res > 0 and cqe.res <= limits.page_bytes) {
                    self.input[page_index].state = .ready;
                    self.input[page_index].len = @intCast(cqe.res);
                } else self.returnConnectionInput(tag.index, page_index);
                return;
            }
            if (connection.state == .closing) {
                self.returnConnectionInput(tag.index, page_index);
                return self.finalize(tag.index);
            }
            if (cqe.err() != .SUCCESS or cqe.res <= 0 or cqe.res > limits.page_bytes) {
                self.returnConnectionInput(tag.index, page_index);
                const reason: exchange.DisconnectReason = if (cqe.err() == .SUCCESS and cqe.res == 0) .peer_closed else .transport_error;
                return self.requestClose(tag.index, reason);
            }
            self.input[page_index].state = .ready;
            self.input[page_index].len = @intCast(cqe.res);
            self.pushEvent(.{ .received = .{
                .connection = self.connectionHandle(tag.index),
                .page = .{ .id = inputId(page_index), .bytes = self.input_bytes[page_index][0..@intCast(cqe.res)] },
            } });
        }

        fn completeSend(self: *Self, tag: Tag, cqe: linux.io_uring_cqe) void {
            const connection = self.taggedConnection(tag) orelse return;
            connection.send_pending = false;
            connection.send_cancel_pending = false;
            if (self.reloading) {
                if (cqe.err() == .SUCCESS and cqe.res > 0) _ = self.consumeOutput(connection, @intCast(cqe.res));
                return;
            }
            if (connection.state == .closing) {
                self.releaseOutput(connection);
                return self.finalize(tag.index);
            }
            if (cqe.err() == .AGAIN) return self.stageWritablePoll(tag.index);
            if (cqe.err() != .SUCCESS or cqe.res <= 0) return self.requestClose(tag.index, .transport_error);
            if (!self.consumeOutput(connection, @intCast(cqe.res))) return self.failInvariant();
        }

        fn completeWritable(self: *Self, tag: Tag, cqe: linux.io_uring_cqe) void {
            const connection = self.taggedConnection(tag) orelse return;
            connection.writable_pending = false;
            if (connection.writable_cancel_pending) {
                connection.writable_cancel_pending = false;
                if (self.reloading and self.reload_cancel_count != 0) self.reload_cancel_count -= 1;
            }
            if (self.reloading) return;
            if (connection.state != .open) return self.finalize(tag.index);
            if (cqe.err() != .SUCCESS) return self.requestClose(tag.index, .transport_error);
        }

        fn completeClose(self: *Self, tag: Tag, cqe: linux.io_uring_cqe) void {
            const connection = self.taggedConnection(tag) orelse return;
            connection.close_pending = false;
            if (cqe.err() != .SUCCESS) sockets.close(connection.fd);
            connection.fd = invalid_fd;
            self.finalize(tag.index);
        }

        fn completeAcceptCancel(self: *Self) void {
            self.accept_cancel_pending = false;
            if (self.reloading and self.reload_cancel_count != 0) self.reload_cancel_count -= 1;
            self.closeListenerWhenIdle();
        }

        fn completeReloadCancel(self: *Self, tag: Tag, recv: bool) void {
            if (self.reload_cancel_count != 0) self.reload_cancel_count -= 1;
            _ = tag;
            _ = recv;
        }

        fn requestClose(self: *Self, index: u16, reason: exchange.DisconnectReason) void {
            const connection = &self.connections[index];
            if (connection.state != .open) return;
            const identity = self.connectionHandle(index);
            connection.state = .closing;
            self.pushEvent(.{ .closed = .{ .connection = identity, .reason = reason } });
            if (!connection.send_pending) self.releaseOutput(connection);
            self.finalize(index);
        }

        fn finalize(self: *Self, index: u16) void {
            const connection = &self.connections[index];
            if (connection.state != .closing) return;
            if (connection.recv_pending or connection.send_pending or connection.writable_pending or connection.writable_cancel_pending or connection.close_pending) return;
            if (connection.input_page != null or connection.fd != invalid_fd) return;
            connection.* = .{ .generation = connection.generation };
        }

        fn closeListenerWhenIdle(self: *Self) void {
            if (!self.stopping or self.accept_pending or self.listener == invalid_fd) return;
            sockets.close(self.listener);
            self.listener = invalid_fd;
        }

        fn admitConnection(self: *Self, index: u16, fd: posix.socket_t) void {
            const previous = self.connections[index].generation;
            var generation = previous +% 1;
            if (generation == 0) generation = 1;
            self.connections[index] = .{ .state = .open, .fd = fd, .generation = generation };
            self.pushEvent(.{ .accepted = self.connectionHandle(index) });
        }

        fn freeConnection(self: *Self) ?u16 {
            for (self.connections, 0..) |connection, index| {
                if (connection.state == .free) return @intCast(index);
            }
            return null;
        }

        fn openConnection(self: *Self, identity: exchange.Connection) ?*Connection {
            if (identity.index >= limits.connections) return null;
            const connection = &self.connections[identity.index];
            if (connection.state != .open or connection.generation != identity.generation) return null;
            return connection;
        }

        fn taggedConnection(self: *Self, tag: Tag) ?*Connection {
            if (tag.index >= limits.connections) return null;
            const connection = &self.connections[tag.index];
            if (connection.state == .free or connection.generation != tag.generation) return null;
            return connection;
        }

        fn connectionHandle(self: *const Self, index: u16) exchange.Connection {
            return .{ .index = index, .generation = self.connections[index].generation };
        }

        fn takeInputPage(self: *Self) ?u16 {
            if (self.free_input_count == 0) return null;
            self.free_input_count -= 1;
            return self.free_input[self.free_input_count];
        }

        fn returnConnectionInput(self: *Self, owner: u16, page: u16) void {
            if (self.connections[owner].input_page == page) self.connections[owner].input_page = null;
            self.returnInputPage(page);
        }

        fn returnInputPage(self: *Self, page: u16) void {
            self.input[page] = .{};
            self.free_input[self.free_input_count] = page;
            self.free_input_count += 1;
        }

        fn pushEvent(self: *Self, event: exchange.TransportEvent) void {
            if (self.event_count == limits.event_capacity) return self.failInvariant();
            const tail = (self.event_head + self.event_count) % limits.event_capacity;
            self.events[tail] = event;
            self.event_count += 1;
        }

        fn failInvariant(self: *Self) void {
            self.faulted = true;
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

        fn copyOutput(self: *const Self, destination: []u8, connection: *const Connection) void {
            std.debug.assert(destination.len >= connection.output_len);
            var page = connection.output_head;
            var offset: usize = 0;
            while (page) |index| {
                const item = self.output[index];
                const bytes = self.output_bytes[index][item.start..item.end];
                @memcpy(destination[offset..][0..bytes.len], bytes);
                offset += bytes.len;
                page = item.next;
            }
            std.debug.assert(offset == connection.output_len);
        }
    };
}

const Operation = enum(u8) { accept, recv, send, writable, close, cancel_accept, cancel_recv, cancel_send, cancel_writable };
const Tag = struct { kind: Operation, index: u16, generation: u32 };

fn pack(kind: Operation, index: u16, generation: u32) u64 {
    return (@as(u64, @intFromEnum(kind)) << 56) |
        (@as(u64, index) << 32) | generation;
}

fn unpack(value: u64) ?Tag {
    const raw_kind: u8 = @intCast(value >> 56);
    if (raw_kind > @intFromEnum(Operation.cancel_writable)) return null;
    return .{
        .kind = @enumFromInt(raw_kind),
        .index = @intCast((value >> 32) & std.math.maxInt(u16)),
        .generation = @truncate(value),
    };
}

fn validateLimits(comptime limits: Limits) void {
    if (limits.connections == 0 or limits.connections >= std.math.maxInt(u16)) @compileError("connections must fit a non-sentinel u16");
    if (limits.input_pages < limits.connections or limits.input_pages > std.math.maxInt(u16)) @compileError("input_pages must cover connections and fit u16");
    if (limits.page_bytes == 0) @compileError("page_bytes must be nonzero");
    if (limits.output_pages == 0 or limits.output_pages > std.math.maxInt(u16)) @compileError("output_pages must be nonzero and fit u16");
    if (limits.output_page_bytes == 0) @compileError("output_page_bytes must be nonzero");
    if (limits.output_pages_per_connection == 0 or limits.output_pages_per_connection > limits.output_pages) @compileError("output_pages_per_connection must be within the global output page pool");
    if (limits.event_capacity < limits.connections * 2 + limits.input_pages) @compileError("event_capacity cannot retain accepted, input, and closed events");
    if (limits.completion_batch == 0) @compileError("completion_batch must be nonzero");
    if (limits.ring_entries == 0 or !std.math.isPowerOfTwo(limits.ring_entries)) @compileError("ring_entries must be a nonzero power of two");
}

const test_limits: Limits = .{
    .connections = 2,
    .input_pages = 2,
    .page_bytes = 16,
    .output_pages = 4,
    .output_page_bytes = 16,
    .output_pages_per_connection = 2,
    .event_capacity = 10,
    .completion_batch = 4,
    .ring_entries = 8,
};

const shared_pool_test_limits: Limits = .{
    .connections = 2,
    .input_pages = 2,
    .page_bytes = 16,
    .output_pages = 2,
    .output_page_bytes = 16,
    .output_pages_per_connection = 2,
    .event_capacity = 10,
    .completion_batch = 4,
    .ring_entries = 8,
};

test "localhost listener and ring initialize when the host permits io_uring" {
    const T = Transport(test_limits);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var state = T.init(.{ .address = address }) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated, error.OpcodeNotSupported => return,
        else => return err,
    };
    defer state.deinit();
    try std.testing.expect(state.ring_initialized);
    try std.testing.expect(state.listener >= 0);
    try std.testing.expect(state.accept_pending);
}

test "output streams are fixed and generation safe" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const handle = state.connectionHandle(0);
    const api = state.transport();
    try testing.expectEqual(@as(usize, 32), api.vtable.output_credit(api.context, handle));
    try testing.expect(api.vtable.write(api.context, handle, "first"));
    try testing.expect(api.vtable.write(api.context, handle, "second"));
    try testing.expectEqual(@as(usize, 21), api.vtable.output_credit(api.context, handle));
    api.vtable.close(api.context, .{ .index = 0, .generation = handle.generation + 1 }, .kicked);
    try testing.expectEqual(T.ConnectionState.open, state.connections[0].state);
}

test "one input lease is retained and reborrowed until explicit release" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const page = state.takeInputPage().?;
    state.connections[0].input_page = page;
    state.connections[0].recv_pending = true;
    state.input[page] = .{ .state = .receiving, .owner = 0 };
    @memcpy(state.input_bytes[page][0..3], "abc");
    state.completeReceive(.{ .kind = .recv, .index = 0, .generation = state.connections[0].generation }, .{ .user_data = 0, .res = 3, .flags = 0 });
    var events: [2]exchange.TransportEvent = undefined;
    const api = state.transport();
    try testing.expectEqual(@as(usize, 2), api.vtable.complete(api.context, &events));
    const received = events[1].received;
    try testing.expectEqualStrings("abc", received.page.bytes);
    try testing.expectEqualStrings("abc", api.vtable.input_page(api.context, received.page.id).?.bytes);
    api.vtable.release_input(api.context, received.page.id);
    try testing.expect(api.vtable.input_page(api.context, received.page.id) == null);
    try testing.expectEqual(test_limits.input_pages, state.free_input_count);
}

test "partial sends reclaim exactly the completed stream bytes" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const handle = state.connectionHandle(0);
    const api = state.transport();
    try testing.expect(api.vtable.write(api.context, handle, "abcdefgh"));
    state.connections[0].send_pending = true;
    state.completeSend(.{ .kind = .send, .index = 0, .generation = handle.generation }, .{ .user_data = 0, .res = 6, .flags = 0 });
    try testing.expectEqual(@as(usize, 2), state.connections[0].output_len);
    state.connections[0].send_pending = true;
    state.completeSend(.{ .kind = .send, .index = 0, .generation = handle.generation }, .{ .user_data = 0, .res = 2, .flags = 0 });
    try testing.expectEqual(@as(usize, 0), state.connections[0].output_len);
}

test "output stream writes are atomic at the fixed capacity" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const handle = state.connectionHandle(0);
    const api = state.transport();
    const full = [_]u8{0xaa} ** 32;
    try testing.expect(api.vtable.write(api.context, handle, &full));
    try testing.expect(!api.vtable.write(api.context, handle, "x"));
    const metrics = api.vtable.output_metrics(api.context, handle).?;
    try testing.expectEqual(@as(usize, 32), metrics.queued_bytes);
    try testing.expectEqual(@as(usize, 32), metrics.capacity_bytes);
}

test "the output pool is shared and a completed page immediately admits another connection" {
    const testing = std.testing;
    const T = Transport(shared_pool_test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    state.admitConnection(1, 8);
    const first = state.connectionHandle(0);
    const second = state.connectionHandle(1);
    const api = state.transport();
    const full = [_]u8{0xaa} ** 32;
    try testing.expect(api.vtable.write(api.context, first, &full));
    try testing.expectEqual(@as(usize, 0), api.vtable.output_credit(api.context, second));
    state.connections[0].send_pending = true;
    state.completeSend(.{ .kind = .send, .index = 0, .generation = first.generation }, .{ .user_data = 0, .res = 16, .flags = 0 });
    try testing.expectEqual(@as(usize, 16), api.vtable.output_credit(api.context, second));
    try testing.expect(api.vtable.write(api.context, second, "second page"));
}

test "writable polling suppresses optional output admission" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const handle = state.connectionHandle(0);
    const api = state.transport();
    state.connections[0].writable_pending = true;
    try testing.expectEqual(@as(usize, 0), api.vtable.output_credit(api.context, handle));
    try testing.expect(!api.vtable.write(api.context, handle, "x"));
}

test "closing an idle connection releases every queued output page" {
    const testing = std.testing;
    const T = Transport(test_limits);
    var state = T.stateOnly();
    state.admitConnection(0, 7);
    const handle = state.connectionHandle(0);
    const api = state.transport();
    const full = [_]u8{0xaa} ** 32;
    try testing.expect(api.vtable.write(api.context, handle, &full));
    state.requestClose(0, .kicked);
    try testing.expectEqual(@as(usize, 0), state.connections[0].output_len);
    try testing.expectEqual(test_limits.output_pages, state.free_output_count);
}
