const std = @import("std");

const assert = std.debug.assert;

const shared = @import("metrics");

pub const Record = shared.Record;

pub const Tick = struct {
    sequence: u64 = 0,
    ended_ns: i96 = 0,
    duration_ns: u64 = 0,
};

pub const Metrics = struct {
    completed_tick: Tick = .{},
    recorder: shared.Recorder,
    plugins: []Record,
    traces: []Record,
    current: ?u32 = null,
    trace_base: u32 = 0,
    trace_count: u32 = 0,
    previous: ?*Metrics = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, plugins: usize, traces: usize, enabled: bool) !Metrics {
        const records = try allocator.alloc(Record, plugins + traces);
        @memset(records, .{});
        return .{
            .recorder = .{ .io = io, .enabled = enabled, .records = records },
            .plugins = records[0..plugins],
            .traces = records[plugins..],
        };
    }

    pub fn enter(self: *Metrics, plugin: usize, base: usize, count: usize) Scope {
        assert(self.current == null);
        assert(plugin < self.plugins.len);
        assert(base + count <= self.traces.len);
        self.current = @intCast(plugin);
        self.trace_base = @intCast(base);
        self.trace_count = @intCast(count);
        self.previous = active;
        active = self;
        return .{ .metrics = self, .scope = self.recorder.begin(plugin), .plugin = true };
    }
};

threadlocal var active: ?*Metrics = null;

/// Borrowed on the Simulation owner thread. Do not retain across ticks.
pub fn snapshot() ?*const Metrics {
    return active;
}

pub const Scope = struct {
    metrics: ?*Metrics = null,
    scope: shared.Scope = .{},
    plugin: bool = false,

    pub fn end(self: Scope) void {
        const metrics = self.metrics orelse return;
        self.scope.end();

        if (self.plugin) {
            assert(active == metrics);
            assert(metrics.current != null);
            metrics.current = null;
            active = metrics.previous;
        }
    }
};

pub fn scope(trace: anytype) Scope {
    const metrics = active orelse return .{};
    const index = @intFromEnum(trace);
    assert(index < metrics.trace_count);
    return .{ .metrics = metrics, .scope = metrics.recorder.begin(metrics.plugins.len + metrics.trace_base + index) };
}
