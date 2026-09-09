const std = @import("std");
const lightning_rod = @import("lightning_rod");
const chunk_key = lightning_rod.chunk_key;
const codec = @import("../vanilla_persistence_codec.zig");
const FatalError = lightning_rod.plugin_lifecycle.FatalError;

const metadata_root_key = "\x00";
const legacy_metadata_key = "state";
const metadata_record_key_bytes = 5;
const legacy_metadata_player_tag: u8 = 1;
const metadata_item_tag: u8 = 2;
const metadata_living_tag: u8 = 3;
const runtime_checkpoint_batch_ticks = 16;
const startup_scan_records = 32;
const startup_scan_cursor_bytes = @max(chunk_key.encoded_bytes, metadata_record_key_bytes);
const player_record_tag = 'p';
const player_name_tag = 'n';
const player_record_key_bytes = 1 + @sizeOf(u128);

const PageState = enum(u8) { free, reading, buffered, request_waiting };

const Page = struct {
    state: PageState = .free,
    world: lightning_rod.world_identity.Handle = lightning_rod.world_identity.invalid,
    chunk: lightning_rod.geometry.ChunkPos = .{ .x = 0, .z = 0 },
    request: lightning_rod.persistence.Request = lightning_rod.persistence.no_request,
    allocation_start: u16 = 0,
    allocation_count: u16 = 0,
    buffered_length: u32 = 0,
    stale: bool = false,
    streaming: bool = false,
};

const StagedChunk = struct {
    world: lightning_rod.world_identity.Handle,
    chunk: lightning_rod.geometry.ChunkPos,
    revision: u64,
};

const QueuedChunk = struct {
    world: lightning_rod.world_identity.Handle,
    chunk: lightning_rod.geometry.ChunkPos,
    revision: u64,
    offset: u32,
    length: u32,
};

fn metadataKey(tag: u8, ordinal: usize) ?[metadata_record_key_bytes]u8 {
    const index = std.math.cast(u32, ordinal) orelse return null;
    var key: [metadata_record_key_bytes]u8 = undefined;
    key[0] = tag;
    std.mem.writeInt(u32, key[1..], index, .little);
    return key;
}

fn metadataRecordKey(key: []const u8) ?u8 {
    if (key.len != metadata_record_key_bytes) return null;
    return switch (key[0]) {
        metadata_item_tag, metadata_living_tag => key[0],
        else => null,
    };
}

fn playerRecordKey(uuid: u128) [player_record_key_bytes]u8 {
    var key: [player_record_key_bytes]u8 = undefined;
    key[0] = player_record_tag;
    std.mem.writeInt(u128, key[1..], uuid, .big);
    return key;
}

fn playerNameKey(storage: *[player_record_key_bytes]u8, name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len + 1 > storage.len) return null;
    storage[0] = player_name_tag;
    @memcpy(storage[1 .. name.len + 1], name);
    return storage[0 .. name.len + 1];
}

pub const RequestResult = enum(u8) { resident, pending, submitted, backpressured };
pub const WriteError = FatalError || error{ ChunkMissing, InvalidMutation, MutationCapacity };

pub const Activity = struct {
    free: usize = 0,
    reading: usize = 0,
    request_waiting: usize = 0,
    generating: usize = 0,
    staged_chunks: usize = 0,
    dirty_chunks: usize = 0,
    staging: bool = false,
    checkpoint_pending: bool = false,
    read_hits: u64 = 0,
    read_misses: u64 = 0,
    generation_calls: u64 = 0,
    generation_nanoseconds: u64 = 0,
    generation_maximum_nanoseconds: u64 = 0,
    generated_chunks: u64 = 0,
    persisted_chunks: u64 = 0,
    derived_cache_misses: u64 = 0,
    projection_requests: u64 = 0,
    render_requests: u64 = 0,
    cold_requests: u64 = 0,
    transient_chunks: usize = 0,
    transient_capacity: usize = 0,
    emitted_shapes: u64 = 0,
    installed_shapes: u64 = 0,
    materialization_nanoseconds: u64 = 0,
    decode_nanoseconds: u64 = 0,
    encode_nanoseconds: u64 = 0,
    stage_nanoseconds: u64 = 0,
    queued_chunks: usize = 0,
    queued_bytes: usize = 0,
    exact_reads: u64 = 0,
    exact_loader_reads: u64 = 0,
    exact_read_nanoseconds: u64 = 0,
};

pub const DerivedChunkCodec = struct {
    context: *anyopaque,
    encode: *const fn (*anyopaque, lightning_rod.world_identity.Handle, lightning_rod.geometry.ChunkPos, []u8) ?[]u8,
    decode: *const fn (*anyopaque, lightning_rod.world_identity.Handle, lightning_rod.geometry.ChunkPos, []const u8) bool,
};

fn validateStoredChunkIndex(namespace: lightning_rod.persistence.Namespace) !void {
    var records: [startup_scan_records]lightning_rod.persistence.ScanRecord = undefined;
    var cursor: [startup_scan_cursor_bytes]u8 = undefined;
    var cursor_length: usize = 0;
    while (true) {
        const batch = namespace.scan(cursor[0..cursor_length], &records) catch return error.StorageReadFailed;
        if (batch.count == 0) {
            if (batch.more) return error.StorageReadFailed;
            return;
        }
        for (records[0..batch.count]) |record| try validateStoredChunkRecord(record);
        if (!batch.more) return;
        const last = records[batch.count - 1].key;
        if (last.len > cursor.len) return error.StorageCorrupt;
        @memcpy(cursor[0..last.len], last);
        cursor_length = last.len;
    }
}

fn validateStoredChunkRecord(record: lightning_rod.persistence.ScanRecord) !void {
    if (std.mem.eql(u8, record.key, legacy_metadata_key)) return error.StorageSchemaUnsupported;
    if (std.mem.eql(u8, record.key, metadata_root_key)) {
        if (record.value_bytes == 0 or record.value_bytes > codec.maximum_root_encoded_size) return error.StorageCorrupt;
        return;
    }
    if (record.key.len == metadata_record_key_bytes and record.key[0] == legacy_metadata_player_tag)
        return error.StorageSchemaUnsupported;
    if ((record.key.len == player_record_key_bytes and record.key[0] == player_record_tag) or
        (record.key.len >= 2 and record.key.len <= player_record_key_bytes and record.key[0] == player_name_tag))
    {
        if (record.value_bytes == 0 or record.value_bytes > codec.maximum_record_encoded_size) return error.StorageCorrupt;
        return;
    }
    if (metadataRecordKey(record.key)) |_| {
        if (record.value_bytes == 0 or record.value_bytes > codec.maximum_record_encoded_size) return error.StorageCorrupt;
        return;
    }
    _ = chunk_key.decode(record.key) catch return error.StorageCorrupt;
    if (record.value_bytes == 0 or record.value_bytes > lightning_rod.chunk_storage.encoded_size)
        return error.StorageCorrupt;
}

pub const Persistence = struct {
    pub const id = "minecraft:vanilla_persistence";
    pub const Configuration = struct {
        read_capacity: usize = 256,
        read_bytes: usize = 4 * 1024 * 1024,
        read_granularity: usize = 4 * 1024,
        read_budget_ns: u64 = 10 * std.time.ns_per_ms,
        staging_budget_ns: u64 = 8 * std.time.ns_per_ms,
        queue_chunks: usize = 2_048,
        queue_bytes: usize = 8 * 1024 * 1024,
    };
    pub const Dependencies = struct {
        access: lightning_rod.persistence.PluginAccess,
        worlds: *lightning_rod.worlds.Worlds,
        clock: *lightning_rod.clock.Clock,
        time: *lightning_rod.time.Time,
        random: *lightning_rod.random.Random,
        blocks: *lightning_rod.blocks.Blocks,
        living: *lightning_rod.entities.LivingEntities,
        players: *lightning_rod.players.Players,
        items: *lightning_rod.entities.ItemEntities,
        runtime_metrics: ?*lightning_rod.metrics.Runtime,
    };

    deps: Dependencies,
    configuration: Configuration,
    metadata_root: [codec.maximum_root_encoded_size]u8 = undefined,
    metadata_record: [codec.maximum_record_encoded_size]u8 = undefined,
    pages: []Page,
    read_storage: []u8,
    read_allocations: []bool,
    read_allocation_count: usize = 0,
    checkpoint_bytes: []u8,
    // Dedicated synchronous canonical-read buffer. It is never borrowed by
    // asynchronous reads or checkpoint encoding.
    exact_read: []u8 = &.{},
    staged_chunks: []StagedChunk,
    staged_chunk_count: usize = 0,
    queued_chunks: []QueuedChunk,
    queued_bytes: []u8,
    queue_read: usize = 0,
    queue_write: usize = 0,
    queue_head: usize = 0,
    queue_count: usize = 0,
    queue_used: usize = 0,
    runtime_staging: bool = false,
    runtime_staging_tick: u64 = 0,
    checkpoint_needs_begin: bool = false,
    checkpoint_pending: bool = false,
    derived_chunk_codec: ?DerivedChunkCodec = null,
    read_hits: u64 = 0,
    read_misses: u64 = 0,
    persisted_chunks: u64 = 0,
    derived_cache_misses: u64 = 0,
    projection_requests: u64 = 0,
    render_requests: u64 = 0,
    cold_requests: u64 = 0,
    decode_nanoseconds: u64 = 0,
    encode_nanoseconds: u64 = 0,
    stage_nanoseconds: u64 = 0,
    exact_reads: u64 = 0,
    exact_loader_reads: u64 = 0,
    exact_read_nanoseconds: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Persistence {
        if (configuration.read_capacity == 0 or configuration.read_bytes == 0 or
            configuration.read_granularity == 0 or configuration.read_bytes % configuration.read_granularity != 0 or
            configuration.read_bytes / configuration.read_granularity > std.math.maxInt(u16) or
            configuration.read_budget_ns == 0 or
            configuration.staging_budget_ns == 0 or
            configuration.queue_chunks == 0 or configuration.queue_bytes == 0 or
            configuration.queue_bytes > std.math.maxInt(u32))
            return error.InvalidCapacity;
        const checkpoint_capacity = deps.access.checkpointCapacity();
        if (checkpoint_capacity < 2) return error.InvalidCapacity;
        const self = try lightning_rod.preallocated.create(Persistence, allocator);
        self.* = .{
            .deps = deps,
            .configuration = configuration,
            .pages = try lightning_rod.preallocated.alloc(Page, allocator, configuration.read_capacity),
            .read_storage = try lightning_rod.preallocated.alloc(u8, allocator, configuration.read_bytes),
            .read_allocations = try lightning_rod.preallocated.alloc(bool, allocator, configuration.read_bytes / configuration.read_granularity),
            .checkpoint_bytes = try lightning_rod.preallocated.alloc(u8, allocator, lightning_rod.chunk_storage.encoded_size),
            .exact_read = try lightning_rod.preallocated.alloc(u8, allocator, lightning_rod.chunk_storage.encoded_size),
            .staged_chunks = try lightning_rod.preallocated.alloc(StagedChunk, allocator, checkpoint_capacity),
            .queued_chunks = try lightning_rod.preallocated.alloc(QueuedChunk, allocator, configuration.queue_chunks),
            .queued_bytes = try lightning_rod.preallocated.alloc(u8, allocator, configuration.queue_bytes),
        };
        @memset(self.pages, .{});
        @memset(self.read_allocations, false);
        try validateStoredChunkIndex(self.namespace());
        try self.restore();
        try deps.players.bindSavedPlayerStorage(.{ .context = self, .load_fn = loadSavedPlayer, .save_fn = saveSavedPlayer });
        return self;
    }

    fn requestProjection(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        self.projection_requests +%= 1;
        return self.requestWithPriority(world, chunk, false);
    }

    fn requestRender(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        self.render_requests +%= 1;
        return self.requestWithPriority(world, chunk, true);
    }

    fn requestCold(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        self.cold_requests +%= 1;
        return self.requestWithPriority(world, chunk, false);
    }

    fn requestWithPriority(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos, streaming: bool) RequestResult {
        // work() turns this refusal into a fatal tick error before gameplay can
        // treat an unavailable canonical record as a generation miss.
        if (self.namespace().persistence.poisoned()) return .backpressured;
        if (self.deps.blocks.materializedChunk(world, chunk) != null) return .resident;
        if (self.findPage(world, chunk)) |page| {
            if (streaming) self.pages[page].streaming = true;
            if (self.pages[page].stale and self.pages[page].state == .buffered) {
                self.releaseRead(&self.pages[page]);
                self.pages[page] = .{};
            } else return .pending;
        }
        if (self.newestQueuedChunk(world, chunk)) |queued|
            return self.bufferQueuedChunk(queued, streaming);
        const key = self.chunkKey(world, chunk) orelse
            std.debug.panic("chunk request used a stale world handle at {d}, {d}", .{ chunk.x, chunk.z });
        const storage = self.namespace();
        const length = storage.length(&key) orelse {
            self.read_misses +%= 1;
            const accepted = if (streaming)
                self.deps.blocks.requestStreamingChunkGeneration(world, chunk)
            else
                self.deps.blocks.requestChunkGeneration(world, chunk);
            return if (accepted) .submitted else .backpressured;
        };
        const page = self.freePage(streaming) orelse return .backpressured;
        self.pages[page] = .{ .world = world, .chunk = chunk, .streaming = streaming };
        std.debug.assert(length != 0 and length <= lightning_rod.chunk_storage.encoded_size);
        if (!self.allocateRead(page, length)) {
            self.pages[page] = .{};
            return .backpressured;
        }
        const token = storage.read(&key, self.pageBuffer(page));
        if (token == lightning_rod.persistence.no_request) {
            self.releaseRead(&self.pages[page]);
            self.pages[page] = .{};
            return .backpressured;
        }
        self.pages[page].state = .reading;
        self.pages[page].request = token;
        return .submitted;
    }

    /// Reports whether canonical bytes are already available without requiring
    /// a resident materialization. A missing record starts normal projection
    /// work so callers can retry after generation rather than treating it as
    /// simulation-ready air.
    fn canonicalAvailable(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) FatalError!bool {
        if (self.namespace().persistence.poisoned()) return error.StorageReadFailed;
        if (self.deps.blocks.materializedChunk(world, chunk) != null) return true;
        if (self.newestQueuedChunk(world, chunk) != null) return true;
        const key = self.chunkKey(world, chunk) orelse return error.StorageCorrupt;
        if (self.namespace().length(&key) != null) return true;
        if (self.namespace().persistence.poisoned()) return error.StorageReadFailed;
        _ = self.requestProjection(world, chunk);
        return false;
    }

    /// Returns the latest canonical block state without admitting a resident
    /// materialization. The bound Loader may synchronously read persisted data.
    /// `null` means that this chunk key has no canonical record, not that a
    /// cache or asynchronous read missed it.
    fn readStoredBlock(self: *Persistence, world: lightning_rod.world_identity.Handle, position: lightning_rod.geometry.BlockPos) FatalError!?i32 {
        var result: [1]?i32 = undefined;
        try self.readStoredBlocks(world, &.{position}, &result);
        return result[0];
    }

    fn readStoredBlocks(self: *Persistence, world: lightning_rod.world_identity.Handle, positions: []const lightning_rod.geometry.BlockPos, states: []?i32) FatalError!void {
        std.debug.assert(positions.len == states.len);
        self.exact_reads +%= positions.len;
        if (self.namespace().persistence.poisoned()) return error.StorageReadFailed;
        var begin: usize = 0;
        while (begin < positions.len) {
            const chunk = lightning_rod.geometry.chunkForBlock(positions[begin]);
            var end = begin + 1;
            while (end < positions.len and lightning_rod.geometry.sameChunk(chunk, lightning_rod.geometry.chunkForBlock(positions[end]))) : (end += 1) {}
            if (self.deps.blocks.materializedChunk(world, chunk)) |_| {
                for (positions[begin..end], states[begin..end]) |position, *state|
                    state.* = self.deps.blocks.blockAt(world, position);
            } else if (try self.storedChunkView(world, chunk)) |view| {
                for (positions[begin..end], states[begin..end]) |position, *state|
                    state.* = view.blockAt(position) catch return error.StorageCorrupt;
            } else {
                @memset(states[begin..end], null);
            }
            begin = end;
        }
    }

    fn storedChunkView(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) FatalError!?lightning_rod.chunk_storage.View {
        if (self.newestQueuedChunk(world, chunk)) |queued|
            return try storedChunkViewBytes(chunk, self.queuedChunkBytes(queued));

        const key = self.chunkKey(world, chunk) orelse return error.StorageCorrupt;
        self.exact_loader_reads +%= 1;
        const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds();
        defer if (started) |start| {
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |finish|
                self.exact_read_nanoseconds +%= finish -| start;
        };
        const loaded = self.deps.access.load(&key, self.exact_read) catch |err| return switch (err) {
            error.DestinationTooSmall => error.StorageCapacityExceeded,
            error.Corrupt, error.InvalidKey => error.StorageCorrupt,
            error.ReadFailed => error.StorageReadFailed,
        };
        const length = switch (loaded) {
            .missing => return null,
            .value => |value| value,
        };
        return try storedChunkViewBytes(chunk, self.exact_read[0..length]);
    }

    fn storedChunkViewBytes(
        chunk: lightning_rod.geometry.ChunkPos,
        bytes: []const u8,
    ) FatalError!lightning_rod.chunk_storage.View {
        return lightning_rod.chunk_storage.View.init(chunk, bytes) catch |err| {
            std.log.err("event=stored_chunk_view_failed x={d} z={d} error={s}", .{ chunk.x, chunk.z, @errorName(err) });
            return error.StorageCorrupt;
        };
    }

    fn writeStoredBlocks(self: *Persistence, io: std.Io, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos, writes: []const lightning_rod.chunk_storage.BlockWrite, mutations: []lightning_rod.geometry.BlockMutation) WriteError!usize {
        if (mutations.len < writes.len) return error.MutationCapacity;
        if (writes.len == 0) return 0;
        for (writes) |write| {
            if (!lightning_rod.geometry.sameChunk(lightning_rod.geometry.chunkForBlock(write.position), chunk) or
                lightning_rod.blocks.sectionIndexForY(write.position.y) == null or
                !lightning_rod.terrain.validBlockState(write.state)) return error.InvalidMutation;
        }
        if (self.namespace().persistence.poisoned()) return error.StorageReadFailed;
        const view = if (self.deps.blocks.materializedChunk(world, chunk) != null) resident: {
            const bytes = lightning_rod.chunk_storage.encode(self.exact_read, self.deps.blocks, world, chunk) catch return error.StorageCorrupt;
            break :resident try storedChunkViewBytes(chunk, bytes);
        } else (try self.storedChunkView(world, chunk)) orelse return error.ChunkMissing;
        var count: usize = 0;
        var seen: [lightning_rod.world_limits.section_count][lightning_rod.blocks.blocks_per_section / 64]u64 = undefined;
        var initialized = [_]bool{false} ** lightning_rod.world_limits.section_count;
        var index = writes.len;
        while (index != 0) {
            index -= 1;
            const write = writes[index];
            const section = lightning_rod.blocks.sectionIndexForY(write.position.y).?;
            if (!initialized[section]) {
                @memset(&seen[section], 0);
                initialized[section] = true;
            }
            const local = lightning_rod.blocks.localBlockIndexForPosition(write.position);
            const mask = @as(u64, 1) << @intCast(local % 64);
            if (seen[section][local / 64] & mask != 0) continue;
            seen[section][local / 64] |= mask;
            const previous = view.blockAt(write.position) catch return error.StorageCorrupt;
            if (previous == write.state) continue;
            mutations[count] = .{ .world = world, .pos = write.position, .previous_state = previous, .block_state = write.state };
            count += 1;
        }
        if (count == 0) return 0;
        std.mem.reverse(lightning_rod.geometry.BlockMutation, mutations[0..count]);
        const next_revision = self.deps.blocks.nextContentRevision(view.content_revision) catch return error.StorageCorrupt;
        const rewritten = view.rewrite(self.checkpoint_bytes, writes, next_revision) catch |err| return switch (err) {
            error.UnexpectedChunkPosition, error.InvalidWorldSection, error.InvalidChunkBlockState => error.InvalidMutation,
            error.EndOfStream => error.StorageCapacityExceeded,
            else => error.StorageCorrupt,
        };

        var writer = lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter{ .namespace = self.namespace(), .io = io };
        while (self.queuedChunk()) |queued| {
            const key = self.chunkKey(queued.world, queued.chunk) orelse return error.StorageCorrupt;
            writer.put(&key, self.queuedChunkBytes(queued)) catch |err| return canonicalWriteError(err);
            self.popQueuedChunk();
        }
        const key = self.chunkKey(world, chunk) orelse return error.StorageCorrupt;
        writer.put(&key, rewritten) catch |err| return canonicalWriteError(err);
        if (self.findPage(world, chunk)) |page| self.pages[page].stale = true;
        self.deps.blocks.acceptStoredMutations(world, chunk, mutations[0..count]);
        return count;
    }

    fn canonicalWriteError(err: lightning_rod.plugin_lifecycle.Checkpoint.Error) FatalError {
        return switch (err) {
            error.CapacityExceeded => error.StorageCapacityExceeded,
            error.InvalidKey => error.StorageCorrupt,
            error.Unavailable, error.Canceled => error.StorageWriteFailed,
        };
    }

    fn requestCapacity(self: *const Persistence) usize {
        return @min(self.pages.len, self.deps.blocks.generationRequestCapacity());
    }

    fn activity(self: *const Persistence) Activity {
        const generation_metrics = self.deps.blocks.generationMetrics();
        var result = Activity{
            .staged_chunks = self.staged_chunk_count,
            .staging = self.runtime_staging,
            .checkpoint_pending = self.checkpoint_pending or self.runtime_staging,
            .read_hits = self.read_hits,
            .read_misses = self.read_misses,
            .generation_calls = generation_metrics.calls,
            .generation_nanoseconds = generation_metrics.nanoseconds,
            .generation_maximum_nanoseconds = generation_metrics.maximum_nanoseconds,
            .generated_chunks = generation_metrics.installed,
            .persisted_chunks = self.persisted_chunks,
            .derived_cache_misses = self.derived_cache_misses,
            .projection_requests = self.projection_requests,
            .render_requests = self.render_requests,
            .cold_requests = self.cold_requests,
            .transient_chunks = self.deps.blocks.materializedChunkCount(),
            .transient_capacity = self.deps.blocks.materializationCapacity(),
            .emitted_shapes = generation_metrics.emitted,
            .installed_shapes = generation_metrics.installed,
            .materialization_nanoseconds = generation_metrics.materialization_nanoseconds,
            .decode_nanoseconds = self.decode_nanoseconds,
            .encode_nanoseconds = self.encode_nanoseconds,
            .stage_nanoseconds = self.stage_nanoseconds,
            .queued_chunks = self.queue_count,
            .queued_bytes = self.queue_used,
            .exact_reads = self.exact_reads,
            .exact_loader_reads = self.exact_loader_reads,
            .exact_read_nanoseconds = self.exact_read_nanoseconds,
        };
        for (self.pages) |page| switch (page.state) {
            .free => result.free += 1,
            .reading, .buffered => result.reading += 1,
            .request_waiting => result.request_waiting += 1,
        };
        result.generating = self.deps.blocks.pendingChunkGenerationCount();
        for (self.deps.blocks.active_materialization_indices[0..self.deps.blocks.materialization_count]) |index| {
            const resident = &self.deps.blocks.materialized_chunks[index];
            if (resident.valid and (resident.dirty or resident.dirty_section_mask != 0))
                result.dirty_chunks += 1;
        }
        return result;
    }

    fn setDerivedChunkCodec(self: *Persistence, value: DerivedChunkCodec) void {
        std.debug.assert(self.derived_chunk_codec == null);
        self.derived_chunk_codec = value;
    }

    fn work(self: *Persistence) FatalError!void {
        if (self.namespace().persistence.poisoned()) return error.StorageReadFailed;
        try self.completeCheckpoint();
        try self.advancePages();
        if (self.deps.runtime_metrics) |value| {
            const current = self.activity();
            value.setMaterialization(
                current.free,
                current.reading,
                current.request_waiting,
                current.generating,
                current.dirty_chunks,
                self.pages.len,
                self.pages.len,
                self.read_storage.len + self.checkpoint_bytes.len + self.exact_read.len + self.metadata_root.len + self.metadata_record.len +
                    std.mem.sliceAsBytes(self.pages).len +
                    std.mem.sliceAsBytes(self.staged_chunks).len + std.mem.sliceAsBytes(self.read_allocations).len +
                    std.mem.sliceAsBytes(self.queued_chunks).len + self.queued_bytes.len,
                self.readBytes(),
                self.read_storage.len,
                current.read_hits,
                current.read_misses,
                current.generated_chunks,
                current.persisted_chunks,
                current.exact_reads,
                current.exact_loader_reads,
                current.exact_read_nanoseconds,
            );
        }
    }

    fn loadSavedPlayer(raw: *anyopaque, client_uuid: u128, username: []const u8, output: *lightning_rod.players.CorePlayer) lightning_rod.players.SavedPlayerLoadError!bool {
        const self: *Persistence = @ptrCast(@alignCast(raw));
        var state = self.persistedState();
        if (client_uuid != 0) {
            const direct_key = playerRecordKey(client_uuid);
            const direct = self.deps.access.load(&direct_key, &self.metadata_record) catch |err| return mapSavedLoadError(err);
            switch (direct) {
                .value => |length| {
                    output.* = codec.decodePlayerRecord(&state, self.metadata_record[0..length]) catch return error.StorageCorrupt;
                    // A UUID identifies the player even when a legitimate rename
                    // changed the record's username.
                    if (output.uuid != client_uuid) return error.StorageCorrupt;
                    return true;
                },
                .missing => return false,
            }
        }
        var alias_storage: [player_record_key_bytes]u8 = undefined;
        const alias = playerNameKey(&alias_storage, username) orelse return false;
        const alias_record = self.deps.access.load(alias, &self.metadata_record) catch |err| return mapSavedLoadError(err);
        const alias_bytes = switch (alias_record) {
            .missing => return false,
            .value => |length| self.metadata_record[0..length],
        };
        if (alias_bytes.len != @sizeOf(u128)) return error.StorageCorrupt;
        const alias_uuid = std.mem.readInt(u128, alias_bytes[0..@sizeOf(u128)], .big);
        const key = playerRecordKey(alias_uuid);
        const record = self.deps.access.load(&key, &self.metadata_record) catch |err| return mapSavedLoadError(err);
        const length = switch (record) {
            .missing => return error.StorageCorrupt,
            .value => |value| value,
        };
        output.* = codec.decodePlayerRecord(&state, self.metadata_record[0..length]) catch return error.StorageCorrupt;
        if (output.uuid != alias_uuid) return error.StorageCorrupt;
        return std.mem.eql(u8, output.name_slice(), username);
    }

    fn saveSavedPlayer(raw: *anyopaque, io: std.Io, player: *const lightning_rod.players.CorePlayer) lightning_rod.players.SavedPlayerSaveError!void {
        const self: *Persistence = @ptrCast(@alignCast(raw));
        const state = self.persistedState();
        var record_key = playerRecordKey(player.uuid);
        var alias_storage: [player_record_key_bytes]u8 = undefined;
        const alias_key = playerNameKey(&alias_storage, player.name_slice()) orelse return error.StorageCorrupt;
        var uuid_bytes: [@sizeOf(u128)]u8 = undefined;
        std.mem.writeInt(u128, &uuid_bytes, player.uuid, .big);
        const encoded = codec.encodePlayerRecord(&self.metadata_record, &state, player.*) catch return error.StorageCorrupt;
        const records = [_]lightning_rod.persistence.CheckpointRecord{
            .{ .key = &record_key, .operation = .{ .put = encoded } },
            .{ .key = alias_key, .operation = .{ .put = &uuid_bytes } },
        };
        const storage = self.namespace();
        const reservation = storage.reserve(&records) catch |err| retry: {
            if (err != error.Backpressured) return mapSavedReserveError(err);
            storage.persistence.drain(io) catch return error.StorageUnavailable;
            break :retry storage.reserve(&records) catch |failure| return mapSavedReserveError(failure);
        };
        storage.publish(reservation);
    }

    fn writePlayer(self: *Persistence, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter, state: *codec.PersistedState, player: lightning_rod.players.CorePlayer) !void {
        var record_key = playerRecordKey(player.uuid);
        var alias_storage: [player_record_key_bytes]u8 = undefined;
        const alias_key = playerNameKey(&alias_storage, player.name_slice()) orelse return error.CapacityExceeded;
        var uuid_bytes: [@sizeOf(u128)]u8 = undefined;
        std.mem.writeInt(u128, &uuid_bytes, player.uuid, .big);
        const encoded = try codec.encodePlayerRecord(&self.metadata_record, state, player);
        try writer.batch(&.{
            .{ .key = &record_key, .operation = .{ .put = encoded } },
            .{ .key = alias_key, .operation = .{ .put = &uuid_bytes } },
        });
    }

    fn mapSavedLoadError(err: lightning_rod.persistence.LoadError) lightning_rod.players.SavedPlayerLoadError {
        return switch (err) {
            error.Corrupt, error.InvalidKey, error.DestinationTooSmall => error.StorageCorrupt,
            error.ReadFailed => error.StorageUnavailable,
        };
    }
    fn mapSavedReserveError(err: lightning_rod.persistence.ReserveError) lightning_rod.players.SavedPlayerSaveError {
        return switch (err) {
            error.InvalidKey, error.ValueTooLarge, error.IndexCapacityExceeded => error.StorageCorrupt,
            error.Backpressured, error.StorageFailed => error.StorageUnavailable,
        };
    }

    pub fn checkpoint(self: *Persistence, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        try self.completeCheckpoint();
        if (self.checkpoint_pending) return error.CheckpointStillPending;
        if (self.runtime_staging) {
            for (self.staged_chunks[0..self.staged_chunk_count]) |staged|
                self.deps.blocks.markChunkCleanThrough(staged.world, staged.chunk, staged.revision);
            self.persisted_chunks +%= @intCast(self.staged_chunk_count);
            self.staged_chunk_count = 0;
            self.runtime_staging = false;
        }
        while (self.queuedChunk()) |queued| {
            const key = self.chunkKey(queued.world, queued.chunk) orelse return error.StaleWorldHandle;
            try writer.put(&key, self.queuedChunkBytes(queued));
            self.popQueuedChunk();
        }
        var state = self.persistedState();
        for (state.players.activeSlots()) |slot|
            try self.writePlayer(writer, &state, state.players.records[slot]);
        for (state.items.active_indices[0..state.items.active_count], 0..) |item_index, index| {
            const key = metadataKey(metadata_item_tag, index) orelse return error.CapacityExceeded;
            try writer.put(&key, try codec.encodeItemRecord(&self.metadata_record, &state, state.items.value(item_index)));
        }
        for (state.living.entities.active_indices[0..state.living.entities.active_count], 0..) |living_index, index| {
            const key = metadataKey(metadata_living_tag, index) orelse return error.CapacityExceeded;
            try writer.put(&key, try codec.encodeLivingRecord(&self.metadata_record, &state, living_index));
        }
        try self.stageDirtyChunks(writer);
        try writer.put(metadata_root_key, try codec.encodeRoot(&self.metadata_root, try codec.root(&state)));
        self.checkpoint_pending = true;
    }

    fn restore(self: *Persistence) !void {
        const loaded = try self.deps.access.load(metadata_root_key, &self.metadata_root);
        switch (loaded) {
            .missing => {},
            .value => |length| {
                var state = self.persistedState();
                const root = try codec.decodeRoot(self.metadata_root[0..length]);
                try codec.beginRestore(&state, root);
                const items: usize = @intCast(root.items);
                const living: usize = @intCast(root.living);
                for (0..items) |index| {
                    const key = metadataKey(metadata_item_tag, index) orelse return error.StorageCorrupt;
                    const record = try self.deps.access.load(&key, &self.metadata_record);
                    const bytes = switch (record) {
                        .missing => return error.StorageCorrupt,
                        .value => |value_length| self.metadata_record[0..value_length],
                    };
                    try codec.restoreItemRecord(&state, bytes);
                }
                for (0..living) |index| {
                    const key = metadataKey(metadata_living_tag, index) orelse return error.StorageCorrupt;
                    const record = try self.deps.access.load(&key, &self.metadata_record);
                    const bytes = switch (record) {
                        .missing => return error.StorageCorrupt,
                        .value => |value_length| self.metadata_record[0..value_length],
                    };
                    try codec.restoreLivingRecord(&state, bytes);
                }
                codec.finishRestore(&state, root);
            },
        }
    }

    fn advancePages(self: *Persistence) FatalError!void {
        const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds() orelse 0;
        for ([_]bool{ true, false }) |streaming| {
            for (self.pages, 0..) |*page, index| {
                if (page.state == .free or page.streaming != streaming) continue;
                switch (page.state) {
                    .free => unreachable,
                    .reading, .buffered => try self.pollPage(page, index),
                    .request_waiting => self.restartStalePage(page),
                }
                if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |elapsed|
                    if (elapsed -| started >= self.configuration.read_budget_ns) return;
            }
        }
    }

    fn flushDirtyChunks(self: *Persistence) FatalError!void {
        self.enqueueDirtyChunks() catch |err| {
            std.log.err("event=chunk_staging_failed error={s}", .{@errorName(err)});
            return error.StorageWriteFailed;
        };
        if (self.checkpoint_pending) return;
        if (!self.runtime_staging) {
            if (self.queue_count == 0) return;
            if (self.deps.access.checkpointProgress() != .ready) return;
            self.staged_chunk_count = 0;
            self.runtime_staging = true;
            self.runtime_staging_tick = self.deps.clock.tick;
        }
        const complete = self.stageRuntimeSlice() catch |err| {
            std.log.err("event=chunk_staging_failed error={s}", .{@errorName(err)});
            return error.StorageWriteFailed;
        };
        if (!complete) return;
        if (self.staged_chunk_count == 0) {
            self.runtime_staging = false;
            return;
        }
        if (self.staged_chunk_count != self.staged_chunks.len and
            self.deps.clock.tick -| self.runtime_staging_tick < runtime_checkpoint_batch_ticks) return;
        self.runtime_staging = false;
        switch (self.deps.access.flush()) {
            .ready, .pending => {
                self.checkpoint_pending = true;
            },
            .backpressured => {
                self.checkpoint_needs_begin = true;
                self.checkpoint_pending = true;
            },
            .missing, .too_small, .failed => return error.StorageWriteFailed,
        }
    }

    fn pollPage(self: *Persistence, page: *Page, index: usize) FatalError!void {
        if (page.state == .buffered) {
            if (page.stale) {
                self.restartStalePage(page);
                return;
            }
            if (self.deps.blocks.materializedChunk(page.world, page.chunk) == null and
                self.deps.blocks.materializedChunkCount() == self.deps.blocks.materializationCapacity()) return;
            return self.decodePage(page, index, page.buffered_length, false);
        }
        std.debug.assert(page.state == .reading);
        const result = self.deps.access.pollRead(page.request);
        switch (result.status) {
            .pending => {},
            .ready => {
                if (page.stale) {
                    self.restartStalePage(page);
                    return;
                }
                if (self.deps.blocks.materializedChunk(page.world, page.chunk) == null and
                    self.deps.blocks.materializedChunkCount() == self.deps.blocks.materializationCapacity())
                {
                    self.read_hits +%= 1;
                    page.state = .buffered;
                    page.buffered_length = @intCast(result.bytes);
                    return;
                }
                return self.decodePage(page, index, result.bytes, true);
            },
            .missing => {
                if (page.stale) {
                    self.restartStalePage(page);
                    return;
                }
                self.read_misses +%= 1;
                self.releaseRead(page);
                const accepted = if (page.streaming)
                    self.deps.blocks.requestStreamingChunkGeneration(page.world, page.chunk)
                else
                    self.deps.blocks.requestChunkGeneration(page.world, page.chunk);
                if (accepted)
                    page.* = .{}
                else
                    page.state = .request_waiting;
            },
            .backpressured => {},
            .too_small => {
                std.log.err("event=chunk_read_capacity x={d} z={d} required={d}", .{ page.chunk.x, page.chunk.z, result.bytes });
                return error.StorageCapacityExceeded;
            },
            .failed => return error.StorageReadFailed,
        }
    }

    fn decodePage(self: *Persistence, page: *Page, index: usize, length: usize, count_read: bool) FatalError!void {
        if (self.deps.blocks.materializedChunk(page.world, page.chunk) != null) {
            self.releaseRead(page);
            page.* = .{};
            return;
        }
        std.debug.assert(length != 0 and length <= self.pageBuffer(index).len);
        const decode_started = lightning_rod.plugin_profiler.tickElapsedNanoseconds();
        const tail = lightning_rod.chunk_storage.decodeWithTail(
            self.deps.blocks,
            page.world,
            page.chunk,
            self.pageBuffer(index)[0..length],
        ) catch |err| {
            std.log.err("event=chunk_decode_failed x={d} z={d} error={s}", .{ page.chunk.x, page.chunk.z, @errorName(err) });
            return switch (err) {
                error.WorldSectionCapacity, error.MaterializationCapacity, error.MaterializationLookupFull => error.StorageCapacityExceeded,
                else => error.StorageCorrupt,
            };
        };
        if (tail.len == 0 or !self.decodeDerived(page.world, page.chunk, tail)) {
            self.derived_cache_misses +%= 1;
        }
        if (decode_started) |start| {
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |finish|
                self.decode_nanoseconds +%= finish -| start;
        }
        if (count_read) self.read_hits +%= 1;
        self.releaseRead(page);
        page.* = .{};
    }

    fn restartStalePage(self: *Persistence, page: *Page) void {
        const world = page.world;
        const chunk = page.chunk;
        const streaming = page.streaming;
        self.releaseRead(page);
        page.* = .{};
        if (self.requestWithPriority(world, chunk, streaming) == .backpressured)
            page.* = .{ .state = .request_waiting, .world = world, .chunk = chunk, .streaming = streaming, .stale = true };
    }

    fn stageDirtyChunks(self: *Persistence, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        self.staged_chunk_count = 0;
        for (self.deps.blocks.active_materialization_indices[0..self.deps.blocks.materialization_count]) |index| {
            const resident = &self.deps.blocks.materialized_chunks[index];
            if (!resident.valid or !(resident.dirty or resident.dirty_section_mask != 0)) continue;
            if (self.staged_chunk_count == self.staged_chunks.len) return error.CapacityExceeded;
            const revision = self.deps.blocks.chunkDirtyRevision(resident.world, resident.chunk);
            const bytes = try self.encodeChunk(resident.world, resident.chunk);
            const key = self.chunkKey(resident.world, resident.chunk) orelse return error.StaleWorldHandle;
            try writer.put(&key, bytes);
            self.staged_chunks[self.staged_chunk_count] = .{ .world = resident.world, .chunk = resident.chunk, .revision = revision };
            self.staged_chunk_count += 1;
        }
    }

    fn stageRuntimeSlice(self: *Persistence) !bool {
        const storage = self.namespace();
        const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds() orelse 0;
        for (0..self.staged_chunks.len) |_| {
            if (self.staged_chunk_count == self.staged_chunks.len) return true;
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |elapsed|
                if (elapsed -| started >= self.configuration.staging_budget_ns) return false;
            const queued = self.queuedChunk() orelse return true;
            const key = self.chunkKey(queued.world, queued.chunk) orelse return error.StaleWorldHandle;
            const stage_started = lightning_rod.plugin_profiler.tickElapsedNanoseconds();
            const stage_status = storage.stagePut(&key, self.queuedChunkBytes(queued));
            if (stage_started) |start| {
                if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |finish|
                    self.stage_nanoseconds +%= finish -| start;
            }
            switch (stage_status) {
                .ready => {},
                .backpressured => return self.staged_chunk_count != 0,
                .missing, .pending, .too_small, .failed => return error.PersistenceUnavailable,
            }
            self.staged_chunks[self.staged_chunk_count] = .{ .world = queued.world, .chunk = queued.chunk, .revision = queued.revision };
            self.staged_chunk_count += 1;
            self.popQueuedChunk();
        }
        return self.staged_chunk_count == self.staged_chunks.len or self.queue_count == 0;
    }

    fn enqueueDirtyChunks(self: *Persistence) !void {
        const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds() orelse 0;
        for (0..self.deps.blocks.materializationCapacity()) |_| {
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |elapsed|
                if (elapsed -| started >= self.configuration.staging_budget_ns) return;
            const index = self.nextUnstagedDirty() orelse return;
            const resident = &self.deps.blocks.materialized_chunks[index];
            const revision = self.deps.blocks.chunkDirtyRevision(resident.world, resident.chunk);
            const bytes = try self.encodeChunk(resident.world, resident.chunk);
            if (!self.pushQueuedChunk(resident.world, resident.chunk, revision, bytes)) return;
            self.deps.blocks.markChunkCleanThrough(resident.world, resident.chunk, revision);
        }
    }

    fn nextUnstagedDirty(self: *const Persistence) ?u16 {
        for (self.deps.blocks.active_materialization_indices[0..self.deps.blocks.materialization_count]) |index| {
            const resident = &self.deps.blocks.materialized_chunks[index];
            if (!resident.valid or !(resident.dirty or resident.dirty_section_mask != 0)) continue;
            return index;
        }
        return null;
    }

    fn pushQueuedChunk(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos, revision: u64, bytes: []const u8) bool {
        if (self.queue_count == self.queued_chunks.len or bytes.len > self.queued_bytes.len - self.queue_used) return false;
        if (self.queue_count != 0 and self.queue_write == self.queue_read) return false;
        var offset = self.queue_write;
        if (self.queue_write >= self.queue_read) {
            if (bytes.len > self.queued_bytes.len - self.queue_write) {
                if (bytes.len > self.queue_read) return false;
                offset = 0;
            }
        } else if (bytes.len > self.queue_read - self.queue_write) return false;
        @memcpy(self.queued_bytes[offset..][0..bytes.len], bytes);
        const tail = (self.queue_head + self.queue_count) % self.queued_chunks.len;
        self.queued_chunks[tail] = .{
            .world = world,
            .chunk = chunk,
            .revision = revision,
            .offset = @intCast(offset),
            .length = @intCast(bytes.len),
        };
        self.queue_write = (offset + bytes.len) % self.queued_bytes.len;
        self.queue_count += 1;
        self.queue_used += bytes.len;
        if (self.findPage(world, chunk)) |page| self.pages[page].stale = true;
        return true;
    }

    fn queuedChunk(self: *const Persistence) ?QueuedChunk {
        if (self.queue_count == 0) return null;
        return self.queued_chunks[self.queue_head];
    }

    fn newestQueuedChunk(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ?QueuedChunk {
        var result: ?QueuedChunk = null;
        for (0..self.queue_count) |offset| {
            const queued = self.queued_chunks[(self.queue_head + offset) % self.queued_chunks.len];
            if (queued.world.eql(world) and lightning_rod.geometry.sameChunk(queued.chunk, chunk)) result = queued;
        }
        return result;
    }

    fn bufferQueuedChunk(self: *Persistence, queued: QueuedChunk, streaming: bool) RequestResult {
        std.debug.assert(queued.length != 0 and queued.length <= lightning_rod.chunk_storage.encoded_size);
        const page = self.freePage(streaming) orelse return .backpressured;
        self.pages[page] = .{ .world = queued.world, .chunk = queued.chunk, .streaming = streaming };
        if (!self.allocateRead(page, queued.length)) {
            self.pages[page] = .{};
            return .backpressured;
        }
        @memcpy(self.pageBuffer(page)[0..queued.length], self.queuedChunkBytes(queued));
        self.pages[page].state = .buffered;
        self.pages[page].buffered_length = queued.length;
        return .submitted;
    }

    fn queuedChunkBytes(self: *const Persistence, queued: QueuedChunk) []const u8 {
        return self.queued_bytes[queued.offset..][0..queued.length];
    }

    fn popQueuedChunk(self: *Persistence) void {
        const queued = self.queued_chunks[self.queue_head];
        self.queue_used -= queued.length;
        self.queue_read = (@as(usize, queued.offset) + queued.length) % self.queued_bytes.len;
        self.queue_head = (self.queue_head + 1) % self.queued_chunks.len;
        self.queue_count -= 1;
        if (self.queue_count == 0) {
            self.queue_read = 0;
            self.queue_write = 0;
            self.queue_head = 0;
        }
    }

    fn completeCheckpoint(self: *Persistence) FatalError!void {
        if (!self.checkpoint_pending) return;
        if (self.checkpoint_needs_begin) {
            switch (self.deps.access.flush()) {
                .ready, .pending => self.checkpoint_needs_begin = false,
                .backpressured => return,
                .missing, .too_small, .failed => return error.StorageWriteFailed,
            }
        }
        switch (self.deps.access.checkpointProgress()) {
            .ready => {
                for (self.staged_chunks[0..self.staged_chunk_count]) |staged|
                    self.deps.blocks.markChunkCleanThrough(staged.world, staged.chunk, staged.revision);
                self.persisted_chunks +%= @intCast(self.staged_chunk_count);
                self.staged_chunk_count = 0;
                self.checkpoint_needs_begin = false;
                self.checkpoint_pending = false;
            },
            .pending, .backpressured => {},
            .missing, .too_small, .failed => return error.StorageDurabilityFailed,
        }
    }

    fn namespace(self: *const Persistence) lightning_rod.persistence.Namespace {
        return self.deps.access.runtime();
    }

    fn findPage(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ?usize {
        for (self.pages, 0..) |page, index| if (page.state != .free and page.world.eql(world) and lightning_rod.geometry.sameChunk(page.chunk, chunk)) return index;
        return null;
    }

    fn freePage(self: *const Persistence, streaming: bool) ?usize {
        const normal_start = self.pages.len * 3 / 4;
        const pages = if (streaming) self.pages else self.pages[normal_start..];
        for (pages, 0..) |page, index| if (page.state == .free)
            return index + if (streaming) 0 else normal_start;
        return null;
    }

    fn allocateRead(self: *Persistence, page: usize, length: usize) bool {
        const count = std.math.divCeil(usize, length, self.configuration.read_granularity) catch return false;
        var run: usize = 0;
        for (self.read_allocations, 0..) |used, index| {
            run = if (used) 0 else run + 1;
            if (run != count) continue;
            const start = index + 1 - count;
            @memset(self.read_allocations[start .. start + count], true);
            self.read_allocation_count += count;
            self.pages[page].allocation_start = @intCast(start);
            self.pages[page].allocation_count = @intCast(count);
            return true;
        }
        return false;
    }

    fn readBytes(self: *const Persistence) usize {
        return self.read_allocation_count * self.configuration.read_granularity;
    }

    fn releaseRead(self: *Persistence, page: *Page) void {
        if (page.allocation_count == 0) return;
        const start: usize = page.allocation_start;
        const count: usize = page.allocation_count;
        @memset(self.read_allocations[start .. start + count], false);
        self.read_allocation_count -= count;
        page.allocation_start = 0;
        page.allocation_count = 0;
    }

    fn pageBuffer(self: *Persistence, page: usize) []u8 {
        const value = self.pages[page];
        const start = @as(usize, value.allocation_start) * self.configuration.read_granularity;
        const length = @as(usize, value.allocation_count) * self.configuration.read_granularity;
        return self.read_storage[start..][0..length];
    }

    fn encodeChunk(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ![]u8 {
        const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds();
        defer if (started) |start| {
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |finish|
                self.encode_nanoseconds +%= finish -| start;
        };
        const encoded = try lightning_rod.chunk_storage.encode(self.checkpoint_bytes, self.deps.blocks, world, chunk);
        const codec_value = self.derived_chunk_codec orelse return encoded;
        const remaining = self.checkpoint_bytes[encoded.len..];
        const tail = codec_value.encode(codec_value.context, world, chunk, remaining) orelse return encoded;
        return lightning_rod.chunk_storage.append(self.checkpoint_bytes, encoded, tail) catch encoded;
    }

    fn decodeDerived(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos, bytes: []const u8) bool {
        const codec_value = self.derived_chunk_codec orelse return false;
        return codec_value.decode(codec_value.context, world, chunk, bytes);
    }

    fn chunkKey(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ?[chunk_key.encoded_bytes]u8 {
        const record = self.deps.worlds.getConst(world) orelse return null;
        var key: [chunk_key.encoded_bytes]u8 = undefined;
        _ = chunk_key.encode(&key, .{ .world = record.key, .chunk = chunk });
        return key;
    }

    fn persistedState(self: *Persistence) codec.PersistedState {
        return .{ .worlds = self.deps.worlds, .clock = self.deps.clock, .time = self.deps.time, .random = self.deps.random, .living = self.deps.living, .players = self.deps.players, .items = self.deps.items };
    }
};

pub const ChunkWork = struct {
    pub const id = "minecraft:chunk_work";
    pub const Configuration = struct {};
    pub const Dependencies = struct { storage: *Persistence };

    storage: *Persistence,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*ChunkWork {
        const self = try allocator.create(ChunkWork);
        self.* = .{ .storage = deps.storage };
        return self;
    }

    pub fn tick(self: *ChunkWork, _: std.mem.Allocator) FatalError!void {
        return self.storage.work();
    }
};

pub const FlushChunks = struct {
    pub const id = "minecraft:flush_chunks";
    pub const Configuration = struct {};
    pub const Dependencies = struct { storage: *Persistence };

    storage: *Persistence,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*FlushChunks {
        const self = try allocator.create(FlushChunks);
        self.* = .{ .storage = deps.storage };
        return self;
    }

    pub fn tick(self: *FlushChunks, _: std.mem.Allocator) FatalError!void {
        return self.storage.flushDirtyChunks();
    }
};

pub const Materializer = struct {
    pub const id = "minecraft:chunk_materializer";
    pub const Configuration = struct {};
    pub const Dependencies = struct { storage: *Persistence };

    storage: *Persistence,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*Materializer {
        const self = try allocator.create(Materializer);
        self.* = .{ .storage = deps.storage };
        return self;
    }

    pub fn requestProjection(self: *Materializer, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        return self.storage.requestProjection(world, chunk);
    }

    pub fn requestRender(self: *Materializer, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        return self.storage.requestRender(world, chunk);
    }

    pub fn requestCold(self: *Materializer, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        return self.storage.requestCold(world, chunk);
    }

    pub fn requestCapacity(self: *const Materializer) usize {
        return self.storage.requestCapacity();
    }

    /// Canonical readiness for admission. This includes resident, queued,
    /// staged, and persisted records; it deliberately does not require cache
    /// residency. Missing chunks are submitted for ordinary projection work.
    pub fn canonicalAvailable(self: *Materializer, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) FatalError!bool {
        return self.storage.canonicalAvailable(world, chunk);
    }

    /// Looks up canonical state in resident memory, the newest private queue
    /// entry, then the bound synchronous Loader. `null` is an absent canonical
    /// chunk record; it is never a synthetic air block.
    pub fn readStoredBlock(self: *Materializer, world: lightning_rod.world_identity.Handle, position: lightning_rod.geometry.BlockPos) FatalError!?i32 {
        return self.storage.readStoredBlock(world, position);
    }

    /// Adjacent positions in the same chunk share one canonical read and validation.
    /// May wait for storage; prefer a prepared projection in steady-state simulation.
    pub fn readStoredBlocks(self: *Materializer, world: lightning_rod.world_identity.Handle, positions: []const lightning_rod.geometry.BlockPos, states: []?i32) FatalError!void {
        return self.storage.readStoredBlocks(world, positions, states);
    }

    /// Stages one canonical chunk atomically before invalidating its cached copy.
    /// Scratch mutations are caller-owned; no raw chunk must remain resident.
    pub fn writeStoredBlocks(self: *Materializer, io: std.Io, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos, writes: []const lightning_rod.chunk_storage.BlockWrite, mutations: []lightning_rod.geometry.BlockMutation) WriteError!usize {
        return self.storage.writeStoredBlocks(io, world, chunk, writes, mutations);
    }

    pub fn activity(self: *const Materializer) Activity {
        return self.storage.activity();
    }

    pub fn setDerivedChunkCodec(self: *Materializer, value: DerivedChunkCodec) void {
        self.storage.setDerivedChunkCodec(value);
    }
};

test "stored chunk record validation rejects invalid keys and lengths" {
    var key: [chunk_key.encoded_bytes]u8 = undefined;
    _ = chunk_key.encode(&key, .{ .world = .{ .value = 1 }, .chunk = .{ .x = 0, .z = 0 } });
    try validateStoredChunkRecord(.{ .key = &key, .value_bytes = 1 });
    try validateStoredChunkRecord(.{ .key = metadata_root_key, .value_bytes = codec.maximum_root_encoded_size });
    const player_key = metadataKey(legacy_metadata_player_tag, 0).?;
    try std.testing.expectError(error.StorageSchemaUnsupported, validateStoredChunkRecord(.{ .key = &player_key, .value_bytes = codec.maximum_record_encoded_size }));
    try std.testing.expectError(error.StorageSchemaUnsupported, validateStoredChunkRecord(.{ .key = legacy_metadata_key, .value_bytes = 1 }));
    try std.testing.expectError(error.StorageCorrupt, validateStoredChunkRecord(.{ .key = "invalid", .value_bytes = 1 }));
    try std.testing.expectError(error.StorageCorrupt, validateStoredChunkRecord(.{ .key = &key, .value_bytes = 0 }));
    try std.testing.expectError(error.StorageCorrupt, validateStoredChunkRecord(.{ .key = &key, .value_bytes = lightning_rod.chunk_storage.encoded_size + 1 }));
}

test "stable UUID does not restore a same-name player alias" {
    const Loader = struct {
        store: *lightning_rod.persistence.Store,

        fn read(raw: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) lightning_rod.persistence.LoadError!lightning_rod.persistence.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return switch (self.store.currentValue(namespace, key)) {
                .missing => .missing,
                .staged => |value| {
                    if (destination.len < value.len) return error.DestinationTooSmall;
                    @memcpy(destination[0..value.len], value);
                    return .{ .value = value.len };
                },
                .failed, .persisted => error.ReadFailed,
            };
        }
    };

    var state: lightning_rod.test_support.state.State = undefined;
    try state.init(std.testing.allocator, 0x4a1a5);
    defer state.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const store = try lightning_rod.persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 4,
        .maximum_checkpoint_records = 4,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = player_record_key_bytes,
        .maximum_value_bytes = codec.maximum_record_encoded_size,
        .maximum_checkpoint_bytes = 4 * 1024,
    }, 4 * 1024);
    var loader = Loader{ .store = store };
    const access = lightning_rod.persistence.Access.init(.{
        .interface = store.interface(),
        .loader = .{ .context = &loader, .read_fn = Loader.read },
        .maximum_checkpoint_records = 4,
    });
    var persistence = Persistence{
        .deps = .{
            .access = access.plugin(Persistence.id),
            .worlds = state.worlds,
            .clock = &state.clock,
            .time = &state.time,
            .random = &state.random,
            .blocks = &state.blocks,
            .living = &state.living,
            .players = &state.players,
            .items = &state.items,
            .runtime_metrics = null,
        },
        .configuration = .{},
        .pages = &.{},
        .read_storage = &.{},
        .read_allocations = &.{},
        .checkpoint_bytes = &.{},
        .staged_chunks = &.{},
        .queued_chunks = &.{},
        .queued_bytes = &.{},
    };
    var stored: lightning_rod.players.CorePlayer = .{ .world = state.world, .uuid = 0x11 };
    @memcpy(stored.name[0..9], "shared-id");
    stored.name_len = 9;
    var state_view = persistence.persistedState();
    var encoded_bytes: [codec.maximum_record_encoded_size]u8 = undefined;
    const encoded = try codec.encodePlayerRecord(&encoded_bytes, &state_view, stored);
    var record_key = playerRecordKey(stored.uuid);
    var alias_storage: [player_record_key_bytes]u8 = undefined;
    const alias_key = playerNameKey(&alias_storage, stored.name_slice()).?;
    var uuid_bytes: [@sizeOf(u128)]u8 = undefined;
    std.mem.writeInt(u128, &uuid_bytes, stored.uuid, .big);
    try std.testing.expectEqual(lightning_rod.persistence.Status.ready, store.interface().stageBatch(&.{
        .{ .namespace = Persistence.id, .key = &record_key, .operation = .{ .put = encoded } },
        .{ .namespace = Persistence.id, .key = alias_key, .operation = .{ .put = &uuid_bytes } },
    }));

    var output: lightning_rod.players.CorePlayer = undefined;
    try std.testing.expect(!(try persistence.loadSavedPlayer(0x22, "shared-id", &output)));
    try std.testing.expect(try persistence.loadSavedPlayer(0, "shared-id", &output));
    try std.testing.expectEqual(stored.uuid, output.uuid);
}

test "stored chunk index scan advances past metadata at a page boundary" {
    var memory: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try lightning_rod.persistence.Store.initForTest(fixed.allocator(), .{
        .maximum_keys = 64,
        .maximum_checkpoint_records = 64,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 40,
        .maximum_key_bytes = chunk_key.encoded_bytes,
        .maximum_value_bytes = 8,
        .maximum_checkpoint_bytes = 4 * 1024,
    }, 4 * 1024);
    const namespace = store.interface().namespace(Persistence.id);
    var keys: [startup_scan_records - 1][chunk_key.encoded_bytes]u8 = undefined;
    var records: [startup_scan_records + 1]lightning_rod.persistence.CheckpointRecord = undefined;
    for (&keys, 0..) |*key, index| {
        _ = chunk_key.encode(key, .{ .world = .{ .value = 1 }, .chunk = .{ .x = @intCast(index), .z = 0 } });
        records[index] = .{ .namespace = Persistence.id, .key = key, .operation = .{ .put = "x" } };
    }
    records[keys.len] = .{ .namespace = Persistence.id, .key = metadata_root_key, .operation = .{ .put = "metadata" } };
    records[keys.len + 1] = .{ .namespace = Persistence.id, .key = "z", .operation = .{ .put = "x" } };
    try std.testing.expectEqual(lightning_rod.persistence.Status.ready, store.interface().stageBatch(&records));
    try std.testing.expectEqual(lightning_rod.persistence.Status.pending, store.interface().flush());
    store.submit();
    _ = store.complete(1);

    var scan: [startup_scan_records]lightning_rod.persistence.ScanRecord = undefined;
    const first = try namespace.scan("", &scan);
    try std.testing.expect(first.more);
    try std.testing.expectEqual(@as(usize, startup_scan_records), first.count);
    // The root is now the smallest binary key; the first page must still end
    // at a chunk key so validation resumes into the following page.
    try std.testing.expectEqualSlices(u8, &keys[keys.len - 1], scan[first.count - 1].key);
    try std.testing.expectError(error.StorageCorrupt, validateStoredChunkIndex(namespace));
}

test "stored chunk index validates paginated namespace before admitting reads" {
    const configuration: lightning_rod.persistence.Configuration = .{
        .maximum_keys = 64,
        .maximum_checkpoint_records = 64,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 40,
        .maximum_key_bytes = chunk_key.encoded_bytes,
        .maximum_value_bytes = lightning_rod.chunk_storage.encoded_size + 1,
        .maximum_checkpoint_bytes = lightning_rod.chunk_storage.encoded_size + 8 * 1024,
    };
    var memory: [2 * 1024 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const store = try lightning_rod.persistence.Store.initForTest(
        fixed.allocator(),
        configuration,
        configuration.maximum_checkpoint_bytes,
    );
    const namespace = store.interface().namespace(Persistence.id);
    var keys: [startup_scan_records + 1][chunk_key.encoded_bytes]u8 = undefined;
    var records: [startup_scan_records + 2]lightning_rod.persistence.CheckpointRecord = undefined;
    records[0] = .{ .namespace = Persistence.id, .key = metadata_root_key, .operation = .{ .put = "metadata" } };
    for (&keys, 0..) |*key, index| {
        _ = chunk_key.encode(key, .{ .world = .{ .value = 1 }, .chunk = .{ .x = @intCast(index), .z = 0 } });
        records[index + 1] = .{ .namespace = Persistence.id, .key = key, .operation = .{ .put = "x" } };
    }
    try std.testing.expectEqual(lightning_rod.persistence.Status.ready, store.interface().stageBatch(&records));
    try std.testing.expectEqual(lightning_rod.persistence.Status.pending, store.interface().flush());
    store.submit();
    _ = store.complete(1);
    try validateStoredChunkIndex(namespace);

    var oversized_key: [chunk_key.encoded_bytes]u8 = undefined;
    _ = chunk_key.encode(&oversized_key, .{ .world = .{ .value = 1 }, .chunk = .{ .x = -1, .z = 0 } });
    var oversized_value: [lightning_rod.chunk_storage.encoded_size + 1]u8 = undefined;
    try std.testing.expectEqual(
        lightning_rod.persistence.Status.ready,
        store.interface().stage(.{ .namespace = Persistence.id, .key = &oversized_key, .operation = .{ .put = &oversized_value } }),
    );
    try std.testing.expectEqual(lightning_rod.persistence.Status.pending, store.interface().flush());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectError(error.StorageCorrupt, validateStoredChunkIndex(namespace));
}

test "failed storage is fatal while idle and never admitted as chunk generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try lightning_rod.blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
    });
    const worlds = try lightning_rod.worlds.Worlds.init(arena.allocator(), .{ .initial = &.{.{
        .key = .{ .value = 1 },
        .name = "test:overworld",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }}, .maximum_worlds = 1 });
    const store = try lightning_rod.persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = chunk_key.encoded_bytes,
        .maximum_value_bytes = lightning_rod.chunk_storage.encoded_size,
        .maximum_checkpoint_bytes = lightning_rod.chunk_storage.encoded_size + 1024,
    }, lightning_rod.chunk_storage.encoded_size + 1024);
    const access = lightning_rod.persistence.Access.init(.{
        .interface = store.interface(),
        .maximum_checkpoint_records = 1,
    });
    var deps: Persistence.Dependencies = undefined;
    deps.blocks = blocks;
    deps.worlds = worlds;
    deps.access = access.plugin(Persistence.id);
    var persistence = Persistence{
        .deps = deps,
        .configuration = .{},
        .pages = &.{},
        .read_storage = &.{},
        .read_allocations = &.{},
        .checkpoint_bytes = &.{},
        .staged_chunks = &.{},
        .queued_chunks = &.{},
        .queued_bytes = &.{},
    };
    store.markFailed();

    try std.testing.expectError(error.StorageReadFailed, persistence.work());
    try std.testing.expectError(error.StorageReadFailed, persistence.canonicalAvailable(worlds.active()[0], .{ .x = 0, .z = 0 }));
    try std.testing.expectEqual(
        RequestResult.backpressured,
        persistence.requestWithPriority(worlds.active()[0], .{ .x = 0, .z = 0 }, false),
    );
    try std.testing.expectEqual(@as(u64, 0), blocks.generationMetrics().calls);
}

test "failed read completion is fatal while materialization cache is full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try lightning_rod.blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
    });
    var generator: lightning_rod.test_support.world_generator.Generator = .{ .mode = .flat };
    generator.bind(blocks);
    const worlds = try lightning_rod.worlds.Worlds.init(arena.allocator(), .{ .initial = &.{.{
        .key = .{ .value = 1 },
        .name = "test:overworld",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }}, .maximum_worlds = 1 });
    const world = worlds.active()[0];
    for (0..blocks.materializationCapacity()) |index|
        _ = blocks.materializeGeneratedChunk(world, .{ .x = @intCast(index + 1), .z = 0 }, 1);
    try std.testing.expectEqual(blocks.materializationCapacity(), blocks.materializedChunkCount());

    const store = try lightning_rod.persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 1,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = chunk_key.encoded_bytes,
        .maximum_value_bytes = lightning_rod.chunk_storage.encoded_size,
        .maximum_checkpoint_bytes = lightning_rod.chunk_storage.encoded_size + 1024,
    }, lightning_rod.chunk_storage.encoded_size + 1024);
    const access = lightning_rod.persistence.Access.init(.{
        .interface = store.interface(),
        .maximum_checkpoint_records = 1,
    });
    var page_storage: [1]u8 = undefined;
    const request = store.read(Persistence.id, "x", &page_storage);
    try std.testing.expect(request != lightning_rod.persistence.no_request);
    var pages: [1]Page = .{.{
        .state = .reading,
        .world = world,
        .chunk = .{ .x = 0, .z = 0 },
        .request = request,
        .allocation_count = 1,
    }};
    var allocations = [_]bool{true};
    var deps: Persistence.Dependencies = undefined;
    deps.blocks = blocks;
    deps.worlds = worlds;
    deps.access = access.plugin(Persistence.id);
    var persistence = Persistence{
        .deps = deps,
        .configuration = .{ .read_capacity = 1, .read_bytes = 1, .read_granularity = 1 },
        .pages = &pages,
        .read_storage = &page_storage,
        .read_allocations = &allocations,
        .read_allocation_count = 1,
        .checkpoint_bytes = &.{},
        .staged_chunks = &.{},
        .queued_chunks = &.{},
        .queued_bytes = &.{},
    };
    store.markFailed();

    try std.testing.expectError(error.StorageReadFailed, persistence.pollPage(&persistence.pages[0], 0));
}

test "queued chunk overlay reloads the newest evicted revision" {
    const TestLoader = struct {
        store: *lightning_rod.persistence.Store,
        backing: *lightning_rod.persistence.Store,

        fn read(context: *anyopaque, namespace: []const u8, key: []const u8, destination: []u8) lightning_rod.persistence.LoadError!lightning_rod.persistence.LoadResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            return switch (self.store.currentValue(namespace, key)) {
                .failed => error.ReadFailed,
                .missing => .missing,
                .staged => |value| {
                    if (destination.len < value.len) return error.DestinationTooSmall;
                    @memcpy(destination[0..value.len], value);
                    return .{ .value = value.len };
                },
                .persisted => |location| result: {
                    if (destination.len < location.length) return error.DestinationTooSmall;
                    if (location.pack != 0 or location.offset > self.backing.test_storage_len or
                        location.length > self.backing.test_storage_len - location.offset) return error.ReadFailed;
                    @memcpy(destination[0..location.length], self.backing.test_storage[location.offset..][0..location.length]);
                    break :result .{ .value = location.length };
                },
            };
        }
    };
    const registry = lightning_rod.registry_data;
    const chunk = lightning_rod.geometry.ChunkPos{ .x = 0, .z = 0 };
    const position = lightning_rod.geometry.BlockPos{ .x = 1, .y = 65, .z = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try lightning_rod.blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    const worlds = try lightning_rod.worlds.Worlds.init(arena.allocator(), .{ .initial = &.{.{
        .key = .{ .value = 1 },
        .name = "test:overworld",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }}, .maximum_worlds = 1 });
    const world = worlds.active()[0];
    const store = try lightning_rod.persistence.Store.initForTest(arena.allocator(), .{
        .maximum_keys = 8,
        .maximum_checkpoint_records = 8,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 64,
        .maximum_key_bytes = chunk_key.encoded_bytes,
        .maximum_value_bytes = lightning_rod.chunk_storage.encoded_size,
        .maximum_checkpoint_bytes = lightning_rod.chunk_storage.encoded_size + 8 * 1024,
    }, lightning_rod.chunk_storage.encoded_size + 8 * 1024);
    var loader_context = TestLoader{ .store = store, .backing = store };
    const access = lightning_rod.persistence.Access.init(.{
        .interface = store.interface(),
        .loader = .{ .context = &loader_context, .read_fn = TestLoader.read },
        .maximum_checkpoint_records = 8,
    });
    var generator: lightning_rod.test_support.world_generator.Generator = .{ .mode = .flat };
    generator.bind(blocks);
    _ = blocks.materializeGeneratedChunk(world, chunk, 1);

    var checkpoint: [lightning_rod.chunk_storage.encoded_size]u8 = undefined;
    _ = try blocks.setBlock(world, position, registry.block_stone_default_state);
    const first = try lightning_rod.chunk_storage.encode(&checkpoint, blocks, world, chunk);
    var first_copy: [lightning_rod.chunk_storage.encoded_size]u8 = undefined;
    @memcpy(first_copy[0..first.len], first);
    _ = try blocks.setBlock(world, position, registry.state_water_level_0);
    const second = try lightning_rod.chunk_storage.encode(&checkpoint, blocks, world, chunk);
    var second_copy: [lightning_rod.chunk_storage.encoded_size]u8 = undefined;
    @memcpy(second_copy[0..second.len], second);

    var pages: [2]Page = .{ .{}, .{} };
    const granularity = lightning_rod.chunk_storage.encoded_size / 2;
    const allocation_count = 2;
    const read_storage = try arena.allocator().alloc(u8, allocation_count * granularity);
    const read_allocations = try arena.allocator().alloc(bool, allocation_count);
    @memset(read_allocations, false);
    var staged_chunks: [1]StagedChunk = undefined;
    var queued_chunks: [3]QueuedChunk = undefined;
    const queued_bytes = try arena.allocator().alloc(u8, lightning_rod.chunk_storage.encoded_size * 3);
    var exact_read: [lightning_rod.chunk_storage.encoded_size]u8 = undefined;
    var deps: Persistence.Dependencies = undefined;
    deps.blocks = blocks;
    deps.worlds = worlds;
    deps.access = access.plugin(Persistence.id);
    var persistence = Persistence{
        .deps = deps,
        .configuration = .{ .read_capacity = pages.len, .read_bytes = read_storage.len, .read_granularity = granularity },
        .pages = &pages,
        .read_storage = read_storage,
        .read_allocations = read_allocations,
        .checkpoint_bytes = &checkpoint,
        .exact_read = &exact_read,
        .staged_chunks = &staged_chunks,
        .queued_chunks = &queued_chunks,
        .queued_bytes = queued_bytes,
    };
    try std.testing.expect(persistence.pushQueuedChunk(world, chunk, 1, first_copy[0..first.len]));
    try std.testing.expect(persistence.pushQueuedChunk(world, chunk, 2, second_copy[0..second.len]));
    var key: [chunk_key.encoded_bytes]u8 = undefined;
    _ = chunk_key.encode(&key, .{ .world = worlds.getConst(world).?.key, .chunk = chunk });
    try std.testing.expectEqual(
        lightning_rod.persistence.Status.ready,
        store.stage(.{ .namespace = Persistence.id, .key = &key, .operation = .{ .put = first_copy[0..first.len] } }),
    );
    blocks.markChunkClean(world, chunk);
    try std.testing.expectEqual(@as(usize, 1), blocks.releaseUnusedMaterializations());
    try std.testing.expect(blocks.materializedChunk(world, chunk) == null);

    try std.testing.expectEqual(RequestResult.submitted, persistence.requestWithPriority(world, chunk, false));
    try persistence.pollPage(&persistence.pages[1], 1);
    try std.testing.expectEqual(registry.state_water_level_0, blocks.blockAt(world, position));

    blocks.markChunkClean(world, chunk);
    try std.testing.expectEqual(@as(usize, 1), blocks.releaseUnusedMaterializations());
    try std.testing.expectEqual(
        registry.state_water_level_0,
        (try persistence.readStoredBlock(world, position)).?,
    );
    persistence.popQueuedChunk();
    persistence.popQueuedChunk();
    try std.testing.expectEqual(
        registry.block_stone_default_state,
        (try persistence.readStoredBlock(world, position)).?,
    );
    const loader_reads = persistence.exact_loader_reads;
    var batch_states: [3]?i32 = undefined;
    const adjacent = lightning_rod.geometry.BlockPos{ .x = position.x + 1, .y = position.y, .z = position.z };
    try persistence.readStoredBlocks(world, &.{ position, adjacent, position }, &batch_states);
    try std.testing.expectEqual(loader_reads + 1, persistence.exact_loader_reads);
    try std.testing.expectEqual(@as(?i32, registry.block_stone_default_state), batch_states[0]);
    try std.testing.expectEqual(@as(?i32, registry.block_air_default_state), batch_states[1]);
    try std.testing.expectEqual(batch_states[0], batch_states[2]);
    try std.testing.expect(try persistence.canonicalAvailable(world, chunk));
    try std.testing.expect(blocks.materializedChunk(world, chunk) == null);
    try std.testing.expectEqual(
        lightning_rod.persistence.Status.ready,
        store.stage(.{ .namespace = Persistence.id, .key = &key, .operation = .delete }),
    );
    try std.testing.expectEqual(@as(?i32, null), try persistence.readStoredBlock(world, position));

    const retry_chunk = lightning_rod.geometry.ChunkPos{ .x = 1, .z = 0 };
    const held_chunk = lightning_rod.geometry.ChunkPos{ .x = 2, .z = 0 };
    const retry_bytes = try arena.allocator().alloc(u8, granularity + 1);
    @memset(retry_bytes, 0);
    persistence.pages[0] = .{ .state = .reading, .world = world, .chunk = held_chunk, .allocation_count = 1 };
    persistence.pages[1] = .{ .state = .buffered, .world = world, .chunk = retry_chunk, .allocation_start = 1, .allocation_count = 1, .buffered_length = 1 };
    @memset(persistence.read_allocations, true);
    persistence.read_allocation_count = 2;
    try std.testing.expect(persistence.pushQueuedChunk(world, retry_chunk, 3, retry_bytes));
    persistence.restartStalePage(&persistence.pages[1]);
    try std.testing.expectEqual(PageState.request_waiting, persistence.pages[1].state);
    try std.testing.expect(persistence.pages[1].stale);
    persistence.releaseRead(&persistence.pages[0]);
    persistence.pages[0] = .{};
    persistence.restartStalePage(&persistence.pages[1]);
    try std.testing.expectEqual(PageState.buffered, persistence.pages[1].state);
    try std.testing.expectEqual(@as(u32, @intCast(retry_bytes.len)), persistence.pages[1].buffered_length);

    persistence.releaseRead(&persistence.pages[1]);
    persistence.pages[1] = .{};
    while (persistence.queuedChunk() != null) persistence.popQueuedChunk();
    const late_chunk = lightning_rod.geometry.ChunkPos{ .x = 3, .z = 0 };
    const late_position = lightning_rod.geometry.BlockPos{ .x = 49, .y = 65, .z = 1 };
    _ = blocks.materializeGeneratedChunk(world, late_chunk, 1);
    _ = try blocks.setBlock(world, late_position, registry.block_stone_default_state);
    const old = try lightning_rod.chunk_storage.encode(&checkpoint, blocks, world, late_chunk);
    @memcpy(first_copy[0..old.len], old);
    _ = try blocks.setBlock(world, late_position, registry.state_water_level_0);
    const newest = try lightning_rod.chunk_storage.encode(&checkpoint, blocks, world, late_chunk);
    @memcpy(second_copy[0..newest.len], newest);
    blocks.markChunkClean(world, late_chunk);
    try std.testing.expectEqual(@as(usize, 1), blocks.releaseUnusedMaterializations());
    const late_key = persistence.chunkKey(world, late_chunk).?;
    try std.testing.expectEqual(lightning_rod.persistence.Status.ready, persistence.namespace().stagePut(&late_key, first_copy[0..old.len]));
    try std.testing.expectEqual(lightning_rod.persistence.Status.pending, store.interface().flush());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(RequestResult.submitted, persistence.requestWithPriority(world, late_chunk, false));
    try std.testing.expectEqual(PageState.reading, persistence.pages[1].state);
    try std.testing.expect(persistence.pushQueuedChunk(world, late_chunk, 4, second_copy[0..newest.len]));
    try std.testing.expect(try persistence.stageRuntimeSlice());
    try std.testing.expect(persistence.queuedChunk() == null);
    _ = store.complete(1);
    try persistence.pollPage(&persistence.pages[1], 1);
    try std.testing.expectEqual(PageState.reading, persistence.pages[1].state);
    try persistence.pollPage(&persistence.pages[1], 1);
    try std.testing.expectEqual(registry.state_water_level_0, blocks.blockAt(world, late_position));
    blocks.markChunkClean(world, late_chunk);
    try std.testing.expect(blocks.evictChunk(world, late_chunk));
    const generation_calls = blocks.generationMetrics().calls;
    var mutations: [2]lightning_rod.geometry.BlockMutation = undefined;
    const rewrite_count = try persistence.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = registry.block_dirt_default_state },
        .{ .position = late_position, .state = registry.block_stone_default_state },
    }, &mutations);
    try std.testing.expectEqual(@as(usize, 1), rewrite_count);
    try std.testing.expectEqual(registry.state_water_level_0, mutations[0].previous_state);
    try std.testing.expectEqual(registry.block_stone_default_state, mutations[0].block_state);
    try std.testing.expectEqual(@as(?i32, registry.block_stone_default_state), try persistence.readStoredBlock(world, late_position));
    try std.testing.expectEqual(@as(usize, 0), blocks.materializedChunkCount());
    try std.testing.expectEqual(generation_calls, blocks.generationMetrics().calls);
    try std.testing.expectEqual(mutations[0], blocks.blockMutation(blocks.block_mutation_sequence));
    const late_adjacent = lightning_rod.geometry.BlockPos{ .x = late_position.x + 1, .y = late_position.y, .z = late_position.z };
    var coalesced: [3]lightning_rod.geometry.BlockMutation = undefined;
    try std.testing.expectEqual(@as(usize, 1), try persistence.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = registry.block_dirt_default_state },
        .{ .position = late_adjacent, .state = registry.block_stone_default_state },
        .{ .position = late_position, .state = registry.block_stone_default_state },
    }, &coalesced));
    try std.testing.expectEqual(late_adjacent, coalesced[0].pos);
    try std.testing.expectEqual(registry.block_air_default_state, coalesced[0].previous_state);
    const mutation_sequence = blocks.block_mutation_sequence;
    persistence.checkpoint_bytes = checkpoint[0..16];
    try std.testing.expectError(error.StorageCapacityExceeded, persistence.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = registry.block_dirt_default_state },
    }, &mutations));
    try std.testing.expectEqual(mutation_sequence, blocks.block_mutation_sequence);
    try std.testing.expectEqual(@as(?i32, registry.block_stone_default_state), try persistence.readStoredBlock(world, late_position));
    persistence.checkpoint_bytes = &checkpoint;
    const state = try arena.allocator().create(lightning_rod.test_support.state.State);
    try state.init(std.testing.allocator, 7);
    defer state.deinit();
    var sessions = lightning_rod.sessions.Sessions.init(772);
    const outputs = try lightning_rod.Packets.init(arena.allocator(), .{
        .inputs = &state.inputs,
        .blocks = blocks,
        .players = &state.players,
        .containers = &state.containers,
        .living = &state.living,
        .items = &state.items,
        .worlds = worlds,
        .sessions = &sessions,
    }, .{ .maximum_input_packets = 4, .input_byte_capacity = 1024, .maximum_player_messages = 4 });
    outputs.temporary = arena.allocator();
    var materializer = Materializer{ .storage = &persistence };
    const leaf = try @import("vanilla_leaf_distance.zig").LeafDistance.init(arena.allocator(), .{
        .materialization = &materializer,
        .blocks = blocks,
        .outputs = outputs,
    }, .{});
    const leaf_behavior = @import("../vanilla/leaf_behavior.zig");
    const initial_leaf = leaf_behavior.withDistance(registry.block_oak_leaves_default_state, 7);
    _ = try materializer.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = initial_leaf },
        .{ .position = .{ .x = late_position.x + 1, .y = late_position.y, .z = late_position.z }, .state = registry.block_oak_log_default_state },
    }, &mutations);
    try leaf.tick(std.testing.io, arena.allocator());
    try std.testing.expectEqual(@as(?u8, 7), leaf_behavior.distance((try materializer.readStoredBlock(world, late_position)).?));
    try std.testing.expectEqual(@as(usize, 1), leaf.scheduled_count);
    try leaf.tick(std.testing.io, arena.allocator());
    const updated_leaf = (try materializer.readStoredBlock(world, late_position)).?;
    try std.testing.expectEqual(@as(?u8, 1), leaf_behavior.distance(updated_leaf));
    try std.testing.expectEqual(@as(usize, 0), blocks.materializedChunkCount());
    try std.testing.expectEqual(generation_calls, blocks.generationMetrics().calls);
    try std.testing.expectEqual(updated_leaf, blocks.blockMutation(blocks.block_mutation_sequence).block_state);
    const resident_length = (try TestLoader.read(&loader_context, Persistence.id, &late_key, &first_copy)).value;
    try lightning_rod.chunk_storage.decode(blocks, world, late_chunk, first_copy[0..resident_length]);
    try std.testing.expectEqual(@as(usize, 1), blocks.materializedChunkCount());
    _ = try materializer.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = initial_leaf },
    }, &mutations);
    try leaf.tick(std.testing.io, arena.allocator());
    try leaf.tick(std.testing.io, arena.allocator());
    try std.testing.expectEqual(@as(?i32, updated_leaf), try materializer.readStoredBlock(world, late_position));
    try std.testing.expectEqual(@as(usize, 0), blocks.materializedChunkCount());
    try std.testing.expectEqual(lightning_rod.persistence.Status.pending, store.interface().flush());
    store.submit();
    _ = store.complete(1);
    try std.testing.expectEqual(@as(?i32, updated_leaf), try materializer.readStoredBlock(world, late_position));
    const reopened = try lightning_rod.persistence.Store.initIndex(arena.allocator(), store.configuration);
    try std.testing.expectEqual(store.test_storage_len, try reopened.recover(store.test_storage[0..store.test_storage_len]));
    loader_context.store = reopened;
    try std.testing.expectEqual(@as(?i32, updated_leaf), try materializer.readStoredBlock(world, late_position));
    try std.testing.expectEqual(@as(usize, 0), blocks.materializedChunkCount());
    loader_context.store = store;
    const final_mutation_sequence = blocks.block_mutation_sequence;
    store.markFailed();
    try std.testing.expectError(error.StorageReadFailed, persistence.writeStoredBlocks(std.testing.io, world, late_chunk, &.{
        .{ .position = late_position, .state = registry.block_dirt_default_state },
    }, &mutations));
    try std.testing.expectEqual(final_mutation_sequence, blocks.block_mutation_sequence);
}
