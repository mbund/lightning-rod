const std = @import("std");
const preallocated = @import("preallocated");

pub const window_ticks = 100;

pub const PluginTiming = struct {
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    generation_bytes: u64 = 0,
    tick_memory_total_bytes: u64 = 0,
    tick_memory_window_bytes: u64 = 0,
    tick_memory_last_bytes: u64 = 0,
    tick_memory_max_bytes: u64 = 0,
};

pub const TraceTiming = struct {
    total_ns: u64 = 0,
    window_ns: u64 = 0,
    last_ns: u64 = 0,
    max_ns: u64 = 0,
    total_calls: u64 = 0,
    window_calls: u64 = 0,
    last_calls: u32 = 0,
    max_calls: u32 = 0,
};

pub const Profiler = struct {
    enabled: bool = false,
    tick_count: u64 = 0,
    tick_total_ns: u64 = 0,
    tick_window_ns: u64 = 0,
    tick_last_ns: u64 = 0,
    tick_max_ns: u64 = 0,
    window_cursor: usize = 0,
    window_count: usize = 0,
    tick_samples: []u64 = &.{},
    plugin_samples: []align(64) [window_ticks]u64 = &.{},
    plugin_memory_samples: []align(64) [window_ticks]u64 = &.{},
    plugins: []PluginTiming = &.{},
    current_plugins: []u64 = &.{},
    current_plugin_memory: []u64 = &.{},
    trace_samples: []align(64) [window_ticks]u64 = &.{},
    trace_call_samples: []align(64) [window_ticks]u32 = &.{},
    traces: []TraceTiming = &.{},
    current_traces: []u64 = &.{},
    current_trace_calls: []u32 = &.{},
    registered_plugin_count: usize = 0,
    registered_trace_count: usize = 0,
    tick_started_ns: u64 = 0,

    pub fn allocate(self: *Profiler, allocator: std.mem.Allocator, plugin_count: usize, trace_count: usize) !void {
        self.* = .{};
        self.tick_samples = try preallocated.alloc(u64, allocator, window_ticks);
        self.plugin_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", plugin_count);
        self.plugin_memory_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", plugin_count);
        self.plugins = try preallocated.alloc(PluginTiming, allocator, plugin_count);
        self.current_plugins = try preallocated.alloc(u64, allocator, plugin_count);
        self.current_plugin_memory = try preallocated.alloc(u64, allocator, plugin_count);
        self.trace_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", trace_count);
        self.trace_call_samples = try preallocated.alignedAlloc([window_ticks]u32, allocator, .@"64", trace_count);
        self.traces = try preallocated.alloc(TraceTiming, allocator, trace_count);
        self.current_traces = try preallocated.alloc(u64, allocator, trace_count);
        self.current_trace_calls = try preallocated.alloc(u32, allocator, trace_count);
        self.clear(false);
    }

    pub fn setEnabled(self: *Profiler, enabled: bool) void {
        if (enabled and !self.enabled) self.clear(true) else self.enabled = enabled;
    }

    fn clear(self: *Profiler, enabled: bool) void {
        const tick_samples = self.tick_samples;
        const plugin_samples = self.plugin_samples;
        const plugin_memory_samples = self.plugin_memory_samples;
        const plugins = self.plugins;
        const current_plugins = self.current_plugins;
        const current_plugin_memory = self.current_plugin_memory;
        const trace_samples = self.trace_samples;
        const trace_call_samples = self.trace_call_samples;
        const traces = self.traces;
        const current_traces = self.current_traces;
        const current_trace_calls = self.current_trace_calls;
        self.* = .{
            .enabled = enabled,
            .tick_samples = tick_samples,
            .plugin_samples = plugin_samples,
            .plugin_memory_samples = plugin_memory_samples,
            .plugins = plugins,
            .current_plugins = current_plugins,
            .current_plugin_memory = current_plugin_memory,
            .trace_samples = trace_samples,
            .trace_call_samples = trace_call_samples,
            .traces = traces,
            .current_traces = current_traces,
            .current_trace_calls = current_trace_calls,
        };
        @memset(self.tick_samples, 0);
        @memset(self.plugin_samples, [_]u64{0} ** window_ticks);
        @memset(self.plugin_memory_samples, [_]u64{0} ** window_ticks);
        for (self.plugins) |*plugin| {
            const generation_bytes = plugin.generation_bytes;
            plugin.* = .{ .generation_bytes = generation_bytes };
        }
        @memset(self.current_plugins, 0);
        @memset(self.current_plugin_memory, 0);
        @memset(self.trace_samples, [_]u64{0} ** window_ticks);
        @memset(self.trace_call_samples, [_]u32{0} ** window_ticks);
        @memset(self.traces, .{});
        @memset(self.current_traces, 0);
        @memset(self.current_trace_calls, 0);
    }

    pub fn beginTick(self: *Profiler) void {
        if (!self.enabled) return;
        @memset(self.current_plugins[0..self.registered_plugin_count], 0);
        @memset(self.current_plugin_memory[0..self.registered_plugin_count], 0);
        @memset(self.current_traces[0..self.registered_trace_count], 0);
        @memset(self.current_trace_calls[0..self.registered_trace_count], 0);
        self.tick_started_ns = monotonicNanoseconds();
        active_profiler = self;
    }

    pub fn finishTick(self: *Profiler) void {
        if (!self.enabled) return;
        active_profiler = null;
        const elapsed = monotonicNanoseconds() -| self.tick_started_ns;
        const cursor = self.window_cursor;
        self.finishTickSample(cursor, elapsed);
        self.finishPluginSamples(cursor);
        self.finishTraceSamples(cursor);
        self.tick_count +%= 1;
        if (self.window_count < window_ticks) self.window_count += 1;
        self.window_cursor = (cursor + 1) % window_ticks;
    }

    fn finishTickSample(self: *Profiler, cursor: usize, elapsed: u64) void {
        self.tick_window_ns = self.tick_window_ns - self.tick_samples[cursor] + elapsed;
        self.tick_samples[cursor] = elapsed;
        self.tick_last_ns = elapsed;
        self.tick_total_ns +%= elapsed;
        self.tick_max_ns = @max(self.tick_max_ns, elapsed);
    }

    fn finishPluginSamples(self: *Profiler, cursor: usize) void {
        for (0..self.registered_plugin_count) |index| {
            const current = self.current_plugins[index];
            const timing = &self.plugins[index];
            timing.window_ns = timing.window_ns - self.plugin_samples[index][cursor] + current;
            timing.total_ns +%= current;
            timing.last_ns = current;
            timing.max_ns = @max(timing.max_ns, current);
            self.plugin_samples[index][cursor] = current;
            const memory = self.current_plugin_memory[index];
            timing.tick_memory_window_bytes = timing.tick_memory_window_bytes -
                self.plugin_memory_samples[index][cursor] + memory;
            timing.tick_memory_total_bytes +%= memory;
            timing.tick_memory_last_bytes = memory;
            timing.tick_memory_max_bytes = @max(timing.tick_memory_max_bytes, memory);
            self.plugin_memory_samples[index][cursor] = memory;
        }
    }

    pub fn setGenerationMemory(self: *Profiler, values: []const u64) void {
        std.debug.assert(values.len == self.plugins.len);
        for (self.plugins, values) |*plugin, bytes| plugin.generation_bytes = bytes;
        @memset(self.current_plugin_memory, 0);
    }

    pub fn generationMemory(self: *Profiler) []u64 {
        return self.current_plugin_memory;
    }

    fn finishTraceSamples(self: *Profiler, cursor: usize) void {
        for (0..self.registered_trace_count) |index| {
            const calls = self.current_trace_calls[index];
            const elapsed = self.current_traces[index];
            const timing = &self.traces[index];
            timing.window_ns = timing.window_ns - self.trace_samples[index][cursor] + elapsed;
            timing.total_ns +%= elapsed;
            timing.last_ns = elapsed;
            timing.max_ns = @max(timing.max_ns, elapsed);
            timing.window_calls = timing.window_calls - self.trace_call_samples[index][cursor] + calls;
            timing.total_calls +%= calls;
            timing.last_calls = calls;
            timing.max_calls = @max(timing.max_calls, calls);
            self.trace_samples[index][cursor] = elapsed;
            self.trace_call_samples[index][cursor] = calls;
        }
    }
};

var active_profiler: ?*Profiler = null;
var active_trace_base: usize = 0;
var active_trace_count: usize = 0;
var active_plugin_index: ?usize = null;

pub fn beginPlugin(index: usize, trace_base: usize, trace_count: usize) u64 {
    const profiler = active_profiler orelse return 0;
    active_trace_base = trace_base;
    active_trace_count = trace_count;
    active_plugin_index = index;
    std.debug.assert(index < profiler.plugins.len);
    std.debug.assert(trace_base + trace_count <= profiler.traces.len);
    profiler.registered_plugin_count = @max(profiler.registered_plugin_count, index + 1);
    profiler.registered_trace_count = @max(profiler.registered_trace_count, trace_base + trace_count);
    return monotonicNanoseconds();
}

pub fn endPlugin(index: usize, started_ns: u64) void {
    active_trace_base = 0;
    active_trace_count = 0;
    active_plugin_index = null;
    if (started_ns == 0) return;
    const profiler = active_profiler orelse return;
    std.debug.assert(index < profiler.current_plugins.len);
    profiler.current_plugins[index] +%= monotonicNanoseconds() -| started_ns;
}

pub fn recordTickMemory(bytes: usize) void {
    const profiler = active_profiler orelse return;
    const index = active_plugin_index orelse return;
    std.debug.assert(index < profiler.current_plugin_memory.len);
    profiler.current_plugin_memory[index] +|= @intCast(bytes);
}

pub const TraceSpan = struct {
    index: usize = 0,
    started_ns: u64 = 0,

    pub inline fn end(self: *TraceSpan) void {
        if (self.started_ns == 0) return;
        const profiler = active_profiler orelse {
            self.started_ns = 0;
            return;
        };
        profiler.current_traces[self.index] +%= monotonicNanoseconds() -| self.started_ns;
        self.started_ns = 0;
    }
};

pub inline fn beginTrace(comptime trace: anytype) TraceSpan {
    requireTraceEnum(@TypeOf(trace));
    const local_index: usize = @intFromEnum(trace);
    if (active_profiler == null or local_index >= active_trace_count) return .{};
    const index = active_trace_base + local_index;
    const profiler = active_profiler.?;
    std.debug.assert(index < profiler.current_traces.len);
    profiler.current_trace_calls[index] +%= 1;
    return .{ .index = index, .started_ns = monotonicNanoseconds() };
}

pub inline fn countTrace(comptime trace: anytype, count: usize) void {
    requireTraceEnum(@TypeOf(trace));
    const local_index: usize = @intFromEnum(trace);
    if (active_profiler == null or local_index >= active_trace_count) return;
    const index = active_trace_base + local_index;
    std.debug.assert(index < active_profiler.?.current_trace_calls.len);
    active_profiler.?.current_trace_calls[index] +|= @intCast(@min(count, std.math.maxInt(u32)));
}

fn requireTraceEnum(comptime Trace: type) void {
    if (@typeInfo(Trace) != .@"enum") @compileError("plugin trace identifiers must be enum values");
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "profiler maintains a bounded rolling plugin window" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 3, 0);
    profiler.setEnabled(true);
    profiler.registered_plugin_count = 3;
    for (0..window_ticks + 1) |index| {
        profiler.beginTick();
        profiler.current_plugins[2] = @intCast(index + 1);
        profiler.finishTick();
    }
    try std.testing.expectEqual(@as(u64, window_ticks + 1), profiler.tick_count);
    try std.testing.expectEqual(@as(usize, window_ticks), profiler.window_count);
    try std.testing.expectEqual(@as(u64, 5150), profiler.plugins[2].window_ns);
    try std.testing.expectEqual(@as(u64, window_ticks + 1), profiler.plugins[2].last_ns);
}

test "named trace scopes record time and call frequency" {
    const TestTrace = enum { work };
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 3, 8);
    profiler.setEnabled(true);
    profiler.beginTick();
    const started = beginPlugin(2, 7, 1);
    for (0..200) |_| {
        var trace = beginTrace(TestTrace.work);
        trace.end();
    }
    endPlugin(2, started);
    profiler.finishTick();
    try std.testing.expectEqual(@as(u32, 200), profiler.traces[7].last_calls);
    try std.testing.expectEqual(@as(u64, 200), profiler.traces[7].window_calls);
    try std.testing.expect(profiler.traces[7].window_ns > 0);
}

test "profiler rolls plugin temporary memory over the timing window" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 1, 0);
    profiler.setGenerationMemory(&.{4096});
    profiler.setEnabled(true);
    for (0..window_ticks + 1) |index| {
        profiler.beginTick();
        const started = beginPlugin(0, 0, 0);
        recordTickMemory(index + 1);
        endPlugin(0, started);
        profiler.finishTick();
    }
    try std.testing.expectEqual(@as(u64, 4096), profiler.plugins[0].generation_bytes);
    try std.testing.expectEqual(@as(u64, 5150), profiler.plugins[0].tick_memory_window_bytes);
    try std.testing.expectEqual(@as(u64, 101), profiler.plugins[0].tick_memory_last_bytes);
}
