const std = @import("std");
const builtin = @import("builtin");
const config_module = @import("config.zig");
const hot_reload = @import("hot_reload.zig");
const huge_page_allocator = @import("huge_page_allocator.zig");
pub const reload_abi = @import("hot_reload_abi.zig");
const tui = @import("tui.zig");
const async_log = @import("async_log.zig");
const reactor_connection = @import("reactor_connection.zig");
const reactor_linux = @import("reactor_linux.zig");
const reactor_kernel = @import("reactor_kernel.zig");
const reactor_exchange = @import("reactor_exchange.zig");
const reactor_dashboard = @import("reactor_dashboard.zig");
const reactor_completion = @import("reactor_completion.zig");
const reactor_network = @import("reactor_network.zig");
const reactor_transport = @import("reactor_transport.zig");

const linux = std.os.linux;
const net = std.Io.net;
const posix = std.posix;

const io_log = std.log.scoped(.server_io);
const protocol_log = std.log.scoped(.protocol);
const tick_log = std.log.scoped(.simulation);
var shutdown_requested = std.atomic.Value(bool).init(false);

pub const RunOptions = struct {
    tui: bool = false,
    /// Null selects the first CPU allowed by the process cpuset. On the
    /// supported Linux targets CPU numbering places performance cores first;
    /// operators can select an exact logical CPU with --cpu=N.
    cpu: ?usize = null,
};

const config = config_module.value;

const Completion = reactor_completion.Tag;
const log_completion_user_data_base = (Completion{ .kind = .log, .index = 0, .token = 0 }).pack();

const Client = reactor_connection.Connection;

const Reload = struct {
    requester: reload_abi.ConnectionHandle,
    started_ms: u64,
    connection_capacity_before: usize,
    reactor_memory_before: usize,
};

const ReloadNotice = struct {
    requester: reload_abi.ConnectionHandle,
    elapsed_ms: u64,
};

pub const Server = struct {
    runtime_storage: std.heap.ArenaAllocator,
    io: std.Io,
    network: reactor_network.Network,
    secure_random: std.Random.ChaCha,
    mailbox: reactor_exchange.Mailbox,
    transport: reactor_transport.State,
    kernel_context: reactor_kernel.Context,
    kernel_api: reload_abi.KernelApi,
    tick_deadline: linux.timespec = undefined,
    logs: async_log.Queue,
    tick_module: hot_reload.Manager,
    reload: ?Reload = null,
    reload_notice: ?ReloadNotice = null,
    dashboard: reactor_dashboard.Dashboard,
    tick_sequence: u64 = 0,
    save_ticks_remaining: u64,
    connected_protocols: [reactor_connection.virtual_capacity]i32 = undefined,

    pub fn allocateRuntimeStorage(
        self: *Server,
        allocator: std.mem.Allocator,
    ) !void {
        self.runtime_storage = std.heap.ArenaAllocator.init(allocator);
        errdefer self.runtime_storage.deinit();
        const storage = self.runtime_storage.allocator();
        try self.network.allocate(storage);
        try self.mailbox.allocate(storage);
        try self.transport.allocate(storage);
        errdefer self.transport.deinit();
        self.initializeApis();
        try self.logs.allocate(storage);
    }

    fn initializeApis(self: *Server) void {
        self.kernel_context = .{
            .connections = &self.network.connections,
            .output = &self.network.output,
            .transport = &self.transport,
            .random = &self.secure_random,
        };
        self.kernel_api = self.kernel_context.api();
    }

    pub fn initClients(self: *Server) void {
        self.network.connections.reset();
    }

    fn init(self: *Server, allocator: std.mem.Allocator, io: std.Io, address: net.IpAddress, dashboard: ?*tui.Terminal) !void {
        self.* = undefined;
        try self.allocateRuntimeStorage(allocator);
        errdefer {
            self.transport.deinit();
            self.network.connections.deinit();
            self.runtime_storage.deinit();
        }
        self.io = io;
        var entropy: [std.Random.ChaCha.secret_seed_length]u8 = undefined;
        try reactor_linux.entropy(&entropy);
        self.secure_random = std.Random.ChaCha.init(entropy);
        self.reload = null;
        self.reload_notice = null;
        self.dashboard = reactor_dashboard.Dashboard.init(dashboard);
        self.tick_sequence = 0;
        self.save_ticks_remaining = config.checkpoint_interval_ticks;
        self.mailbox.clear();
        try self.initializeTickModule(io, dashboard);
        errdefer self.tick_module.deinit();
        self.initClients();
        self.tick_deadline = try reactor_linux.firstDeadline(config.ticks_per_second);
        try self.network.initializeRing(allocator);
        errdefer self.network.deinit();
        try self.network.initializeListener(address);
        self.logs.activate();
        errdefer self.logs.deactivate();
        self.logStartup(address);
        try self.network.submitAccept();
        _ = try self.network.ring.submit();
    }

    fn initializeTickModule(self: *Server, io: std.Io, dashboard: ?*tui.Terminal) !void {
        self.tick_module = try hot_reload.Manager.init(
            io,
            config.tick_module_path,
            config.reload_state_virtual_bytes,
            .disk,
        );
        errdefer self.tick_module.deinit();
        try self.tick_module.loadInitial(self.reactorMemoryBytes());
        try self.network.ensurePlayerCapacity(self.tick_module.maximumPlayers());
        try self.tick_module.validateActiveMemory(self.reactorMemoryBytes());
        self.tick_module.setProfilingEnabled(dashboard != null);
    }

    fn logStartup(self: *const Server, address: net.IpAddress) void {
        io_log.info("event=server_listening address={f} max_players={} connection_capacity={}", .{ address, self.tick_module.maximumPlayers(), self.network.connections.items.len });
        io_log.info("event=memory_layout server_bytes={} client_bytes={} output_pool_bytes={} reactor_committed_bytes={} generation_bytes={} configured_max_bytes={}", .{
            @sizeOf(Server),
            @sizeOf(Client),
            config.output_buffer_count * config.output_buffer_size,
            self.reactorMemoryBytes(),
            self.tick_module.generationMemoryBytes(),
            self.tick_module.maximumMemoryBytes(),
        });
    }

    fn deinit(self: *Server) void {
        self.logs.deactivate();
        self.tick_module.deinit();
        self.network.deinit();
        self.transport.deinit();
        self.runtime_storage.deinit();
    }

    fn run(self: *Server) !void {
        var cqes_buffer: [config.completion_batch]linux.io_uring_cqe = undefined;
        var event_loop_iterations: u64 = 0;
        while (true) {
            event_loop_iterations +%= 1;
            std.debug.assert(event_loop_iterations != 0);
            const completed_this_tick = try self.waitForTickBoundary(&cqes_buffer);
            reactor_linux.advanceDeadline(&self.tick_deadline, config.ticks_per_second);
            self.dashboard.completed(completed_this_tick);
            const shutting_down = shutdown_requested.load(.acquire);
            if (shutting_down) return self.gracefulShutdown();
            try self.renderDashboardIfDue();
            var exchange = self.tickExchange();
            const invocation = reload_abi.TickInvocation{ .exchange = &exchange };
            self.invokeTickModule(&invocation) catch |err|
                tick_log.err("event=tick_failed sequence={} err={}", .{ self.tick_sequence, err });
            try self.consumeTickCommands(&exchange);
            if (self.reload != null) {
                try self.performReload();
            } else {
                self.saveIfDue();
            }
            self.tick_sequence +%= 1;
            std.debug.assert(self.tick_sequence != 0);
            try self.stagePendingIo();
        }
    }

    fn gracefulShutdown(self: *Server) !void {
        for (0..self.network.connections.items.len) |slot|
            self.network.close(&self.mailbox, slot, .server_shutdown);
        var exchange = self.tickExchange();
        try self.invokeTickModule(&.{ .exchange = &exchange });
        try self.consumeTickCommandsBuffered(&exchange);
        try self.tick_module.save();
    }

    fn invokeTickModule(
        self: *Server,
        invocation: *const reload_abi.TickInvocation,
    ) !void {
        self.tick_module.tick(invocation) catch |err| {
            try self.transport.finishTick();
            return err;
        };
        try self.transport.finishTick();
    }

    fn stagePendingIo(self: *Server) !void {
        try self.logs.submit(&self.network.ring, log_completion_user_data_base);
    }

    fn waitForTickBoundary(
        self: *Server,
        storage: *[config.completion_batch]linux.io_uring_cqe,
    ) !u32 {
        const deadline_ns = reactor_linux.nanoseconds(self.tick_deadline);
        const now_ns = try reactor_linux.monotonicNanoseconds();
        const remaining_ns = deadline_ns -| now_ns;
        const timeout = linux.kernel_timespec{
            .sec = @intCast(remaining_ns / std.time.ns_per_s),
            .nsec = @intCast(remaining_ns % std.time.ns_per_s),
        };
        _ = try self.network.ring.timeout(
            (Completion{ .kind = .tick_timeout, .index = 0, .token = 0 }).pack(),
            &timeout,
            0,
            0,
        );
        var completion_count: u32 = 0;
        for (0..std.math.maxInt(u32)) |_| {
            _ = self.network.ring.submit_and_wait(1) catch |err| {
                if (err == error.SignalInterrupt and
                    shutdown_requested.load(.acquire))
                    return completion_count;
                return err;
            };
            self.dashboard.submitted();
            const cqes = storage[0..try self.network.ring.copy_cqes(storage, 0)];
            var reached_deadline = false;
            for (cqes) |cqe| {
                const completion = Completion.unpack(cqe.user_data);
                if (completion.kind == .tick_timeout) {
                    reached_deadline = true;
                    continue;
                }
                try self.complete(cqe);
                completion_count += 1;
            }
            if (reached_deadline) return completion_count;
            try self.logs.submit(&self.network.ring, log_completion_user_data_base);
        }
        return error.EventLoopIterationLimitExceeded;
    }

    fn renderDashboardIfDue(self: *Server) !void {
        try self.dashboard.render(
            try reactor_linux.monotonicMilliseconds(),
            &self.network.connections,
            &self.network.output,
            &self.tick_module,
        );
    }

    fn complete(self: *Server, cqe: linux.io_uring_cqe) !void {
        const completion = Completion.unpack(cqe.user_data);
        switch (completion.kind) {
            .accept => try self.network.completeAccept(&self.mailbox, cqe),
            .recv => try self.network.completeRecv(&self.mailbox, completion, cqe),
            .send => try self.network.completeSend(&self.mailbox, completion, cqe),
            .close => {},
            .log => self.logs.complete(completion.index, cqe.res),
            .tick_timeout => {},
        }
    }

    fn performReload(self: *Server) !void {
        const reload = self.reload orelse return;
        const started_ns = try reactor_linux.monotonicNanoseconds();
        self.prepareReloadCandidate() catch |err| return self.abortReload(err);
        const prepared_ns = try reactor_linux.monotonicNanoseconds();
        self.tick_module.save() catch |err| return self.abortReload(err);
        const saved_ns = try reactor_linux.monotonicNanoseconds();
        self.beginClientReconfiguration() catch |err| return self.abortReload(err);
        const reconfigured_ns = try reactor_linux.monotonicNanoseconds();
        self.tick_module.transitionPreparedReload(
            self.reactorMemoryBytes(),
            reload.reactor_memory_before,
        ) catch |err| {
            self.rollbackReloadCapacity(reload);
            self.resetReloadBoundaryInput();
            self.attachReloadedConnections();
            return self.abortReload(err);
        };
        const activated_ns = try reactor_linux.monotonicNanoseconds();
        self.resetReloadBoundaryInput();
        self.attachReloadedConnections();
        const attached_ns = try reactor_linux.monotonicNanoseconds();
        const completed_ms = try reactor_linux.monotonicMilliseconds();
        const elapsed = completed_ms -| reload.started_ms;
        tick_log.info(
            "event=reload_profile prepare_ms={d:.3} save_ms={d:.3} reconfigure_ms={d:.3} transition_ms={d:.3} attach_ms={d:.3} operation_ms={d:.3} request_ms={}",
            .{
                elapsedMilliseconds(prepared_ns - started_ns),
                elapsedMilliseconds(saved_ns - prepared_ns),
                elapsedMilliseconds(reconfigured_ns - saved_ns),
                elapsedMilliseconds(activated_ns - reconfigured_ns),
                elapsedMilliseconds(attached_ns - activated_ns),
                elapsedMilliseconds(attached_ns - started_ns),
                elapsed,
            },
        );
        tick_log.info("event=reload_complete generation={} elapsed_ms={} max_players={} default_gamemode={}", .{
            self.tick_module.activeGenerationNumber(),
            elapsed,
            self.tick_module.maximumPlayers(),
            self.tick_module.defaultGamemode(),
        });
        self.reload = null;
        self.reload_notice = .{ .requester = reload.requester, .elapsed_ms = elapsed };
        self.save_ticks_remaining = config.checkpoint_interval_ticks;
    }

    fn elapsedMilliseconds(nanoseconds: u64) f64 {
        return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
    }

    fn saveIfDue(self: *Server) void {
        std.debug.assert(self.save_ticks_remaining > 0);
        self.save_ticks_remaining -= 1;
        if (self.save_ticks_remaining != 0) return;
        self.tick_module.save() catch |err|
            tick_log.err("event=periodic_save_failed err={s}", .{@errorName(err)});
        self.save_ticks_remaining = config.checkpoint_interval_ticks;
    }

    fn prepareReloadCandidate(self: *Server) !void {
        const reload = &self.reload.?;
        reload.connection_capacity_before = self.network.connections.items.len;
        reload.reactor_memory_before = self.reactorMemoryBytes();
        const protocol_count = self.collectConnectedProtocols(&self.connected_protocols);
        try self.tick_module.prepareReload(self.connected_protocols[0..protocol_count]);
        errdefer self.tick_module.cancelPendingReload();
        if (self.tick_module.pendingMaximumPlayers() <
            self.network.connections.reserved_player_count)
            return error.TickModuleMaximumBelowConnectedPlayers;
        try self.network.ensurePlayerCapacity(self.tick_module.pendingMaximumPlayers());
    }

    fn abortReload(self: *Server, err: anyerror) void {
        if (self.reload) |reload| self.rollbackReloadCapacity(reload);
        self.tick_module.cancelPendingReload();
        self.failReload(err);
    }

    fn rollbackReloadCapacity(self: *Server, reload: Reload) void {
        if (self.network.connections.items.len == reload.connection_capacity_before) return;
        self.network.shrinkConnectionCapacity(reload.connection_capacity_before) catch
            @panic("failed to roll back connection capacity after reload");
    }

    fn beginClientReconfiguration(self: *Server) !void {
        const minimum_transition_bytes = 16 + 6;
        if (!self.network.output.canReservePlayBatch(
            self.network.connections.items,
            minimum_transition_bytes,
        )) return error.ReloadTransitionBackpressured;
        var exchange = self.tickExchange();
        try self.tick_module.beginReconfiguration(&exchange);
        try self.consumeTickCommandsBuffered(&exchange);
        var transition_count: usize = 0;
        for (self.network.connections.items) |*client| {
            if (client.phase == .play) {
                client.reload_transition_pending = true;
                transition_count += 1;
            }
        }
        tick_log.info("event=reload_reconfiguration_started clients={}", .{transition_count});
        try self.network.flushAll();
    }

    fn resetReloadBoundaryInput(self: *Server) void {
        for (0..self.network.connections.items.len) |slot| {
            const state = self.network.connections.items[slot].phase;
            if (state != .free and state != .play) {
                const handle = self.connectionHandle(@intCast(slot));
                self.network.close(&self.mailbox, slot, .server_shutdown);
                self.network.connections.release(handle);
            }
        }
        self.mailbox.clear();
        for (self.network.connections.items) |*client| {
            std.debug.assert(!client.scratch_lease_active);
            std.debug.assert(!client.output_lease_active);
        }
    }

    fn attachReloadedConnections(self: *Server) void {
        for (self.network.connections.items, 0..) |*client, slot| {
            if (client.phase != .play or !client.player_reserved) continue;
            client.reload_transition_pending = false;
            if (!self.mailbox.attachedConnection(
                self.connectionHandle(@intCast(slot)),
                client.protocol_number,
                client.player_uuid,
                client.player_name[0..client.player_name_len],
                .play,
                true,
            )) @panic("tick event buffer exhausted while attaching retained connections");
        }
    }

    fn failReload(self: *Server, err: anyerror) void {
        const reload = self.reload orelse return;
        tick_log.err("event=reload_failed module={s} err={}", .{ config.tick_module_path, err });
        const completed_ms = reactor_linux.monotonicMilliseconds() catch reload.started_ms;
        self.reload = null;
        self.stageReloadResult(
            reload.requester,
            false,
            completed_ms -| reload.started_ms,
        );
    }

    fn collectConnectedProtocols(
        self: *const Server,
        destination: *[reactor_connection.virtual_capacity]i32,
    ) usize {
        var count: usize = 0;
        for (self.network.connections.items) |*client| {
            if (client.phase == .free or client.protocol_number == 0) continue;
            destination[count] = client.protocol_number;
            count += 1;
        }
        return count;
    }

    fn reactorMemoryBytes(self: *const Server) usize {
        return std.mem.alignForward(usize, @sizeOf(Server), std.heap.pageSize()) +
            self.runtime_storage.queryCapacity() +
            self.network.connections.committedBytes() +
            @as(usize, config.recv_buffer_size) * config.recv_buffer_count;
    }

    pub fn connectionHandle(self: *const Server, slot: u16) reload_abi.ConnectionHandle {
        return self.network.connections.handle(slot);
    }

    fn stageReloadResult(
        self: *Server,
        connection: reload_abi.ConnectionHandle,
        succeeded: bool,
        elapsed_ms: u64,
    ) void {
        const slot = self.slotForHandle(connection) orelse return;
        if (!self.network.playSlotValid(@intCast(slot))) return;
        if (!self.mailbox.reloadResult(
            connection,
            succeeded,
            elapsed_ms,
        )) tick_log.err("event=reload_result_dropped reason=tick_event_buffer_full", .{});
    }

    pub fn tickExchange(self: *Server) reload_abi.TickExchange {
        return self.mailbox.begin(
            self.tick_sequence,
            reactor_linux.nanoseconds(self.tick_deadline),
            &self.kernel_api,
        );
    }

    pub fn consumeTickCommands(self: *Server, exchange: *const reload_abi.TickExchange) !void {
        try self.consumeTickCommandsBuffered(exchange);
        try self.network.flushAll();
    }

    pub fn consumeTickCommandsBuffered(self: *Server, exchange: *const reload_abi.TickExchange) !void {
        var iterator = try self.mailbox.iterator(exchange);
        const command_limit = exchange.commands.len / @sizeOf(reload_abi.RecordHeader) + 1;
        for (0..command_limit) |_| {
            const record = (try iterator.next()) orelse break;
            try self.consumeTickCommand(record);
        } else return error.TickCommandCountExceeded;
        self.mailbox.finish(exchange);
    }

    fn slotForHandle(self: *const Server, handle: reload_abi.ConnectionHandle) ?usize {
        return self.network.connections.lookup(handle);
    }

    fn releaseClosedConnection(
        self: *Server,
        handle: reload_abi.ConnectionHandle,
    ) void {
        self.network.connections.release(handle);
    }

    fn applyProtocolSelection(
        self: *Server,
        command: *const reload_abi.SelectProtocolCommand,
    ) !?u16 {
        const slot_index = self.slotForHandle(command.connection) orelse return null;
        const slot: u16 = @intCast(slot_index);
        const client = &self.network.connections.items[slot_index];
        if (client.phase != .handshaking) return null;
        if (!self.tick_module.supportsProtocol(command.protocol_number)) {
            protocol_log.warn(
                "event=protocol_selection_unavailable slot={} protocol={}",
                .{ slot, command.protocol_number },
            );
            self.network.close(&self.mailbox, slot_index, .kicked);
            return null;
        }
        _ = self.network.connections.selectProtocol(
            command.connection,
            command.protocol_number,
            command.intent,
        ) orelse return null;
        protocol_log.info(
            "event=protocol_selected slot={} protocol={} intent={}",
            .{ slot, command.protocol_number, command.intent },
        );
        return slot;
    }

    fn consumeTickCommand(self: *Server, record: reload_abi.CommandRecord) !void {
        switch (record.header.kind) {
            reload_abi.CommandKind.log => self.logs.enqueue((try record.log()).message()),
            reload_abi.CommandKind.close_connection => self.commandClose(try record.closeConnection()),
            reload_abi.CommandKind.close_after_output => self.commandCloseAfterOutput(try record.closeAfterOutput()),
            reload_abi.CommandKind.release_connection => self.releaseClosedConnection((try record.releaseConnection()).connection),
            reload_abi.CommandKind.request_reload => self.commandReload(try record.requestReload()),
            reload_abi.CommandKind.reserve_player => self.commandReservePlayer(try record.reservePlayer()),
            reload_abi.CommandKind.enter_configuration => self.commandEnterConfiguration(try record.enterConfiguration()),
            reload_abi.CommandKind.enter_play => self.commandEnterPlay(try record.enterPlay()),
            reload_abi.CommandKind.select_protocol => _ = try self.applyProtocolSelection(try record.selectProtocol()),
            else => return error.UnsupportedTickCommand,
        }
    }

    fn commandClose(self: *Server, command: *const reload_abi.CloseConnectionCommand) void {
        if (self.slotForHandle(command.connection)) |slot|
            self.network.close(&self.mailbox, slot, command.reason);
    }

    fn commandCloseAfterOutput(self: *Server, command: *const reload_abi.CloseAfterOutputCommand) void {
        if (self.slotForHandle(command.connection)) |slot| {
            self.network.connections.items[slot].close_after_send = true;
            self.network.connections.items[slot].close_after_send_reason = .kicked;
        }
    }

    fn commandReload(self: *Server, command: *const reload_abi.RequestReloadCommand) void {
        if (self.reload != null or self.slotForHandle(command.connection) == null) return;
        self.reload = .{
            .requester = command.connection,
            .started_ms = reactor_linux.monotonicMilliseconds() catch 0,
            .connection_capacity_before = self.network.connections.items.len,
            .reactor_memory_before = self.reactorMemoryBytes(),
        };
        tick_log.info("event=reload_requested connection={}", .{command.connection.value()});
    }

    fn commandReservePlayer(self: *Server, command: *const reload_abi.ReservePlayerCommand) void {
        self.network.connections.reservePlayer(
            command.connection,
            @bitCast(command.player_uuid),
            command.name,
            command.name_len,
        );
    }

    fn commandEnterConfiguration(self: *Server, command: *const reload_abi.EnterConfigurationCommand) void {
        const connection_index = self.slotForHandle(command.connection) orelse return;
        const reloading = self.network.connections.items[connection_index].reload_transition_pending;
        const slot = self.network.connections.enterConfiguration(command.connection) orelse return;
        if (reloading) {
            protocol_log.info("event=reconfiguration_acknowledged slot={} next_state=configuration", .{slot});
        } else {
            protocol_log.info("event=login_acknowledged slot={} next_state=configuration", .{slot});
        }
    }

    fn commandEnterPlay(self: *Server, command: *const reload_abi.EnterPlayCommand) void {
        const slot = self.network.connections.enterPlay(command.connection) orelse return;
        protocol_log.info("event=finish_configuration_ack slot={} next_state=play", .{slot});
        if (self.reload_notice) |notice| {
            if (notice.requester.value() == command.connection.value()) {
                self.stageReloadResult(notice.requester, true, notice.elapsed_ms);
                self.reload_notice = null;
            }
        }
    }
};

test "reload attachment preserves durable transport state" {
    const server = try std.heap.page_allocator.create(Server);
    defer std.heap.page_allocator.destroy(server);
    try server.allocateRuntimeStorage(std.testing.allocator);
    defer {
        server.transport.deinit();
        server.network.connections.deinit();
        server.runtime_storage.deinit();
    }
    server.initClients();
    server.mailbox.clear();
    const client = &server.network.connections.items[0];
    client.phase = .play;
    client.player_reserved = true;
    client.protocol_number = 772;
    client.compression_threshold = 256;
    const secret = [_]u8{0x41} ** 16;
    const Cfb8 = @import("crypto_support.zig").Cfb8;
    client.encryptor = Cfb8.init(secret);
    client.decryptor = Cfb8.init(secret);
    server.attachReloadedConnections();

    try std.testing.expectEqual(@as(?i32, 256), client.compression_threshold);
    try std.testing.expect(client.encryptor != null);
    try std.testing.expect(client.decryptor != null);
    try std.testing.expectEqual(reactor_connection.Phase.play, client.phase);
}

pub fn run(init: std.process.Init, options: RunOptions) !void {
    shutdown_requested.store(false, .release);
    const cpu_placement = try reactor_linux.pinOneCpu(options.cpu);
    tick_log.info("event=cpu_affinity cpu={d} mode={s}", .{
        cpu_placement.simulation,
        if (options.cpu == null) "auto" else "explicit",
    });
    const shutdown_action: posix.Sigaction = .{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var old_interrupt: posix.Sigaction = undefined;
    var old_terminate: posix.Sigaction = undefined;
    posix.sigaction(.INT, &shutdown_action, &old_interrupt);
    defer posix.sigaction(.INT, &old_interrupt, null);
    posix.sigaction(.TERM, &shutdown_action, &old_terminate);
    defer posix.sigaction(.TERM, &old_terminate, null);

    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };
    const allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        huge_page_allocator.allocator;

    var terminal: tui.Terminal = undefined;
    const dashboard: ?*tui.Terminal = if (options.tui) dashboard: {
        terminal = try tui.Terminal.init();
        break :dashboard &terminal;
    } else null;
    defer if (dashboard) |value| value.deinit();

    const address = try net.IpAddress.parse("127.0.0.1", config.port);
    const server = try allocator.create(Server);
    defer allocator.destroy(server);
    @memset(std.mem.asBytes(server), 0);
    try server.init(allocator, init.io, address, dashboard);
    defer server.deinit();
    try reactor_linux.registerWorkerAffinity(&server.network.ring, &cpu_placement.io_workers);
    io_log.info("event=io_worker_affinity cpus={d} simulation_cpu={d}", .{
        linux.CPU_COUNT(cpu_placement.io_workers),
        cpu_placement.simulation,
    });
    try server.run();
}

fn handleShutdownSignal(_: posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}
