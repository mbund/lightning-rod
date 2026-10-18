//! Common process bootstrap. Test selection and plugin composition belong to each test directory.
const control = @import("e2e_control");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const protocols = @import("protocols");
const profile = @import("lightning_rod_linux");
const vanilla = @import("vanilla");
const java = @import("minecraft_java");
const metrics = lightning_rod.metrics;

pub const autosave_disabled: lightning_rod.Autosave = .{ .ticks = null };

pub const Configuration = struct {
    autosave: lightning_rod.Autosave = autosave_disabled,
    plaintext: bool = false,
    compression_threshold: ?usize = 256,
    reload_executable: ?[]const u8 = null,
};

pub const Arguments = struct { fixture: []const u8 = "", port: u16 = 25565 };

pub fn plugins() @TypeOf(vanilla.plugins()) {
    return lightning_rod.plugin.replace(vanilla.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, .{ .render_distance = 2 }),
    });
}

pub fn arguments(init: std.process.Init) !Arguments {
    var result: Arguments = .{};
    if (init.environ_map.get("LIGHTNING_ROD_PORT")) |port| result.port = try std.fmt.parseInt(u16, port, 10);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--fixture=")) result.fixture = arg[10..] else if (std.mem.startsWith(u8, arg, "--port=")) result.port = try std.fmt.parseInt(u16, arg[7..], 10) else return error.InvalidArgument;
    }
    return result;
}

pub fn metricsExport(init: std.process.Init) ?lightning_rod.metrics.Exporter.Configuration {
    const directory = init.environ_map.get("LIGHTNING_ROD_METRICS_DIRECTORY") orelse return null;
    return .{ .directory = directory, .stop_file = "metrics.stop" };
}

pub fn aliceOperator() [1]u128 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("OfflinePlayer:alice", &digest, .{});
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    return .{std.mem.readInt(u128, &digest, .big)};
}

pub fn run(init: std.process.Init, selections: anytype, config: Configuration) !void {
    const startup = profile.Startup.capture(init.io);
    const allocator = init.gpa;
    const started = std.Io.Clock.now(.awake, init.io);
    const cpu_started = std.Io.Clock.now(.cpu_thread, init.io);
    var registry = try metrics.Registry.init(allocator, init.io, .{ .capacity = 8 });
    defer registry.deinit();
    const total = try registry.timer(.{ .name = "bootstrap.total", .description = "Prepare protocol selection encryption and server configuration" });
    const cpu = try registry.timer(.{ .name = "bootstrap.cpu", .description = "Process bootstrap on the owning thread", .clock = .thread_cpu });
    const arguments_timer = try registry.timer(.{ .name = "bootstrap.arguments", .description = "Parse fixture command line arguments" });
    const protocols_timer = try registry.timer(.{ .name = "bootstrap.protocols", .description = "Initialize protocol tables and canonical registry translations" });
    const encryption_timer = try registry.timer(.{ .name = "bootstrap.encryption", .description = "Read and initialize the RSA private key" });
    const play_plugins = lightning_rod.plugin.insertAfter(selections, vanilla.Reload, lightning_rod.plugin.configured(control.Control, .{}));
    const players_index = comptime lightning_rod.plugin.indexOfId(@TypeOf(selections), vanilla.Players.id).?;
    const arguments_started = arguments_timer.start();
    const args = try arguments(init);
    arguments_started.end();
    const protocols_started = protocols_timer.start();
    var selected = try protocols.Default.init(allocator);
    defer selected.deinit(allocator);
    protocols_started.end();
    const encryption_started = encryption_timer.start();
    var key: ?java.RsaPrivateKey = if (config.plaintext) null else try java.RsaPrivateKey.read(init.io, init.environ_map.get("LIGHTNING_ROD_E2E_KEY") orelse return error.MissingEncryptionKey);
    defer if (key) |*value| value.deinit();
    encryption_started.end();
    const session_plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocols.Handshake, protocols.Handshake.Configuration{}),
        lightning_rod.plugin.replace(vanilla.session_plugins(&selected), .{
            lightning_rod.plugin.configured(vanilla.LoginEncryption, vanilla.LoginEncryption.Configuration{ .key = if (key) |*value| value else null }),
            lightning_rod.plugin.configured(vanilla.Status, vanilla.Status.Configuration{ .description = "E2E Vanilla Status" }),
        }),
    });
    const router = profile.SingleSimulation{};
    total.observe(@intCast(std.Io.Clock.now(.awake, init.io).nanoseconds - started.nanoseconds));
    cpu.observe(@intCast(std.Io.Clock.now(.cpu_thread, init.io).nanoseconds - cpu_started.nanoseconds));
    try metrics.Exporter.writeSnapshotFile(allocator, init.io, &registry, metricsExport(init), "bootstrap", 0);
    try profile.Server(@TypeOf(play_plugins), protocols.Endpoint, @TypeOf(session_plugins), @TypeOf(router)).run(allocator, init, .{
        .plugins = play_plugins,
        .startup = startup,
        .simulation = .{ .memory_bytes = 32 * 1024 * 1024, .temporary_bytes = 256 * 1024, .autosave = config.autosave },
        .session_plugins = session_plugins,
        .router = router,
        .protocols = &selected,
        .max_players = selections[players_index].configuration.maximum,
        .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = args.port } },
        .compression_threshold = config.compression_threshold,
        .metrics_export = metricsExport(init),
        .reload = .{ .executable = config.reload_executable },
    }, .{});
}
