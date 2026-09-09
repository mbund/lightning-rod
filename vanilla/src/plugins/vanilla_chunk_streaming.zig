const lightning_rod = @import("lightning_rod");
const chunk_packet = lightning_rod.chunk_packet;
const chunk_stream = lightning_rod.chunk_stream;
const geometry = lightning_rod.geometry;
const std = @import("std");
const plugin_profiler = lightning_rod.plugin_profiler;
const vanilla_lighting = @import("vanilla_lighting.zig");
const vanilla_persistence = @import("vanilla_persistence.zig");
const view = lightning_rod.view;

pub const ChunkStreaming = struct {
    pub const id = "minecraft:chunk_streaming";
    pub const Trace = enum {
        residency,
        lighting,
        encoding,
        packet_batch,
        request_scan,
        requested,
        delivered,
        client_ack_wait,
        resident_wait,
        output_backpressure,
        budget_wait,
    };
    pub const Configuration = struct {
        view_distance_chunks: i32 = 32,
        tick_budget_ns: u64 = 45 * std.time.ns_per_ms,

        pub fn validate(self: Configuration) !void {
            if (self.view_distance_chunks < 0) return error.InvalidViewDistance;
            if (self.tick_budget_ns == 0) return error.InvalidTickBudget;
        }
    };
    pub const Dependencies = struct {
        blocks: *lightning_rod.blocks.Blocks,
        clock: *lightning_rod.clock.Clock,
        lighting: *vanilla_lighting.Lighting,
        paging: *vanilla_persistence.Persistence,
        players: *lightning_rod.players.Players,
        inputs: *lightning_rod.inputs.Inputs,
        sessions: *lightning_rod.sessions.Sessions,
    };

    const microbatch_chunks = 1;
    const diagnostic_interval_ticks = 100;
    const maximum_unacknowledged_batches = 10;
    const acknowledgement_fallback_ticks = 5;
    const Wait = enum { none, client_ack, resident, output, budget };
    const Player = struct {
        session_generation: u64 = 0,
        tracker: chunk_stream.Tracker = .{},
        unacknowledged_batches: u8 = 0,
        batch_limit: u16 = 1,
        batch_started_tick: u64 = 0,
        pending_batch_finish: ?u16 = null,
        delivered: u32 = 0,
        requests: u32 = 0,
        batches: u16 = 0,
        ack_wait_ticks: u16 = 0,
        maximum_ack_ticks: u16 = 0,
        resident_waits: u16 = 0,
        output_backpressure: u16 = 0,
        last_batch_size: u16 = 0,
        wait: Wait = .none,

        fn beginSession(self: *Player, generation: u64, center: geometry.ChunkPos) bool {
            std.debug.assert(generation != 0);
            if (self.session_generation == generation) return false;
            self.tracker.reset(center);
            self.session_generation = generation;
            self.unacknowledged_batches = 0;
            self.batch_limit = 1;
            self.pending_batch_finish = null;
            self.clearDiagnostics();
            return true;
        }

        fn clearDiagnostics(self: *Player) void {
            self.delivered = 0;
            self.requests = 0;
            self.batches = 0;
            self.ack_wait_ticks = 0;
            self.maximum_ack_ticks = 0;
            self.resident_waits = 0;
            self.output_backpressure = 0;
            self.last_batch_size = 0;
        }
    };

    deps: Dependencies,
    configuration: Configuration,
    order: chunk_stream.Order,
    players: []Player,
    empty_view: view.PlayerView = .{},
    last_paging: vanilla_persistence.Activity = .{},
    cursor: usize = 0,

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

    pub fn tick(self: *ChunkStreaming, temporary: std.mem.Allocator) void {
        self.applyBatchAcknowledgements();
        self.recenterPlayers(temporary);
        var requests = plugin_profiler.beginTrace(Trace.request_scan);
        self.requestChunks();
        requests.end();
        self.stageChunks(temporary);
        self.logDiagnostics();
    }

    fn applyBatchAcknowledgements(self: *ChunkStreaming) void {
        for (self.deps.players.activeSlots()) |slot| {
            const recommendation = self.deps.inputs.takeChunkBatchReceived(slot) orelse continue;
            const state = &self.players[slot];
            if (state.unacknowledged_batches == 0) continue;
            state.unacknowledged_batches = 0;
            const elapsed = self.deps.clock.tick -| state.batch_started_tick;
            state.maximum_ack_ticks = @max(state.maximum_ack_ticks, @as(u16, @intCast(@min(elapsed, std.math.maxInt(u16)))));
            if (!std.math.isFinite(recommendation)) {
                state.batch_limit = 1;
                continue;
            }
            const rounded = @ceil(recommendation);
            state.batch_limit = @intFromFloat(std.math.clamp(rounded, 1, @as(f32, @floatFromInt(self.order.indices.len))));
        }
    }

    fn recenterPlayers(self: *ChunkStreaming, temporary: std.mem.Allocator) void {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            const center = chunkForPosition(player.position);
            const state = &self.players[slot];
            const generation = self.deps.players.session_generations[slot];
            if (state.beginSession(generation, center)) continue;
            if (geometry.sameChunk(state.tracker.center, center)) continue;
            if (!self.finishPendingBatch(temporary, slot, state)) continue;
            if (!self.sendControl(temporary, slot, .{ .recenter = center })) continue;
            state.tracker.recenter(center);
        }
    }

    fn stageChunks(self: *ChunkStreaming, temporary: std.mem.Allocator) void {
        const slots = self.deps.players.activeSlots();
        if (slots.len == 0) return;
        for (0..slots.len) |offset| {
            const index = (self.cursor + offset) % slots.len;
            const slot = slots[index];
            const state = &self.players[slot];
            state.wait = .none;
            if (self.budgetExhausted()) {
                plugin_profiler.countTrace(Trace.budget_wait, 1);
                state.wait = .budget;
                break;
            }
            if (!self.finishPendingBatch(temporary, slot, state)) {
                state.wait = .output;
                continue;
            }
            if (!self.canSendBatch(state)) {
                plugin_profiler.countTrace(Trace.client_ack_wait, 1);
                state.ack_wait_ticks +|= 1;
                state.wait = .client_ack;
                continue;
            }
            const player = &self.deps.players.records[slot];
            _ = self.stagePlayerBatch(temporary, slot, player.world);
        }
        self.cursor = (self.cursor + 1) % slots.len;
    }

    fn requestChunks(self: *ChunkStreaming) void {
        const slots = self.deps.players.activeSlots();
        if (slots.len == 0) return;
        const capacity = self.deps.paging.requestCapacity();
        const quota = std.math.divCeil(usize, capacity, slots.len) catch unreachable;
        var requested: usize = 0;
        defer plugin_profiler.countTrace(Trace.requested, requested);
        for (0..slots.len) |offset| {
            const index = (self.cursor + offset) % slots.len;
            const slot = slots[index];
            const player = &self.deps.players.records[slot];
            const state = &self.players[slot];
            var iterator = state.tracker.missingIterator();
            for (0..quota) |_| {
                const chunk = iterator.next() orelse break;
                if (!self.requestOne(state, player.world, chunk, &requested)) return;
            }
        }
    }

    fn requestOne(self: *ChunkStreaming, state: *Player, world: lightning_rod.world_identity.Handle, position: geometry.ChunkPos, requested: *usize) bool {
        switch (self.deps.paging.request(world, position)) {
            .resident, .pending => {},
            .submitted => {
                requested.* += 1;
                state.requests +|= 1;
                if (requested.* == self.deps.paging.requestCapacity()) return false;
            },
            .backpressured => return false,
        }
        return true;
    }

    fn stagePlayerBatch(self: *ChunkStreaming, temporary: std.mem.Allocator, slot: u16, world: lightning_rod.world_identity.Handle) usize {
        const state = &self.players[slot];
        const session = self.deps.players.session(slot) orelse return 0;
        const limit: usize = state.batch_limit;
        if (limit == 0) return 0;

        var positions: [microbatch_chunks]geometry.ChunkPos = undefined;
        var arguments: [microbatch_chunks]ChunkPacket.Arguments = undefined;
        var items: [microbatch_chunks]lightning_rod.sessions.PacketBatchItem = undefined;
        var iterator = state.tracker.missingIterator();
        var count = self.collectResident(world, &iterator, positions[0..@min(limit, microbatch_chunks)]);
        if (count == 0) {
            plugin_profiler.countTrace(Trace.resident_wait, 1);
            state.resident_waits +|= 1;
            state.wait = .resident;
            return 0;
        }
        if (!self.sendControl(temporary, slot, .begin_batch)) {
            state.wait = .output;
            return 0;
        }
        var accepted: usize = 0;
        var backpressured: usize = 0;
        while (count != 0) {
            if (accepted != 0 and self.budgetExhausted()) break;
            const accepted_before = accepted;
            for (positions[0..count], arguments[0..count], items[0..count]) |position, *arguments_entry, *item| {
                arguments_entry.* = .{ .streaming = self, .world = world, .position = position };
                item.* = .{ .recipient = session, .encoder = lightning_rod.sessions.generated(ChunkPacket, arguments_entry) };
            }
            var packet_batch = plugin_profiler.beginTrace(Trace.packet_batch);
            const admissions = self.deps.sessions.tryBatch(temporary, items[0..count], .chunks) catch &.{};
            packet_batch.end();
            for (positions[0..admissions.len], admissions) |position, admission| switch (admission) {
                .accepted => {
                    state.tracker.mark(position);
                    accepted += 1;
                },
                .backpressured => backpressured += 1,
                .closed, .wrong_protocol, .wrong_phase => {},
            };
            if (admissions.len != count or accepted - accepted_before != count or accepted == limit) break;
            count = self.collectResident(world, &iterator, positions[0..@min(limit - accepted, microbatch_chunks)]);
        }
        plugin_profiler.countTrace(Trace.delivered, accepted);
        plugin_profiler.countTrace(Trace.output_backpressure, backpressured);
        state.delivered +|= @intCast(accepted);
        state.output_backpressure +|= @intCast(@min(backpressured, std.math.maxInt(u16)));
        state.last_batch_size = @intCast(accepted);
        state.batches +|= @intFromBool(accepted != 0);
        if (backpressured != 0) state.wait = .output;
        state.pending_batch_finish = @intCast(accepted);
        if (!self.finishPendingBatch(temporary, slot, state)) state.wait = .output;
        return accepted;
    }

    fn finishPendingBatch(self: *ChunkStreaming, temporary: std.mem.Allocator, slot: u16, state: *Player) bool {
        const count = state.pending_batch_finish orelse return true;
        if (!self.sendControl(temporary, slot, .{ .finish_batch = count })) return false;
        state.pending_batch_finish = null;
        state.unacknowledged_batches +|= 1;
        state.batch_started_tick = self.deps.clock.tick;
        state.wait = .client_ack;
        return true;
    }

    fn logDiagnostics(self: *ChunkStreaming) void {
        if (self.deps.clock.tick == 0 or self.deps.clock.tick % diagnostic_interval_ticks != 0) return;
        const paging = self.deps.paging.activity();
        const previous = self.last_paging;
        self.last_paging = paging;
        std.log.info("event=chunk_work free={d} reading={d} generation_waiting={d} generating={d} read_hits={d} read_misses={d} generation_slices={d} generation_us={d} generated={d} persisted={d} derived_rebuilds={d} dirty={d} staged={d} staging={} checkpoint={}", .{
            paging.free,
            paging.reading,
            paging.generation_waiting,
            paging.generating,
            paging.read_hits -| previous.read_hits,
            paging.read_misses -| previous.read_misses,
            paging.generation_slices -| previous.generation_slices,
            (paging.generation_nanoseconds -| previous.generation_nanoseconds) / std.time.ns_per_us,
            paging.generated_chunks -| previous.generated_chunks,
            paging.persisted_chunks -| previous.persisted_chunks,
            paging.derived_rebuilds -| previous.derived_rebuilds,
            paging.dirty_chunks,
            paging.staged_chunks,
            paging.staging,
            paging.checkpoint_pending,
        });
        for (self.deps.players.activeSlots()) |slot| {
            const state = &self.players[slot];
            if (state.tracker.sent_count == self.order.indices.len and state.unacknowledged_batches == 0) continue;
            const session = self.deps.players.session(slot) orelse continue;
            const output = self.deps.sessions.outputState(session) orelse lightning_rod.sessions.OutputState{ .credit_bytes = 0, .queued_bytes = 0, .capacity_bytes = 0 };
            std.log.info("event=chunk_stream slot={d} sent={d}/{d} delivered={d} batches={d} last_batch={d} client_limit={d} unacked={d} wait={s} ack_wait={d} max_ack={d} resident_waits={d} requests={d} backpressure={d} output={d}/{d}", .{
                slot,
                state.tracker.sent_count,
                self.order.indices.len,
                state.delivered,
                state.batches,
                state.last_batch_size,
                state.batch_limit,
                state.unacknowledged_batches,
                @tagName(state.wait),
                state.ack_wait_ticks,
                state.maximum_ack_ticks,
                state.resident_waits,
                state.requests,
                state.output_backpressure,
                output.queued_bytes,
                output.capacity_bytes,
            });
            state.clearDiagnostics();
        }
    }

    fn canSendBatch(self: *const ChunkStreaming, state: *const Player) bool {
        if (state.unacknowledged_batches < maximum_unacknowledged_batches) return true;
        return self.deps.clock.tick -| state.batch_started_tick >=
            acknowledgement_fallback_ticks;
    }

    fn collectResident(self: *ChunkStreaming, world: lightning_rod.world_identity.Handle, iterator: *chunk_stream.Tracker.MissingIterator, positions: []geometry.ChunkPos) usize {
        var residency = plugin_profiler.beginTrace(Trace.residency);
        defer residency.end();
        var count: usize = 0;
        while (count < positions.len) {
            const chunk = iterator.next() orelse break;
            if (!self.deps.blocks.ticketResidentChunk(world, chunk)) break;
            positions[count] = chunk;
            count += 1;
        }
        return count;
    }

    fn budgetExhausted(self: *const ChunkStreaming) bool {
        const elapsed = plugin_profiler.tickElapsedNanoseconds() orelse return false;
        return elapsed >= self.configuration.tick_budget_ns;
    }

    fn sendControl(self: *ChunkStreaming, temporary: std.mem.Allocator, slot: u16, control: ChunkControl) bool {
        const session = self.deps.players.session(slot) orelse return false;
        const result = self.deps.sessions.sendOne(temporary, session, .control, ControlPacket, &control) catch return false;
        return result == .accepted;
    }
};

const ChunkControl = union(enum) { begin_batch, finish_batch: u16, recenter: geometry.ChunkPos };

const ControlPacket = struct {
    pub const Arguments = ChunkControl;
    pub const phase: lightning_rod.sessions.Phase = .play;
    pub const maximum_payload_bytes = 16;

    pub fn encode(protocol: lightning_rod.sessions.Protocol, control: *const Arguments, output: []u8) ?lightning_rod.sessions.EncodedPacket {
        const payload = switch (control.*) {
            .begin_batch => lightning_rod.protocol_versions.staticCall("encodeChunkBatchStart", protocol.value, .{output}),
            .finish_batch => |count| lightning_rod.protocol_versions.staticCall("encodeChunkBatchFinished", protocol.value, .{ output, @as(i32, count) }),
            .recenter => |position| lightning_rod.protocol_versions.staticCall("encodeUpdateViewPosition", protocol.value, .{ output, position.x, position.z }),
        } catch return null;
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
        const resident = self.deps.blocks.residentChunkRef(arguments.world, arguments.position, self.deps.clock.tick) orelse return null;
        var lighting_trace = plugin_profiler.beginTrace(ChunkStreaming.Trace.lighting);
        const lighting = self.deps.lighting.chunk(arguments.world, arguments.position);
        lighting_trace.end();
        var encoding_trace = plugin_profiler.beginTrace(ChunkStreaming.Trace.encoding);
        const payload = chunk_packet.writeChunkPayload(output, self.deps.blocks, arguments.world, &self.empty_view, arguments.position, &resident.entry.shape, lighting, protocol.value) catch {
            encoding_trace.end();
            return null;
        };
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

    try std.testing.expect(player.beginSession(1, center));
    const first = player.tracker.nextMissing().?;
    player.tracker.mark(first);
    try std.testing.expect(!player.beginSession(1, center));
    try std.testing.expect(!geometry.sameChunk(first, player.tracker.nextMissing().?));

    try std.testing.expect(player.beginSession(2, center));
    try std.testing.expect(geometry.sameChunk(first, player.tracker.nextMissing().?));
}
