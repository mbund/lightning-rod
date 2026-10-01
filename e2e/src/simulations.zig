const protocol_set = @import("protocols");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const sessions = @import("sessions");
const wire_1_21_5 = @import("wire_1_21_5");
const Fixture = @import("fixture.zig").Plugin;
const command_probe = @import("../tests/commands/server.zig");
const teleport_probe = @import("../tests/teleport/server.zig");

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

pub fn run(init: std.process.Init, plugins: anytype, protocols: *protocol_set.Default, encryption: ?vanilla.LoginEncryption.Key, transfers: bool, port: u16) !void {
    const selected = lightning_rod.plugin.replace(lightning_rod.plugin.remove(lightning_rod.plugin.remove(plugins, command_probe.Probe), teleport_probe.Probe), .{
        lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 1 }),
        lightning_rod.plugin.configured(vanilla.Chunks, vanilla.Chunks.Configuration{ .cache_sections = 24 }),
        lightning_rod.plugin.configured(vanilla.BlockSynchronization, vanilla.BlockSynchronization.Configuration{ .delta_sections = 8 }),
        lightning_rod.plugin.configured(vanilla.Entities, vanilla.Entities.Configuration{ .cache_records = 16 }),
        lightning_rod.plugin.configured(vanilla.ItemEntities, vanilla.ItemEntities.Configuration{ .cache_records = 16 }),
        lightning_rod.plugin.configured(vanilla.ItemReplication, vanilla.ItemReplication.Configuration{ .cache_records = 16 }),
        lightning_rod.plugin.configured(vanilla.Inventories, vanilla.Inventories.Configuration{ .cache_slots = 47, .cache_items = 1 }),
        lightning_rod.plugin.configured(vanilla.Chat, vanilla.Chat.Configuration{ .pending_messages = 8 }),
    });
    const ConfigurationPlugin = vanilla.SessionConfiguration(protocol_set.Default);
    const routing = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginStart, vanilla.LoginStart.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{ .key = encryption }),
        lightning_rod.plugin.configured(vanilla.Disconnect, vanilla.Disconnect.Configuration{}),
        lightning_rod.plugin.configured(vanilla.OfflineAuthentication, vanilla.OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginCompression, vanilla.LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginSuccess, vanilla.LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Keepalive, vanilla.Keepalive.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{ .description = "E2E islands" }),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = protocols }),
        lightning_rod.plugin.configured(vanilla.ConfigurationFinish, vanilla.ConfigurationFinish.Configuration{}),
        lightning_rod.plugin.configured(RoutePlayers, .{}),
    });
    const router = IslandRouter{};
    const Server = linux.Server(@TypeOf(selected), protocol_set.Endpoint, @TypeOf(routing), @TypeOf(router));
    var endpoints: [3]*sessions.Service = undefined;
    const alice = lightning_rod.plugin.replace(selected, .{lightning_rod.plugin.configured(Fixture, Fixture.Configuration{
        .kind = .transfer,
        .inventory = true,
        .destination = if (transfers) &endpoints[2] else null,
        .full_destination = if (transfers) &endpoints[1] else null,
    })});
    const destination = lightning_rod.plugin.replace(selected, .{lightning_rod.plugin.configured(Fixture, Fixture.Configuration{
        .kind = .transfer,
        .destination = &endpoints[0],
    })});
    const instances = [_]Server.Instance{
        .{
            .plugins = alice,
            .endpoint = &endpoints[0],
            .storage_path = "lightning-rod-data/alice",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 768 * 1024, .temporary_bytes = 16 * 1024 },
        },
        .{
            .plugins = selected,
            .endpoint = &endpoints[1],
            .storage_path = "lightning-rod-data/bob",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 768 * 1024, .temporary_bytes = 16 * 1024 },
        },
        .{
            .plugins = destination,
            .endpoint = &endpoints[2],
            .storage_path = "lightning-rod-data/destination",
            .max_players = 1,
            .packet_bytes = 128 * 1024,
            .memory = .{ .memory_bytes = 768 * 1024, .temporary_bytes = 16 * 1024 },
        },
    };
    return Server.runMany(init, .{
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .instances = instances[0..if (transfers) @as(usize, 3) else 2],
        .protocols = protocols,
        .session_plugins = routing,
        .router = router,

        .max_players = 2,
    });
}
