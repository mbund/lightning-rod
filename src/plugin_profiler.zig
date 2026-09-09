const std = @import("std");
const metrics = @import("metrics.zig");
const preallocated = @import("preallocated");

pub const window_ticks = 100;

pub const PluginTiming = struct {
    initialization_ns: u64 = 0,
    checkpoint_ns: u64 = 0,
    closing_ns: u64 = 0,
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

pub const Counter = struct {
    context: *const anyopaque,
    read_fn: *const fn (context: *const anyopaque) u64,

    pub fn read(self: Counter) u64 {
        return self.read_fn(self.context);
    }
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

const Name = struct {
    ptr: [*]const u8 = "".ptr,
    len: usize = 0,
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
    plugin_names: []Name = &.{},
    generation_plugin_memory: []u64 = &.{},
    current_plugins: []u64 = &.{},
    current_plugin_memory: []u64 = &.{},
    trace_samples: []align(64) [window_ticks]u64 = &.{},
    trace_call_samples: []align(64) [window_ticks]u32 = &.{},
    traces: []TraceTiming = &.{},
    trace_plugin_indices: []usize = &.{},
    trace_names: []Name = &.{},
    current_traces: []u64 = &.{},
    current_trace_calls: []u32 = &.{},
    published: metrics.Snapshot = .{},
    registered_plugin_count: usize = 0,
    registered_trace_count: usize = 0,
    tick_started_ns: u64 = 0,
    counter: ?Counter = null,

    pub fn setCounter(self: *Profiler, counter: Counter) void {
        self.counter = counter;
    }

    pub fn allocate(self: *Profiler, allocator: std.mem.Allocator, plugin_count: usize, trace_count: usize) !void {
        self.* = .{};
        self.tick_samples = try preallocated.alloc(u64, allocator, window_ticks);
        self.plugin_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", plugin_count);
        self.plugin_memory_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", plugin_count);
        self.plugins = try preallocated.alloc(PluginTiming, allocator, plugin_count);
        self.plugin_names = try preallocated.alloc(Name, allocator, plugin_count);
        self.generation_plugin_memory = try preallocated.alloc(u64, allocator, plugin_count);
        self.current_plugins = try preallocated.alloc(u64, allocator, plugin_count);
        self.current_plugin_memory = try preallocated.alloc(u64, allocator, plugin_count);
        self.trace_samples = try preallocated.alignedAlloc([window_ticks]u64, allocator, .@"64", trace_count);
        self.trace_call_samples = try preallocated.alignedAlloc([window_ticks]u32, allocator, .@"64", trace_count);
        self.traces = try preallocated.alloc(TraceTiming, allocator, trace_count);
        self.trace_plugin_indices = try preallocated.alloc(usize, allocator, trace_count);
        self.trace_names = try preallocated.alloc(Name, allocator, trace_count);
        self.current_traces = try preallocated.alloc(u64, allocator, trace_count);
        self.current_trace_calls = try preallocated.alloc(u32, allocator, trace_count);
        self.published.plugins = try preallocated.alloc(metrics.Plugin, allocator, plugin_count);
        self.published.traces = try preallocated.alloc(metrics.Trace, allocator, trace_count);
        self.clear(false);
    }

    pub fn setEnabled(self: *Profiler, enabled: bool) error{MissingCounter}!void {
        if (!enabled) {
            self.enabled = false;
            return;
        }
        if (self.counter == null) return error.MissingCounter;
        if (!self.enabled) self.clear(true);
    }

    fn clear(self: *Profiler, enabled: bool) void {
        const tick_samples = self.tick_samples;
        const plugin_samples = self.plugin_samples;
        const plugin_memory_samples = self.plugin_memory_samples;
        const plugins = self.plugins;
        const plugin_names = self.plugin_names;
        const generation_plugin_memory = self.generation_plugin_memory;
        const current_plugins = self.current_plugins;
        const current_plugin_memory = self.current_plugin_memory;
        const trace_samples = self.trace_samples;
        const trace_call_samples = self.trace_call_samples;
        const traces = self.traces;
        const trace_plugin_indices = self.trace_plugin_indices;
        const trace_names = self.trace_names;
        const current_traces = self.current_traces;
        const current_trace_calls = self.current_trace_calls;
        const published = self.published;
        const registered_plugin_count = self.registered_plugin_count;
        const registered_trace_count = self.registered_trace_count;
        const counter = self.counter;
        self.* = .{
            .enabled = enabled,
            .tick_samples = tick_samples,
            .plugin_samples = plugin_samples,
            .plugin_memory_samples = plugin_memory_samples,
            .plugins = plugins,
            .plugin_names = plugin_names,
            .generation_plugin_memory = generation_plugin_memory,
            .current_plugins = current_plugins,
            .current_plugin_memory = current_plugin_memory,
            .trace_samples = trace_samples,
            .trace_call_samples = trace_call_samples,
            .traces = traces,
            .trace_plugin_indices = trace_plugin_indices,
            .trace_names = trace_names,
            .current_traces = current_traces,
            .current_trace_calls = current_trace_calls,
            .published = published,
            .registered_plugin_count = registered_plugin_count,
            .registered_trace_count = registered_trace_count,
            .counter = counter,
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
        std.debug.assert(active_profiler == null);
        if (!self.enabled) return;
        @memset(self.current_plugins[0..self.registered_plugin_count], 0);
        @memset(self.current_plugin_memory[0..self.registered_plugin_count], 0);
        @memset(self.current_traces[0..self.registered_trace_count], 0);
        @memset(self.current_trace_calls[0..self.registered_trace_count], 0);
        self.tick_started_ns = self.now();
        active_profiler = self;
    }

    pub fn finishTick(self: *Profiler) void {
        if (!self.enabled) return;
        std.debug.assert(active_profiler == self);
        const tick_duration = self.duration(self.tick_started_ns);
        active_profiler = null;
        const cursor = self.window_cursor;
        self.finishTickSample(cursor, tick_duration);
        self.finishPluginSamples(cursor);
        self.finishTraceSamples(cursor);
        self.tick_count +%= 1;
        if (self.window_count < window_ticks) self.window_count += 1;
        self.window_cursor = (cursor + 1) % window_ticks;
    }

    fn finishTickSample(self: *Profiler, cursor: usize, duration_ns: u64) void {
        self.tick_window_ns = self.tick_window_ns - self.tick_samples[cursor] + duration_ns;
        self.tick_samples[cursor] = duration_ns;
        self.tick_last_ns = duration_ns;
        self.tick_total_ns +%= duration_ns;
        self.tick_max_ns = @max(self.tick_max_ns, duration_ns);
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
        std.mem.copyForwards(u64, self.generation_plugin_memory, values);
        for (self.plugins, values) |*plugin, bytes| plugin.generation_bytes = bytes;
        @memset(self.current_plugin_memory, 0);
    }

    pub fn setMemory(self: *Profiler, capacity: usize, generation: usize, temporary: usize) void {
        self.published.memory_capacity_bytes = @intCast(capacity);
        self.published.generation_memory_bytes = @intCast(generation);
        self.published.tick_memory_capacity_bytes = @intCast(temporary);
    }

    pub fn setPluginName(self: *Profiler, index: usize, name: []const u8) void {
        std.debug.assert(index < self.plugin_names.len);
        self.plugin_names[index] = .{ .ptr = name.ptr, .len = name.len };
    }

    pub fn setTrace(self: *Profiler, index: usize, plugin_index: usize, name: []const u8) void {
        std.debug.assert(index < self.trace_names.len);
        std.debug.assert(plugin_index < self.plugin_names.len);
        self.trace_plugin_indices[index] = plugin_index;
        self.trace_names[index] = .{ .ptr = name.ptr, .len = name.len };
        self.registered_trace_count = @max(self.registered_trace_count, index + 1);
    }

    pub fn snapshot(self: *Profiler) *const metrics.Snapshot {
        const destination = &self.published;
        destination.revision = self.tick_count;
        destination.tick_count = self.tick_count;
        destination.tick_total_ns = self.tick_total_ns;
        destination.tick_window_ns = self.tick_window_ns;
        destination.tick_window_max_ns = 0;
        for (self.tick_samples[0..self.window_count]) |sample|
            destination.tick_window_max_ns = @max(destination.tick_window_max_ns, sample);
        destination.tick_last_ns = self.tick_last_ns;
        destination.tick_max_ns = self.tick_max_ns;
        destination.window_count = self.window_count;
        destination.plugin_count = self.registered_plugin_count;
        destination.trace_count = self.registered_trace_count;
        self.copyPlugins(destination);
        self.copyTraces(destination);
        return destination;
    }

    fn copyPlugins(self: *const Profiler, destination: *metrics.Snapshot) void {
        std.debug.assert(destination.plugin_count <= destination.plugins.len);
        for (destination.plugins[0..destination.plugin_count], 0..) |*item, index| {
            const timing = self.plugins[index];
            const name = self.plugin_names[index];
            var window_max_ns: u64 = 0;
            for (self.plugin_samples[index][0..self.window_count]) |sample|
                window_max_ns = @max(window_max_ns, sample);
            item.* = .{
                .id_ptr = name.ptr,
                .id_len = name.len,
                .total_ns = timing.total_ns,
                .window_ns = timing.window_ns,
                .window_max_ns = window_max_ns,
                .last_ns = timing.last_ns,
                .max_ns = timing.max_ns,
                .generation_bytes = timing.generation_bytes,
                .tick_memory_total_bytes = timing.tick_memory_total_bytes,
                .tick_memory_window_bytes = timing.tick_memory_window_bytes,
                .tick_memory_last_bytes = timing.tick_memory_last_bytes,
                .tick_memory_max_bytes = timing.tick_memory_max_bytes,
            };
        }
    }

    fn copyTraces(self: *const Profiler, destination: *metrics.Snapshot) void {
        std.debug.assert(destination.trace_count <= destination.traces.len);
        for (destination.traces[0..destination.trace_count], 0..) |*item, index| {
            const timing = self.traces[index];
            const name = self.trace_names[index];
            item.* = .{
                .plugin_index = self.trace_plugin_indices[index],
                .name_ptr = name.ptr,
                .name_len = name.len,
                .total_ns = timing.total_ns,
                .window_ns = timing.window_ns,
                .last_ns = timing.last_ns,
                .max_ns = timing.max_ns,
                .total_calls = timing.total_calls,
                .window_calls = timing.window_calls,
                .last_calls = timing.last_calls,
                .max_calls = timing.max_calls,
            };
        }
    }

    pub fn beginInitialization(self: *Profiler, index: usize) u64 {
        self.registered_plugin_count = @max(self.registered_plugin_count, index + 1);
        return self.now();
    }

    pub fn endInitialization(self: *Profiler, index: usize, started: u64) void {
        self.plugins[index].initialization_ns +%= self.duration(started);
    }

    pub fn beginCheckpoint(self: *Profiler, index: usize) u64 {
        self.registered_plugin_count = @max(self.registered_plugin_count, index + 1);
        return self.now();
    }

    pub fn endCheckpoint(self: *Profiler, index: usize, started: u64) void {
        self.plugins[index].checkpoint_ns +%= self.duration(started);
    }

    pub fn beginClosing(self: *Profiler, index: usize) u64 {
        self.registered_plugin_count = @max(self.registered_plugin_count, index + 1);
        return self.now();
    }

    pub fn endClosing(self: *Profiler, index: usize, started: u64) void {
        self.plugins[index].closing_ns +%= self.duration(started);
    }

    fn now(self: *const Profiler) u64 {
        return if (self.counter) |counter| counter.read() else 0;
    }

    fn duration(self: *const Profiler, started: u64) u64 {
        return self.now() -| started;
    }

    pub fn generationMemory(self: *Profiler) []u64 {
        return self.generation_plugin_memory;
    }

    fn finishTraceSamples(self: *Profiler, cursor: usize) void {
        for (0..self.registered_trace_count) |index| {
            const calls = self.current_trace_calls[index];
            const trace_duration = self.current_traces[index];
            const timing = &self.traces[index];
            timing.window_ns = timing.window_ns - self.trace_samples[index][cursor] + trace_duration;
            timing.total_ns +%= trace_duration;
            timing.last_ns = trace_duration;
            timing.max_ns = @max(timing.max_ns, trace_duration);
            timing.window_calls = timing.window_calls - self.trace_call_samples[index][cursor] + calls;
            timing.total_calls +%= calls;
            timing.last_calls = calls;
            timing.max_calls = @max(timing.max_calls, calls);
            self.trace_samples[index][cursor] = trace_duration;
            self.trace_call_samples[index][cursor] = calls;
        }
    }
};

threadlocal var active_profiler: ?*Profiler = null;
threadlocal var active_trace_base: usize = 0;
threadlocal var active_trace_count: usize = 0;
threadlocal var active_plugin_index: ?usize = null;

pub fn snapshotActive() ?*const metrics.Snapshot {
    const profiler = active_profiler orelse return null;
    return profiler.snapshot();
}

pub fn tickElapsedNanoseconds() ?u64 {
    const profiler = active_profiler orelse return null;
    return profiler.now() -| profiler.tick_started_ns;
}

pub fn beginPlugin(index: usize, trace_base: usize, trace_count: usize) ?u64 {
    const profiler = active_profiler orelse return null;
    active_trace_base = trace_base;
    active_trace_count = trace_count;
    active_plugin_index = index;
    std.debug.assert(index < profiler.plugins.len);
    std.debug.assert(trace_base + trace_count <= profiler.traces.len);
    profiler.registered_plugin_count = @max(profiler.registered_plugin_count, index + 1);
    profiler.registered_trace_count = @max(profiler.registered_trace_count, trace_base + trace_count);
    return monotonicNanoseconds();
}

pub fn endPlugin(index: usize, started_ns: ?u64) void {
    active_trace_base = 0;
    active_trace_count = 0;
    active_plugin_index = null;
    const started = started_ns orelse return;
    const profiler = active_profiler orelse return;
    std.debug.assert(index < profiler.current_plugins.len);
    profiler.current_plugins[index] +%= monotonicNanoseconds() -| started;
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
    active: bool = false,

    pub inline fn end(self: *TraceSpan) void {
        if (!self.active) return;
        const profiler = active_profiler orelse {
            self.active = false;
            return;
        };
        profiler.current_traces[self.index] +%= monotonicNanoseconds() -| self.started_ns;
        self.active = false;
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
    return .{ .index = index, .started_ns = monotonicNanoseconds(), .active = true };
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
    const profiler = active_profiler orelse return 0;
    return profiler.now();
}

test "profiler maintains a bounded rolling plugin window" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 3, 0);
    profiler.setCounter(testCounter());
    try profiler.setEnabled(true);
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
    profiler.setCounter(testCounter());
    try profiler.setEnabled(true);
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

test "snapshot preserves every allocated plugin and trace name" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 2, 2);
    profiler.setPluginName(0, "test:first");
    profiler.setPluginName(1, "test:second");
    profiler.setTrace(0, 1, "read");
    profiler.setTrace(1, 1, "write");
    profiler.registered_plugin_count = 2;
    const view = profiler.snapshot();
    try std.testing.expectEqual(@as(usize, 2), view.plugin_count);
    try std.testing.expectEqual(@as(usize, 2), view.trace_count);
    try std.testing.expectEqualStrings("test:second", view.plugins[1].id());
    try std.testing.expectEqual(@as(usize, 1), view.traces[0].plugin_index);
    try std.testing.expectEqualStrings("write", view.traces[1].name());
}

test "profiler rolls plugin temporary memory over the timing window" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 1, 0);
    profiler.setGenerationMemory(&.{4096});
    profiler.setCounter(testCounter());
    try profiler.setEnabled(true);
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

fn testCounter() Counter {
    return .{ .context = &test_counter_value, .read_fn = readTestCounter };
}

fn readTestCounter(context: *const anyopaque) u64 {
    const value: *std.atomic.Value(u64) = @ptrCast(@alignCast(@constCast(context)));
    return value.fetchAdd(1, .monotonic);
}

var test_counter_value: std.atomic.Value(u64) = .init(1);

test "enabled profiling requires a monotonic counter" {
    var profiler: Profiler = .{};
    try std.testing.expectError(error.MissingCounter, profiler.setEnabled(true));
    try std.testing.expect(!profiler.enabled);
}

test "zero is a valid monotonic counter value" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 1, 0);
    var value: std.atomic.Value(u64) = .init(0);
    profiler.setCounter(.{ .context = &value, .read_fn = readTestCounter });
    const started = profiler.beginInitialization(0);
    profiler.endInitialization(0, started);
    try std.testing.expectEqual(@as(u64, 1), profiler.plugins[0].initialization_ns);
}

test "active tick elapsed time uses the configured monotonic counter" {
    var profiler: Profiler = .{};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try profiler.allocate(arena.allocator(), 1, 0);
    var value: std.atomic.Value(u64) = .init(41);
    profiler.setCounter(.{ .context = &value, .read_fn = readTestCounter });
    try profiler.setEnabled(true);
    profiler.beginTick();
    try std.testing.expectEqual(@as(?u64, 1), tickElapsedNanoseconds());
    profiler.finishTick();
    try std.testing.expectEqual(@as(?u64, null), tickElapsedNanoseconds());
}

test "concurrent Core profiling remains isolated across worker threads" {
    const Worker = struct {
        profiler: *Profiler,
        started: std.Io.Event = .unset,
        release: std.Io.Event = .unset,

        fn run(self: *@This()) void {
            self.profiler.beginTick();
            const started = beginPlugin(0, 0, 0);
            self.started.set(std.testing.io);
            self.release.wait(std.testing.io) catch unreachable;
            recordTickMemory(22);
            endPlugin(0, started);
            self.profiler.finishTick();
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var first: Profiler = .{};
    var second: Profiler = .{};
    for ([_]*Profiler{ &first, &second }) |profiler| {
        try profiler.allocate(arena.allocator(), 1, 0);
        profiler.setCounter(testCounter());
        try profiler.setEnabled(true);
    }
    var worker: Worker = .{ .profiler = &second };
    {
        const thread = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        defer {
            worker.release.set(std.testing.io);
            thread.join();
        }
        try worker.started.wait(std.testing.io);
        first.beginTick();
        const started = beginPlugin(0, 0, 0);
        recordTickMemory(11);
        endPlugin(0, started);
        first.finishTick();
        try std.testing.expectEqual(@as(u64, 11), first.plugins[0].tick_memory_last_bytes);
        try std.testing.expectEqual(@as(?u64, null), tickElapsedNanoseconds());
    }
    try std.testing.expectEqual(@as(u64, 22), second.plugins[0].tick_memory_last_bytes);
    second.beginTick();
    const started = beginPlugin(0, 0, 0);
    recordTickMemory(33);
    endPlugin(0, started);
    second.finishTick();
    try std.testing.expectEqual(@as(u64, 55), second.plugins[0].tick_memory_window_bytes);
}
