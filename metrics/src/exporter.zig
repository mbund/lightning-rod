const std = @import("std");
const metrics = @import("metrics.zig");

/// The recording lane drains observations between ticks. No exporter thread is needed.
pub const Exporter = struct {
    pub const Configuration = struct {
        directory: []const u8,
        stop_file: ?[]const u8 = null,
    };
    const capacity = 4096;
    const State = struct {
        io: std.Io,
        file: std.Io.File,
        path: []u8,
        stop_path: ?[]u8,
        complete_path: []u8,
        stream: metrics.Stream,
        stopping: bool = false,
        failed: bool = false,
        failure: ?anyerror = null,
        count: u64 = 0,
        offset: u64 = 0,
        finished: bool = false,

        fn run(self: *State) void {
            if (self.failed) return;
            self.drain() catch |err| {
                self.failure = err;
                self.failed = true;
            };
        }

        fn drain(self: *State) !void {
            var buffer: [16 * 1024]u8 = undefined;
            var writer = self.file.writer(self.io, &buffer);
            writer.pos = self.offset;
            defer self.offset = writer.pos;
            if (self.finished) return;
            const stopping = self.stopping;
            if (self.stream.overflow.load(.acquire)) return error.MetricsQueueFull;
            if (!stopping and !self.stream.freeze.load(.monotonic)) {
                if (self.stop_path) |path| {
                    const requested = requested: {
                        std.Io.Dir.cwd().access(self.io, path, .{}) catch |err| switch (err) {
                            error.FileNotFound => break :requested false,
                            else => return err,
                        };
                        break :requested true;
                    };
                    if (requested) self.stream.freeze.store(true, .release);
                }
            }
            const sealed = stopping or self.stream.sealed.load(.acquire);
            while (self.stream.next()) |sample| {
                try std.json.Stringify.value(.{ .type = "observation", .kind = "timer", .unit = "nanoseconds", .name = sample.name, .clock = sample.clock, .sequence = sample.sequence, .recorded_ns = sample.recorded_ns, .value = sample.value }, .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                self.count += 1;
            }
            try writer.interface.flush();
            if (sealed) {
                try std.json.Stringify.value(.{ .type = "end", .cutoff = self.stream.freeze.load(.acquire), .samples = self.count }, .{}, &writer.interface);
                try writer.interface.writeByte('\n');
                try writer.interface.flush();
                try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.complete_path, .data = "complete\n" });
                self.finished = true;
                return;
            }
        }
    };

    state: *State,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, registry: *metrics.Registry, config: Configuration, index: usize, names: []const []const u8) !Exporter {
        const path = try std.fmt.allocPrint(allocator, "{s}/server-{d}-{d}.metrics.jsonl", .{ config.directory, std.Io.Clock.now(.awake, io).nanoseconds, index });
        errdefer allocator.free(path);
        const complete_path = try std.fmt.allocPrint(allocator, "{s}.complete", .{path});
        errdefer allocator.free(complete_path);
        const stop_path = if (config.stop_file) |name| try std.fs.path.join(allocator, &.{ config.directory, name }) else null;
        errdefer if (stop_path) |name| allocator.free(name);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        errdefer file.close(io);
        const samples = try allocator.alloc(metrics.Sample, capacity);
        errdefer allocator.free(samples);
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .io = io, .file = file, .path = path, .stop_path = stop_path, .complete_path = complete_path, .stream = .{ .samples = samples } };
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
        self.state.run();
        if (self.state.failed) return self.state.failure.?;
        if (self.state.stream.overflow.load(.acquire)) return error.MetricsQueueFull;
    }

    /// Finish recording before detaching the stream.
    pub fn deinit(self: *Exporter, allocator: std.mem.Allocator, registry: *metrics.Registry) !void {
        const state = self.state;
        state.stopping = true;
        state.run();
        for (registry.records[0..registry.count]) |*record| {
            if (record.stream == &state.stream) record.stream = null;
        }
        const failure = state.failure;
        state.file.close(state.io);
        allocator.free(state.path);
        allocator.free(state.complete_path);
        if (state.stop_path) |path| allocator.free(path);
        allocator.free(state.stream.samples);
        allocator.destroy(state);
        self.* = undefined;
        if (failure) |err| return err;
    }

    pub fn writeSnapshotFile(allocator: std.mem.Allocator, io: std.Io, registry: *const metrics.Registry, config: ?Configuration, lane: []const u8, index: usize) !void {
        const selected = config orelse return;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{d}-{d}.snapshot.jsonl", .{ selected.directory, lane, std.Io.Clock.now(.awake, io).nanoseconds, index });
        defer allocator.free(path);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
        defer file.close(io);
        var buffer: [16 * 1024]u8 = undefined;
        var output = file.writer(io, &buffer);
        try writeSnapshot(registry, &output.interface);
        try output.interface.flush();
    }

    /// Snapshot reads require quiescent ownership, just like Registry.snapshot.
    pub fn writeSnapshot(registry: *const metrics.Registry, writer: *std.Io.Writer) !void {
        for (registry.records[0..registry.count]) |*record| {
            const snapshot = &record.snapshot;
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
    }
};

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
    defer if (!closed) exporter.deinit(allocator, &registry) catch {};
    registry.sequence = 7;
    counter.add(3);
    timer.observe(1000);
    try directory.dir.writeFile(io, .{ .sub_path = "stop", .data = "stop\n" });
    const deadline = std.Io.Clock.now(.awake, io).nanoseconds + 5 * std.time.ns_per_s;
    while (!exporter.state.stream.freeze.load(.acquire)) {
        try exporter.check();
        if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.TestTimeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete_path, .{}));
    timer.observe(60_000_000);
    try exporter.deinit(allocator, &registry);
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
    state.* = .{ .io = io, .file = read_only, .path = &.{}, .stop_path = null, .complete_path = complete, .stream = .{ .samples = &samples } };
    try registry.subscribe("tick", &state.stream);
    timer.observe(1);
    timer.observe(2);
    state.run();
    try std.testing.expectEqual(error.MetricsQueueFull, state.failure.?);
    try std.testing.expect(state.failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete, .{}));
    state.stream.overflow.store(false, .release);
    state.failure = null;
    state.failed = false;
    state.stopping = true;
    state.run();
    try std.testing.expect(state.failed);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, complete, .{}));
}
