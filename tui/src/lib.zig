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
        period_ticks: u32 = 5,
    };
    pub const Dependencies = struct {
        runtime_metrics: ?*metrics.Runtime,
        clock: ?*lightning_rod.clock.Clock,
        blocks: ?*lightning_rod.blocks.Blocks,
        living: ?*lightning_rod.entities.LivingEntities,
        items: ?*lightning_rod.entities.ItemEntities,
        players: ?*lightning_rod.players.Players,
    };

    deps: Dependencies,
    period_ticks: u32,
    ticks_until_capture: u32 = 0,
    captured: bool = false,
    published: Snapshot = .{},
    previous: metrics.Snapshot = .{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Plugin {
        if (configuration.period_ticks == 0) return error.InvalidPeriod;
        const self = try preallocated.create(Plugin, allocator);
        self.* = .{
            .deps = deps,
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

    pub fn ready(self: *const Plugin) bool {
        return self.captured;
    }

    fn capture(self: *Plugin) void {
        const observed = plugin_profiler.snapshotActive() orelse return;
        self.published.metrics = observed.*;
        if (self.deps.runtime_metrics) |value| value.apply(&self.published.metrics);
        if (self.deps.clock) |value| self.published.metrics.world_tick = value.currentTick();
        if (self.deps.blocks) |value| {
            self.published.metrics.transient_chunks = value.materializedChunkCount();
            self.published.metrics.transient_chunk_capacity = value.materializationCapacity();
            self.published.metrics.modified_sections = value.modifiedSectionCount();
            self.published.metrics.modified_section_capacity = value.modifiedSectionCapacity();
            self.published.metrics.modified_blocks = value.modifiedBlockCount();
            self.published.metrics.pending_terrain_chunks = value.pendingChunkGenerationCount();
        }
        if (self.deps.living) |value| self.published.metrics.living_entities = value.activeCount();
        if (self.deps.items) |value| self.published.metrics.item_entities = value.activeCount();
        if (self.deps.players) |value| {
            self.published.metrics.players = value.activeCount();
            self.published.metrics.player_capacity = value.playerCapacity();
        }
        const current = &self.published.metrics;
        current.interval_ticks = current.tick_count -| self.previous.tick_count;
        current.interval_session_direct_bytes = current.session_direct_payload_bytes -| self.previous.session_direct_payload_bytes;
        current.interval_session_copied_bytes = current.session_copied_payload_bytes -| self.previous.session_copied_payload_bytes;
        current.interval_session_fanout_bytes = current.session_fanout_payload_bytes -| self.previous.session_fanout_payload_bytes;
        current.interval_session_prepared_copy_bytes = current.session_prepared_copy_bytes -| self.previous.session_prepared_copy_bytes;
        current.interval_session_transport_direct_bytes = current.session_transport_direct_bytes -| self.previous.session_transport_direct_bytes;
        current.interval_session_transport_fallback_copy_bytes = current.session_transport_fallback_copy_bytes -| self.previous.session_transport_fallback_copy_bytes;
        current.interval_persistence_read_bytes = current.persistence_read_bytes -| self.previous.persistence_read_bytes;
        current.interval_persistence_read_completions = current.persistence_read_completions -| self.previous.persistence_read_completions;
        current.interval_persistence_write_bytes = current.persistence_write_bytes -| self.previous.persistence_write_bytes;
        current.interval_persistence_write_completions = current.persistence_write_completions -| self.previous.persistence_write_completions;
        current.interval_persistence_submit_calls = current.persistence_submit_calls -| self.previous.persistence_submit_calls;
        self.previous = current.*;
        self.published.revision +%= 1;
        self.captured = true;
    }
};

pub fn render(snapshot: *const Snapshot, dimensions: Dimensions, writer: *std.Io.Writer) !void {
    try renderHeader(snapshot, writer);
    try renderWorld(snapshot.metrics, writer);
    const content_rows = dimensions.rows -| 23;
    const plugin_rows = content_rows * 2 / 3;
    try renderPlugins(snapshot.metrics, dimensions.columns, plugin_rows, writer);
    try renderTraces(snapshot.metrics, content_rows - plugin_rows, writer);
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
    try writer.writeAll("Memory startup ");
    try renderBytes(writer, value.generation_memory_bytes);
    try writer.writeAll(" / core ");
    try renderBytes(writer, value.memory_capacity_bytes);
    try writer.writeAll("  temporary ");
    try renderBytes(writer, value.tick_memory_capacity_bytes);
    try writer.writeAll("  headroom ");
    try renderBytes(writer, value.memory_capacity_bytes -| value.generation_memory_bytes -| value.tick_memory_capacity_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("Process plan ");
    try renderBytes(writer, value.memory_planned_bytes);
    try writer.writeAll(" / limit ");
    try renderBytes(writer, value.memory_limit_bytes);
    try writer.writeAll("  host ");
    try renderBytes(writer, value.host_memory_bytes);
    try writer.writeAll("  RSS ");
    try renderBytes(writer, value.resident_set_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("Host transport ");
    try renderBytes(writer, value.transport_memory_bytes);
    try writer.writeAll("  sessions ");
    try renderBytes(writer, value.sessions_memory_bytes);
    try writer.writeAll("  persistence ");
    try renderBytes(writer, value.persistence_memory_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("Host reload ");
    try renderBytes(writer, value.reload_memory_bytes);
    try writer.writeAll("  transition ");
    try renderBytes(writer, value.reload_transition_bytes);
    try writer.writeAll("  logs ");
    try renderBytes(writer, value.logging_memory_bytes);
    try writer.writeByte('\n');
}

fn renderWorld(value: metrics.Snapshot, writer: *std.Io.Writer) !void {
    try writer.print("World tick {d}  players {d}/{d}  connections {d}  backpressured {d}  living {d}  items {d}\n", .{
        value.world_tick,
        value.players,
        value.player_capacity,
        value.connections,
        value.backpressured_connections,
        value.living_entities,
        value.item_entities,
    });
    try writer.writeAll("Network output ");
    try renderBytes(writer, value.network_output_bytes);
    try writer.writeAll(" / ");
    try renderBytes(writer, value.network_output_capacity_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("Session exchange pending ");
    try writer.print("{d}  direct ", .{value.session_exchange_messages});
    try renderBytes(writer, value.session_direct_payload_bytes);
    try writer.writeAll("  copied ");
    try renderBytes(writer, value.session_copied_payload_bytes);
    try writer.writeAll("  fanout ");
    try renderBytes(writer, value.session_fanout_payload_bytes);
    try writer.print("/{d} deliveries\n", .{value.session_fanout_deliveries});
    try writer.print("Session queue {d} prepared frames  ", .{value.session_prepared_frames});
    try renderBytes(writer, value.session_prepared_bytes);
    try writer.writeAll(" physical  ");
    try renderBytes(writer, value.session_delivery_bytes);
    try writer.writeAll(" recipient backlog\n");
    try writer.writeAll("Session copies prepared ");
    try renderBytes(writer, value.session_prepared_copy_bytes);
    try writer.writeAll("  final direct ");
    try renderBytes(writer, value.session_transport_direct_bytes);
    try writer.writeAll("  fallback copies ");
    try renderBytes(writer, value.session_transport_fallback_copy_bytes);
    try writer.writeByte('\n');
    try writer.writeAll("Session interval encoded ");
    try renderBytes(writer, value.interval_session_direct_bytes + value.interval_session_fanout_bytes);
    try writer.writeAll("  staged copies ");
    try renderBytes(writer, value.interval_session_copied_bytes);
    try writer.writeAll("  prepared/final/fallback ");
    try renderBytes(writer, value.interval_session_prepared_copy_bytes);
    try writer.writeByte('/');
    try renderBytes(writer, value.interval_session_transport_direct_bytes);
    try writer.writeByte('/');
    try renderBytes(writer, value.interval_session_transport_fallback_copy_bytes);
    try writer.print(" over {d} ticks\n", .{value.interval_ticks});
    try writer.print("Transient chunks {d}/{d}  tickets {d}/{d}  admitted {d}/{d} transitions {d}{s}  modified sections {d}/{d} blocks {d}  terrain pending {d}\n", .{
        value.transient_chunks,
        value.transient_chunk_capacity,
        value.gameplay_tickets,
        value.gameplay_ticket_capacity,
        value.admitted_chunks,
        value.admission_capacity,
        value.admission_transitions,
        if (value.admission_overflow) " OVERFLOW" else "",
        value.modified_sections,
        value.modified_section_capacity,
        value.modified_blocks,
        value.pending_terrain_chunks,
    });
    try writer.print("Materialization reads {d}/{d} free {d}  generation {d}/{d}  waiting requests {d} dirty {d}  memory ", .{
        value.materialization_reading,
        value.materialization_read_capacity,
        value.materialization_free,
        value.materialization_generating,
        value.materialization_generation_capacity,
        value.materialization_request_waiting,
        value.materialization_dirty,
    });
    try renderBytes(writer, value.materialization_memory_bytes);
    try writer.writeAll("  active read bytes ");
    try renderBytes(writer, value.materialization_read_bytes);
    try writer.writeAll("/");
    try renderBytes(writer, value.materialization_read_byte_capacity);
    try writer.print("\nMaterialization lifetime hits {d} misses {d} generated {d} persisted {d}\n", .{
        value.materialization_read_hits,
        value.materialization_read_misses,
        value.materialization_generated,
        value.materialization_persisted,
    });
    try writer.print("Exact block reads {d}  loader {d}  total synchronous time {d:.3}ms\n", .{
        value.materialization_exact_reads,
        value.materialization_exact_loader_reads,
        milliseconds(value.materialization_exact_read_nanoseconds),
    });
    try writer.print("Persistence keys {d}", .{value.persistence_keys});
    if (value.persistence_key_capacity != 0)
        try writer.print("/{d}", .{value.persistence_key_capacity})
    else
        try writer.writeAll(" (disk indexed)");
    try writer.print("  reads {d}/{d}  writes {d}/{d}  submissions {d}\n", .{
        value.persistence_read_completions,
        value.persistence_read_submissions,
        value.persistence_write_completions,
        value.persistence_write_submissions,
        value.persistence_submit_calls,
    });
    try writer.writeAll("Persistence bytes read ");
    try renderBytes(writer, value.persistence_read_bytes);
    try writer.writeAll("  written ");
    try renderBytes(writer, value.persistence_write_bytes);
    try writer.writeByte('\n');
    try writer.print("Persistence interval reads {d}  writes {d}  submissions {d}  bytes ", .{
        value.interval_persistence_read_completions,
        value.interval_persistence_write_completions,
        value.interval_persistence_submit_calls,
    });
    try renderBytes(writer, value.interval_persistence_read_bytes);
    try writer.writeAll(" / ");
    try renderBytes(writer, value.interval_persistence_write_bytes);
    try writer.print(" over {d} ticks\n", .{value.interval_ticks});
    try writer.print("Disk index pages read {d}  cache hits {d}  pending hits {d}  writes {d}/{d}  cache {d}/{d}\n", .{
        value.disk_index_page_reads,
        value.disk_index_cache_hits,
        value.disk_index_pending_hits,
        value.disk_index_page_writes,
        value.disk_index_written_pages,
        value.disk_index_cache_pages,
        value.disk_index_cache_capacity,
    });
    try writer.print("World projections chunks {d}/{d}  masks {d}/{d}  state pages {d}/{d}  overflow {s}\n", .{
        value.projected_chunks,
        value.projected_chunk_capacity,
        value.projection_masks,
        value.projection_mask_capacity,
        value.projection_state_pages,
        value.projection_state_page_capacity,
        if (value.projection_overflow) "yes" else "no",
    });
    try writer.print("Lighting projections chunks {d}/{d}  pages {d}/{d}\n", .{
        value.lighting_chunks,
        value.lighting_chunk_capacity,
        value.lighting_pages,
        value.lighting_page_capacity,
    });
    try writer.print("Collision projections chunks {d}/{d}  masks {d}/{d}  exceptions {d}/{d}  fluids {d}/{d}  incomplete {d}\n", .{
        value.collision_chunks,
        value.collision_chunk_capacity,
        value.collision_masks,
        value.collision_mask_capacity,
        value.collision_exceptions,
        value.collision_exception_capacity,
        value.collision_fluid_spans,
        value.collision_fluid_span_capacity,
        value.collision_incomplete_chunks,
    });
    try writer.print("Deferred world input blocks {d}  digs {d}\n", .{ value.deferred_block_inputs, value.deferred_dig_inputs });
}

fn renderPlugins(value: metrics.Snapshot, columns: usize, maximum_rows: usize, writer: *std.Io.Writer) !void {
    const count = @min(value.plugin_count, value.plugins.len);
    const visible = @min(count, maximum_rows);
    try writer.writeAll("\n\x1b[1mHottest plugins — average time and temporary memory\x1b[0m\n");
    var previous: ?usize = null;
    for (0..visible) |_| {
        const index = nextPlugin(value.plugins[0..count], previous) orelse break;
        try renderPlugin(value.window_count, value.plugins[index], columns, writer);
        previous = index;
    }
    if (visible < count) try writer.print("… {d} plugins hidden\n", .{count - visible});
}

fn nextPlugin(values: []const metrics.Plugin, previous: ?usize) ?usize {
    var best: ?usize = null;
    for (values, 0..) |_, index| {
        if (previous) |cutoff| if (!pluginBefore(values, cutoff, index)) continue;
        if (best == null or pluginBefore(values, index, best.?)) best = index;
    }
    return best;
}

fn pluginBefore(values: []const metrics.Plugin, left: usize, right: usize) bool {
    if (values[left].window_ns != values[right].window_ns)
        return values[left].window_ns > values[right].window_ns;
    if (values[left].generation_bytes != values[right].generation_bytes)
        return values[left].generation_bytes > values[right].generation_bytes;
    return left < right;
}

fn renderTraces(value: metrics.Snapshot, maximum_rows: usize, writer: *std.Io.Writer) !void {
    const count = @min(value.trace_count, value.traces.len);
    const visible = @min(count, maximum_rows);
    if (visible == 0) return;
    try writer.writeAll("\n\x1b[1mHottest traces — average time and calls\x1b[0m\n");
    var previous: ?usize = null;
    for (0..visible) |_| {
        const index = nextTrace(value.traces[0..count], previous) orelse break;
        const trace = value.traces[index];
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
        previous = index;
    }
    if (visible < count) try writer.print("… {d} traces hidden\n", .{count - visible});
}

fn nextTrace(values: []const metrics.Trace, previous: ?usize) ?usize {
    var best: ?usize = null;
    for (values, 0..) |_, index| {
        if (previous) |cutoff| if (!traceBefore(values, cutoff, index)) continue;
        if (best == null or traceBefore(values, index, best.?)) best = index;
    }
    return best;
}

fn traceBefore(values: []const metrics.Trace, left: usize, right: usize) bool {
    if (values[left].window_ns != values[right].window_ns)
        return values[left].window_ns > values[right].window_ns;
    return left < right;
}

fn renderPlugin(window_count: usize, plugin: metrics.Plugin, columns: usize, writer: *std.Io.Writer) !void {
    const name_width = @min(columns -| 24, @as(usize, 48));
    const name = plugin.id()[0..@min(plugin.id().len, name_width)];
    const average_ns = if (window_count == 0) 0 else plugin.window_ns / window_count;
    const average_memory = if (window_count == 0) 0 else plugin.tick_memory_window_bytes / window_count;
    try writer.print("{s} {d:.3}ms  reserved ", .{ name, milliseconds(average_ns) });
    try renderBytes(writer, plugin.generation_bytes);
    try writer.writeAll("  tmp avg ");
    try renderBytes(writer, average_memory);
    try writer.writeAll(" max ");
    try renderBytes(writer, plugin.tick_memory_max_bytes);
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
