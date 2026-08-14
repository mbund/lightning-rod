const entity_store = @import("world/entities.zig");
const input_store = @import("world/inputs.zig");
const player_store = @import("world/players.zig");
const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const vanilla_time = @import("world/time.zig");
const game_rules = @import("world/game_rules.zig");
const world_random = @import("world/random.zig");
const world_clock = @import("world/clock.zig");
const world_store = @import("world/worlds.zig");
const world_identity = @import("world/identity.zig");
const std = @import("std");
const config = @import("config.zig").value;
const view = @import("view.zig");
const commands = @import("commands.zig");
const play_decode = @import("play_decode.zig");
const protocol_versions = @import("protocol_versions.zig");
const protocol_values = @import("protocol_values.zig");
const protocol_support = @import("protocol_support");
const game_data = @import("game_data.zig");
const registry_data = @import("registry_data");
const play_encode = @import("play_encode.zig");
const diagnostics = @import("diagnostics.zig");
const light_projection = @import("light_projection.zig");
const hot_reload_abi = @import("hot_reload_abi.zig");
const tick_transport = @import("tick_transport.zig");
const tick_io = @import("tick_io.zig");
const replication = @import("replication.zig");
const chunk_stream = @import("chunk_view_tracker.zig");
const chunk_storage = @import("chunk_storage.zig");
const chunk_packet = @import("chunk_packet.zig");

pub const PendingPlayDisconnect = struct {
    world: world_identity.Handle,
    entity_id: i32,
    uuid: u128,
    name: [config.max_username_bytes]u8,
    name_len: u8,
    dig_position: ?geometry.BlockPos,

    pub fn nameSlice(self: *const PendingPlayDisconnect) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ReloadResult = struct {
    requester: u16,
    succeeded: bool,
    elapsed_ms: u64,
};

pub const PacketReservation = struct {
    bytes: []u8,
    protocol_number: i32,
    transport: ?tick_transport.Reservation = null,
};

pub const DirectPacketApi = struct {
    context: *anyopaque,
    begin: *const fn (*anyopaque, u16, usize) PacketReservation,
    finish: *const fn (*anyopaque, u16, usize) anyerror!void,
    abort: *const fn (*anyopaque, u16) void,
    backpressured: *const fn (*anyopaque, u16) bool,
};

pub const BorrowedInput = struct {
    slot: u16,
    protocol_number: i32,
    payload: []const u8,
};

pub const KeepAliveState = struct {
    last_tick: u64 = 0,
    last_id: i64 = 0,
    latency_ms: i32 = 0,
    awaiting_response: bool = false,
    latency_dirty: bool = false,
};

const view_chunk_count = chunk_stream.chunk_count;

pub const ChunkDataPreparation = enum {
    ready,
    loaded,
    missing,
};

pub const Host = struct {
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    inputs: *input_store.Inputs,
    containers: *player_store.Containers,
    blocks: *block_store.Blocks,
    living: *entity_store.LivingEntities,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    io: *tick_io.TickIo,
    exchange: ?*hot_reload_abi.TickExchange = null,
    connection_handles: []const ?hot_reload_abi.ConnectionHandle = &.{},
    borrowed_inputs: []const BorrowedInput = &.{},
    active_play_slots_override: ?[]const u16 = null,
    active_play_slot_storage: ?[]u16 = null,
    active_play_slot_count: ?*usize = null,
    pending_play_join_storage: ?[]u16 = null,
    pending_play_join_count: ?*usize = null,
    pending_play_disconnect_storage: ?[]PendingPlayDisconnect = null,
    pending_play_disconnect_count: ?*usize = null,
    keep_alive_states: ?[]KeepAliveState = null,
    reload_result: ?*?ReloadResult = null,
    replication_state: *replication.State,
    chunk_stream_cursor: *usize,
    direct_packet_api: ?DirectPacketApi = null,
    chunk_streaming_enabled: bool,
    runtime_maximum_players: usize,

    pub const production_tick_host = true;

    pub fn init(
        worlds: *world_store.Worlds,
        clock: *world_clock.Clock,
        time: *vanilla_time.Time,
        rules: *game_rules.GameRules,
        random: *world_random.Random,
        inputs: *input_store.Inputs,
        containers: *player_store.Containers,
        blocks: *block_store.Blocks,
        living: *entity_store.LivingEntities,
        players: *player_store.Players,
        items: *entity_store.ItemEntities,
        io: *tick_io.TickIo,
        exchange: *hot_reload_abi.TickExchange,
        connection_handles: []const ?hot_reload_abi.ConnectionHandle,
        borrowed_inputs: []const BorrowedInput,
        active_play_slot_storage: []u16,
        active_play_slot_count: *usize,
        pending_play_join_storage: []u16,
        pending_play_join_count: *usize,
        pending_play_disconnect_storage: []PendingPlayDisconnect,
        pending_play_disconnect_count: *usize,
        keep_alive_states: []KeepAliveState,
        reload_result: *?ReloadResult,
        replication_state: *replication.State,
        chunk_stream_cursor: *usize,
        chunk_streaming_enabled: bool,
        runtime_maximum_players: usize,
    ) Host {
        return .{
            .worlds = worlds,
            .clock = clock,
            .time = time,
            .rules = rules,
            .random = random,
            .inputs = inputs,
            .containers = containers,
            .blocks = blocks,
            .living = living,
            .players = players,
            .items = items,
            .io = io,
            .exchange = exchange,
            .connection_handles = connection_handles,
            .borrowed_inputs = borrowed_inputs,
            .active_play_slot_storage = active_play_slot_storage,
            .active_play_slot_count = active_play_slot_count,
            .pending_play_join_storage = pending_play_join_storage,
            .pending_play_join_count = pending_play_join_count,
            .pending_play_disconnect_storage = pending_play_disconnect_storage,
            .pending_play_disconnect_count = pending_play_disconnect_count,
            .keep_alive_states = keep_alive_states,
            .reload_result = reload_result,
            .replication_state = replication_state,
            .chunk_stream_cursor = chunk_stream_cursor,
            .chunk_streaming_enabled = chunk_streaming_enabled,
            .runtime_maximum_players = runtime_maximum_players,
        };
    }

    pub fn dispatchTickInputs(self: *Host, handler: *play_decode.Handler) void {
        for (self.borrowed_inputs) |packet| {
            if (packet.slot >= self.players.records.len or
                self.players.records[packet.slot].state != .play)
                continue;
            protocol_versions.staticCall(
                "dispatchPlay",
                packet.protocol_number,
                .{ packet.payload, packet.slot, handler },
            ) catch |err| {
                var storage: [192]u8 = undefined;
                const message = std.fmt.bufPrint(
                    &storage,
                    "warn(protocol): event=client_tick_input_error slot={} err={}\n",
                    .{ packet.slot, err },
                ) catch "warn(protocol): event=client_tick_input_error\n";
                self.logMessage(message);
                const exchange = self.exchange orelse continue;
                const index: usize = packet.slot;
                if (index >= self.connection_handles.len) continue;
                const connection = self.connection_handles[index] orelse continue;
                _ = exchange.appendCloseConnection(connection, .kicked);
            };
        }
    }
    pub fn activePlaySlots(self: *const Host) []const u16 {
        if (self.active_play_slot_storage) |storage|
            return storage[0..self.active_play_slot_count.?.*];
        return self.active_play_slots_override.?;
    }

    fn chunkForPosition(position: geometry.Vec3) geometry.ChunkPos {
        return .{
            .x = geometry.chunkCoord(geometry.blockCoord(position.x)),
            .z = geometry.chunkCoord(geometry.blockCoord(position.z)),
        };
    }
    pub fn pendingPlayJoins(self: *const Host) []const u16 {
        const storage = self.pending_play_join_storage orelse
            diagnostics.panic("tick host has no pending-play-join storage", &.{});
        const count = self.pending_play_join_count orelse
            diagnostics.panic("tick host has no pending-play-join count", &.{});
        return storage[0..count.*];
    }
    pub fn preparePlayJoinTerrain(self: *Host, slot: u16) bool {
        const player = &self.players.records[slot];
        if (player.play_join_terrain_ready) return true;
        const chunk = geometry.chunkForBlock(.{
            .x = geometry.blockCoord(player.position.x),
            .y = @intCast(std.math.clamp(
                geometry.blockCoord(player.position.y),
                @as(i32, config.world_min_y),
                @as(i32, block_store.world_top_y),
            )),
            .z = geometry.blockCoord(player.position.z),
        });
        if (self.blocks.residentChunk(player.world, chunk) == null) {
            const prepared = self.prepareChunkData(slot, chunk) catch return false;
            if (prepared == .missing and !self.generateChunkData(slot, chunk))
                return false;
            if (self.blocks.residentChunk(player.world, chunk) == null) return false;
        }
        if (player.needs_spawn_position) {
            player.position.y = @floatFromInt(
                @as(i32, self.blocks.surfaceHeightAt(
                    player.world,
                    geometry.blockCoord(player.position.x),
                    geometry.blockCoord(player.position.z),
                )) + 1,
            );
            player.needs_spawn_position = false;
        }
        player.play_join_terrain_ready = true;
        return true;
    }
    pub fn playJoinTerrainReady(self: *const Host, slot: u16) bool {
        return self.players.records[slot].play_join_terrain_ready;
    }
    pub fn finishPendingPlayJoins(self: *Host) void {
        const storage = self.pending_play_join_storage orelse
            diagnostics.panic("tick host has no pending-play-join storage", &.{});
        const count = self.pending_play_join_count orelse
            diagnostics.panic("tick host has no pending-play-join count", &.{});
        var retained: usize = 0;
        for (storage[0..count.*]) |slot| {
            if (self.playBootstrapComplete(slot)) {
                self.activatePlaySlot(slot);
                continue;
            }
            storage[retained] = slot;
            retained += 1;
        }
        count.* = retained;
    }
    fn activatePlaySlot(self: *Host, slot: u16) void {
        const active = self.active_play_slot_storage orelse return;
        const count = self.active_play_slot_count orelse return;
        for (active[0..count.*]) |candidate|
            if (candidate == slot) return;
        if (count.* == active.len)
            diagnostics.panic("active play slot capacity exhausted", &.{});
        active[count.*] = slot;
        count.* += 1;
    }
    pub fn pendingPlayDisconnects(self: *const Host) []const PendingPlayDisconnect {
        const storage = self.pending_play_disconnect_storage orelse
            diagnostics.panic("tick host has no pending-play-disconnect storage", &.{});
        const count = self.pending_play_disconnect_count orelse
            diagnostics.panic("tick host has no pending-play-disconnect count", &.{});
        return storage[0..count.*];
    }
    pub fn finishPendingPlayDisconnects(self: *Host) void {
        const count = self.pending_play_disconnect_count orelse
            diagnostics.panic("tick host has no pending-play-disconnect count", &.{});
        count.* = 0;
    }
    pub fn playBootstrapComplete(self: *const Host, slot: u16) bool {
        return self.players.records[slot].play_bootstrap_complete;
    }
    pub fn markPlayBootstrapComplete(self: *Host, slot: u16) void {
        self.players.records[slot].play_bootstrap_complete = true;
    }
    pub fn completePlayKeepAlive(self: *Host, slot: u16, id: i64) void {
        const states = self.keep_alive_states orelse return;
        if (slot >= states.len or
            slot >= self.players.records.len or
            self.players.records[slot].state != .play)
            return;
        const state = &states[slot];
        const matched = state.awaiting_response and id == state.last_id;
        if (matched) {
            state.awaiting_response = false;
            const elapsed_ticks = self.clock.tick -% state.last_tick;
            const tick_ms = std.time.ms_per_s / config.ticks_per_second;
            state.latency_ms = @intCast(@min(
                elapsed_ticks *| tick_ms,
                @as(u64, std.math.maxInt(i32)),
            ));
            state.latency_dirty = true;
            return;
        }
        var storage: [192]u8 = undefined;
        const message = std.fmt.bufPrint(
            &storage,
            "warn(protocol): event=play_keep_alive_mismatch slot={} id={} expected={}\n",
            .{ slot, id, state.last_id },
        ) catch "warn(protocol): event=play_keep_alive_mismatch\n";
        self.logMessage(message);
    }
    pub fn keepAliveDue(self: *const Host, slot: u16, tick: u64) bool {
        const states = self.keep_alive_states orelse return false;
        if (slot >= states.len) return false;
        return tick -% states[slot].last_tick >= config.keep_alive_interval_ticks;
    }
    pub fn playerLatencyDirty(self: *const Host, slot: u16) bool {
        const states = self.keep_alive_states orelse return false;
        return slot < states.len and states[slot].latency_dirty;
    }
    pub fn finishPlayerLatency(self: *Host, slot: u16) void {
        const states = self.keep_alive_states orelse return;
        if (slot < states.len) states[slot].latency_dirty = false;
    }
    pub fn requestReload(self: *Host, slot: u16) void {
        const exchange = self.exchange orelse return;
        if (slot >= self.connection_handles.len) return;
        const connection = self.connection_handles[slot] orelse return;
        if (!exchange.appendRequestReload(connection))
            diagnostics.panic("tick command buffer exhausted while requesting reload", &.{});
    }
    pub fn claimReloadResult(self: *Host) ?ReloadResult {
        const storage = self.reload_result orelse return null;
        const result = storage.*;
        storage.* = null;
        return result;
    }
    pub fn logMessage(self: *Host, message: []const u8) void {
        const exchange = self.exchange orelse
            diagnostics.panic("reloadable log command requires a tick exchange", &.{});
        if (!exchange.appendLog(message))
            diagnostics.panic("tick command buffer exhausted while writing log message", &.{});
    }

    pub fn chunkStreamingEnabled(self: *const Host) bool {
        return self.chunk_streaming_enabled;
    }
    pub fn beginTerrainGenerationBatch(self: *Host) void {
        self.blocks.beginChunkGenerationBatch();
    }
    pub fn prunePlaySlots(_: *Host) void {}
    pub fn chunkViewCenter(self: *const Host, slot: u16) geometry.ChunkPos {
        return self.replication_state.clients[slot].chunks.center;
    }
    pub fn playerWorld(self: *const Host, slot: u16) world_identity.Handle {
        return self.players.records[slot].world;
    }
    pub fn recenterChunkView(self: *Host, slot: u16, pos: geometry.ChunkPos) void {
        const chunks = &self.replication_state.clients[slot].chunks;
        chunks.recenter(pos);
        self.requestItemSync(slot);
    }
    pub fn chunkOutputBackpressured(self: *const Host, slot: u16) bool {
        if (self.outputKernel(slot)) |output|
            return output.kernel.output_backpressured(
                output.kernel.context,
                output.handle,
            );
        const direct = self.direct_packet_api orelse return true;
        return direct.backpressured(direct.context, slot);
    }
    pub fn nextMissingChunk(self: *const Host, slot: u16, cursor: *usize) ?geometry.ChunkPos {
        return self.replication_state.clients[slot].chunks.nextMissingFrom(cursor);
    }
    pub fn beginChunkBatch(self: *Host, slot: u16) u16 {
        return self.replication_state.clients[slot].beginChunkBatch();
    }
    pub fn acknowledgeChunkBatch(self: *Host, slot: u16, chunks_per_tick: f32) void {
        self.replication_state.clients[slot].acknowledgeChunkBatch(chunks_per_tick);
    }
    pub fn chunkProjection(self: *const Host, slot: u16, pos: geometry.ChunkPos) view.ChunkProjection {
        return self.replication_state.clients[slot].view.chunkProjection(pos);
    }
    pub fn playerView(self: *const Host, slot: u16) *const view.PlayerView {
        return &self.replication_state.clients[slot].view;
    }
    pub fn queueChunkBatchStart(self: *Host, slot: u16) !void {
        return self.encodePacket(slot, "encodeChunkBatchStart", .{});
    }
    pub fn prepareChunkData(
        self: *Host,
        slot: u16,
        pos: geometry.ChunkPos,
    ) !ChunkDataPreparation {
        const world = self.players.records[slot].world;
        if (self.blocks.residentChunk(world, pos) != null) return .ready;
        if (self.exchange == null) return .missing;
        var path_storage: [config.max_resource_path_bytes]u8 = undefined;
        const path = self.chunkDataPath(&path_storage, world, pos) catch
            return error.ChunkLoadFailed;
        switch (self.io.read(path)) {
            .ready => |loaded| {
                chunk_storage.decode(
                    self.blocks,
                    world,
                    pos,
                    loaded,
                ) catch |err| switch (err) {
                    error.ResidentChunkCapacity,
                    error.WorldSectionCapacity,
                    => {
                        self.blocks.requestResidentEviction();
                        return error.ChunkLoadPending;
                    },
                    else => {
                        std.log.err(
                            "event=chunk_decode_failed chunk_x={} chunk_z={} error={s}",
                            .{ pos.x, pos.z, @errorName(err) },
                        );
                        return error.ChunkLoadFailed;
                    },
                };
                return .loaded;
            },
            .missing => return .missing,
            .pending => return error.ChunkLoadPending,
            .failed => return error.ChunkLoadFailed,
        }
    }

    pub fn generateChunkData(self: *Host, slot: u16, pos: geometry.ChunkPos) bool {
        const world = self.players.records[slot].world;
        if (!self.bulkWorkSupported()) {
            _ = self.blocks.generatedHeightChunkRef(
                world,
                pos,
                self.clock.tick,
            );
            return true;
        }
        self.blocks.requestChunkGeneration(world, pos);
        return false;
    }

    pub fn prefetchChunkData(
        self: *Host,
        slot: u16,
        maximum: usize,
    ) usize {
        if (self.exchange == null or self.chunkOutputBackpressured(slot))
            return 0;
        var iterator =
            self.replication_state.clients[slot].chunks.missingIterator();
        var admitted: usize = 0;
        for (0..view_chunk_count) |_| {
            if (admitted == maximum) break;
            const pos = iterator.next() orelse break;
            const world = self.players.records[slot].world;
            if (self.blocks.residentChunk(world, pos) != null or
                self.blocks.chunkDirty(world, pos))
                continue;
            var path_storage: [config.max_resource_path_bytes]u8 = undefined;
            const path = self.chunkDataPath(&path_storage, world, pos) catch continue;
            const status = self.io.prefetch(path);
            if (status == .backpressured) break;
            admitted += 1;
        }
        return admitted;
    }

    fn bulkWorkSupported(self: *const Host) bool {
        const exchange = self.exchange orelse return false;
        const kernel = exchange.kernel orelse return false;
        return kernel.capabilities &
            hot_reload_abi.KernelCapability.bulk_work != 0;
    }

    fn chunkDataPath(self: *const Host, buffer: []u8, world: world_identity.Handle, pos: geometry.ChunkPos) ![]const u8 {
        const key = (self.worlds.getConst(world) orelse return error.UnknownWorld).key;
        return std.fmt.bufPrint(buffer, "world/chunks/{x}/{d}_{d}.lrc", .{ key.value, pos.x, pos.z });
    }
    pub fn queueChunkPacket(
        self: *Host,
        slot: u16,
        pos: geometry.ChunkPos,
        lighting: *const light_projection.Chunk,
    ) !void {
        const reservation = try self.beginPacketCapacity(
            slot,
            chunk_packet.estimated_chunk_packet_len,
        );
        errdefer self.abortPacket(slot);
        const player_view =
            &self.replication_state.clients[slot].view;
        const world = self.players.records[slot].world;
        const resident =
            self.blocks.residentChunk(world, pos) orelse
            return error.ChunkLoadPending;
        const shape = &resident.shape;

        const prefix = try protocol_versions.staticCall(
            "encodeChunkPrefix",
            reservation.protocol_number,
            .{ reservation.bytes, pos.x, pos.z },
        );
        var rest = reservation.bytes[prefix.len..];
        rest = try chunk_packet.writeHeightmaps(rest, self.blocks, world, pos, shape);

        const count_offset =
            reservation.bytes.len - rest.len;
        const count_reserve = chunk_packet.chunk_data_count_reserve;
        if (rest.len < count_reserve) return error.EndOfStream;
        rest = rest[count_reserve..];
        const data_offset = reservation.bytes.len - rest.len;
        for (0..config.overworld_section_count) |section|
            rest = try chunk_packet.writeChunkSection(
                rest,
                self.blocks,
                world,
                player_view,
                pos,
                section,
                shape,
                reservation.protocol_number,
            );
        const data_end = reservation.bytes.len - rest.len;
        const data_len = data_end - data_offset;
        var count_bytes: [count_reserve]u8 = undefined;
        const count_rest = try protocol_support.write_count(
            &count_bytes,
            i32,
            data_len,
        );
        const count_len = count_bytes.len - count_rest.len;
        @memcpy(
            reservation.bytes[count_offset..][0..count_len],
            count_bytes[0..count_len],
        );
        if (count_len != count_reserve)
            std.mem.copyForwards(
                u8,
                reservation.bytes[count_offset + count_len ..][0..data_len],
                reservation.bytes[data_offset..data_end],
            );
        rest = reservation.bytes[count_offset + count_len + data_len ..];
        rest = try chunk_packet.writeChunkBlockEntities(
            rest,
            self.blocks,
            world,
            pos,
        );
        rest = try chunk_packet.writeChunkLight(rest, lighting);
        return self.finishPacket(slot, reservation, rest);
    }
    pub fn markChunkSent(self: *Host, slot: u16, pos: geometry.ChunkPos) void {
        self.replication_state.clients[slot].chunks.mark(pos);
        self.requestItemSync(slot);
    }
    pub fn releaseStreamedChunk(self: *Host, slot: u16, pos: geometry.ChunkPos) ?u16 {
        return self.blocks.releaseStreamedChunk(self.players.records[slot].world, pos);
    }
    pub fn chunkStreamCursor(self: *const Host) usize {
        return self.chunk_stream_cursor.*;
    }
    pub fn advanceChunkStreamCursor(self: *Host) void {
        const slots = self.activePlaySlots();
        if (slots.len != 0)
            self.chunk_stream_cursor.* = (self.chunk_stream_cursor.* + 1) % slots.len;
    }
    pub fn queue_update_light(self: *Host, slot: u16, update: light_projection.Update) !void {
        return self.encodePacketCapacity(
            slot,
            chunk_packet.lightPacketCapacity(update),
            "encodeUpdateLight",
            .{update},
        );
    }
    pub fn queueChunkBatchFinished(self: *Host, slot: u16, count: u16) !void {
        return self.encodePacket(slot, "encodeChunkBatchFinished", .{@as(i32, count)});
    }
    pub fn finishChunkBatch(self: *Host, slot: u16, count: u16) void {
        self.replication_state.clients[slot].finishChunkBatch(count);
    }

    pub fn resetClientWorldView(self: *Host, slot: u16, position: geometry.Vec3) geometry.ChunkPos {
        const center = chunkForPosition(position);
        self.replication_state.reset(slot);
        self.replication_state.clients[slot].chunks.reset(center);
        return center;
    }
    pub fn canSeePosition(
        self: *const Host,
        slot: u16,
        world: world_identity.Handle,
        position: geometry.Vec3,
    ) bool {
        if (!self.players.records[slot].world.eql(world)) return false;
        if (!self.chunkStreamingEnabled()) return true;
        const projection = &self.replication_state.clients[slot];
        const chunk = chunkForPosition(position);
        if (!chunk_stream.inView(chunk, projection.chunks.center) or
            !projection.chunks.has(chunk))
            return false;
        return true;
    }
    pub fn hasSentChunkAtPosition(
        self: *const Host,
        slot: u16,
        world: world_identity.Handle,
        position: geometry.Vec3,
    ) bool {
        if (!self.chunkStreamingEnabled()) return self.canSeePosition(slot, world, position);
        return self.replication_state.clients[slot].chunks.delivered(
            chunkForPosition(position),
        ) and self.canSeePosition(slot, world, position);
    }

    pub fn hasSentChunk(self: *const Host, slot: u16, chunk: geometry.ChunkPos) bool {
        if (!self.chunkStreamingEnabled()) return true;
        return self.replication_state.clients[slot].chunks.delivered(chunk);
    }
    pub fn canSeeBlock(self: *const Host, slot: u16, world: world_identity.Handle, pos: geometry.BlockPos) bool {
        if (!self.players.records[slot].world.eql(world)) return false;
        if (!self.chunkStreamingEnabled()) return true;
        const projection = &self.replication_state.clients[slot];
        const chunk = geometry.chunkForBlock(pos);
        if (!chunk_stream.inView(chunk, projection.chunks.center) or
            !projection.chunks.has(chunk))
            return false;
        return true;
    }
    pub fn canSeeBlockChange(self: *const Host, slot: u16, world: world_identity.Handle, pos: geometry.BlockPos) bool {
        if (!self.players.records[slot].world.eql(world)) return false;
        if (!self.chunkStreamingEnabled()) return true;
        const projection = &self.replication_state.clients[slot];
        const chunk = geometry.chunkForBlock(pos);
        if (!chunk_stream.inView(chunk, projection.chunks.center) or
            !projection.chunks.has(chunk))
            return false;
        return true;
    }
    pub fn visibleBlockChangeState(self: *const Host, slot: u16, _: world_identity.Handle, pos: geometry.BlockPos) i32 {
        return self.visibleBlockState(slot, pos);
    }
    pub fn visibleBlockState(self: *const Host, slot: u16, pos: geometry.BlockPos) i32 {
        const player_view = &self.replication_state.clients[slot].view;
        return player_view.blockAt(self.blocks, self.players.records[slot].world, pos);
    }
    pub fn claimArmSwing(self: *Host, slot: u16) bool {
        const player = &self.players.records[slot];
        const current_tick = self.clock.tick;
        if (player.last_arm_swing_tick == current_tick) return false;
        player.last_arm_swing_tick = current_tick;
        return true;
    }
    pub fn playerVisible(self: *const Host, target: u16, subject: u16) bool {
        return self.replication_state.clients[target].playerVisible(subject);
    }
    pub fn setPlayerVisible(self: *Host, target: u16, subject: u16, visible: bool) void {
        self.replication_state.clients[target].setPlayerVisible(subject, visible);
    }
    pub fn livingVisible(self: *const Host, slot: u16, index: u16) bool {
        const word = index >> 6;
        const mask = @as(u64, 1) << @intCast(index & 63);
        return self.replication_state.clients[slot].visible_living[word] & mask != 0;
    }
    pub fn setLivingVisible(self: *Host, slot: u16, index: u16, visible: bool) void {
        const word = index >> 6;
        const mask = @as(u64, 1) << @intCast(index & 63);
        if (visible)
            self.replication_state.clients[slot].visible_living[word] |= mask
        else
            self.replication_state.clients[slot].visible_living[word] &= ~mask;
    }
    pub fn itemVisible(self: *const Host, slot: u16, index: u16) bool {
        return self.replication_state.clients[slot].itemVisible(index);
    }
    pub fn setItemVisible(self: *Host, slot: u16, index: u16, visible: bool) void {
        self.replication_state.clients[slot].setItemVisible(index, visible);
    }
    pub fn itemMetadataPending(self: *const Host, slot: u16, index: u16) bool {
        return self.replication_state.clients[slot].itemMetadataPending(index);
    }
    pub fn setItemMetadataPending(self: *Host, slot: u16, index: u16, pending: bool) void {
        self.replication_state.clients[slot].setItemMetadataPending(index, pending);
    }
    pub fn nextVisibleItem(self: *const Host, slot: u16, first: u16) ?u16 {
        if (first >= config.max_item_entities) return null;
        const words = self.replication_state.clients[slot].visible_items;
        var word_index: usize = first >> 6;
        const first_bit: u6 = @intCast(first & 63);
        var word = words[word_index] &
            (@as(u64, std.math.maxInt(u64)) << first_bit);
        while (word_index < words.len) {
            if (word != 0) {
                const index = word_index * 64 + @ctz(word);
                return if (index < config.max_item_entities)
                    @intCast(index)
                else
                    null;
            }
            word_index += 1;
            if (word_index == words.len) break;
            word = words[word_index];
        }
        return null;
    }
    pub fn requestItemSync(self: *Host, slot: u16) void {
        self.replication_state.clients[slot].item_sync_pending = true;
    }
    pub fn claimItemSync(self: *Host, slot: u16) bool {
        const projection = &self.replication_state.clients[slot];
        const pending = projection.item_sync_pending;
        projection.item_sync_pending = false;
        return pending;
    }
    inline fn encodePacket(self: *Host, slot: u16, comptime operation: []const u8, arguments: anytype) !void {
        return self.encodePacketCapacity(slot, 1, operation, arguments);
    }

    inline fn encodePacketCapacity(
        self: *Host,
        slot: u16,
        minimum_bytes: usize,
        comptime operation: []const u8,
        arguments: anytype,
    ) !void {
        const reservation = try self.beginPacketCapacity(slot, minimum_bytes);
        errdefer self.abortPacket(slot);
        const body = try protocol_versions.staticCall(
            operation,
            reservation.protocol_number,
            .{reservation.bytes} ++ arguments,
        );
        try self.finishPacketBody(slot, reservation, body);
    }

    fn beginPacket(self: *Host, slot: u16) !PacketReservation {
        return self.beginPacketCapacity(slot, 1);
    }

    fn beginPacketCapacity(
        self: *Host,
        slot: u16,
        minimum_bytes: usize,
    ) !PacketReservation {
        if (self.outputKernel(slot)) |output| {
            const reservation = try tick_transport.begin(
                output.kernel,
                output.handle,
                minimum_bytes,
            );
            return .{
                .bytes = reservation.body,
                .protocol_number = reservation.lease.protocol_number,
                .transport = reservation,
            };
        }
        const direct = self.direct_packet_api orelse
            return error.OutputKernelUnavailable;
        return direct.begin(direct.context, slot, minimum_bytes);
    }

    fn abortPacket(self: *Host, slot: u16) void {
        if (self.outputKernel(slot)) |output| {
            output.kernel.cancel_output(output.kernel.context, output.handle.value());
            return;
        }
        const direct = self.direct_packet_api orelse return;
        direct.abort(direct.context, slot);
    }

    fn commitPacket(self: *Host, slot: u16, reservation: PacketReservation, body_len: usize) !void {
        if (self.outputKernel(slot)) |output| {
            return tick_transport.finish(
                output.kernel,
                reservation.transport orelse return error.InvalidOutputLease,
                body_len,
            );
        }
        const direct = self.direct_packet_api orelse return error.OutputKernelUnavailable;
        return direct.finish(direct.context, slot, body_len);
    }

    fn outputKernel(self: *const Host, slot: u16) ?struct {
        kernel: *const hot_reload_abi.KernelApi,
        handle: hot_reload_abi.ConnectionHandle,
    } {
        const exchange = self.exchange orelse return null;
        const kernel = exchange.kernel orelse return null;
        if (!kernel.header.supports(@sizeOf(hot_reload_abi.KernelApi)) or
            kernel.capabilities & hot_reload_abi.KernelCapability.output_leases == 0 or
            slot >= self.connection_handles.len)
            return null;
        const handle = self.connection_handles[slot] orelse return null;
        return .{ .kernel = kernel, .handle = handle };
    }

    fn finishPacketBody(self: *Host, slot: u16, reservation: PacketReservation, body: []u8) !void {
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(slot, reservation, body.len);
    }

    fn finishPacket(self: *Host, slot: u16, reservation: PacketReservation, rest: []u8) !void {
        const rest_address = @intFromPtr(rest.ptr);
        const start_address = @intFromPtr(reservation.bytes.ptr);
        if (rest_address < start_address or rest_address > start_address + reservation.bytes.len)
            return error.InvalidProtocolEncoderResult;
        try self.commitPacket(slot, reservation, rest_address - start_address);
    }

    pub fn queue_play_login(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const world = self.worlds.getConst(player.world) orelse return error.UnknownWorld;
        const dimensions = self.worlds.dimensionRegistry() orelse return error.DimensionRegistryNotBound;
        const dimension_type = dimensions.protocolIndex(world.dimension) orelse return error.UnknownDimension;
        const world_names = [1][]const u8{world.nameSlice()};
        return self.encodePacket(slot, "encodePlayLogin", .{protocol_values.PlayLogin{
            .entity_id = player.entity_id,
            .world_names = &world_names,
            .dimension_type = dimension_type,
            .world_name = world.nameSlice(),
            .max_players = @intCast(self.runtime_maximum_players),
            .view_distance = config.view_distance_chunks,
            .simulation_distance = config.simulation_distance_chunks,
            .hashed_seed = @bitCast(world.seed),
            .gamemode = @intCast(@intFromEnum(player.gamemode)),
            .sea_level = world.spawn_y,
        }});
    }
    pub fn queue_declare_commands(self: *Host, slot: u16, declarations: []const commands.Declaration) !void {
        return self.encodePacket(slot, "encodeDeclareCommands", .{declarations});
    }
    pub fn queue_hotbar_slot(self: *Host, slot: u16, hotbar_slot: u4) !void {
        const player = &self.players.records[slot];
        const state_id = self.players.nextInventoryStateId(slot);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startSetSlot", reservation.protocol_number, .{
            reservation.bytes, @as(i32, 0), state_id, @as(i16, 36) + @as(i16, hotbar_slot),
        });
        rest = try writeSlotPayload(rest, player.hotbar[hotbar_slot], reservation.protocol_number);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_player_inventory(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const state_id = self.players.nextInventoryStateId(slot);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startWindowItems", reservation.protocol_number, .{ reservation.bytes, @as(i32, 0), state_id });
        const tail = try play_encode.playerInventoryTail(
            rest,
            player,
            player.crafting_result,
            protocol_versions.staticItemMapping(reservation.protocol_number),
            protocol_versions.staticDamageComponentId(reservation.protocol_number),
        );
        rest = rest[tail.len..];
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_selected_hotbar_slot(self: *Host, slot: u16) !void {
        return self.encodePacket(slot, "encodeHeldItemSlot", .{@as(i32, self.players.records[slot].selected_hotbar_slot)});
    }
    pub fn queue_player_inventory_slot(self: *Host, slot: u16, inventory_slot: i32) !void {
        const player = &self.players.records[slot];
        const stack = if (inventory_slot >= 0 and inventory_slot < 9)
            player.hotbar[@intCast(inventory_slot)]
        else if (inventory_slot >= 9 and inventory_slot < 36)
            player.main_inventory[@intCast(inventory_slot - 9)]
        else
            return error.InvalidPlayerInventorySlot;
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startSetPlayerInventory", reservation.protocol_number, .{ reservation.bytes, inventory_slot });
        rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_player_screen_slot(self: *Host, slot: u16, screen_slot: i16) !void {
        const player = &self.players.records[slot];
        const stack = switch (screen_slot) {
            0 => player.crafting_result,
            1...4 => player.crafting_grid[@intCast(screen_slot - 1)],
            5...8 => player.armor[@intCast(screen_slot - 5)],
            9...35 => player.main_inventory[@intCast(screen_slot - 9)],
            36...44 => player.hotbar[@intCast(screen_slot - 36)],
            45 => player.offhand,
            else => return error.InvalidPlayerScreenSlot,
        };
        const state_id = self.players.nextInventoryStateId(slot);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startSetSlot", reservation.protocol_number, .{ reservation.bytes, @as(i32, 0), state_id, screen_slot });
        rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_open_crafting_table(self: *Host, slot: u16) !void {
        const container = &self.containers.open[slot];
        std.debug.assert(container.kind == .crafting_table);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startOpenWindow", reservation.protocol_number, .{ reservation.bytes, container.id, @as(i32, 12) });
        rest = try writeTextComponent(rest, "Crafting");
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_crafting_table_inventory(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const container = &self.containers.open[slot];
        std.debug.assert(container.kind == .crafting_table);
        const state_id = self.containers.nextStateId(self.players, slot);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startWindowItems", reservation.protocol_number, .{ reservation.bytes, container.id, state_id });
        rest = try protocol_support.write_count(rest, i32, 46);
        for (0..46) |inventory_slot| {
            const stack = switch (inventory_slot) {
                0 => container.crafting_result,
                1...9 => container.crafting_grid[inventory_slot - 1],
                10...36 => player.main_inventory[inventory_slot - 10],
                37...45 => player.hotbar[inventory_slot - 37],
                else => unreachable,
            };
            rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        }
        rest = try writeSlotPayload(rest, player.cursor_stack, reservation.protocol_number);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_open_container(self: *Host, slot: u16, title: []const u8) !void {
        const container = &self.containers.open[slot];
        std.debug.assert(container.kind == .chest or container.kind == .furnace);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startOpenWindow", reservation.protocol_number, .{ reservation.bytes, container.id, container.menu_type });
        rest = try writeTextComponent(rest, title);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_container_inventory(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const container = &self.containers.open[slot];
        std.debug.assert(container.kind == .chest or container.kind == .furnace);
        const state_id = self.containers.nextStateId(self.players, slot);
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startWindowItems", reservation.protocol_number, .{ reservation.bytes, container.id, state_id });
        const top_count: usize = container.top_slot_count;
        rest = try protocol_support.write_count(rest, i32, top_count + 36);
        for (container.top_slots[0..top_count]) |stack|
            rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        for (player.main_inventory) |stack|
            rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        for (player.hotbar) |stack|
            rest = try writeSlotPayload(rest, stack, reservation.protocol_number);
        rest = try writeSlotPayload(rest, player.cursor_stack, reservation.protocol_number);
        try self.finishPacket(slot, reservation, rest);
    }
    pub fn queue_container_property(self: *Host, slot: u16, property: i16, value: i16) !void {
        const container = &self.containers.open[slot];
        return self.encodePacket(slot, "encodeContainerProperty", .{ container.id, property, value });
    }
    pub fn queue_block_action(self: *Host, slot: u16, position: geometry.BlockPos, action: u8, parameter: u8, block_id: i32) !void {
        return self.encodePacket(slot, "encodeBlockAction", .{
            position.x,
            position.y,
            position.z,
            action,
            parameter,
            block_id,
        });
    }
    pub fn queue_close_window(self: *Host, slot: u16, window_id: i32) !void {
        return self.encodePacket(slot, "encodeCloseWindow", .{window_id});
    }
    pub fn queue_update_view_position(self: *Host, slot: u16, x: i32, z: i32) !void {
        return self.encodePacket(slot, "encodeUpdateViewPosition", .{ x, z });
    }
    pub fn queue_spawn_position(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const world = self.worlds.getConst(player.world) orelse return error.UnknownWorld;
        return self.encodePacket(slot, "encodeSpawnPosition", .{
            world.spawn_x,
            world.spawn_y,
            world.spawn_z,
            @as(f32, 0),
        });
    }
    pub fn queue_start_waiting_for_chunks(self: *Host, slot: u16) !void {
        return self.encodePacket(slot, "encodeGameStateChange", .{ @as(u8, 13), @as(f32, 0) });
    }
    pub fn queue_gamemode_change(self: *Host, slot: u16, mode: player_store.GameMode) !void {
        return self.encodePacket(slot, "encodeGameStateChange", .{ @as(u8, 3), @as(f32, @floatFromInt(@intFromEnum(mode))) });
    }
    pub fn queue_player_abilities(self: *Host, slot: u16, mode: player_store.GameMode) !void {
        const flags: i8 = switch (mode) {
            .survival, .adventure => 0,
            .creative => 0x0d,
            .spectator => 0x0f,
        };
        return self.encodePacket(slot, "encodeAbilities", .{ flags, @as(f32, 0.05), @as(f32, 0.1) });
    }
    pub fn queue_player_combat_attributes(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const held = self.players.selectedHotbarStack(slot);
        return self.encodePacket(slot, "encodeCombatAttributes", .{
            player.entity_id,
            game_data.playerAttackDamage(held.item_id),
            game_data.playerAttackSpeed(held.item_id),
        });
    }
    pub fn queue_player_position(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        return self.encodePacket(slot, "encodePlayerPosition", .{protocol_values.PlayerPosition{
            .teleport_id = 1,
            .x = player.position.x,
            .y = player.position.y,
            .z = player.position.z,
            .velocity_x = 0,
            .velocity_y = 0,
            .velocity_z = 0,
            .yaw = player.rotation.yaw,
            .pitch = player.rotation.pitch,
        }});
    }
    pub fn queue_player_info_add(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        return self.encodePacket(target, "encodePlayerInfoAdd", .{
            player.uuid,
            player.name_slice(),
            @as(i32, @intFromEnum(player.gamemode)),
        });
    }
    pub fn queue_player_info_add_batch(self: *Host, target: u16, subjects: []const u16) !void {
        if (subjects.len == 0 or subjects.len > config.max_players)
            return error.InvalidPlayerInfoBatch;
        var entries: [config.max_players]protocol_values.PlayerInfo = undefined;
        for (subjects, 0..) |subject, index| {
            if (subject >= self.players.records.len) return error.InvalidPlayerSlot;
            const player = &self.players.records[subject];
            entries[index] = .{
                .uuid = player.uuid,
                .name = player.name_slice(),
                .gamemode = @intFromEnum(player.gamemode),
            };
        }
        return self.encodePacket(
            target,
            "encodePlayerInfoAddBatch",
            .{entries[0..subjects.len]},
        );
    }
    pub fn queue_player_info_gamemode(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        return self.encodePacket(target, "encodePlayerInfoGamemode", .{
            player.uuid,
            @as(i32, @intFromEnum(player.gamemode)),
        });
    }
    pub fn queue_player_info_latency(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        const states = self.keep_alive_states orelse return error.MissingKeepAliveState;
        if (subject >= states.len) return error.InvalidPlayerSlot;
        return self.encodePacket(target, "encodePlayerInfoLatency", .{
            player.uuid,
            states[subject].latency_ms,
        });
    }
    pub fn queue_player_remove(self: *Host, target: u16, uuid: u128) !void {
        return self.encodePacket(target, "encodePlayerRemove", .{uuid});
    }
    pub fn queue_spawn_player_entity(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        const entity_type = try protocol_versions.staticWireEntity(reservation.protocol_number, registry_data.entity_player_type_id);
        const body = try protocol_versions.staticCall("encodeSpawnEntity", reservation.protocol_number, .{ reservation.bytes, protocol_values.SpawnEntity{
            .entity_id = player.entity_id,
            .uuid = player.uuid,
            .entity_type = entity_type,
            .x = player.position.x,
            .y = player.position.y,
            .z = player.position.z,
            .pitch = play_encode.angleByte(player.rotation.pitch),
            .yaw = play_encode.angleByte(player.rotation.yaw),
            .head_yaw = play_encode.angleByte(player.rotation.yaw),
            .data = 0,
            .velocity_x = 0,
            .velocity_y = 0,
            .velocity_z = 0,
        } });
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(target, reservation, body.len);
    }
    pub fn queue_player_entity_position(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        return self.encodePacket(target, "encodeSyncEntityPosition", .{
            player.entity_id,
            player.position.x,
            player.position.y,
            player.position.z,
            @as(f64, 0),
            @as(f64, 0),
            @as(f64, 0),
            player.rotation.yaw,
            player.rotation.pitch,
            player.on_ground,
        });
    }
    pub fn queue_entity_equipment(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        var rest = try protocol_versions.staticCall("startEntityEquipment", reservation.protocol_number, .{ reservation.bytes, player.entity_id });
        rest = try writeSingleEquipment(rest, 0, self.players.selectedHotbarStack(subject), reservation.protocol_number);
        try self.finishPacket(target, reservation, rest);
    }
    pub fn queue_player_state_metadata(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        {
            const reservation = try self.beginPacket(target);
            errdefer self.abortPacket(target);
            var rest = try protocol_versions.staticCall("startEntityMetadata", reservation.protocol_number, .{ reservation.bytes, player.entity_id });
            rest = try play_encode.playerFlagsMetadata(rest, player.sneaking, player.sprinting);
            try self.finishPacket(target, reservation, rest);
        }
        {
            const reservation = try self.beginPacket(target);
            errdefer self.abortPacket(target);
            var rest = try protocol_versions.staticCall("startEntityMetadata", reservation.protocol_number, .{ reservation.bytes, player.entity_id });
            rest = try play_encode.playerPoseMetadata(rest, player.sneaking);
            try self.finishPacket(target, reservation, rest);
        }
    }
    pub fn queue_keep_alive(self: *Host, slot: u16) !void {
        const tick = self.clock.tick;
        const id: i64 = @bitCast(config.seed ^ (@as(u64, slot) << 48) ^ tick);
        try self.encodePacket(slot, "encodeKeepAlive", .{id});
        const states = self.keep_alive_states orelse return;
        if (slot >= states.len) return;
        states[slot].last_tick = tick;
        states[slot].last_id = id;
        states[slot].awaiting_response = true;
    }
    pub fn queue_block_change(self: *Host, slot: u16, x: i32, z: i32, y: i16, state: i32) !void {
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        const wire_state = try protocol_versions.staticWireBlockState(reservation.protocol_number, state);
        const body = try protocol_versions.staticCall("encodeBlockChange", reservation.protocol_number, .{ reservation.bytes, x, y, z, wire_state });
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(slot, reservation, body.len);
    }
    pub fn queue_acknowledge_player_digging(self: *Host, slot: u16, sequence: i32) !void {
        return self.encodePacket(slot, "encodeAcknowledgeSequence", .{sequence});
    }
    pub fn queue_block_break_animation(self: *Host, slot: u16, entity: i32, pos: geometry.BlockPos, stage: i8) !void {
        return self.encodePacket(slot, "encodeBlockBreakAnimation", .{ entity, pos.x, pos.y, pos.z, stage });
    }
    pub fn queue_arm_swing(self: *Host, slot: u16, entity: i32, hand: i32) !void {
        return self.encodePacket(slot, "encodeArmSwing", .{ entity, hand });
    }
    pub fn queue_hurt_animation(self: *Host, slot: u16, entity: i32, yaw: f32) !void {
        return self.encodePacket(slot, "encodeHurtAnimation", .{ entity, yaw });
    }
    pub fn queue_player_attack_damage(self: *Host, slot: u16, entity: i32, attacker: i32) !void {
        return self.encodePacket(slot, "encodeDamageEvent", .{ entity, @as(i32, 34), attacker + 1, attacker + 1 });
    }
    pub fn queue_mob_attack_damage(self: *Host, slot: u16, entity: i32, attacker: i32) !void {
        return self.encodePacket(slot, "encodeDamageEvent", .{ entity, @as(i32, 27), attacker + 1, attacker + 1 });
    }
    pub fn queue_on_fire_damage(self: *Host, slot: u16, entity: i32) !void {
        return self.encodePacket(slot, "encodeDamageEvent", .{ entity, @as(i32, 30), @as(i32, 0), @as(i32, 0) });
    }
    pub fn queue_fall_damage(self: *Host, slot: u16, entity: i32) !void {
        return self.encodePacket(slot, "encodeDamageEvent", .{ entity, @as(i32, 10), @as(i32, 0), @as(i32, 0) });
    }
    pub fn queue_player_death(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        var message_buffer: [64]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "{s} was slain by Zombie", .{player.name_slice()});
        return self.encodePacket(target, "encodeDeathCombatEvent", .{ player.entity_id, message });
    }
    pub fn queue_player_pvp_death(self: *Host, target: u16, subject: u16, attacker: u16) !void {
        const player = &self.players.records[subject];
        const attacking_player = &self.players.records[attacker];
        var message_buffer: [96]u8 = undefined;
        const message = try std.fmt.bufPrint(
            &message_buffer,
            "{s} was slain by {s}",
            .{ player.name_slice(), attacking_player.name_slice() },
        );
        return self.encodePacket(target, "encodeDeathCombatEvent", .{ player.entity_id, message });
    }
    pub fn queue_player_fall_death(self: *Host, target: u16, subject: u16) !void {
        const player = &self.players.records[subject];
        var message_buffer: [64]u8 = undefined;
        const message = try std.fmt.bufPrint(&message_buffer, "{s} fell from a high place", .{player.name_slice()});
        return self.encodePacket(target, "encodeDeathCombatEvent", .{ player.entity_id, message });
    }
    pub fn queue_entity_status(self: *Host, slot: u16, entity: i32, status: i8) !void {
        return self.encodePacket(slot, "encodeEntityStatus", .{ entity, status });
    }
    pub fn queue_sound_effect(self: *Host, slot: u16, sound: protocol_values.Sound, position: geometry.Vec3, volume: f32, pitch: f32, seed: i64) !void {
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        const sound_id = protocol_versions.staticWireSound(reservation.protocol_number, sound);
        const body = try protocol_versions.staticCall("encodeSoundEffect", reservation.protocol_number, .{
            reservation.bytes,
            sound_id,
            @as(i32, @intFromFloat(@floor(position.x * 8))),
            @as(i32, @intFromFloat(@floor(position.y * 8))),
            @as(i32, @intFromFloat(@floor(position.z * 8))),
            volume,
            pitch,
            seed,
        });
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(slot, reservation, body.len);
    }
    pub fn queue_collect_item(self: *Host, slot: u16, entity: i32, collector: i32, count: u8) !void {
        return self.encodePacket(slot, "encodeCollectItem", .{ entity, collector, @as(i32, count) });
    }
    pub fn queue_update_health(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        return self.encodePacket(slot, "encodeUpdateHealth", .{ player.health, player.food, player.saturation });
    }
    pub fn queue_update_time(self: *Host, slot: u16) !void {
        return self.encodePacket(slot, "encodeUpdateTime", .{
            @as(i64, @bitCast(self.clock.tick)),
            @as(i64, @bitCast(self.time.day_time)),
            self.rules.do_daylight_cycle,
        });
    }
    pub fn queue_spawn_item_entity(self: *Host, target: u16, index: usize) !void {
        const entity = self.items.value(index);
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        const entity_type = try protocol_versions.staticWireEntity(reservation.protocol_number, registry_data.entity_item_type_id);
        const body = try protocol_versions.staticCall("encodeSpawnEntity", reservation.protocol_number, .{ reservation.bytes, protocol_values.SpawnEntity{
            .entity_id = entity.entity_id,
            .uuid = entity.uuid,
            .entity_type = entity_type,
            .x = entity.position.x,
            .y = entity.position.y,
            .z = entity.position.z,
            .pitch = 0,
            .yaw = 0,
            .head_yaw = 0,
            .data = 0,
            .velocity_x = play_encode.entityVelocity(entity.velocity.x),
            .velocity_y = play_encode.entityVelocity(entity.velocity.y),
            .velocity_z = play_encode.entityVelocity(entity.velocity.z),
        } });
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(target, reservation, body.len);
    }
    pub fn queue_item_entity_position_sync(self: *Host, target: u16, index: usize) !void {
        const entity = self.items.value(index);
        return self.encodePacket(target, "encodeSyncEntityPosition", .{
            entity.entity_id,
            entity.position.x,
            entity.position.y,
            entity.position.z,
            entity.velocity.x,
            entity.velocity.y,
            entity.velocity.z,
            @as(f32, 0),
            @as(f32, 0),
            entity.on_ground,
        });
    }
    pub fn queue_item_entity_metadata(self: *Host, target: u16, index: usize) !void {
        const entity = self.items.value(index);
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        var rest = try protocol_versions.staticCall("startEntityMetadata", reservation.protocol_number, .{ reservation.bytes, entity.entity_id });
        rest = try writeItemEntityMetadata(rest, entity.stack, reservation.protocol_number);
        try self.finishPacket(target, reservation, rest);
    }
    pub fn queue_living_equipment(self: *Host, target: u16, index: u16, equipment: u8) !void {
        const equipped = self.living.entities.equipment[index][equipment];
        const stack = player_store.HotbarStack{ .item_id = equipped.item_id, .damage = equipped.damage, .count = equipped.count };
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        var rest = try protocol_versions.staticCall("startEntityEquipment", reservation.protocol_number, .{ reservation.bytes, self.living.entities.entity_ids[index] });
        rest = try writeSingleEquipment(rest, equipment, stack, reservation.protocol_number);
        try self.finishPacket(target, reservation, rest);
    }
    pub fn queue_spawn_living_entity(self: *Host, target: u16, index: u16) !void {
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        const entity_type = try protocol_versions.staticWireEntity(reservation.protocol_number, entity_store.livingEntityCanonicalTypeId(self.living.entities.entity_types[index]));
        const body = try protocol_versions.staticCall("encodeSpawnEntity", reservation.protocol_number, .{ reservation.bytes, protocol_values.SpawnEntity{
            .entity_id = self.living.entities.entity_ids[index],
            .uuid = self.living.entities.uuids[index],
            .entity_type = entity_type,
            .x = self.living.entities.position_x[index],
            .y = self.living.entities.position_y[index],
            .z = self.living.entities.position_z[index],
            .pitch = play_encode.entityAngle(self.living.entities.pitch[index]),
            .yaw = play_encode.entityAngle(self.living.entities.yaw[index]),
            .head_yaw = play_encode.entityAngle(self.living.entities.head_yaw[index]),
            .data = 0,
            .velocity_x = play_encode.entityVelocity(self.living.entities.velocity_x[index]),
            .velocity_y = play_encode.entityVelocity(self.living.entities.velocity_y[index]),
            .velocity_z = play_encode.entityVelocity(self.living.entities.velocity_z[index]),
        } });
        if (body.ptr != reservation.bytes.ptr) return error.InvalidProtocolEncoderResult;
        try self.commitPacket(target, reservation, body.len);
    }
    pub fn queue_living_entity_position(self: *Host, target: u16, index: u16) !void {
        return self.encodePacket(target, "encodeSyncEntityPosition", .{
            self.living.entities.entity_ids[index],
            self.living.entities.position_x[index],
            self.living.entities.position_y[index],
            self.living.entities.position_z[index],
            self.living.entities.velocity_x[index],
            self.living.entities.velocity_y[index],
            self.living.entities.velocity_z[index],
            self.living.entities.yaw[index],
            self.living.entities.pitch[index],
            self.living.entities.on_ground[index],
        });
    }
    pub fn queue_living_entity_metadata(self: *Host, target: u16, index: u16) !void {
        const reservation = try self.beginPacket(target);
        errdefer self.abortPacket(target);
        var rest = try protocol_versions.staticCall("startEntityMetadata", reservation.protocol_number, .{ reservation.bytes, self.living.entities.entity_ids[index] });
        rest = try protocol_support.write_u8(rest, 0);
        rest = try protocol_support.write_varint(rest, 0);
        rest = try protocol_support.write_i8(rest, if (self.living.entities.fire_ticks[index] > 0) 0x01 else 0);
        rest = try protocol_support.write_u8(rest, 9);
        rest = try protocol_support.write_varint(rest, 3);
        rest = try protocol_support.write_f32(rest, self.living.entities.health[index]);
        rest = try protocol_support.write_u8(rest, 15);
        rest = try protocol_support.write_varint(rest, 0);
        rest = try protocol_support.write_i8(rest, if (self.living.entities.attacking[index]) 0x04 else 0);
        rest = try protocol_support.write_u8(rest, 16);
        rest = try protocol_support.write_varint(rest, 8);
        rest = try protocol_support.write_bool(rest, self.living.entities.baby[index]);
        rest = try protocol_support.write_u8(rest, 0xff);
        try self.finishPacket(target, reservation, rest);
    }
    pub fn queue_entity_destroy(self: *Host, target: u16, entity: i32) !void {
        return self.encodePacket(target, "encodeEntityDestroy", .{entity});
    }
    pub fn queue_entity_move_look(self: *Host, target: u16, moving: u16, previous: input_store.PreviousMovement) !void {
        const player = &self.players.records[moving];
        return self.encodePacket(target, "encodeEntityMoveLook", .{
            player.entity_id,
            play_encode.relativeMoveDelta(previous.position.x, player.position.x),
            play_encode.relativeMoveDelta(previous.position.y, player.position.y),
            play_encode.relativeMoveDelta(previous.position.z, player.position.z),
            play_encode.angleByte(player.rotation.yaw),
            play_encode.angleByte(player.rotation.pitch),
            player.on_ground,
        });
    }
    pub fn queue_entity_head_rotation(self: *Host, target: u16, moving: u16) !void {
        const player = &self.players.records[moving];
        return self.encodePacket(target, "encodeEntityHeadRotation", .{ player.entity_id, play_encode.angleByte(player.rotation.yaw) });
    }
    pub fn queue_living_entity_head_rotation(self: *Host, target: u16, index: u16) !void {
        return self.encodePacket(target, "encodeEntityHeadRotation", .{
            self.living.entities.entity_ids[index],
            play_encode.entityAngle(self.living.entities.head_yaw[index]),
        });
    }
    pub fn queue_living_entity_velocity(self: *Host, target: u16, index: u16) !void {
        return self.queue_living_entity_velocity_values(
            target,
            index,
            self.living.entities.velocity_x[index],
            self.living.entities.velocity_y[index],
            self.living.entities.velocity_z[index],
        );
    }
    pub fn queue_living_entity_velocity_values(self: *Host, target: u16, index: u16, x: f64, y: f64, z: f64) !void {
        return self.encodePacket(target, "encodeEntityVelocity", .{
            self.living.entities.entity_ids[index],
            play_encode.entityVelocity(x),
            play_encode.entityVelocity(y),
            play_encode.entityVelocity(z),
        });
    }
    pub fn queue_player_velocity_values(self: *Host, target: u16, subject: u16, x: f64, y: f64, z: f64) !void {
        return self.encodePacket(target, "encodeEntityVelocity", .{
            self.players.records[subject].entity_id,
            play_encode.entityVelocity(x),
            play_encode.entityVelocity(y),
            play_encode.entityVelocity(z),
        });
    }
    pub fn queue_respawn(self: *Host, slot: u16) !void {
        const player = &self.players.records[slot];
        const world = self.worlds.getConst(player.world) orelse return error.UnknownWorld;
        const dimensions = self.worlds.dimensionRegistry() orelse return error.DimensionRegistryNotBound;
        const dimension_type = dimensions.protocolIndex(world.dimension) orelse return error.UnknownDimension;
        return self.encodePacket(slot, "encodeRespawn", .{protocol_values.Respawn{
            .dimension_type = dimension_type,
            .world_name = world.nameSlice(),
            .hashed_seed = @bitCast(world.seed),
            .gamemode = @intCast(@intFromEnum(player.gamemode)),
            .sea_level = world.spawn_y,
        }});
    }

    const SystemChatPacket = struct {
        reservation: PacketReservation,
        rest: []u8,
    };

    fn beginSystemChat(self: *Host, slot: u16, text_len: usize) !SystemChatPacket {
        if (text_len > config.max_chat_component_bytes or text_len > std.math.maxInt(u16))
            return error.TextComponentTooLong;
        const reservation = try self.beginPacket(slot);
        errdefer self.abortPacket(slot);
        var rest = try protocol_versions.staticCall("startSystemChat", reservation.protocol_number, .{reservation.bytes});
        rest = try protocol_support.write_u8(rest, 10);
        rest = try protocol_support.write_u8(rest, 8);
        rest = try protocol_support.write_u16(rest, 4);
        rest = try protocol_support.write_bytes(rest, "text");
        rest = try protocol_support.write_u16(rest, @intCast(text_len));
        return .{ .reservation = reservation, .rest = rest };
    }

    fn finishSystemChat(self: *Host, slot: u16, packet: SystemChatPacket, text_len: usize) !void {
        var rest = packet.rest[text_len..];
        rest = try protocol_support.write_u8(rest, 0);
        rest = try protocol_support.write_bool(rest, false);
        try self.finishPacket(slot, packet.reservation, rest);
    }

    pub fn queue_system_chat_text(self: *Host, slot: u16, text: []const u8) !void {
        const packet = try self.beginSystemChat(slot, text.len);
        errdefer self.abortPacket(slot);
        @memcpy(packet.rest[0..text.len], text);
        try self.finishSystemChat(slot, packet, text.len);
    }

    pub fn queue_system_chat_format(self: *Host, slot: u16, comptime format: []const u8, args: anytype) !void {
        if (comptime @typeInfo(@TypeOf(args)).@"struct".fields.len == 0) {
            _ = comptime std.fmt.count(format, args);
            return self.queue_system_chat_text(slot, format);
        }
        const text_len = std.fmt.count(format, args);
        const packet = try self.beginSystemChat(slot, text_len);
        errdefer self.abortPacket(slot);
        const formatted = try std.fmt.bufPrint(packet.rest[0..text_len], format, args);
        std.debug.assert(formatted.len == text_len);
        try self.finishSystemChat(slot, packet, text_len);
    }
};

fn writeSlotPayload(buffer: []u8, stack: player_store.HotbarStack, protocol_number: i32) ![]u8 {
    var rest = try protocol_support.write_varint(buffer, if (stack.isEmpty()) 0 else @as(i32, stack.count));
    if (!stack.isEmpty()) {
        rest = try protocol_support.write_varint(rest, try protocol_versions.staticWireItem(protocol_number, stack.item_id));
        rest = try protocol_support.write_varint(rest, @intFromBool(stack.damage != 0));
        rest = try protocol_support.write_varint(rest, 0);
        if (stack.damage != 0) {
            rest = try protocol_support.write_varint(rest, protocol_versions.staticDamageComponentId(protocol_number));
            rest = try protocol_support.write_varint(rest, stack.damage);
        }
    }
    return rest;
}

fn writeSingleEquipment(buffer: []u8, equipment_slot: u8, stack: player_store.HotbarStack, protocol_number: i32) ![]u8 {
    const rest = try protocol_support.write_i8(buffer, @intCast(equipment_slot));
    return writeSlotPayload(rest, stack, protocol_number);
}

fn writeItemEntityMetadata(buffer: []u8, stack: player_store.HotbarStack, protocol_number: i32) ![]u8 {
    var rest = try protocol_support.write_u8(buffer, 8);
    rest = try protocol_support.write_varint(rest, 7);
    rest = try writeSlotPayload(rest, stack, protocol_number);
    return protocol_support.write_u8(rest, 0xff);
}

fn writeTextComponent(buffer: []u8, value: []const u8) ![]u8 {
    if (value.len > std.math.maxInt(u16)) return error.TextComponentTooLong;
    var rest = try protocol_support.write_u8(buffer, 10);
    rest = try protocol_support.write_u8(rest, 8);
    rest = try protocol_support.write_u16(rest, 4);
    rest = try protocol_support.write_bytes(rest, "text");
    rest = try protocol_support.write_u16(rest, @intCast(value.len));
    rest = try protocol_support.write_bytes(rest, value);
    return protocol_support.write_u8(rest, 0);
}
