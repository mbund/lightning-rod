const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const metrics_abi = @import("hot_reload_abi.zig");

const stdout_fd = 1;
const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H";
const leave_screen = "\x1b[?25h\x1b[?1049l";

pub const Snapshot = struct {
    metrics: metrics_abi.MetricsSnapshot,
    world_tick: u64,
    target_tps: u64,
    pending_ticks: u8,
    connected_sockets: usize,
    reserved_players: usize,
    play_players: usize,
    maximum_players: usize,
    living_entities: usize,
    item_entities: usize,
    resident_sections: usize,
    modified_blocks: usize,
    cached_chunks: usize,
    pending_terrain_chunks: usize,
    output_buffers_used: usize,
    output_buffers_total: usize,
    io_submissions: u64 = 0,
    io_completions: u64 = 0,
    io_last_completions: u32 = 0,
    io_peak_completions: u32 = 0,
    terrain_last_ns: u64 = 0,
    terrain_max_ns: u64 = 0,
    tick_generation: u64,
    protocols: [32]i32 = [_]i32{0} ** 32,
    protocol_count: usize = 0,
};

pub const Terminal = struct {
    active: bool = false,

    pub fn init() !Terminal {
        if (queryTerminalSize() == null) return error.TuiRequiresTerminal;
        try writeAll(enter_screen);
        return .{ .active = true };
    }

    pub fn deinit(self: *Terminal) void {
        if (!self.active) return;
        writeAll(leave_screen) catch {};
        self.active = false;
    }

    pub fn draw(self: *Terminal, snapshot: *const Snapshot) !void {
        if (!self.active) return;
        var buffer: [32 * 1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const size = terminalSize();
        try render(snapshot, size.rows, size.cols, &writer);
        try writeAll(writer.buffered());
    }
};

const TerminalSize = struct { rows: usize, cols: usize };

fn terminalSize() TerminalSize {
    return queryTerminalSize() orelse .{ .rows = 24, .cols = 80 };
}

fn queryTerminalSize() ?TerminalSize {
    var value: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = linux.ioctl(stdout_fd, linux.T.IOCGWINSZ, @intFromPtr(&value));
    if (linux.errno(result) != .SUCCESS or value.row == 0 or value.col == 0) return null;
    return .{ .rows = value.row, .cols = value.col };
}

fn writeAll(bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const result = linux.write(stdout_fd, remaining.ptr, remaining.len);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.WriteFailed;
                remaining = remaining[result..];
            },
            .INTR => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub fn render(snapshot: *const Snapshot, rows: usize, cols: usize, writer: *std.Io.Writer) !void {
    const metrics = &snapshot.metrics;
    const window_count = metrics.window_count;
    const average_tick_ns = average(metrics.tick_window_ns, window_count);
    try renderSummary(snapshot, average_tick_ns, writer);
    const trace_count = @min(metrics.trace_count, metrics.traces.len);
    const visible_trace_rows = @min(trace_count, @min(@as(usize, 6), rows -| 19));
    try renderTraces(metrics, window_count, visible_trace_rows, trace_count, cols, writer);
    const workload_rows = try renderWorkload(snapshot, metrics, writer);
    try renderPlugins(metrics, rows, cols, visible_trace_rows, trace_count, workload_rows, average_tick_ns, writer);
    try writer.writeAll("\x1b[0m");
}

fn renderSummary(snapshot: *const Snapshot, average_tick_ns: u64, writer: *std.Io.Writer) !void {
    const metrics = &snapshot.metrics;
    const average_ms = nanosecondsToMilliseconds(average_tick_ns);
    const last_ms = nanosecondsToMilliseconds(metrics.tick_last_ns);
    const max_ms = nanosecondsToMilliseconds(metrics.tick_max_ns);
    const tick_budget_ms = if (snapshot.target_tps == 0) 0 else 1000.0 / @as(f64, @floatFromInt(snapshot.target_tps));

    try writer.writeAll("\x1b[H\x1b[2J\x1b[1;36mLIGHTNING ROD\x1b[0m  high-performance Minecraft server\n");
    try writer.print("Tick {d}   target {d} TPS   backlog {d}   generation {d}\n", .{
        snapshot.world_tick,
        snapshot.target_tps,
        snapshot.pending_ticks,
        snapshot.tick_generation,
    });
    try writer.print("MSPT  avg \x1b[1m{d:.3}\x1b[0m   last {d:.3}   max {d:.3}   budget {d:.1}\n", .{ average_ms, last_ms, max_ms, tick_budget_ms });
    try writer.print("Players  play {d} / reserved {d} / limit {d}   sockets {d}\n", .{
        snapshot.play_players,
        snapshot.reserved_players,
        snapshot.maximum_players,
        snapshot.connected_sockets,
    });
    try writer.writeAll("Protocols ");
    if (snapshot.protocol_count == 0) {
        try writer.writeAll("none");
    } else {
        for (snapshot.protocols[0..snapshot.protocol_count], 0..) |protocol, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.print("{d}", .{protocol});
        }
    }
    try writer.writeByte('\n');
    try writer.print("World  living {d}   items {d}   resident sections {d}   modified blocks {d}\n", .{
        snapshot.living_entities,
        snapshot.item_entities,
        snapshot.resident_sections,
        snapshot.modified_blocks,
    });
    try writer.print("Streaming  cached chunks {d}   terrain queue {d}   output buffers {d}/{d}\n", .{
        snapshot.cached_chunks,
        snapshot.pending_terrain_chunks,
        snapshot.output_buffers_used,
        snapshot.output_buffers_total,
    });
    try writer.print(
        "I/O  submissions {d}   completions {d}   CQEs last/peak {d}/{d}\n",
        .{
            snapshot.io_submissions,
            snapshot.io_completions,
            snapshot.io_last_completions,
            snapshot.io_peak_completions,
        },
    );
    try writer.print("Terrain generation  last {d:.3}ms   max {d:.3}ms\n", .{
        nanosecondsToMilliseconds(snapshot.terrain_last_ns),
        nanosecondsToMilliseconds(snapshot.terrain_max_ns),
    });
    try writer.writeAll("Memory  generation ");
    try renderBytes(writer, metrics.generation_memory_bytes);
    try writer.writeAll("   tick temporary avg ");
    try renderBytes(writer, averageTickMemory(metrics));
    try writer.writeAll(" / capacity ");
    try renderBytes(writer, metrics.tick_memory_capacity_bytes);
    try writer.writeByte('\n');
}

fn renderTraces(metrics: *const metrics_abi.MetricsSnapshot, window_count: usize, visible: usize, total: usize, cols: usize, writer: *std.Io.Writer) !void {
    try writer.writeAll("\n\x1b[1mHottest named plugin traces — inclusive average over the last 100 ticks\x1b[0m\n");
    var trace_order: [metrics_abi.metrics_trace_capacity]u16 = undefined;
    sortTraceIndices(metrics, total, &trace_order);
    for (trace_order[0..visible]) |trace_index|
        try renderTraceLine(writer, metrics, metrics.traces[trace_index], window_count, cols);
    if (visible == 0) try writer.writeAll("No plugin traces declared.\n");
    if (visible < total) try writer.print("… {d} named traces hidden\n", .{total - visible});
}

fn renderWorkload(snapshot: *const Snapshot, metrics: *const metrics_abi.MetricsSnapshot, writer: *std.Io.Writer) !usize {
    const has_random_tick_workload = traceCallsPerTick(metrics, "minecraft:random_ticks", "action_chunks") != null;
    if (!has_random_tick_workload) return 0;
    try writer.print("Random tick workload  chunks {d:.1}  sections {d:.1}  probes {d:.1}  hits {d:.2}  unindexed {d:.1}\n", .{
        traceCallsPerTick(metrics, "minecraft:random_ticks", "action_chunks").?,
        traceCallsPerTick(metrics, "minecraft:random_ticks", "action_sections") orelse 0,
        traceCallsPerTick(metrics, "minecraft:random_ticks", "coordinate_probes") orelse 0,
        traceCallsPerTick(metrics, "minecraft:random_ticks", "action_hits") orelse 0,
        traceCallsPerTick(metrics, "minecraft:random_ticks", "unindexed_sections") orelse 0,
    });
    try writer.print("Leaf drops (generation total)  decays {d}  sapling rolls {d}  spawned {d}  active world items {d}  failures {d}  capacity {d}\n", .{
        traceTotalCalls(metrics, "minecraft:random_ticks", "leaf_decays") orelse 0,
        traceTotalCalls(metrics, "minecraft:random_ticks", "leaf_sapling_rolls") orelse 0,
        traceTotalCalls(metrics, "minecraft:random_ticks", "leaf_sapling_spawns") orelse 0,
        snapshot.item_entities,
        traceTotalCalls(metrics, "minecraft:random_ticks", "leaf_drop_spawn_failures") orelse 0,
        traceTotalCalls(metrics, "minecraft:random_ticks", "leaf_drop_capacity_failures") orelse 0,
    });
    try writer.print("Item lifecycle (generation total)  player pickup {d}  zombie pickup {d}  merges {d}  despawns {d}\n", .{
        traceTotalCalls(metrics, "minecraft:item_entity_tick", "player_pickups") orelse 0,
        traceTotalCalls(metrics, "minecraft:zombie_loot_pickup", "pickups") orelse 0,
        traceTotalCalls(metrics, "minecraft:item_entity_tick", "stack_merges") orelse 0,
        traceTotalCalls(metrics, "minecraft:item_entity_tick", "despawns") orelse 0,
    });
    return 3;
}

fn renderPlugins(metrics: *const metrics_abi.MetricsSnapshot, rows: usize, cols: usize, trace_rows: usize, trace_count: usize, workload_rows: usize, average_tick_ns: u64, writer: *std.Io.Writer) !void {
    try writer.writeAll("\n\x1b[1mPlugins — average time and temporary memory over the last 100 ticks\x1b[0m\n");
    const plugin_count = @min(metrics.plugin_count, metrics.plugins.len);
    const base_rows = 14 + trace_rows + @intFromBool(trace_rows < trace_count) + workload_rows;
    const available_rows = rows -| base_rows;
    const two_columns = cols >= 150;
    const plugin_rows = if (two_columns) (plugin_count + 1) / 2 else plugin_count;
    const visible_rows = @min(plugin_rows, available_rows);
    const first_column_count = if (two_columns) (plugin_count + 1) / 2 else plugin_count;
    for (0..visible_rows) |row| {
        try renderPluginCell(writer, metrics.plugins[row], metrics.window_count, average_tick_ns, if (two_columns) (cols - 2) / 2 else @min(cols, 100));
        if (two_columns) {
            const second = row + first_column_count;
            if (second < plugin_count) {
                try writer.writeAll("  ");
                try renderPluginCell(writer, metrics.plugins[second], metrics.window_count, average_tick_ns, (cols - 2) / 2);
            }
        }
        try writer.writeByte('\n');
    }
    if (visible_rows < plugin_rows) try writer.print("… {d} plugin rows hidden; enlarge the terminal\n", .{plugin_rows - visible_rows});
}

fn traceCallsPerTick(metrics: *const metrics_abi.MetricsSnapshot, plugin_id: []const u8, trace_name: []const u8) ?f64 {
    const calls = traceWindowCalls(metrics, plugin_id, trace_name) orelse return null;
    if (metrics.window_count == 0) return 0;
    return @as(f64, @floatFromInt(calls)) / @as(f64, @floatFromInt(metrics.window_count));
}

fn traceWindowCalls(metrics: *const metrics_abi.MetricsSnapshot, plugin_id: []const u8, trace_name: []const u8) ?u64 {
    const trace_count = @min(metrics.trace_count, metrics.traces.len);
    for (metrics.traces[0..trace_count]) |trace| {
        if (trace.plugin_index >= @min(metrics.plugin_count, metrics.plugins.len)) continue;
        if (!std.mem.eql(u8, metrics.plugins[trace.plugin_index].id(), plugin_id) or !std.mem.eql(u8, trace.name(), trace_name)) continue;
        return trace.window_calls;
    }
    return null;
}

fn traceTotalCalls(metrics: *const metrics_abi.MetricsSnapshot, plugin_id: []const u8, trace_name: []const u8) ?u64 {
    const trace_count = @min(metrics.trace_count, metrics.traces.len);
    for (metrics.traces[0..trace_count]) |trace| {
        if (trace.plugin_index >= @min(metrics.plugin_count, metrics.plugins.len)) continue;
        if (!std.mem.eql(u8, metrics.plugins[trace.plugin_index].id(), plugin_id) or !std.mem.eql(u8, trace.name(), trace_name)) continue;
        return trace.total_calls;
    }
    return null;
}

fn sortTraceIndices(metrics: *const metrics_abi.MetricsSnapshot, trace_count: usize, output: *[metrics_abi.metrics_trace_capacity]u16) void {
    for (0..trace_count) |index| {
        var insert = index;
        while (insert != 0 and metrics.traces[output[insert - 1]].window_ns < metrics.traces[index].window_ns) : (insert -= 1)
            output[insert] = output[insert - 1];
        output[insert] = @intCast(index);
    }
}

fn renderTraceLine(
    writer: *std.Io.Writer,
    metrics: *const metrics_abi.MetricsSnapshot,
    trace: metrics_abi.TraceMetrics,
    window_count: usize,
    cols: usize,
) !void {
    if (trace.plugin_index >= @min(metrics.plugin_count, metrics.plugins.len)) return;
    const plugin = metrics.plugins[trace.plugin_index];
    const plugin_id = plugin.id();
    const name = trace.name();
    const label_width = @min(@as(usize, 50), cols -| 38);
    const separator = " > ";
    const plugin_width = @min(plugin_id.len, label_width);
    try writer.writeAll(plugin_id[0..plugin_width]);
    var written = plugin_width;
    if (written < label_width) {
        const separator_width = @min(separator.len, label_width - written);
        try writer.writeAll(separator[0..separator_width]);
        written += separator_width;
    }
    if (written < label_width) {
        const name_width = @min(name.len, label_width - written);
        try writer.writeAll(name[0..name_width]);
        written += name_width;
    }
    for (written..label_width) |_| try writer.writeByte(' ');

    const average_ns = average(trace.window_ns, window_count);
    const plugin_average_ns = average(plugin.window_ns, window_count);
    const percent = if (plugin_average_ns == 0) 0 else @as(f64, @floatFromInt(average_ns)) * 100.0 / @as(f64, @floatFromInt(plugin_average_ns));
    const calls_per_tick = if (window_count == 0) 0 else @as(f64, @floatFromInt(trace.window_calls)) / @as(f64, @floatFromInt(window_count));
    const microseconds_per_call = if (trace.window_calls == 0) 0 else @as(f64, @floatFromInt(trace.window_ns)) / @as(f64, @floatFromInt(trace.window_calls)) / std.time.ns_per_us;
    try writer.print(" {d:.3}ms  {d:.1}% plugin  {d:.1} calls/tick  {d:.3}us/call\n", .{
        nanosecondsToMilliseconds(average_ns),
        percent,
        calls_per_tick,
        microseconds_per_call,
    });
}

fn renderPluginCell(writer: *std.Io.Writer, metric: metrics_abi.PluginMetrics, window_count: usize, average_tick_ns: u64, width: usize) !void {
    const id_width = @min(@as(usize, 29), width -| 38);
    const id = metric.id();
    const shown = id[0..@min(id.len, id_width)];
    try writer.writeAll(shown);
    for (shown.len..id_width) |_| try writer.writeByte(' ');
    const plugin_average_ns = average(metric.window_ns, window_count);
    const percent = if (average_tick_ns == 0) 0 else @as(f64, @floatFromInt(plugin_average_ns)) * 100.0 / @as(f64, @floatFromInt(average_tick_ns));
    try writer.print(" {d:.3}ms ", .{nanosecondsToMilliseconds(plugin_average_ns)});
    try writer.print("{d:.1}%", .{percent});
    try writer.writeAll("  gen ");
    try renderBytes(writer, metric.generation_bytes);
    try writer.writeAll("  tmp ");
    try renderBytes(writer, average(metric.tick_memory_window_bytes, window_count));
}

fn averageTickMemory(metrics: *const metrics_abi.MetricsSnapshot) u64 {
    if (metrics.window_count == 0) return 0;
    var total: u64 = 0;
    for (metrics.plugins[0..@min(metrics.plugin_count, metrics.plugins.len)]) |plugin|
        total +|= plugin.tick_memory_window_bytes;
    return total / metrics.window_count;
}

fn renderBytes(writer: *std.Io.Writer, bytes: u64) !void {
    if (bytes >= 1024 * 1024) {
        try writer.print("{d:.1}MiB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)});
    } else if (bytes >= 1024) {
        try writer.print("{d:.1}KiB", .{@as(f64, @floatFromInt(bytes)) / 1024.0});
    } else {
        try writer.print("{d}B", .{bytes});
    }
}

fn average(total: u64, count: usize) u64 {
    return if (count == 0) 0 else total / count;
}

fn nanosecondsToMilliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "dashboard renders server and plugin metrics" {
    const id = "minecraft:test_plugin";
    var snapshot: Snapshot = .{
        .metrics = .{
            .tick_count = 10,
            .tick_window_ns = 20 * std.time.ns_per_ms,
            .tick_last_ns = 2 * std.time.ns_per_ms,
            .tick_max_ns = 3 * std.time.ns_per_ms,
            .window_count = 10,
            .plugin_count = 1,
        },
        .world_tick = 42,
        .target_tps = 20,
        .pending_ticks = 0,
        .connected_sockets = 2,
        .reserved_players = 2,
        .play_players = 2,
        .maximum_players = 1024,
        .living_entities = 77,
        .item_entities = 3,
        .resident_sections = 100,
        .modified_blocks = 4,
        .cached_chunks = 64,
        .pending_terrain_chunks = 3,
        .output_buffers_used = 2,
        .output_buffers_total = 512,
        .tick_generation = 2,
        .protocol_count = 2,
    };
    snapshot.protocols[0] = 771;
    snapshot.protocols[1] = 772;
    snapshot.metrics.plugins[0] = .{
        .id_ptr = id.ptr,
        .id_len = id.len,
        .total_ns = 5 * std.time.ns_per_ms,
        .window_ns = 5 * std.time.ns_per_ms,
        .last_ns = std.time.ns_per_ms,
        .max_ns = 2 * std.time.ns_per_ms,
        .generation_bytes = 12 * 1024 * 1024,
        .tick_memory_window_bytes = 40 * 1024,
    };
    const trace_name = "work_queue";
    snapshot.metrics.trace_count = 1;
    snapshot.metrics.traces[0] = .{
        .plugin_index = 0,
        .name_ptr = trace_name.ptr,
        .name_len = trace_name.len,
        .total_ns = 2 * std.time.ns_per_ms,
        .window_ns = 2 * std.time.ns_per_ms,
        .last_ns = 200 * std.time.ns_per_us,
        .max_ns = 300 * std.time.ns_per_us,
        .total_calls = 40,
        .window_calls = 40,
        .last_calls = 4,
        .max_calls = 5,
    };
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(&snapshot, 24, 100, &writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "MSPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "minecraft:test_plugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "work_queue") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "calls/tick") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "gen 12.0MiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "tmp 4.0KiB") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "771, 772") != null);
}
