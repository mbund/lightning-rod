const e2e_control = @import("e2e_control");
const std = @import("std");
const reload_execve = @import("reload_execve");
const lightning_rod = @import("lightning_rod");
const selected_protocol = @import("protocols");
const profiles = @import("profiles");
const networking = @import("network_stdio");
const vanilla = @import("vanilla");
const persistence = @import("storage");
const reload = @import("reload");
const ExtraNegotiation = @import("extra_negotiation.zig").ExtraNegotiation;

const WorldProvider = struct {
    pub const id = vanilla.VanillaWorlds.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        registry_identity: *vanilla.RegistryIdentity,
        worlds: *vanilla.Worlds,
    };
    pub const Services = .{*vanilla.VanillaWorlds};

    worlds: vanilla.VanillaWorlds,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*WorldProvider {
        const self = try allocator.create(WorldProvider);
        var dimension = vanilla.VanillaWorlds.dimensions.overworld;
        dimension.name = "example:bright";
        self.* = .{ .worlds = .{
            .overworld = try deps.worlds.create(.{ .name = "example:world", .dimension = dimension }),
            .nether = try deps.worlds.create(.{ .name = "minecraft:the_nether", .dimension = vanilla.VanillaWorlds.dimensions.nether }),
            .end = try deps.worlds.create(.{ .name = "minecraft:the_end", .dimension = vanilla.VanillaWorlds.dimensions.end }),
        } };
        return self;
    }

    pub fn service(self: *WorldProvider, comptime Contract: type) Contract {
        return &self.worlds;
    }
};

pub fn main(init: std.process.Init) !void {
    const startup = profiles.Startup.capture(init.io);
    const allocator = init.gpa;
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(WorldProvider, WorldProvider.Configuration{}),
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 2 }),
        }),
        lightning_rod.plugin.configured(e2e_control.Control, .{}),
    });
    var selected = try selected_protocol.Protocols.init(allocator);
    defer selected.deinit(allocator);
    const ConfigurationPlugin = vanilla.SessionConfiguration(selected_protocol.Protocols);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(selected_protocol.Handshake, selected_protocol.Handshake.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginStart, vanilla.LoginStart.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Disconnect, vanilla.Disconnect.Configuration{}),
        lightning_rod.plugin.configured(vanilla.OfflineAuthentication, vanilla.OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginCompression, vanilla.LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(ExtraNegotiation, ExtraNegotiation.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginSuccess, vanilla.LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Keepalive, vanilla.Keepalive.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{}),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = &selected }),
    });
    var store = try persistence.Store.init(allocator, init.io, .{ .path = "custom-store" });
    defer store.deinit();
    const router = profiles.SingleSimulation{};
    const Server = profiles.Server(@TypeOf(plugins), selected_protocol.Endpoint, networking.Transport(.{
        .connections = 32,
        .operations = 256,
        .events = 320,
    }), reload_execve, @TypeOf(session_plugins), @TypeOf(router));
    try Server.run(allocator, init, .{
        .metrics_export = if (init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY")) |directory| .{ .directory = directory, .stop_file = "metrics.stop" } else null,
        .plugins = plugins,
        .simulation = .{ .memory_bytes = 32 * 1024 * 1024, .temporary_bytes = 256 * 1024, .autosave = .{ .ticks = null } },
        .session_plugins = session_plugins,
        .startup = startup,
        .router = router,
        .max_players = 2,
        .protocols = &selected,
        .persistence = &store,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .reload = .{ .executable = "/proc/self/exe" },
    }, .{});
}
