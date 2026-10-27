const e2e_control = @import("e2e_control");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const selected_protocol = @import("protocols");
const profile = @import("e2e_profile");
const sessions = @import("sessions");
const vanilla = @import("vanilla");
const persistence = @import("storage");
const ExtraNegotiation = @import("extra_negotiation.zig").ExtraNegotiation;

const WorldProvider = struct {
    pub const id = vanilla.VanillaWorlds.id;
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        registry_identity: *vanilla.RegistryIdentity,
        worlds: *vanilla.Worlds,
    };
    pub const Provides = .{*vanilla.VanillaWorlds};

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

    pub fn provide(self: *WorldProvider, comptime Contract: type) Contract {
        return &self.worlds;
    }
};

pub fn main(init: std.process.Init) !void {
    const maximum_players = 2;
    const startup = profile.Startup.capture(init.io);
    const metrics_output: lightning_rod.metrics.Exporter.Configuration = .{
        .directory = init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY") orelse return error.MissingMetricsDirectory,
        .stop_file = "metrics.stop",
    };
    var memory = lightning_rod.Memory.init(std.heap.page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse return error.MissingServerAddress;
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    const gameplay_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(WorldProvider, WorldProvider.Configuration{}),
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = maximum_players, .render_distance = 2 }),
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
    try profile.Server(@TypeOf(gameplay_plugins), selected_protocol.Endpoint, @TypeOf(session_plugins), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = gameplay_plugins,
        .network = .{
            .plugins = session_plugins,
            .protocols = &selected,
            .router = .{},
            .endpoints = &.{.{ .id = 0, .connections = maximum_players }},
            .max_players = maximum_players,
            .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        },
        .metrics_export = metrics_output,
        .simulation = .{ .temporary_bytes = 256 * 1024, .autosave = .{ .ticks = null } },
        .startup = startup,
        .persistence = &store,
        .reload = .{ .executable = "/proc/self/exe" },
    }, .{});
}
