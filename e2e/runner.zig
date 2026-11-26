const std = @import("std");
const builtin = @import("builtin");
const allMarkers = @import("src/artifacts.zig").allMarkers;
const entity_compare = @import("src/entity_compare.zig");
const process_cleanup = @import("src/process_cleanup.zig");
const manifest = @import("src/manifest.zig");
const selection = @import("src/selection.zig");
const protocol_catalog = @import("protocol_catalog");
const scheduling = @import("src/scheduling.zig");
const performance = @import("src/performance.zig");
const ReloadTest = @import("src/reload.zig").Test;
const UpgradeTest = @import("src/upgrade.zig").Test;
const ManagedChild = @import("src/child.zig").ManagedChild;
const Listener = @import("src/listener.zig").Listener;
const client_bundle = @import("src/client_bundle.zig");
const SessionServer = @import("src/session_server.zig").SessionServer;

const max_processes = manifest.maximum_peers + 2;
const max_clients = manifest.maximum_peers;
const scenario_timeout_s = 180;

/// One client release with the test's fixtures compiled against it.
const Client = struct {
    version: []const u8,
    bundle: []const u8,
    fixtures: []const u8,
};

const Arguments = struct {
    realtime: bool = false,
    server: []const u8,
    /// The test directory, which holds the server's data files and the default artifact root.
    directory: []const u8,
    test_manifest: manifest.Manifest,
    clients: []const Client,
    artifacts: ?[]const u8,
    scenario: manifest.Scenario,
    address: []const u8,
    client_version: []const u8,
    peer_versions: []const []const u8,
    upgrade_from: []const u8,
    /// Debug servers miss the tick budget, so their runs report it without failing.
    performance_budget: enum { enforce, report } = .enforce,
};

var process_groups: [max_processes]std.atomic.Value(std.posix.pid_t) = @splat(.init(0));
var interrupted = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.E2eRequiresLinux;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--upgrade-releases")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, try UpgradeTest.releases(init.arena.allocator()));
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "--test-client")) {
        const bundle = try client_bundle.Bundle.open(init, args[3], args[2]);
        const run_directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.arena.allocator());
        const command = try bundle.command(init, try std.fs.path.join(init.arena.allocator(), &.{ run_directory, ".zig-cache/client-api" }), &.{}, &.{}, .api_test);
        var child = try std.process.spawn(init.io, .{ .argv = command, .environ_map = init.environ_map });
        const result = try child.wait(init.io);
        if (result != .exited or result.exited != 0) return error.ClientApiTestFailed;
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--server-exec")) {
        try scheduling.enable();
        var watchdog: std.os.linux.rlimit = undefined;
        if (std.os.linux.errno(std.os.linux.getrlimit(.RTTIME, &watchdog)) != .SUCCESS) return error.SchedulerConfigurationFailed;
        std.log.info("event=e2e_server_scheduler policy=fifo priority={d} rttime_soft_us={d} rttime_hard_us={d}", .{ scheduling.priority, watchdog.cur, watchdog.max });
        return std.process.replace(init.io, .{ .argv = args[2..], .environ_map = init.environ_map });
    }
    try process_cleanup.enable();
    defer _ = process_cleanup.finish(init.io) catch {};
    installSignalHandlers();

    const arguments = try parse(init, args);
    if (arguments.realtime) scheduling.preflight() catch |err| {
        if (err == error.RealtimePermissionRequired)
            std.log.err("FIFO scheduling requires CAP_SYS_NICE or RLIMIT_RTPRIO >= 1. In your shell, run: sudo prlimit --pid $$ --rtprio=1:1 . Use -Drealtime=false for normal scheduling.", .{});
        return err;
    };
    try ensureExecutable(init.io, arguments.server);
    try run(init, arguments);
}

fn run(init: std.process.Init, arguments: Arguments) !void {
    if (interrupted.load(.acquire)) return error.Interrupted;

    const cwd = std.Io.Dir.cwd();
    const working_directory = try cwd.realPathFileAlloc(init.io, ".", init.gpa);
    defer init.gpa.free(working_directory);
    const server = try std.fs.path.resolve(init.gpa, &.{ working_directory, arguments.server });
    defer init.gpa.free(server);
    const artifact_root = arguments.artifacts orelse try std.fs.path.join(init.arena.allocator(), &.{ arguments.directory, "artifacts" });
    try cwd.createDirPath(init.io, artifact_root);
    const root = try cwd.realPathFileAlloc(init.io, artifact_root, init.gpa);
    defer init.gpa.free(root);
    const artifacts = try std.fmt.allocPrint(init.gpa, "{s}/{s}-{s}", .{ root, arguments.scenario.name, arguments.client_version });
    defer init.gpa.free(artifacts);
    const lock_path = try std.fmt.allocPrint(init.gpa, "{s}.lock", .{artifacts});
    defer init.gpa.free(lock_path);
    const lock = cwd.createFile(init.io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| {
        if (err == error.WouldBlock) return error.ScenarioAlreadyRunning;
        return err;
    };
    defer lock.close(init.io);
    // A run must start without result files, coordination markers, or world data
    // from the previous run of this scenario.
    try cwd.deleteTree(init.io, artifacts);
    try cwd.createDir(init.io, artifacts, .default_dir);
    std.log.info("event=e2e_started scenario={s} artifacts={s}", .{ arguments.scenario.name, artifacts });
    const world = try std.fs.path.join(init.gpa, &.{ artifacts, "server" });
    defer init.gpa.free(world);
    try cwd.createDir(init.io, world, .default_dir);
    const preparation_scenario = arguments.scenario.prepare;
    var preparation_performance_failed = false;
    if (preparation_scenario) |scenario| {
        const preparation = try std.fs.path.join(init.gpa, &.{ artifacts, "prepare" });
        defer init.gpa.free(preparation);
        try cwd.createDir(init.io, preparation, .default_dir);
        runScenario(init, arguments, arguments.test_manifest.find(scenario).?, server, preparation, world, &.{}) catch |err| {
            try writeSummary(init, preparation, scenario, false, @errorName(err));
            if (err == error.PerformanceBudgetExceeded) preparation_performance_failed = true else {
                try writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err));
                return err;
            }
        };
    }

    runScenario(init, arguments, arguments.scenario, server, artifacts, world, arguments.peer_versions) catch |err| {
        writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err)) catch {};
        std.log.err("event=e2e_failed reason={s} artifacts={s}", .{ @errorName(err), artifacts });
        return err;
    };
    proveEntities(init, artifacts, arguments.scenario.peers) catch |err| {
        writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err)) catch {};
        std.log.err("event=e2e_failed reason={s} artifacts={s}", .{ @errorName(err), artifacts });
        return err;
    };
    if (preparation_performance_failed) {
        try writeSummary(init, artifacts, arguments.scenario.name, false, "PreparationPerformanceBudgetExceeded");
        return error.PreparationPerformanceBudgetExceeded;
    }
    std.log.info("event=e2e_passed artifacts={s}", .{artifacts});
}

fn runScenario(init: std.process.Init, arguments: Arguments, test_case: manifest.Scenario, server_path: []const u8, artifacts: []const u8, world: []const u8, peer_versions: []const []const u8) !void {
    const requested_address = arguments.address;
    const primary_version = arguments.client_version;
    const realtime = arguments.realtime;
    const upgrade_from = arguments.upgrade_from;
    std.debug.assert(peer_versions.len == 0 or peer_versions.len == test_case.peers.len);
    var listener = try Listener.init(init.io, requested_address);
    defer listener.deinit(init.io);
    var address_bytes: [128]u8 = undefined;
    const address = try std.fmt.bufPrint(&address_bytes, "{f}", .{listener.server.?.socket.address});
    std.log.info("event=e2e_listener address={s}", .{address});
    const scenario = test_case.name;
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_DIRECTORY", arguments.directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_ADDRESS", address);
    try init.environ_map.put("LIGHTNING_ROD_METRICS_DIRECTORY", artifacts);
    const port = try std.fmt.allocPrint(init.gpa, "--port={s}", .{address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..]});
    defer init.gpa.free(port);
    try init.environ_map.put("LIGHTNING_ROD_PORT", port[7..]);
    // Online scenarios point the server and every client at a session server of their own.
    var session_server: SessionServer = undefined;
    var session_properties: [3][]const u8 = undefined;
    var client_properties: []const []const u8 = &.{};
    if (test_case.session_server) {
        try session_server.start(init.io);
        const host = session_server.host();
        try init.environ_map.put("LIGHTNING_ROD_E2E_SESSION_HOST", host);
        for (&session_properties, [_][]const u8{ "session", "services", "profiles" }) |*property, service|
            property.* = try std.fmt.allocPrint(init.arena.allocator(), "-Dminecraft.api.{s}.host={s}", .{ service, host });
        client_properties = &session_properties;
    }
    defer if (test_case.session_server) {
        session_server.stop();
        _ = init.environ_map.swapRemove("LIGHTNING_ROD_E2E_SESSION_HOST");
    };
    const fixture = test_case.fixture;
    const fixture_arg = if (fixture) |name| try std.fmt.allocPrint(init.gpa, "--fixture={s}", .{name}) else null;
    defer if (fixture_arg) |arg| init.gpa.free(arg);
    var upgrade: ?UpgradeTest = if (test_case.upgrade) try UpgradeTest.prepare(init, server_path, artifacts, world, upgrade_from, &process_groups[0]) else null;
    var argv: [5][]const u8 = undefined;
    var argc: usize = 0;

    argv[argc] = if (upgrade) |coordinator| coordinator.executable else server_path;
    argc += 1;
    if (upgrade) |coordinator| {
        @memcpy(argv[argc..][0..coordinator.arguments.len], &coordinator.arguments);
        argc += coordinator.arguments.len;
    }

    if (fixture_arg) |arg| {
        argv[argc] = arg;
        argv[argc + 1] = port;
        argc += 2;
    }

    var evidence_checked = false;
    defer if (!evidence_checked) {
        _ = performance.summarize(init, artifacts, if (test_case.crash_after) .intentional_crash else .complete) catch false;
    };
    var server_stopped = false;
    var launch: [7][]const u8 = undefined;
    if (realtime) {
        launch[0] = try std.process.executablePathAlloc(init.io, init.arena.allocator());
        launch[1] = "--server-exec";
        @memcpy(launch[2..][0..argc], argv[0..argc]);
    }
    var descriptor_bytes: [32]u8 = undefined;
    try init.environ_map.put("LIGHTNING_ROD_LISTENER_FD", try std.fmt.bufPrint(&descriptor_bytes, "{d}", .{listener.server.?.socket.handle}));
    defer _ = init.environ_map.swapRemove("LIGHTNING_ROD_LISTENER_FD");
    var server = try spawn(init, if (realtime) launch[0 .. argc + 2] else argv[0..argc], artifacts, world, "server.log", &listener);
    listener.deinit(init.io);
    _ = init.environ_map.swapRemove("LIGHTNING_ROD_LISTENER_FD");
    process_groups[0].store(server.group, .release);
    defer {
        if (!server_stopped) server.stop(init.io);
        process_groups[0].store(0, .release);
    }
    var xvfb = try spawnDisplay(init, artifacts);
    process_groups[1].store(xvfb.group, .release);
    defer {
        xvfb.stop(init.io);
        process_groups[1].store(0, .release);
    }
    const display = try waitForDisplay(init, artifacts);
    const peers = test_case.peers;
    var clients: [manifest.maximum_peers]ManagedChild = undefined;
    var count: usize = 0;
    defer for (clients[0..count], 0..) |*child, index| {
        child.stop(init.io);
        process_groups[index + 2].store(0, .release);
    };

    for (peers) |peer| {
        const connect_tick: usize = if (count + 1 == peers.len) test_case.last_peer_connect_tick else 40;
        const peer_version = if (peer_versions.len == 0) primary_version else peer_versions[count];
        clients[count] = try spawnClient(init, arguments, artifacts, scenario, peer, peers, connect_tick, address, peer_version, display, client_properties, test_case.session_server);
        process_groups[count + 2].store(clients[count].group, .release);
        count += 1;
        const startup_deadline = std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds + 120 * std.time.ns_per_s;
        while (!try allMarkers(init, artifacts, &.{peer}, ".ready")) {
            if (interrupted.load(.monotonic)) return error.Interrupted;
            if (std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds >= startup_deadline) return error.ClientStartupTimeout;
            try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
        }
    }

    const start_path = try std.fs.path.join(init.gpa, &.{ artifacts, "clients.start" });
    defer init.gpa.free(start_path);
    const pending_path = try std.fmt.allocPrint(init.gpa, "{s}.pending", .{start_path});
    defer init.gpa.free(pending_path);
    var start_bytes: [64]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = pending_path,
        .data = try std.fmt.bufPrint(&start_bytes, "{d}\n", .{std.Io.Clock.now(.awake, init.io).nanoseconds}),
    });
    try std.Io.Dir.cwd().rename(pending_path, .cwd(), start_path, init.io);

    try waitForResults(init, artifacts, peers, if (test_case.reload) .{ .world = world, .executable = server_path, .protocol_mismatch = test_case.protocol_mismatch, .selected = if (test_case.reload_once) ReloadTest.once else &ReloadTest.rounds } else null, if (upgrade) |*coordinator| coordinator else null, server.group);
    const clients_passed = try resultsPassed(init, artifacts, peers);
    if (test_case.crash_after) try performance.seal(init, artifacts);
    // Simulation flush and session draining each have their own shutdown deadline.
    // Allow both phases across multiple simulations, then assert the actual exit status.
    server.shutdown(init.io, test_case.crash_after, .fromSeconds(30)) catch |err| {
        std.log.err("event=e2e_server_shutdown_failed reason={s} termination={any}", .{ @errorName(err), server.termination });
        return err;
    };
    server_stopped = true;
    process_groups[0].store(0, .release);
    const server_passed = try performance.summarize(init, artifacts, if (test_case.crash_after) .intentional_crash else .complete);
    evidence_checked = true;
    if (!clients_passed) return error.EndToEndAssertionFailed;
    if (!server_passed) switch (arguments.performance_budget) {
        .enforce => return error.PerformanceBudgetExceeded,
        .report => std.log.warn("event=e2e_performance_reported scenario={s} reason=budget_not_enforced", .{scenario}),
    };
    try writeSummary(init, artifacts, scenario, true, "passed");
}

fn spawn(init: std.process.Init, argv: []const []const u8, artifacts: []const u8, working_directory: []const u8, name: []const u8, listener: ?*Listener) !ManagedChild {
    const path = try std.fs.path.join(init.gpa, &.{ artifacts, name });
    defer init.gpa.free(path);
    const log = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer log.close(init.io);
    const options: std.process.SpawnOptions = .{
        .argv = argv,
        .environ_map = init.environ_map,
        .cwd = .{ .path = working_directory },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    };
    const child = if (listener) |reserved| try reserved.spawn(init.io, options) else try std.process.spawn(init.io, options);
    return .{ .child = child, .group = child.id orelse return error.ProcessIdUnavailable };
}

fn spawnDisplay(init: std.process.Init, artifacts: []const u8) !ManagedChild {
    const number_path = try std.fs.path.join(init.arena.allocator(), &.{ artifacts, "display.number" });
    const log_path = try std.fs.path.join(init.arena.allocator(), &.{ artifacts, "display.log" });
    const number = try std.Io.Dir.cwd().createFile(init.io, number_path, .{});
    defer number.close(init.io);
    const log = try std.Io.Dir.cwd().createFile(init.io, log_path, .{});
    defer log.close(init.io);
    const child = try std.process.spawn(init.io, .{
        .argv = &.{ "Xvfb", "-displayfd", "1", "-screen", "0", "1280x720x24", "-nolisten", "tcp" },
        .environ_map = init.environ_map,
        .stdin = .ignore,
        .stdout = .{ .file = number },
        .stderr = .{ .file = log },
        .pgid = 0,
    });
    return .{ .child = child, .group = child.id orelse return error.ProcessIdUnavailable };
}

fn waitForDisplay(init: std.process.Init, artifacts: []const u8) ![]const u8 {
    const path = try std.fs.path.join(init.arena.allocator(), &.{ artifacts, "display.number" });
    const until = std.Io.Clock.now(.awake, init.io).nanoseconds + 10 * std.time.ns_per_s;
    while (std.Io.Clock.now(.awake, init.io).nanoseconds < until) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(32));
        defer init.gpa.free(bytes);
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |end| {
            const number = try std.fmt.parseInt(u16, bytes[0..end], 10);
            return std.fmt.allocPrint(init.arena.allocator(), ":{d}", .{number});
        }
        try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
    }
    return error.DisplayStartupTimeout;
}

fn spawnClient(init: std.process.Init, arguments: Arguments, artifacts: []const u8, scenario: []const u8, peer: []const u8, peers: []const []const u8, connect_tick: usize, address: []const u8, client_version: []const u8, display: []const u8, extra_properties: []const []const u8, online: bool) !ManagedChild {
    const allocator = init.gpa;
    const version = try std.fmt.allocPrint(allocator, "-Dmcc.version={s}", .{client_version});
    defer allocator.free(version);
    const address_arg = try std.fmt.allocPrint(allocator, "-Dmcc.server={s}", .{address});
    defer allocator.free(address_arg);
    const expected_peers = try std.mem.join(allocator, ",", peers);
    defer allocator.free(expected_peers);
    const events = try std.fmt.allocPrint(allocator, "-Dmcc.events={s}/{s}.events.jsonl", .{ artifacts, peer });
    defer allocator.free(events);
    const output = try std.fmt.allocPrint(allocator, "-Dmcc.artifacts={s}", .{artifacts});
    defer allocator.free(output);
    const peer_arg = try std.fmt.allocPrint(allocator, "-Dmcc.peer={s}", .{peer});
    defer allocator.free(peer_arg);
    const expected = try std.fmt.allocPrint(allocator, "-Dmcc.expectedPeers={s}", .{expected_peers});
    defer allocator.free(expected);
    const scenario_arg = try std.fmt.allocPrint(allocator, "-Dmcc.scenario={s}", .{scenario});
    defer allocator.free(scenario_arg);
    const connect_arg = try std.fmt.allocPrint(allocator, "-Dmcc.connectTick={d}", .{connect_tick});
    defer allocator.free(connect_arg);
    const fixture_arg = try std.fmt.allocPrint(allocator, "-Dmcc.fixture={s}", .{arguments.test_manifest.client});
    defer allocator.free(fixture_arg);
    const client = for (arguments.clients) |client| {
        if (std.mem.eql(u8, client.version, client_version)) break client;
    } else return error.ClientBundleUnavailable;
    const run_dir = try std.fmt.allocPrint(allocator, "{s}/run/{s}", .{ artifacts, peer });
    defer allocator.free(run_dir);
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("DISPLAY", display);
    try environment.put("LP_NUM_THREADS", "2");
    const bundle = try client_bundle.Bundle.open(init, client.bundle, client_version);
    const base_properties = [_][]const u8{ version, address_arg, events, output, peer_arg, expected, scenario_arg, connect_arg, fixture_arg };
    const properties = try std.mem.concat(init.arena.allocator(), []const u8, &.{ &base_properties, extra_properties });
    // Online, a client logs in as a Mojang account does: under the UUID the session server knows
    // it by, with a token naming it, which the session server hands its chat key for. Releases
    // before 1.21.9 only ask for one as an account of type msa; later ones ignore the type.
    var uuid_text: [36]u8 = undefined;
    const account = [_][]const u8{ "--userType", "msa", "--uuid", formatUuid(&uuid_text, @import("src/session_server.zig").onlineUuid(peer)), "--accessToken", peer };
    const login = [_][]const u8{ "--username", peer, "--gameDir", run_dir };
    const command = try bundle.command(init, run_dir, properties, if (online) &(login ++ account) else &login, .{ .fixtures = client.fixtures });
    const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ artifacts, peer });
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().createFile(init.io, log_path, .{});
    defer log.close(init.io);
    const child = try std.process.spawn(init.io, .{
        .argv = command,
        .cwd = .{ .path = run_dir },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });
    return .{ .child = child, .group = child.id orelse return error.ProcessIdUnavailable };
}

fn waitForResults(init: std.process.Init, artifacts: []const u8, peers: []const []const u8, reload: ?ReloadTest, upgrade: ?*UpgradeTest, server: std.posix.pid_t) !void {
    var reload_test = reload;
    const deadline = std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds + scenario_timeout_s * std.time.ns_per_s;

    while (std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds < deadline) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        if (try allMarkers(init, artifacts, peers, ".result")) return;
        for (peers) |peer| {
            if (try allMarkers(init, artifacts, &.{peer}, ".result") and
                !try resultsPassed(init, artifacts, &.{peer})) return error.EndToEndAssertionFailed;
        }

        if (reload_test) |*test_case| try test_case.poll(init, artifacts, peers, deadline, &interrupted);
        if (upgrade) |coordinator| try coordinator.poll(init, artifacts, peers, server);

        for (&process_groups, 0..) |*group, index| {
            const pid = group.load(.acquire);
            if (pid == 0) continue;

            var info: std.os.linux.siginfo_t = std.mem.zeroes(std.os.linux.siginfo_t);
            const result = std.os.linux.waitid(.PID, pid, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null);
            if (std.os.linux.errno(result) == .SUCCESS and info.code != 0) {
                if (try allMarkers(init, artifacts, peers, ".result")) return;
                if (index >= 2 and index - 2 < peers.len and try allMarkers(init, artifacts, peers[index - 2 .. index - 1], ".result")) continue;
                std.log.err("event=e2e_child_exited pid={d}", .{pid});
                return error.ChildExitedBeforeResults;
            }
        }

        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }

    return error.EndToEndTimeout;
}

fn resultsPassed(init: std.process.Init, artifacts: []const u8, peers: []const []const u8) !bool {
    for (peers) |peer| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.result", .{ artifacts, peer });
        defer init.gpa.free(path);
        const result = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(1024));
        defer init.gpa.free(result);
        if (!std.mem.startsWith(u8, result, "PASS ")) {
            std.log.err("event=e2e_client_failed peer={s} result={s}", .{ peer, result });
            return false;
        }
    }

    return true;
}

fn writeSummary(init: std.process.Init, artifacts: []const u8, scenario: []const u8, passed: bool, reason: []const u8) !void {
    const path = try std.fmt.allocPrint(init.gpa, "{s}/summary.json", .{artifacts});
    defer init.gpa.free(path);
    const file = try std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true });
    defer file.close(init.io);
    const summary = try std.json.Stringify.valueAlloc(init.gpa, .{ .scenario = scenario, .passed = passed, .reason = reason }, .{});
    defer init.gpa.free(summary);
    try file.writeStreamingAll(init.io, summary);
}

/// --manifest PATH --directory PATH --scenario NAME --server PATH --key PATH --client-version RELEASE
/// [--client RELEASE BUNDLE FIXTURES]... [--address HOST:PORT] [--artifacts PATH]
/// [--realtime true|false] [--upgrade-from REVISION] [--performance-budget enforce|report]
fn parse(init: std.process.Init, values: []const [:0]const u8) !Arguments {
    const allocator = init.arena.allocator();
    var realtime = false;
    var address: []const u8 = "127.0.0.1:0";
    var server: ?[]const u8 = null;
    var artifacts: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var directory: ?[]const u8 = null;
    var key: ?[]const u8 = null;
    var scenario: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var upgrade_from: []const u8 = "HEAD^";
    var performance_budget: @FieldType(Arguments, "performance_budget") = .enforce;
    var clients: [max_clients]Client = undefined;
    var client_count: usize = 0;
    var index: usize = 1;

    while (index < values.len) {
        const name = values[index];
        if (std.mem.eql(u8, name, "--client")) {
            if (index + 3 >= values.len) return error.MissingArgumentValue;
            if (client_count == clients.len) return error.TooManyClients;
            clients[client_count] = .{
                .version = values[index + 1],
                .bundle = try std.Io.Dir.cwd().realPathFileAlloc(init.io, values[index + 2], allocator),
                .fixtures = try std.Io.Dir.cwd().realPathFileAlloc(init.io, values[index + 3], allocator),
            };
            client_count += 1;
            index += 4;
            continue;
        }
        if (index + 1 >= values.len) return error.MissingArgumentValue;
        const value = values[index + 1];
        index += 2;
        if (std.mem.eql(u8, name, "--realtime")) {
            if (std.mem.eql(u8, value, "true")) realtime = true else if (std.mem.eql(u8, value, "false")) realtime = false else return error.InvalidRealtimeMode;
        } else if (std.mem.eql(u8, name, "--upgrade-from")) {
            upgrade_from = value;
        } else if (std.mem.eql(u8, name, "--client-version")) {
            version = value;
        } else if (std.mem.eql(u8, name, "--server")) {
            server = value;
        } else if (std.mem.eql(u8, name, "--address")) {
            address = value;
        } else if (std.mem.eql(u8, name, "--artifacts")) {
            artifacts = value;
        } else if (std.mem.eql(u8, name, "--manifest")) {
            manifest_path = value;
        } else if (std.mem.eql(u8, name, "--directory")) {
            directory = value;
        } else if (std.mem.eql(u8, name, "--key")) {
            key = value;
        } else if (std.mem.eql(u8, name, "--performance-budget")) {
            performance_budget = std.meta.stringToEnum(@TypeOf(performance_budget), value) orelse return error.InvalidPerformanceBudget;
        } else if (std.mem.eql(u8, name, "--scenario")) {
            scenario = value;
        } else return error.UnknownArgument;
    }

    const test_manifest = try manifest.read(init.io, init.gpa, allocator, manifest_path orelse return error.MissingManifest);
    const selected = test_manifest.find(scenario orelse return error.MissingScenario) orelse return error.UnknownScenario;
    const requested = version orelse return error.MissingClientVersion;
    const client_version = protocol_catalog.versions[protocol_catalog.releaseIndex(requested) orelse return error.UnsupportedClientVersion].minecraft_version;
    const peer_versions = try selection.peerVersions(protocol_catalog, allocator, selected, client_version);
    for (peer_versions) |peer_version| {
        for (clients[0..client_count]) |client| {
            if (std.mem.eql(u8, client.version, peer_version)) break;
        } else return error.ClientBundleUnavailable;
    }
    // The server and the upgrade coordinator read the key from the environment.
    try init.environ_map.put("LIGHTNING_ROD_E2E_KEY", try std.Io.Dir.cwd().realPathFileAlloc(init.io, key orelse return error.MissingEncryptionKey, allocator));
    return .{
        .realtime = realtime,
        .address = address,
        .server = server orelse return error.MissingServerExecutable,
        .directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, directory orelse return error.MissingTestDirectory, allocator),
        .test_manifest = test_manifest,
        .clients = try allocator.dupe(Client, clients[0..client_count]),
        .artifacts = artifacts,
        .scenario = selected,
        .client_version = client_version,
        .peer_versions = peer_versions,
        .upgrade_from = upgrade_from,
        .performance_budget = performance_budget,
    };
}

fn ensureExecutable(io: std.Io, path: []const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return error.ServerExecutableUnavailable;
    defer file.close(io);
    if (@backingInt((try file.stat(io)).permissions) & 0o111 == 0) return error.ServerNotExecutable;
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);

    for (&process_groups) |*group| {
        const value = group.load(.monotonic);

        if (value != 0) _ = std.os.linux.kill(-value, .KILL);
    }
}

fn formatUuid(buffer: *[36]u8, uuid: u128) []const u8 {
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>32}", .{uuid}) catch unreachable;
    _ = std.fmt.bufPrint(buffer, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
    return buffer;
}

test "online UUIDs format as Java writes them" {
    var buffer: [36]u8 = undefined;
    try std.testing.expectEqualStrings("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0", formatUuid(&buffer, 0x0f1e2d3c4b5a69788796a5b4c3d2e1f0));
}

/// Where the server traced its entities, each client's trace is held to it: between exact
/// states, every tick a client computed must be the server's, bit for bit. What each client
/// matched and where it strayed goes to `<peer>.entity-proof.txt`.
fn proveEntities(init: std.process.Init, artifacts: []const u8, peers: []const []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const limit = std.Io.Limit.limited(1024 * 1024 * 1024);
    const server_path = try std.fmt.allocPrint(init.gpa, "{s}/server.entities", .{artifacts});
    defer init.gpa.free(server_path);
    const server_text = cwd.readFileAlloc(init.io, server_path, init.gpa, limit) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer init.gpa.free(server_text);
    var server = try entity_compare.Server.parse(init.gpa, server_text);
    defer server.deinit(init.gpa);
    var failed = false;
    for (peers) |peer| {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.entities", .{ artifacts, peer });
        defer init.gpa.free(path);
        const client = try cwd.readFileAlloc(init.io, path, init.gpa, limit);
        defer init.gpa.free(client);
        var report = try entity_compare.compare(init.gpa, &server, client, 64);
        defer report.deinit(init.gpa);
        const report_path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.entity-proof.txt", .{ artifacts, peer });
        defer init.gpa.free(report_path);
        const file = try cwd.createFile(init.io, report_path, .{});
        defer file.close(init.io);
        var buffer: [4096]u8 = undefined;
        var writer = file.writer(init.io, &buffer);
        const out = &writer.interface;
        try out.print("anchors {d} unmatched {d} compared {d} strayed {d} latent {d}\n", .{ report.anchors, report.unmatched, report.compared, report.strayed, report.latent });
        for (report.divergences.items) |divergence| {
            try out.print("entity {d} at server tick {d}, {d} after its exact state, moving apart since {?d}\n  client {f}\n  server {f}\n", .{ divergence.id, divergence.server_tick, divergence.after, divergence.moved_apart, divergence.client, divergence.server });
        }
        try out.flush();
        std.log.info("event=e2e_entity_proof peer={s} anchors={d} unmatched={d} compared={d} strayed={d} latent={d}", .{ peer, report.anchors, report.unmatched, report.compared, report.strayed, report.latent });
        // A proof that compared nothing proves nothing.
        if (report.strayed > 0 or report.unmatched > 0 or report.compared == 0) failed = true;
    }
    if (failed) return error.EntityProofFailed;
}
