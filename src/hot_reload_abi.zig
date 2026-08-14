const std = @import("std");

pub const major_version: u16 = 12;
pub const minor_version: u16 = 0;

pub const Symbol = struct {
    pub const describe: [:0]const u8 = "lightning_rod_tick_describe";
    pub const initialize: [:0]const u8 = "lightning_rod_tick_initialize";
    pub const tick: [:0]const u8 = "lightning_rod_tick";
    pub const save: [:0]const u8 = "lightning_rod_tick_save";
    pub const load: [:0]const u8 = "lightning_rod_tick_load";
    pub const begin_reconfiguration: [:0]const u8 = "lightning_rod_tick_begin_reconfiguration";
    pub const deinitialize: [:0]const u8 = "lightning_rod_tick_deinitialize";
    pub const set_profiling: [:0]const u8 = "lightning_rod_tick_set_profiling";
    pub const metrics: [:0]const u8 = "lightning_rod_tick_metrics";
};

pub const Header = extern struct {
    size: u32,
    major: u16,
    minor: u16,

    pub fn init(comptime T: type) Header {
        return .{
            .size = @sizeOf(T),
            .major = major_version,
            .minor = minor_version,
        };
    }

    pub fn supports(self: Header, minimum_size: usize) bool {
        return self.major == major_version and self.size >= minimum_size;
    }
};

pub const ConnectionHandle = extern struct {
    index: u32,
    generation: u32,

    pub fn value(self: ConnectionHandle) u64 {
        return (@as(u64, self.generation) << 32) | self.index;
    }
};

pub const Bytes = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn slice(self: Bytes) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const MutableBytes = extern struct {
    ptr: [*]u8,
    len: usize,

    pub fn slice(self: MutableBytes) []u8 {
        return self.ptr[0..self.len];
    }
};

pub const RecordHeader = extern struct {
    size: u32,
    kind: u16,
    flags: u16,
};

pub const EventKind = struct {
    pub const connected: u16 = 1;
    pub const disconnected: u16 = 3;
    pub const reload_result: u16 = 6;
    pub const raw_input: u16 = 7;
    pub const attached_connection: u16 = 8;
};

pub const DisconnectReason = enum(u8) {
    peer_closed,
    timeout,
    transport_error,
    kicked,
    server_shutdown,
};

pub const ConnectedEvent = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(ConnectedEvent),
        .kind = EventKind.connected,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const DisconnectedEvent = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(DisconnectedEvent),
        .kind = EventKind.disconnected,
        .flags = 0,
    },
    connection: ConnectionHandle,
    reason: DisconnectReason = .peer_closed,
    _reserved: [7]u8 = @splat(0),
};

pub const ReloadResultEvent = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(ReloadResultEvent),
        .kind = EventKind.reload_result,
        .flags = 0,
    },
    connection: ConnectionHandle,
    elapsed_ms: u64,
    succeeded: u8,
    _reserved: [7]u8 = [_]u8{0} ** 7,
};

pub const RawInputEvent = extern struct {
    record: RecordHeader,
    connection: ConnectionHandle,
    payload_len: u32,
    _reserved: u32 = 0,

    pub fn payload(self: *const RawInputEvent) []const u8 {
        const bytes: [*]const u8 = @ptrCast(self);
        return bytes[@sizeOf(RawInputEvent)..][0..self.payload_len];
    }
};

pub const AttachedConnectionEvent = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(AttachedConnectionEvent),
        .kind = EventKind.attached_connection,
        .flags = 0,
    },
    connection: ConnectionHandle,
    player_uuid: [16]u8,
    protocol_number: i32,
    phase: ConnectionPhase,
    name_len: u8,
    reconfiguring: u8,
    _reserved: u8 = 0,
    name: [16]u8,
};

pub const ConnectionPhase = enum(u8) {
    configuration,
    play,
};

pub const EventWriter = struct {
    buffer: []u8,
    written: *usize,

    pub fn connected(self: EventWriter, connection: ConnectionHandle) bool {
        return self.append(ConnectedEvent{ .connection = connection });
    }

    pub fn disconnected(
        self: EventWriter,
        connection: ConnectionHandle,
        reason: DisconnectReason,
    ) bool {
        return self.append(DisconnectedEvent{
            .connection = connection,
            .reason = reason,
        });
    }

    pub fn reloadResult(
        self: EventWriter,
        connection: ConnectionHandle,
        succeeded: bool,
        elapsed_ms: u64,
    ) bool {
        return self.append(ReloadResultEvent{
            .connection = connection,
            .elapsed_ms = elapsed_ms,
            .succeeded = @intFromBool(succeeded),
        });
    }

    pub fn rawInput(self: EventWriter, connection: ConnectionHandle, payload: []const u8) bool {
        if (payload.len > std.math.maxInt(u32)) return false;
        const payload_size = @sizeOf(RawInputEvent) + payload.len;
        const record_size = std.mem.alignForward(usize, payload_size, record_alignment);
        const start = self.written.*;
        if (record_size > self.buffer.len -| start) return false;
        const destination = self.buffer[start..][0..record_size];
        @memset(destination, 0);
        const output: *RawInputEvent = @ptrCast(@alignCast(destination.ptr));
        output.* = .{
            .record = .{
                .size = @intCast(payload_size),
                .kind = EventKind.raw_input,
                .flags = 0,
            },
            .connection = connection,
            .payload_len = @intCast(payload.len),
        };
        @memcpy(destination[@sizeOf(RawInputEvent)..][0..payload.len], payload);
        self.written.* = start + record_size;
        return true;
    }

    pub fn attachedConnection(
        self: EventWriter,
        connection: ConnectionHandle,
        protocol_number: i32,
        player_uuid: u128,
        name: []const u8,
        phase: ConnectionPhase,
        reconfiguring: bool,
    ) bool {
        if (name.len > 16) return false;
        var name_storage: [16]u8 = @splat(0);
        @memcpy(name_storage[0..name.len], name);
        return self.append(AttachedConnectionEvent{
            .connection = connection,
            .player_uuid = @bitCast(player_uuid),
            .protocol_number = protocol_number,
            .phase = phase,
            .name_len = @intCast(name.len),
            .reconfiguring = @intFromBool(reconfiguring),
            .name = name_storage,
        });
    }

    fn append(self: EventWriter, value: anytype) bool {
        const T = @TypeOf(value);
        comptime std.debug.assert(@alignOf(T) <= record_alignment);
        const record_size = std.mem.alignForward(usize, @sizeOf(T), record_alignment);
        const start = self.written.*;
        if (record_size > self.buffer.len -| start) return false;
        const destination = self.buffer[start..][0..record_size];
        @memset(destination, 0);
        const output: *T = @ptrCast(@alignCast(destination.ptr));
        output.* = value;
        self.written.* = start + record_size;
        return true;
    }
};

pub const EventRecord = struct {
    header: *const RecordHeader,
    bytes: []const u8,

    pub fn connected(self: EventRecord) !*const ConnectedEvent {
        if (self.header.kind != EventKind.connected or self.bytes.len != @sizeOf(ConnectedEvent))
            return error.InvalidTickEvent;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn disconnected(self: EventRecord) !*const DisconnectedEvent {
        if (self.header.kind != EventKind.disconnected or self.bytes.len != @sizeOf(DisconnectedEvent))
            return error.InvalidTickEvent;
        const event: *const DisconnectedEvent = @ptrCast(@alignCast(self.bytes.ptr));
        if (@intFromEnum(event.reason) > @intFromEnum(DisconnectReason.server_shutdown) or
            !std.mem.allEqual(u8, &event._reserved, 0))
            return error.InvalidTickEvent;
        return event;
    }

    pub fn rawInput(self: EventRecord) !*const RawInputEvent {
        if (self.header.kind != EventKind.raw_input or self.bytes.len < @sizeOf(RawInputEvent))
            return error.InvalidTickEvent;
        const event: *const RawInputEvent = @ptrCast(@alignCast(self.bytes.ptr));
        if (event._reserved != 0 or @sizeOf(RawInputEvent) + event.payload_len != self.bytes.len)
            return error.InvalidTickEvent;
        return event;
    }

    pub fn reloadResult(self: EventRecord) !*const ReloadResultEvent {
        if (self.header.kind != EventKind.reload_result or
            self.bytes.len != @sizeOf(ReloadResultEvent) or
            self.header.flags != 0)
            return error.InvalidTickEvent;
        const event: *const ReloadResultEvent = @ptrCast(@alignCast(self.bytes.ptr));
        if (event.succeeded > 1 or
            !std.mem.allEqual(u8, &event._reserved, 0))
            return error.InvalidTickEvent;
        return event;
    }

    pub fn attachedConnection(self: EventRecord) !*const AttachedConnectionEvent {
        if (self.header.kind != EventKind.attached_connection or
            self.bytes.len != @sizeOf(AttachedConnectionEvent) or
            self.header.flags != 0)
            return error.InvalidTickEvent;
        const event: *const AttachedConnectionEvent = @ptrCast(@alignCast(self.bytes.ptr));
        if (event.name_len > event.name.len or
            event.reconfiguring > 1 or event._reserved != 0)
            return error.InvalidTickEvent;
        return event;
    }
};

pub const EventIterator = struct {
    remaining: []const u8,

    pub fn init(exchange: *const TickExchange) EventIterator {
        return .{ .remaining = exchange.events.slice() };
    }

    pub fn next(self: *EventIterator) !?EventRecord {
        if (self.remaining.len == 0) return null;
        if (self.remaining.len < @sizeOf(RecordHeader)) return error.InvalidTickEventStream;
        const header: *const RecordHeader = @ptrCast(@alignCast(self.remaining.ptr));
        if (header.size < @sizeOf(RecordHeader) or header.size > self.remaining.len)
            return error.InvalidTickEventStream;
        const padded_size = std.mem.alignForward(usize, header.size, record_alignment);
        if (padded_size > self.remaining.len) return error.InvalidTickEventStream;
        const record = EventRecord{
            .header = header,
            .bytes = self.remaining[0..header.size],
        };
        self.remaining = self.remaining[padded_size..];
        return record;
    }
};

pub const CommandKind = struct {
    pub const close_connection: u16 = 1;
    pub const log: u16 = 2;
    pub const select_protocol: u16 = 3;
    pub const close_after_output: u16 = 4;
    pub const enter_configuration: u16 = 5;
    pub const reserve_player: u16 = 6;
    pub const enter_play: u16 = 7;
    pub const release_connection: u16 = 8;
    pub const request_reload: u16 = 9;
};

const record_alignment = 8;

pub const TickExchange = extern struct {
    header: Header = Header.init(TickExchange),
    sequence: u64,
    monotonic_ns: u64,
    deadline_ns: u64,
    events: Bytes,
    commands: MutableBytes,
    command_bytes_written: usize = 0,
    kernel: ?*const KernelApi = null,

    pub fn resetCommands(self: *TickExchange) void {
        self.command_bytes_written = 0;
    }

    pub fn appendLog(self: *TickExchange, message: []const u8) bool {
        if (message.len > std.math.maxInt(u32)) return false;
        const payload_size = @sizeOf(LogCommand) + message.len;
        const record_size = std.mem.alignForward(usize, payload_size, record_alignment);
        const start = self.command_bytes_written;
        if (record_size > self.commands.len -| start) return false;
        const destination = self.commands.slice()[start..][0..record_size];
        @memset(destination, 0);
        const command: *LogCommand = @ptrCast(@alignCast(destination.ptr));
        command.* = .{
            .record = .{
                .size = @intCast(payload_size),
                .kind = CommandKind.log,
                .flags = 0,
            },
            .message_len = @intCast(message.len),
        };
        @memcpy(destination[@sizeOf(LogCommand)..][0..message.len], message);
        self.command_bytes_written = start + record_size;
        return true;
    }

    pub fn appendCloseConnection(
        self: *TickExchange,
        connection: ConnectionHandle,
        reason: DisconnectReason,
    ) bool {
        return self.appendFixed(CloseConnectionCommand{
            .connection = connection,
            .reason = reason,
        });
    }

    pub fn appendSelectProtocol(
        self: *TickExchange,
        connection: ConnectionHandle,
        protocol_number: i32,
        intent: u8,
    ) bool {
        if (intent != 1 and intent != 2) return false;
        return self.appendFixed(SelectProtocolCommand{
            .connection = connection,
            .protocol_number = protocol_number,
            .intent = intent,
        });
    }

    pub fn appendCloseAfterOutput(self: *TickExchange, connection: ConnectionHandle) bool {
        return self.appendFixed(CloseAfterOutputCommand{ .connection = connection });
    }

    pub fn appendEnterConfiguration(self: *TickExchange, connection: ConnectionHandle) bool {
        return self.appendFixed(EnterConfigurationCommand{ .connection = connection });
    }

    pub fn appendReservePlayer(
        self: *TickExchange,
        connection: ConnectionHandle,
        new_player: bool,
        player_uuid: u128,
        name: []const u8,
    ) bool {
        if (name.len > 16) return false;
        var name_storage: [16]u8 = @splat(0);
        @memcpy(name_storage[0..name.len], name);
        return self.appendFixed(ReservePlayerCommand{
            .connection = connection,
            .new_player = @intFromBool(new_player),
            .player_uuid = @bitCast(player_uuid),
            .name_len = @intCast(name.len),
            .name = name_storage,
        });
    }

    pub fn appendEnterPlay(self: *TickExchange, connection: ConnectionHandle) bool {
        return self.appendFixed(EnterPlayCommand{ .connection = connection });
    }

    pub fn appendReleaseConnection(self: *TickExchange, connection: ConnectionHandle) bool {
        return self.appendFixed(ReleaseConnectionCommand{ .connection = connection });
    }

    pub fn appendRequestReload(self: *TickExchange, connection: ConnectionHandle) bool {
        return self.appendFixed(RequestReloadCommand{ .connection = connection });
    }

    fn appendFixed(self: *TickExchange, value: anytype) bool {
        const T = @TypeOf(value);
        comptime std.debug.assert(@alignOf(T) <= record_alignment);
        const record_size = std.mem.alignForward(usize, @sizeOf(T), record_alignment);
        const start = self.command_bytes_written;
        if (record_size > self.commands.len -| start) return false;
        const destination = self.commands.slice()[start..][0..record_size];
        @memset(destination, 0);
        const output: *T = @ptrCast(@alignCast(destination.ptr));
        output.* = value;
        self.command_bytes_written = start + record_size;
        return true;
    }
};

pub const CloseConnectionCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(CloseConnectionCommand),
        .kind = CommandKind.close_connection,
        .flags = 0,
    },
    connection: ConnectionHandle,
    reason: DisconnectReason,
    _reserved: [7]u8 = @splat(0),
};

pub const SelectProtocolCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(SelectProtocolCommand),
        .kind = CommandKind.select_protocol,
        .flags = 0,
    },
    connection: ConnectionHandle,
    protocol_number: i32,
    intent: u8,
    _reserved: [3]u8 = .{ 0, 0, 0 },
};

pub const CloseAfterOutputCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(CloseAfterOutputCommand),
        .kind = CommandKind.close_after_output,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const EnterConfigurationCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(EnterConfigurationCommand),
        .kind = CommandKind.enter_configuration,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const ReservePlayerCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(ReservePlayerCommand),
        .kind = CommandKind.reserve_player,
        .flags = 0,
    },
    connection: ConnectionHandle,
    player_uuid: [16]u8,
    new_player: u8,
    name_len: u8,
    _reserved: [6]u8 = [_]u8{0} ** 6,
    name: [16]u8,
};

pub const EnterPlayCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(EnterPlayCommand),
        .kind = CommandKind.enter_play,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const ReleaseConnectionCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(ReleaseConnectionCommand),
        .kind = CommandKind.release_connection,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const RequestReloadCommand = extern struct {
    record: RecordHeader = .{
        .size = @sizeOf(RequestReloadCommand),
        .kind = CommandKind.request_reload,
        .flags = 0,
    },
    connection: ConnectionHandle,
};

pub const LogCommand = extern struct {
    record: RecordHeader,
    message_len: u32,
    _reserved: u32 = 0,

    pub fn message(self: *const LogCommand) []const u8 {
        const bytes: [*]const u8 = @ptrCast(self);
        return bytes[@sizeOf(LogCommand)..][0..self.message_len];
    }
};

pub const CommandRecord = struct {
    header: *const RecordHeader,
    bytes: []const u8,

    pub fn log(self: CommandRecord) !*const LogCommand {
        if (self.header.kind != CommandKind.log or self.bytes.len < @sizeOf(LogCommand))
            return error.InvalidTickCommand;
        const command: *const LogCommand = @ptrCast(@alignCast(self.bytes.ptr));
        if (command._reserved != 0) return error.InvalidTickCommand;
        if (@sizeOf(LogCommand) + command.message_len != self.bytes.len)
            return error.InvalidTickCommand;
        return command;
    }

    pub fn closeConnection(self: CommandRecord) !*const CloseConnectionCommand {
        if (self.header.kind != CommandKind.close_connection or
            self.bytes.len != @sizeOf(CloseConnectionCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn selectProtocol(self: CommandRecord) !*const SelectProtocolCommand {
        if (self.header.kind != CommandKind.select_protocol or
            self.bytes.len != @sizeOf(SelectProtocolCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        const command: *const SelectProtocolCommand = @ptrCast(@alignCast(self.bytes.ptr));
        if (!std.mem.allEqual(u8, &command._reserved, 0) or
            (command.intent != 1 and command.intent != 2))
            return error.InvalidTickCommand;
        return command;
    }

    pub fn closeAfterOutput(self: CommandRecord) !*const CloseAfterOutputCommand {
        if (self.header.kind != CommandKind.close_after_output or
            self.bytes.len != @sizeOf(CloseAfterOutputCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn enterConfiguration(self: CommandRecord) !*const EnterConfigurationCommand {
        if (self.header.kind != CommandKind.enter_configuration or
            self.bytes.len != @sizeOf(EnterConfigurationCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn reservePlayer(self: CommandRecord) !*const ReservePlayerCommand {
        if (self.header.kind != CommandKind.reserve_player or
            self.bytes.len != @sizeOf(ReservePlayerCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        const command: *const ReservePlayerCommand = @ptrCast(@alignCast(self.bytes.ptr));
        if (command.new_player > 1 or command.name_len > command.name.len or
            !std.mem.allEqual(u8, &command._reserved, 0))
            return error.InvalidTickCommand;
        return command;
    }

    pub fn enterPlay(self: CommandRecord) !*const EnterPlayCommand {
        if (self.header.kind != CommandKind.enter_play or
            self.bytes.len != @sizeOf(EnterPlayCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn releaseConnection(self: CommandRecord) !*const ReleaseConnectionCommand {
        if (self.header.kind != CommandKind.release_connection or
            self.bytes.len != @sizeOf(ReleaseConnectionCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }

    pub fn requestReload(self: CommandRecord) !*const RequestReloadCommand {
        if (self.header.kind != CommandKind.request_reload or
            self.bytes.len != @sizeOf(RequestReloadCommand) or
            self.header.flags != 0)
            return error.InvalidTickCommand;
        return @ptrCast(@alignCast(self.bytes.ptr));
    }
};

pub const CommandIterator = struct {
    remaining: []const u8,

    pub fn init(exchange: *const TickExchange) !CommandIterator {
        if (exchange.command_bytes_written > exchange.commands.len)
            return error.InvalidTickCommandStream;
        return .{ .remaining = exchange.commands.slice()[0..exchange.command_bytes_written] };
    }

    pub fn next(self: *CommandIterator) !?CommandRecord {
        if (self.remaining.len == 0) return null;
        if (self.remaining.len < @sizeOf(RecordHeader)) return error.InvalidTickCommandStream;
        const header: *const RecordHeader = @ptrCast(@alignCast(self.remaining.ptr));
        if (header.size < @sizeOf(RecordHeader) or header.size > self.remaining.len)
            return error.InvalidTickCommandStream;
        const padded_size = std.mem.alignForward(usize, header.size, record_alignment);
        if (padded_size > self.remaining.len) return error.InvalidTickCommandStream;
        const record = CommandRecord{
            .header = header,
            .bytes = self.remaining[0..header.size],
        };
        self.remaining = self.remaining[padded_size..];
        return record;
    }
};

pub const TickInvocation = extern struct {
    header: Header = Header.init(TickInvocation),
    exchange: *TickExchange,
};

pub const OutputLease = extern struct {
    id: u64 = 0,
    bytes: MutableBytes,
    protocol_number: i32 = 0,
    _reserved: u32 = 0,
};

pub const KernelStatus = enum(u32) {
    ok,
    incomplete,
    invalid_connection,
    backpressured,
    invalid_lease,
    unsupported,
    rejected,
};

pub const KernelCapability = struct {
    pub const output_leases: u64 = 1 << 0;
    pub const entropy: u64 = 1 << 1;
    pub const bulk_work: u64 = 1 << 2;
    pub const wire_transport: u64 = 1 << 3;
};

pub const ReserveOutputFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
    minimum_capacity: usize,
    output: *OutputLease,
) callconv(.c) KernelStatus;

pub const CommitOutputFn = *const fn (
    context: *anyopaque,
    lease: u64,
    body_length: usize,
) callconv(.c) KernelStatus;

pub const CancelOutputFn = *const fn (
    context: *anyopaque,
    lease: u64,
) callconv(.c) void;

pub const FillRandomFn = *const fn (
    context: *anyopaque,
    output: MutableBytes,
) callconv(.c) KernelStatus;

pub const OutputBackpressuredFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
) callconv(.c) bool;

pub const AppendInputFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
    bytes: Bytes,
) callconv(.c) KernelStatus;

pub const NextPacketFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
    packet: *Bytes,
) callconv(.c) KernelStatus;

pub const SetCompressionFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
    threshold: i32,
) callconv(.c) KernelStatus;

pub const SetEncryptionFn = *const fn (
    context: *anyopaque,
    connection: ConnectionHandle,
    secret: Bytes,
) callconv(.c) KernelStatus;

pub const KernelApi = extern struct {
    header: Header = Header.init(KernelApi),
    capabilities: u64,
    context: *anyopaque,
    reserve_output: ReserveOutputFn,
    commit_output: CommitOutputFn,
    cancel_output: CancelOutputFn,
    fill_random: FillRandomFn,
    output_backpressured: OutputBackpressuredFn,
    append_input: AppendInputFn,
    next_packet: NextPacketFn,
    set_compression: SetCompressionFn,
    set_encryption: SetEncryptionFn,
};

pub const Status = enum(u32) {
    ok = 0,
    initialization_failed = 1,
    tick_failed = 2,
    connection_failed = 3,
    invalid_request = 4,
    save_failed = 5,
    pending = 6,
};

pub const PanicContext = extern struct {
    message_ptr: [*]const u8,
    message_len: usize,
    phase_ptr: [*]const u8,
    phase_len: usize,
    plugin_id_ptr: [*]const u8,
    plugin_id_len: usize,
    system_type_ptr: [*]const u8,
    system_type_len: usize,
    plugin_index: usize,
    system_index: usize,
    tick: u64,
    subject: usize,
    has_plugin: u8,
    has_tick: u8,
    has_subject: u8,
    _reserved: [5]u8 = [_]u8{0} ** 5,
    return_address: usize,

    pub fn message(self: *const @This()) []const u8 {
        return self.message_ptr[0..self.message_len];
    }
};

pub const PanicFn = *const fn (context: *const PanicContext) callconv(.c) noreturn;

pub const metrics_plugin_capacity = 128;
pub const metrics_trace_capacity = 256;

pub const PluginMetrics = extern struct {
    id_ptr: [*]const u8,
    id_len: usize,
    total_ns: u64,
    window_ns: u64,
    last_ns: u64,
    max_ns: u64,
    generation_bytes: u64 = 0,
    tick_memory_total_bytes: u64 = 0,
    tick_memory_window_bytes: u64 = 0,
    tick_memory_last_bytes: u64 = 0,
    tick_memory_max_bytes: u64 = 0,

    pub fn id(self: @This()) []const u8 {
        return self.id_ptr[0..self.id_len];
    }
};

pub const TraceMetrics = extern struct {
    plugin_index: usize,
    name_ptr: [*]const u8,
    name_len: usize,
    total_ns: u64,
    window_ns: u64,
    last_ns: u64,
    max_ns: u64,
    total_calls: u64,
    window_calls: u64,
    last_calls: u32,
    max_calls: u32,

    pub fn name(self: @This()) []const u8 {
        return self.name_ptr[0..self.name_len];
    }
};

pub const MetricsSnapshot = extern struct {
    header: Header = Header.init(MetricsSnapshot),
    tick_count: u64 = 0,
    tick_total_ns: u64 = 0,
    tick_window_ns: u64 = 0,
    tick_last_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    window_count: usize = 0,
    plugin_count: usize = 0,
    plugins: [metrics_plugin_capacity]PluginMetrics = undefined,
    trace_count: usize = 0,
    traces: [metrics_trace_capacity]TraceMetrics = undefined,
    world_tick: u64 = 0,
    living_entities: usize = 0,
    item_entities: usize = 0,
    resident_sections: usize = 0,
    modified_blocks: usize = 0,
    pending_terrain_chunks: usize = 0,
    terrain_last_ns: u64 = 0,
    terrain_max_ns: u64 = 0,
    generation_memory_bytes: u64 = 0,
    tick_memory_capacity_bytes: u64 = 0,
};

pub const Descriptor = extern struct {
    header: Header = Header.init(Descriptor),
    optimize_mode: u8,
    _descriptor_reserved: [7]u8 = [_]u8{0} ** 7,
    required_kernel_capabilities: u64 = 0,
    state_size: usize,
    state_alignment: usize,
    state_capacity: usize,
    maximum_memory_bytes: usize,
    maximum_players: u32,
    default_gamemode: u8,
    _configuration_reserved: [3]u8 = [_]u8{0} ** 3,
    supported_protocols: [*]const i32,
    supported_protocol_count: usize,
};

pub const Initialize = extern struct {
    panic_fn: PanicFn,
    state_bytes: usize,
    state_used_bytes: *usize,
    storage_mode: StorageMode,
    _reserved: [7]u8 = @splat(0),
};

pub const StorageMode = enum(u8) {
    disk,
    memory,
};

pub const DescribeFn = *const fn () callconv(.c) *const Descriptor;
pub const InitializeFn = *const fn (state: *anyopaque, input: *const Initialize) callconv(.c) Status;
pub const TickFn = *const fn (state: *anyopaque, invocation: *const TickInvocation) callconv(.c) Status;
pub const SaveFn = *const fn (state: *anyopaque) callconv(.c) Status;
pub const LoadFn = *const fn (state: *anyopaque) callconv(.c) Status;
pub const BeginReconfigurationFn = *const fn (state: *anyopaque, exchange: *TickExchange) callconv(.c) Status;
pub const DeinitializeFn = *const fn (state: *anyopaque) callconv(.c) void;
pub const SetProfilingFn = *const fn (state: *anyopaque, enabled: u8) callconv(.c) void;
pub const MetricsFn = *const fn (state: *const anyopaque, output: *MetricsSnapshot) callconv(.c) void;
pub const descriptor_size = @sizeOf(Descriptor);

test "tick command records are bounded and independently parseable" {
    var events: [0]u8 = .{};
    var commands: [128]u8 align(record_alignment) = undefined;
    var exchange = TickExchange{
        .sequence = 7,
        .monotonic_ns = 11,
        .deadline_ns = 13,
        .events = .{ .ptr = events[0..].ptr, .len = 0 },
        .commands = .{ .ptr = &commands, .len = commands.len },
    };
    try std.testing.expect(exchange.appendLog("hello"));
    try std.testing.expect(exchange.appendLog("world"));
    var iterator = try CommandIterator.init(&exchange);
    try std.testing.expectEqualStrings("hello", (try (try iterator.next()).?.log()).message());
    try std.testing.expectEqualStrings("world", (try (try iterator.next()).?.log()).message());
    try std.testing.expect((try iterator.next()) == null);
}

test "connection commands carry generation-stamped transport decisions" {
    var events: [0]u8 = .{};
    var commands: [256]u8 align(record_alignment) = undefined;
    var exchange = TickExchange{
        .sequence = 7,
        .monotonic_ns = 11,
        .deadline_ns = 13,
        .events = .{ .ptr = events[0..].ptr, .len = 0 },
        .commands = .{ .ptr = &commands, .len = commands.len },
    };
    const selected = ConnectionHandle{ .index = 4, .generation = 12 };
    const closed = ConnectionHandle{ .index = 7, .generation = 19 };
    try std.testing.expect(exchange.appendSelectProtocol(selected, 772, 2));
    try std.testing.expect(exchange.appendCloseAfterOutput(selected));
    try std.testing.expect(exchange.appendEnterPlay(selected));
    try std.testing.expect(exchange.appendCloseConnection(closed, .kicked));
    try std.testing.expect(exchange.appendReleaseConnection(closed));
    try std.testing.expect(exchange.appendRequestReload(selected));

    var iterator = try CommandIterator.init(&exchange);
    const select = try (try iterator.next()).?.selectProtocol();
    try std.testing.expectEqual(selected.value(), select.connection.value());
    try std.testing.expectEqual(@as(i32, 772), select.protocol_number);
    try std.testing.expectEqual(@as(u8, 2), select.intent);
    const close_after = try (try iterator.next()).?.closeAfterOutput();
    try std.testing.expectEqual(selected.value(), close_after.connection.value());
    const enter_play = try (try iterator.next()).?.enterPlay();
    try std.testing.expectEqual(selected.value(), enter_play.connection.value());
    const close = try (try iterator.next()).?.closeConnection();
    try std.testing.expectEqual(closed.value(), close.connection.value());
    try std.testing.expectEqual(DisconnectReason.kicked, close.reason);
    const release = try (try iterator.next()).?.releaseConnection();
    try std.testing.expectEqual(closed.value(), release.connection.value());
    const reload = try (try iterator.next()).?.requestReload();
    try std.testing.expectEqual(selected.value(), reload.connection.value());
    try std.testing.expect((try iterator.next()) == null);
}

test "connection lifecycle events use generation-stamped handles" {
    var storage: [128]u8 align(record_alignment) = undefined;
    var written: usize = 0;
    const writer = EventWriter{ .buffer = &storage, .written = &written };
    const handle = ConnectionHandle{ .index = 19, .generation = 27 };
    try std.testing.expect(writer.connected(handle));
    try std.testing.expect(writer.disconnected(handle, .peer_closed));
    try std.testing.expect(writer.reloadResult(handle, true, 42));
    var commands: [0]u8 = .{};
    var exchange = TickExchange{
        .sequence = 1,
        .monotonic_ns = 2,
        .deadline_ns = 3,
        .events = .{ .ptr = &storage, .len = written },
        .commands = .{ .ptr = commands[0..].ptr, .len = 0 },
    };
    var iterator = EventIterator.init(&exchange);
    try std.testing.expectEqual(handle.value(), (try (try iterator.next()).?.connected()).connection.value());
    try std.testing.expectEqual(handle.value(), (try (try iterator.next()).?.disconnected()).connection.value());
    const reload = try (try iterator.next()).?.reloadResult();
    try std.testing.expectEqual(handle.value(), reload.connection.value());
    try std.testing.expectEqual(@as(u8, 1), reload.succeeded);
    try std.testing.expectEqual(@as(u64, 42), reload.elapsed_ms);
    try std.testing.expect((try iterator.next()) == null);
}

test "raw input events preserve opaque stream bytes" {
    var storage: [128]u8 align(record_alignment) = undefined;
    var written: usize = 0;
    const writer = EventWriter{ .buffer = &storage, .written = &written };
    const handle = ConnectionHandle{ .index = 4, .generation = 9 };
    try std.testing.expect(writer.rawInput(handle, &.{ 0x01, 0x02, 0x03 }));
    var commands: [0]u8 = .{};
    var exchange = TickExchange{
        .sequence = 1,
        .monotonic_ns = 2,
        .deadline_ns = 3,
        .events = .{ .ptr = &storage, .len = written },
        .commands = .{ .ptr = commands[0..].ptr, .len = 0 },
    };
    var iterator = EventIterator.init(&exchange);
    const input = try (try iterator.next()).?.rawInput();
    try std.testing.expectEqual(handle.value(), input.connection.value());
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, input.payload());
    try std.testing.expect((try iterator.next()) == null);
}

test "tick module descriptor contains data, not callable entry points" {
    inline for (@typeInfo(Descriptor).@"struct".fields) |field| {
        switch (@typeInfo(field.type)) {
            .pointer => |pointer| try std.testing.expect(@typeInfo(pointer.child) != .@"fn"),
            else => {},
        }
    }
}

test "tick module exports have explicit C signatures" {
    const TickFunction = @typeInfo(TickFn).pointer.child;
    try std.testing.expect(std.builtin.CallingConvention.eql(
        std.builtin.CallingConvention.c,
        @typeInfo(TickFunction).@"fn".calling_convention,
    ));
}

test "transport ABI contains no Minecraft layout types" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(ConnectionHandle));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(RecordHeader));
    try std.testing.expectEqual(.@"extern", @typeInfo(TickExchange).@"struct".layout);
    try std.testing.expectEqual(.@"extern", @typeInfo(KernelApi).@"struct".layout);
}
