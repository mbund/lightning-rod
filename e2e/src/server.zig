const std = @import("std");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("lightning_rod_vanilla_1_21_6");

const AuthenticationProbe = struct {
    const Online = linux.authentication.Online(4);
    const Verifier = Online.Verifier;
    mode: enum { accept, reject, timeout } = .accept,
    uuid: u128 = 0,
    polls: usize = 0,

    fn interface(self: *@This()) Verifier {
        return .{ .context = self, .vtable = &.{ .start = start, .poll = poll, .cancel = cancel } };
    }
    fn start(raw: *anyopaque, request: Verifier.Request) Verifier.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (request.server_hash.len == 0) return .rejected;
        self.uuid = linux.authentication.Offline.uuid(request.username);
        self.polls = 0;
        std.log.info("event=e2e_auth_verifying", .{});
        return .pending;
    }
    fn poll(raw: *anyopaque, _: lightning_rod.transport.Connection) Verifier.Result {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.polls += 1;
        if (self.polls < 3 or self.mode == .timeout) return .pending;
        std.log.info("event=e2e_auth_result accepted={}", .{self.mode == .accept});
        return if (self.mode == .accept) .{ .accepted = self.uuid } else .rejected;
    }
    fn cancel(_: *anyopaque, _: lightning_rod.transport.Connection) void {
        std.log.info("event=e2e_auth_canceled", .{});
    }
};

const FatalStorageProbe = struct {
    pub const id = "lightning_rod_e2e:fatal_storage_probe";
    pub const Configuration = struct { enabled: bool = false };
    pub const Dependencies = struct { players: *lightning_rod.players.Players };
    deps: Dependencies,
    config: Configuration,
    ticks: usize = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{ .deps = deps, .config = config };
        return self;
    }

    pub fn tick(self: *@This()) lightning_rod.plugin_lifecycle.FatalError!void {
        if (!self.config.enabled or self.deps.players.activeCount() == 0) return;
        self.ticks += 1;
        if (self.ticks == 100) return error.StorageReadFailed;
    }

    pub fn checkpoint(self: *@This(), _: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (self.config.enabled) std.log.err("event=e2e_unexpected_checkpoint", .{});
    }
};

const FixturePrepare = struct {
    pub const id = "lightning_rod_e2e:fixture_prepare";
    pub const Configuration = struct { enabled: bool = false };
    pub const Dependencies = struct {
        materialization: *vanilla.Materializer,
        worlds: *lightning_rod.worlds.Worlds,
    };

    deps: Dependencies,
    order: ?lightning_rod.chunk_stream.Order = null,
    cursor: usize = 0,
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, config: Configuration) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{ .deps = deps };
        if (config.enabled) self.order = try lightning_rod.chunk_stream.Order.create(allocator, 32);
        return self;
    }

    pub fn tick(self: *@This()) void {
        const order = &(self.order orelse return);
        const world = self.deps.worlds.active()[0];
        while (self.cursor < order.indices.len) {
            const position = positionForIndex(order, order.indices[self.cursor]);
            if (self.deps.materialization.requestRender(world, position) == .backpressured) break;
            self.cursor += 1;
        }
        if (self.complete or self.cursor != order.indices.len) return;
        const activity = self.deps.materialization.activity();
        if (activity.installed_shapes < @as(u64, @intCast(order.indices.len)) or activity.reading != 0 or
            activity.request_waiting != 0 or activity.generating != 0 or
            activity.staged_chunks != 0 or activity.dirty_chunks != 0 or
            activity.queued_chunks != 0 or activity.staging or activity.checkpoint_pending)
            return;
        self.complete = true;
        std.log.info("event=e2e_persisted_fixture_ready chunks={d}", .{order.indices.len});
    }

    fn positionForIndex(order: *const lightning_rod.chunk_stream.Order, index: u16) lightning_rod.geometry.ChunkPos {
        return .{
            .x = @as(i32, @intCast(@as(usize, index) % order.diameter)) - order.grid_radius,
            .z = @as(i32, @intCast(@as(usize, index) / order.diameter)) - order.grid_radius,
        };
    }
};

const ReloadProbe = struct {
    pub const id = "lightning_rod_e2e:reload_probe";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        lifecycle: *lightning_rod.player_lifecycle.Events,
        packets: *lightning_rod.Packets,
    };

    deps: Dependencies,
    players: u8 = 0,
    request_slot: u16 = 0,
    ticks: u16 = 0,
    requested: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*ReloadProbe {
        const self = try allocator.create(ReloadProbe);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *ReloadProbe, _: std.mem.Allocator) void {
        for (self.deps.lifecycle.joined.values) |joined| {
            self.players +|= 1;
            self.request_slot = joined.slot;
            std.log.info("event=e2e_reload_probe_joined players={d}", .{self.players});
        }
        if (self.players < 2 or self.requested) return;
        self.ticks +|= 1;
        if (self.ticks < 100) return;
        self.requested = true;
        std.log.info("event=e2e_reload_probe_requested", .{});
        self.deps.packets.requestReload(self.request_slot);
    }
};

const SteadyStateProbe = struct {
    pub const id = "lightning_rod_e2e:steady_state_probe";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        clock: *lightning_rod.clock.Clock,
        players: *lightning_rod.players.Players,
        tickets: *vanilla.ChunkTickets,
        admission: *vanilla.SimulationAdmission,
        streaming: *vanilla.ChunkStreaming,
        materialization: *vanilla.Materializer,
        runtime_metrics: *lightning_rod.metrics.Runtime,
    };

    deps: Dependencies,
    idle_ticks: u8 = 0,
    settled_tick: u64 = 0,
    measurement_started_tick: u64 = 0,
    persistence_read_bytes: u64 = 0,
    persistence_write_bytes: u64 = 0,
    persistence_submissions: u64 = 0,
    reported: bool = false,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*SteadyStateProbe {
        const self = try allocator.create(SteadyStateProbe);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *SteadyStateProbe) void {
        if (self.reported or self.deps.players.activeCount() != 1) return;
        const slot = self.deps.players.activeSlots()[0];
        const activity = self.deps.materialization.activity();
        const idle = self.deps.streaming.complete(slot) and activity.reading == 0 and
            activity.request_waiting == 0 and activity.generating == 0 and
            activity.staged_chunks == 0 and activity.dirty_chunks == 0 and
            activity.queued_chunks == 0 and !activity.staging and !activity.checkpoint_pending;
        if (self.settled_tick == 0) {
            self.idle_ticks = if (idle) self.idle_ticks +| 1 else 0;
            if (self.idle_ticks < 20) return;
            self.settled_tick = self.deps.clock.tick;
            std.log.info("event=e2e_steady_state_warmup tick={d} ticks={d}", .{ self.settled_tick, lightning_rod.plugin_profiler.window_ticks });
            return;
        }
        if (self.measurement_started_tick == 0) {
            if (self.deps.clock.tick - self.settled_tick < lightning_rod.plugin_profiler.window_ticks) return;
            var baseline: lightning_rod.metrics.Snapshot = .{};
            self.deps.runtime_metrics.apply(&baseline);
            self.persistence_read_bytes = baseline.persistence_read_bytes;
            self.persistence_write_bytes = baseline.persistence_write_bytes;
            self.persistence_submissions = baseline.persistence_submit_calls;
            self.measurement_started_tick = self.deps.clock.tick;
            std.log.info("event=e2e_steady_state_started tick={d}", .{self.measurement_started_tick});
            return;
        }
        if (self.deps.clock.tick - self.measurement_started_tick < lightning_rod.plugin_profiler.window_ticks) return;
        const snapshot = lightning_rod.plugin_profiler.snapshotActive() orelse return;
        if (snapshot.window_count != lightning_rod.plugin_profiler.window_ticks) return;
        const player = &self.deps.players.records[slot];
        const center = lightning_rod.geometry.ChunkPos{
            .x = lightning_rod.geometry.chunkCoord(lightning_rod.geometry.blockCoord(player.position.x)),
            .z = lightning_rod.geometry.chunkCoord(lightning_rod.geometry.blockCoord(player.position.z)),
        };
        var entity: usize = 0;
        var block: usize = 0;
        var full: usize = 0;
        var invalid: usize = 0;
        const radius: u32 = @intCast(self.deps.tickets.simulationDistance());
        const edge: i32 = @intCast(radius + 3);
        var dz: i32 = -edge;
        while (dz <= edge) : (dz += 1) {
            var dx: i32 = -edge;
            while (dx <= edge) : (dx += 1) {
                const distance = @max(@abs(dx), @abs(dz));
                const expected: ?vanilla.simulation_admission.Level = if (distance <= radius)
                    .entity_ticking
                else if (distance == radius + 1)
                    .block_ticking
                else if (distance == radius + 2)
                    .full
                else
                    null;
                const actual = self.deps.admission.level(player.world, .{ .x = center.x + dx, .z = center.z + dz });
                if (actual != expected) invalid += 1;
                if (actual) |level| switch (level) {
                    .entity_ticking => entity += 1,
                    .block_ticking => block += 1,
                    .full => full += 1,
                };
            }
        }
        var runtime_snapshot: lightning_rod.metrics.Snapshot = .{};
        self.deps.runtime_metrics.apply(&runtime_snapshot);
        const read_bytes = runtime_snapshot.persistence_read_bytes -| self.persistence_read_bytes;
        const write_bytes = runtime_snapshot.persistence_write_bytes -| self.persistence_write_bytes;
        const submissions = runtime_snapshot.persistence_submit_calls -| self.persistence_submissions;
        const average = snapshot.tick_window_ns / snapshot.window_count;
        std.log.info("event=e2e_steady_state samples={d} avg_ns={d} max_ns={d} target_ns=200000 simulation_distance={d} entity={d} block={d} full={d} invalid={d} admission_overflow={} persistence_read_bytes={d} persistence_write_bytes={d} persistence_submissions={d}", .{
            snapshot.window_count,
            average,
            snapshot.tick_window_max_ns,
            self.deps.tickets.simulationDistance(),
            entity,
            block,
            full,
            invalid,
            self.deps.admission.overflow(),
            read_bytes,
            write_bytes,
            submissions,
        });
        for (snapshot.plugins[0..snapshot.plugin_count]) |item| {
            if (item.window_ns == 0) continue;
            std.log.info("event=e2e_steady_plugin plugin={s} avg_ns={d} max_ns={d}", .{
                item.id(),
                item.window_ns / snapshot.window_count,
                item.window_max_ns,
            });
        }
        self.reported = true;
    }
};

const StreamTimingProbe = struct {
    pub const id = "lightning_rod_e2e:stream_timing_probe";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        clock: *lightning_rod.clock.Clock,
        players: *lightning_rod.players.Players,
        streaming: *vanilla.ChunkStreaming,
    };

    deps: Dependencies,
    started: bool = false,
    completed: bool = false,
    start_tick: u64 = 0,
    start_time: ?std.Io.Clock.Timestamp = null,
    last_progress_tick: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*@This() {
        const self = try allocator.create(@This());
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *@This(), io: std.Io) void {
        if (self.completed or self.deps.players.activeCount() != 1) return;
        const slot = self.deps.players.activeSlots()[0];
        const delivered = self.deps.streaming.deliveredCount(slot);
        if (!self.started) {
            if (delivered == 0) return;
            self.started = true;
            self.start_tick = self.deps.clock.tick;
            self.start_time = std.Io.Clock.Timestamp.now(io, .awake);
            self.last_progress_tick = self.start_tick;
            std.log.info("event=e2e_stream_clock_started tick={d} delivered={d} slot={d}", .{ self.start_tick, delivered, slot });
        }
        const current_tick = self.deps.clock.tick;
        const complete = self.deps.streaming.complete(slot);
        if (!complete and current_tick -| self.last_progress_tick < 20) return;
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        const elapsed_ns: u64 = @intCast(now.raw.nanoseconds - self.start_time.?.raw.nanoseconds);
        const elapsed_us = elapsed_ns / std.time.ns_per_us;
        if (!complete) {
            self.last_progress_tick = current_tick;
            std.log.info("event=e2e_stream_progress start_tick={d} current_tick={d} elapsed_ticks={d} delivered={d} wall_elapsed_us={d} slot={d}", .{
                self.start_tick,
                current_tick,
                current_tick -| self.start_tick,
                delivered,
                elapsed_us,
                slot,
            });
            return;
        }
        self.completed = true;
        std.log.info("event=e2e_stream_clock_completed start_tick={d} end_tick={d} elapsed_ticks={d} delivered={d} wall_elapsed_us={d} slot={d}", .{
            self.start_tick,
            current_tick,
            current_tick -| self.start_tick,
            delivered,
            elapsed_us,
            slot,
        });
    }
};

pub const std_options: std.Options = .{ .logFn = lightning_rod.logging.logFn };

const seed: u64 = 0x6d_62_75_6e_64_00_00_01;
const flat_worlds = [_]lightning_rod.worlds.Description{
    .{
        .key = .{ .value = 1 },
        .name = "minecraft:overworld",
        .dimension = lightning_rod.dimensions.Vanilla.dimensionId(lightning_rod.dimensions.Overworld),
        .generator = vanilla.WorldGeneration.generatorId(lightning_rod.world_generation.Flat),
        .seed = seed,
        .spawn_x = 8,
        .spawn_y = 66,
        .spawn_z = 8,
    },
};

pub fn main(init: std.process.Init) !void {
    var io = init.io;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var flat = false;
    var prepare_persisted = false;
    var fatal_storage = false;
    var auth_mode: ?@FieldType(AuthenticationProbe, "mode") = null;
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--flat")) flat = true;
        if (std.mem.eql(u8, argument, "--prepare-persisted")) prepare_persisted = true;
        if (std.mem.eql(u8, argument, "--fatal-storage")) fatal_storage = true;
        if (std.mem.eql(u8, argument, "--auth-success")) auth_mode = .accept;
        if (std.mem.eql(u8, argument, "--auth-reject")) auth_mode = .reject;
        if (std.mem.eql(u8, argument, "--auth-timeout")) auth_mode = .timeout;
    }
    const base = if (flat)
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            lightning_rod.plugin.configured(lightning_rod.worlds.Worlds, lightning_rod.worlds.Worlds.Configuration{ .initial = &flat_worlds, .maximum_worlds = 4 }),
            lightning_rod.plugin.configured(lightning_rod.players.Players, lightning_rod.players.Players.Configuration{ .initial_world = flat_worlds[0].key, .maximum_connections = 64, .maximum_players = 32 }),
        })
    else
        vanilla.plugins();
    const plugins = lightning_rod.plugin.compose(.{
        base,
        lightning_rod.plugin.configured(ReloadProbe, ReloadProbe.Configuration{}),
        lightning_rod.plugin.configured(SteadyStateProbe, SteadyStateProbe.Configuration{}),
        lightning_rod.plugin.configured(StreamTimingProbe, StreamTimingProbe.Configuration{}),
        lightning_rod.plugin.configured(FatalStorageProbe, FatalStorageProbe.Configuration{ .enabled = fatal_storage }),
        lightning_rod.plugin.configured(FixturePrepare, FixturePrepare.Configuration{ .enabled = prepare_persisted }),
    });
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{
        .address = "127.0.0.1",
        .port = 25575,
        .root_path = "lightning-rod-data/e2e.root",
    });
    var verifier: AuthenticationProbe = .{ .mode = auth_mode orelse .accept };
    var authentication = AuthenticationProbe.Online.init(&io, verifier.interface(), lightning_rod.crypto_support.testing.identity());
    defer authentication.deinit();
    authentication.authenticate_client = false;
    try Server.run(init, .{ .plugins = plugins, .authentication = if (auth_mode != null) authentication.interface() else null });
}
