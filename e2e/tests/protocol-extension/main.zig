const std = @import("std");
const reload_execve = @import("reload_execve");
const sessions = @import("sessions");
const lightning_rod = @import("lightning_rod");
const selected_protocol = @import("protocols");
const profiles = @import("profiles");
const networking = @import("network_stdio");
const vanilla = @import("vanilla");
const persistence = @import("storage_local");
const reload = @import("reload");
const ExtraNegotiation = @import("extra_negotiation.zig").ExtraNegotiation;

pub export const lightning_rod_resume_manifest linksection(reload_execve.section_name) = reload_execve.executableManifest(selected_protocol.Endpoint);

const ReloadProbe = struct {
    pub const id = "example:reload_probe";
    pub const Configuration = struct {};
    pub const Dependencies = struct { command_dispatch: *vanilla.CommandDispatch, reload_request: *reload.Request };
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ReloadProbe {
        const self = try allocator.create(ReloadProbe);
        self.* = .{ .deps = deps };
        try deps.command_dispatch.observeCommand(self, onCommand);
        return self;
    }

    fn onCommand(self: *ReloadProbe, _: sessions.Handle, text: []const u8) !void {
        if (std.mem.eql(u8, text, "protocol_reload")) try self.deps.reload_request.stage("protocol-extension");
    }
};

const WorldProvider = struct {
    pub const id = vanilla.VanillaWorlds.id;
    pub const Configuration = struct {};
    pub const Dependencies = vanilla.VanillaWorlds.Dependencies;
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
    const address = init.environ_map.get("LIGHTNING_ROD_E2E_ADDRESS") orelse "127.0.0.1:25565";
    const port = try std.fmt.parseInt(u16, address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..], 10);
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(WorldProvider, WorldProvider.Configuration{}),
            lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .maximum = 2, .render_distance = 4 }),
        }),
        lightning_rod.plugin.configured(ReloadProbe, ReloadProbe.Configuration{}),
    });
    var selected = try selected_protocol.Protocols.init(init.gpa);
    defer selected.deinit(init.gpa);
    const ConfigurationPlugin = vanilla.SessionConfiguration(selected_protocol.Protocols);
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(selected_protocol.Handshake, selected_protocol.Handshake.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginStart, vanilla.LoginStart.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Disconnect, vanilla.Disconnect.Configuration{}),
        lightning_rod.plugin.configured(vanilla.OfflineAuthentication, vanilla.OfflineAuthentication.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginCompression, vanilla.LoginCompression.Configuration{}),
        lightning_rod.plugin.configured(vanilla.LoginSuccess, vanilla.LoginSuccess.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Keepalive, vanilla.Keepalive.Configuration{}),
        lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{}),
        lightning_rod.plugin.configured(ConfigurationPlugin, ConfigurationPlugin.Configuration{ .protocols = &selected }),
        lightning_rod.plugin.configured(ExtraNegotiation, ExtraNegotiation.Configuration{}),
        lightning_rod.plugin.configured(vanilla.ConfigurationFinish, vanilla.ConfigurationFinish.Configuration{}),
    });
    var store = try persistence.Store.init(init.gpa, init.io, .{ .path = "custom-store", .max_value_bytes = 64 * 1024 });
    defer store.deinit(init.io);
    const router = profiles.SingleSimulation{};
    const Server = profiles.Server(@TypeOf(plugins), selected_protocol.Endpoint, networking.Transport(.{
        .connections = 32,
        .operations = 256,
        .events = 320,
    }), persistence.Store, reload_execve, @TypeOf(session_plugins), @TypeOf(router));
    try Server.run(init, .{
        .plugins = plugins,
        .session_plugins = session_plugins,
        .reload_manifest = &lightning_rod_resume_manifest,
        .router = router,
        .max_players = 2,
        .protocols = &selected,
        .persistence = store.interface(),
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = port } },
        .reload = .{ .executable = "/proc/self/exe" },
    });
}
