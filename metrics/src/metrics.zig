const std = @import("std");
const assert = std.debug.assert;

pub const Exporter = @import("exporter.zig").Exporter;
pub const Unit = enum { count, bytes, nanoseconds };
pub const Kind = enum { counter, gauge, histogram, timer };
pub const Clock = enum { wall, thread_cpu };
pub const bucket_max = 16;
pub const duration_buckets = &[_]u64{ 1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000, 50_000_000, 100_000_000, 500_000_000, 1_000_000_000 };

const Definition = struct {
    namespace: []const u8 = "",
    name: []const u8,
    description: []const u8,
    unit: Unit = .count,
    clock: Clock = .wall,
    buckets: []const u64 = &.{},
};

const ValueDefinition = struct {
    namespace: []const u8 = "",
    name: []const u8,
    description: []const u8,
    unit: Unit = .count,
};

pub const Snapshot = struct {
    name: []const u8,
    description: []const u8,
    kind: Kind,
    unit: Unit,
    clock: Clock,
    count: u64 = 0,
    value: u64 = 0,
    total: u64 = 0,
    maximum: u64 = 0,
    recorded_ns: i96 = 0,
    sequence: u64 = 0,
    bounds: [bucket_max]u64 = @splat(0),
    // Disjoint buckets include their upper bound. The final bucket contains overflow.
    buckets: [bucket_max + 1]u64 = @splat(0),
    bounds_count: u8 = 0,
};

pub const Sample = struct {
    name: []const u8,
    clock: Clock,
    sequence: u64,
    recorded_ns: i96,
    value: u64,
};

/// One producer and one consumer. Overflow invalidates the captured stream.
pub const Stream = struct {
    samples: []Sample,
    head: std.atomic.Value(u64) = .init(0),
    tail: std.atomic.Value(u64) = .init(0),
    overflow: std.atomic.Value(bool) = .init(false),
    freeze: std.atomic.Value(bool) = .init(false),
    sealed: std.atomic.Value(bool) = .init(false),

    fn push(self: *Stream, sample: Sample) void {
        if (self.sealed.load(.monotonic)) return;
        const tail = self.tail.load(.monotonic);
        if (tail - self.head.load(.acquire) == self.samples.len) {
            self.overflow.store(true, .release);
            return;
        }
        self.samples[tail % self.samples.len] = sample;
        self.tail.store(tail + 1, .release);
        // Include the observation already in flight when a cutoff is requested.
        if (self.freeze.load(.acquire)) self.sealed.store(true, .release);
    }

    pub fn next(self: *Stream) ?Sample {
        const head = self.head.load(.monotonic);
        if (head == self.tail.load(.acquire)) return null;
        const sample = self.samples[head % self.samples.len];
        self.head.store(head + 1, .release);
        return sample;
    }
};

const Record = struct {
    snapshot: Snapshot,
    stream: ?*Stream = null,
    name: [128]u8,
    description: [256]u8,
};

/// A registry is one recording lane. Keep its address stable after creating timer handles.
/// Transfer ownership only at a quiescent boundary.
/// Concurrent workers use separate registries and publish snapshots through their channels.
pub const Registry = struct {
    pub const Configuration = struct { capacity: usize = 256, enabled: bool = true };
    pub const Error = error{ OutOfMemory, Capacity, ConflictingDefinition, InvalidDefinition, Sealed };

    allocator: std.mem.Allocator,
    io: std.Io,
    records: []Record,
    count: usize = 0,
    enabled: bool = true,
    sealed: bool = false,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Configuration) Error!Registry {
        return .{ .allocator = allocator, .io = io, .records = try allocator.alloc(Record, if (config.enabled) config.capacity else 0), .enabled = config.enabled };
    }

    pub fn deinit(self: *Registry) void {
        self.allocator.free(self.records);
        self.* = undefined;
    }

    pub fn counter(self: *Registry, definition: Counter.Definition) Error!Counter {
        return .{ .record = try self.register(.counter, .{
            .namespace = definition.namespace,
            .name = definition.name,
            .description = definition.description,
            .unit = definition.unit,
        }) };
    }

    pub fn gauge(self: *Registry, definition: Gauge.Definition) Error!Gauge {
        return .{ .record = try self.register(.gauge, .{
            .namespace = definition.namespace,
            .name = definition.name,
            .description = definition.description,
            .unit = definition.unit,
        }) };
    }

    pub fn histogram(self: *Registry, definition: Histogram.Definition) Error!Histogram {
        return .{ .record = try self.register(.histogram, .{
            .namespace = definition.namespace,
            .name = definition.name,
            .description = definition.description,
            .unit = definition.unit,
            .buckets = definition.buckets,
        }) };
    }

    pub fn timer(self: *Registry, definition: Timer.Definition) Error!Timer {
        return .{ .registry = self, .record = try self.register(.timer, .{
            .namespace = definition.namespace,
            .name = definition.name,
            .description = definition.description,
            .unit = .nanoseconds,
            .clock = definition.clock,
            .buckets = definition.buckets,
        }) };
    }

    pub fn seal(self: *Registry) void {
        self.sealed = true;
    }

    pub fn at(self: *const Registry, index: usize) Snapshot {
        assert(index < self.count);
        return self.records[index].snapshot;
    }

    pub fn find(self: *const Registry, name: []const u8) ?Snapshot {
        for (self.records[0..self.count]) |*record| {
            if (std.mem.eql(u8, record.snapshot.name, name)) return record.snapshot;
        }
        return null;
    }

    /// Names and descriptions borrow this registry and must outlive snapshot consumers.
    pub fn snapshot(self: *const Registry, destination: []Snapshot) []Snapshot {
        assert(destination.len >= self.count);
        for (self.records[0..self.count], destination[0..self.count]) |record, *output| output.* = record.snapshot;
        return destination[0..self.count];
    }

    /// Change subscriptions only while the producer is quiescent.
    pub fn subscribe(self: *Registry, name: []const u8, stream: *Stream) !void {
        for (self.records[0..self.count]) |*record| {
            if (!std.mem.eql(u8, record.snapshot.name, name)) continue;
            if (record.snapshot.kind != .timer or record.stream != null) return error.InvalidSubscription;
            record.stream = stream;
            return;
        }
        return error.MetricNotFound;
    }

    fn register(self: *Registry, kind: Kind, definition: Definition) Error!?*Record {
        if (self.sealed) return error.Sealed;
        if (definition.name.len == 0 or definition.name.len > 127 or definition.namespace.len > 127 or definition.namespace.len + definition.name.len > 127 or definition.description.len == 0 or definition.description.len > 256 or definition.buckets.len > bucket_max) return error.InvalidDefinition;
        for (definition.buckets, 0..) |bound, i| {
            if (i != 0 and bound <= definition.buckets[i - 1]) return error.InvalidDefinition;
        }
        if (kind != .histogram and kind != .timer and definition.buckets.len != 0) return error.InvalidDefinition;
        if (!self.enabled) return null;
        var name_buffer: [128]u8 = undefined;
        const prefix = definition.namespace.len + @intFromBool(definition.namespace.len != 0);
        const name = name_buffer[0 .. prefix + definition.name.len];
        if (definition.namespace.len != 0) {
            @memcpy(name[0..definition.namespace.len], definition.namespace);
            name[definition.namespace.len] = '.';
        }
        @memcpy(name[prefix..], definition.name);
        for (self.records[0..self.count]) |*record| {
            const existing = &record.snapshot;
            if (!std.mem.eql(u8, existing.name, name)) continue;
            if (existing.kind != kind or existing.unit != definition.unit or existing.clock != definition.clock or !std.mem.eql(u8, existing.description, definition.description) or !std.mem.eql(u64, existing.bounds[0..existing.bounds_count], definition.buckets)) return error.ConflictingDefinition;
            return record;
        }
        if (self.count == self.records.len) return error.Capacity;
        const record = &self.records[self.count];
        @memcpy(record.name[0..name.len], name);
        @memcpy(record.description[0..definition.description.len], definition.description);
        record.snapshot = .{ .name = record.name[0..name.len], .description = record.description[0..definition.description.len], .kind = kind, .unit = definition.unit, .clock = definition.clock, .bounds_count = @intCast(definition.buckets.len) };
        record.stream = null;
        @memcpy(record.snapshot.bounds[0..definition.buckets.len], definition.buckets);
        self.count += 1;
        return record;
    }
};

pub const Counter = struct {
    pub const Definition = ValueDefinition;

    record: ?*Record = null,

    pub fn add(self: Counter, amount: u64) void {
        const record = self.record orelse return;
        record.snapshot.value +|= amount;
    }

    pub fn value(self: Counter) u64 {
        return if (self.record) |record| record.snapshot.value else 0;
    }
};

pub const Gauge = struct {
    pub const Definition = ValueDefinition;

    record: ?*Record = null,

    pub fn set(self: Gauge, value: u64) void {
        const record = self.record orelse return;
        record.snapshot.value = value;
    }
};

pub const Histogram = struct {
    pub const Definition = struct {
        namespace: []const u8 = "",
        name: []const u8,
        description: []const u8,
        unit: Unit = .count,
        buckets: []const u64,
    };

    record: ?*Record = null,

    pub fn observe(self: Histogram, value: u64) void {
        const record = self.record orelse return;
        recordObservation(record, value);
    }
};

fn recordObservation(record: *Record, value: u64) void {
    const snapshot = &record.snapshot;
    snapshot.count +|= 1;
    snapshot.value = value;
    snapshot.total +|= value;
    snapshot.maximum = @max(snapshot.maximum, value);
    var bucket: usize = 0;
    while (bucket < snapshot.bounds_count and value > snapshot.bounds[bucket]) : (bucket += 1) {}
    snapshot.buckets[bucket] +|= 1;
}

pub const Timer = struct {
    pub const Definition = struct {
        namespace: []const u8 = "",
        name: []const u8,
        description: []const u8,
        clock: Clock = .wall,
        buckets: []const u64 = duration_buckets,
    };

    registry: ?*Registry = null,
    record: ?*Record = null,

    pub fn start(self: Timer) Span {
        const record = self.record orelse return .{};
        return .{ .timer = self, .started = std.Io.Clock.now(if (record.snapshot.clock == .wall) .awake else .cpu_thread, self.registry.?.io).nanoseconds };
    }

    pub fn observe(self: Timer, nanoseconds: u64) void {
        if (self.record == null) return;
        self.recordAt(nanoseconds, std.Io.Clock.now(.awake, self.registry.?.io).nanoseconds);
    }

    fn recordAt(self: Timer, nanoseconds: u64, recorded_ns: i96) void {
        const target = self.record orelse return;
        const registry = self.registry.?;
        recordObservation(target, nanoseconds);
        target.snapshot.recorded_ns = recorded_ns;
        target.snapshot.sequence = registry.sequence;
        if (target.stream) |stream| stream.push(.{
            .name = target.snapshot.name,
            .clock = target.snapshot.clock,
            .sequence = registry.sequence,
            .recorded_ns = recorded_ns,
            .value = nanoseconds,
        });
    }

    pub fn read(self: Timer) ?Snapshot {
        return if (self.record) |record| record.snapshot else null;
    }
};

/// A thread CPU span must start and end on the same operating system thread.
pub const Span = struct {
    timer: Timer = .{},
    started: i96 = 0,

    pub fn elapsed(self: Span) u64 {
        const record = self.timer.record orelse return 0;
        const now = std.Io.Clock.now(if (record.snapshot.clock == .wall) .awake else .cpu_thread, self.timer.registry.?.io).nanoseconds;
        assert(now >= self.started);
        return @intCast(now - self.started);
    }
    pub fn end(self: Span) void {
        const record = self.timer.record orelse return;
        const registry = self.timer.registry.?;
        const ended = std.Io.Clock.now(if (record.snapshot.clock == .wall) .awake else .cpu_thread, registry.io).nanoseconds;
        assert(ended >= self.started);
        self.timer.recordAt(@intCast(ended - self.started), if (record.snapshot.clock == .wall) ended else std.Io.Clock.now(.awake, registry.io).nanoseconds);
    }
};

test "typed instruments share definitions, own names, and reject conflicts" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 4 });
    defer registry.deinit();
    const counter = try registry.counter(.{ .name = "bytes", .namespace = "network", .description = "Sent bytes", .unit = .bytes });
    const same = try registry.counter(.{ .name = "network.bytes", .description = "Sent bytes", .unit = .bytes });
    counter.add(7);
    same.add(3);
    try std.testing.expectEqual(@as(u64, 10), counter.value());
    try std.testing.expectError(error.ConflictingDefinition, registry.gauge(.{ .name = "network.bytes", .description = "Sent bytes", .unit = .bytes }));
    const gauge = try registry.gauge(.{ .name = "queue", .description = "Pending writes" });
    gauge.set(9);
    gauge.set(2);
    try std.testing.expectEqual(@as(u64, 2), registry.find("queue").?.value);
    const histogram = try registry.histogram(.{ .name = "batch", .description = "Batch size", .buckets = &.{ 1, 4 } });
    for ([_]u64{ 0, 1, 2, 4, 5 }) |value| histogram.observe(value);
    const snapshot = registry.find("batch").?;
    try std.testing.expectEqualSlices(u64, &.{ 2, 2, 1 }, snapshot.buckets[0..3]);
    try std.testing.expectEqual(@as(u64, 12), snapshot.total);
    try std.testing.expectEqual(@as(u64, 5), snapshot.maximum);
    registry.seal();
    try std.testing.expectError(error.Sealed, registry.counter(.{ .name = "late", .description = "Too late" }));
}

test "registry owns bounded metadata without allocating during registration" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var registry = try Registry.init(failing.allocator(), std.testing.io, .{ .capacity = 2 });
    defer registry.deinit();
    var namespace = "server".*;
    var name = "tick".*;
    var description = "Tick duration".*;
    const counter = try registry.counter(.{ .namespace = &namespace, .name = &name, .description = &description });
    @memset(&namespace, 'x');
    @memset(&name, 'x');
    @memset(&description, 'x');
    const same = try registry.counter(.{ .name = "server.tick", .description = "Tick duration" });
    counter.add(7);
    same.add(3);
    try std.testing.expectEqual(@as(u64, 10), registry.find("server.tick").?.value);
    try std.testing.expectEqualStrings("Tick duration", registry.find("server.tick").?.description);
    const maximum_name: [126]u8 = @splat('a');
    const maximum_description: [256]u8 = @splat('b');
    _ = try registry.counter(.{ .namespace = "n", .name = &maximum_name, .description = &maximum_description });
    try std.testing.expectEqual(@as(usize, 128), registry.at(1).name.len);
    try std.testing.expectEqualStrings(&maximum_description, registry.at(1).description);
    try std.testing.expectError(error.ConflictingDefinition, registry.gauge(.{ .name = "server.tick", .description = "Tick duration" }));
    try std.testing.expectError(error.Capacity, registry.counter(.{ .name = "full", .description = "Full registry" }));
    const oversized_name: [128]u8 = @splat('a');
    try std.testing.expectError(error.InvalidDefinition, registry.counter(.{ .name = &oversized_name, .description = "Too long" }));
}

test "timer streams preserve order, detect overflow, and acknowledge cutoff" {
    var registry = try Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 2 });
    defer registry.deinit();
    const timer = try registry.timer(.{ .name = "tick.duration", .description = "Complete tick" });
    var samples: [2]Sample = undefined;
    var stream: Stream = .{ .samples = &samples };
    try registry.subscribe("tick.duration", &stream);
    registry.sequence = 7;
    timer.observe(50_000_000);
    registry.sequence = 8;
    timer.observe(1);
    timer.observe(2);
    try std.testing.expect(stream.overflow.load(.acquire));
    try std.testing.expectEqual(@as(u64, 7), stream.next().?.sequence);
    try std.testing.expectEqual(@as(u64, 8), stream.next().?.sequence);
    try std.testing.expect(stream.next() == null);
    stream.freeze.store(true, .release);
    timer.observe(3);
    try std.testing.expect(stream.sealed.load(.acquire));
    timer.observe(4);
    try std.testing.expectEqual(@as(u64, 3), stream.next().?.value);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqual(@as(u64, 5), timer.read().?.count);
}

test "disabled handles are inert, capacities bounded, and CPU timers supported" {
    const disabled: Timer = .{};
    disabled.start().end();
    var registry = try Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 1 });
    defer registry.deinit();
    try std.testing.expectError(error.InvalidDefinition, registry.histogram(.{ .name = "bad", .description = "Unsorted", .buckets = &.{ 2, 1 } }));
    const timer = try registry.timer(.{ .name = "cpu", .description = "Thread CPU time", .clock = .thread_cpu });
    timer.start().end();
    try std.testing.expectEqual(@as(u64, 1), timer.read().?.count);
    try std.testing.expectEqual(Clock.thread_cpu, timer.read().?.clock);
    try std.testing.expectError(error.Capacity, registry.counter(.{ .name = "full", .description = "Capacity exhausted" }));
}

test {
    std.testing.refAllDecls(@This());
}
