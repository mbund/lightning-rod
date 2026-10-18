const std = @import("std");

const Sample = struct {
    type: []const u8,
    name: []const u8,
    clock: []const u8,
    sequence: u64,
    recorded_ns: i96,
    value: u64,
};
const Header = struct { type: []const u8 };
const Footer = struct { type: []const u8, cutoff: bool, samples: u64 };
pub const Distribution = struct {
    count: u64 = 0,
    maximum_ns: u64 = 0,
    exceeded: u64 = 0,
    worst_tick: u64 = 0,

    pub fn add(self: *Distribution, duration_ns: u64, tick: u64, budget_ns: u64) void {
        self.count += 1;
        if (duration_ns > self.maximum_ns) {
            self.maximum_ns = duration_ns;
            self.worst_tick = tick;
        }
        self.exceeded += @intFromBool(duration_ns > budget_ns);
    }
};

// Work samples belong to the preceding gameplay tick. Each recorder file is a
// separate simulation lifetime, so identical tick IDs after reload stay separate.
const Tick = struct {
    id: ?u64 = null,
    duration_ns: u64 = 0,
    active: bool = false,
    started_ns: i96 = 0,

    fn finish(self: *Tick, ticks: *Distribution) void {
        if (self.id) |id| if (self.active) ticks.add(self.duration_ns, id, 50 * std.time.ns_per_ms);
        self.* = .{ .started_ns = self.started_ns };
    }

    fn add(self: *Tick, sample: Sample, ticks: *Distribution, work: *Distribution) !void {
        if (!std.mem.eql(u8, sample.type, "observation") or !std.mem.eql(u8, sample.clock, "wall")) return error.InvalidPerformanceSample;
        const active = sample.recorded_ns >= self.started_ns;
        if (std.mem.eql(u8, sample.name, "server.tick")) {
            if (self.id) |id| if (sample.sequence <= id) return error.InvalidPerformanceSample;
            self.finish(ticks);
            self.* = .{ .id = sample.sequence, .duration_ns = sample.value, .active = active, .started_ns = self.started_ns };
        } else if (std.mem.eql(u8, sample.name, "server.work")) {
            if (self.id == null or self.id.? != sample.sequence) return error.InvalidPerformanceSample;
            self.duration_ns = try std.math.add(u64, self.duration_ns, sample.value);
            if (self.active) work.add(sample.value, sample.sequence, 50 * std.time.ns_per_ms);
        } else return error.InvalidPerformanceSample;
    }
};

pub const TailPolicy = enum { complete, intentional_crash };

const ReadResult = struct { truncated: bool, complete: bool };

fn readSamples(reader: *std.Io.Reader, allocator: std.mem.Allocator, policy: TailPolicy, started_ns: i96, ticks: *Distribution, work: *Distribution) !ReadResult {
    var tick: Tick = .{ .started_ns = started_ns };
    var truncated = false;
    var complete = false;
    var count: u64 = 0;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                truncated = reader.buffered().len != 0;
                if (truncated and policy == .complete) return error.TruncatedPerformanceSample;
                break;
            },
            else => return err,
        };
        const header = try std.json.parseFromSlice(Header, allocator, line, .{ .ignore_unknown_fields = true });
        defer header.deinit();
        if (complete) return error.InvalidPerformanceSample;
        if (std.mem.eql(u8, header.value.type, "end")) {
            const footer = try std.json.parseFromSlice(Footer, allocator, line, .{});
            defer footer.deinit();
            const end = footer.value;
            if (end.samples != count) return error.InvalidPerformanceSample;
            if (!end.cutoff) {
                tick.finish(ticks);
            } else if (policy != .intentional_crash) return error.InvalidPerformanceSample;
            complete = true;
            continue;
        }
        const parsed = try std.json.parseFromSlice(Sample, allocator, line, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        try tick.add(parsed.value, ticks, work);
        count += 1;
    }
    // A crash can interrupt the final tick. Its captured time can prove a breach,
    // but cannot establish that the complete tick stayed within budget.
    if (tick.duration_ns > 50 * std.time.ns_per_ms) tick.finish(ticks);
    return .{ .truncated = truncated, .complete = complete and !truncated };
}

pub fn seal(init: std.process.Init, artifacts: []const u8) !void {
    var directory = try std.Io.Dir.cwd().openDir(init.io, artifacts, .{ .iterate = true });
    defer directory.close(init.io);
    try directory.writeFile(init.io, .{ .sub_path = "metrics.stop", .data = "stop\n" });
    const deadline = std.Io.Clock.now(.awake, init.io).nanoseconds + 5 * std.time.ns_per_s;
    while (true) {
        var iterator = directory.iterate();
        var found = false;
        var complete = true;
        while (try iterator.next(init.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "server-") or !std.mem.endsWith(u8, entry.name, ".metrics.jsonl")) continue;
            found = true;
            var bytes: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&bytes, "{s}.complete", .{entry.name});
            directory.access(init.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => complete = false,
                else => return err,
            };
        }
        if (found and complete) return;
        if (std.Io.Clock.now(.awake, init.io).nanoseconds >= deadline) return error.MetricsDrainTimeout;
        try std.Io.sleep(init.io, .fromMilliseconds(10), .awake);
    }
}

pub fn summarize(init: std.process.Init, artifacts: []const u8, policy: TailPolicy) !bool {
    var directory = try std.Io.Dir.cwd().openDir(init.io, artifacts, .{ .iterate = true });
    defer directory.close(init.io);
    var iterator = directory.iterate();
    var truncated_files: u64 = 0;
    var incomplete_files: u64 = 0;
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var marker: [64]u8 = undefined;
    const started = try directory.readFile(init.io, "clients.start", &marker);
    const started_ns = try std.fmt.parseInt(i96, std.mem.trim(u8, started, "\n"), 10);
    const buffer = try init.gpa.alloc(u8, 4096);
    defer init.gpa.free(buffer);
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "server-") or !std.mem.endsWith(u8, entry.name, ".metrics.jsonl")) continue;
        const file = try directory.openFile(init.io, entry.name, .{});
        defer file.close(init.io);
        var reader = file.reader(init.io, buffer);
        const result = try readSamples(&reader.interface, init.gpa, policy, started_ns, &ticks, &work);
        truncated_files += @intFromBool(result.truncated);
        incomplete_files += @intFromBool(!result.complete);
    }
    const passed = ticks.count > 0 and ticks.exceeded == 0 and incomplete_files == 0;
    const output = try directory.createFile(init.io, "performance.metrics.json", .{});
    defer output.close(init.io);
    var writer = output.writer(init.io, buffer);
    try std.json.Stringify.value(.{ .passed = passed, .budget_clock = "wall", .ticks = ticks, .work = work, .truncated_files = truncated_files, .incomplete_files = incomplete_files }, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
    if (ticks.count == 0) return error.ServerMetricsMissing;
    if (incomplete_files != 0) return error.ServerMetricsIncomplete;
    if (!passed) std.log.err("event=e2e_performance_failed ticks_over_budget={d} work_over_budget={d} maximum_tick_wall_ns={d} maximum_work_wall_ns={d}", .{ ticks.exceeded, work.exceeded, ticks.maximum_ns, work.maximum_ns });
    return passed;
}

fn testSample(operation: []const u8, id: u64, duration_ns: u64, phase: []const u8) Sample {
    return .{ .type = "observation", .name = if (std.mem.eql(u8, operation, "tick")) "server.tick" else "server.work", .clock = "wall", .sequence = id, .recorded_ns = if (std.mem.eql(u8, phase, "test")) 1 else -1, .value = duration_ns };
}

test "wall budget includes tick and all following work, including the final tick" {
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var tick: Tick = .{};
    try tick.add(testSample("tick", 7, 30_000_000, "test"), &ticks, &work);
    try tick.add(testSample("work", 7, 15_000_000, "test"), &ticks, &work);
    try tick.add(testSample("work", 7, 15_000_000, "test"), &ticks, &work);
    try tick.add(testSample("tick", 8, 50_000_000, "test"), &ticks, &work);
    tick.finish(&ticks);
    try std.testing.expectEqual(@as(u64, 2), ticks.count);
    try std.testing.expectEqual(@as(u64, 1), ticks.exceeded);
    try std.testing.expectEqual(@as(u64, 60_000_000), ticks.maximum_ns);
    try std.testing.expectEqual(@as(u64, 7), ticks.worst_tick);
    try std.testing.expectEqual(@as(u64, 2), work.count);
}

test "startup work does not become a partial test tick when clients start" {
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var tick: Tick = .{};
    try tick.add(testSample("tick", 1, 100_000_000, "startup"), &ticks, &work);
    try tick.add(testSample("work", 1, 100_000_000, "test"), &ticks, &work);
    try tick.add(testSample("tick", 2, 1_000_000, "test"), &ticks, &work);
    tick.finish(&ticks);
    try std.testing.expectEqual(@as(u64, 1), ticks.count);
    try std.testing.expectEqual(@as(u64, 0), ticks.exceeded);
    try std.testing.expectEqual(@as(u64, 0), work.count);
    // A fresh recorder after reload may repeat tick IDs.
    try tick.add(testSample("tick", 2, 1_000_000, "test"), &ticks, &work);
    tick.finish(&ticks);
    try std.testing.expectEqual(@as(u64, 2), ticks.count);
}

test "work must follow its tick and CPU samples are rejected" {
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var tick: Tick = .{};
    try std.testing.expectError(error.InvalidPerformanceSample, tick.add(testSample("work", 1, 1, "test"), &ticks, &work));
    var cpu = testSample("tick", 1, 1, "test");
    cpu.clock = "thread_cpu";
    try std.testing.expectError(error.InvalidPerformanceSample, tick.add(cpu, &ticks, &work));
    try tick.add(testSample("tick", 1, 1, "test"), &ticks, &work);
    try std.testing.expectError(error.InvalidPerformanceSample, tick.add(testSample("work", 2, 1, "test"), &ticks, &work));
}

test "only intentional crashes permit truncated records without hiding known breaches" {
    const prefix = "{\"type\":\"observation\",\"name\":\"server.tick\",\"sequence\":1,\"recorded_ns\":1,\"clock\":\"wall\",\"value\":1000}\n";
    const next = "{\"type\":\"observation\",\"name\":\"server.tick\",\"sequence\":2,\"recorded_ns\":1,\"clock\":\"wall\",\"value\":60000000}\n";
    for ([_][]const u8{ "{", "{\"duration_ns\":100000000}" }) |tail| {
        const bytes = try std.mem.concat(std.testing.allocator, u8, &.{ prefix, next, tail });
        defer std.testing.allocator.free(bytes);
        var ticks: Distribution = .{};
        var work: Distribution = .{};
        var strict: std.Io.Reader = .fixed(bytes);
        try std.testing.expectError(error.TruncatedPerformanceSample, readSamples(&strict, std.testing.allocator, .complete, 0, &ticks, &work));
        ticks = .{};
        var crashed: std.Io.Reader = .fixed(bytes);
        try std.testing.expect((try readSamples(&crashed, std.testing.allocator, .intentional_crash, 0, &ticks, &work)).truncated);
        try std.testing.expectEqual(@as(u64, 2), ticks.count);
        try std.testing.expectEqual(@as(u64, 1), ticks.exceeded);
    }
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var complete: std.Io.Reader = .fixed(prefix);
    const unsealed = try readSamples(&complete, std.testing.allocator, .complete, 0, &ticks, &work);
    try std.testing.expect(!unsealed.truncated and !unsealed.complete);
    try std.testing.expectEqual(@as(u64, 0), ticks.count);
    var partial: std.Io.Reader = .fixed(prefix ++ "{");
    ticks = .{};
    try std.testing.expect((try readSamples(&partial, std.testing.allocator, .intentional_crash, 0, &ticks, &work)).truncated);
    try std.testing.expectEqual(@as(u64, 0), ticks.count);
    var terminated: std.Io.Reader = .fixed(prefix);
    try std.testing.expect(!(try readSamples(&terminated, std.testing.allocator, .intentional_crash, 0, &ticks, &work)).complete);
    try std.testing.expectEqual(@as(u64, 0), ticks.count);
}

test "drain footers verify the captured prefix and preserve a known cutoff breach" {
    const prefix = "{\"type\":\"observation\",\"name\":\"server.tick\",\"sequence\":1,\"recorded_ns\":1,\"clock\":\"wall\",\"value\":60000000}\n";
    const footer = "{\"type\":\"end\",\"cutoff\":true,\"samples\":1}\n";
    var ticks: Distribution = .{};
    var work: Distribution = .{};
    var captured: std.Io.Reader = .fixed(prefix ++ footer);
    const result = try readSamples(&captured, std.testing.allocator, .intentional_crash, 0, &ticks, &work);
    try std.testing.expect(result.complete and !result.truncated);
    try std.testing.expectEqual(@as(u64, 1), ticks.exceeded);
    var after_end: std.Io.Reader = .fixed(prefix ++ footer ++ prefix);
    try std.testing.expectError(error.InvalidPerformanceSample, readSamples(&after_end, std.testing.allocator, .intentional_crash, 0, &ticks, &work));
    var bad_count: std.Io.Reader = .fixed(footer);
    try std.testing.expectError(error.InvalidPerformanceSample, readSamples(&bad_count, std.testing.allocator, .complete, 0, &ticks, &work));
    const complete_footer = "{\"type\":\"end\",\"cutoff\":false,\"samples\":1}\n";
    ticks = .{};
    var clean: std.Io.Reader = .fixed(prefix ++ complete_footer);
    try std.testing.expect((try readSamples(&clean, std.testing.allocator, .complete, 0, &ticks, &work)).complete);
    try std.testing.expectEqual(@as(u64, 1), ticks.count);
}

test "missing observation values and clocks cannot establish a passing budget" {
    const missing_value = "{\"type\":\"observation\",\"name\":\"server.tick\",\"clock\":\"wall\",\"sequence\":1,\"recorded_ns\":1}\n";
    const missing_clock = "{\"type\":\"observation\",\"name\":\"server.tick\",\"value\":1,\"sequence\":1,\"recorded_ns\":1}\n";
    for ([_][]const u8{ missing_value, missing_clock }) |bytes| {
        var reader: std.Io.Reader = .fixed(bytes);
        var ticks: Distribution = .{};
        var work: Distribution = .{};
        try std.testing.expectError(error.MissingField, readSamples(&reader, std.testing.allocator, .complete, 0, &ticks, &work));
        try std.testing.expectEqual(@as(u64, 0), ticks.count);
    }
}
