const lightning_rod = @import("lightning_rod");
const metrics = lightning_rod.metrics;
const plugin_profiler = lightning_rod.plugin_profiler;
const preallocated = lightning_rod.preallocated;
const std = @import("std");

pub const Dimensions = struct {
    rows: usize = 24,
    columns: usize = 100,
};

pub const Snapshot = struct {
    revision: u64 = 0,
    metrics: metrics.Snapshot = .{},
};

pub const Plugin = struct {
    pub const id = "lightning_rod:tui";

    pub const Configuration = struct {
        source: ?metrics.Source = null,
        period_ticks: u32 = 5,
    };

    source: ?metrics.Source,
    period_ticks: u32,
    ticks_until_capture: u32 = 0,
    source_revision: u64 = 0,
    captured: bool = false,
    published: Snapshot = .{},

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Plugin {
        if (configuration.period_ticks == 0) return error.InvalidPeriod;
        const self = try preallocated.create(Plugin, allocator);
        self.* = .{
            .source = configuration.source,
            .period_ticks = configuration.period_ticks,
        };
        return self;
    }

    pub fn tick(self: *Plugin) void {
        if (self.ticks_until_capture != 0) {
            self.ticks_until_capture -= 1;
            return;
        }
        self.ticks_until_capture = self.period_ticks - 1;
        self.capture();
    }

    pub fn snapshot(self: *const Plugin) *const Snapshot {
        return &self.published;
    }

    fn capture(self: *Plugin) void {
        if (self.source) |source| return self.captureSource(source);
        const observed = plugin_profiler.snapshotActive() orelse return;
        self.published.metrics = observed.*;
        self.published.revision +%= 1;
        self.captured = true;
    }

    fn captureSource(self: *Plugin, source: metrics.Source) void {
        const observed = source.snapshot();
        if (self.captured and observed.revision == self.source_revision) return;
        self.published.metrics = observed.*;
        self.published.revision +%= 1;
        self.source_revision = observed.revision;
        self.captured = true;
    }
};

pub fn render(snapshot: *const Snapshot, dimensions: Dimensions, writer: *std.Io.Writer) !void {
    try renderHeader(snapshot, writer);
    try renderWorld(snapshot.metrics, writer);
    try renderPlugins(snapshot.metrics, dimensions, writer);
    try renderTraces(snapshot.metrics, dimensions, writer);
    try writer.writeAll("\x1b[0m");
}

fn renderHeader(snapshot: *const Snapshot, writer: *std.Io.Writer) !void {
    const value = snapshot.metrics;
    const average_ns = if (value.window_count == 0) 0 else value.tick_window_ns / value.window_count;
    try writer.writeAll("\x1b[H\x1b[2J\x1b[1;36mLIGHTNING ROD\x1b[0m\n");
    try writer.print("metrics revision {d}  tick {d}\n", .{ snapshot.revision, value.tick_count });
    try writer.print("MSPT avg {d:.3}  last {d:.3}  max {d:.3}\n", .{
        milliseconds(average_ns),
        milliseconds(value.tick_last_ns),
        milliseconds(value.tick_max_ns),
    });
    try writer.writeAll("Memory generation ");
    try renderBytes(writer, value.generation_memory_bytes);
    try writer.writeAll("  temporary capacity ");
    try renderBytes(writer, value.tick_memory_capacity_bytes);
    try writer.writeByte('\n');
}

fn renderWorld(value: metrics.Snapshot, writer: *std.Io.Writer) !void {
    try writer.print("World tick {d}  living {d}  items {d}\n", .{
        value.world_tick,
        value.living_entities,
        value.item_entities,
    });
    try writer.print("Resident sections {d}  modified blocks {d}  terrain pending {d}\n", .{
        value.resident_sections,
        value.modified_blocks,
        value.pending_terrain_chunks,
    });
}

fn renderPlugins(value: metrics.Snapshot, dimensions: Dimensions, writer: *std.Io.Writer) !void {
    const count = @min(value.plugin_count, value.plugins.len);
    const rows = dimensions.rows -| 7;
    const visible = @min(count, rows);
    try writer.writeAll("\n\x1b[1mPlugins — average time and temporary memory\x1b[0m\n");
    for (value.plugins[0..visible]) |plugin| try renderPlugin(value.window_count, plugin, dimensions.columns, writer);
    if (visible < count) try writer.print("… {d} plugins hidden\n", .{count - visible});
}

fn renderTraces(value: metrics.Snapshot, dimensions: Dimensions, writer: *std.Io.Writer) !void {
    const count = @min(value.trace_count, value.traces.len);
    const rows = dimensions.rows -| 10;
    const visible = @min(count, rows);
    if (visible == 0) return;
    try writer.writeAll("\n\x1b[1mTraces — average time and calls\x1b[0m\n");
    for (value.traces[0..visible]) |trace| {
        const plugin_name = if (trace.plugin_index < value.plugin_count)
            value.plugins[trace.plugin_index].id()
        else
            "unknown";
        const average_ns = if (value.window_count == 0) 0 else trace.window_ns / value.window_count;
        try writer.print("{s}/{s} {d:.3}ms  {d} calls\n", .{
            plugin_name,
            trace.name(),
            milliseconds(average_ns),
            trace.last_calls,
        });
    }
    if (visible < count) try writer.print("… {d} traces hidden\n", .{count - visible});
}

fn renderPlugin(window_count: usize, plugin: metrics.Plugin, columns: usize, writer: *std.Io.Writer) !void {
    const name_width = @min(columns -| 24, @as(usize, 48));
    const name = plugin.id()[0..@min(plugin.id().len, name_width)];
    const average_ns = if (window_count == 0) 0 else plugin.window_ns / window_count;
    try writer.print("{s} {d:.3}ms  tmp ", .{ name, milliseconds(average_ns) });
    try renderBytes(writer, plugin.tick_memory_last_bytes);
    try writer.writeByte('\n');
}

fn renderBytes(writer: *std.Io.Writer, bytes: u64) !void {
    if (bytes < 1024) return writer.print("{d}B", .{bytes});
    if (bytes < 1024 * 1024) return writer.print("{d:.1}KiB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    return writer.print("{d:.1}MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

test "plugin captures a changed immutable source on its configured period" {
    var source_snapshot: metrics.Snapshot = .{ .revision = 1, .tick_count = 4 };
    var bytes: [@sizeOf(Plugin) + 64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    const plugin = try Plugin.init(fixed.allocator(), .{ .source = metrics.static(&source_snapshot), .period_ticks = 2 });
    plugin.tick();
    try std.testing.expectEqual(@as(u64, 4), plugin.snapshot().metrics.tick_count);
    source_snapshot = .{ .revision = 2, .tick_count = 9 };
    plugin.tick();
    try std.testing.expectEqual(@as(u64, 4), plugin.snapshot().metrics.tick_count);
    plugin.tick();
    try std.testing.expectEqual(@as(u64, 9), plugin.snapshot().metrics.tick_count);
}

test "renderer is bounded and contains no terminal dependency" {
    const name = "test:plugin";
    var plugins = [_]metrics.Plugin{.{ .id_ptr = name.ptr, .id_len = name.len }};
    const snapshot: Snapshot = .{ .revision = 1, .metrics = .{
        .tick_count = 2,
        .plugin_count = 1,
        .plugins = &plugins,
    } };
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try render(&snapshot, .{}, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "test:plugin") != null);
}
