const std = @import("std");
const profile = @import("profile");
const linux = std.os.linux;

const Cache = enum { warm, cold };
const Phases = struct {
    initialize_ns: u64 = 0,
    storage_ns: u64 = 0,
    recovery_ns: u64 = 0,
    sessions_ns: u64 = 0,
    simulation_ns: u64 = 0,
    checkpoint_ns: u64 = 0,
    submit_ns: u64 = 0,
    close_hooks_ns: u64 = 0,
    close_wait_ns: u64 = 0,
    durability_wait_ns: u64 = 0,
    durability_cpu_ns: u64 = 0,
};
const Sample = struct {
    launch_to_ready_ns: u64,
    launch_to_entry_ns: u64,
    entry_to_ready_ns: u64,
    main_cpu_ns: u64,
    signal_to_exit_ns: u64,
    phases: Phases,
};
const Distribution = struct { minimum_ns: u64, median_ns: u64, p95_ns: u64, maximum_ns: u64 };

fn distribution(values: []u64) Distribution {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return .{ .minimum_ns = values[0], .median_ns = values[values.len / 2], .p95_ns = values[(values.len * 95 + 99) / 100 - 1], .maximum_ns = values[values.len - 1] };
}

fn waitReadable(io: std.Io, fd: i32, milliseconds: u32) !void {
    const deadline = std.Io.Clock.now(.awake, io).nanoseconds + @as(i96, milliseconds) * std.time.ns_per_ms;
    while (true) {
        const left = deadline - std.Io.Clock.now(.awake, io).nanoseconds;
        if (left <= 0) return error.Timeout;
        var descriptor: linux.pollfd = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        const result = linux.poll(@ptrCast(&descriptor), 1, @intCast(@divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.Timeout;
                if (descriptor.revents & linux.POLL.NVAL != 0) return error.InvalidDescriptor;
                return;
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn phasesRead(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Phases {
    const Snapshot = struct { name: []const u8, count: u64, value: u64 };
    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var result: Phases = .{};
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".snapshot.jsonl")) continue;
        const file = try directory.openFile(io, entry.name, .{});
        defer file.close(io);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &buffer);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            const parsed = try std.json.parseFromSlice(Snapshot, allocator, line, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            const sample = parsed.value;
            if (sample.count == 0) continue;
            if (std.mem.eql(u8, sample.name, "server.initialize")) result.initialize_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "server.initialize.storage")) result.storage_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "storage.initialize.recovery")) result.recovery_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "server.initialize.sessions")) result.sessions_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "server.initialize.simulation")) result.simulation_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "simulation.checkpoint")) result.checkpoint_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "simulation.submit")) result.submit_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "simulation.close.hooks")) result.close_hooks_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "simulation.close.wait")) result.close_wait_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "storage.durability_wait")) result.durability_wait_ns = sample.value;
            if (std.mem.eql(u8, sample.name, "storage.durability_wait.cpu")) result.durability_cpu_ns = sample.value;
        }
    }
    if (result.initialize_ns == 0 or result.storage_ns == 0) return error.StartupMetricsMissing;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return error.MissingServer;
    var source: ?[]const u8 = null;
    var output: []const u8 = ".zig-cache/startup-bench";
    var repeats: usize = 10;
    var cache: Cache = .warm;
    var shutdown_delay_ms: u32 = 0;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 == args.len) return error.MissingArgument;
        if (std.mem.eql(u8, args[i], "--world")) {
            source = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--output")) {
            output = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--repeats")) {
            repeats = try std.fmt.parseInt(usize, args[i + 1], 10);
        } else if (std.mem.eql(u8, args[i], "--cache")) {
            cache = std.meta.stringToEnum(Cache, args[i + 1]) orelse return error.InvalidCacheMode;
        } else if (std.mem.eql(u8, args[i], "--shutdown-delay-ms")) {
            shutdown_delay_ms = try std.fmt.parseInt(u32, args[i + 1], 10);
        } else return error.UnknownArgument;
    }
    if (repeats == 0 or repeats > 100) return error.InvalidRepeatCount;
    if (shutdown_delay_ms > 1000) return error.InvalidShutdownDelay;
    const source_path = try cwd.realPathFileAlloc(io, source orelse return error.MissingWorld, allocator);
    const source_file = try cwd.openFile(io, source_path, .{});
    defer source_file.close(io);
    if (linux.errno(linux.flock(source_file.handle, std.posix.LOCK.SH | std.posix.LOCK.NB)) != .SUCCESS) return error.WorldInUse;
    const database_bytes = (try source_file.stat(io)).size;
    if (database_bytes == 0) return error.EmptyWorld;
    try cwd.createDirPath(io, output);
    output = try cwd.realPathFileAlloc(io, output, allocator);
    if (std.mem.startsWith(u8, source_path, output) and source_path.len > output.len and source_path[output.len] == '/') return error.WorldInsideBenchmarkOutput;
    const server = try cwd.realPathFileAlloc(io, args[1], allocator);
    const world = try std.fs.path.join(allocator, &.{ output, "world" });
    const metrics = try std.fs.path.join(allocator, &.{ output, "metrics" });
    const world_arg = try std.fmt.allocPrint(allocator, "--world={s}", .{world});
    const metrics_arg = try std.fmt.allocPrint(allocator, "--metrics-directory={s}", .{metrics});
    const samples = try allocator.alloc(Sample, repeats);
    var wal_bytes: u64 = 0;
    for (samples, 0..) |*sample, round| {
        try cwd.deleteTree(io, metrics);
        try cwd.createDirPath(io, metrics);
        for ([_][]const u8{ "", ".wal", ".wal.next" }) |suffix| {
            const destination = try std.fmt.allocPrint(allocator, "{s}{s}", .{ world, suffix });
            if (std.mem.eql(u8, suffix, ".wal.next")) {
                cwd.deleteFile(io, destination) catch |err| if (err != error.FileNotFound) return err;
                continue;
            }
            const from = try std.fmt.allocPrint(allocator, "{s}{s}", .{ source_path, suffix });
            cwd.copyFile(from, cwd, destination, io, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    if (suffix.len == 0) return err;
                    cwd.deleteFile(io, destination) catch |delete_error| if (delete_error != error.FileNotFound) return delete_error;
                    continue;
                },
                else => return err,
            };
            const file = try cwd.openFile(io, destination, .{ .mode = .read_write });
            defer file.close(io);
            if (suffix.len != 0) wal_bytes = (try file.stat(io)).size;
            try file.sync(io);
            if (cache == .warm) {
                // Reflink copies do not populate the destination inode's page cache.
                var buffer: [64 * 1024]u8 = undefined;
                var offset: u64 = 0;
                while (true) {
                    const count = try file.readPositionalAll(io, &buffer, offset);
                    offset += count;
                    if (count < buffer.len) break;
                }
            }
            if (cache == .cold and linux.errno(linux.fadvise(file.handle, 0, 0, linux.POSIX_FADV.DONTNEED)) != .SUCCESS) return error.CacheAdviceFailed;
        }
        const log_path = try std.fs.path.join(allocator, &.{ output, "server.log" });
        const log = try cwd.createFile(io, log_path, .{});
        defer log.close(io);
        const launched = std.Io.Clock.now(.awake, io).nanoseconds;
        var child = try std.process.spawn(io, .{ .argv = &.{ server, "--startup-report", "--port=0", world_arg, metrics_arg }, .cwd = .{ .path = output }, .stdin = .ignore, .stdout = .pipe, .stderr = .{ .file = log } });
        defer child.kill(io);
        const descriptor = linux.pidfd_open(child.id.?, 0);
        if (linux.errno(descriptor) != .SUCCESS) return error.ProcessHandleFailed;
        const pidfile: std.Io.File = .{ .handle = @intCast(descriptor), .flags = .{ .nonblocking = false } };
        defer pidfile.close(io);
        try waitReadable(io, child.stdout.?.handle, 30_000);
        var buffer: [64]u8 = undefined;
        var reader = child.stdout.?.reader(io, &buffer);
        const report = profile.Startup.Report.read(&reader.interface) catch |err| {
            std.log.err("event=startup_report_failed reason={s} log={s}", .{ @errorName(err), log_path });
            return err;
        };
        if (report.entered_ns < launched) return error.InvalidStartupReport;
        if (shutdown_delay_ms != 0) try std.Io.sleep(io, .fromMilliseconds(shutdown_delay_ms), .awake);
        const stopping = std.Io.Clock.now(.awake, io).nanoseconds;
        const signal = linux.errno(linux.kill(child.id.?, .INT));
        if (signal != .SUCCESS and signal != .SRCH) return error.ShutdownSignalFailed;
        try waitReadable(io, pidfile.handle, 10_000);
        const exited = std.Io.Clock.now(.awake, io).nanoseconds;
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) return error.ServerFailed;
        sample.* = .{ .launch_to_ready_ns = @intCast(report.ready_ns - launched), .launch_to_entry_ns = @intCast(report.entered_ns - launched), .entry_to_ready_ns = @intCast(report.ready_ns - report.entered_ns), .main_cpu_ns = report.cpu_ns, .signal_to_exit_ns = @intCast(exited - stopping), .phases = try phasesRead(init.gpa, io, metrics) };
        std.debug.print("startup {d}/{d}: total={d:.3}ms entry={d:.3}ms initialization={d:.3}ms cpu={d:.3}ms shutdown={d:.3}ms\n", .{ round + 1, repeats, @as(f64, @floatFromInt(sample.launch_to_ready_ns)) / 1e6, @as(f64, @floatFromInt(sample.launch_to_entry_ns)) / 1e6, @as(f64, @floatFromInt(sample.entry_to_ready_ns)) / 1e6, @as(f64, @floatFromInt(sample.main_cpu_ns)) / 1e6, @as(f64, @floatFromInt(sample.signal_to_exit_ns)) / 1e6 });
    }
    const values = try allocator.alloc(u64, samples.len);
    for (samples, values) |sample, *value| value.* = sample.launch_to_ready_ns;
    const total = distribution(values);
    for (samples, values) |sample, *value| value.* = sample.launch_to_entry_ns;
    const entry = distribution(values);
    for (samples, values) |sample, *value| value.* = sample.entry_to_ready_ns;
    const startup = distribution(values);
    for (samples, values) |sample, *value| value.* = sample.main_cpu_ns;
    const cpu = distribution(values);
    for (samples, values) |sample, *value| value.* = sample.signal_to_exit_ns;
    const shutdown = distribution(values);
    const result_path = try std.fs.path.join(allocator, &.{ output, "results.json" });
    const file = try cwd.createFile(io, result_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try std.json.Stringify.value(.{ .world = source_path, .database_bytes = database_bytes, .wal_bytes = wal_bytes, .filesystem_cache = cache, .shutdown_delay_ms = shutdown_delay_ms, .repeats = repeats, .launch_to_ready = total, .launch_to_entry = entry, .entry_to_ready = startup, .main_cpu = cpu, .signal_to_exit = shutdown, .samples = samples }, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    std.debug.print("startup median={d:.3}ms p95={d:.3}ms results={s}\n", .{ @as(f64, @floatFromInt(total.median_ns)) / 1e6, @as(f64, @floatFromInt(total.p95_ns)) / 1e6, result_path });
    std.debug.print("shutdown median={d:.3}ms p95={d:.3}ms\n", .{ @as(f64, @floatFromInt(shutdown.median_ns)) / 1e6, @as(f64, @floatFromInt(shutdown.p95_ns)) / 1e6 });
}
