const entity_store = @import("world/entities.zig");
const input_store = @import("world/inputs.zig");
const player_store = @import("world/players.zig");
const block_store = @import("world/blocks.zig");
const vanilla_time = @import("world/time.zig");
const game_rules = @import("world/game_rules.zig");
const world_random = @import("world/random.zig");
const world_clock = @import("world/clock.zig");
const world_store = @import("world/worlds.zig");
const world_identity = @import("world/identity.zig");
const std = @import("std");
const preallocated = @import("preallocated");
const builtin = @import("builtin");
const abi = @import("hot_reload_abi.zig");
const diagnostics = @import("diagnostics.zig");
const plugin_api = @import("plugin_api.zig");
const plugin_profiler = @import("plugin_profiler.zig");
const player_lifecycle = @import("player_lifecycle.zig");
const packet_writer = @import("packet_writer.zig");
const server_tick = @import("server_tick.zig");
const tick_host = @import("tick_host.zig");
const tick_transport = @import("tick_transport.zig");
const tick_module_harness = @import("tick_module_harness.zig");
const replication = @import("replication.zig");
const protocol_versions = @import("protocol_versions.zig");
const connection_api = @import("connection_api.zig");
const config = @import("config.zig").value;
const configuration_bootstrap = @import("configuration_bootstrap.zig");
const tick_services = @import("tick_services.zig");
const crypto_support = @import("crypto_support.zig");
const generation_allocator = @import("generation_allocator.zig");

fn removeBorrowedInputsForSlot(
    inputs: []tick_host.BorrowedInput,
    length: *usize,
    slot: u16,
) void {
    var write: usize = 0;
    for (inputs[0..length.*]) |input| {
        if (input.slot == slot) continue;
        inputs[write] = input;
        write += 1;
    }
    length.* = write;
}

pub fn Runtime(comptime ProfileFactory: type) type {
    return struct {
        const Self = @This();
        const Writer = packet_writer.Packets;
        const Profile = ProfileFactory.Plugins;
        const plugin_count = plugin_api.count(Profile);
        const trace_count = plugin_api.traceCount(Profile);
        const supported_protocols = protocol_versions.numbers(ProfileFactory.protocols);

        var host_panic: ?abi.PanicFn = null;
        var active_host: ?*tick_host.Host = null;

        const PluginMetricMetadata = struct {
            id_ptr: [*]const u8,
            id_len: usize,
        };

        const TraceMetricMetadata = struct {
            plugin_index: usize,
            name_ptr: [*]const u8,
            name_len: usize,
        };

        const plugin_metric_metadata = metadata: {
            var result: [plugin_count]PluginMetricMetadata = undefined;
            for (0..plugin_count) |index| {
                const Plugin = plugin_api.pluginType(Profile, index);
                result[index] = .{ .id_ptr = Plugin.id.ptr, .id_len = Plugin.id.len };
            }
            break :metadata result;
        };

        const trace_metric_metadata = metadata: {
            var result: [trace_count]TraceMetricMetadata = undefined;
            var trace_index: usize = 0;
            for (0..plugin_count) |plugin_index| {
                const Plugin = plugin_api.pluginType(Profile, plugin_index);
                if (@hasDecl(Plugin, "Trace")) {
                    for (@typeInfo(Plugin.Trace).@"enum".fields) |field| {
                        result[trace_index] = .{
                            .plugin_index = plugin_index,
                            .name_ptr = field.name.ptr,
                            .name_len = field.name.len,
                        };
                        trace_index += 1;
                    }
                }
            }
            break :metadata result;
        };

        const State = struct {
            config: *const ProfileFactory.Configuration = &ProfileFactory.configuration,
            plugins: *Profile,
            services: *tick_services.Services,
            tick_arena: *tick_services.Arena,
            profiler: plugin_profiler.Profiler = .{},
            replication: replication.State = .{},
            identity: crypto_support.Identity = undefined,
            state_storage_used: usize = 0,
            dynamic_storage: generation_allocator.Allocator = undefined,
            connections: []ConnectionState = &.{},
            connection_handles: []?abi.ConnectionHandle = &.{},
            keep_alive_states: []tick_host.KeepAliveState = &.{},
            play_inputs: BoundedList(tick_host.BorrowedInput) = .{},
            active_play_slots: BoundedList(u16) = .{},
            pending_play_joins: BoundedList(u16) = .{},
            pending_play_disconnects: BoundedList(tick_host.PendingPlayDisconnect) = .{},
            player_joined: BoundedList(player_lifecycle.PlayerJoined) = .{},
            play_started: BoundedList(player_lifecycle.PlayStarted) = .{},
            players_left: BoundedList(player_lifecycle.PlayerLeft) = .{},
            reload_result: ?tick_host.ReloadResult = null,
            chunk_stream_cursor: usize = 0,
            chunk_streaming_enabled: bool = true,
            connection_event_count: u64 = 0,
            active_connection_count: usize = 0,
            world_tick: u64 = 0,
            living_entity_count: usize = 0,
            item_entity_count: usize = 0,
            resident_section_count: usize = 0,
            modified_block_count: usize = 0,
            pending_terrain_chunk_count: usize = 0,
            terrain_last_ns: u64 = 0,
            terrain_max_ns: u64 = 0,
        };

        fn BoundedList(comptime T: type) type {
            return struct {
                values: []T = &.{},
                len: usize = 0,

                fn allocate(self: *@This(), allocator: std.mem.Allocator, capacity: usize) !void {
                    self.values = try preallocated.alloc(T, allocator, capacity);
                    self.len = 0;
                }

                fn clear(self: *@This()) void {
                    self.len = 0;
                }

                fn append(self: *@This(), value: T) !void {
                    if (self.len == self.values.len) return error.CapacityExceeded;
                    self.values[self.len] = value;
                    self.len += 1;
                }

                fn items(self: *const @This()) []const T {
                    return self.values[0..self.len];
                }
            };
        }

        const ConnectionPhase = enum(u8) {
            handshaking,
            status,
            login,
            configuration,
            play,
        };

        const ConfigurationStep = enum { start, registries };

        const ConnectionState = struct {
            handle: abi.ConnectionHandle = .{ .index = 0, .generation = 0 },
            active: bool = false,
            protocol_number: i32 = 0,
            phase: ConnectionPhase = .handshaking,
            player_reserved: bool = false,
            reconfiguring: bool = false,
            play_start_reason: player_lifecycle.PlayStartReason = .login,
            awaiting_encryption: bool = false,
            verify_token: [4]u8 = @splat(0),
        };

        const state_storage_offset = std.mem.alignForward(usize, @sizeOf(State), 64);

        fn panicWithPluginContext(message: []const u8, return_address: ?usize) noreturn {
            var context = abi.PanicContext{
                .message_ptr = message.ptr,
                .message_len = message.len,
                .phase_ptr = message.ptr,
                .phase_len = 0,
                .plugin_id_ptr = message.ptr,
                .plugin_id_len = 0,
                .system_type_ptr = message.ptr,
                .system_type_len = 0,
                .plugin_index = 0,
                .system_index = 0,
                .tick = 0,
                .subject = 0,
                .has_plugin = 0,
                .has_tick = 0,
                .has_subject = 0,
                .return_address = return_address orelse 0,
            };
            if (plugin_api.activeSystem()) |active| {
                context.phase_ptr = active.phase.ptr;
                context.phase_len = active.phase.len;
                context.plugin_id_ptr = active.plugin_id.ptr;
                context.plugin_id_len = active.plugin_id.len;
                context.system_type_ptr = active.system_type.ptr;
                context.system_type_len = active.system_type.len;
                context.plugin_index = active.plugin_index;
                context.system_index = active.system_index;
                context.has_plugin = 1;
                if (active.tick) |value| {
                    context.tick = value;
                    context.has_tick = 1;
                }
                if (active.subject) |value| {
                    context.subject = value;
                    context.has_subject = 1;
                }
            }
            if (host_panic) |callback| callback(&context);
            @trap();
        }

        pub const panic = diagnostics.FullPanic(panicWithPluginContext);

        pub fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
            const host = active_host orelse return std.log.defaultLog(level, scope, format, args);
            var buffer: [1024]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            writer.print("{s}", .{level.asText()}) catch return;
            if (scope != .default) writer.print("({s})", .{@tagName(scope)}) catch return;
            writer.writeAll(": ") catch return;
            writer.print(format, args) catch return;
            writer.writeByte('\n') catch return;
            host.logMessage(writer.buffered());
        }

        fn initialize(
            raw_state: *anyopaque,
            panic_fn: abi.PanicFn,
            state_bytes: usize,
            state_used_bytes: *usize,
            storage_mode: abi.StorageMode,
        ) callconv(.c) abi.Status {
            host_panic = panic_fn;
            if (state_bytes <= state_storage_offset) return .initialization_failed;
            const started_ns = monotonicNanoseconds() orelse 0;
            const state: *State = @ptrCast(@alignCast(raw_state));
            const storage_base: [*]u8 = @ptrCast(raw_state);
            state.dynamic_storage = generation_allocator.Allocator.init(
                storage_base[state_storage_offset..state_bytes],
            );
            const storage = state.dynamic_storage.allocator();
            state.config = &ProfileFactory.configuration;
            initializeFields(state);
            allocateCoreState(state, storage) catch |err| {
                std.log.err("event=tick_module_core_initialization_failed error={s} used_bytes={}", .{ @errorName(err), state.dynamic_storage.used() });
                return .initialization_failed;
            };
            const core_initialized_ns = monotonicNanoseconds() orelse started_ns;
            state.services = tick_services.Services.create(storage, storage_mode, ProfileFactory.configuration.server.storage_io) catch |err| {
                std.log.err("event=tick_module_service_initialization_failed error={s} used_bytes={}", .{ @errorName(err), state.dynamic_storage.used() });
                return .initialization_failed;
            };
            const services_initialized_ns = monotonicNanoseconds() orelse core_initialized_ns;
            state.tick_arena = tick_services.Arena.create(storage) catch |err| {
                std.log.err("event=tick_module_arena_initialization_failed error={s} used_bytes={}", .{ @errorName(err), state.dynamic_storage.used() });
                return .initialization_failed;
            };
            const arena_initialized_ns = monotonicNanoseconds() orelse services_initialized_ns;
            state.dynamic_storage.trackPlugins(state.profiler.generationMemory());
            state.plugins = ProfileFactory.create(&state.dynamic_storage, state.services) catch |err| {
                std.log.err("event=tick_module_plugin_initialization_failed error={s} used_bytes={}", .{ @errorName(err), state.dynamic_storage.used() });
                return .initialization_failed;
            };
            state.profiler.setGenerationMemory(state.dynamic_storage.plugin_bytes);
            const plugins_initialized_ns = monotonicNanoseconds() orelse core_initialized_ns;
            state.state_storage_used = state.dynamic_storage.used();
            state_used_bytes.* = state_storage_offset + state.state_storage_used;
            std.log.info("event=tick_module_initialized state_used_bytes={} state_capacity_bytes={} core_ms={d:.3} plugins_ms={d:.3}", .{
                state.state_storage_used,
                state_bytes,
                @as(f64, @floatFromInt(core_initialized_ns -| started_ns)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(plugins_initialized_ns -| core_initialized_ns)) / std.time.ns_per_ms,
            });
            std.log.info(
                "event=tick_module_init_profile services_ms={d:.3} tick_arena_ms={d:.3} composition_ms={d:.3}",
                .{
                    milliseconds(services_initialized_ns -| core_initialized_ns),
                    milliseconds(arena_initialized_ns -| services_initialized_ns),
                    milliseconds(plugins_initialized_ns -| arena_initialized_ns),
                },
            );
            state.dynamic_storage.seal();
            return .ok;
        }

        fn saveConfiguredPlugins(raw_state: *anyopaque) abi.Status {
            const state: *State = @ptrCast(@alignCast(raw_state));
            state.services.io.begin() catch return .save_failed;
            plugin_api.save(state.plugins) catch |err| {
                std.log.err("event=tick_module_save_failed error={s}", .{@errorName(err)});
                return .save_failed;
            };
            state.services.io.finish() catch return .save_failed;
            state.services.io.synchronize() catch return .save_failed;
            return .ok;
        }

        fn loadConfiguredPlugins(raw_state: *anyopaque) abi.Status {
            const state: *State = @ptrCast(@alignCast(raw_state));
            state.services.io.begin() catch return .initialization_failed;
            plugin_api.load(state.plugins) catch |err| {
                std.log.err("event=tick_module_load_failed error={s}", .{@errorName(err)});
                return .initialization_failed;
            };
            state.services.io.finish() catch return .initialization_failed;
            state.services.io.synchronize() catch return .initialization_failed;
            return .ok;
        }

        fn configuredHost(
            state: *State,
            exchange: *abi.TickExchange,
        ) tick_host.Host {
            const stores = ProfileFactory.stores(state.plugins);
            return tick_host.Host.init(
                stores.worlds,
                stores.clock,
                stores.time,
                stores.game_rules,
                stores.random,
                stores.inputs,
                stores.containers,
                stores.blocks,
                stores.living,
                stores.players,
                stores.items,
                state.services.io,
                exchange,
                state.connection_handles,
                state.play_inputs.items(),
                state.active_play_slots.values,
                &state.active_play_slots.len,
                state.pending_play_joins.values,
                &state.pending_play_joins.len,
                state.pending_play_disconnects.values,
                &state.pending_play_disconnects.len,
                state.keep_alive_states,
                &state.reload_result,
                &state.replication,
                &state.chunk_stream_cursor,
                state.chunk_streaming_enabled,
                state.config.server.max_players,
            );
        }

        fn initializeFields(state: *State) void {
            state.profiler = .{};
            state.replication = .{};
            state.identity = crypto_support.Identity.init();
            state.connections = &.{};
            state.connection_handles = &.{};
            state.keep_alive_states = &.{};
            state.play_inputs = .{};
            state.active_play_slots = .{};
            state.pending_play_joins = .{};
            state.pending_play_disconnects = .{};
            state.player_joined = .{};
            state.play_started = .{};
            state.players_left = .{};
            state.reload_result = null;
            state.chunk_stream_cursor = 0;
            state.chunk_streaming_enabled = true;
        }

        fn allocateCoreState(state: *State, storage: std.mem.Allocator) !void {
            try state.replication.allocate(storage);
            state.connections = try preallocated.alloc(ConnectionState, storage, config.connectionCapacity());
            @memset(state.connections, .{});
            state.connection_handles = try preallocated.alloc(?abi.ConnectionHandle, storage, config.connectionCapacity());
            @memset(state.connection_handles, null);
            state.keep_alive_states = try preallocated.alloc(tick_host.KeepAliveState, storage, config.connectionCapacity());
            @memset(state.keep_alive_states, .{});
            try state.play_inputs.allocate(storage, config.max_tick_input_packets);
            try state.active_play_slots.allocate(storage, config.max_players);
            try state.pending_play_joins.allocate(storage, config.max_players);
            try state.pending_play_disconnects.allocate(storage, config.max_players);
            try state.player_joined.allocate(storage, config.max_players);
            try state.play_started.allocate(storage, config.max_players);
            try state.players_left.allocate(storage, config.max_players);
            try state.profiler.allocate(storage, plugin_count, trace_count);
        }

        fn invocation(value: *const abi.TickInvocation) ?*const abi.TickInvocation {
            if (!value.header.supports(@sizeOf(abi.TickInvocation))) return null;
            if (!value.exchange.header.supports(@sizeOf(abi.TickExchange))) return null;
            return value;
        }

        fn consumeKernelEvents(
            state: *State,
            host: *tick_host.Host,
            exchange: *abi.TickExchange,
        ) abi.Status {
            state.play_inputs.clear();
            state.player_joined.clear();
            state.play_started.clear();
            state.players_left.clear();
            var events = abi.EventIterator.init(exchange);
            while (events.next() catch return .invalid_request) |event| {
                const status: abi.Status = switch (event.header.kind) {
                    abi.EventKind.connected => consumeConnected(state, host, event),
                    abi.EventKind.disconnected => consumeDisconnected(state, host, exchange, event),
                    abi.EventKind.raw_input => consumeRawInput(state, host, exchange, event),
                    abi.EventKind.reload_result => consumeReloadResult(state, event),
                    abi.EventKind.attached_connection => consumeAttachedConnection(state, host, exchange, event),
                    else => .ok,
                };
                if (status != .ok) return status;
                state.connection_event_count +%= 1;
            }
            return .ok;
        }

        fn consumeConnected(state: *State, host: *tick_host.Host, event: abi.EventRecord) abi.Status {
            const connected = event.connected() catch return .invalid_request;
            if (connected.connection.index >= state.connections.len) return .tick_failed;
            const slot: u16 = @intCast(connected.connection.index);
            if (host.players.records[slot].state == .free)
                host.players.beginConnection(host.random, slot);
            replaceConnectionAtIndex(state, connected.connection);
            const connection = &state.connections[connected.connection.index];
            if (!connection.active) state.active_connection_count += 1;
            connection.* = .{ .handle = connected.connection, .active = true };
            storeConnectionHandle(state, connected.connection) catch return .tick_failed;
            state.replication.reset(slot);
            return .ok;
        }

        fn consumeDisconnected(state: *State, host: *tick_host.Host, exchange: *abi.TickExchange, event: abi.EventRecord) abi.Status {
            const disconnected = event.disconnected() catch return .invalid_request;
            const connection = connectionForHandle(state, disconnected.connection) orelse return .ok;
            const slot: u16 = @intCast(disconnected.connection.index);
            const reason: player_lifecycle.LeaveReason = @enumFromInt(@intFromEnum(disconnected.reason));
            if (!exchange.appendReleaseConnection(disconnected.connection))
                return .tick_failed;
            if (connection.phase == .play)
                stageDisconnect(state, host, slot) catch return .tick_failed;
            state.players_left.append(.{
                .slot = slot,
                .connection = disconnected.connection,
                .reason = reason,
            }) catch return .tick_failed;
            for (state.active_play_slots.items()) |recipient|
                state.replication.clients[recipient].setPlayerVisible(slot, false);
            state.replication.reset(slot);
            removePlaySlot(state, slot);
            std.debug.assert(state.active_connection_count != 0);
            state.active_connection_count -= 1;
            state.connections[disconnected.connection.index] = .{};
            removeConnectionHandle(state, disconnected.connection);
            return .ok;
        }

        fn stageDisconnect(state: *State, host: *tick_host.Host, slot: u16) !void {
            const player = &host.players.records[slot];
            var name: [config.max_username_bytes]u8 = undefined;
            @memcpy(name[0..player.name_len], player.name_slice());
            try state.pending_play_disconnects.append(.{
                .world = player.world,
                .entity_id = player.entity_id,
                .uuid = player.uuid,
                .name = name,
                .name_len = @intCast(player.name_len),
                .dig_position = null,
            });
        }

        fn consumeRawInput(
            state: *State,
            host: *tick_host.Host,
            exchange: *abi.TickExchange,
            event: abi.EventRecord,
        ) abi.Status {
            const input = event.rawInput() catch return .invalid_request;
            const connection = connectionForHandle(state, input.connection) orelse return .ok;
            var context = RawPacketContext{
                .state = state,
                .host = host,
                .connection = connection,
                .exchange = exchange,
            };
            const kernel = exchange.kernel orelse return .invalid_request;
            if (kernel.append_input(
                kernel.context,
                input.connection,
                .{ .ptr = input.payload().ptr, .len = input.payload().len },
            ) != .ok) return closeMalformedInput(exchange, input.connection);
            for (0..config.max_tick_input_packets) |_| {
                var packet: abi.Bytes = .{ .ptr = undefined, .len = 0 };
                switch (kernel.next_packet(kernel.context, input.connection, &packet)) {
                    .ok => consumeDecodedPacket(&context, packet.slice()) catch {
                        if (context.status != .ok) return context.status;
                        return closeMalformedInput(exchange, input.connection);
                    },
                    .incomplete => return .ok,
                    else => return closeMalformedInput(exchange, input.connection),
                }
            }
            return .tick_failed;
        }

        fn closeMalformedInput(
            exchange: *abi.TickExchange,
            connection: abi.ConnectionHandle,
        ) abi.Status {
            return if (exchange.appendCloseConnection(connection, .kicked)) .ok else .tick_failed;
        }

        fn consumeReloadResult(state: *State, event: abi.EventRecord) abi.Status {
            const result = event.reloadResult() catch return .invalid_request;
            const connection = connectionForHandle(state, result.connection) orelse return .ok;
            if (connection.phase != .play) return .ok;
            state.reload_result = .{
                .requester = @intCast(result.connection.index),
                .succeeded = result.succeeded != 0,
                .elapsed_ms = result.elapsed_ms,
            };
            return .ok;
        }

        fn consumeAttachedConnection(
            state: *State,
            host: *tick_host.Host,
            exchange: *abi.TickExchange,
            event: abi.EventRecord,
        ) abi.Status {
            const attached = event.attachedConnection() catch return .invalid_request;
            if (attached.connection.index >= state.connections.len)
                return .tick_failed;
            const slot: u16 = @intCast(attached.connection.index);
            if (host.players.records[slot].state == .free)
                host.players.beginConnection(host.random, slot);
            _ = host.players.login(
                host.random,
                slot,
                attached.name[0..attached.name_len],
                @bitCast(attached.player_uuid),
            ) catch return .tick_failed;
            const player = &host.players.records[slot];
            if (!world_identity.valid(player.world) or host.worlds.getConst(player.world) == null) {
                player.world = host.worlds.find(state.config.server.spawn_world) orelse
                    return .initialization_failed;
                const spawn = host.worlds.getConst(player.world) orelse
                    return .initialization_failed;
                player.position = .{
                    .x = @floatFromInt(spawn.spawn_x),
                    .y = @floatFromInt(spawn.spawn_y),
                    .z = @floatFromInt(spawn.spawn_z),
                };
                player.needs_spawn_position = false;
            }
            host.players.transition(slot, .configuration);
            replaceConnectionAtIndex(state, attached.connection);
            state.replication.reset(slot);
            state.connections[slot] = .{
                .handle = attached.connection,
                .active = true,
                .protocol_number = attached.protocol_number,
                .phase = if (attached.phase == .play) .play else .configuration,
                .player_reserved = true,
                .reconfiguring = attached.reconfiguring != 0,
                .play_start_reason = .reconfiguration,
            };
            storeConnectionHandle(state, attached.connection) catch return .tick_failed;
            state.active_connection_count += 1;
            if (attached.phase == .configuration) {
                const status = runConfigurationPhase(state, &state.connections[slot], exchange, .start);
                if (status != .ok) return status;
            }
            return .ok;
        }

        const RawPacketContext = struct {
            state: *State,
            host: *tick_host.Host,
            connection: *ConnectionState,
            exchange: *abi.TickExchange,
            status: abi.Status = .ok,
        };

        fn consumeDecodedPacket(context: *RawPacketContext, payload: []const u8) !void {
            if (context.connection.phase == .play) {
                if (context.connection.reconfiguring) {
                    const acknowledged = protocol_versions.staticCall(
                        "decodeConfigurationAcknowledged",
                        context.connection.protocol_number,
                        .{payload},
                    ) catch false;
                    if (!acknowledged) return;
                    const status = runConfigurationPhase(
                        context.state,
                        context.connection,
                        context.exchange,
                        .start,
                    );
                    if (status != .ok) {
                        context.status = status;
                        return error.ConfigurationResetFailed;
                    }
                    if (!context.exchange.appendEnterConfiguration(context.connection.handle)) {
                        context.status = .tick_failed;
                        return error.TickCommandBufferExhausted;
                    }
                    context.connection.phase = .configuration;
                    context.connection.reconfiguring = false;
                    context.host.players.transition(
                        @intCast(context.connection.handle.index),
                        .configuration,
                    );
                    removePlaySlot(
                        context.state,
                        @intCast(context.connection.handle.index),
                    );
                    return;
                }
                const state = context.state;
                try state.play_inputs.append(.{
                    .slot = @intCast(context.connection.handle.index),
                    .protocol_number = context.connection.protocol_number,
                    .payload = payload,
                });
                return;
            }
            context.status = observeConnectionPacket(
                context.state,
                context.host,
                context.connection,
                payload,
                context.exchange,
            );
            if (context.status == .connection_failed) {
                if (!context.exchange.appendCloseConnection(context.connection.handle, .kicked))
                    context.status = .tick_failed;
                return;
            }
            if (context.status != .ok) return error.TickInputRejected;
        }

        fn removePlaySlot(state: *State, slot: u16) void {
            removeSlot(&state.active_play_slots, slot);
            removeSlot(&state.pending_play_joins, slot);
            removeBorrowedInputsForSlot(
                state.play_inputs.values,
                &state.play_inputs.len,
                slot,
            );
            if (slot < state.keep_alive_states.len)
                state.keep_alive_states[slot] = .{};
        }

        fn containsSlot(slots: []const u16, slot: u16) bool {
            for (slots) |candidate|
                if (candidate == slot) return true;
            return false;
        }

        fn isJoinPending(state: *const State, slot_index: u32) bool {
            if (slot_index > std.math.maxInt(u16)) return false;
            const slot: u16 = @intCast(slot_index);
            return containsSlot(state.pending_play_joins.items(), slot);
        }

        fn removeSlot(slots: *BoundedList(u16), slot: u16) void {
            var index: usize = 0;
            while (index < slots.len) {
                if (slots.values[index] != slot) {
                    index += 1;
                    continue;
                }
                slots.len -= 1;
                slots.values[index] = slots.values[slots.len];
            }
        }

        fn storeConnectionHandle(state: *State, handle: abi.ConnectionHandle) !void {
            const index: usize = handle.index;
            if (index >= config.connectionCapacity()) return error.ConnectionCapacityExceeded;
            state.connection_handles[index] = handle;
        }

        fn connectionForHandle(
            state: *State,
            handle: abi.ConnectionHandle,
        ) ?*ConnectionState {
            if (handle.index >= state.connections.len) return null;
            const connection = &state.connections[handle.index];
            if (!connection.active or connection.handle.generation != handle.generation)
                return null;
            return connection;
        }

        fn replaceConnectionAtIndex(state: *State, handle: abi.ConnectionHandle) void {
            const index: usize = handle.index;
            if (index >= state.connections.len) return;
            const previous = &state.connections[index];
            if (!previous.active or previous.handle.generation == handle.generation) return;
            previous.* = .{};
            if (state.active_connection_count != 0) {
                std.debug.assert(state.active_connection_count != 0);
                state.active_connection_count -= 1;
            }
            if (index <= std.math.maxInt(u16)) removePlaySlot(state, @intCast(index));
            if (index < state.connection_handles.len)
                state.connection_handles[index] = null;
        }

        fn removeConnectionHandle(state: *State, handle: abi.ConnectionHandle) void {
            const index: usize = handle.index;
            if (index >= state.connection_handles.len) return;
            const current = state.connection_handles[index] orelse return;
            if (current.value() == handle.value())
                state.connection_handles[index] = null;
        }

        fn observeConnectionPacket(
            state: *State,
            host: *tick_host.Host,
            connection: *ConnectionState,
            payload: []const u8,
            exchange: *abi.TickExchange,
        ) abi.Status {
            return switch (connection.phase) {
                .handshaking => observeHandshake(host, connection, payload, exchange),
                .status => observeStatus(state, connection, payload, exchange),
                .login => observeLogin(state, host, connection, payload, exchange),
                .configuration => observeConfiguration(state, host, connection, payload, exchange),
                .play => .ok,
            };
        }

        fn observeHandshake(host: *tick_host.Host, connection: *ConnectionState, payload: []const u8, exchange: *abi.TickExchange) abi.Status {
            const handshake = protocol_versions.decodeHandshake(payload) catch return .connection_failed;
            const protocol_number = if (handshake.intent == 1 and !protocol_versions.supportsNumber(ProfileFactory.protocols, handshake.protocol_number))
                protocol_versions.defaultNumber(ProfileFactory.protocols)
            else
                handshake.protocol_number;
            if (handshake.intent != 1 and handshake.intent != 2) return .connection_failed;
            if (handshake.intent == 2 and !protocol_versions.supportsNumber(ProfileFactory.protocols, protocol_number)) return .connection_failed;
            if (!exchange.appendSelectProtocol(connection.handle, protocol_number, @intCast(handshake.intent)))
                return .tick_failed;
            connection.protocol_number = protocol_number;
            connection.phase = if (handshake.intent == 1) .status else .login;
            host.players.transition(
                @intCast(connection.handle.index),
                if (handshake.intent == 1) .status else .login,
            );
            return .ok;
        }

        fn observeStatus(state: *State, connection: *ConnectionState, payload: []const u8, exchange: *abi.TickExchange) abi.Status {
            const command = protocol_versions.staticCall("decodeStatus", connection.protocol_number, .{payload}) catch
                return .connection_failed;
            switch (command) {
                .request => return runStatus(state, connection, exchange),
                .ping => |timestamp| emitStatusPong(connection, exchange, timestamp) catch
                    return .connection_failed,
            }
            return .ok;
        }

        fn observeLogin(state: *State, host: *tick_host.Host, connection: *ConnectionState, payload: []const u8, exchange: *abi.TickExchange) abi.Status {
            const command = protocol_versions.staticCall("decodeLogin", connection.protocol_number, .{payload}) catch
                return .connection_failed;
            switch (command) {
                .start => |start| return runLoginStart(state, host, connection, exchange, start.username, start.uuid),
                .encryption_response => |response| {
                    if (!completeEncryption(exchange, &state.identity, connection, response)) return .connection_failed;
                    return runLoginAuthenticated(state, host, connection, exchange);
                },
                .acknowledged => {
                    const status = runConfigurationPhase(state, connection, exchange, .start);
                    if (status != .ok) return status;
                    if (!exchange.appendEnterConfiguration(connection.handle)) return .tick_failed;
                    connection.phase = .configuration;
                    host.players.transition(@intCast(connection.handle.index), .configuration);
                },
            }
            return .ok;
        }

        fn observeConfiguration(state: *State, host: *tick_host.Host, connection: *ConnectionState, payload: []const u8, exchange: *abi.TickExchange) abi.Status {
            const command = protocol_versions.staticCall("decodeConfiguration", connection.protocol_number, .{payload}) catch
                return .connection_failed;
            switch (command) {
                .ignore => {},
                .select_known_packs => return runConfigurationPhase(state, connection, exchange, .registries),
                .finish => return enterPlay(state, host, connection, exchange),
            }
            return .ok;
        }

        fn enterPlay(state: *State, host: *tick_host.Host, connection: *ConnectionState, exchange: *abi.TickExchange) abi.Status {
            if (!exchange.appendEnterPlay(connection.handle)) return .tick_failed;
            const slot: u16 = @intCast(connection.handle.index);
            const player = &host.players.records[slot];
            if (!world_identity.valid(player.world) or host.worlds.getConst(player.world) == null) {
                player.world = host.worlds.find(state.config.server.spawn_world) orelse
                    return .initialization_failed;
                const spawn = host.worlds.getConst(player.world) orelse
                    return .initialization_failed;
                player.position = .{
                    .x = @floatFromInt(spawn.spawn_x),
                    .y = @floatFromInt(spawn.spawn_y),
                    .z = @floatFromInt(spawn.spawn_z),
                };
                player.needs_spawn_position = false;
            }
            player.play_bootstrap_complete = false;
            player.play_join_terrain_ready = false;
            player.play_join_stage = 0;
            player.announce_join = connection.play_start_reason == .login;
            connection.phase = .play;
            host.players.transition(slot, .play);
            state.keep_alive_states[slot].last_tick = host.clock.tick;
            if (!containsSlot(state.pending_play_joins.items(), slot))
                state.pending_play_joins.append(slot) catch return .tick_failed;
            if (connection.play_start_reason == .login) state.player_joined.append(.{
                .slot = slot,
                .connection = connection.handle,
            }) catch return .tick_failed;
            state.play_started.append(.{
                .slot = slot,
                .connection = connection.handle,
                .reason = connection.play_start_reason,
            }) catch return .tick_failed;
            return .ok;
        }

        const StatusEmitter = struct {
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            first_error: ?anyerror = null,

            pub fn status(self: *@This(), draft: *const connection_api.StatusDraft) void {
                emitStatusResponse(self.connection, self.exchange, draft) catch |err| {
                    if (self.first_error == null) self.first_error = err;
                };
            }
        };

        const LoginChallenge = struct {
            public_key: []const u8,
            verify_token: []const u8,
        };

        const LoginEmitter = struct {
            state: *State,
            host: *tick_host.Host,
            connection: *ConnectionState,
            exchange: *abi.TickExchange,
            first_error: ?anyerror = null,
            challenge: ?LoginChallenge = null,
            new_player: bool = false,

            pub fn fail(self: *@This(), err: anyerror) void {
                if (self.first_error == null) self.first_error = err;
            }

            pub fn authenticationStarted(self: *const @This(), _: u16) bool {
                return self.connection.player_reserved or self.connection.awaiting_encryption;
            }

            pub fn loginPlayer(
                self: *@This(),
                slot: u16,
                username: []const u8,
                uuid: u128,
            ) bool {
                const disposition = self.host.players.login(self.host.random, slot, username, uuid) catch |err| {
                    self.fail(err);
                    return false;
                };
                self.new_player = disposition == .new_player;
                self.host.players.records[slot].needs_spawn_position =
                    self.new_player;
                if (self.new_player)
                    self.host.players.records[slot].gamemode =
                        @enumFromInt(@intFromEnum(self.state.config.server.default_gamemode));
                return true;
            }

            pub fn reservePlayer(self: *@This(), _: u16) void {
                if (self.connection.player_reserved) {
                    self.fail(error.PlayerAlreadyReserved);
                    return;
                }
                if (!self.exchange.appendReservePlayer(
                    self.connection.handle,
                    self.new_player,
                    self.host.players.records[self.connection.handle.index].uuid,
                    self.host.players.records[self.connection.handle.index].name_slice(),
                )) {
                    self.fail(error.TickCommandBufferExhausted);
                    return;
                }
                self.connection.player_reserved = true;
            }

            pub fn prepareEncryptionChallenge(self: *@This(), _: u16) void {
                const kernel = self.loginKernel() orelse {
                    self.fail(error.LoginTransportUnavailable);
                    return;
                };
                switch (kernel.fill_random(
                    kernel.context,
                    .{
                        .ptr = self.connection.verify_token[0..].ptr,
                        .len = self.connection.verify_token.len,
                    },
                )) {
                    .ok => {
                        const public_key = self.state.identity.publicKey();
                        self.challenge = .{
                            .public_key = public_key,
                            .verify_token = &self.connection.verify_token,
                        };
                        self.connection.awaiting_encryption = true;
                    },
                    else => self.fail(error.EncryptionChallengeRejected),
                }
            }

            pub fn encryptionRequest(self: *@This(), _: u16) bool {
                const challenge = self.challenge orelse {
                    self.fail(error.MissingEncryptionChallenge);
                    return false;
                };
                emitEncryptionRequest(
                    self.connection,
                    self.exchange,
                    challenge,
                ) catch |err| {
                    self.fail(err);
                    return false;
                };
                return true;
            }

            pub fn loginDisconnect(self: *@This(), _: u16, reason: []const u8) bool {
                emitLoginDisconnect(self.connection, self.exchange, reason) catch |err| {
                    self.fail(err);
                    return false;
                };
                return true;
            }

            pub fn closeAfterSend(self: *@This(), _: u16) void {
                if (!self.exchange.appendCloseAfterOutput(self.connection.handle))
                    self.fail(error.TickCommandBufferExhausted);
            }

            pub fn compressionPacket(self: *@This(), _: u16) bool {
                emitCompressionNegotiation(self.connection, self.exchange) catch |err| {
                    self.fail(err);
                    return false;
                };
                return true;
            }

            pub fn enableCompression(self: *@This(), _: u16) void {
                const kernel = self.loginKernel() orelse {
                    self.fail(error.TransportKernelUnavailable);
                    return;
                };
                if (kernel.set_compression(
                    kernel.context,
                    self.connection.handle,
                    config.compression_threshold,
                ) != .ok) self.fail(error.TransportRejected);
            }

            pub fn loginSuccess(self: *@This(), slot: u16) bool {
                const player = &self.host.players.records[slot];
                emitLoginSuccess(
                    self.connection,
                    self.exchange,
                    player.uuid,
                    player.name_slice(),
                ) catch |err| {
                    self.fail(err);
                    return false;
                };
                return true;
            }

            fn loginKernel(self: *const @This()) ?*const abi.KernelApi {
                const kernel = self.exchange.kernel orelse return null;
                if (!kernel.header.supports(@sizeOf(abi.KernelApi)) or
                    kernel.capabilities & abi.KernelCapability.entropy == 0)
                    return null;
                return kernel;
            }
        };

        const ConfigurationEmitter = struct {
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            first_error: ?anyerror = null,

            fn capture(self: *@This(), result: anytype) void {
                result catch |err| if (self.first_error == null) {
                    self.first_error = err;
                };
            }

            pub fn featureFlags(self: *@This(), _: u16) void {
                self.capture(self.emit("encodeFeatureFlags", .{}, 32));
            }

            pub fn knownPacks(self: *@This(), _: u16) void {
                const wire_descriptor = protocolDescriptor(self.connection.protocol_number) orelse {
                    self.first_error = error.UnsupportedProtocol;
                    return;
                };
                self.capture(self.emit(
                    "encodeKnownPacks",
                    .{wire_descriptor.minecraft_name},
                    wire_descriptor.minecraft_name.len + 32,
                ));
            }

            pub fn vanillaRegistries(
                self: *@This(),
                _: u16,
                dimensions: @import("world/dimension_api.zig").Service,
            ) void {
                for (configuration_bootstrap.singleton_registries) |registry| {
                    if (std.mem.eql(u8, registry.registry_id, "minecraft:dimension_type")) {
                        self.capture(self.emit(
                            "encodeDimensionRegistry",
                            .{dimensions.definitions},
                            dimensions.definitions.len * @import("world/dimensions.zig").max_protocol_nbt_bytes + 256,
                        ));
                    } else {
                        const entries = [_][]const u8{registry.entry_id};
                        self.capture(self.emit(
                            "encodeRegistryData",
                            .{ registry.registry_id, &entries },
                            256,
                        ));
                    }
                    if (self.first_error != null) return;
                    if (std.mem.eql(u8, registry.registry_id, "minecraft:dimension_type")) {
                        self.capture(self.emit(
                            "encodeRegistryData",
                            .{ "minecraft:worldgen/biome", configuration_bootstrap.biomeNames() },
                            16 * 1024,
                        ));
                        if (self.first_error != null) return;
                        self.capture(self.emit(
                            "encodeRegistryData",
                            .{ "minecraft:damage_type", &configuration_bootstrap.damage_types },
                            16 * 1024,
                        ));
                        if (self.first_error != null) return;
                    }
                }
            }

            pub fn gameplayTags(self: *@This(), _: u16) void {
                var payload_storage: [32 * 1024]u8 = undefined;
                const payload = configuration_bootstrap.writeGameplayTags(&payload_storage) catch |err| {
                    self.first_error = err;
                    return;
                };
                self.capture(self.emit(
                    "encodeConfigurationTags",
                    .{payload},
                    payload.len + 32,
                ));
            }

            pub fn finishConfiguration(self: *@This(), _: u16) void {
                self.capture(self.emit("encodeFinishConfiguration", .{}, 16));
            }

            fn emit(
                self: *@This(),
                comptime operation: []const u8,
                arguments: anytype,
                minimum_capacity: usize,
            ) !void {
                const lease = try reserveOutput(
                    self.connection,
                    self.exchange,
                    minimum_capacity,
                );
                errdefer if (self.exchange.kernel) |kernel|
                    tick_transport.cancel(kernel, lease);
                const body = try protocol_versions.staticCall(
                    operation,
                    self.connection.protocol_number,
                    .{lease.body} ++ arguments,
                );
                try commitOutput(self.exchange, lease, body.len);
            }
        };

        fn runLoginStart(
            state: *State,
            host: *tick_host.Host,
            connection: *ConnectionState,
            exchange: *abi.TickExchange,
            username: []const u8,
            uuid: u128,
        ) abi.Status {
            if (connection.handle.index > std.math.maxInt(u16))
                return .connection_failed;
            var draft = connection_api.LoginDraft{
                .slot = @intCast(connection.handle.index),
                .username = username,
                .uuid = uuid,
                .current_players = reservedPlayerCount(state),
                .maximum_players = state.config.server.max_players,
            };
            var emitter = LoginEmitter{
                .state = state,
                .host = host,
                .connection = connection,
                .exchange = exchange,
            };
            plugin_api.loginStart(state.plugins, &draft);
            if (!draft.accepted) {
                if (emitter.loginDisconnect(draft.slot, draft.rejection_reason))
                    emitter.closeAfterSend(draft.slot);
            } else if (emitter.authenticationStarted(draft.slot)) {
                emitter.fail(error.UnexpectedLoginStart);
            } else if (emitter.loginPlayer(draft.slot, draft.username, draft.uuid)) {
                emitter.reservePlayer(draft.slot);
                emitter.prepareEncryptionChallenge(draft.slot);
                _ = emitter.encryptionRequest(draft.slot);
            }
            return if (emitter.first_error == null) .ok else .connection_failed;
        }

        fn runLoginAuthenticated(
            state: *State,
            host: *tick_host.Host,
            connection: *ConnectionState,
            exchange: *abi.TickExchange,
        ) abi.Status {
            if (connection.handle.index > std.math.maxInt(u16))
                return .connection_failed;
            var emitter = LoginEmitter{
                .state = state,
                .host = host,
                .connection = connection,
                .exchange = exchange,
            };
            const slot: u16 = @intCast(connection.handle.index);
            if (emitter.compressionPacket(slot)) {
                emitter.enableCompression(slot);
                _ = emitter.loginSuccess(slot);
            }
            return if (emitter.first_error == null) .ok else .connection_failed;
        }

        fn runConfigurationPhase(
            state: *State,
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            comptime step: ConfigurationStep,
        ) abi.Status {
            if (connection.handle.index > std.math.maxInt(u16))
                return .connection_failed;
            var emitter = ConfigurationEmitter{
                .connection = connection,
                .exchange = exchange,
            };
            const slot: u16 = @intCast(connection.handle.index);
            switch (step) {
                .start => {
                    emitter.featureFlags(slot);
                    emitter.knownPacks(slot);
                },
                .registries => {
                    const worlds = ProfileFactory.stores(state.plugins).worlds;
                    const dimensions = worlds.dimensionRegistry() orelse
                        return .initialization_failed;
                    emitter.vanillaRegistries(slot, dimensions);
                    emitter.gameplayTags(slot);
                    emitter.finishConfiguration(slot);
                },
            }
            return if (emitter.first_error == null) .ok else .connection_failed;
        }

        fn reservedPlayerCount(state: *const State) usize {
            var count: usize = 0;
            for (state.connections) |connection|
                if (connection.active and connection.player_reserved) {
                    count += 1;
                };
            return count;
        }

        fn runStatus(
            state: *State,
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
        ) abi.Status {
            const wire_descriptor = protocolDescriptor(connection.protocol_number) orelse
                return .connection_failed;
            if (connection.handle.index > std.math.maxInt(u16)) return .connection_failed;
            var draft = connection_api.StatusDraft{
                .slot = @intCast(connection.handle.index),
                .version_name = wire_descriptor.status_name,
                .protocol_number = wire_descriptor.protocol_number,
                .motd = state.config.server.status_motd,
                .maximum_players = state.config.server.max_players,
                .online_players = onlineConnectionCount(state),
            };
            var emitter = StatusEmitter{
                .connection = connection,
                .exchange = exchange,
            };
            plugin_api.status(state.plugins, &draft);
            if (!draft.cancelled) emitter.status(&draft);
            return if (emitter.first_error == null) .ok else .connection_failed;
        }

        fn onlineConnectionCount(state: *const State) usize {
            var count: usize = 0;
            for (state.connections) |connection|
                if (connection.active and connection.phase == .play) {
                    count += 1;
                };
            return count;
        }

        fn protocolDescriptor(protocol_number: i32) ?*const protocol_versions.Descriptor {
            for (&protocol_versions.supported) |*wire_descriptor|
                if (wire_descriptor.protocol_number == protocol_number) return wire_descriptor;
            return null;
        }

        fn completeEncryption(
            exchange: *abi.TickExchange,
            identity: *const crypto_support.Identity,
            connection: *ConnectionState,
            response: anytype,
        ) bool {
            var shared_secret: [16]u8 = undefined;
            var token_storage: [4]u8 = undefined;
            const secret = identity.decrypt(&shared_secret, response.shared_secret) catch return false;
            const token = identity.decrypt(&token_storage, response.verify_token) catch return false;
            if (secret.len != shared_secret.len or token.len != connection.verify_token.len or
                !std.crypto.timing_safe.eql([4]u8, token[0..4].*, connection.verify_token))
                return false;
            const kernel = exchange.kernel orelse return false;
            if (kernel.set_encryption(
                kernel.context,
                connection.handle,
                .{ .ptr = &shared_secret, .len = shared_secret.len },
            ) != .ok) return false;
            connection.awaiting_encryption = false;
            return true;
        }

        fn emitEncryptionRequest(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            challenge: LoginChallenge,
        ) !void {
            const lease = try reserveOutput(connection, exchange, 512);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeEncryptionRequest",
                connection.protocol_number,
                .{
                    lease.body,
                    challenge.public_key,
                    challenge.verify_token,
                },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn emitLoginDisconnect(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            reason: []const u8,
        ) !void {
            var component_storage: [256]u8 = undefined;
            const component = try std.fmt.bufPrint(
                &component_storage,
                "{{\"text\":\"{s}\"}}",
                .{reason},
            );
            const lease = try reserveOutput(connection, exchange, component.len + 16);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeLoginDisconnect",
                connection.protocol_number,
                .{ lease.body, component },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn emitCompressionNegotiation(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
        ) !void {
            const lease = try reserveOutput(connection, exchange, 16);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeSetCompression",
                connection.protocol_number,
                .{ lease.body, config.compression_threshold },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn emitLoginSuccess(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            uuid: u128,
            username: []const u8,
        ) !void {
            const lease = try reserveOutput(connection, exchange, username.len + 32);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeLoginSuccess",
                connection.protocol_number,
                .{ lease.body, uuid, username },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn reserveOutput(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            minimum_capacity: usize,
        ) !tick_transport.Reservation {
            const kernel = exchange.kernel orelse return error.OutputKernelUnavailable;
            if (!kernel.header.supports(@sizeOf(abi.KernelApi)) or
                kernel.capabilities & abi.KernelCapability.output_leases == 0)
                return error.OutputKernelUnavailable;
            return tick_transport.begin(kernel, connection.handle, minimum_capacity);
        }

        fn commitOutput(
            exchange: *abi.TickExchange,
            lease: tick_transport.Reservation,
            body_length: usize,
        ) !void {
            const kernel = exchange.kernel orelse return error.OutputKernelUnavailable;
            try tick_transport.finish(kernel, lease, body_length);
        }

        fn emitStatusResponse(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            draft: *const connection_api.StatusDraft,
        ) !void {
            var json_storage: [1024]u8 = undefined;
            const json = try std.fmt.bufPrint(
                &json_storage,
                \\{{"version":{{"name":"{s}","protocol":{}}},"players":{{"max":{},"online":{}}},"description":{{"text":"{s}"}}}}
            ,
                .{
                    draft.version_name,
                    draft.protocol_number,
                    draft.maximum_players,
                    draft.online_players,
                    draft.motd,
                },
            );
            const lease = try reserveOutput(connection, exchange, json.len + 16);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeStatusResponse",
                connection.protocol_number,
                .{ lease.body, json },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn emitStatusPong(
            connection: *const ConnectionState,
            exchange: *abi.TickExchange,
            timestamp: i64,
        ) !void {
            const lease = try reserveOutput(connection, exchange, 16);
            errdefer if (exchange.kernel) |kernel|
                tick_transport.cancel(kernel, lease);
            const body = try protocol_versions.staticCall(
                "encodeStatusPong",
                connection.protocol_number,
                .{ lease.body, timestamp },
            );
            try commitOutput(exchange, lease, body.len);
        }

        fn beginReconfiguration(
            state: *State,
            exchange: *abi.TickExchange,
        ) abi.Status {
            for (state.connections) |*connection| {
                if (!connection.active or connection.phase != .play) continue;
                const lease = reserveOutput(connection, exchange, 16) catch
                    return .tick_failed;
                const body = protocol_versions.staticCall(
                    "encodeStartConfiguration",
                    connection.protocol_number,
                    .{lease.body},
                ) catch {
                    if (exchange.kernel) |kernel| tick_transport.cancel(kernel, lease);
                    return .tick_failed;
                };
                commitOutput(exchange, lease, body.len) catch return .tick_failed;
                connection.reconfiguring = true;
                connection.play_start_reason = .reconfiguration;
            }
            return .ok;
        }

        fn runTick(raw_state: *anyopaque, call: *const abi.TickInvocation) abi.Status {
            const state: *State = @ptrCast(@alignCast(raw_state));
            var event_host = configuredHost(state, call.exchange);
            const event_status = consumeKernelEvents(state, &event_host, call.exchange);
            if (event_status != .ok) return event_status;
            var host = configuredHost(state, call.exchange);
            active_host = &host;
            defer active_host = null;
            state.profiler.beginTick();
            defer state.profiler.finishTick();
            host.beginTerrainGenerationBatch();
            const tick_allocator = state.tick_arena.begin();
            defer state.tick_arena.finish();
            server_tick.run(
                ProfileFactory,
                &host,
                state.plugins,
                state.services,
                tick_allocator,
                .{ .values = state.player_joined.items() },
                .{ .values = state.players_left.items() },
                state.play_started.items(),
            ) catch |err| {
                std.log.err("event=tick_module_tick_failed error={s}", .{@errorName(err)});
                return .tick_failed;
            };
            generateTerrain(state, call.exchange) catch return .tick_failed;
            captureWorldMetrics(state, &host);
            return .ok;
        }

        fn tick(raw_state: *anyopaque, call_input: *const abi.TickInvocation) callconv(.c) abi.Status {
            const call = invocation(call_input) orelse return .invalid_request;
            return runTick(raw_state, call);
        }

        fn generateTerrain(state: *State, exchange: *const abi.TickExchange) !void {
            state.terrain_last_ns = 0;
            const kernel = exchange.kernel orelse return;
            if (kernel.capabilities & abi.KernelCapability.bulk_work == 0) return;
            const stores = ProfileFactory.stores(state.plugins);
            const blocks = stores.blocks;
            const clock = stores.clock;
            if (blocks.pendingChunkGenerationCount() == 0) return;
            const started = monotonicNanoseconds() orelse return error.ClockUnavailable;
            defer {
                const finished = monotonicNanoseconds() orelse started;
                state.terrain_last_ns = finished -| started;
                state.terrain_max_ns = @max(state.terrain_max_ns, state.terrain_last_ns);
            }
            for (0..config.max_bulk_terrain_jobs) |_| {
                const now = monotonicNanoseconds() orelse return error.ClockUnavailable;
                if (now >= exchange.deadline_ns or
                    exchange.deadline_ns - now <= config.bulk_work_reserve_ns)
                    break;
                switch (blocks.generateRequestedChunk(clock.tick)) {
                    .complete, .pending => {},
                    .idle, .backpressured => break,
                }
            }
            captureWorldMetricsFromStores(state, clock, blocks);
        }

        fn monotonicNanoseconds() ?u64 {
            var now: std.os.linux.timespec = undefined;
            if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
                return null;
            return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
                @as(u64, @intCast(now.nsec));
        }

        fn milliseconds(nanoseconds: u64) f64 {
            return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
        }

        fn setProfiling(raw_state: *anyopaque, enabled: u8) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(raw_state));
            state.profiler.setEnabled(enabled != 0);
        }

        fn captureWorldMetrics(state: *State, host: *const tick_host.Host) void {
            state.world_tick = host.clock.tick;
            state.living_entity_count = host.living.entities.active_count;
            state.item_entity_count = host.items.active_count;
            captureWorldMetricsFromStores(state, host.clock, host.blocks);
        }

        fn captureWorldMetricsFromStores(
            state: *State,
            clock: *const world_clock.Clock,
            blocks: *const block_store.Blocks,
        ) void {
            state.world_tick = clock.tick;
            state.resident_section_count = blocks.modified_section_count;
            state.modified_block_count = blocks.modified_block_count;
            state.pending_terrain_chunk_count = blocks.pendingChunkGenerationCount();
        }

        fn metrics(raw_state: *const anyopaque, output: *abi.MetricsSnapshot) callconv(.c) void {
            const state: *const State = @ptrCast(@alignCast(raw_state));
            const profiler = &state.profiler;
            const output_header = output.header;
            if (output_header.major != abi.major_version or
                output_header.size < @sizeOf(abi.Header)) return;
            var snapshot: abi.MetricsSnapshot = .{
                .tick_count = profiler.tick_count,
                .tick_total_ns = profiler.tick_total_ns,
                .tick_window_ns = profiler.tick_window_ns,
                .tick_last_ns = profiler.tick_last_ns,
                .tick_max_ns = profiler.tick_max_ns,
                .window_count = profiler.window_count,
                .plugin_count = plugin_count,
                .trace_count = trace_count,
                .world_tick = state.world_tick,
                .living_entities = state.living_entity_count,
                .item_entities = state.item_entity_count,
                .resident_sections = state.resident_section_count,
                .modified_blocks = state.modified_block_count,
                .pending_terrain_chunks = state.pending_terrain_chunk_count,
                .terrain_last_ns = state.terrain_last_ns,
                .terrain_max_ns = state.terrain_max_ns,
                .generation_memory_bytes = state_storage_offset + state.state_storage_used,
                .tick_memory_capacity_bytes = state.tick_arena.bytes.len,
            };
            const visible_plugins = @min(plugin_metric_metadata.len, abi.metrics_plugin_capacity);
            for (plugin_metric_metadata[0..visible_plugins], 0..) |metadata, index| {
                const timing = profiler.plugins[index];
                snapshot.plugins[index] = .{
                    .id_ptr = metadata.id_ptr,
                    .id_len = metadata.id_len,
                    .total_ns = timing.total_ns,
                    .window_ns = timing.window_ns,
                    .last_ns = timing.last_ns,
                    .max_ns = timing.max_ns,
                    .generation_bytes = timing.generation_bytes,
                    .tick_memory_total_bytes = timing.tick_memory_total_bytes,
                    .tick_memory_window_bytes = timing.tick_memory_window_bytes,
                    .tick_memory_last_bytes = timing.tick_memory_last_bytes,
                    .tick_memory_max_bytes = timing.tick_memory_max_bytes,
                };
            }
            const visible_traces = @min(trace_metric_metadata.len, abi.metrics_trace_capacity);
            for (trace_metric_metadata[0..visible_traces], 0..) |metadata, trace_index| {
                const timing = profiler.traces[trace_index];
                snapshot.traces[trace_index] = .{
                    .plugin_index = metadata.plugin_index,
                    .name_ptr = metadata.name_ptr,
                    .name_len = metadata.name_len,
                    .total_ns = timing.total_ns,
                    .window_ns = timing.window_ns,
                    .last_ns = timing.last_ns,
                    .max_ns = timing.max_ns,
                    .total_calls = timing.total_calls,
                    .window_calls = timing.window_calls,
                    .last_calls = timing.last_calls,
                    .max_calls = timing.max_calls,
                };
            }
            const copy_len = @min(@as(usize, output_header.size), @sizeOf(abi.MetricsSnapshot));
            const destination: [*]u8 = @ptrCast(output);
            const source: [*]const u8 = @ptrCast(&snapshot);
            @memcpy(destination[0..copy_len], source[0..copy_len]);
        }

        fn deinitialize(raw_state: *anyopaque) callconv(.c) void {
            const state: *State = @ptrCast(@alignCast(raw_state));
            const started_ns = monotonicNanoseconds() orelse 0;
            plugin_api.deinit(state.plugins);
            const plugins_ns = monotonicNanoseconds() orelse started_ns;
            state.services.deinit();
            const services_ns = monotonicNanoseconds() orelse plugins_ns;
            state.identity.deinit();
            const completed_ns = monotonicNanoseconds() orelse services_ns;
            std.log.info(
                "event=tick_module_deinit_profile plugins_ms={d:.3} services_ms={d:.3} identity_ms={d:.3} total_ms={d:.3}",
                .{
                    milliseconds(plugins_ns -| started_ns),
                    milliseconds(services_ns -| plugins_ns),
                    milliseconds(completed_ns -| services_ns),
                    milliseconds(completed_ns -| started_ns),
                },
            );
        }

        const module_descriptor: abi.Descriptor = .{
            .optimize_mode = @intFromEnum(builtin.mode),
            .required_kernel_capabilities = abi.KernelCapability.output_leases |
                abi.KernelCapability.entropy |
                abi.KernelCapability.wire_transport,
            .state_size = @sizeOf(State),
            .state_alignment = @alignOf(State),
            .state_capacity = config.tick_state_bytes,
            .maximum_memory_bytes = ProfileFactory.configuration.server.maximum_memory_bytes,
            .maximum_players = ProfileFactory.configuration.server.max_players,
            .default_gamemode = @intFromEnum(ProfileFactory.configuration.server.default_gamemode),
            .supported_protocols = &supported_protocols,
            .supported_protocol_count = supported_protocols.len,
        };

        pub fn moduleDescribe() callconv(.c) *const abi.Descriptor {
            return &module_descriptor;
        }

        pub fn moduleInitialize(raw_state: *anyopaque, input: *const abi.Initialize) callconv(.c) abi.Status {
            return initialize(
                raw_state,
                input.panic_fn,
                input.state_bytes,
                input.state_used_bytes,
                input.storage_mode,
            );
        }

        pub fn moduleTick(raw_state: *anyopaque, input: *const abi.TickInvocation) callconv(.c) abi.Status {
            return tick(raw_state, input);
        }

        pub fn moduleSave(raw_state: *anyopaque) callconv(.c) abi.Status {
            return saveConfiguredPlugins(raw_state);
        }

        pub fn moduleLoad(raw_state: *anyopaque) callconv(.c) abi.Status {
            return loadConfiguredPlugins(raw_state);
        }

        pub fn moduleBeginReconfiguration(raw_state: *anyopaque, exchange: *abi.TickExchange) callconv(.c) abi.Status {
            return beginReconfiguration(@ptrCast(@alignCast(raw_state)), exchange);
        }

        pub fn moduleDeinitialize(raw_state: *anyopaque) callconv(.c) void {
            deinitialize(raw_state);
        }

        pub fn moduleSetProfiling(raw_state: *anyopaque, enabled: u8) callconv(.c) void {
            setProfiling(raw_state, enabled);
        }

        pub fn moduleMetrics(raw_state: *const anyopaque, output: *abi.MetricsSnapshot) callconv(.c) void {
            metrics(raw_state, output);
        }

        pub const Harness = tick_module_harness.Harness(State, ProfileFactory);
    };
}

test "disconnect removes play input staged earlier in the tick" {
    var inputs = [_]tick_host.BorrowedInput{
        .{ .slot = 3, .protocol_number = 772, .payload = &.{0x01} },
        .{ .slot = 7, .protocol_number = 772, .payload = &.{0x02} },
        .{ .slot = 3, .protocol_number = 772, .payload = &.{0x03} },
    };
    var length = inputs.len;
    removeBorrowedInputsForSlot(&inputs, &length, 3);
    try std.testing.expectEqual(@as(usize, 1), length);
    try std.testing.expectEqual(@as(u16, 7), inputs[0].slot);
    try std.testing.expectEqualSlices(u8, &.{0x02}, inputs[0].payload);
}
