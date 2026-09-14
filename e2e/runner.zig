const std = @import("std");
const builtin = @import("builtin");
const allMarkers = @import("src/artifacts.zig").allMarkers;
const process_cleanup = @import("src/process_cleanup.zig");
const catalog = @import("src/catalog.zig");
const ReloadTest = @import("tests/reload/server.zig").Test;

const max_processes = 5;
const scenario_timeout_s = 180;

const Arguments = struct {
    server: []const u8,
    client: []const u8,
    artifacts: []const u8,
    scenario: catalog.Case,
    address: []const u8,
    strace: bool,
    client_version: []const u8,
    gradle: [3][]const u8,
};

const ManagedChild = struct {
    child: std.process.Child,
    group: std.posix.pid_t,

    fn stop(self: *ManagedChild, io: std.Io) void {
        std.posix.kill(-self.group, .TERM) catch {};
        const deadline = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + std.time.ns_per_s;

        while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < deadline) {
            var info: std.os.linux.siginfo_t = undefined;
            @memset(std.mem.asBytes(&info), 0);

            switch (std.os.linux.errno(std.os.linux.waitid(.PID, self.group, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null))) {
                .SUCCESS => if (info.code != 0) break,
                .INTR => continue,
                else => break,
            }

            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch break;
        }

        std.posix.kill(-self.group, .KILL) catch {};
        self.child.kill(io);
    }
};

var process_groups: [max_processes]std.atomic.Value(std.posix.pid_t) = .{ .init(0), .init(0), .init(0), .init(0), .init(0) };
var interrupted = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.E2eRequiresLinux;
    try process_cleanup.enable();
    defer _ = process_cleanup.finish(init.io) catch {};
    installSignalHandlers();
    const cases = try catalog.load(init.arena.allocator(), init.io, "tests");
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--list")) {
        for (cases) |case| {
            if (case.internal) continue;

            const line = try std.fmt.allocPrint(init.arena.allocator(), "{s}\t{s}\n", .{ case.name, case.directory });
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
        }

        return;
    }

    const arguments = try parse(args, cases);
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
    const client = try cwd.realPathFileAlloc(init.io, arguments.client, init.gpa);
    defer init.gpa.free(client);
    try cwd.createDirPath(init.io, arguments.artifacts);
    const root = try cwd.realPathFileAlloc(init.io, arguments.artifacts, init.gpa);
    defer init.gpa.free(root);
    const artifacts = try std.fmt.allocPrint(init.gpa, "{s}/{s}-{s}-{d}", .{ root, arguments.scenario.name, arguments.client_version, std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds });
    defer init.gpa.free(artifacts);
    try cwd.createDir(init.io, artifacts, .default_dir);
    std.log.info("event=e2e_started scenario={s} artifacts={s}", .{ arguments.scenario.name, artifacts });
    {
        const wrapper = try std.fs.path.join(init.gpa, &.{ client, "gradlew" });
        defer init.gpa.free(wrapper);
        var compile_client = try spawn(init, &.{ wrapper, "--no-daemon", "compileClientJava", arguments.gradle[0], arguments.gradle[1], arguments.gradle[2] }, artifacts, client, "client-build.log");
        process_groups[0].store(compile_client.group, .release);
        defer {
            compile_client.stop(init.io);
            process_groups[0].store(0, .release);
        }
        const result = try compile_client.child.wait(init.io);
        if (result != .exited or result.exited != 0) return error.ClientBuildFailed;
    }
    const world = try std.fs.path.join(init.gpa, &.{ artifacts, "server" });
    defer init.gpa.free(world);
    try cwd.createDir(init.io, world, .default_dir);
    var preparation_failure: ?anyerror = null;
    const preparation_scenario = arguments.scenario.prepare;
    if (preparation_scenario) |scenario| {
        const preparation = try std.fs.path.join(init.gpa, &.{ artifacts, "prepare" });
        defer init.gpa.free(preparation);
        try cwd.createDir(init.io, preparation, .default_dir);
        runScenario(init, catalog.find(cases, scenario).?, server, client, preparation, world, arguments.address, arguments.strace, arguments.gradle) catch |err| {
            try writeSummary(init, preparation, scenario, false, @errorName(err));
            if (err != error.TickBudgetExceeded) {
                try writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err));
                return err;
            }

            preparation_failure = err;
        };
    }

    runScenario(init, arguments.scenario, server, client, artifacts, world, arguments.address, arguments.strace, arguments.gradle) catch |err| {
        writeSummary(init, artifacts, arguments.scenario.name, false, @errorName(err)) catch {};
        std.log.err("event=e2e_failed reason={s} artifacts={s}", .{ @errorName(err), artifacts });
        return err;
    };
    if (preparation_failure) |err| {
        try writeSummary(init, artifacts, arguments.scenario.name, false, "preparation_tick_budget_exceeded");
        return err;
    }

    std.log.info("event=e2e_passed artifacts={s}", .{artifacts});
}

fn runScenario(init: std.process.Init, test_case: catalog.Case, server_path: []const u8, client_dir: []const u8, artifacts: []const u8, world: []const u8, address: []const u8, strace: bool, gradle: [3][]const u8) !void {
    const scenario = test_case.name;
    const test_directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, test_case.directory, init.gpa);
    defer init.gpa.free(test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_DIRECTORY", test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_ADDRESS", address);
    const port = try std.fmt.allocPrint(init.gpa, "--port={s}", .{address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..]});
    defer init.gpa.free(port);
    const fixture = test_case.fixture;
    const fixture_arg = if (fixture) |name| try std.fmt.allocPrint(init.gpa, "--fixture={s}", .{name}) else null;
    defer if (fixture_arg) |arg| init.gpa.free(arg);
    var argv: [8][]const u8 = undefined;
    var argc: usize = 0;

    if (strace) for ([_][]const u8{ "strace", "-f", "-c", "-o", "syscalls.txt" }) |arg| {
        argv[argc] = arg;
        argc += 1;
    };

    argv[argc] = server_path;
    argc += 1;

    if (fixture_arg) |arg| {
        argv[argc] = arg;
        argv[argc + 1] = port;
        argc += 2;
    }

    const reload = std.mem.eql(u8, scenario, "reload-multi");
    var server = try spawn(init, argv[0..argc], artifacts, world, "server.log");
    process_groups[0].store(server.group, .release);
    defer {
        server.stop(init.io);
        process_groups[0].store(0, .release);
    }
    var xvfb = try spawn(init, &.{ "Xvfb", ":97", "-screen", "0", "1280x720x24", "-nolisten", "tcp" }, artifacts, artifacts, "display.log");
    process_groups[1].store(xvfb.group, .release);
    defer {
        xvfb.stop(init.io);
        process_groups[1].store(0, .release);
    }
    try std.Io.sleep(init.io, .fromMilliseconds(1_500), .awake);
    const peers = test_case.peers;
    var clients: [3]ManagedChild = undefined;
    var count: usize = 0;
    defer for (clients[0..count], 0..) |*child, index| {
        child.stop(init.io);
        process_groups[index + 2].store(0, .release);
    };

    for (peers) |peer| {
        const connect_tick: usize = if (count + 1 == peers.len) test_case.last_peer_connect_tick else 40;
        clients[count] = try spawnClient(init, client_dir, artifacts, scenario, peer, peers, connect_tick, address, gradle);
        process_groups[count + 2].store(clients[count].group, .release);
        count += 1;
    }

    try waitForResults(init, artifacts, peers, if (reload) .{ .world = world, .executable = server_path } else null);
    const passed = try resultsPassed(init, artifacts, peers);
    {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/server.log", .{artifacts});
        defer init.gpa.free(path);
        const log = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
        defer init.gpa.free(log);
        if (!strace and std.mem.indexOf(u8, log, "event=slow_tick ") != null) return error.TickBudgetExceeded;

        if (reload) try ReloadTest.verify(log, peers.len);
        if (std.mem.eql(u8, scenario, "chunks-simulations-multi") and (std.mem.count(u8, log, "event=simulation_ready ") != 2 or std.mem.indexOf(u8, log, "event=session_routed endpoint=0 ") == null or std.mem.indexOf(u8, log, "event=session_routed endpoint=1 ") == null))
            return error.SimulationRoutingFailed;
        if (std.mem.indexOf(u8, scenario, "encrypted") != null and std.mem.count(u8, log, "event=session_encrypted ") != peers.len)
            return error.EncryptionBypassed;
        if (std.mem.eql(u8, scenario, "transfer-multi") and std.mem.count(u8, log, "event=session_transfer ") != 2) return error.TransferFailed;
        if (std.mem.eql(u8, scenario, "encryption-reject") and (std.mem.indexOf(u8, log, "reason=InvalidEncryption") == null or std.mem.indexOf(u8, log, "event=session_play_attached") != null))
            return error.InvalidEncryptionAccepted;
        if (std.mem.startsWith(u8, scenario, "chunks-disk") and std.mem.indexOf(u8, log, "event=terrain_generation_started") != null)
            return error.UnexpectedTerrainGeneration;
    }
    try writeSummary(init, artifacts, scenario, passed, if (passed) "passed" else "client_failed");
    if (!passed) return error.EndToEndAssertionFailed;
}

fn spawn(init: std.process.Init, argv: []const []const u8, artifacts: []const u8, working_directory: []const u8, name: []const u8) !ManagedChild {
    const path = try std.fs.path.join(init.gpa, &.{ artifacts, name });
    defer init.gpa.free(path);
    const log = try std.Io.Dir.cwd().createFile(init.io, path, .{});
    defer log.close(init.io);
    const child = try std.process.spawn(init.io, .{
        .argv = argv,
        .environ_map = init.environ_map,
        .cwd = .{ .path = working_directory },
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });
    return .{ .child = child, .group = child.id orelse return error.ProcessIdUnavailable };
}

fn spawnClient(init: std.process.Init, client_dir: []const u8, artifacts: []const u8, scenario: []const u8, peer: []const u8, peers: []const []const u8, connect_tick: usize, address: []const u8, gradle: [3][]const u8) !ManagedChild {
    const allocator = init.gpa;
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
    const run_dir = try std.fmt.allocPrint(allocator, "-Dmcc.runDir=.e2e/{s}-{s}", .{ scenario, peer });
    defer allocator.free(run_dir);
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("DISPLAY", ":97");
    try environment.put("LP_NUM_THREADS", "2");
    const wrapper = try std.fs.path.join(allocator, &.{ client_dir, "gradlew" });
    defer allocator.free(wrapper);
    const log_path = try std.fmt.allocPrint(allocator, "{s}/{s}.log", .{ artifacts, peer });
    defer allocator.free(log_path);
    const log = try std.Io.Dir.cwd().createFile(init.io, log_path, .{});
    defer log.close(init.io);
    const child = try std.process.spawn(init.io, .{
        .argv = &.{ wrapper, "--no-daemon", "-p", client_dir, "runClient", gradle[0], gradle[1], gradle[2], address_arg, events, output, peer_arg, expected, scenario_arg, connect_arg, run_dir },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
        .pgid = 0,
    });
    return .{ .child = child, .group = child.id orelse return error.ProcessIdUnavailable };
}

fn waitForResults(init: std.process.Init, artifacts: []const u8, peers: []const []const u8, reload: ?ReloadTest) !void {
    var reload_test = reload;
    const deadline = std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds + scenario_timeout_s * std.time.ns_per_s;

    while (std.Io.Clock.Timestamp.now(init.io, .awake).raw.nanoseconds < deadline) {
        if (interrupted.load(.acquire)) return error.Interrupted;
        if (try allMarkers(init, artifacts, peers, ".result")) return;

        if (reload_test) |*test_case| try test_case.poll(init, artifacts, peers, deadline, &interrupted);

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
        if (!std.mem.startsWith(u8, result, "PASS ")) return false;
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

fn parse(values: []const [:0]const u8, cases: []const catalog.Case) !Arguments {
    var strace = false;
    var address: []const u8 = "127.0.0.1:25565";
    var server: ?[]const u8 = null;
    var client: []const u8 = "client";
    var artifacts: []const u8 = "artifacts";
    var scenario: ?catalog.Case = null;
    var version: []const u8 = "1.21.8";
    var index: usize = 1;

    while (index < values.len) : (index += 2) {
        if (index + 1 >= values.len) return error.MissingArgumentValue;

        const key = values[index];
        const value = values[index + 1];

        if (std.mem.eql(u8, key, "--client-version")) version = value else if (std.mem.eql(u8, key, "--server")) server = value else if (std.mem.eql(u8, key, "--strace")) strace = std.mem.eql(u8, value, "true") else if (std.mem.eql(u8, key, "--address")) address = value else if (std.mem.eql(u8, key, "--client")) client = value else if (std.mem.eql(u8, key, "--artifacts")) artifacts = value else if (std.mem.eql(u8, key, "--scenario")) scenario = catalog.find(cases, value) orelse return error.UnknownScenario else return error.UnknownArgument;
    }

    const gradle: [3][]const u8 = if (std.mem.eql(u8, version, "1.21.6"))
        .{ "-Pminecraft_version=1.21.6", "-Pyarn_mappings=1.21.6+build.1", "-Pfabric_api_version=0.128.2+1.21.6" }
    else if (std.mem.eql(u8, version, "1.21.8"))
        .{ "-Pminecraft_version=1.21.8", "-Pyarn_mappings=1.21.8+build.1", "-Pfabric_api_version=0.136.1+1.21.8" }
    else
        return error.UnsupportedClientVersion;
    return .{
        .strace = strace,
        .address = address,
        .server = server orelse return error.MissingServerExecutable,
        .client = client,
        .artifacts = artifacts,
        .scenario = scenario orelse return error.MissingScenario,
        .client_version = version,
        .gradle = gradle,
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
