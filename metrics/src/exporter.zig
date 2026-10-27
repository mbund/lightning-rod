const std = @import("std");
const metrics = @import("metrics.zig");
const system = @import("system");

pub const Exporter = struct {
    pub const id = "lightning_rod:metrics_export";

    pub const Configuration = struct {
        directory: []const u8,
        stop_file: ?[]const u8 = null,
        snapshot_capacity: usize = 4096,
        io_mode: system.FileBatch.Mode = .uring,
    };
    const capacity = 4096;
    const State = struct {
        file: std.Io.File,
        path: []u8,
        path_storage: []u8 = &.{},
        complete_storage: []u8 = &.{},
        snapshot_storage: []u8 = &.{},
        directory: []const u8 = "",
        index: usize = 0,
        generation: u64 = 0,
        stop_path: ?[:0]u8,
        complete_path: []u8,
        stream: metrics.Stream,
        stopping: bool = false,
        failed: std.atomic.Value(bool) = .init(false),
        failure: ?anyerror = null,
        count: u64 = 0,
        offset: u64 = 0,
        finished: bool = false,
        registry: ?*metrics.Registry = null,
        snapshots: []metrics.Snapshot = &.{},
        snapshot_file: ?std.Io.File = null,
        snapshot_path: ?[]u8 = null,
        snapshot_offset: u64 = 0,
        next_snapshot: i96 = 0,
        observations: bool = true,
        output: ?system.FileBatch = null,
        sample_bytes: [16 * 1024]u8 = undefined,
        snapshot_bytes: [16 * 1024]u8 = undefined,
        snapshot_count: usize = 0,
        snapshot_at: usize = 0,
        pending_sample: ?metrics.Sample = null,
        stop_requested: bool = false,
        checking_stop: bool = false,
        next_stop_check: i96 = 0,

        fn nextSample(self: *State) ?metrics.Sample {
            if (self.pending_sample) |sample| {
                self.pending_sample = null;
                return sample;
            }
            return self.stream.next();
        }

        fn completeOutput(self: *State) !bool {
            errdefer |err| {
                self.failure = err;
                self.failed.store(true, .release);
            }
            if (self.output) |*output| if (output.active) {
                if (!try output.poll()) return false;
                if (self.checking_stop) {
                    self.checking_stop = false;
                    if (self.stop_requested) {
                        self.stream.freeze.store(true, .release);
                        if (!self.observations) self.stream.sealed.store(true, .release);
                    }
                }
            };
            return true;
        }

        fn waitOutput(self: *State) !void {
            errdefer |err| {
                self.failure = err;
                self.failed.store(true, .release);
            }
            if (self.output) |*output| if (output.active) {
                try output.wait(null);
                if (self.checking_stop and self.stop_requested) self.stream.freeze.store(true, .release);
                self.checking_stop = false;
            };
        }

        fn writeSnapshots(self: *State, io: std.Io) !void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            const registry = self.registry orelse return;
            const snapshots = try registry.snapshotTree(self.snapshots);
            var buffer: [16 * 1024]u8 = undefined;
            var writer = self.snapshot_file.?.writer(io, &buffer);
            writer.pos = self.snapshot_offset;
            defer self.snapshot_offset = writer.pos;
            for (snapshots) |snapshot| try writeRecord(snapshot, &writer.interface);
            try writer.interface.flush();
        }

        fn run(self: *State, io: std.Io) void {
            if (self.failed.load(.acquire)) return;
            self.drain(io, capacity) catch |err| {
                self.failure = err;
                self.failed.store(true, .release);
            };
        }

        fn drain(self: *State, io: std.Io, limit: usize) !void {
            const protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(protection);
            var buffer: [16 * 1024]u8 = undefined;
            var writer = self.file.writer(io, &buffer);
            writer.pos = self.offset;
            defer self.offset = writer.pos;
            if (self.finished) return;
            const stopping = self.stopping;
            if (self.stream.overflow.load(.acquire)) return error.MetricsQueueFull;
            if (!stopping and !self.stream.freeze.load(.monotonic)) {
                if (self.stop_path) |path| {
                    const requested = requested: {
                        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
                            error.FileNotFound => break :requested false,
                            else => return err,
                        };
                        break :requested true;
                    };
                    if (requested) {
                        self.stream.freeze.store(true, .release);
                        if (!self.observations) self.stream.sealed.store(true, .release);
                    }
                }
            }
            const sealed = stopping or self.stream.sealed.load(.acquire);
            var count: usize = 0;
            while (count < limit) : (count += 1) {
                const sample = self.nextSample() orelse break;
                try std.json.Stringify.value(.{ .type = "observation", .kind = "timer", .unit = "nanoseconds", .name = sample.name, .clock = sample.clock, .sequence = sample.sequence, .recorded_ns = sample.recorded_ns, .value = sample.value }, .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                self.count += 1;
            }
            try writer.interface.flush();
            if (sealed and self.stream.head.load(.acquire) == self.stream.tail.load(.acquire)) {
                try std.json.Stringify.value(.{ .type = "end", .cutoff = self.stream.freeze.load(.acquire), .samples = self.count }, .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                try writer.interface.flush();
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.complete_path, .data = "complete\n" });
                self.finished = true;
                return;
            }
        }
    };

    state: *State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, registry: *metrics.Registry, config: Configuration, index: usize, names: []const []const u8) !Exporter {
        const path_storage = try allocator.alloc(u8, config.directory.len + 128);
        errdefer allocator.free(path_storage);
        const complete_storage = try allocator.alloc(u8, path_storage.len + 16);
        errdefer allocator.free(complete_storage);
        const snapshot_storage = try allocator.alloc(u8, path_storage.len + 32);
        errdefer allocator.free(snapshot_storage);
        const path = try std.fmt.bufPrint(path_storage, "{s}/server-{d}-{d}-0.metrics.jsonl", .{ config.directory, std.Io.Clock.now(.awake, io).nanoseconds, index });
        const complete_path = try std.fmt.bufPrint(complete_storage, "{s}.complete", .{path});
        const stop_path = if (config.stop_file) |name| try std.mem.concatWithSentinel(allocator, u8, &.{ config.directory, "/", name }, 0) else null;
        errdefer if (stop_path) |name| allocator.free(name);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        errdefer file.close(io);
        const snapshot_path = try std.fmt.bufPrint(snapshot_storage, "{s}.snapshot.jsonl", .{path});
        const snapshot_file = try std.Io.Dir.cwd().createFile(io, snapshot_path, .{ .exclusive = true });
        errdefer snapshot_file.close(io);
        const snapshots = try allocator.alloc(metrics.Snapshot, config.snapshot_capacity);
        errdefer allocator.free(snapshots);
        const samples = try allocator.alloc(metrics.Sample, capacity);
        errdefer allocator.free(samples);
        var output = try system.FileBatch.init(io, config.io_mode);
        errdefer output.deinit();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        // Recording exporter work must not immediately schedule another export.
        state.* = .{ .file = file, .path = path, .path_storage = path_storage, .complete_storage = complete_storage, .snapshot_storage = snapshot_storage, .directory = config.directory, .index = index, .stop_path = stop_path, .complete_path = complete_path, .stream = .{ .samples = samples, .notify_after = 32 }, .registry = registry.root(), .snapshots = snapshots, .snapshot_file = snapshot_file, .snapshot_path = snapshot_path, .observations = names.len != 0, .output = output };
        // Validate the complete subscription before retaining pointers into the stream.
        for (names, 0..) |name, i| {
            const snapshot = registry.find(name) orelse return error.MetricNotFound;
            if (snapshot.kind != .timer) return error.InvalidSubscription;
            for (names[0..i]) |previous| if (std.mem.eql(u8, previous, name)) return error.InvalidSubscription;
        }
        errdefer for (registry.records[0..registry.count]) |*record| {
            if (record.stream == &state.stream) record.stream = null;
        };
        for (names) |name| try registry.subscribe(name, &state.stream);
        return .{ .state = state };
    }

    pub fn check(self: Exporter) !void {
        if (self.state.failed.load(.acquire)) return self.state.failure.?;
        if (self.state.stream.overflow.load(.acquire)) return error.MetricsQueueFull;
    }

    /// Producers must be quiescent while the stream is restarted.
    pub fn restart(self: *Exporter, io: std.Io) !void {
        const state = self.state;
        try self.check();
        std.debug.assert(state.stopping and state.finished);
        state.generation += 1;
        const path = try std.fmt.bufPrint(state.path_storage, "{s}/server-{d}-{d}-{d}.metrics.jsonl", .{ state.directory, std.Io.Clock.now(.awake, io).nanoseconds, state.index, state.generation });
        const complete_path = try std.fmt.bufPrint(state.complete_storage, "{s}.complete", .{path});
        const snapshot_path = try std.fmt.bufPrint(state.snapshot_storage, "{s}.snapshot.jsonl", .{path});
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        errdefer file.close(io);
        const snapshot_file = try std.Io.Dir.cwd().createFile(io, snapshot_path, .{ .exclusive = true });
        state.file.close(io);
        if (state.snapshot_file) |previous| previous.close(io);
        state.file = file;
        state.snapshot_file = snapshot_file;
        state.path = path;
        state.complete_path = complete_path;
        state.snapshot_path = snapshot_path;
        state.stream = .{ .samples = state.stream.samples, .notify_after = 32 };
        state.stopping = false;
        state.finished = false;
        state.count = 0;
        state.offset = 0;
        state.snapshot_offset = 0;
        state.next_snapshot = 0;
        state.snapshot_at = 0;
        state.snapshot_count = 0;
        state.pending_sample = null;
        state.checking_stop = false;
        state.stop_requested = false;
        state.next_stop_check = 0;
    }

    pub fn poll(self: *Exporter, io: std.Io) !void {
        if (!self.state.stream.ready.isSet() and std.Io.Clock.now(.awake, io).nanoseconds < self.state.next_snapshot) return;
        self.state.stream.ready.reset();
        self.process(io) catch |err| {
            self.state.failure = err;
            self.state.failed.store(true, .release);
            return err;
        };
    }

    fn process(self: *Exporter, io: std.Io) !void {
        const state = self.state;
        try self.check();
        if (!try state.completeOutput()) {
            state.stream.ready.set(io);
            return;
        }
        if (state.finished) return;
        if (state.stream.sealed.load(.acquire) and state.pending_sample == null and state.snapshot_at == state.snapshot_count and state.stream.head.load(.acquire) == state.stream.tail.load(.acquire)) {
            try state.drain(io, 0);
            return;
        }
        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        if (state.snapshot_at == state.snapshot_count and now >= state.next_snapshot) {
            state.snapshot_count = (try state.registry.?.snapshotTree(state.snapshots)).len;
            state.snapshot_at = 0;
            state.next_snapshot = now + std.time.ns_per_s;
        }
        var snapshots = std.Io.Writer.fixed(&state.snapshot_bytes);
        var encoded: usize = 0;
        while (state.snapshot_at < state.snapshot_count and encoded < 32) : (encoded += 1) {
            const before = snapshots.end;
            writeRecord(state.snapshots[state.snapshot_at], &snapshots) catch {
                snapshots.end = before;
                if (before == 0) return error.MetricRecordTooLarge;
                break;
            };
            state.snapshot_at += 1;
        }
        var samples = std.Io.Writer.fixed(&state.sample_bytes);
        const available = state.stream.tail.load(.acquire) - state.stream.head.load(.acquire);
        const drain_samples = available >= state.stream.notify_after or state.pending_sample != null or state.stream.sealed.load(.acquire);
        for (0..if (drain_samples) @as(usize, 32) else 0) |_| {
            const sample = state.nextSample() orelse break;
            const before = samples.end;
            std.json.Stringify.value(.{ .type = "observation", .kind = "timer", .unit = "nanoseconds", .name = sample.name, .clock = sample.clock, .sequence = sample.sequence, .recorded_ns = sample.recorded_ns, .value = sample.value }, .{}, &samples) catch {
                samples.end = before;
                state.pending_sample = sample;
                if (before == 0) return error.MetricRecordTooLarge;
                break;
            };
            samples.writeByte('\n') catch {
                samples.end = before;
                state.pending_sample = sample;
                if (before == 0) return error.MetricRecordTooLarge;
                break;
            };
            state.count += 1;
        }
        var operations: [3]system.FileBatch.Operation = undefined;
        var count: usize = 0;
        if (!state.stream.freeze.load(.acquire) and now >= state.next_stop_check) if (state.stop_path) |path| {
            state.next_stop_check = now + 100 * std.time.ns_per_ms;
            state.checking_stop = true;
            operations[count] = .{ .exists = .{ .directory = std.Io.Dir.cwd(), .path = path, .result = &state.stop_requested } };
            count += 1;
        };
        if (snapshots.end != 0) {
            operations[count] = .{ .write = .{ .file = state.snapshot_file.?, .offset = state.snapshot_offset, .bytes = snapshots.buffered() } };
            state.snapshot_offset += snapshots.end;
            count += 1;
        }
        if (samples.end != 0) {
            operations[count] = .{ .write = .{ .file = state.file, .offset = state.offset, .bytes = samples.buffered() } };
            state.offset += samples.end;
            count += 1;
        }
        if (count != 0) try state.output.?.submit(operations[0..count]);
        const pending = state.stream.tail.load(.acquire) - state.stream.head.load(.acquire);
        if (count != 0 or state.snapshot_at != state.snapshot_count or state.pending_sample != null or pending >= state.stream.notify_after or (pending != 0 and state.stream.sealed.load(.acquire))) state.stream.ready.set(io);
    }

    pub fn finish(self: *Exporter, io: std.Io) !void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        try self.state.waitOutput();
        self.state.stopping = true;
        self.state.stream.sealed.store(true, .release);
        self.state.writeSnapshots(io) catch |err| {
            self.state.failure = err;
            self.state.failed.store(true, .release);
            return err;
        };
        self.state.run(io);
        try self.check();
    }

    pub fn capture(self: *Exporter, io: std.Io) !void {
        try self.check();
        try self.state.waitOutput();
        try self.state.writeSnapshots(io);
    }

    /// The producer must be quiescent before detaching its stream.
    pub fn deinit(self: *Exporter, allocator: std.mem.Allocator, io: std.Io, registry: *metrics.Registry) !void {
        const state = self.state;
        state.waitOutput() catch |err| {
            state.failure = err;
            state.failed.store(true, .release);
        };
        if (state.output) |*output| output.deinit();
        state.stopping = true;
        state.run(io);
        for (registry.records[0..registry.count]) |*record| {
            if (record.stream == &state.stream) record.stream = null;
        }
        const failure = state.failure;
        const snapshot_result = state.writeSnapshots(io);
        state.file.close(io);
        if (state.snapshot_file) |file| file.close(io);
        allocator.free(state.path_storage);
        allocator.free(state.complete_storage);
        if (state.stop_path) |path| allocator.free(path);
        allocator.free(state.stream.samples);
        allocator.free(state.snapshots);
        allocator.free(state.snapshot_storage);
        allocator.destroy(state);
        self.* = undefined;
        if (failure) |err| return err;
        try snapshot_result;
    }

    /// Snapshot reads require quiescent ownership, just like Registry.snapshot.
    pub fn writeSnapshot(registry: *const metrics.Registry, writer: *std.Io.Writer) !void {
        for (registry.records[0..registry.count]) |*record| {
            const snapshot = record.read();
            try writeRecord(snapshot, writer);
        }
    }

    fn writeRecord(snapshot: metrics.Snapshot, writer: *std.Io.Writer) !void {
        try std.json.Stringify.value(.{
            .type = "snapshot",
            .name = snapshot.name,
            .description = snapshot.description,
            .kind = snapshot.kind,
            .unit = snapshot.unit,
            .clock = snapshot.clock,
            .count = snapshot.count,
            .value = snapshot.value,
            .total = snapshot.total,
            .maximum = snapshot.maximum,
            .sequence = snapshot.sequence,
            .recorded_ns = snapshot.recorded_ns,
            .bounds = snapshot.bounds[0..snapshot.bounds_count],
            .buckets = snapshot.buckets[0 .. snapshot.bounds_count + 1],
        }, .{}, writer);
        try writer.writeByte('\n');
    }
};

test "exporter restarts inside a sealed memory reservation" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}", .{directory.sub_path});
    var memory = system.Memory.init(std.testing.allocator, io);
    defer memory.deinit();
    const allocator = memory.allocator("metrics");
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 1 });
    defer registry.deinit();
    const timer = try registry.timer(.{ .name = "tick", .description = "Complete tick" });
    var exporter = try Exporter.init(allocator, io, &registry, .{ .directory = root }, 0, &.{"tick"});
    defer exporter.deinit(allocator, io, &registry) catch unreachable;
    memory.seal();
    const assigned = memory.assigned_bytes;
    const samples = exporter.state.stream.samples.ptr;
    timer.observe(1);
    try exporter.finish(io);
    const previous_generation = exporter.state.generation;
    try exporter.restart(io);
    try std.testing.expectEqual(previous_generation + 1, exporter.state.generation);
    try std.testing.expectEqual(samples, exporter.state.stream.samples.ptr);
    timer.observe(2);
    try exporter.finish(io);
    try std.testing.expectEqual(@as(u64, 1), exporter.state.count);
    try std.testing.expectEqual(assigned, memory.assigned_bytes);
}

test "exporter drains standard observations and acknowledges only a producer cutoff" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}", .{directory.sub_path});
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 2 });
    defer registry.deinit();
    const counter = try registry.counter(.{ .name = "packets", .description = "Packets produced" });
    const timer = try registry.timer(.{ .name = "tick", .description = "Complete tick" });
    var exporter = try Exporter.init(allocator, io, &registry, .{ .directory = root, .stop_file = "stop" }, 0, &.{"tick"});
    const output_path = try allocator.dupe(u8, exporter.state.path);
    defer allocator.free(output_path);
    const complete_path = try allocator.dupe(u8, exporter.state.complete_path);
    defer allocator.free(complete_path);
    var closed = false;
    defer if (!closed) exporter.deinit(allocator, io, &registry) catch {};
    registry.sequence.store(7, .release);
    counter.add(3);
    timer.observe(1000);
    try directory.dir.writeFile(io, .{ .sub_path = "stop", .data = "stop\n" });
    const deadline = std.Io.Clock.now(.awake, io).nanoseconds + 5 * std.time.ns_per_s;
    while (!exporter.state.stream.freeze.load(.acquire)) {
        try exporter.poll(io);
        try exporter.check();
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete_path, .{}));
    timer.observe(60_000_000);
    while (!exporter.state.finished) {
        try exporter.poll(io);
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.Io.Dir.cwd().access(io, complete_path, .{});
    try exporter.finish(io);
    try exporter.deinit(allocator, io, &registry);
    closed = true;
    try std.Io.Dir.cwd().access(io, complete_path, .{});
    var bytes: [4096]u8 = undefined;
    const output = try std.Io.Dir.cwd().readFile(io, output_path, &bytes);
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var observations: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        if (std.mem.eql(u8, object.get("type").?.string, "end")) {
            try std.testing.expect(object.get("cutoff").?.bool);
            try std.testing.expectEqual(@as(i64, 2), object.get("samples").?.integer);
        } else {
            try std.testing.expectEqualStrings("tick", object.get("name").?.string);
            try std.testing.expectEqual(@as(i64, 7), object.get("sequence").?.integer);
            observations += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), observations);
    var writer = std.Io.Writer.fixed(&bytes);
    try Exporter.writeSnapshot(&registry, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"kind\":\"counter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"value\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"maximum\":60000000") != null);
}

test "incomplete subscription does not retain pointers into a failed exporter" {
    const allocator = std.testing.allocator;
    var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 2 });
    defer registry.deinit();
    _ = try registry.timer(.{ .name = "first", .description = "First timer" });
    _ = try registry.timer(.{ .name = "second", .description = "Second timer" });
    var samples: [1]metrics.Sample = undefined;
    var stream: metrics.Stream = .{ .samples = &samples };
    try registry.subscribe("second", &stream);
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}", .{directory.sub_path});
    try std.testing.expectError(error.InvalidSubscription, Exporter.init(allocator, std.testing.io, &registry, .{ .directory = root }, 0, &.{ "first", "second" }));
    try std.testing.expect(registry.records[0].stream == null);
    try std.testing.expect(registry.records[1].stream == &stream);
}

test "overflow and file write failures never publish a complete capture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 1 });
    defer registry.deinit();
    const timer = try registry.timer(.{ .name = "tick", .description = "Complete tick" });
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(io, "samples", .{});
    file.close(io);
    const read_only = try directory.dir.openFile(io, "samples", .{});
    defer read_only.close(io);
    var path: [256]u8 = undefined;
    const complete = try std.fmt.bufPrint(&path, ".zig-cache/tmp/{s}/complete", .{directory.sub_path});
    const state = try allocator.create(Exporter.State);
    defer allocator.destroy(state);
    var samples: [1]metrics.Sample = undefined;
    state.* = .{ .file = read_only, .path = &.{}, .stop_path = null, .complete_path = complete, .stream = .{ .samples = &samples } };
    try registry.subscribe("tick", &state.stream);
    timer.observe(1);
    timer.observe(2);
    state.run(io);
    try std.testing.expectEqual(error.MetricsQueueFull, state.failure.?);
    try std.testing.expect(state.failed.load(.acquire));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete, .{}));
    state.stream.overflow.store(false, .release);
    state.failure = null;
    state.failed.store(false, .release);
    state.stopping = true;
    state.run(io);
    try std.testing.expect(state.failed.load(.acquire));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete, .{}));
}

test "work observations do not keep their own exporter runnable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    defer allocator.free(path);
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 1 });
    defer registry.deinit();
    const work = try registry.timer(.{ .name = "server.work", .description = "Background execution" });
    var exporter = try Exporter.init(allocator, io, &registry, .{ .directory = path }, 0, &.{"server.work"});
    defer exporter.deinit(allocator, io, &registry) catch {};
    for (0..64) |_| work.observe(1);
    var idle = false;
    for (0..128) |_| {
        try exporter.poll(io);
        try exporter.state.waitOutput();
        work.observe(1);
        if (!exporter.state.stream.ready.isSet()) {
            idle = true;
            break;
        }
    }
    try std.testing.expect(idle);
    const recorded = exporter.state.count;
    try std.testing.expect(recorded >= 64 and recorded < 96);
    work.observe(1);
    try exporter.poll(io);
    try std.testing.expectEqual(recorded, exporter.state.count);
    try std.testing.expect(!exporter.state.stream.ready.isSet());
    try exporter.finish(io);
}

test "one exporter captures simulation storage and session registries across threads" {
    const allocator = std.testing.allocator;
    var root = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 1 });
    defer root.deinit();
    const bytes = try root.counter(.{ .name = "storage.wal_bytes", .description = "WAL bytes", .unit = .bytes });
    var simulation = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 1, .parent = &root });
    defer simulation.deinit();
    const tick = try simulation.timer(.{ .name = "server.tick", .description = "Simulation tick" });
    var sessions = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 1, .parent = &simulation });
    defer sessions.deinit();
    const packets = try sessions.counter(.{ .name = "sessions.packets", .description = "Sent packets" });
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{directory.sub_path});
    defer allocator.free(path);
    var exporter = try Exporter.init(allocator, std.testing.io, &simulation, .{ .directory = path, .snapshot_capacity = 3 }, 0, &.{"server.tick"});
    var closed = false;
    defer if (!closed) exporter.deinit(allocator, std.testing.io, &simulation) catch {};
    const snapshot_path = try allocator.dupe(u8, exporter.state.snapshot_path.?);
    defer allocator.free(snapshot_path);
    const io = std.testing.io;
    for (0..64) |_| {
        bytes.add(4096);
        tick.observe(1000);
        packets.add(2);
    }
    try exporter.finish(io);
    try exporter.finish(std.testing.io);
    try exporter.deinit(allocator, std.testing.io, &simulation);
    closed = true;
    var buffer: [16 * 1024]u8 = undefined;
    const output = try std.Io.Dir.cwd().readFile(std.testing.io, snapshot_path, &buffer);
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var found: u3 = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const row = parsed.value.object;
        const name = row.get("name").?.string;
        if (std.mem.eql(u8, name, "storage.wal_bytes") and row.get("value").?.integer == 64 * 4096) found |= 1;
        if (std.mem.eql(u8, name, "server.tick") and row.get("count").?.integer == 64) found |= 2;
        if (std.mem.eql(u8, name, "sessions.packets") and row.get("value").?.integer == 128) found |= 4;
    }
    try std.testing.expectEqual(@as(u3, 7), found);
}
