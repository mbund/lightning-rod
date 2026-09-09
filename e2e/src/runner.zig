const std = @import("std");
const process_cleanup = @import("process_cleanup.zig");

const Scenario = enum { chunks, chunks_full, chunks_flat, chunks_persisted, chunks_prepare, chunks_prepare_flat, chunks_varied_disk, steady, reload, reload_failure, fatal_storage, auth_success, auth_reject, auth_timeout, skyblock_chat };

const Fixture = enum { vanilla, flat };

const default_capture_bytes = 32 * 1024 * 1024;
const maximum_capture_bytes = default_capture_bytes;

const Arguments = struct {
    server: []const u8,
    skyblock_server: ?[]const u8 = null,
    client: []const u8,
    artifacts: []const u8,
    scenario: []const u8,
    capture_bytes: ?u64 = null,
};

const Child = struct {
    process: std.process.Child,
    cleanup_slot: usize,

    fn shutdown(self: *Child, io: std.Io) !std.process.Child.Term {
        const pid = self.process.id orelse return error.ServerAlreadyExited;
        try std.posix.kill(pid, .TERM);
        const deadline = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + 10 * std.time.ns_per_s;
        while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < deadline) {
            var info: std.os.linux.siginfo_t = undefined;
            @memset(std.mem.asBytes(&info), 0);
            switch (std.os.linux.errno(std.os.linux.waitid(.PID, pid, &info, std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT, null))) {
                .SUCCESS => if (info.code != 0) {
                    const term = try self.process.wait(io);
                    cleanup_groups[self.cleanup_slot].store(0, .release);
                    return term;
                },
                .INTR => continue,
                else => return error.ServerWaitFailed,
            }
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        return error.ServerShutdownTimedOut;
    }

    fn stop(self: *Child, io: std.Io) void {
        const group = cleanup_groups[self.cleanup_slot].load(.acquire);
        if (group != 0) std.posix.kill(-group, .KILL) catch {};
        self.process.kill(io);
        cleanup_groups[self.cleanup_slot].store(0, .release);
    }
};

const ServerMemory = struct {
    last_rss_bytes: ?u64 = null,
    maximum_hwm_bytes: ?u64 = null,
    rss_available: bool = false,
    hwm_available: bool = false,

    fn sample(self: *ServerMemory, io: std.Io, pid: std.posix.pid_t) void {
        var path_storage: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_storage, "/proc/{d}/status", .{pid}) catch return;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return;
        defer file.close(io);

        var status_storage: [4096]u8 = undefined;
        const length = file.readPositionalAll(io, &status_storage, 0) catch return;
        const status = parseServerMemoryStatus(status_storage[0..length]);
        if (status.rss_bytes) |rss_bytes| {
            self.last_rss_bytes = rss_bytes;
            self.rss_available = true;
        }
        if (status.hwm_bytes) |hwm_bytes| {
            self.maximum_hwm_bytes = @max(self.maximum_hwm_bytes orelse 0, hwm_bytes);
            self.hwm_available = true;
        }
    }
};

const ServerMemoryStatus = struct {
    rss_bytes: ?u64 = null,
    hwm_bytes: ?u64 = null,
};

fn parseServerMemoryStatus(status: []const u8) ServerMemoryStatus {
    var result = ServerMemoryStatus{};
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            result.rss_bytes = parseStatusKibibytes(line["VmRSS:".len..]);
        } else if (std.mem.startsWith(u8, line, "VmHWM:")) {
            result.hwm_bytes = parseStatusKibibytes(line["VmHWM:".len..]);
        }
    }
    return result;
}

fn parseStatusKibibytes(value: []const u8) ?u64 {
    var fields = std.mem.tokenizeAny(u8, value, " \t");
    const kibibytes = std.fmt.parseInt(u64, fields.next() orelse return null, 10) catch return null;
    if (!std.mem.eql(u8, fields.next() orelse return null, "kB") or fields.next() != null) return null;
    return std.math.mul(u64, kibibytes, 1024) catch null;
}

var cleanup_groups: [4]std.atomic.Value(std.posix.pid_t) = .{
    .init(0), .init(0), .init(0), .init(0),
};
var interrupted: std.atomic.Value(bool) = .init(false);

fn installSignalCleanup() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalCleanup },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn signalCleanup(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);
    for (&cleanup_groups) |*group| {
        const id = group.load(.monotonic);
        if (id != 0) _ = std.os.linux.kill(-id, .KILL);
    }
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) return error.E2eRequiresLinux;
    try process_cleanup.enable();
    defer _ = process_cleanup.finish(init.io) catch |err| {
        std.log.err("event=e2e_cleanup_failed error={s}", .{@errorName(err)});
    };
    installSignalCleanup();
    const values = try init.minimal.args.toSlice(init.arena.allocator());
    const arguments = try parse(values);
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_result = std.os.linux.getcwd(&cwd_buffer, cwd_buffer.len);
    if (std.os.linux.errno(cwd_result) != .SUCCESS) return error.CurrentDirectoryUnavailable;
    const cwd_length: usize = cwd_result - 1;
    const server = try std.fs.path.join(init.gpa, &.{ cwd_buffer[0..cwd_length], arguments.server });
    defer init.gpa.free(server);
    const client = try std.fs.path.join(init.gpa, &.{ cwd_buffer[0..cwd_length], arguments.client });
    defer init.gpa.free(client);
    const artifacts = try std.fs.path.join(init.gpa, &.{ cwd_buffer[0..cwd_length], arguments.artifacts });
    defer init.gpa.free(artifacts);
    if (std.mem.eql(u8, arguments.scenario, "all")) {
        const skyblock_relative = arguments.skyblock_server orelse return error.MissingSkyblockServer;
        const skyblock_server = try std.fs.path.join(init.gpa, &.{ cwd_buffer[0..cwd_length], skyblock_relative });
        defer init.gpa.free(skyblock_server);
        try runScenario(init, server, client, artifacts, .chunks, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .chunks_flat, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .chunks_persisted, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .steady, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .reload, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .reload_failure, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .fatal_storage, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .auth_success, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .auth_reject, arguments.capture_bytes);
        try runScenario(init, server, client, artifacts, .auth_timeout, arguments.capture_bytes);
        try runScenario(init, skyblock_server, client, artifacts, .skyblock_chat, arguments.capture_bytes);
        return;
    }
    const scenario: Scenario = if (std.mem.eql(u8, arguments.scenario, "chunks"))
        .chunks
    else if (std.mem.eql(u8, arguments.scenario, "skyblock-chat"))
        .skyblock_chat
    else if (std.mem.eql(u8, arguments.scenario, "chunks-flat"))
        .chunks_flat
    else if (std.mem.eql(u8, arguments.scenario, "chunks-full"))
        .chunks_full
    else if (std.mem.eql(u8, arguments.scenario, "chunks-persisted")) blk: {
        try runScenario(init, server, client, artifacts, .chunks_prepare_flat, arguments.capture_bytes);
        break :blk .chunks_persisted;
    } else if (std.mem.eql(u8, arguments.scenario, "chunks-varied-disk")) blk: {
        try runScenario(init, server, client, artifacts, .chunks_prepare, arguments.capture_bytes);
        break :blk .chunks_varied_disk;
    } else if (std.mem.eql(u8, arguments.scenario, "steady"))
        .steady
    else if (std.mem.eql(u8, arguments.scenario, "fatal-storage"))
        .fatal_storage
    else if (std.mem.eql(u8, arguments.scenario, "auth-success"))
        .auth_success
    else if (std.mem.eql(u8, arguments.scenario, "auth-reject"))
        .auth_reject
    else if (std.mem.eql(u8, arguments.scenario, "auth-timeout"))
        .auth_timeout
    else if (std.mem.eql(u8, arguments.scenario, "reload"))
        .reload
    else if (std.mem.eql(u8, arguments.scenario, "reload-failure"))
        .reload_failure
    else
        return error.UnknownScenario;
    try runScenario(init, server, client, artifacts, scenario, arguments.capture_bytes);
}

fn runScenario(init: std.process.Init, source_server: []const u8, client_dir: []const u8, artifact_root: []const u8, scenario: Scenario, capture_bytes: ?u64) !void {
    const io = init.io;
    if (interrupted.load(.acquire)) return error.Interrupted;
    defer _ = process_cleanup.finish(io) catch |err| {
        std.log.err("event=e2e_cleanup_failed error={s}", .{@errorName(err)});
    };
    const allocator = init.gpa;
    const name = switch (scenario) {
        .chunks => "chunks",
        .chunks_full => "chunks-full",
        .chunks_flat => "chunks-flat",
        .chunks_persisted => "chunks-persisted",
        .chunks_prepare => "chunks-prepare",
        .chunks_prepare_flat => "chunks-prepare-flat",
        .chunks_varied_disk => "chunks-varied-disk",
        .steady => "steady",
        .fatal_storage => "fatal-storage",
        .auth_success => "auth-success",
        .auth_reject => "auth-reject",
        .auth_timeout => "auth-timeout",
        .reload => "reload",
        .reload_failure => "reload-failure",
        .skyblock_chat => "skyblock-chat",
    };
    const artifacts = try std.fs.path.join(allocator, &.{ artifact_root, name });
    defer allocator.free(artifacts);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, artifacts) catch {};
    try cwd.createDirPath(io, artifacts);
    const server_dir = if (fixtureFor(scenario)) |fixture|
        try std.fs.path.join(allocator, &.{ artifact_root, fixtureArtifactName(fixture), "server" })
    else
        try std.fs.path.join(allocator, &.{ artifacts, "server" });
    defer allocator.free(server_dir);
    try cwd.createDirPath(io, server_dir);
    const executable = try std.fs.path.join(allocator, &.{ artifacts, "lightning-rod-server" });
    defer allocator.free(executable);
    try std.Io.Dir.copyFileAbsolute(source_server, executable, io, .{ .replace = true });
    const stdout_path = try std.fs.path.join(allocator, &.{ artifacts, "server.stdout.log" });
    defer allocator.free(stdout_path);
    const stderr_path = try std.fs.path.join(allocator, &.{ artifacts, "server.stderr.log" });
    defer allocator.free(stderr_path);
    const stdout = try cwd.createFile(io, stdout_path, .{ .truncate = true });
    defer stdout.close(io);
    const stderr = try cwd.createFile(io, stderr_path, .{ .truncate = true });
    defer stderr.close(io);
    var server = Child{ .process = try std.process.spawn(io, .{
        .argv = switch (scenario) {
            .auth_success => &.{ executable, "--flat", "--auth-success" },
            .auth_reject => &.{ executable, "--flat", "--auth-reject" },
            .auth_timeout => &.{ executable, "--flat", "--auth-timeout" },
            .fatal_storage => &.{ executable, "--flat", "--fatal-storage" },
            .chunks_flat, .chunks_persisted, .steady => &.{ executable, "--flat" },
            .chunks_prepare => &.{ executable, "--prepare-persisted" },
            .chunks_prepare_flat => &.{ executable, "--flat", "--prepare-persisted" },
            else => &.{executable},
        },
        .cwd = .{ .path = server_dir },
        .stdin = .ignore,
        .stdout = .{ .file = stdout },
        .stderr = .{ .file = stderr },
        .pgid = 0,
    }), .cleanup_slot = 0 };
    cleanup_groups[0].store(server.process.id.?, .release);
    var server_stopped = false;
    defer if (!server_stopped) server.stop(io);
    if (isFixturePreparation(scenario)) {
        try waitForPersistedFixture(io, allocator, cwd, stdout_path);
        const term = try server.shutdown(io);
        server_stopped = true;
        switch (term) {
            .exited => |code| if (code != 0) return error.FixtureShutdownFailed,
            else => return error.FixtureShutdownFailed,
        }
        return;
    }
    try reserveServerCore();
    var xvfb = Child{ .process = try std.process.spawn(io, .{
        .argv = &.{ "Xvfb", ":97", "-screen", "0", "1280x720x24", "-nolisten", "tcp" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }), .cleanup_slot = 1 };
    cleanup_groups[1].store(xvfb.process.id.?, .release);
    defer xvfb.stop(io);
    try std.Io.sleep(io, .fromMilliseconds(1500), .awake);
    const peers: []const []const u8 = if (scenario == .reload or scenario == .reload_failure or scenario == .skyblock_chat) &.{ "alice", "bob" } else &.{"alice"};
    var children: [2]Child = undefined;
    var child_count: usize = 0;
    defer for (children[0..child_count]) |*child| child.stop(io);
    for (peers) |peer| {
        children[child_count] = .{ .process = try spawnClient(init, client_dir, artifacts, name, peer, peers, 40 + child_count * 100, capture_bytes), .cleanup_slot = child_count + 2 };
        cleanup_groups[child_count + 2].store(children[child_count].process.id.?, .release);
        child_count += 1;
    }
    const started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const deadline_seconds: u64 = if (scenario == .chunks_full) 1200 else 180;
    const deadline = started + deadline_seconds * std.time.ns_per_s;
    var reload_allowed = scenario != .reload and scenario != .reload_failure;
    var steady_measured = scenario != .steady;
    var server_memory = ServerMemory{};
    waiting: while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < deadline) {
        server_memory.sample(io, server.process.id.?);
        if (interrupted.load(.monotonic)) return error.Interrupted;
        if (!reload_allowed and try allMarkers(io, allocator, artifacts, peers, ".ready")) {
            if (scenario == .reload_failure) try cwd.deleteFile(io, executable);
            try writeMarker(io, allocator, artifacts, "allow-reload");
            reload_allowed = true;
        }
        if (scenario == .steady and !steady_measured) {
            const log = cwd.readFileAlloc(io, stdout_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            if (log) |value| {
                defer allocator.free(value);
                if (std.mem.indexOf(u8, value, "event=e2e_steady_state samples=100") != null) {
                    try writeMarker(io, allocator, artifacts, "steady-measured");
                    steady_measured = true;
                }
            }
        }
        if (steady_measured and try allMarkers(io, allocator, artifacts, peers, ".result")) break;
        for (peers) |peer| {
            const path = try markerPath(allocator, artifacts, peer, ".result");
            defer allocator.free(path);
            const result = cwd.readFileAlloc(io, path, allocator, .limited(1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(result);
            if (std.mem.startsWith(u8, result, "FAIL ")) break :waiting;
        }
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    } else return error.EndToEndTimeout;
    if (scenario != .steady) {
        try std.Io.sleep(io, .fromMilliseconds(1_200), .awake);
    }
    var clients_passed = true;
    for (peers) |peer| {
        const path = try markerPath(allocator, artifacts, peer, ".result");
        defer allocator.free(path);
        const result = cwd.readFileAlloc(io, path, allocator, .limited(1024)) catch |err| switch (err) {
            error.FileNotFound => {
                clients_passed = false;
                continue;
            },
            else => return err,
        };
        defer allocator.free(result);
        if (!std.mem.startsWith(u8, result, "PASS ")) clients_passed = false;
    }
    var server_exit_code: ?u32 = null;
    var server_termination: ?[]const u8 = null;
    var graceful_shutdown_ms: ?u64 = null;
    if (scenario == .chunks_flat or scenario == .skyblock_chat) {
        const shutdown_started = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        const term = try server.shutdown(io);
        graceful_shutdown_ms = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - shutdown_started, std.time.ns_per_ms));
        server_termination = @tagName(term);
        switch (term) {
            .exited => |code| {
                server_exit_code = code;
                if (code != 0) return error.FixtureShutdownFailed;
            },
            else => return error.FixtureShutdownFailed,
        }
    }
    if (scenario == .fatal_storage) {
        const term = try server.process.wait(io);
        server_termination = @tagName(term);
        switch (term) {
            .exited => |code| server_exit_code = code,
            else => {},
        }
    }
    try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    const server_log = try cwd.readFileAlloc(io, stdout_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(server_log);
    var deadline_violations: usize = 0;
    var maximum_observed_tick_us: u64 = 0;
    var lines = std.mem.splitScalar(u8, server_log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "event=core_tick_deadline_exceeded") != null) {
            deadline_violations += 1;
            maximum_observed_tick_us = @max(maximum_observed_tick_us, field(line, "elapsed_us=") orelse 0);
        } else if (std.mem.indexOf(u8, line, "event=core_tick_profile") != null) {
            maximum_observed_tick_us = @max(maximum_observed_tick_us, field(line, "max_us=") orelse 0);
        }
    }
    const tick_deadline_passed = deadline_violations == 0 and maximum_observed_tick_us <= 50_000;
    var passed = clients_passed and tick_deadline_passed;
    var persisted_streaming_passed: ?bool = null;
    if (scenario == .chunks_persisted or scenario == .chunks_varied_disk) {
        const profile = lastEvent(server_log, "event=chunk_stream_profile");
        persisted_streaming_passed = if (profile) |record|
            (field(record, "generation_us=") orelse 1) == 0 and
                (field(record, "generation_calls=") orelse 1) == 0 and
                (field(record, "generated=") orelse 1) == 0 and
                (field(record, "encoded_chunks=") orelse 0) >= 3725
        else
            false;
        passed = passed and persisted_streaming_passed.?;
    }
    var authentication_passed: ?bool = null;
    var fatal_shutdown_passed: ?bool = null;
    var steady_state_passed: ?bool = null;
    if (scenario == .auth_success or scenario == .auth_reject or scenario == .auth_timeout) {
        const expected = switch (scenario) {
            .auth_success => "event=e2e_auth_result accepted=true",
            .auth_reject => "event=e2e_auth_result accepted=false",
            .auth_timeout => "event=e2e_auth_canceled",
            else => unreachable,
        };
        authentication_passed = std.mem.indexOf(u8, server_log, "event=e2e_auth_verifying") != null and
            std.mem.indexOf(u8, server_log, expected) != null and
            (scenario == .auth_success or std.mem.indexOf(u8, server_log, "event=core_player_attached") == null);
        passed = passed and authentication_passed.?;
    }
    if (scenario == .fatal_storage) {
        fatal_shutdown_passed = server_exit_code != null and server_exit_code.? != 0 and
            std.mem.indexOf(u8, server_log, "event=fatal_shutdown error=CoreFailed checkpoint=false") != null and
            std.mem.indexOf(u8, server_log, "event=e2e_unexpected_checkpoint") == null;
        passed = passed and fatal_shutdown_passed.?;
    }
    var steady_average_ns: u64 = 0;
    var steady_maximum_ns: u64 = 0;
    var steady_read_bytes: u64 = 0;
    var steady_write_bytes: u64 = 0;
    var steady_persistence_submissions: u64 = 0;
    if (scenario == .steady) {
        steady_state_passed = false;
        const record = lastEvent(server_log, "event=e2e_steady_state");
        if (record == null) {
            passed = false;
        } else {
            steady_average_ns = field(record.?, "avg_ns=") orelse 0;
            steady_maximum_ns = field(record.?, "max_ns=") orelse std.math.maxInt(u64);
            steady_read_bytes = field(record.?, "persistence_read_bytes=") orelse 0;
            steady_write_bytes = field(record.?, "persistence_write_bytes=") orelse 0;
            steady_persistence_submissions = field(record.?, "persistence_submissions=") orelse 0;
            steady_state_passed = std.mem.indexOf(u8, record.?, "samples=100") != null and
                field(record.?, "simulation_distance=") == 8 and
                field(record.?, "entity=") == 289 and
                field(record.?, "block=") == 72 and
                field(record.?, "full=") == 80 and
                std.mem.indexOf(u8, record.?, "invalid=0") != null and
                std.mem.indexOf(u8, record.?, "admission_overflow=false") != null and
                std.mem.indexOf(u8, server_log, "event=chunk_stream_profile slot=0 chunks=3725") != null and
                steady_maximum_ns <= 50 * std.time.ns_per_ms;
        }
        passed = passed and steady_state_passed.?;
    }
    const elapsed = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - started;
    const summary_path = try std.fs.path.join(allocator, &.{ artifacts, "summary.json" });
    defer allocator.free(summary_path);
    const summary = try std.json.Stringify.valueAlloc(allocator, .{
        .scenario = name,
        .passed = passed,
        .clients_passed = clients_passed,
        .tick_deadline_passed = tick_deadline_passed,
        .persisted_streaming_passed = persisted_streaming_passed,
        .deadline_violations = deadline_violations,
        .maximum_observed_tick_us = maximum_observed_tick_us,
        .authentication_passed = authentication_passed,
        .fatal_shutdown_passed = fatal_shutdown_passed,
        .server_exit_code = server_exit_code,
        .server_termination = server_termination,
        .graceful_shutdown_ms = graceful_shutdown_ms,
        .steady_state_passed = steady_state_passed,
        .elapsed_ms = @divTrunc(elapsed, std.time.ns_per_ms),
        .steady_average_ns = steady_average_ns,
        .steady_maximum_ns = steady_maximum_ns,
        .steady_target_ns = @as(u64, 200_000),
        .steady_target_met = steady_average_ns != 0 and steady_average_ns <= 200_000,
        .persistence_read_bytes = steady_read_bytes,
        .persistence_write_bytes = steady_write_bytes,
        .persistence_submissions = steady_persistence_submissions,
        .server_last_rss_bytes = server_memory.last_rss_bytes,
        .server_max_hwm_bytes = server_memory.maximum_hwm_bytes,
        .server_rss_available = server_memory.rss_available,
        .server_hwm_available = server_memory.hwm_available,
    }, .{});
    defer allocator.free(summary);
    const summary_file = try cwd.createFile(io, summary_path, .{ .truncate = true });
    defer summary_file.close(io);
    try summary_file.writeStreamingAll(io, summary);
    if (!passed) return error.EndToEndAssertionFailed;
}

fn fixtureFor(scenario: Scenario) ?Fixture {
    return switch (scenario) {
        .chunks_prepare, .chunks_varied_disk => .vanilla,
        .chunks_prepare_flat, .chunks_persisted => .flat,
        else => null,
    };
}

fn fixtureArtifactName(fixture: Fixture) []const u8 {
    return switch (fixture) {
        .vanilla => "chunks-prepare",
        .flat => "chunks-prepare-flat",
    };
}

fn isFixturePreparation(scenario: Scenario) bool {
    return scenario == .chunks_prepare or scenario == .chunks_prepare_flat;
}

fn reserveServerCore() !void {
    var allowed = try std.posix.sched_getaffinity(0);
    if (std.os.linux.CPU_COUNT(allowed) <= 2) return;
    var removed: usize = 0;
    for (&allowed) |*word| {
        while (word.* != 0 and removed != 2) : (removed += 1)
            word.* &= word.* - 1;
        if (removed == 2) break;
    }
    try std.os.linux.sched_setaffinity(0, &allowed);
}

fn waitForPersistedFixture(io: std.Io, allocator: std.mem.Allocator, cwd: std.Io.Dir, stdout_path: []const u8) !void {
    const timeout_ns: u64 = 30 * 60 * std.time.ns_per_s;
    const deadline = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds + timeout_ns;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds < deadline) {
        if (interrupted.load(.monotonic)) return error.Interrupted;
        const log = cwd.readFileAlloc(io, stdout_path, allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (log) |value| {
            defer allocator.free(value);
            if (std.mem.indexOf(u8, value, "event=e2e_persisted_fixture_ready chunks=3725") != null) return;
            if (std.mem.indexOf(u8, value, "event=fatal_shutdown") != null) return error.FixturePreparationFailed;
        }
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    }
    return error.FixturePreparationTimedOut;
}

fn spawnClient(init: std.process.Init, client_dir: []const u8, artifacts: []const u8, scenario: []const u8, peer: []const u8, peers: []const []const u8, connect_tick: usize, capture_bytes: ?u64) !std.process.Child {
    const allocator = init.gpa;
    const events = try markerPath(allocator, artifacts, peer, ".events.jsonl");
    defer allocator.free(events);
    const capture = try markerPath(allocator, artifacts, peer, ".packets.mcc");
    defer allocator.free(capture);
    const run_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ scenario, peer });
    defer allocator.free(run_name);
    const run_relative = try std.fs.path.join(allocator, &.{ ".e2e", run_name });
    defer allocator.free(run_relative);
    const run_dir = try std.fs.path.join(allocator, &.{ client_dir, run_relative });
    defer allocator.free(run_dir);
    try std.Io.Dir.cwd().createDirPath(init.io, run_dir);
    const options_path = try std.fs.path.join(allocator, &.{ run_dir, "options.txt" });
    defer allocator.free(options_path);
    const options = try std.Io.Dir.cwd().createFile(init.io, options_path, .{ .truncate = true });
    defer options.close(init.io);
    try options.writeStreamingAll(init.io, "version:4440\n" ++
        "onboardAccessibility:true\n" ++
        "skipMultiplayerWarning:true\n" ++
        "joinedFirstServer:true\n" ++
        "tutorialStep:none\n" ++
        "renderDistance:32\n" ++
        "simulationDistance:12\n" ++
        "enableVsync:false\n" ++
        "maxFps:120\n");
    const peer_list = try std.mem.join(allocator, ",", peers);
    defer allocator.free(peer_list);
    const event_arg = try std.fmt.allocPrint(allocator, "-Dmcc.events={s}", .{events});
    defer allocator.free(event_arg);
    const output_arg = try std.fmt.allocPrint(allocator, "-Dmcc.output={s}", .{capture});
    defer allocator.free(output_arg);
    const artifacts_arg = try std.fmt.allocPrint(allocator, "-Dmcc.artifacts={s}", .{artifacts});
    defer allocator.free(artifacts_arg);
    const peer_arg = try std.fmt.allocPrint(allocator, "-Dmcc.peer={s}", .{peer});
    defer allocator.free(peer_arg);
    const peers_arg = try std.fmt.allocPrint(allocator, "-Dmcc.expectedPeers={s}", .{peer_list});
    defer allocator.free(peers_arg);
    const scenario_arg = try std.fmt.allocPrint(allocator, "-Dmcc.scenario={s}", .{scenario});
    defer allocator.free(scenario_arg);
    const connect_arg = try std.fmt.allocPrint(allocator, "-Dmcc.connectTick={d}", .{connect_tick});
    defer allocator.free(connect_arg);
    const chunk_scenario = std.mem.startsWith(u8, scenario, "chunks") or std.mem.eql(u8, scenario, "steady");
    const radius_arg = if (chunk_scenario) "-Dmcc.minimumRadius=2" else "-Dmcc.minimumRadius=0";
    const performance = std.mem.eql(u8, scenario, "chunks-flat") or std.mem.eql(u8, scenario, "chunks-persisted") or std.mem.eql(u8, scenario, "chunks-varied-disk");
    const full = performance or std.mem.eql(u8, scenario, "chunks-full") or std.mem.eql(u8, scenario, "steady");
    const target_arg = if (full) "-Dmcc.targetChunks=3725" else "-Dmcc.targetChunks=256";
    const deadline_arg = if (performance or std.mem.eql(u8, scenario, "steady")) "-Dmcc.maximumStreamTicks=100" else "-Dmcc.maximumStreamTicks=0";
    const soak_arg = if (std.mem.eql(u8, scenario, "auth-success"))
        "-Dmcc.minimumSoakTicks=40"
    else if (std.mem.eql(u8, scenario, "chunks"))
        "-Dmcc.minimumSoakTicks=200"
    else
        "-Dmcc.minimumSoakTicks=0";
    const stall_arg = if (std.mem.eql(u8, scenario, "chunks"))
        "-Dmcc.maximumStallTicks=600"
    else
        "-Dmcc.maximumStallTicks=100";
    const timeout_arg = if (std.mem.eql(u8, scenario, "chunks-full"))
        "-Dmcc.timeoutTicks=18000"
    else if (std.mem.eql(u8, scenario, "steady"))
        "-Dmcc.timeoutTicks=3600"
    else
        "-Dmcc.timeoutTicks=2400";
    const capture_arg = try std.fmt.allocPrint(allocator, "-Dmcc.captureBytes={d}", .{captureBytes(scenario, capture_bytes)});
    defer allocator.free(capture_arg);
    const run_arg = try std.fmt.allocPrint(allocator, "-Dmcc.runDir={s}", .{run_relative});
    defer allocator.free(run_arg);
    var environment = try init.environ_map.clone(allocator);
    defer environment.deinit();
    try environment.put("DISPLAY", ":97");
    return std.process.spawn(init.io, .{
        .argv = &.{ "gradle", "--no-daemon", "-p", client_dir, "runClient", "-Dmcc.server=127.0.0.1:25575", event_arg, output_arg, artifacts_arg, peer_arg, peers_arg, scenario_arg, radius_arg, target_arg, deadline_arg, soak_arg, stall_arg, timeout_arg, capture_arg, connect_arg, run_arg },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
}

fn lastEvent(log: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.lastIndexOf(u8, log, marker) orelse return null;
    const end = std.mem.indexOfScalarPos(u8, log, start, '\n') orelse log.len;
    return log[start..end];
}

fn field(record: []const u8, name: []const u8) ?u64 {
    const start = (std.mem.indexOf(u8, record, name) orelse return null) + name.len;
    var end = start;
    while (end < record.len and std.ascii.isDigit(record[end])) end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(u64, record[start..end], 10) catch null;
}

fn allMarkers(io: std.Io, allocator: std.mem.Allocator, artifacts: []const u8, peers: []const []const u8, suffix: []const u8) !bool {
    for (peers) |peer| {
        const path = try markerPath(allocator, artifacts, peer, suffix);
        defer allocator.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

fn markerPath(allocator: std.mem.Allocator, artifacts: []const u8, peer: []const u8, suffix: []const u8) ![]u8 {
    const name = try std.mem.concat(allocator, u8, &.{ peer, suffix });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ artifacts, name });
}

fn writeMarker(io: std.Io, allocator: std.mem.Allocator, artifacts: []const u8, name: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ artifacts, name });
    defer allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "go\n");
}

fn parse(arguments: []const [:0]const u8) !Arguments {
    var result = Arguments{ .server = "", .client = "", .artifacts = "artifacts", .scenario = "all" };
    var index: usize = 1;
    while (index < arguments.len) : (index += 2) {
        if (index + 1 >= arguments.len) return error.MissingArgumentValue;
        const key = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, key, "--server")) result.server = value else if (std.mem.eql(u8, key, "--skyblock-server")) result.skyblock_server = value else if (std.mem.eql(u8, key, "--client")) result.client = value else if (std.mem.eql(u8, key, "--artifacts")) result.artifacts = value else if (std.mem.eql(u8, key, "--scenario")) result.scenario = value else if (std.mem.eql(u8, key, "--capture-bytes")) {
            const capture_bytes = std.fmt.parseInt(u64, value, 10) catch return error.InvalidCaptureBytes;
            if (capture_bytes > maximum_capture_bytes) return error.InvalidCaptureBytes;
            result.capture_bytes = capture_bytes;
        } else return error.UnknownArgument;
    }
    if (result.server.len == 0 or result.client.len == 0) return error.MissingRequiredArgument;
    return result;
}

fn captureBytes(scenario: []const u8, override: ?u64) u64 {
    return override orelse if (std.mem.eql(u8, scenario, "chunks-full")) 0 else default_capture_bytes;
}

test "server memory status parser reports valid and unavailable fields" {
    const valid = parseServerMemoryStatus(
        "Name:\tlightning-rod\n" ++
            "VmRSS:\t  123 kB\n" ++
            "VmHWM:\t456 kB\n",
    );
    try std.testing.expectEqual(@as(?u64, 123 * 1024), valid.rss_bytes);
    try std.testing.expectEqual(@as(?u64, 456 * 1024), valid.hwm_bytes);

    const invalid = parseServerMemoryStatus(
        "VmRSS:\tinvalid kB\n" ++
            "VmHWM:\t456 bytes\n",
    );
    try std.testing.expectEqual(@as(?u64, null), invalid.rss_bytes);
    try std.testing.expectEqual(@as(?u64, null), invalid.hwm_bytes);
}

test "capture override preserves defaults and permits disabled capture" {
    try std.testing.expectEqual(@as(u64, 0), captureBytes("chunks-full", null));
    try std.testing.expectEqual(@as(u64, default_capture_bytes), captureBytes("chunks-flat", null));
    try std.testing.expectEqual(@as(u64, 0), captureBytes("chunks-flat", 0));
}
