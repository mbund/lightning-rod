const std = @import("std");
const java = @import("minecraft_java");
const protocol_set = @import("protocols");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const sessions = @import("sessions");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const Chunks = @import("chunks").Chunks;
const LoginEncryption = @import("connection").session_encryption.LoginEncryption;
const Operators = @import("commands").operators.Operators;
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
    var codec_workers: usize = 4;
    var output_burst_slots: usize = 8;
    var input_burst_slots: usize = 2;
    var storage_batch_groups: usize = 8;
    var encryption_key_path: ?[]const u8 = null;
    var metrics_export: ?lightning_rod.metrics.Exporter.Configuration = null;
    var storage_path: []const u8 = "lightning-rod-data/world";
    var hull = true;
    var port: u16 = if (init.environ_map.get("LIGHTNING_ROD_PORT")) |value| try std.fmt.parseInt(u16, value, 10) else 25565;

    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "--no-compression")) {
            compression = null;
        } else if (std.mem.startsWith(u8, argument, "--max-players=")) {
            max_players = try std.fmt.parseInt(usize, argument["--max-players=".len..], 10);
            if (max_players == 0) return error.InvalidPlayerCapacity;
        } else if (std.mem.startsWith(u8, argument, "--codec-workers=")) {
            codec_workers = try std.fmt.parseInt(usize, argument["--codec-workers=".len..], 10);
            if (codec_workers == 0) return error.InvalidCodecCapacity;
        } else if (std.mem.startsWith(u8, argument, "--output-burst-slots=")) {
            output_burst_slots = try std.fmt.parseInt(usize, argument["--output-burst-slots=".len..], 10);
            if (output_burst_slots == 0 or output_burst_slots > 64) return error.InvalidBurstCapacity;
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
        } else if (std.mem.eql(u8, argument, "--no-hull")) {
            hull = false;
        } else if (std.mem.eql(u8, argument, "--startup-report")) {
            startup.report = .stdout();
        } else return error.UnknownArgument;
    }

    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:CMakeLists_txt", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    const operators = [_]u128{std.mem.readInt(u128, &digest, .big)};

    var chunk_configuration = Chunks.Configuration.forPlayers(max_players);
    chunk_configuration.storage_batch_groups = storage_batch_groups;
    const gameplay_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(Streaming, .{ .prefetch = 3, .hull = hull }),
            lightning_rod.plugin.configured(Players, Players.Configuration{ .maximum = max_players }),
            lightning_rod.plugin.configured(Chunks, chunk_configuration),
            lightning_rod.plugin.configured(Operators, Operators.Configuration{
                .operators = &operators,
            }),
        }),
        lightning_rod.plugin.configured(tps.Tps, .{}),
        lightning_rod.plugin.configured(RegionDebug, .{}),
    });
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    var key: ?java.RsaPrivateKey = if (encryption_key_path) |path| try java.RsaPrivateKey.read(init.io, path) else null;
    defer if (key) |*private_key| private_key.deinit();
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.replace(connection_plugins(&protocols), .{
            lightning_rod.plugin.configured(LoginEncryption, .{ .key = if (key) |*value| value else null }),
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
            .codec_workers = codec_workers,
            .input_burst_slots = input_burst_slots,
            .output_burst_slots = output_burst_slots,
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
