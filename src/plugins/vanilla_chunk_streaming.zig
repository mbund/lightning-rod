const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const world_clock = lightning_rod.clock;
const std = @import("std");
const plugin_profiler = lightning_rod.plugin_profiler;
const config = lightning_rod.config.value;
const chunk_stream = lightning_rod.chunk_stream;
const vanilla_lighting = @import("vanilla_lighting.zig");
const Packets = lightning_rod.Packets;

pub const ChunkStreaming = struct {
    pub const id = "minecraft:chunk_streaming";

    lighting: *vanilla_lighting.Lighting,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, lighting: *vanilla_lighting.Lighting, outputs: *Packets) !*ChunkStreaming {
        const self = try allocator.create(ChunkStreaming);
        self.* = .{ .lighting = lighting, .outputs = outputs };
        return self;
    }

    const view_chunk_count = chunk_stream.chunk_count;
    const maximum_chunks_per_batch: u16 = 64;
    const maximum_candidates_per_tick: usize = 256;

    const StreamState = struct {
        blocked: bool = false,
        batch_started: bool = false,
        batch_count: u16 = 0,
        batch_limit: u16 = 0,
        candidates: usize = 0,
        cursor: usize = 0,
    };

    const StreamResult = enum { sent, deferred, blocked };

    pub const Trace = enum {
        resource_lookup,
        terrain_request,
        lighting_lookup,
        lighting_rebuild,
        packet_queue,
    };

    fn chunkForPosition(position: geometry.Vec3) geometry.ChunkPos {
        return .{
            .x = geometry.chunkCoord(geometry.blockCoord(position.x)),
            .z = geometry.chunkCoord(geometry.blockCoord(position.z)),
        };
    }

    fn streamChunks(
        outputs: *Packets,
        lighting: *vanilla_lighting.Lighting,
    ) !void {
        const backend = outputs;
        if (!backend.chunkStreamingEnabled()) return;
        backend.prunePlaySlots();
        const slots = backend.activePlaySlots();
        if (slots.len == 0) return;
        var states: [config.max_players]StreamState = undefined;
        @memset(states[0..slots.len], .{});
        for (slots, states[0..slots.len]) |slot, *state|
            state.batch_limit = @min(maximum_chunks_per_batch, backend.beginChunkBatch(slot));
        prefetchChunks(backend, slots);
        try recenterPlayers(backend, slots, states[0..slots.len]);
        try streamAvailableChunks(outputs, lighting, slots, states[0..slots.len]);
        backend.advanceChunkStreamCursor();
        try finishBatches(backend, slots, states[0..slots.len]);
        backend.prunePlaySlots();
    }

    fn prefetchChunks(backend: *Packets, slots: []const u16) void {
        var prefetch_budget = config.max_concurrent_chunk_loads;
        for (0..slots.len) |offset| {
            if (prefetch_budget == 0) break;
            const player_index = (backend.chunkStreamCursor() + offset) % slots.len;
            const players_remaining = slots.len - offset;
            const fair_share = std.math.divCeil(
                usize,
                prefetch_budget,
                players_remaining,
            ) catch unreachable;
            const admitted = backend.prefetchChunkData(
                slots[player_index],
                fair_share,
            );
            prefetch_budget -= @min(prefetch_budget, admitted);
        }
    }

    fn recenterPlayers(backend: *Packets, slots: []const u16, states: []StreamState) !void {
        for (slots, 0..) |slot, player_index| {
            const center = chunkForPosition(backend.playerPosition(slot));
            const current = backend.chunkViewCenter(slot);
            if (center.x == current.x and center.z == current.z) continue;
            backend.queue_update_view_position(slot, center.x, center.z) catch |err| switch (err) {
                error.PlayerWriteBackpressure => {
                    states[player_index].blocked = true;
                    continue;
                },
                else => return err,
            };
            backend.recenterChunkView(slot, center);
        }
    }

    fn streamAvailableChunks(
        outputs: *Packets,
        lighting: *vanilla_lighting.Lighting,
        slots: []const u16,
        states: []StreamState,
    ) !void {
        const backend = outputs;
        for (0..view_chunk_count) |_| {
            var made_progress = false;
            for (0..slots.len) |offset| {
                const player_index = (backend.chunkStreamCursor() + offset) % slots.len;
                const slot = slots[player_index];
                const state = &states[player_index];
                if (state.blocked) continue;
                if (state.batch_count == state.batch_limit or
                    state.candidates == maximum_candidates_per_tick)
                {
                    state.blocked = true;
                    continue;
                }
                if (backend.chunkOutputBackpressured(slot)) {
                    state.blocked = true;
                    continue;
                }
                const missing = backend.nextMissingChunk(slot, &state.cursor) orelse {
                    state.blocked = true;
                    continue;
                };
                state.candidates += 1;
                made_progress = true;
                if (try streamOneChunk(outputs, lighting, slot, missing, state) == .blocked)
                    state.blocked = true;
            }
            if (!made_progress) break;
        }
    }

    fn streamOneChunk(
        outputs: *Packets,
        lighting: *vanilla_lighting.Lighting,
        slot: u16,
        missing: geometry.ChunkPos,
        state: *StreamState,
    ) !StreamResult {
        const backend = outputs;
        const world = backend.playerWorld(slot);
        const preparation = result: {
            var trace = plugin_profiler.beginTrace(Trace.resource_lookup);
            defer trace.end();
            break :result backend.prepareChunkData(slot, missing);
        };
        const prepared = preparation catch |err| switch (err) {
            error.ChunkLoadPending, error.ChunkLoadFailed => return .deferred,
        };
        if (prepared == .missing) {
            var trace = plugin_profiler.beginTrace(Trace.terrain_request);
            defer trace.end();
            if (!backend.generateChunkData(slot, missing)) return .deferred;
        }
        const chunk_light = cached: {
            var trace = plugin_profiler.beginTrace(Trace.lighting_lookup);
            defer trace.end();
            break :cached lighting.cachedChunk(world, missing);
        } orelse rebuild: {
            var trace = plugin_profiler.beginTrace(Trace.lighting_rebuild);
            defer trace.end();
            break :rebuild lighting.chunk(world, missing);
        };
        if (!state.batch_started) {
            backend.queueChunkBatchStart(slot) catch |err| switch (err) {
                error.PlayerWriteBackpressure => return .blocked,
                else => return err,
            };
            state.batch_started = true;
        }
        const queued = result: {
            var trace = plugin_profiler.beginTrace(Trace.packet_queue);
            defer trace.end();
            break :result backend.queueChunkPacket(slot, missing, chunk_light);
        };
        queued catch |err| switch (err) {
            error.PlayerWriteBackpressure,
            error.ChunkLoadPending,
            error.ChunkLoadFailed,
            error.ChunkRequiresCompression,
            => return .blocked,
            else => return err,
        };
        backend.markChunkSent(slot, missing);
        if (backend.releaseStreamedChunk(slot, missing)) |resident_index|
            lighting.releaseResidentChunk(resident_index, world, missing);
        lighting.flushChanges();
        state.batch_count += 1;
        return .sent;
    }

    fn finishBatches(backend: *Packets, slots: []const u16, states: []const StreamState) !void {
        for (slots, 0..) |slot, player_index| {
            const state = states[player_index];
            if (!state.batch_started) continue;
            try backend.queueChunkBatchFinished(slot, state.batch_count);
            backend.finishChunkBatch(slot, state.batch_count);
        }
    }

    pub fn tick(self: *ChunkStreaming, _: std.mem.Allocator) void {
        streamChunks(self.outputs, self.lighting) catch |err| self.outputs.input_failed(err);
    }
};
