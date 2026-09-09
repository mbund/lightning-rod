const lightning_rod = @import("lightning_rod");
const chunk_packet = lightning_rod.chunk_packet;
const chunk_stream = lightning_rod.chunk_stream;
const geometry = lightning_rod.geometry;
const std = @import("std");
const plugin_profiler = lightning_rod.plugin_profiler;
const vanilla_lighting = @import("vanilla_lighting.zig");
const vanilla_join = @import("vanilla_join.zig");
const vanilla_persistence = @import("vanilla_persistence.zig");
const view = lightning_rod.view;

pub const ChunkStreaming = struct {
    pub const id = "minecraft:chunk_streaming";
    pub const Trace = enum {
        lighting,
        encoding,
        packet_batch,
        request_scan,
        requested,
        delivered,
        resident_wait,
        output_backpressure,
    };
    pub const Configuration = struct {
        view_distance_chunks: i32 = 32,
        tick_budget_ns: u64 = 30 * std.time.ns_per_ms,

        pub fn validate(self: Configuration) !void {
            if (self.view_distance_chunks < 0) return error.InvalidViewDistance;
            if (self.tick_budget_ns == 0) return error.InvalidTickBudget;
        }
    };
    pub const Dependencies = struct {
        blocks: *lightning_rod.blocks.Blocks,
        clock: *lightning_rod.clock.Clock,
        lighting: *vanilla_lighting.Lighting,
        materialization: *vanilla_persistence.Materializer,
        inputs: *lightning_rod.inputs.Inputs,
        players: *lightning_rod.players.Players,
        join: *vanilla_join.PlayJoin,
        sessions: *lightning_rod.sessions.Sessions,
    };

    const microbatch_chunks = 64;
    const diagnostic_interval_ticks = 100;
    const Wait = enum { none, resident, output };
    const Batch = struct {
        const Phase = enum { idle, open };

        phase: Phase = .idle,
        count: u8 = 0,
        limit: u8 = microbatch_chunks,

        fn reset(self: *Batch) void {
            self.* = .{};
        }

        fn start(self: *Batch, admission: lightning_rod.sessions.PacketAdmission) bool {
            if (self.phase != .idle or admission != .accepted) return false;
            self.phase = .open;
            self.count = 0;
            return true;
        }

        fn recordAccepted(self: *Batch, accepted: u16) void {
            std.debug.assert(self.phase == .open);
            std.debug.assert(@as(usize, accepted) <= microbatch_chunks - @as(usize, self.count));
            self.count += @intCast(accepted);
        }

        fn finish(self: *Batch, admission: lightning_rod.sessions.PacketAdmission) bool {
            if (self.phase != .open or admission != .accepted) return false;
            self.phase = .idle;
            self.count = 0;
            return true;
        }

        fn acknowledge(self: *Batch, chunks_per_tick: f32) void {
            if (!std.math.isFinite(chunks_per_tick) or chunks_per_tick <= 0) return;
            const maximum: f32 = @floatFromInt(microbatch_chunks);
            const bounded = @min(chunks_per_tick, maximum);
            self.limit = @intFromFloat(@max(@as(f32, 1), @ceil(bounded)));
        }
    };

    const Player = struct {
        session_generation: u64 = 0,
        tracker: chunk_stream.Tracker = .{},
        delivered: u32 = 0,
        requests: u32 = 0,
        resident_waits: u16 = 0,
        output_backpressure: u16 = 0,
        wait: Wait = .none,
        request_cursor: usize = 0,
        stream_after_tick: u64 = 0,
        completion_logged: bool = false,
        batch: Batch = .{},

        fn beginSession(self: *Player, generation: u64, center: geometry.ChunkPos, tick_number: u64) bool {
            std.debug.assert(generation != 0);
            if (self.session_generation == generation) return false;
            self.tracker.reset(center);
            self.session_generation = generation;
            self.request_cursor = 0;
            self.stream_after_tick = tick_number;
            self.completion_logged = false;
            self.batch.reset();
            self.clearDiagnostics();
            return true;
        }

        fn clearDiagnostics(self: *Player) void {
            self.delivered = 0;
            self.requests = 0;
            self.resident_waits = 0;
            self.output_backpressure = 0;
        }
    };

    deps: Dependencies,
    configuration: Configuration,
    order: chunk_stream.Order,
    players: []Player,
    empty_view: view.PlayerView = .{},
    last_materialization: vanilla_persistence.Activity = .{},
    cursor: usize = 0,
    tick_started_ns: u64 = 0,
    lighting_nanoseconds: u64 = 0,
    encoding_nanoseconds: u64 = 0,
    encoded_chunks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*ChunkStreaming {
        try configuration.validate();
        const self = try allocator.create(ChunkStreaming);
        self.* = .{
            .deps = deps,
            .configuration = configuration,
            .order = try chunk_stream.Order.create(allocator, configuration.view_distance_chunks),
            .players = try allocator.alloc(Player, deps.players.records.len),
        };
        for (self.players) |*player| {
            player.* = .{};
            try player.tracker.allocate(allocator, &self.order);
        }
        return self;
    }

    pub fn complete(self: *const ChunkStreaming, slot: u16) bool {
        if (slot >= self.players.len) return false;
        const state = &self.players[slot];
        return state.session_generation == self.deps.players.session_generations[slot] and
            state.tracker.sent_count == self.order.indices.len;
    }

    pub fn deliveredCount(self: *const ChunkStreaming, slot: u16) u32 {
        if (slot >= self.players.len) return 0;
        return @intCast(self.players[slot].tracker.sent_count);
    }

    pub fn tick(self: *ChunkStreaming, temporary: std.mem.Allocator) void {
        self.tick_started_ns = plugin_profiler.tickElapsedNanoseconds() orelse 0;

        const slots = self.deps.players.activeSlots();
        for (slots) |slot| {
            const player = &self.deps.players.records[slot];
            const state = &self.players[slot];
            const center = chunkForPosition(player.position);
            const generation = self.deps.players.session_generations[slot];
            if (state.beginSession(generation, center, self.deps.clock.tick)) {
                std.log.info("event=chunk_stream_started slot={d} generation={d} center={d},{d} chunks={d}", .{ slot, generation, center.x, center.z, state.tracker.order.len });
                continue;
            }
            if (geometry.sameChunk(state.tracker.center, center)) continue;
            if (!self.sendRecenter(temporary, slot, center)) continue;
            state.tracker.recenter(center);
            state.request_cursor = 0;
        }

        var requests = plugin_profiler.beginTrace(Trace.request_scan);
        if (slots.len != 0) {
            const capacity = self.deps.materialization.requestCapacity();
            const quota = std.math.divCeil(usize, capacity, slots.len) catch unreachable;
            var requested: usize = 0;
            for (0..slots.len) |offset| {
                const slot = slots[(self.cursor + offset) % slots.len];
                const player = &self.deps.players.records[slot];
                const state = &self.players[slot];
                var player_requested: usize = 0;
                while (player_requested < quota and requested < capacity) {
                    var next_cursor = state.request_cursor;
                    const next = state.tracker.nextMissingFrom(&next_cursor) orelse break;
                    switch (self.deps.materialization.requestRender(player.world, next)) {
                        .resident, .pending => state.request_cursor = next_cursor,
                        .submitted => {
                            state.request_cursor = next_cursor;
                            requested += 1;
                            player_requested += 1;
                            state.requests +|= 1;
                        },
                        .backpressured => break,
                    }
                }
            }
            plugin_profiler.countTrace(Trace.requested, requested);
        }
        requests.end();

        var progress = true;
        while (progress and !self.budgetExhausted()) {
            progress = false;
            for (0..slots.len) |offset| {
                const slot = slots[(self.cursor + offset) % slots.len];
                const state = &self.players[slot];
                state.wait = .none;
                if (self.deps.inputs.takeChunkBatchReceived(slot)) |chunks_per_tick|
                    state.batch.acknowledge(chunks_per_tick);
                if (!self.deps.join.presentationReady(slot) or self.deps.clock.tick <= state.stream_after_tick) continue;
                const session = self.deps.players.session(slot) orelse continue;
                const output = self.deps.sessions.outputState(session) orelse continue;
                if (output.credit_bytes == 0) {
                    state.output_backpressure +|= 1;
                    state.wait = .output;
                    plugin_profiler.countTrace(Trace.output_backpressure, 1);
                    continue;
                }
                if (state.batch.phase == .open) {
                    if (self.finishBatch(temporary, session, state)) progress = true;
                    continue;
                }
                const world = self.deps.players.records[slot].world;
                var positions: [microbatch_chunks]geometry.ChunkPos = undefined;
                var arguments: [microbatch_chunks]ChunkPacket.Arguments = undefined;
                var items: [microbatch_chunks]lightning_rod.sessions.PacketBatchItem = undefined;
                var iterator = state.tracker.missingIterator();
                var count: usize = 0;
                while (count < @as(usize, state.batch.limit)) {
                    const chunk = iterator.next() orelse break;
                    if (self.deps.blocks.materializedChunk(world, chunk) == null) continue;
                    positions[count] = chunk;
                    count += 1;
                }
                if (count == 0) {
                    plugin_profiler.countTrace(Trace.resident_wait, 1);
                    state.resident_waits +|= 1;
                    state.wait = .resident;
                    continue;
                }
                if (!state.batch.start(self.sendBatchStart(temporary, session))) {
                    state.output_backpressure +|= 1;
                    state.wait = .output;
                    plugin_profiler.countTrace(Trace.output_backpressure, 1);
                    continue;
                }
                for (positions[0..count], arguments[0..count], items[0..count]) |position, *arguments_entry, *item| {
                    arguments_entry.* = .{ .streaming = self, .world = world, .position = position };
                    item.* = .{ .recipient = session, .encoder = lightning_rod.sessions.generated(ChunkPacket, arguments_entry) };
                }
                var packet_batch = plugin_profiler.beginTrace(Trace.packet_batch);
                const admissions = self.deps.sessions.batch(temporary, items[0..count], .chunks) catch &.{};
                packet_batch.end();
                var accepted: u16 = 0;
                var backpressured: u16 = 0;
                for (positions[0..admissions.len], admissions) |position, admission| switch (admission) {
                    .accepted => {
                        state.tracker.mark(position);
                        accepted +|= 1;
                        if (!self.chunkNeededByAnotherPlayer(slot, world, position)) _ = self.deps.blocks.evictChunk(world, position);
                    },
                    .backpressured => backpressured +|= 1,
                    .closed, .wrong_protocol, .wrong_phase => {},
                };
                state.batch.recordAccepted(accepted);
                plugin_profiler.countTrace(Trace.delivered, accepted);
                plugin_profiler.countTrace(Trace.output_backpressure, backpressured);
                state.delivered +|= accepted;
                state.output_backpressure +|= backpressured;
                if (backpressured != 0) state.wait = .output;
                progress = self.finishBatch(temporary, session, state) or progress or accepted != 0;
                if (self.budgetExhausted()) break;
            }
        }
        if (slots.len != 0) self.cursor = (self.cursor + 1) % slots.len;

        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.players[slot];
            if (state.tracker.sent_count != self.order.indices.len or state.completion_logged) continue;
            state.completion_logged = true;
            const activity = self.deps.materialization.activity();
            std.log.info("event=chunk_stream_profile slot={d} chunks={d} generation_us={d} materialization_us={d} persistence_decode_us={d} persistence_encode_us={d} persistence_stage_us={d} lighting_us={d} packet_encode_us={d} encoded_chunks={d} generation_calls={d} generated={d}", .{
                slot,
                state.tracker.sent_count,
                activity.generation_nanoseconds / std.time.ns_per_us,
                activity.materialization_nanoseconds / std.time.ns_per_us,
                activity.decode_nanoseconds / std.time.ns_per_us,
                activity.encode_nanoseconds / std.time.ns_per_us,
                activity.stage_nanoseconds / std.time.ns_per_us,
                self.lighting_nanoseconds / std.time.ns_per_us,
                self.encoding_nanoseconds / std.time.ns_per_us,
                self.encoded_chunks,
                activity.generation_calls,
                activity.generated_chunks,
            });
        }
        self.logDiagnostics();
    }

    fn logDiagnostics(self: *ChunkStreaming) void {
        if (self.deps.clock.tick == 0 or self.deps.clock.tick % diagnostic_interval_ticks != 0) return;
        const materialization = self.deps.materialization.activity();
        const previous = self.last_materialization;
        self.last_materialization = materialization;
        std.log.info("event=chunk_io_work decode_us={d} encode_us={d} stage_us={d} queued_chunks={d} queued_bytes={d}", .{
            (materialization.decode_nanoseconds -| previous.decode_nanoseconds) / std.time.ns_per_us,
            (materialization.encode_nanoseconds -| previous.encode_nanoseconds) / std.time.ns_per_us,
            (materialization.stage_nanoseconds -| previous.stage_nanoseconds) / std.time.ns_per_us,
            materialization.queued_chunks,
            materialization.queued_bytes,
        });
        std.log.info("event=chunk_work io_free={d} reading={d} request_waiting={d} generating={d} transient={d}/{d} dirty={d} projection_requests={d} render_requests={d} cold_requests={d} read_hits={d} read_misses={d} generation_calls={d} generation_us={d} generation_max_us={d} generated={d} emitted={d} installed={d} materialization_us={d} persisted={d} derived_cache_misses={d} staged={d} staging={} checkpoint={}", .{
            materialization.free,
            materialization.reading,
            materialization.request_waiting,
            materialization.generating,
            materialization.transient_chunks,
            materialization.transient_capacity,
            materialization.dirty_chunks,
            materialization.projection_requests -| previous.projection_requests,
            materialization.render_requests -| previous.render_requests,
            materialization.cold_requests -| previous.cold_requests,
            materialization.read_hits -| previous.read_hits,
            materialization.read_misses -| previous.read_misses,
            materialization.generation_calls -| previous.generation_calls,
            (materialization.generation_nanoseconds -| previous.generation_nanoseconds) / std.time.ns_per_us,
            materialization.generation_maximum_nanoseconds / std.time.ns_per_us,
            materialization.generated_chunks -| previous.generated_chunks,
            materialization.emitted_shapes -| previous.emitted_shapes,
            materialization.installed_shapes -| previous.installed_shapes,
            (materialization.materialization_nanoseconds -| previous.materialization_nanoseconds) / std.time.ns_per_us,
            materialization.persisted_chunks -| previous.persisted_chunks,
            materialization.derived_cache_misses -| previous.derived_cache_misses,
            materialization.staged_chunks,
            materialization.staging,
            materialization.checkpoint_pending,
        });
        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.players[slot];
            if (state.tracker.sent_count == self.order.indices.len) continue;
            const session = self.deps.players.session(slot) orelse continue;
            const output = self.deps.sessions.outputState(session) orelse lightning_rod.sessions.OutputState{ .credit_bytes = 0, .queued_bytes = 0, .capacity_bytes = 0 };
            std.log.info("event=chunk_stream slot={d} sent={d}/{d} delivered={d} wait={s} resident_waits={d} requests={d} backpressure={d} output={d}/{d}", .{
                slot,
                state.tracker.sent_count,
                self.order.indices.len,
                state.delivered,
                @tagName(state.wait),
                state.resident_waits,
                state.requests,
                state.output_backpressure,
                output.queued_bytes,
                output.capacity_bytes,
            });
            state.clearDiagnostics();
        }
    }

    fn chunkNeededByAnotherPlayer(self: *const ChunkStreaming, sent_slot: u16, world: lightning_rod.world_identity.Handle, position: geometry.ChunkPos) bool {
        for (self.deps.players.activeSlots()) |slot| {
            if (slot == sent_slot or !self.deps.players.records[slot].world.eql(world)) continue;
            if (!self.deps.join.presentationReady(slot)) continue;
            if (self.players[slot].tracker.wants(position)) return true;
        }
        return false;
    }

    fn chunkNeededByAnyPlayer(self: *const ChunkStreaming, world: lightning_rod.world_identity.Handle, position: geometry.ChunkPos) bool {
        for (self.deps.players.activeSlots()) |slot| {
            if (!self.deps.players.records[slot].world.eql(world)) continue;
            if (!self.deps.join.presentationReady(slot)) continue;
            if (self.players[slot].tracker.wants(position)) return true;
        }
        return false;
    }

    pub fn needsMaterialization(self: *const ChunkStreaming, world: lightning_rod.world_identity.Handle, position: geometry.ChunkPos) bool {
        return self.chunkNeededByAnyPlayer(world, position);
    }

    fn budgetExhausted(self: *const ChunkStreaming) bool {
        const elapsed = plugin_profiler.tickElapsedNanoseconds() orelse return false;
        return elapsed -| self.tick_started_ns >= self.configuration.tick_budget_ns;
    }

    fn sendRecenter(self: *ChunkStreaming, temporary: std.mem.Allocator, slot: u16, position: geometry.ChunkPos) bool {
        const session = self.deps.players.session(slot) orelse return false;
        const result = self.deps.sessions.sendOne(temporary, session, .control, RecenterPacket, &position) catch return false;
        return result == .accepted;
    }

    fn sendBatchStart(self: *ChunkStreaming, temporary: std.mem.Allocator, session: lightning_rod.players.Session) lightning_rod.sessions.PacketAdmission {
        const arguments = BatchStartPacket.Arguments{};
        return self.deps.sessions.sendOne(temporary, session, .control, BatchStartPacket, &arguments) catch .backpressured;
    }

    fn finishBatch(self: *ChunkStreaming, temporary: std.mem.Allocator, session: lightning_rod.players.Session, state: *Player) bool {
        std.debug.assert(state.batch.phase == .open);
        const count: i32 = state.batch.count;
        const admission = self.deps.sessions.sendOne(temporary, session, .control, BatchFinishedPacket, &count) catch .backpressured;
        if (state.batch.finish(admission)) return count != 0;
        state.output_backpressure +|= 1;
        state.wait = .output;
        plugin_profiler.countTrace(Trace.output_backpressure, 1);
        return false;
    }
};

const BatchStartPacket = struct {
    pub const Arguments = struct {};
    pub const phase: lightning_rod.sessions.Phase = .play;
    pub const maximum_payload_bytes = 5;

    pub fn encode(protocol: lightning_rod.sessions.Protocol, _: *const Arguments, output: []u8) ?lightning_rod.sessions.EncodedPacket {
        const payload = lightning_rod.protocol_versions.staticCall("encodeChunkBatchStart", protocol.value, .{output}) catch return null;
        return .{ .payload = payload };
    }
};

const BatchFinishedPacket = struct {
    pub const Arguments = i32;
    pub const phase: lightning_rod.sessions.Phase = .play;
    pub const maximum_payload_bytes = 10;

    pub fn encode(protocol: lightning_rod.sessions.Protocol, count: *const Arguments, output: []u8) ?lightning_rod.sessions.EncodedPacket {
        const payload = lightning_rod.protocol_versions.staticCall("encodeChunkBatchFinished", protocol.value, .{ output, count.* }) catch return null;
        return .{ .payload = payload };
    }
};

const RecenterPacket = struct {
    pub const Arguments = geometry.ChunkPos;
    pub const phase: lightning_rod.sessions.Phase = .play;
    pub const maximum_payload_bytes = 10;

    pub fn encode(protocol: lightning_rod.sessions.Protocol, position: *const Arguments, output: []u8) ?lightning_rod.sessions.EncodedPacket {
        const payload = lightning_rod.protocol_versions.staticCall("encodeUpdateViewPosition", protocol.value, .{ output, position.x, position.z }) catch return null;
        return .{ .payload = payload };
    }
};

const ChunkPacket = struct {
    pub const Arguments = struct {
        streaming: *ChunkStreaming,
        world: lightning_rod.world_identity.Handle,
        position: geometry.ChunkPos,
    };
    pub const phase: lightning_rod.sessions.Phase = .play;
    pub const maximum_payload_bytes = chunk_packet.maximum_payload_bytes;

    pub fn encode(protocol: lightning_rod.sessions.Protocol, arguments: *const Arguments, output: []u8) ?lightning_rod.sessions.EncodedPacket {
        const self = arguments.streaming;
        const resident = self.deps.blocks.materializedChunkRef(arguments.world, arguments.position, self.deps.clock.tick) orelse return null;
        var lighting_trace = plugin_profiler.beginTrace(ChunkStreaming.Trace.lighting);
        const lighting_started = plugin_profiler.tickElapsedNanoseconds();
        const lighting = self.deps.lighting.presentedChunk(arguments.world, arguments.position);
        if (lighting_started) |start| {
            if (plugin_profiler.tickElapsedNanoseconds()) |finish|
                self.lighting_nanoseconds +%= finish -| start;
        }
        lighting_trace.end();
        var encoding_trace = plugin_profiler.beginTrace(ChunkStreaming.Trace.encoding);
        const encoding_started = plugin_profiler.tickElapsedNanoseconds();
        const payload = chunk_packet.writeChunkPayload(output, self.deps.blocks, arguments.world, &self.empty_view, arguments.position, &resident.entry.shape, lighting, protocol.value) catch {
            encoding_trace.end();
            return null;
        };
        if (encoding_started) |start| {
            if (plugin_profiler.tickElapsedNanoseconds()) |finish|
                self.encoding_nanoseconds +%= finish -| start;
        }
        self.encoded_chunks +%= 1;
        encoding_trace.end();
        return .{ .payload = payload };
    }
};

fn chunkForPosition(position: geometry.Vec3) geometry.ChunkPos {
    return .{ .x = geometry.chunkCoord(geometry.blockCoord(position.x)), .z = geometry.chunkCoord(geometry.blockCoord(position.z)) };
}

test "a reused player slot receives every chunk for its new session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const order = try chunk_stream.Order.create(arena.allocator(), 1);
    var player = ChunkStreaming.Player{};
    try player.tracker.allocate(arena.allocator(), &order);
    const center = geometry.ChunkPos{ .x = 4, .z = -2 };

    try std.testing.expect(player.beginSession(1, center, 4));
    const first = player.tracker.nextMissing().?;
    player.tracker.mark(first);
    try std.testing.expect(!player.beginSession(1, center, 5));
    try std.testing.expect(!geometry.sameChunk(first, player.tracker.nextMissing().?));

    try std.testing.expect(player.beginSession(2, center, 6));
    try std.testing.expect(geometry.sameChunk(first, player.tracker.nextMissing().?));
}

test "chunk batches retain an open finish across backpressure and acknowledgements tune the next batch" {
    var batch: ChunkStreaming.Batch = .{};
    try std.testing.expect(!batch.start(.backpressured));
    try std.testing.expectEqual(ChunkStreaming.Batch.Phase.idle, batch.phase);

    try std.testing.expect(batch.start(.accepted));
    batch.recordAccepted(3);
    try std.testing.expectEqual(@as(u8, 3), batch.count);
    try std.testing.expect(!batch.finish(.backpressured));
    try std.testing.expectEqual(ChunkStreaming.Batch.Phase.open, batch.phase);
    try std.testing.expectEqual(@as(u8, 3), batch.count);

    try std.testing.expect(batch.finish(.accepted));
    try std.testing.expectEqual(ChunkStreaming.Batch.Phase.idle, batch.phase);
    try std.testing.expectEqual(@as(u8, 0), batch.count);
    batch.acknowledge(3.2);
    try std.testing.expectEqual(ChunkStreaming.Batch.Phase.idle, batch.phase);
    try std.testing.expectEqual(@as(u8, 4), batch.limit);
}

test "invalid chunk batch acknowledgements cannot change the next batch limit" {
    var batch: ChunkStreaming.Batch = .{};
    try std.testing.expect(batch.start(.accepted));
    batch.recordAccepted(1);
    try std.testing.expect(batch.finish(.accepted));
    batch.acknowledge(0);
    try std.testing.expectEqual(ChunkStreaming.Batch.Phase.idle, batch.phase);
    try std.testing.expectEqual(@as(u8, ChunkStreaming.microbatch_chunks), batch.limit);
}

test "a player waiting for spawn data cannot retain another player's render cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const world = lightning_rod.world_identity.Handle{ .index = 0, .generation = 1 };
    var records: [2]lightning_rod.players.CorePlayer align(64) = .{ .{ .world = world }, .{ .world = world } };
    var slots = [_]u16{ 0, 1 };
    var players: lightning_rod.players.Players = undefined;
    players.records = &records;
    players.active_slots = &slots;
    players.active_count = slots.len;
    var ready = [_]bool{ true, false };
    var join: @import("vanilla_join.zig").PlayJoin = undefined;
    join.ready = &ready;
    const order = try chunk_stream.Order.create(arena.allocator(), 1);
    var states = [_]ChunkStreaming.Player{ .{}, .{} };
    for (&states) |*state| {
        try state.tracker.allocate(arena.allocator(), &order);
        _ = state.beginSession(1, .{ .x = 0, .z = 0 }, 1);
    }
    var streaming: ChunkStreaming = undefined;
    streaming.deps.players = &players;
    streaming.deps.join = &join;
    streaming.players = &states;
    const chunk = states[0].tracker.nextMissing().?;
    states[0].tracker.mark(chunk);
    try std.testing.expect(!streaming.chunkNeededByAnotherPlayer(0, world, chunk));
    try std.testing.expect(!streaming.needsMaterialization(world, chunk));
    ready[1] = true;
    try std.testing.expect(streaming.chunkNeededByAnotherPlayer(0, world, chunk));
    try std.testing.expect(streaming.needsMaterialization(world, chunk));
    states[1].tracker.mark(chunk);
    try std.testing.expect(!streaming.needsMaterialization(world, chunk));
}
