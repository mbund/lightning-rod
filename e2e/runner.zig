const std = @import("std");
const builtin = @import("builtin");
const allMarkers = @import("src/artifacts.zig").allMarkers;
const process_cleanup = @import("src/process_cleanup.zig");
const catalog = @import("src/catalog.zig");
const ReloadTest = @import("tests/reload/test.zig").Test;

const max_processes = catalog.maximum_peers + 2;
const scenario_timeout_s = 180;

const Arguments = struct {
    server: []const u8,
    client: []const u8,
    artifacts: []const u8,
    scenario: catalog.Case,
    address: []const u8,
    strace: bool,
    client_version: []const u8,
    gradle: [5][]const u8,
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

var process_groups: [max_processes]std.atomic.Value(std.posix.pid_t) = @splat(.init(0));
var interrupted = std.atomic.Value(bool).init(false);

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .linux) return error.E2eRequiresLinux;
    try process_cleanup.enable();
    defer _ = process_cleanup.finish(init.io) catch {};
    installSignalHandlers();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
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
    try init.environ_map.put("LIGHTNING_ROD_E2E_CLIENT_SOURCE", client);
    try cwd.createDirPath(init.io, arguments.artifacts);
    const root = try cwd.realPathFileAlloc(init.io, arguments.artifacts, init.gpa);
    defer init.gpa.free(root);
    const artifacts = try std.fmt.allocPrint(init.gpa, "{s}/{s}-{s}-{d}", .{ root, arguments.scenario.name, arguments.client_version, std.Io.Clock.Timestamp.now(init.io, .real).raw.nanoseconds });
    defer init.gpa.free(artifacts);
    try cwd.createDir(init.io, artifacts, .default_dir);
    std.log.info("event=e2e_started scenario={s} artifacts={s}", .{ arguments.scenario.name, artifacts });
    const client_versions = if (arguments.scenario.peer_versions.len == 0) &.{arguments.client_version} else arguments.scenario.peer_versions;
    for (client_versions, 0..) |version, index| {
        var duplicate = false;
        for (client_versions[0..index]) |previous| duplicate = duplicate or std.mem.eql(u8, previous, version);
        if (duplicate) continue;
        const gradle = try clientArguments(init, client, version);
        const wrapper = try std.fs.path.join(init.gpa, &.{ client, "gradlew" });
        defer init.gpa.free(wrapper);
        const log = try std.fmt.allocPrint(init.gpa, "client-build-{s}.log", .{version});
        defer init.gpa.free(log);
        var compile_client = try spawn(init, &.{ wrapper, "--no-daemon", "compileClientJava", gradle[0], gradle[1], gradle[2], gradle[3], gradle[4] }, artifacts, client, log);
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

fn runScenario(init: std.process.Init, test_case: catalog.Case, server_path: []const u8, client_dir: []const u8, artifacts: []const u8, world: []const u8, address: []const u8, strace: bool, gradle: [5][]const u8) !void {
    const scenario = test_case.name;
    const test_directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, test_case.directory, init.gpa);
    defer init.gpa.free(test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_TEST_DIRECTORY", test_directory);
    try init.environ_map.put("LIGHTNING_ROD_E2E_ADDRESS", address);
    const port = try std.fmt.allocPrint(init.gpa, "--port={s}", .{address[(std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidAddress) + 1 ..]});
    defer init.gpa.free(port);
    try init.environ_map.put("LIGHTNING_ROD_PORT", port[7..]);
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
    var clients: [catalog.maximum_peers]ManagedChild = undefined;
    var count: usize = 0;
    defer for (clients[0..count], 0..) |*child, index| {
        child.stop(init.io);
        process_groups[index + 2].store(0, .release);
    };

    for (peers) |peer| {
        const connect_tick: usize = if (count + 1 == peers.len) test_case.last_peer_connect_tick else 40;
        const peer_gradle = if (test_case.peer_versions.len == 0) gradle else try clientArguments(init, client_dir, test_case.peer_versions[count]);
        clients[count] = try spawnClient(init, client_dir, artifacts, scenario, peer, peers, connect_tick, address, peer_gradle);
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
    const start = try std.Io.Dir.cwd().createFile(init.io, start_path, .{});
    start.close(init.io);

    try waitForResults(init, artifacts, peers, if (test_case.reload) .{ .world = world, .executable = server_path, .protocol_mismatch = test_case.protocol_mismatch } else null);
    if (!try resultsPassed(init, artifacts, peers)) return error.EndToEndAssertionFailed;
    {
        const path = try std.fmt.allocPrint(init.gpa, "{s}/server.log", .{artifacts});
        defer init.gpa.free(path);
        const log = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(16 * 1024 * 1024));
        defer init.gpa.free(log);
        if (!strace and std.mem.indexOf(u8, log, "event=slow_tick ") != null) return error.TickBudgetExceeded;

        if (test_case.reload) try ReloadTest.verify(log, peers.len);

        for (test_case.required_logs) |rule| {
            const expected = rule.count * (if (rule.per_peer) peers.len else @as(usize, 1));
            const actual = std.mem.count(u8, log, rule.text);
            if (if (rule.at_least) actual < expected else actual != expected) {
                std.log.err("event=e2e_log_count_mismatch text={s} expected={d}", .{ rule.text, expected });
                return error.LogCountMismatch;
            }
        }

        for (test_case.forbidden_logs) |text| {
            if (std.mem.indexOf(u8, log, text) != null) {
                std.log.err("event=e2e_forbidden_log text={s}", .{text});
                return error.ForbiddenLog;
            }
        }
    }
    try writeSummary(init, artifacts, scenario, true, "passed");
    if (test_case.crash_after) try std.posix.kill(-server.group, .KILL);
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

fn spawnClient(init: std.process.Init, client_dir: []const u8, artifacts: []const u8, scenario: []const u8, peer: []const u8, peers: []const []const u8, connect_tick: usize, address: []const u8, gradle: [5][]const u8) !ManagedChild {
    const allocator = init.gpa;
    const version = try std.fmt.allocPrint(allocator, "-Dmcc.version={s}", .{gradle[0]["-Pminecraft_version=".len..]});
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
        .argv = &.{ wrapper, "--no-daemon", "runClient", gradle[0], gradle[1], gradle[2], gradle[3], gradle[4], version, address_arg, events, output, peer_arg, expected, scenario_arg, connect_arg, run_dir },
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
    var strace = false;
    var address: []const u8 = "127.0.0.1:25565";
    var server: ?[]const u8 = null;
    var client: []const u8 = "client";
    var artifacts: []const u8 = "artifacts";
    var scenario: ?catalog.Case = null;
    var version: ?[]const u8 = null;
    var index: usize = 1;

    while (index < values.len) : (index += 2) {
        if (index + 1 >= values.len) return error.MissingArgumentValue;

        const key = values[index];
        const value = values[index + 1];
        if (std.mem.eql(u8, key, "--tests")) continue;

        if (std.mem.eql(u8, key, "--client-version")) version = value else if (std.mem.eql(u8, key, "--server")) server = value else if (std.mem.eql(u8, key, "--strace")) strace = std.mem.eql(u8, value, "true") else if (std.mem.eql(u8, key, "--address")) address = value else if (std.mem.eql(u8, key, "--client")) client = value else if (std.mem.eql(u8, key, "--artifacts")) artifacts = value else if (std.mem.eql(u8, key, "--scenario")) scenario = catalog.find(cases, value) orelse return error.UnknownScenario else return error.UnknownArgument;
    }

    const client_version = version orelse return error.MissingClientVersion;
    return .{
        .strace = strace,
        .address = address,
        .server = server orelse return error.MissingServerExecutable,
        .client = client,
        .artifacts = artifacts,
        .scenario = scenario orelse return error.MissingScenario,
        .client_version = client_version,
        .gradle = try clientArguments(init, client, client_version),
    };
}

fn clientArguments(init: std.process.Init, client: []const u8, version: []const u8) ![5][]const u8 {
    const allocator = init.arena.allocator();
    const Version = struct { release: []const u8, api: []const u8, fabric: []const u8 };
    const path = try std.fs.path.join(allocator, &.{ client, "versions.json" });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024));
    const versions = try std.json.parseFromSliceLeaky([]const Version, allocator, bytes, .{});
    var selected: ?Version = null;
    for (versions) |entry| if (std.mem.eql(u8, entry.release, version)) {
        if (selected != null) return error.DuplicateClientVersion;
        selected = entry;
    };
    const entry = selected orelse return error.UnsupportedClientVersion;
    const directory = try std.Io.Dir.cwd().realPathFileAlloc(init.io, client, allocator);
    const project = try std.fs.path.join(allocator, &.{ directory, "build", "clients", entry.release });
    try std.Io.Dir.cwd().createDirPath(init.io, project);
    for ([_][]const u8{ "build.gradle", "settings.gradle", "gradle.properties" }) |name| {
        const source = try std.fs.path.join(allocator, &.{ directory, name });
        const destination = try std.fs.path.join(allocator, &.{ project, name });
        try std.Io.Dir.cwd().copyFile(source, .cwd(), destination, init.io, .{});
    }
    return .{
        try std.fmt.allocPrint(allocator, "-Pminecraft_version={s}", .{entry.release}),
        try std.fmt.allocPrint(allocator, "-Pclient_api={s}", .{entry.api}),
        try std.fmt.allocPrint(allocator, "-Pfabric_api_version={s}", .{entry.fabric}),
        "-p",
        project,
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
