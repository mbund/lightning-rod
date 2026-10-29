const control = @import("e2e_control");
const java = @import("minecraft_java");
const profile = @import("profile.zig");
const protocol_set = @import("protocols");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const host = @import("host");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const execution = @import("execution");
const wire_1_21_5 = @import("wire_1_21_5");

const RoutePlayers = struct {
    pub const id = "e2e:route_players";
    pub const Configuration = struct {};
    pub const SessionLoginState = struct { seen: bool = false };
    pub const SessionConfigurationState = struct { sent: bool = false, rounds: u32 = 0 };
    pub const SessionState = struct {
        login: SessionLoginState = .{},
        configuration: SessionConfigurationState = .{},
    };
    pub const Dependencies = struct { phases: *sessions.Phases };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*RoutePlayers {
        const self = try allocator.create(RoutePlayers);
        self.* = .{};
        try deps.phases.onLogin(self, onLogin);
        try deps.phases.onConfiguration(self, onConfiguration);
        try deps.phases.onClosed(self, onClosed);
        return self;
    }

    fn onLogin(_: *RoutePlayers, scope: sessions.PhaseScope, state: *SessionLoginState, event: sessions.PhaseEvent, _: []u8) !sessions.LoginStep {
        if (event != .begin) return error.UnexpectedLoginEvent;
        state.seen = true;
        const handle = scope.profile.connection;
        std.log.info("event=session_login_plugin protocol={d} connection={d}:{d}", .{ scope.profile.protocol, handle.index, handle.generation });
        return .done;
    }

    fn onConfiguration(_: *RoutePlayers, scope: sessions.PhaseScope, state: *SessionConfigurationState, event: sessions.PhaseEvent, output: []u8) !sessions.ConfigurationStep {
        if (event == .begin) {
            state.rounds += 1;
            const handle = scope.profile.connection;
            const payload = try sessions.packet_api.encodeFor(protocol_set.implementations, writeIsland, scope.profile.protocol, output, .{});
            state.sent = true;
            std.log.info("event=session_configuration_plugin protocol={d} connection={d}:{d} destination={?d} round={d}", .{ scope.profile.protocol, handle.index, handle.generation, scope.destination, state.rounds });
            return .{ .send = payload };
        }
        if (event == .poll and state.sent) return .done;
        return error.UnexpectedConfigurationEvent;
    }

    fn writeIsland(packet: wire_1_21_5.configuration.toClient.packet_custom_payload.Writer) ![]u8 {
        return (try (try packet.channel("lightning_rod:e2e")).data("island")).finish();
    }

    fn onClosed(_: *RoutePlayers, handle: sessions.Handle, state: *SessionState) void {
        std.log.info("event=session_plugin_closed connection={d}:{d} login_seen={} configuration_sent={}", .{ handle.index, handle.generation, state.login.seen, state.configuration.sent });
    }
};

const IslandRouter = struct {
    pub const Destination = enum(u32) { alice, bob, _ };
    routes: []const InitialRoute,

    pub fn route(self: *IslandRouter, player: sessions.Profile) sessions.Route(Destination) {
        for (self.routes) |route_to| if (std.mem.eql(u8, player.name, route_to.player)) return .{ .destination = @enumFromInt(route_to.destination) };
        return .reject;
    }
};

pub const InitialRoute = struct { player: []const u8, destination: u32 };

pub const Configuration = struct {
    plaintext: bool = false,
    render_distance: i32 = 2,
    autosave: lightning_rod.Autosave = profile.autosave_disabled,
    connections: usize = 1,
    routes: []const InitialRoute = &.{ .{ .player = "alice", .destination = 0 }, .{ .player = "bob", .destination = 1 } },
};

pub fn run(init: std.process.Init, plugins: anytype, endpoints: []*sessions.Service, session_plugins: anytype, config: Configuration) !void {
    var memory = lightning_rod.Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    const args = try profile.arguments(init);
    const metrics_export = profile.metricsExport(init) orelse return error.MissingMetricsDirectory;
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    var key: ?java.RsaPrivateKey = if (config.plaintext) null else try java.RsaPrivateKey.read(init.io, init.environ_map.get("LIGHTNING_ROD_E2E_KEY") orelse return error.MissingEncryptionKey);
    defer if (key) |*value| value.deinit();
    std.debug.assert(plugins.len == endpoints.len);
    std.debug.assert(plugins.len == 2 or plugins.len == 3);
    const limits = .{
        lightning_rod.plugin.configured(vanilla.Chunks, vanilla.Chunks.Configuration{ .cache_sections = 48, .demand_sections = 24, .cache_tiles = 6 }),
        lightning_rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = 8, .queued_sections = 8 }),
        lightning_rod.plugin.configured(vanilla.Entities, vanilla.Entities.Configuration{ .cache_records = 16 }),
        lightning_rod.plugin.configured(vanilla.ItemEntities, vanilla.ItemEntities.Configuration{ .cache_records = 16, .maximum = 64 }),
        lightning_rod.plugin.configured(vanilla.ItemReplication, vanilla.ItemReplication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Inventories, vanilla.Inventories.Configuration{ .cache_items = 2 }),
        lightning_rod.plugin.configured(vanilla.Chat, vanilla.Chat.Configuration{ .pending_messages = 8 }),
    };
    const selected = lightning_rod.plugin.replace(lightning_rod.plugin.insertAfter(plugins[0], vanilla.Reload, lightning_rod.plugin.configured(control.Control, .{})), limits);
    const routing = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, .{}),
        lightning_rod.plugin.insertAfter(lightning_rod.plugin.replace(vanilla.session_plugins(&protocols), .{
            lightning_rod.plugin.configured(vanilla.LoginEncryption, .{ .key = if (key) |*value| value else null }),
            lightning_rod.plugin.configured(vanilla.Status, .{ .description = "E2E islands" }),
        }), vanilla.SessionConfiguration(protocol_set.Default), lightning_rod.plugin.configured(RoutePlayers, .{})),
        session_plugins,
    });
    const Network = if (execution.single_threaded)
        sessions.Embedded(protocol_set.Endpoint, @TypeOf(routing), IslandRouter)
    else
        sessions.Threaded(protocol_set.Endpoint, @TypeOf(routing), IslandRouter);
    var endpoint_configurations: [plugins.len]Network.EndpointConfiguration = undefined;
    for (&endpoint_configurations, 0..) |*endpoint, index| endpoint.* = .{ .id = @enumFromInt(index), .connections = config.connections, .page_bytes = 128 * 1024, .output = &endpoints[index] };
    var network_registry = try lightning_rod.metrics.Registry.init(allocator, init.io, .{});
    defer network_registry.deinit();
    const network = try Network.init(allocator, init.io, .{
        .plugins = routing,
        .protocols = &protocols,
        .router = .{ .routes = config.routes },
        .max_players = 2,
        .inherited_listener = try host.inheritedListener(init),
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = args.port } },
        .endpoints = &endpoint_configurations,
    }, .{ .memory = &memory, .metrics = &network_registry });
    defer network.deinit();
    var network_exporter = try lightning_rod.metrics.Exporter.init(allocator, init.io, &network_registry, metrics_export, plugins.len, &.{});
    defer network_exporter.deinit(allocator, init.io, &network_registry) catch {};
    const Simulation = lightning_rod.Simulation(@TypeOf(selected));
    const paths = [_][]const u8{ "lightning-rod-data/alice", "lightning-rod-data/bob", "lightning-rod-data/destination" };
    var stores: [plugins.len]lightning_rod.storage.Store = undefined;
    var worlds: [plugins.len]*Simulation = undefined;
    var registries: [plugins.len]lightning_rod.metrics.Registry = undefined;
    var exporters: [plugins.len]lightning_rod.metrics.Exporter = undefined;
    var terrain: [plugins.len]vanilla.Terrain = undefined;
    var background: [plugins.len]vanilla.ThreadedTerrain = undefined;
    var generation: [plugins.len]*vanilla.Generation = undefined;
    var initialized: usize = 0;
    defer {
        for (worlds[0..initialized], stores[0..initialized], registries[0..initialized], exporters[0..initialized], generation[0..initialized]) |world, *store, *registry, *exporter, producer| {
            exporter.deinit(allocator, init.io, &world.metrics) catch {};
            world.close(host.timing.shutdownDeadline(init.io)) catch |err| std.debug.panic("world shutdown: {t}", .{err});
            producer.deinit();
            world.deinit(allocator);
            store.deinit();
            registry.deinit();
        }
    }
    inline for (plugins, 0..) |selection, index| {
        const players_index = comptime lightning_rod.plugin.indexOfId(@TypeOf(selection), vanilla.Players.id).?;
        var players = selection[players_index].configuration;
        players.maximum = config.connections;
        players.render_distance = config.render_distance;
        const bounded = lightning_rod.plugin.replace(lightning_rod.plugin.insertAfter(selection, vanilla.Reload, lightning_rod.plugin.configured(control.Control, .{})), limits);
        const island = lightning_rod.plugin.replace(bounded, .{
            lightning_rod.plugin.configured(sessions.World, .{ .endpoint = endpoints[index] }),
            lightning_rod.plugin.configured(vanilla.Players, players),
        });
        registries[index] = try .init(allocator, init.io, .{});
        errdefer if (initialized <= index) registries[index].deinit();
        stores[index] = try .init(allocator, init.io, .{ .path = paths[index], .metrics = &registries[index] });
        errdefer if (initialized <= index) stores[index].deinit();
        worlds[index] = try Simulation.init(allocator, init.io, &stores[index], .{ .temporary_bytes = 256 * 1024, .metrics = .{ .capacity = 512, .parent = &registries[index] }, .autosave = config.autosave });
        const world = worlds[index];
        errdefer if (initialized <= index) {
            world.close(host.timing.shutdownDeadline(init.io)) catch {};
            world.deinit(allocator);
        };
        try world.initialize(island, .{ .memory = &memory, .metrics = &world.metrics });
        exporters[index] = try .init(allocator, init.io, &world.metrics, metrics_export, index, &.{ "server.tick", "server.work" });
        errdefer if (initialized <= index) exporters[index].deinit(allocator, init.io, &world.metrics) catch {};
        generation[index] = try vanilla.Generation.init(allocator, init.io, world.get(vanilla.Chunks).generation, if (execution.single_threaded) 0 else 1);
        terrain[index] = .{ .chunks = world.get(vanilla.Chunks), .streaming = world.get(vanilla.Streaming), .blocks = world.get(vanilla.BlockSynchronization), .io = init.io };
        background[index] = .{ .terrain = terrain[index], .io = init.io };
        initialized += 1;
    }
    var started: usize = 0;
    defer for (0..started) |index| {
        if (comptime execution.single_threaded) terrain[index].stop() else background[index].stop();
        generation[index].stop();
    };
    for (0..initialized) |index| {
        try generation[index].start();
        errdefer generation[index].stop();
        if (comptime execution.single_threaded) terrain[index].start() else try background[index].start();
        started += 1;
    }
    try network.start();
    defer network.stop();
    var shutdown: host.Shutdown = .{ .io = init.io };
    var signals: host.Signals = .{ .shutdown = &shutdown };
    try signals.install();
    defer signals.restore();
    memory.seal();
    std.log.info("event=server_ready simulations={d}", .{worlds.len});
    var deadline = std.Io.Clock.now(.awake, init.io).nanoseconds;
    while (!shutdown.requested()) {
        if (comptime execution.single_threaded) try network.poll() else try network.check();
        for (worlds, 0..) |world, index| {
            if (comptime execution.single_threaded) try terrain[index].poll() else try background[index].check();
            const tick = world.server_tick.start();
            try world.tick();
            tick.end();
            try world.poll();
            _ = try stores[index].pollMaintenance(.{ .index_entries = 8, .pages = 8 });
            try exporters[index].poll(init.io);
        }
        try network_exporter.poll(init.io);
        deadline = host.timing.nextTick(deadline, std.Io.Clock.now(.awake, init.io).nanoseconds);
        if (comptime execution.single_threaded) {
            while (std.Io.Clock.now(.awake, init.io).nanoseconds < deadline) {
                var progressed = false;
                for (&terrain) |*item| {
                    if (!item.chunks.ready().isSet()) continue;
                    item.chunks.ready().reset();
                    try item.poll();
                    progressed = true;
                }
                try network.poll();
                if (!progressed) break;
            }
        }
        try std.Io.Timeout.sleep(.{ .deadline = .{ .clock = .awake, .raw = .{ .nanoseconds = deadline } } }, init.io);
    }
}
