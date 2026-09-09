const std = @import("std");
const lightning_rod = @import("lightning_rod");

const core_exchange = lightning_rod.core_exchange;
const exchange = lightning_rod.transport;
const contracts = lightning_rod.runtime;
const session_api = lightning_rod.session_api;
const reexec_reload = @import("reexec_reload.zig");
const linux = std.os.linux;
const posix = std.posix;

pub const Clock = struct {
    context: *const anyopaque,
    now_ns: *const fn (*const anyopaque) u64,

    pub inline fn nowNs(self: Clock) u64 {
        return self.now_ns(self.context);
    }
};

const CoreInput = struct {
    context: *anyopaque,
    drain: *const fn (*anyopaque) bool,
    finish: *const fn (*anyopaque) void,
};

const maximum_status_bytes = 64 * 1024;

pub const Command = enum(u8) {
    stop_accepting,
    final_detachments,
    begin_shutdown,
    begin_reconfiguration,
    abort_reconfiguration,
    begin_quiesce,
    abort_quiesce,
    stop,
};

const ReloadState = enum(u8) { idle, reconfiguring, reconfigured, quiescing, quiesced, detached, failed };

pub fn Worker(
    comptime TransportType: type,
    comptime TableType: type,
    comptime ExchangeType: type,
    comptime completion_budget: usize,
    comptime connection_capacity: usize,
    comptime output_capacity: usize,
    comptime continuation_capacity: usize,
    comptime maximum_output_lanes: usize,
) type {
    if (completion_budget == 0 or connection_capacity == 0 or output_capacity == 0 or maximum_output_lanes == 0)
        @compileError("invalid session worker limits");
    if (maximum_output_lanes > std.math.maxInt(u16))
        @compileError("too many session worker output lanes");
    return struct {
        const Self = @This();
        const Commands = lightning_rod.session_exchange.Spsc(Command, 8);
        const output_message_capacity = @TypeOf(@as(ExchangeType, undefined).to_sessions).message_capacity;
        const pending_capacity = value: {
            const result = std.math.mul(usize, output_message_capacity, maximum_output_lanes) catch
                @compileError("session worker pending output capacity overflows");
            if (result > std.math.maxInt(u16))
                @compileError("session worker pending output capacity exceeds u16 indexes");
            break :value result;
        };
        const status_queue = connection_capacity;
        const Pending = struct {
            message: core_exchange.CoreToSession = undefined,
            lane: u16 = 0,
            next: ?u16 = null,
        };
        const StatusMessage = struct {
            revision: u64,
            len: u16,
            bytes: [maximum_status_bytes]u8,
        };
        const StatusQueue = lightning_rod.session_exchange.Spsc(StatusMessage, 3);

        /// A Core owns this value for as long as it can emit packets. Its exchange
        /// remains SPSC: the Core is the producer and Sessions is the consumer.
        pub const OutputLane = struct {
            worker: *Self,
            exchange: *ExchangeType,

            fn init(worker: *Self, output: *ExchangeType) OutputLane {
                return .{ .worker = worker, .exchange = output };
            }

            pub fn egress(self: *OutputLane) core_exchange.Egress {
                return .{ .context = self, .vtable = &.{ .stage = stage, .stage_fanout = stageFanout, .encode = encode, .encode_fanout = encodeFanout, .flush = flush } };
            }

            fn stage(raw: *anyopaque, output: core_exchange.Output) core_exchange.PacketAdmission {
                const self: *OutputLane = @ptrCast(@alignCast(raw));
                return self.publish(.stage, .{ .stage = .{ .output = output } });
            }

            fn stageFanout(raw: *anyopaque, targets: []const core_exchange.OutputTarget, payload: []const u8) core_exchange.PacketAdmission {
                const self: *OutputLane = @ptrCast(@alignCast(raw));
                return self.publish(.fanout, .{ .fanout = .{ .targets = targets, .payload = payload } });
            }

            fn encode(raw: *anyopaque, target: core_exchange.OutputTarget, encoder: core_exchange.PacketEncoder) core_exchange.PacketAdmission {
                const self: *OutputLane = @ptrCast(@alignCast(raw));
                return self.publish(.encode, .{ .encode = .{ .target = target, .encoder = encoder } });
            }

            fn encodeFanout(raw: *anyopaque, targets: []const core_exchange.OutputTarget, encoder: core_exchange.PacketEncoder) core_exchange.PacketAdmission {
                const self: *OutputLane = @ptrCast(@alignCast(raw));
                return self.publish(.encode_fanout, .{ .encode_fanout = .{ .targets = targets, .encoder = encoder } });
            }

            const Publication = union(enum) {
                stage: struct { output: core_exchange.Output },
                fanout: struct { targets: []const core_exchange.OutputTarget, payload: []const u8 },
                encode: struct { target: core_exchange.OutputTarget, encoder: core_exchange.PacketEncoder },
                encode_fanout: struct { targets: []const core_exchange.OutputTarget, encoder: core_exchange.PacketEncoder },
            };

            fn publish(self: *OutputLane, comptime kind: std.meta.Tag(Publication), publication: Publication) core_exchange.PacketAdmission {
                const count = self.exchange.to_sessions.publicationCount();
                var producer = core_exchange.OutputProducer(ExchangeType).init(self.exchange);
                const result = switch (kind) {
                    .stage => producer.egress().stage(publication.stage.output),
                    .fanout => producer.egress().stageFanout(publication.fanout.targets, publication.fanout.payload),
                    .encode => producer.egress().encode(publication.encode.target, publication.encode.encoder),
                    .encode_fanout => producer.egress().encodeFanout(publication.encode_fanout.targets, publication.encode_fanout.encoder),
                };
                if (self.exchange.to_sessions.publicationCount() != count) self.worker.signal();
                return result;
            }

            fn flush(raw: *anyopaque) void {
                const self: *OutputLane = @ptrCast(@alignCast(raw));
                self.exchange.to_sessions.flush();
                self.worker.signal();
            }
        };

        transport: *TransportType,
        table: *TableType,
        /// The runtime thread is the sole status producer; the Sessions thread
        /// consumes this bounded mailbox. It never shares a Core's SPSC lane.
        status_messages: StatusQueue = .{},
        output_lanes: [maximum_output_lanes]*ExchangeType = undefined,
        output_lane_count: u16,
        io: std.Io,
        clock: Clock,
        status_bytes: [maximum_status_bytes]u8 = undefined,
        status_len: usize,
        status_revision: u64,
        status_source: lightning_rod.sessions.Status,
        status_staged_revision: u64,
        core: ?CoreInput = null,
        commands: Commands = .{},
        input: core_exchange.Ingress,
        pending: [pending_capacity]Pending = undefined,
        pending_heads: [connection_capacity + 1]?u16 = @splat(null),
        pending_tails: [connection_capacity + 1]?u16 = @splat(null),
        pending_counts: [connection_capacity + 1]u16 = @splat(0),
        pending_free: ?u16 = null,
        pending_cursor: u16 = 0,
        output_intake_cursor: u16 = 0,
        wake_fd: posix.fd_t,
        thread: ?std.Thread = null,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        shutdown_submitted: bool = false,
        stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        final_detachments: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        table_shutdown_complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fatal_requested: std.atomic.Value(bool) = .init(false),
        fatal_complete: std.atomic.Value(bool) = .init(false),
        resume_valid: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        reload_state: std.atomic.Value(ReloadState) = std.atomic.Value(ReloadState).init(.idle),
        output_credit: [connection_capacity]std.atomic.Value(usize) = undefined,
        output_queued: [connection_capacity]std.atomic.Value(usize) = undefined,
        metrics: ?*lightning_rod.metrics.Runtime = null,

        pub fn init(
            transport: *TransportType,
            table: *TableType,
            output_lanes: []const *ExchangeType,
            input: core_exchange.Ingress,
            io: std.Io,
            clock: Clock,
            status: lightning_rod.sessions.Status,
        ) !Self {
            const snapshot = status.snapshot();
            if (snapshot.json.len > maximum_status_bytes) return error.StatusSnapshotTooLarge;
            if (output_lanes.len == 0 or output_lanes.len > maximum_output_lanes) return error.InvalidOutputLaneCount;
            for (output_lanes, 0..) |lane, index| for (output_lanes[0..index]) |previous|
                if (lane == previous) return error.DuplicateOutputLane;
            const wake_fd = try createWakeFd();
            errdefer _ = linux.close(wake_fd);
            var self: Self = .{
                .transport = transport,
                .table = table,
                .output_lane_count = @intCast(output_lanes.len),
                .io = io,
                .clock = clock,
                .status_len = snapshot.json.len,
                .status_revision = snapshot.revision,
                .status_source = status,
                .status_staged_revision = snapshot.revision,
                .input = input,
                .wake_fd = wake_fd,
            };
            @memcpy(self.output_lanes[0..output_lanes.len], output_lanes);
            @memcpy(self.status_bytes[0..snapshot.json.len], snapshot.json);
            for (&self.pending, 0..) |*node, index| node.* = .{ .next = if (index + 1 == self.pending.len) null else @intCast(index + 1) };
            self.pending_free = 0;
            for (&self.output_credit) |*value| value.* = std.atomic.Value(usize).init(0);
            for (&self.output_queued) |*value| value.* = std.atomic.Value(usize).init(0);
            return self;
        }

        pub fn start(self: *Self) !void {
            if (self.thread != null or self.running.swap(true, .acq_rel)) return error.SessionWorkerAlreadyStarted;
            errdefer self.running.store(false, .release);
            try self.transport.registerCompletionEvent(self.wake_fd);
            errdefer self.transport.unregisterCompletionEvent();
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        pub fn request(self: *Self, command: Command) bool {
            if (!self.running.load(.acquire) or !self.commands.push(command)) return false;
            signal(self);
            return true;
        }

        pub fn join(self: *Self) void {
            if (self.thread) |thread| thread.join();
            self.thread = null;
            self.transport.unregisterCompletionEvent();
        }

        pub fn stop(self: *Self) void {
            if (self.thread == null) return;
            if (self.running.load(.acquire)) _ = self.request(.stop);
            self.join();
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(self.thread == null and !self.running.load(.acquire));
            _ = linux.close(self.wake_fd);
            self.wake_fd = -1;
        }

        pub fn outputLane(self: *Self, output: *ExchangeType) !OutputLane {
            for (self.output_lanes[0..self.output_lane_count]) |lane|
                if (lane == output) return OutputLane.init(self, output);
            return error.UnregisteredOutputLane;
        }

        pub fn bindCore(self: *Self, core: lightning_rod.sessions.CoreBoundary) void {
            std.debug.assert(self.core == null);
            self.core = .{
                .context = core.context,
                .drain = core.vtable.drain_input,
                .finish = core.vtable.finish_input,
            };
        }

        pub fn bindMetrics(self: *Self, value: *lightning_rod.metrics.Runtime) void {
            std.debug.assert(self.metrics == null);
            self.metrics = value;
        }

        pub fn outputState(self: *const Self, handle: exchange.Connection) ?session_api.OutputState {
            if (handle.index >= self.output_credit.len) return null;
            return .{
                .credit_bytes = self.output_credit[handle.index].load(.acquire),
                .queued_bytes = self.output_queued[handle.index].load(.acquire),
                .capacity_bytes = output_capacity,
            };
        }

        pub fn runtime(self: *Self) contracts.Sessions {
            return .{ .context = self, .vtable = &.{
                .advance = advanceRuntime,
                .take_input = takeInput,
                .finish_input = finishInput,
                .stop_accepting = stopAccepting,
                .stage_final_detachments = stageFinalDetachments,
                .fatal_disconnect = fatalDisconnect,
                .shutdown_progress = shutdownProgress,
            } };
        }

        pub fn backend(self: *Self) contracts.Backend {
            return .{ .context = self, .vtable = &.{
                .complete = backendComplete,
                .submit = backendSubmit,
                .begin_shutdown = beginShutdown,
                .shutdown_progress = backendShutdownProgress,
                .poll_interval_ns = backendPollInterval,
            } };
        }

        pub fn reloaderSessions(self: *Self) reexec_reload.Sessions {
            return .{ .context = self, .vtable = &.{
                .validate_resume = validateResume,
                .begin_reconfiguration = beginReconfiguration,
                .reconfiguration_progress = reconfigurationProgress,
                .abort_reconfiguration = abortReconfiguration,
                .encode = encodeResume,
                .restore = restoreResume,
            } };
        }

        pub fn reloaderTransport(self: *Self) reexec_reload.Transport {
            return .{ .context = self, .vtable = &.{
                .begin_quiesce = beginQuiesce,
                .quiesce_progress = quiesceProgress,
                .abort_quiesce = abortQuiesce,
                .maximum_resume_bytes = maximumResumeBytes,
                .listener = listener,
                .connection_count = connectionCount,
                .connection = connectionForOrdinal,
                .prepare_for_exec = prepareForExec,
                .prepare_listener_for_exec = prepareListenerForExec,
                .restore = restoreTransport,
            } };
        }

        fn advanceRuntime(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.failed.load(.acquire)) {
                std.log.err("event=session_worker_failed", .{});
                return .failed;
            }
            self.stageStatus();
            return .ok;
        }

        fn takeInput(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            const core = self.core orelse {
                std.log.err("event=session_core_input_failed reason=unbound", .{});
                return .failed;
            };
            if (!core.drain(core.context)) {
                std.log.err("event=session_core_input_failed reason=invalid_exchange_input", .{});
                return .failed;
            }
            return .ok;
        }

        fn finishInput(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            const core = self.core orelse return .failed;
            core.finish(core.context);
            signal(self);
            return .ok;
        }

        fn stopAccepting(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            return if (self.request(.stop_accepting)) .ok else .failed;
        }

        fn stageFinalDetachments(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            return if (self.request(.final_detachments)) .ok else .failed;
        }

        fn shutdownProgress(raw: *anyopaque) contracts.Progress {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.failed.load(.acquire)) return .failed;
            if (!self.final_detachments.load(.acquire)) return .pending;
            return if (self.table_shutdown_complete.load(.acquire)) .complete else .pending;
        }

        fn fatalDisconnect(raw: *anyopaque) contracts.Progress {
            const self: *Self = @ptrCast(@alignCast(raw));
            self.fatal_requested.store(true, .release);
            signal(self);
            if (self.failed.load(.acquire)) return .failed;
            return if (self.fatal_complete.load(.acquire)) .complete else .pending;
        }

        fn backendComplete(_: *anyopaque, _: std.Io, _: usize) contracts.Completion {
            return .{ .count = 0 };
        }

        fn backendSubmit(_: *anyopaque, _: std.Io) contracts.Outcome {
            return .ok;
        }

        fn beginShutdown(raw: *anyopaque, _: std.Io) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (!self.request(.begin_shutdown)) return .failed;
            self.shutdown_submitted = true;
            return .ok;
        }

        fn backendPollInterval(raw: *anyopaque) ?u64 {
            const self: *Self = @ptrCast(@alignCast(raw));
            return if (self.shutdown_submitted and !self.stopped.load(.acquire)) std.time.ns_per_ms else null;
        }

        fn backendShutdownProgress(raw: *anyopaque) contracts.Progress {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.failed.load(.acquire)) return .failed;
            return if (self.stopped.load(.acquire)) .complete else .pending;
        }

        fn validateResume(raw: *anyopaque, _: usize) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) == .detached)
                return if (self.table.validateResume(continuation_capacity)) .ok else .failed;
            return if (self.resume_valid.load(.acquire)) .ok else .failed;
        }

        fn beginReconfiguration(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            return if (self.request(.begin_reconfiguration)) .ok else .failed;
        }

        fn reconfigurationProgress(raw: *anyopaque) contracts.Progress {
            const self: *Self = @ptrCast(@alignCast(raw));
            return switch (self.reload_state.load(.acquire)) {
                .reconfigured, .quiescing, .quiesced, .detached => .complete,
                .failed => .failed,
                else => .pending,
            };
        }

        fn abortReconfiguration(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) == .detached) {
                self.table.abortReconfigurationWithTransport(self.transport.transport());
                return .ok;
            }
            return if (self.request(.abort_reconfiguration)) .ok else .failed;
        }

        fn encodeResume(raw: *anyopaque, handle: exchange.Connection, output: []u8) ?reexec_reload.Continuation {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return null;
            const bytes = self.table.encodeResume(handle, output) orelse return null;
            return .{ .id = TableType.resume_id, .version = TableType.resume_version, .bytes = bytes };
        }

        fn restoreResume(raw: *anyopaque, handle: exchange.Connection, id: u32, version: u16, bytes: []const u8) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.running.load(.acquire) or id != TableType.resume_id or version != TableType.resume_version) return .failed;
            return if (self.table.restoreResume(handle, id, version, bytes)) .ok else .failed;
        }

        fn beginQuiesce(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            return if (self.request(.begin_quiesce)) .ok else .failed;
        }

        fn quiesceProgress(raw: *anyopaque) contracts.Progress {
            const self: *Self = @ptrCast(@alignCast(raw));
            switch (self.reload_state.load(.acquire)) {
                .failed => return .failed,
                .quiesced => {
                    self.join();
                    self.reload_state.store(.detached, .release);
                    return .complete;
                },
                .detached => return .complete,
                else => return .pending,
            }
        }

        fn abortQuiesce(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return if (self.request(.abort_quiesce)) .ok else .failed;
            if (self.transport.reloaderTransport().vtable.abort_quiesce(self.transport.reloaderTransport().context) != .ok) return .failed;
            self.reload_state.store(.idle, .release);
            self.stopping.store(false, .release);
            self.stopped.store(false, .release);
            self.start() catch return .failed;
            return .ok;
        }

        fn maximumResumeBytes(raw: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(raw));
            return self.transport.reloaderTransport().vtable.maximum_resume_bytes(self.transport.reloaderTransport().context);
        }

        fn listener(raw: *anyopaque) ?std.posix.fd_t {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return null;
            return self.transport.reloaderTransport().vtable.listener(self.transport.reloaderTransport().context);
        }

        fn connectionCount(raw: *anyopaque) usize {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return 0;
            return self.transport.reloaderTransport().vtable.connection_count(self.transport.reloaderTransport().context);
        }

        fn connectionForOrdinal(raw: *anyopaque, ordinal: usize) ?reexec_reload.TransportConnection {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return null;
            return self.transport.reloaderTransport().vtable.connection(self.transport.reloaderTransport().context, ordinal);
        }

        fn prepareForExec(raw: *anyopaque, handle: exchange.Connection) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return .failed;
            return self.transport.reloaderTransport().vtable.prepare_for_exec(self.transport.reloaderTransport().context, handle);
        }

        fn prepareListenerForExec(raw: *anyopaque) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.reload_state.load(.acquire) != .detached) return .failed;
            return self.transport.reloaderTransport().vtable.prepare_listener_for_exec(self.transport.reloaderTransport().context);
        }

        fn restoreTransport(raw: *anyopaque, saved: reexec_reload.TransportConnection) contracts.Outcome {
            const self: *Self = @ptrCast(@alignCast(raw));
            if (self.running.load(.acquire)) return .failed;
            return self.transport.reloaderTransport().vtable.restore(self.transport.reloaderTransport().context, saved);
        }

        fn run(self: *Self) void {
            reserveCoreCpu() catch {
                self.failed.store(true, .release);
                self.running.store(false, .release);
                self.stopped.store(true, .release);
                return;
            };
            while (!self.stopping.load(.acquire)) {
                const immediate = self.pass();
                if (self.failed.load(.acquire)) break;
                if (self.stopping.load(.acquire)) break;
                if (immediate) continue;
                wait(self) catch {
                    self.failed.store(true, .release);
                    break;
                };
            }
            self.running.store(false, .release);
            self.stopped.store(true, .release);
        }

        fn reserveCoreCpu() !void {
            var allowed = try posix.sched_getaffinity(0);
            if (linux.CPU_COUNT(allowed) <= 2) return;
            var removed: usize = 0;
            for (&allowed) |*word| {
                while (word.* != 0 and removed != 2) : (removed += 1)
                    word.* &= word.* - 1;
                if (removed == 2) break;
            }
            try linux.sched_setaffinity(0, &allowed);
        }

        fn signal(self: *Self) void {
            var value: u64 = 1;
            const bytes = std.mem.asBytes(&value);
            while (true) {
                const result = linux.write(self.wake_fd, bytes.ptr, bytes.len);
                switch (linux.errno(result)) {
                    .SUCCESS => return,
                    .INTR => continue,
                    else => {
                        self.failed.store(true, .release);
                        return;
                    },
                }
            }
        }

        fn wait(self: *Self) !void {
            var value: u64 = 0;
            const bytes = std.mem.asBytes(&value);
            while (true) {
                const result = linux.read(self.wake_fd, bytes.ptr, bytes.len);
                switch (linux.errno(result)) {
                    .SUCCESS => if (result == bytes.len) return else return error.InvalidWakeRead,
                    .INTR => continue,
                    else => |err| return posix.unexpectedErrno(err),
                }
            }
        }

        fn createWakeFd() !posix.fd_t {
            const result = linux.eventfd(0, linux.EFD.CLOEXEC);
            return switch (linux.errno(result)) {
                .SUCCESS => @intCast(result),
                else => |err| posix.unexpectedErrno(err),
            };
        }

        fn pass(self: *Self) bool {
            self.applyCommands();
            if (self.failed.load(.acquire)) return false;
            const transport_backend = self.transport.backend();
            const completion = transport_backend.complete(self.io, completion_budget);
            if (completion.outcome == .failed) {
                self.failed.store(true, .release);
                return false;
            }
            const output_ready = self.consumeOutput();
            if (self.fatal_requested.load(.acquire)) {
                const progress = self.table.fatalDisconnect(self.transport.transport());
                self.fatal_complete.store(progress == .complete, .release);
                if (transport_backend.submit(self.io) == .failed) self.failed.store(true, .release);
                return output_ready or completion.count == completion_budget;
            }
            self.table.advance(self.transport.transport(), self.clock.nowNs(), self.statusSnapshot());
            self.produceInput();
            self.table_shutdown_complete.store(self.table.shutdownProgress() == .complete, .release);
            self.resume_valid.store(self.table.validateResume(continuation_capacity), .release);
            self.advanceReload();
            self.updateOutputSnapshots();
            if (transport_backend.submit(self.io) == .failed) self.failed.store(true, .release);
            if (self.shutdown_requested.load(.acquire) and transport_backend.shutdownProgress() == .complete and self.table.shutdownProgress() == .complete)
                self.stopping.store(true, .release);
            return output_ready or completion.count == completion_budget;
        }

        fn statusSnapshot(self: *const Self) session_api.StatusSnapshot {
            return .{ .revision = self.status_revision, .json = self.status_bytes[0..self.status_len] };
        }

        fn applyCommands(self: *Self) void {
            while (self.commands.pop()) |command| switch (command) {
                .stop_accepting => self.table.stopAccepting(),
                .final_detachments => {
                    self.table.stageFinalDetachments();
                    self.final_detachments.store(true, .release);
                },
                .begin_shutdown => {
                    if (self.transport.backend().beginShutdown(self.io) == .failed)
                        self.failed.store(true, .release)
                    else
                        self.shutdown_requested.store(true, .release);
                },
                .begin_reconfiguration => {
                    if (self.reload_state.load(.acquire) != .idle) {
                        self.reload_state.store(.failed, .release);
                    } else {
                        self.reload_state.store(.reconfiguring, .release);
                    }
                },
                .abort_reconfiguration => {
                    self.table.abortReconfigurationWithTransport(self.transport.transport());
                    self.reload_state.store(.idle, .release);
                },
                .begin_quiesce => {
                    if (self.reload_state.load(.acquire) != .reconfigured or self.transport.reloaderTransport().vtable.begin_quiesce(self.transport.reloaderTransport().context) != .ok)
                        self.reload_state.store(.failed, .release)
                    else
                        self.reload_state.store(.quiescing, .release);
                },
                .abort_quiesce => {
                    if (self.transport.reloaderTransport().vtable.abort_quiesce(self.transport.reloaderTransport().context) != .ok)
                        self.reload_state.store(.failed, .release)
                    else
                        self.reload_state.store(.idle, .release);
                },
                .stop => self.stopping.store(true, .release),
            };
        }

        fn advanceReload(self: *Self) void {
            switch (self.reload_state.load(.acquire)) {
                .reconfiguring => {
                    if (self.outputPending() or !self.pendingEmpty() or !self.table.outputIdle()) return;
                    if (self.table.advanceReconfigurationWithTransport(self.transport.transport()) == .unsupported)
                        self.reload_state.store(.failed, .release)
                    else if (self.table.configurationBarrierStaged())
                        self.reload_state.store(.reconfigured, .release);
                },
                .quiescing => switch (self.transport.reloaderTransport().vtable.quiesce_progress(self.transport.reloaderTransport().context)) {
                    .pending => {},
                    .failed => self.reload_state.store(.failed, .release),
                    .complete => {
                        self.reload_state.store(.quiesced, .release);
                        self.stopping.store(true, .release);
                    },
                },
                else => {},
            }
        }

        fn pendingEmpty(self: *const Self) bool {
            for (self.pending_heads) |head| if (head != null) return false;
            return true;
        }

        fn consumeOutput(self: *Self) bool {
            var status_ready = false;
            for (0..3) |_| {
                const message = self.status_messages.pop() orelse break;
                if (message.len > message.bytes.len) {
                    self.failed.store(true, .release);
                    return false;
                }
                self.consumeStatusSnapshot(message.revision, message.bytes[0..message.len]);
                status_ready = true;
            }
            var examined: usize = 0;
            var empty_lanes: usize = 0;
            while (self.pending_free != null and examined < self.pending.len and empty_lanes < self.laneCount()) : (examined += 1) {
                const lane = self.nextOutputLane();
                const message = lane.exchange.to_sessions.receive() orelse {
                    empty_lanes += 1;
                    continue;
                };
                empty_lanes = 0;
                const queue: usize = if (message.kind == .status)
                    status_queue
                else if (message.connection.index < connection_capacity)
                    message.connection.index
                else {
                    if (!lane.exchange.to_sessions.release(message)) self.failed.store(true, .release);
                    continue;
                };
                const node = self.pending_free.?;
                self.pending_free = self.pending[node].next;
                self.pending[node] = .{ .message = message, .lane = lane.index };
                if (self.pending_tails[queue]) |tail| self.pending[tail].next = node else self.pending_heads[queue] = node;
                self.pending_tails[queue] = node;
                self.pending_counts[queue] += 1;
            }
            var consumed: usize = 0;
            var accepted: usize = 0;
            while (consumed < completion_budget) : (consumed += 1) {
                var selected: ?u16 = null;
                for (0..self.pending_heads.len) |offset| {
                    const queue: u16 = @intCast((@as(usize, self.pending_cursor) + offset) % self.pending_heads.len);
                    if (self.pending_heads[queue] != null) {
                        selected = queue;
                        break;
                    }
                }
                const queue = selected orelse return status_ready or (accepted != 0 and self.outputPending());
                const node = self.pending_heads[queue] orelse return false;
                const message = self.pending[node].message;
                const lane = self.outputLaneAt(self.pending[node].lane);
                const bytes = lane.exchange.to_sessions.consumerBytes(message);
                const result = switch (message.kind) {
                    .status => self.consumeStatus(message, bytes),
                    else => self.table.coreOutputConsumer(core_exchange.outputSource(lane.exchange)).consume(self.transport.transport(), message, bytes),
                };
                if (result == .backpressured and
                    (message.kind != .packet and message.kind != .packet_shared or
                        message.delivery_policy != @intFromEnum(core_exchange.DeliveryPolicy.optional)))
                {
                    self.pending_cursor = @intCast((@as(usize, queue) + 1) % self.pending_heads.len);
                    continue;
                }
                if (!lane.exchange.to_sessions.release(message)) {
                    self.failed.store(true, .release);
                    return false;
                }
                accepted += 1;
                self.pending_heads[queue] = self.pending[node].next;
                if (self.pending_heads[queue] == null) self.pending_tails[queue] = null;
                self.pending_counts[queue] -= 1;
                self.pending[node].next = self.pending_free;
                self.pending_free = node;
                self.pending_cursor = @intCast((@as(usize, queue) + 1) % self.pending_heads.len);
            }
            if (accepted == 0) return status_ready;
            if (self.outputPending()) return true;
            for (self.pending_heads) |head| if (head != null) return true;
            return false;
        }

        fn releasePendingQueue(self: *Self, queue: usize) void {
            var node = self.pending_heads[queue];
            while (node) |index| {
                const next = self.pending[index].next;
                const lane = self.outputLaneAt(self.pending[index].lane);
                if (!lane.exchange.to_sessions.release(self.pending[index].message)) self.failed.store(true, .release);
                self.pending[index].next = self.pending_free;
                self.pending_free = index;
                node = next;
            }
            self.pending_heads[queue] = null;
            self.pending_tails[queue] = null;
            self.pending_counts[queue] = 0;
        }

        fn stageStatus(self: *Self) void {
            const snapshot = self.status_source.snapshot();
            if (snapshot.revision == self.status_staged_revision or snapshot.json.len > maximum_status_bytes) return;
            var message: StatusMessage = undefined;
            message.revision = snapshot.revision;
            message.len = @intCast(snapshot.json.len);
            @memcpy(message.bytes[0..snapshot.json.len], snapshot.json);
            if (!self.status_messages.push(message)) return;
            self.status_staged_revision = snapshot.revision;
            signal(self);
        }

        fn consumeStatus(self: *Self, message: core_exchange.CoreToSession, bytes: []const u8) session_api.PacketAdmission {
            if (message.fragment != .whole or message.total_len != bytes.len or bytes.len > self.status_bytes.len) return .wrong_protocol;
            self.consumeStatusSnapshot(message.status_revision, bytes);
            return .accepted;
        }

        fn consumeStatusSnapshot(self: *Self, revision: u64, bytes: []const u8) void {
            std.debug.assert(bytes.len <= self.status_bytes.len);
            @memcpy(self.status_bytes[0..bytes.len], bytes);
            self.status_len = bytes.len;
            self.status_revision = revision;
        }

        fn produceInput(self: *Self) void {
            const input = self.table.input();
            if (input.attachments.len == 0 and input.detachments.len == 0 and input.packet_views.len == 0) return;
            _ = self.table.publishInput(self.transport.transport(), self.input);
        }

        fn updateOutputSnapshots(self: *Self) void {
            var connections: usize = 0;
            var backpressured: usize = 0;
            var queued: usize = 0;
            for (0..self.output_credit.len) |index| {
                const handle = self.transport.connectionAt(@intCast(index));
                if (handle == null) {
                    self.output_credit[index].store(0, .release);
                    self.output_queued[index].store(0, .release);
                    continue;
                }
                if (self.transport.transport().vtable.output_metrics(self.transport.transport().context, handle.?)) |metrics| {
                    const credit = self.transport.transport().vtable.output_credit(self.transport.transport().context, handle.?);
                    self.output_credit[index].store(credit, .release);
                    self.output_queued[index].store(metrics.queued_bytes, .release);
                    connections += 1;
                    queued += metrics.queued_bytes;
                    backpressured += @intFromBool(credit == 0);
                } else {
                    self.output_credit[index].store(0, .release);
                    self.output_queued[index].store(0, .release);
                }
            }
            if (self.metrics) |value| {
                value.setSessions(connections, backpressured, queued, connections * output_capacity);
                value.setSessionExchange(
                    self.outputPendingMessages(),
                    self.outputMetric(.direct),
                    self.outputMetric(.copied),
                    self.outputMetric(.fanout),
                    self.outputMetric(.deliveries),
                );
                const copies = self.table.copyMetrics();
                value.setSessionCopies(copies.prepared, copies.direct, copies.fallback);
                const queue = self.table.queueMetrics();
                value.setSessionQueue(queue.frames, queue.prepared, queue.deliveries);
            }
        }

        const Lane = struct { exchange: *ExchangeType, index: u16 };

        fn laneCount(self: *const Self) usize {
            return self.output_lane_count;
        }

        fn outputLaneAt(self: *Self, index: u16) Lane {
            std.debug.assert(index < self.laneCount());
            return .{ .exchange = self.output_lanes[index], .index = index };
        }

        fn nextOutputLane(self: *Self) Lane {
            const index = self.output_intake_cursor;
            self.output_intake_cursor = @intCast((@as(usize, index) + 1) % self.laneCount());
            return self.outputLaneAt(index);
        }

        fn outputPending(self: *const Self) bool {
            for (self.output_lanes[0..self.output_lane_count]) |lane|
                if (lane.to_sessions.pendingMessages() != 0) return true;
            return !self.status_messages.empty();
        }

        fn outputPendingMessages(self: *const Self) usize {
            var total: usize = 0;
            for (self.output_lanes[0..self.output_lane_count]) |lane| total += lane.to_sessions.pendingMessages();
            return total;
        }

        const OutputMetric = enum { direct, copied, fanout, deliveries };
        fn outputMetric(self: *const Self, comptime metric: OutputMetric) u64 {
            var total: u64 = 0;
            for (self.output_lanes[0..self.output_lane_count]) |lane| total += switch (metric) {
                .direct => lane.direct_payload_bytes.load(.acquire),
                .copied => lane.copied_payload_bytes.load(.acquire),
                .fanout => lane.fanout_payload_bytes.load(.acquire),
                .deliveries => lane.fanout_deliveries.load(.acquire),
            };
            return total;
        }
    };
}

test "output lanes retain their source through backpressure and release identical page ids independently" {
    const Wire = core_exchange.SessionExchange(.{
        .to_core_pages = 1,
        .to_sessions_pages = 2,
        .to_core_page_bytes = 64,
        .to_sessions_page_bytes = 64,
        .to_core_messages = 2,
        .to_sessions_messages = 2,
    });
    const FakeTransport = struct {
        fn transport(_: *@This()) exchange.Transport {
            return undefined;
        }
    };
    const FakeTable = struct {
        held: bool = true,
        sources: [3]core_exchange.OutputSource = undefined,
        payloads: [3][8]u8 = undefined,
        lengths: [3]u8 = @splat(0),
        count: usize = 0,

        fn coreOutputConsumer(self: *@This(), source: core_exchange.OutputSource) session_api.CoreOutputConsumer {
            return .{ .context = self, .source = source, .vtable = &.{ .consume = consume } };
        }

        fn consume(raw: *anyopaque, _: exchange.Transport, source: core_exchange.OutputSource, _: core_exchange.CoreToSession, bytes: []const u8) core_exchange.PacketAdmission {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.held and std.mem.eql(u8, bytes, "first")) return .backpressured;
            std.debug.assert(self.count < self.sources.len and bytes.len <= self.payloads[0].len);
            self.sources[self.count] = source;
            @memcpy(self.payloads[self.count][0..bytes.len], bytes);
            self.lengths[self.count] = @intCast(bytes.len);
            self.count += 1;
            return .accepted;
        }
    };
    const Status = struct {
        fn snapshot(_: *const anyopaque) session_api.StatusSnapshot {
            return .{ .revision = 0, .json = "{}" };
        }
    };
    const Input = struct {
        fn stage(_: *anyopaque, _: core_exchange.CoreInput) bool {
            return true;
        }
    };
    const TestWorker = Worker(FakeTransport, FakeTable, Wire, 2, 2, 64, 0, 2);
    var first = Wire{};
    first.initialize();
    var second = Wire{};
    second.initialize();
    var transport = FakeTransport{};
    var table = FakeTable{};
    const outputs = [_]*Wire{ &first, &second };
    var worker = try TestWorker.init(
        &transport,
        &table,
        &outputs,
        .{ .context = undefined, .vtable = &.{ .stage = Input.stage } },
        std.testing.io,
        .{ .context = undefined, .now_ns = undefined },
        .{ .context = undefined, .vtable = &.{ .snapshot = Status.snapshot } },
    );
    defer worker.deinit();
    var first_output = try worker.outputLane(&first);
    var second_output = try worker.outputLane(&second);
    const target = core_exchange.OutputTarget{
        .connection = .{ .index = 0, .generation = 1 },
        .protocol = .{ .value = 772 },
        .phase = .play,
        .class = .other,
        .policy = .reliable,
    };
    try std.testing.expectEqual(core_exchange.PacketAdmission.accepted, first_output.egress().stage(.{ .connection = target.connection, .protocol = target.protocol, .phase = target.phase, .class = target.class, .policy = target.policy, .payload = "first" }));
    try std.testing.expectEqual(core_exchange.PacketAdmission.accepted, second_output.egress().stage(.{ .connection = target.connection, .protocol = target.protocol, .phase = target.phase, .class = target.class, .policy = target.policy, .payload = "second" }));
    const healthy = core_exchange.OutputTarget{
        .connection = .{ .index = 1, .generation = 1 },
        .protocol = target.protocol,
        .phase = target.phase,
        .class = target.class,
        .policy = target.policy,
    };
    try std.testing.expectEqual(core_exchange.PacketAdmission.accepted, first_output.egress().stage(.{ .connection = healthy.connection, .protocol = healthy.protocol, .phase = healthy.phase, .class = healthy.class, .policy = healthy.policy, .payload = "healthy" }));
    try std.testing.expectEqual(first.to_sessions.peek(0).?.page, second.to_sessions.peek(0).?.page);

    try std.testing.expect(worker.consumeOutput());
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(core_exchange.outputSource(&first).eql(table.sources[0]));
    try std.testing.expectEqualStrings("healthy", table.payloads[0][0..table.lengths[0]]);
    try std.testing.expectEqual(@as(usize, 0), first.to_sessions.pendingMessages());
    try std.testing.expectEqual(@as(usize, 0), second.to_sessions.pendingMessages());
    table.held = false;
    _ = worker.consumeOutput();
    try std.testing.expectEqual(@as(usize, 3), table.count);
    try std.testing.expect(core_exchange.outputSource(&first).eql(table.sources[1]));
    try std.testing.expect(core_exchange.outputSource(&second).eql(table.sources[2]));
    try std.testing.expectEqualStrings("first", table.payloads[1][0..table.lengths[1]]);
    try std.testing.expectEqualStrings("second", table.payloads[2][0..table.lengths[2]]);
    try std.testing.expect(first.to_sessions.acquireFor(64) != null);
    try std.testing.expect(second.to_sessions.acquireFor(64) != null);
}
