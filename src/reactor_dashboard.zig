const tui = @import("tui.zig");
const config = @import("config.zig").value;
const connections = @import("reactor_connection.zig");
const output = @import("reactor_output.zig");
const hot_reload = @import("hot_reload.zig");

pub const Dashboard = struct {
    terminal: ?*tui.Terminal = null,
    next_render_ms: u64 = 0,
    submissions: u64 = 0,
    completions: u64 = 0,
    completions_last: u32 = 0,
    completions_peak: u32 = 0,

    pub fn init(terminal: ?*tui.Terminal) Dashboard {
        return .{ .terminal = terminal };
    }

    pub fn submitted(self: *Dashboard) void {
        self.submissions +%= 1;
    }

    pub fn completed(self: *Dashboard, count: u32) void {
        self.completions +%= count;
        self.completions_last = count;
        self.completions_peak = @max(self.completions_peak, count);
    }

    pub fn completedAdditional(self: *Dashboard, count: u32) void {
        self.completions +%= count;
        self.completions_last +%= count;
        self.completions_peak = @max(self.completions_peak, self.completions_last);
    }

    pub fn render(
        self: *Dashboard,
        now_ms: u64,
        table: *const connections.Table,
        buffers: *const output.Pool,
        module: *const hot_reload.Manager,
    ) !void {
        const terminal = self.terminal orelse return;
        if (now_ms < self.next_render_ms) return;
        self.next_render_ms = now_ms + 250;
        const metrics = module.metricsSnapshot();
        var snapshot: tui.Snapshot = .{
            .metrics = metrics,
            .world_tick = metrics.world_tick,
            .target_tps = config.ticks_per_second,
            .pending_ticks = 0,
            .connected_sockets = table.connected_count,
            .reserved_players = table.reserved_player_count,
            .play_players = table.play_count,
            .maximum_players = module.maximumPlayers(),
            .living_entities = metrics.living_entities,
            .item_entities = metrics.item_entities,
            .resident_sections = metrics.resident_sections,
            .modified_blocks = metrics.modified_blocks,
            .cached_chunks = 0,
            .pending_terrain_chunks = metrics.pending_terrain_chunks,
            .output_buffers_used = config.output_buffer_count - buffers.free_count,
            .output_buffers_total = config.output_buffer_count,
            .io_submissions = self.submissions,
            .io_completions = self.completions,
            .io_last_completions = self.completions_last,
            .io_peak_completions = self.completions_peak,
            .terrain_last_ns = metrics.terrain_last_ns,
            .terrain_max_ns = metrics.terrain_max_ns,
            .tick_generation = module.activeGenerationNumber(),
        };
        for (module.supportedProtocols()) |protocol_number| {
            snapshot.protocols[snapshot.protocol_count] = protocol_number;
            snapshot.protocol_count += 1;
        }
        try terminal.draw(&snapshot);
    }
};
