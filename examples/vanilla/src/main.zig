const std = @import("std");
const java = @import("minecraft_java");
const protocol_set = @import("protocols");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const sessions = @import("sessions");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const Chunks = @import("chunks").Chunks;
const LoginEncryption = @import("connection").session_encryption.LoginEncryption;
const Authentication = @import("connection").authentication.Authentication;
const commands = @import("commands");
const Operators = commands.operators.Operators;
const Players = @import("players").players.Players;
const RegionDebug = @import("replication").region_debug.RegionDebug;
const Streaming = @import("terrain").streaming.Streaming;
const connection_plugins = @import("connection").plugins;
const tps = @import("tps");
const storm_stick = @import("storm_stick");

pub const std_options: std.Options = .{ .log_level = .debug };

pub fn main(init: std.process.Init) !void {
    var startup = profile.Startup.capture(init.io);
    var memory = lightning_rod.Memory.init(lightning_rod.system.huge_page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    var compression: ?usize = 256;
    var max_players: usize = 32;
    var output_bytes: usize = 64 * 1024;
    var input_burst_slots: usize = 2;
    var storage_batch_groups: usize = 8;
    var encryption_key_path: ?[]const u8 = null;
    var metrics_export: ?lightning_rod.metrics.Exporter.Configuration = null;
    var storage_path: []const u8 = "lightning-rod-data/world";
    var hull = true;
    // Players prove to Mojang who they are, as vanilla's online mode. Off by default: an existing
    // world's players are saved under the UUIDs offline mode gives their names.
    var online_mode = false;
    // One column past the view, the ring vanilla sends so every column in view has its neighbours.
    var prefetch: u2 = 1;
    var tps_bar = true;
    var render_distance: i32 = 32;
    var simulation_distance: i32 = 8;
    // server.properties entity-broadcast-range-percentage.
    var range_percentage: u32 = 100;
    var port: u16 = if (init.environ_map.get("LIGHTNING_ROD_PORT")) |value| try std.fmt.parseInt(u16, value, 10) else 25565;

    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--no-compression")) {
            compression = null;
        } else if (std.mem.startsWith(u8, argument, "--max-players=")) {
            max_players = try std.fmt.parseInt(usize, argument["--max-players=".len..], 10);
            if (max_players == 0) return error.InvalidPlayerCapacity;
        } else if (std.mem.startsWith(u8, argument, "--output-bytes=")) {
            output_bytes = try std.fmt.parseInt(usize, argument["--output-bytes=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--storage-batch-groups=")) {
            storage_batch_groups = try std.fmt.parseInt(usize, argument["--storage-batch-groups=".len..], 10);
            if (storage_batch_groups == 0 or storage_batch_groups > 192) return error.InvalidStorageBatchCapacity;
        } else if (std.mem.startsWith(u8, argument, "--input-burst-slots=")) {
            input_burst_slots = try std.fmt.parseInt(usize, argument["--input-burst-slots=".len..], 10);
            if (input_burst_slots == 0 or input_burst_slots > 64) return error.InvalidBurstCapacity;
        } else if (std.mem.startsWith(u8, argument, "--encryption-key=")) {
            const path = argument["--encryption-key=".len..];
            if (path.len == 0) return error.InvalidEncryptionKeyPath;
            encryption_key_path = path;
        } else if (std.mem.startsWith(u8, argument, "--metrics-directory=")) {
            const directory = argument["--metrics-directory=".len..];
            if (directory.len == 0) return error.InvalidMetricsDirectory;
            metrics_export = .{ .directory = directory };
        } else if (std.mem.startsWith(u8, argument, "--world=")) {
            storage_path = argument["--world=".len..];
            if (storage_path.len == 0) return error.InvalidWorldPath;
        } else if (std.mem.startsWith(u8, argument, "--port=")) {
            port = try std.fmt.parseInt(u16, argument["--port=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--view-distance=")) {
            render_distance = try std.fmt.parseInt(i32, argument["--view-distance=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--simulation-distance=")) {
            simulation_distance = try std.fmt.parseInt(i32, argument["--simulation-distance=".len..], 10);
        } else if (std.mem.startsWith(u8, argument, "--entity-broadcast-range-percentage=")) {
            range_percentage = try std.fmt.parseInt(u32, argument["--entity-broadcast-range-percentage=".len..], 10);
            if (range_percentage < 10 or range_percentage > 1000) return error.InvalidBroadcastRange;
        } else if (std.mem.startsWith(u8, argument, "--prefetch=")) {
            prefetch = try std.fmt.parseInt(u2, argument["--prefetch=".len..], 10);
        } else if (std.mem.eql(u8, argument, "--no-tps-bar")) {
            tps_bar = false;
        } else if (std.mem.eql(u8, argument, "--online-mode")) {
            online_mode = true;
        } else if (std.mem.eql(u8, argument, "--no-hull")) {
            hull = false;
        } else if (std.mem.eql(u8, argument, "--startup-report")) {
            startup.report = .stdout();
        } else return error.UnknownArgument;
    }

    var chunk_configuration = Chunks.Configuration.forPlayers(max_players);
    chunk_configuration.storage_batch_groups = storage_batch_groups;
    const gameplay_plugins = lightning_rod.plugin.compose(.{
        // Every player is an operator here, instead of those vanilla's plugin lists.
        lightning_rod.plugin.replace(lightning_rod.plugin.remove(vanilla.plugins(), Operators), .{
            lightning_rod.plugin.configured(Streaming, .{ .prefetch = prefetch, .hull = hull }),
            lightning_rod.plugin.configured(Players, Players.Configuration{ .maximum = max_players, .render_distance = render_distance, .simulation_distance = simulation_distance }),
            lightning_rod.plugin.configured(Chunks, chunk_configuration),
            lightning_rod.plugin.configured(vanilla.Tracking, vanilla.Tracking.Configuration{ .range_percentage = range_percentage }),
        }),
        lightning_rod.plugin.configured(AllOperators, .{}),
        lightning_rod.plugin.configured(tps.Tps, .{ .shown = tps_bar }),
        lightning_rod.plugin.configured(RegionDebug, .{}),
        lightning_rod.plugin.configured(vanilla.SleepDebug, .{}),
    });
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    // Online mode asks clients to prove who they are over an encrypted login.
    if (online_mode and encryption_key_path == null) return error.OnlineModeNeedsEncryptionKey;
    var key: ?java.RsaPrivateKey = if (encryption_key_path) |path| try java.RsaPrivateKey.read(init.io, path) else null;
    defer if (key) |*private_key| private_key.deinit();
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.replace(connection_plugins(&protocols), .{
            lightning_rod.plugin.configured(LoginEncryption, .{ .key = if (key) |*value| value else null, .authenticate = online_mode }),
            lightning_rod.plugin.configured(Authentication, .{ .online = online_mode }),
        }),
    });
    std.log.info("Starting Lightning Rod", .{});
    try profile.Server(@TypeOf(gameplay_plugins), protocol_set.Endpoint, @TypeOf(session_plugins), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = gameplay_plugins,
        .network = .{
            .plugins = session_plugins,
            .protocols = &protocols,
            .router = .{},
            .max_players = max_players,
            .input_burst_slots = input_burst_slots,
            .output_bytes = output_bytes,
            .decode_slots = input_burst_slots,
            .endpoints = &.{.{ .id = 0, .connections = max_players }},
            .compression_threshold = compression,
            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = port } },
        },
        .metrics_export = metrics_export,
        .startup = startup,
        .storage_path = storage_path,
    }, .{});
}

/// Lets every player use every command, so trying the example server needs no list of operators,
/// in offline or online mode alike. It takes the place of `minecraft:operators`.
const AllOperators = struct {
    pub const id = "example:all_operators";
    pub const Configuration = struct {};
    pub const Dependencies = struct { commands: *commands.Commands };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*AllOperators {
        const self = try allocator.create(AllOperators);
        self.* = .{};
        deps.commands.installPolicyIfUnset(commands.Policy.init(self, allows));
        return self;
    }

    fn allows(_: *const AllOperators, _: u128, _: *const commands.Permission) bool {
        return true;
    }
};
