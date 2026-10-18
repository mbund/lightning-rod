const control = @import("e2e_control");
const java = @import("minecraft_java");
const bootstrap = @import("server.zig");
const protocol_set = @import("protocols");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
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
    pub fn route(_: *IslandRouter, profile: sessions.Profile) sessions.Route {
        if (std.mem.eql(u8, profile.name, "alice")) return .{ .destination = 0 };
        if (std.mem.eql(u8, profile.name, "bob")) return .{ .destination = 1 };
        return .reject;
    }
};

pub const Configuration = struct {
    plaintext: bool = false,
    render_distance: i32 = 2,
    autosave: lightning_rod.Autosave = bootstrap.autosave_disabled,
};

pub fn run(init: std.process.Init, plugins: anytype, endpoints: []*sessions.Service, config: Configuration) !void {
    const allocator = init.gpa;
    const args = try bootstrap.arguments(init);
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    var key: ?java.RsaPrivateKey = if (config.plaintext) null else try java.RsaPrivateKey.read(init.io, init.environ_map.get("LIGHTNING_ROD_E2E_KEY") orelse return error.MissingEncryptionKey);
    defer if (key) |*value| value.deinit();
    std.debug.assert(plugins.len == endpoints.len);
    std.debug.assert(plugins.len == 2 or plugins.len == 3);
    const limits = .{
        lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 1, .render_distance = config.render_distance }),
        lightning_rod.plugin.configured(vanilla.Chunks, vanilla.Chunks.Configuration{ .cache_sections = 24, .cache_tiles = 6 }),
        lightning_rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = 8 }),
        lightning_rod.plugin.configured(vanilla.Entities, vanilla.Entities.Configuration{ .cache_records = 16 }),
        lightning_rod.plugin.configured(vanilla.ItemEntities, vanilla.ItemEntities.Configuration{ .cache_records = 16, .maximum = 64 }),
        lightning_rod.plugin.configured(vanilla.ItemReplication, vanilla.ItemReplication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Inventories, vanilla.Inventories.Configuration{ .cache_slots = 47, .cache_items = 1 }),
        lightning_rod.plugin.configured(vanilla.Chat, vanilla.Chat.Configuration{ .pending_messages = 8 }),
    };
    const selected = lightning_rod.plugin.replace(lightning_rod.plugin.insertAfter(plugins[0], vanilla.Reload, lightning_rod.plugin.configured(control.Control, .{})), limits);
    const routing = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, .{}),
        lightning_rod.plugin.insertAfter(lightning_rod.plugin.replace(vanilla.session_plugins(&protocols), .{
            lightning_rod.plugin.configured(vanilla.LoginEncryption, .{ .key = if (key) |*value| value else null }),
            lightning_rod.plugin.configured(vanilla.Status, .{ .description = "E2E islands" }),
        }), vanilla.SessionConfiguration(protocol_set.Default), lightning_rod.plugin.configured(RoutePlayers, .{})),
    });
    const router = IslandRouter{};
    const Server = linux.Server(@TypeOf(selected), protocol_set.Endpoint, @TypeOf(routing), @TypeOf(router));
    const paths = [_][]const u8{ "lightning-rod-data/alice", "lightning-rod-data/bob", "lightning-rod-data/destination" };
    var instances: [plugins.len]Server.Instance = undefined;
    inline for (plugins, 0..) |selection, index| {
        instances[index] = .{
            .plugins = lightning_rod.plugin.replace(lightning_rod.plugin.insertAfter(selection, vanilla.Reload, lightning_rod.plugin.configured(control.Control, .{})), limits),
            .endpoint = &endpoints[index],
            .storage_path = paths[index],
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .simulation = .{ .memory_bytes = 1024 * 1024, .temporary_bytes = 16 * 1024, .autosave = config.autosave },
        };
    }
    return Server.runMany(allocator, init, .{
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = args.port } },
        .metrics_export = bootstrap.metricsExport(init),
        .instances = &instances,
        .protocols = &protocols,
        .session_plugins = routing,
        .router = router,

        .max_players = 2,
    }, .{});
}
