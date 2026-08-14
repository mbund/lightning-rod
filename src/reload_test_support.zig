const std = @import("std");
const protocol = @import("protocol");
const lightning_rod = @import("lightning_rod");
const reactor = lightning_rod.reactor;
const hot_reload = lightning_rod.hot_reload;
const reload_abi = lightning_rod.hot_reload_abi;
const protocol_versions = lightning_rod.protocol_versions;
const wire = lightning_rod.wire;

const Server = reactor.Server;
const config = lightning_rod.config.value;

fn stagePacket(
    events: reload_abi.EventWriter,
    handle: reload_abi.ConnectionHandle,
    body: []const u8,
) bool {
    var frame: [4096 + 5]u8 = undefined;
    if (body.len > frame.len - 5) return false;
    var value: u32 = @intCast(body.len);
    var prefix_len: usize = 0;
    for (0..5) |_| {
        frame[prefix_len] = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) frame[prefix_len] |= 0x80;
        prefix_len += 1;
        if (value == 0) break;
    }
    @memcpy(frame[prefix_len..][0..body.len], body);
    return events.rawInput(handle, frame[0 .. prefix_len + body.len]);
}

pub const TickModuleManager = hot_reload.Manager;
pub const tick_module_default_path = config.tick_module_path;

const TestServer = struct {
    server: *Server,

    fn init(_: std.mem.Allocator, seed: u64) !TestServer {
        const server = try std.heap.page_allocator.create(Server);
        errdefer std.heap.page_allocator.destroy(server);
        try server.allocateRuntimeStorage(std.heap.page_allocator);
        errdefer server.runtime_storage.deinit();
        var entropy = [_]u8{0} ** std.Random.ChaCha.secret_seed_length;
        std.mem.writeInt(u64, entropy[0..8], seed, .little);
        server.secure_random = std.Random.ChaCha.init(entropy);
        server.mailbox.clear();
        server.tick_deadline = .{ .sec = std.math.maxInt(i32), .nsec = 0 };
        server.network.output.free_count = config.output_buffer_count;
        for (0..config.output_buffer_count) |index|
            server.network.output.free[index] = @intCast(config.output_buffer_count - 1 - index);
        server.initClients();
        return .{ .server = server };
    }

    fn deinit(self: *TestServer) void {
        self.server.transport.deinit();
        self.server.network.connections.deinit();
        self.server.runtime_storage.deinit();
        std.heap.page_allocator.destroy(self.server);
    }
};

fn tick(
    manager: *TickModuleManager,
    server: *Server,
    invocation: *const reload_abi.TickInvocation,
) !void {
    manager.tick(invocation) catch |err| {
        try server.transport.finishTick();
        return err;
    };
    try server.transport.finishTick();
}

/// Exercises the actual shared-object tick entry using the same black-box
/// backend as conformance tests, without opening a socket or a world file.
pub fn exerciseReloadableTick(manager: *TickModuleManager, allocator: std.mem.Allocator) !void {
    var harness = try TestServer.init(allocator, 0x7265_6c6f_6164);
    defer harness.deinit();
    const server = harness.server;
    server.network.connections.items[0].protocol_number = protocol_versions.default.protocolNumber();
    server.network.connections.items[1].protocol_number = protocol_versions.default.protocolNumber();
    std.debug.assert(server.mailbox.connected(server.connectionHandle(0)));
    std.debug.assert(server.mailbox.connected(server.connectionHandle(1)));

    const before = manager.metricsSnapshot().world_tick;
    var exchange = server.tickExchange();
    const invocation = reload_abi.TickInvocation{
        .exchange = &exchange,
    };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
    if (manager.metricsSnapshot().world_tick <= before)
        return error.ReloadableTickDidNotAdvance;

    std.debug.assert(server.mailbox.disconnected(server.connectionHandle(0), .peer_closed));
    std.debug.assert(server.mailbox.disconnected(server.connectionHandle(1), .peer_closed));
    exchange = server.tickExchange();
    exchange.resetCommands();
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
}

pub fn exerciseReloadedPlaySession(
    manager: *TickModuleManager,
    allocator: std.mem.Allocator,
) !void {
    var harness = try TestServer.init(allocator, 0x7265_7375_6d65);
    defer harness.deinit();
    const server = harness.server;

    const slot: u16 = 0;
    const name = "reload-player";
    const uuid: u128 = 0x1122_3344_5566_7788_99aa_bbcc_ddee_ff00;
    const client = &server.network.connections.items[slot];
    client.reset();
    client.protocol_number = protocol_versions.default.protocolNumber();
    client.phase = .play;
    client.player_reserved = true;
    client.player_uuid = uuid;
    client.player_name_len = name.len;
    @memcpy(client.player_name[0..name.len], name);
    server.network.connections.markPlaying(slot);

    var event_storage: [512]u8 align(8) = undefined;
    var event_bytes: usize = 0;
    const events = reload_abi.EventWriter{
        .buffer = &event_storage,
        .written = &event_bytes,
    };
    const handle = server.connectionHandle(slot);
    if (!events.attachedConnection(handle, client.protocol_number, uuid, name, .play, false))
        return error.TestEventBufferExhausted;
    var exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    const invocation = reload_abi.TickInvocation{ .exchange = &exchange };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);

    event_bytes = 0;
    exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = 0 };
    try manager.beginReconfiguration(&exchange);
    if (client.output_segment_count != 1) return error.MissingStartConfiguration;
    const transition_segment = client.constOutputSegment(0);
    const transition_bytes = server.network.output.buffers[transition_segment.buffer_index][transition_segment.offset..transition_segment.len];
    const transition = (try wire.nextPacket(transition_bytes)) orelse
        return error.MissingStartConfiguration;
    switch (try protocol.play.toClient.read(transition.payload).name()) {
        .start_configuration => |body| try body.finish(),
        else => return error.UnexpectedReconfigurationPacket,
    }
    server.network.output.freeClient(client, 0);

    try manager.transitionPreparedReload(0, 0);
    if (manager.activeGenerationNumber() != 2)
        return error.ReloadGenerationWasNotActivated;

    var packet_storage: [64]u8 = undefined;
    const play_writer = protocol.play.toServer.write(&packet_storage);
    const tick_end = try play_writer.tick_end();
    event_bytes = 0;
    if (!events.attachedConnection(
        handle,
        client.protocol_number,
        uuid,
        name,
        .play,
        true,
    )) return error.TestEventBufferExhausted;
    if (!stagePacket(events, handle, (try tick_end.finish()).finish()))
        return error.TestEventBufferExhausted;
    exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
    if (client.phase != .play) return error.InFlightPlayPacketClosedReconfiguration;

    event_bytes = 0;
    const acknowledged = try play_writer.configuration_acknowledged();
    if (!stagePacket(events, handle, (try acknowledged.finish()).finish()))
        return error.TestEventBufferExhausted;

    exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
    if (client.phase != .configuration) return error.ReconfigurationWasNotAcknowledged;
    if (!client.hasQueuedOutput()) return error.MissingConfigurationStart;
    server.network.output.freeClient(client, 0);

    event_bytes = 0;
    const select_known_packs = [_]u8{ 0x07, 0x00 };
    if (!stagePacket(events, handle, &select_known_packs))
        return error.TestEventBufferExhausted;
    exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    try tick(manager, server, &invocation);
    try verifyConfigurationBootstrap(server, client);
    server.network.output.freeClient(client, 0);

    event_bytes = 0;
    const finish_configuration = [_]u8{0x03};
    if (!stagePacket(events, handle, &finish_configuration))
        return error.TestEventBufferExhausted;
    exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
    if (client.phase != .play) return error.ReconfigurationDidNotReturnToPlay;
    server.network.output.freeClient(client, 0);
}

pub fn exerciseReloadableStatus(
    manager: *TickModuleManager,
    allocator: std.mem.Allocator,
) !void {
    var harness = try TestServer.init(allocator, 0x7374_6174_7573);
    defer harness.deinit();
    const server = harness.server;

    const slot: u16 = 0;
    const client = &server.network.connections.items[slot];
    client.reset();
    client.phase = .handshaking;
    const handle = server.connectionHandle(slot);

    var event_storage: [512]u8 align(8) = undefined;
    var event_bytes: usize = 0;
    const events = reload_abi.EventWriter{
        .buffer = &event_storage,
        .written = &event_bytes,
    };
    if (!events.connected(handle)) return error.TestEventBufferExhausted;

    var packet_storage: [128]u8 = undefined;
    const handshake_root = protocol.handshaking.toServer.write(&packet_storage);
    const set_protocol = try handshake_root.set_protocol();
    const version = try set_protocol.protocolVersion(772);
    const host = try version.serverHost("localhost");
    const port = try host.serverPort(25565);
    const handshake = (try port.nextState(1)).finish();
    if (!stagePacket(events, handle, handshake)) return error.TestEventBufferExhausted;

    const status_root = protocol.status.toServer.write(&packet_storage);
    const request = try status_root.ping_start();
    const status_request = (try request.finish()).finish();
    if (!stagePacket(events, handle, status_request)) return error.TestEventBufferExhausted;

    var exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    const invocation = reload_abi.TickInvocation{
        .exchange = &exchange,
    };
    try tick(manager, server, &invocation);

    var commands = try reload_abi.CommandIterator.init(&exchange);
    const selection = try (try commands.next()).?.selectProtocol();
    if (selection.connection.value() != handle.value() or
        selection.protocol_number != 772 or
        selection.intent != 1)
        return error.UnexpectedProtocolSelection;

    if (client.output_segment_count != 1) return error.MissingStatusResponse;
    const segment = client.constOutputSegment(0);
    const queued = server.network.output.buffers[segment.buffer_index][segment.offset..segment.len];
    const framed = (try wire.nextPacket(queued)) orelse return error.MissingStatusResponse;
    if (framed.total_len != queued.len) return error.UnexpectedStatusOutput;
    switch (try protocol.status.toClient.read(framed.payload).name()) {
        .server_info => |packet| {
            const response, const done = try packet.response();
            try done.finish();
            if (std.mem.indexOf(u8, response, "\"protocol\":772") == null)
                return error.IncorrectStatusProtocol;
        },
        else => return error.UnexpectedStatusOutput,
    }

    event_bytes = 0;
    if (!events.disconnected(handle, .peer_closed)) return error.TestEventBufferExhausted;
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    exchange.resetCommands();
    try tick(manager, server, &invocation);
}

pub fn exerciseReloadableConfiguration(
    manager: *TickModuleManager,
    allocator: std.mem.Allocator,
) !void {
    var harness = try TestServer.init(allocator, 0x636f_6e66_6967);
    defer harness.deinit();
    const server = harness.server;

    const slot: u16 = 23;
    const client = &server.network.connections.items[slot];
    client.reset();
    client.phase = .configuration;
    client.protocol_number = protocol_versions.default.protocolNumber();
    const handle = server.connectionHandle(slot);

    var event_storage: [256]u8 align(8) = undefined;
    var event_bytes: usize = 0;
    const events = reload_abi.EventWriter{
        .buffer = &event_storage,
        .written = &event_bytes,
    };
    const select_known_packs = [_]u8{ 0x07, 0x00 };
    if (!stagePacket(events, handle, &select_known_packs))
        return error.TestEventBufferExhausted;

    var exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    const invocation = reload_abi.TickInvocation{
        .exchange = &exchange,
    };
    try tick(manager, server, &invocation);
    try verifyConfigurationBootstrap(server, client);

    event_bytes = 0;
    const finish_configuration = [_]u8{0x03};
    if (!stagePacket(events, handle, &finish_configuration))
        return error.TestEventBufferExhausted;
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    exchange.resetCommands();
    try tick(manager, server, &invocation);

    try verifyPlayTransition(&exchange, handle);

    try server.consumeTickCommandsBuffered(&exchange);
    server.network.output.freeClient(client, 0);

    event_bytes = 0;
    exchange.events = .{ .ptr = &event_storage, .len = 0 };
    exchange.resetCommands();
    try tick(manager, server, &invocation);
    try generatePlayJoinTerrain(manager);
    exchange.resetCommands();
    try tick(manager, server, &invocation);
    if (!try hasPlayLogin(server, client))
        return error.MissingPlayBootstrap;
}

fn verifyConfigurationBootstrap(server: *Server, client: anytype) !void {
    if (client.output_segment_count == 0)
        return error.MissingConfigurationBootstrap;
    const segment = client.constOutputSegment(0);
    var queued = server.network.output.buffers[segment.buffer_index][segment.offset..segment.len];
    var registry_packets: usize = 0;
    var tags_packets: usize = 0;
    var finish_packets: usize = 0;
    while (queued.len != 0) {
        const framed = (try wire.nextPacket(queued)) orelse
            return error.TruncatedConfigurationBootstrap;
        switch (try protocol.configuration.toClient.read(framed.payload).name()) {
            .registry_data => registry_packets += 1,
            .tags => tags_packets += 1,
            .finish_configuration => finish_packets += 1,
            else => return error.UnexpectedConfigurationBootstrapPacket,
        }
        queued = queued[framed.total_len..];
    }
    if (registry_packets != 11 or tags_packets != 1 or finish_packets != 1)
        return error.IncompleteConfigurationBootstrap;
}

fn verifyPlayTransition(exchange: *reload_abi.TickExchange, handle: reload_abi.ConnectionHandle) !void {
    var entered_play = false;
    var commands = try reload_abi.CommandIterator.init(exchange);
    while (try commands.next()) |command| switch (command.header.kind) {
        reload_abi.CommandKind.enter_play => {
            const transition = try command.enterPlay();
            if (transition.connection.value() != handle.value())
                return error.UnexpectedPlayTransition;
            entered_play = true;
        },
        reload_abi.CommandKind.log => _ = try command.log(),
        else => return error.UnexpectedTickCommand,
    };
    if (!entered_play) return error.MissingPlayTransition;
}

fn generatePlayJoinTerrain(manager: *TickModuleManager) !void {
    if (manager.metricsSnapshot().pending_terrain_chunks != 0)
        return error.PlayJoinSpawnTerrainDidNotComplete;
}

fn hasPlayLogin(server: *const Server, client: anytype) !bool {
    for (0..client.output_segment_count) |segment_index| {
        const segment = client.constOutputSegment(segment_index);
        var bytes = server.network.output.buffers[segment.buffer_index][segment.offset..segment.len];
        while (bytes.len != 0) {
            const framed = (try wire.nextPacket(bytes)) orelse
                return error.TruncatedPlayBootstrap;
            switch (try protocol.play.toClient.read(framed.payload).name()) {
                .login => return true,
                else => {},
            }
            bytes = bytes[framed.total_len..];
        }
    }
    return false;
}

pub fn exerciseReloadablePlayInput(
    manager: *TickModuleManager,
    allocator: std.mem.Allocator,
) !void {
    var harness = try TestServer.init(allocator, 0x706c_6179_696e);
    defer harness.deinit();
    const server = harness.server;

    const slot: u16 = 23;
    const client = &server.network.connections.items[slot];
    client.reset();
    client.phase = .play;
    client.protocol_number = protocol_versions.default.protocolNumber();
    const handle = server.connectionHandle(slot);

    var movement_storage: [64]u8 = undefined;
    const movement_root = protocol.play.toServer.write(&movement_storage);
    const movement_body = try movement_root.position_look();
    const movement_x = try movement_body.x(12.5);
    const movement_y = try movement_x.y(70.0);
    const movement_z = try movement_y.z(-3.25);
    const movement_yaw = try movement_z.yaw(90.0);
    const movement_pitch = try movement_yaw.pitch(15.0);
    const movement = (try movement_pitch.flags(.{ .onGround = true })).finish();
    var framed: [69]u8 = undefined;
    var value: u32 = @intCast(movement.len);
    var prefix_len: usize = 0;
    for (0..5) |_| {
        framed[prefix_len] = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) framed[prefix_len] |= 0x80;
        prefix_len += 1;
        if (value == 0) break;
    }
    @memcpy(framed[prefix_len..][0..movement.len], movement);
    if (!server.mailbox.rawInput(handle, framed[0 .. prefix_len + movement.len]))
        return error.TickEventBufferExhausted;

    var exchange = server.tickExchange();
    const invocation = reload_abi.TickInvocation{
        .exchange = &exchange,
    };
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);

    if (server.network.connections.items[slot].phase == .free)
        return error.ReloadablePlayInputRejected;
    if (server.connectionHandle(slot).value() != handle.value())
        return error.ReloadablePlayConnectionChanged;

    std.debug.assert(server.mailbox.disconnected(server.connectionHandle(slot), .peer_closed));
    exchange = server.tickExchange();
    exchange.resetCommands();
    try tick(manager, server, &invocation);
    try server.consumeTickCommandsBuffered(&exchange);
}

pub fn exerciseReloadableLoginStart(
    manager: *TickModuleManager,
    allocator: std.mem.Allocator,
) !void {
    var harness = try TestServer.init(allocator, 0x6c6f_6769_6e);
    defer harness.deinit();
    const server = harness.server;

    const slot: u16 = 2;
    const client = &server.network.connections.items[slot];
    client.reset();
    client.phase = .handshaking;
    client.protocol_number = protocol_versions.default.protocolNumber();
    const handle = server.connectionHandle(slot);

    var event_storage: [768]u8 align(8) = undefined;
    var event_bytes: usize = 0;
    const events = reload_abi.EventWriter{
        .buffer = &event_storage,
        .written = &event_bytes,
    };
    if (!events.connected(handle)) return error.TestEventBufferExhausted;

    var packet_storage: [128]u8 = undefined;
    const handshake_root = protocol.handshaking.toServer.write(&packet_storage);
    const set_protocol = try handshake_root.set_protocol();
    const version = try set_protocol.protocolVersion(772);
    const host = try version.serverHost("localhost");
    const port = try host.serverPort(25565);
    const handshake = (try port.nextState(2)).finish();
    if (!stagePacket(events, handle, handshake)) return error.TestEventBufferExhausted;

    const login_root = protocol.login.toServer.write(&packet_storage);
    const start = try login_root.login_start();
    const username = try start.username("module-login");
    const login_start = (try username.playerUUID(0x1234)).finish();
    if (!stagePacket(events, handle, login_start)) return error.TestEventBufferExhausted;

    var exchange = server.tickExchange();
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    const invocation = reload_abi.TickInvocation{
        .exchange = &exchange,
    };
    try tick(manager, server, &invocation);

    var selected = false;
    var reserved = false;
    var commands = try reload_abi.CommandIterator.init(&exchange);
    while (try commands.next()) |command| switch (command.header.kind) {
        reload_abi.CommandKind.select_protocol => {
            _ = try command.selectProtocol();
            selected = true;
        },
        reload_abi.CommandKind.reserve_player => {
            const reservation = try command.reservePlayer();
            if (reservation.connection.value() != handle.value())
                return error.UnexpectedPlayerReservation;
            reserved = true;
        },
        reload_abi.CommandKind.log => _ = try command.log(),
        else => return error.UnexpectedTickCommand,
    };
    if (!selected or !reserved) return error.ReloadableLoginDidNotStart;
    try verifyEncryptionRequest(server, client);

    event_bytes = 0;
    if (!events.disconnected(handle, .peer_closed)) return error.TestEventBufferExhausted;
    exchange.events = .{ .ptr = &event_storage, .len = event_bytes };
    exchange.resetCommands();
    try tick(manager, server, &invocation);
}

fn verifyEncryptionRequest(server: *const Server, client: anytype) !void {
    if (client.output_segment_count != 1) return error.MissingEncryptionRequest;
    const segment = client.constOutputSegment(0);
    const queued = server.network.output.buffers[segment.buffer_index][segment.offset..segment.len];
    const framed = (try wire.nextPacket(queued)) orelse
        return error.MissingEncryptionRequest;
    switch (try protocol.login.toClient.read(framed.payload).name()) {
        .encryption_begin => {},
        else => return error.UnexpectedLoginOutput,
    }
}
