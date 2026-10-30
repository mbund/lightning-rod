const std = @import("std");
const builtin = @import("builtin");
const allMarkers = @import("src/artifacts.zig").allMarkers;
const process_cleanup = @import("src/process_cleanup.zig");
const catalog = @import("src/catalog.zig");
const selection = @import("src/selection.zig");
const protocol_catalog = @import("protocol_catalog");
const scheduling = @import("src/scheduling.zig");
const performance = @import("src/performance.zig");
const ReloadTest = @import("tests/reload/test.zig").Test;
const UpgradeTest = @import("tests/upgrade/test.zig").Test;
const ManagedChild = @import("src/child.zig").ManagedChild;
const Listener = @import("src/listener.zig").Listener;
const client_bundle = @import("src/client_bundle.zig");

const max_processes = catalog.maximum_peers + 2;
const scenario_timeout_s = 180;

const Arguments = struct {
    realtime: bool = false,
    server: []const u8,
    client_roots: []const []const u8,
    artifacts: ?[]const u8,
    scenario: catalog.Case,
    address: []const u8,
    client_version: []const u8,
    peer_versions: []const []const u8,
    upgrade_from: []const u8,
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
    if ((args.len == 3 or args.len == 4) and std.mem.eql(u8, args[1], "--test-client")) {
        const bundle = try client_bundle.Bundle.open(init, args[2], if (args.len == 4) &.{args[3]} else &.{});
        const run_directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, ".", init.arena.allocator());
        const command = try bundle.command(init, try std.fs.path.join(init.arena.allocator(), &.{ run_directory, ".zig-cache/client-api" }), &.{}, &.{}, true);
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
    var tests_root: []const u8 = "tests";
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, "--tests")) continue;
        if (index + 1 == args.len) return error.MissingArgumentValue;
        tests_root = args[index + 1];
    }
    const cases = try catalog.load(init.arena.allocator(), init.io, tests_root);
    const absolute_tests = try std.Io.Dir.cwd().realPathFileAlloc(init.io, tests_root, init.arena.allocator());
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_ROOT", absolute_tests);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--list")) {
        for (cases) |case| {
            if (case.internal) continue;

            const line = try std.fmt.allocPrint(init.arena.allocator(), "{s}\t{s}\n", .{ case.name, case.directory });
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
        }

        return;
    }

    const arguments = try parse(init, args, cases);
    if (arguments.realtime) scheduling.preflight() catch |err| {
        if (err == error.RealtimePermissionRequired)
            std.log.err("FIFO scheduling requires CAP_SYS_NICE or RLIMIT_RTPRIO >= 1. In your shell, run: sudo prlimit --pid $$ --rtprio=1:1 . Use -Drealtime=false for normal scheduling.", .{});
        return err;
    };
    try ensureExecutable(init.io, arguments.server);
    try run(init, arguments, cases);
}

fn run(init: std.process.Init, arguments: Arguments, cases: []const catalog.Case) !void {
    if (interrupted.load(.acquire)) return error.Interrupted;

    const cwd = std.Io.Dir.cwd();
    const working_directory = try cwd.realPathFileAlloc(init.io, ".", init.gpa);
    defer init.gpa.free(working_directory);
    const server = try std.fs.path.resolve(init.gpa, &.{ working_directory, arguments.server });
    defer init.gpa.free(server);
    const artifact_root = arguments.artifacts orelse try std.fs.path.join(init.arena.allocator(), &.{ arguments.scenario.directory, "artifacts" });
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
        runScenario(init, catalog.find(cases, scenario).?, server, preparation, world, arguments.address, arguments.client_version, &.{}, arguments.realtime, arguments.upgrade_from, arguments.client_roots) catch |err| {
            try writeSummary(init, preparation, scenario, false, @errorName(err));
            if (err == error.PerformanceBudgetExceeded) preparation_performance_failed = true else {
                try writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err));
                return err;
            }
        };
    }

    runScenario(init, arguments.scenario, server, artifacts, world, arguments.address, arguments.client_version, arguments.peer_versions, arguments.realtime, arguments.upgrade_from, arguments.client_roots) catch |err| {
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

fn runScenario(init: std.process.Init, test_case: catalog.Case, server_path: []const u8, artifacts: []const u8, world: []const u8, requested_address: []const u8, primary_version: []const u8, peer_versions: []const []const u8, realtime: bool, upgrade_from: []const u8, client_roots: []const []const u8) !void {
    std.debug.assert(peer_versions.len == 0 or peer_versions.len == test_case.peers.len);
    var listener = try Listener.init(init.io, requested_address);
    defer listener.deinit(init.io);
    var address_bytes: [128]u8 = undefined;
    const address = try std.fmt.bufPrint(&address_bytes, "{f}", .{listener.server.?.socket.address});
    std.log.info("event=e2e_listener address={s}", .{address});
    const scenario = test_case.name;
    const test_directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, test_case.directory, init.gpa);
    defer init.gpa.free(test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_DIRECTORY", test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_ADDRESS", address);
    try init.environ_map.put("LIGHTNING_ROD_METRICS_DIRECTORY", artifacts);
    const port = try std.fmt.allocPrint(init.gpa, "--port={s}", .{address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..]});
    defer init.gpa.free(port);
    try init.environ_map.put("LIGHTNING_ROD_PORT", port[7..]);
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
    var clients: [catalog.maximum_peers]ManagedChild = undefined;
    var count: usize = 0;
    defer for (clients[0..count], 0..) |*child, index| {
        child.stop(init.io);
        process_groups[index + 2].store(0, .release);
    };

    for (peers) |peer| {
        const connect_tick: usize = if (count + 1 == peers.len) test_case.last_peer_connect_tick else 40;
        const peer_version = if (peer_versions.len == 0) primary_version else peer_versions[count];
        clients[count] = try spawnClient(init, artifacts, scenario, peer, peers, connect_tick, address, peer_version, display, client_roots);
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

    try waitForResults(init, artifacts, peers, if (test_case.reload) .{ .world = world, .executable = server_path, .protocol_mismatch = test_case.protocol_mismatch } else null, if (upgrade) |*coordinator| coordinator else null, server.group);
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
    if (!server_passed) return error.PerformanceBudgetExceeded;
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

fn spawnClient(init: std.process.Init, artifacts: []const u8, scenario: []const u8, peer: []const u8, peers: []const []const u8, connect_tick: usize, address: []const u8, client_version: []const u8, display: []const u8, client_roots: []const []const u8) !ManagedChild {
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
    const run_dir = try std.fmt.allocPrint(allocator, "{s}/run/{s}", .{ artifacts, peer });
    defer allocator.free(run_dir);
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("DISPLAY", display);
    try environment.put("LP_NUM_THREADS", "2");
    const bundle = try client_bundle.Bundle.open(init, client_version, client_roots);
    const command = try bundle.command(init, run_dir, &.{ version, address_arg, events, output, peer_arg, expected, scenario_arg, connect_arg }, &.{ "--username", peer, "--gameDir", run_dir }, false);
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

fn parse(init: std.process.Init, values: []const [:0]const u8, cases: []const catalog.Case) !Arguments {
    var realtime = false;
    var address: []const u8 = "127.0.0.1:0";
    var server: ?[]const u8 = null;
    var artifacts: ?[]const u8 = null;
    var scenario: ?catalog.Case = null;
    var version: ?[]const u8 = null;
    var upgrade_from: []const u8 = "HEAD^";
    var client_roots: std.ArrayList([]const u8) = .empty;
    var index: usize = 1;

    while (index < values.len) : (index += 2) {
        if (index + 1 >= values.len) return error.MissingArgumentValue;

        const key = values[index];
        const value = values[index + 1];
        if (std.mem.eql(u8, key, "--tests")) continue;
        if (std.mem.eql(u8, key, "--clients")) {
            try client_roots.append(init.arena.allocator(), value);
            continue;
        }

        if (std.mem.eql(u8, key, "--realtime")) {
            if (std.mem.eql(u8, value, "true")) realtime = true else if (std.mem.eql(u8, value, "false")) realtime = false else return error.InvalidRealtimeMode;
        } else if (std.mem.eql(u8, key, "--upgrade-from")) upgrade_from = value else if (std.mem.eql(u8, key, "--client-version")) version = value else if (std.mem.eql(u8, key, "--server")) server = value else if (std.mem.eql(u8, key, "--address")) address = value else if (std.mem.eql(u8, key, "--artifacts")) artifacts = value else if (std.mem.eql(u8, key, "--scenario")) scenario = catalog.find(cases, value) orelse return error.UnknownScenario else return error.UnknownArgument;
    }

    const client_version = version orelse return error.MissingClientVersion;
    const selected = scenario orelse return error.MissingScenario;
    const peer_versions = try selection.peerVersions(protocol_catalog, init.arena.allocator(), selected, client_version);
    return .{
        .realtime = realtime,
        .address = address,
        .server = server orelse return error.MissingServerExecutable,
        .client_roots = client_roots.items,
        .artifacts = artifacts,
        .scenario = selected,
        .client_version = protocol_catalog.versions[protocol_catalog.releaseIndex(client_version).?].minecraft_version,
        .peer_versions = peer_versions,
        .upgrade_from = upgrade_from,
    };
}

fn ensureExecutable(io: std.Io, path: []const u8) !void {
    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return error.ServerExecutableUnavailable;
    defer file.close(io);
    if (@intFromEnum((try file.stat(io)).permissions) & 0o111 == 0) return error.ServerNotExecutable;
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
