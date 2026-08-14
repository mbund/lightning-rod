const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const vanilla_time = lightning_rod.time;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const config = lightning_rod.config.value;
const preallocated = lightning_rod.preallocated;
const chunk_storage = lightning_rod.chunk_storage;
const persistence = @import("../vanilla_persistence_codec.zig");
const tick_io = lightning_rod.tick_io;
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;

pub const Identity = struct {
    pub const id = "lightning_rod:persistence";
};

const save_batch_capacity = 64;
const save_completion_round_limit = 3;

const PendingChunk = struct {
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    revision: u64,
};

const ChunkSaveProfile = struct {
    resident_scanned: usize = 0,
    dirty_chunks: usize = 0,
    batches: usize = 0,
    completion_rounds: usize = 0,
    encode_attempts: usize = 0,
    encoded_attempt_bytes: usize = 0,
    encode_ns: u64 = 0,
    submit_ns: u64 = 0,
    io_wait_ns: u64 = 0,
};

pub const Persistence = struct {
    pub const id = Identity.id;

    buffer: []u8 = &.{},
    metadata_loaded: bool = false,
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    living: *entity_store.LivingEntities,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
    io: *tick_io.TickIo,

    pub fn create(allocator: std.mem.Allocator, worlds: *world_store.Worlds, clock: *world_clock.Clock, time: *vanilla_time.Time, random: *world_random.Random, blocks: *block_store.Blocks, living: *entity_store.LivingEntities, players: *player_store.Players, items: *entity_store.ItemEntities, io: *tick_io.TickIo) !*Persistence {
        const self = try preallocated.create(Persistence, allocator);
        self.* = .{ .worlds = worlds, .clock = clock, .time = time, .random = random, .blocks = blocks, .living = living, .players = players, .items = items, .io = io };
        self.buffer = try preallocated.alloc(u8, allocator, config.max_file_resource_bytes);
        try ensureWorldDirectories(worlds, io.*);
        return self;
    }

    pub fn load(self: *Persistence) !void {
        const started_ns = monotonicNanoseconds();
        var persisted = self.persistedState();
        const stored = try self.io.readSync(config.world_metadata_path);
        const read_ns = monotonicNanoseconds();
        if (stored) |bytes|
            try persistence.decodeMetadataState(&persisted, bytes);
        const decoded_ns = monotonicNanoseconds();
        self.metadata_loaded = true;
        std.log.info(
            "event=persistence_load_profile metadata_bytes={} read_ms={d:.3} decode_ms={d:.3} total_ms={d:.3}",
            .{
                if (stored) |bytes| bytes.len else 0,
                milliseconds(read_ns -| started_ns),
                milliseconds(decoded_ns -| read_ns),
                milliseconds(decoded_ns -| started_ns),
            },
        );
    }

    pub fn save(self: *Persistence) !void {
        std.debug.assert(self.metadata_loaded);
        const started_ns = monotonicNanoseconds();
        var persisted = self.persistedState();
        try persisted.players.saveActive();
        const players_ns = monotonicNanoseconds();
        var chunks: ChunkSaveProfile = .{};
        try self.saveChunks(persisted.blocks, persisted.worlds, true, &chunks);
        const chunks_ns = monotonicNanoseconds();
        const length = persistence.metadataStateEncodedSize(&persisted);
        if (length > self.buffer.len) {
            std.log.err(
                "event=save_metadata_capacity required={} capacity={}",
                .{ length, self.buffer.len },
            );
            return error.ResourceWriteFailed;
        }
        const bytes = try persistence.encodeMetadataState(self.buffer[0..length], &persisted);
        const encoded_ns = monotonicNanoseconds();
        self.io.writeSync(config.world_metadata_path, bytes) catch |err| {
            std.log.err("event=save_metadata_write_failed error={s}", .{@errorName(err)});
            return error.ResourceWriteFailed;
        };
        const completed_ns = monotonicNanoseconds();
        logSaveProfile(
            chunks,
            length,
            players_ns -| started_ns,
            chunks_ns -| players_ns,
            encoded_ns -| chunks_ns,
            completed_ns -| encoded_ns,
            completed_ns -| started_ns,
        );
    }

    pub fn tick(self: *Persistence, _: std.mem.Allocator) void {
        if (self.blocks.residentPressure()) {
            var profile: ChunkSaveProfile = .{};
            self.saveChunks(self.blocks, self.worlds, true, &profile) catch |err| {
                std.log.err("event=resident_writeback_failed error={s}", .{@errorName(err)});
            };
        }
    }

    fn saveChunks(self: *Persistence, blocks: *block_store.Blocks, worlds: *world_store.Worlds, include_unknown: bool, profile: *ChunkSaveProfile) !void {
        var cursor: usize = 0;
        var pending: [save_batch_capacity]PendingChunk = undefined;
        const batch_limit = config.max_resident_chunks / save_batch_capacity + 1;
        for (0..batch_limit) |_| {
            if (cursor == blocks.resident_chunk_count) return;
            profile.batches += 1;
            try self.io.begin();
            const count = try stageChunkBatch(self, blocks, worlds, include_unknown, &cursor, &pending, profile);
            const wait_started_ns = monotonicNanoseconds();
            try self.io.finish();
            try self.io.synchronize();
            profile.io_wait_ns += monotonicNanoseconds() -| wait_started_ns;
            try finishDirtyChunkBatch(self, blocks, worlds, pending[0..count], profile);
        }
        return error.ResourceWriteFailed;
    }

    fn persistedState(self: *Persistence) persistence.PersistedState {
        return makePersistedState(self.worlds, self.clock, self.time, self.random, self.blocks, self.living, self.players, self.items);
    }
};

fn ensureWorldDirectories(worlds: *const world_store.Worlds, io: tick_io.TickIo) !void {
    var path_storage: [config.max_resource_path_bytes]u8 = undefined;
    for (worlds.active()) |handle| {
        const key = worlds.getConst(handle).?.key;
        const path = try std.fmt.bufPrint(
            &path_storage,
            "world/chunks/{x}",
            .{key.value},
        );
        try io.ensureDirectory(path);
    }
}

fn makePersistedState(
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    living: *entity_store.LivingEntities,
    players: *player_store.Players,
    items: *entity_store.ItemEntities,
) persistence.PersistedState {
    return .{
        .worlds = worlds,
        .clock = clock,
        .time = time,
        .random = random,
        .blocks = blocks,
        .living = living,
        .players = players,
        .items = items,
    };
}

fn stageChunkBatch(
    state: *Persistence,
    blocks: *block_store.Blocks,
    worlds: *world_store.Worlds,
    include_unknown: bool,
    cursor: *usize,
    pending: *[save_batch_capacity]PendingChunk,
    profile: *ChunkSaveProfile,
) !usize {
    var count: usize = 0;
    while (cursor.* < blocks.resident_chunk_count and count < pending.len) {
        const index = blocks.active_resident_indices[cursor.*];
        cursor.* += 1;
        profile.resident_scanned += 1;
        const resident = &blocks.resident_chunks[index];
        if (!resident.valid) continue;
        const dirty = blocks.chunkDirty(resident.world, resident.chunk);
        if (!dirty and (!include_unknown or resident.persistence_known)) continue;
        profile.dirty_chunks += 1;
        const revision = blocks.chunkDirtyRevision(resident.world, resident.chunk);
        switch (writeChunk(state, blocks, worlds, resident.world, resident.chunk, state.io.*, profile)) {
            .complete => blocks.markChunkCleanThrough(resident.world, resident.chunk, revision),
            .pending => {
                pending[count] = .{
                    .world = resident.world,
                    .chunk = resident.chunk,
                    .revision = revision,
                };
                count += 1;
            },
            .failed => return error.ResourceWriteFailed,
        }
    }
    return count;
}

fn finishDirtyChunkBatch(
    state: *Persistence,
    blocks: *block_store.Blocks,
    worlds: *world_store.Worlds,
    pending: []PendingChunk,
    profile: *ChunkSaveProfile,
) !void {
    var remaining = pending.len;
    for (0..save_completion_round_limit) |_| {
        profile.completion_rounds += 1;
        var next: usize = 0;
        for (pending[0..remaining]) |chunk| {
            switch (pollChunkWrite(state, blocks, worlds, chunk, profile)) {
                .complete => blocks.markChunkCleanThrough(
                    chunk.world,
                    chunk.chunk,
                    chunk.revision,
                ),
                .pending => {
                    pending[next] = chunk;
                    next += 1;
                },
                .failed => return error.ResourceWriteFailed,
            }
        }
        if (next == 0) return;
        remaining = next;
        const wait_started_ns = monotonicNanoseconds();
        try state.io.finish();
        try state.io.synchronize();
        profile.io_wait_ns += monotonicNanoseconds() -| wait_started_ns;
    }
    std.log.err("event=chunk_write_completion_stalled count={}", .{remaining});
    return error.ResourceWriteFailed;
}

fn pollChunkWrite(state: *Persistence, blocks: *block_store.Blocks, worlds: *world_store.Worlds, chunk: PendingChunk, profile: *ChunkSaveProfile) tick_io.WriteResult {
    var path_storage: [config.max_resource_path_bytes]u8 = undefined;
    const path = chunkPath(&path_storage, worlds, chunk.world, chunk.chunk) orelse
        return .failed;
    return switch (state.io.pollWrite(path)) {
        .complete => .complete,
        .pending => .pending,
        .failed => .failed,
        .not_started => writeChunk(
            state,
            blocks,
            worlds,
            chunk.world,
            chunk.chunk,
            state.io.*,
            profile,
        ),
    };
}

fn writeChunk(state: *Persistence, blocks: *block_store.Blocks, worlds: *world_store.Worlds, world: world_identity.Handle, chunk: geometry.ChunkPos, io: tick_io.TickIo, profile: *ChunkSaveProfile) tick_io.WriteResult {
    const encode_started_ns = monotonicNanoseconds();
    const encoded = chunk_storage.encode(state.buffer, blocks, world, chunk) catch |err| {
        std.log.err("event=chunk_encode_failed chunk_x={d} chunk_z={d} err={s}", .{ chunk.x, chunk.z, @errorName(err) });
        return .failed;
    };
    const encoded_ns = monotonicNanoseconds();
    profile.encode_attempts += 1;
    profile.encoded_attempt_bytes += encoded.len;
    profile.encode_ns += encoded_ns -| encode_started_ns;
    var path_storage: [config.max_resource_path_bytes]u8 = undefined;
    const path = chunkPath(&path_storage, worlds, world, chunk) orelse return .failed;
    const result = io.write(path, encoded);
    profile.submit_ns += monotonicNanoseconds() -| encoded_ns;
    if (result == .failed) std.log.err(
        "event=chunk_write_failed path={s} chunk_x={d} chunk_z={d}",
        .{ path, chunk.x, chunk.z },
    );
    return result;
}

fn chunkPath(storage: []u8, worlds: *world_store.Worlds, world: world_identity.Handle, chunk: geometry.ChunkPos) ?[]const u8 {
    const key = (worlds.get(world) orelse return null).key;
    return std.fmt.bufPrint(storage, "world/chunks/{x}/{d}_{d}.lrc", .{
        key.value,
        chunk.x,
        chunk.z,
    }) catch null;
}

fn logSaveProfile(chunks: ChunkSaveProfile, metadata_bytes: usize, players_ns: u64, chunks_ns: u64, metadata_encode_ns: u64, metadata_write_ns: u64, total_ns: u64) void {
    std.log.info(
        "event=persistence_save_profile resident_scanned={} dirty_chunks={} batches={} completion_rounds={} encode_attempts={} encoded_attempt_bytes={} metadata_bytes={} players_ms={d:.3} chunks_ms={d:.3} chunk_encode_ms={d:.3} chunk_submit_ms={d:.3} chunk_io_wait_ms={d:.3} metadata_encode_ms={d:.3} metadata_write_ms={d:.3} total_ms={d:.3}",
        .{
            chunks.resident_scanned,
            chunks.dirty_chunks,
            chunks.batches,
            chunks.completion_rounds,
            chunks.encode_attempts,
            chunks.encoded_attempt_bytes,
            metadata_bytes,
            milliseconds(players_ns),
            milliseconds(chunks_ns),
            milliseconds(chunks.encode_ns),
            milliseconds(chunks.submit_ns),
            milliseconds(chunks.io_wait_ns),
            milliseconds(metadata_encode_ns),
            milliseconds(metadata_write_ns),
            milliseconds(total_ns),
        },
    );
}

fn monotonicNanoseconds() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(now.nsec));
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}
