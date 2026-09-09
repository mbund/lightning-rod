const std = @import("std");
const lightning_rod = @import("lightning_rod");
const paging = lightning_rod.chunk_paging;
const codec = @import("../vanilla_persistence_codec.zig");

const metadata_key = "state";

const PageState = enum(u8) { free, reading, waiting_generation };

const Page = struct {
    state: PageState = .free,
    world: lightning_rod.world_identity.Handle = lightning_rod.world_identity.invalid,
    chunk: lightning_rod.geometry.ChunkPos = .{ .x = 0, .z = 0 },
    request: lightning_rod.persistence.Request = lightning_rod.persistence.no_request,
};

const Generation = struct {
    active: bool = false,
    world: lightning_rod.world_identity.Handle = lightning_rod.world_identity.invalid,
    chunk: lightning_rod.geometry.ChunkPos = .{ .x = 0, .z = 0 },
};

const StagedChunk = struct {
    world: lightning_rod.world_identity.Handle,
    chunk: lightning_rod.geometry.ChunkPos,
    revision: u64,
};

pub const RequestResult = enum(u8) { resident, pending, submitted, backpressured };

pub const Activity = struct {
    free: usize = 0,
    reading: usize = 0,
    generation_waiting: usize = 0,
    generating: usize = 0,
    staged_chunks: usize = 0,
    dirty_chunks: usize = 0,
    staging: bool = false,
    checkpoint_pending: bool = false,
    read_hits: u64 = 0,
    read_misses: u64 = 0,
    generation_slices: u64 = 0,
    generation_nanoseconds: u64 = 0,
    generated_chunks: u64 = 0,
    persisted_chunks: u64 = 0,
    derived_rebuilds: u64 = 0,
};

pub const DerivedChunkCodec = struct {
    context: *anyopaque,
    encode: *const fn (*anyopaque, lightning_rod.world_identity.Handle, lightning_rod.geometry.ChunkPos, []u8) ?[]u8,
    decode: *const fn (*anyopaque, lightning_rod.world_identity.Handle, lightning_rod.geometry.ChunkPos, []const u8) bool,
};

pub const Persistence = struct {
    pub const id = "minecraft:vanilla_persistence";
    pub const Configuration = struct {
        page_count: usize = 64,
        generation_count: usize = 64,
        generation_slice_limit: usize = 512,
        generation_budget_ns: u64 = 35 * std.time.ns_per_ms,
        staging_slice_limit: usize = 4,
        staging_budget_ns: u64 = 8 * std.time.ns_per_ms,
        runtime_checkpoint_chunks: usize = 8,
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
    };

    deps: Dependencies,
    configuration: Configuration,
    metadata: []u8,
    pages: []Page,
    generations: []Generation,
    page_bytes: []u8,
    checkpoint_bytes: []u8,
    staged_chunks: []StagedChunk,
    staged_chunk_count: usize = 0,
    runtime_staging: bool = false,
    checkpoint_needs_begin: bool = false,
    checkpoint_pending: bool = false,
    derived_chunk_codec: ?DerivedChunkCodec = null,
    read_hits: u64 = 0,
    read_misses: u64 = 0,
    generation_slices: u64 = 0,
    generation_nanoseconds: u64 = 0,
    generated_chunks: u64 = 0,
    persisted_chunks: u64 = 0,
    derived_rebuilds: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Persistence {
        if (configuration.page_count == 0 or configuration.generation_count == 0 or
            configuration.generation_slice_limit == 0 or configuration.generation_budget_ns == 0 or
            configuration.staging_slice_limit == 0 or configuration.staging_budget_ns == 0 or
            configuration.generation_slice_limit > 1024 or configuration.runtime_checkpoint_chunks == 0)
            return error.InvalidCapacity;
        if (configuration.page_count > deps.blocks.generationRequestCapacity() or
            configuration.generation_count > deps.blocks.generationRequestCapacity())
            return error.InvalidCapacity;
        const checkpoint_capacity = deps.access.checkpointCapacity();
        if (checkpoint_capacity < 2) return error.InvalidCapacity;
        const checkpoint_chunk_limit = checkpoint_capacity - 1;
        const page_byte_count = std.math.mul(usize, configuration.page_count, lightning_rod.chunk_storage.encoded_size) catch return error.InvalidCapacity;
        const persisted_state = codec.PersistedState{
            .worlds = deps.worlds,
            .clock = deps.clock,
            .time = deps.time,
            .random = deps.random,
            .blocks = deps.blocks,
            .living = deps.living,
            .players = deps.players,
            .items = deps.items,
        };
        const self = try lightning_rod.preallocated.create(Persistence, allocator);
        self.* = .{
            .deps = deps,
            .configuration = configuration,
            .metadata = try lightning_rod.preallocated.alloc(u8, allocator, codec.maximumMetadataStateEncodedSize(&persisted_state)),
            .pages = try lightning_rod.preallocated.alloc(Page, allocator, configuration.page_count),
            .generations = try lightning_rod.preallocated.alloc(Generation, allocator, configuration.generation_count),
            .page_bytes = try lightning_rod.preallocated.alloc(u8, allocator, page_byte_count),
            .checkpoint_bytes = try lightning_rod.preallocated.alloc(u8, allocator, lightning_rod.chunk_storage.encoded_size),
            .staged_chunks = try lightning_rod.preallocated.alloc(StagedChunk, allocator, checkpoint_chunk_limit),
        };
        @memset(self.pages, .{});
        @memset(self.generations, .{});
        try self.restore();
        return self;
    }

    pub fn request(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) RequestResult {
        if (self.deps.blocks.ticketResidentChunk(world, chunk)) return .resident;
        if (self.findPage(world, chunk) != null) return .pending;
        if (self.deps.blocks.chunkGenerationPending(world, chunk)) return .pending;
        const page = self.freePage() orelse return .backpressured;
        const key = self.chunkKey(world, chunk) orelse
            std.debug.panic("chunk request used a stale world handle at {d}, {d}", .{ chunk.x, chunk.z });
        const token = self.namespace().read(&key, self.pageBuffer(page));
        if (token == lightning_rod.persistence.no_request) return .backpressured;
        self.pages[page] = .{ .state = .reading, .world = world, .chunk = chunk, .request = token };
        return .submitted;
    }

    pub fn requestCapacity(self: *const Persistence) usize {
        return self.pages.len;
    }

    pub fn activity(self: *const Persistence) Activity {
        var result = Activity{
            .staged_chunks = self.staged_chunk_count,
            .staging = self.runtime_staging,
            .checkpoint_pending = self.checkpoint_pending or self.runtime_staging,
            .read_hits = self.read_hits,
            .read_misses = self.read_misses,
            .generation_slices = self.generation_slices,
            .generation_nanoseconds = self.generation_nanoseconds,
            .generated_chunks = self.generated_chunks,
            .persisted_chunks = self.persisted_chunks,
            .derived_rebuilds = self.derived_rebuilds,
        };
        for (self.pages) |page| switch (page.state) {
            .free => result.free += 1,
            .reading => result.reading += 1,
            .waiting_generation => result.generation_waiting += 1,
        };
        for (self.generations) |generation|
            result.generating += @intFromBool(generation.active);
        for (self.deps.blocks.active_resident_indices[0..self.deps.blocks.resident_chunk_count]) |index| {
            const resident = &self.deps.blocks.resident_chunks[index];
            if (resident.valid and (resident.dirty or resident.dirty_section_mask != 0))
                result.dirty_chunks += 1;
        }
        return result;
    }

    pub fn setDerivedChunkCodec(self: *Persistence, value: DerivedChunkCodec) void {
        std.debug.assert(self.derived_chunk_codec == null);
        self.derived_chunk_codec = value;
    }

    pub fn tick(self: *Persistence, _: std.mem.Allocator) void {
        self.completeCheckpoint();
        self.advancePages();
        for (0..self.configuration.generation_slice_limit) |_| {
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |elapsed|
                if (elapsed >= self.configuration.generation_budget_ns) break;
            const started = lightning_rod.plugin_profiler.tickElapsedNanoseconds();
            const generation = self.deps.blocks.generateRequestedChunk(self.deps.clock.tick);
            if (started) |start| {
                if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |finish|
                    self.generation_nanoseconds +%= finish -| start;
            }
            if (generation != .idle) self.generation_slices +%= 1;
            switch (generation) {
                .complete, .pending => {},
                .idle, .backpressured => break,
            }
        }
        self.finishGeneratedPages();
        self.flushDirtyChunks();
    }

    pub fn checkpoint(self: *Persistence, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        if (self.checkpoint_pending or self.runtime_staging) return error.CheckpointStillPending;
        var state = self.persistedState();
        try state.players.saveActive();
        const length = codec.metadataStateEncodedSize(&state);
        if (length > self.metadata.len) return error.CapacityExceeded;
        try writer.put(metadata_key, try codec.encodeMetadataState(self.metadata[0..length], &state));
        try self.stageDirtyChunks(writer);
        self.checkpoint_pending = true;
    }

    fn restore(self: *Persistence) !void {
        const loaded = self.deps.access.load(metadata_key, self.metadata) catch |err| switch (err) {
            error.ReadFailed => return,
            else => return err,
        };
        switch (loaded) {
            .missing => {},
            .value => |length| {
                var state = self.persistedState();
                try codec.decodeMetadataState(&state, self.metadata[0..length]);
            },
        }
    }

    fn advancePages(self: *Persistence) void {
        for (self.pages, 0..) |*page, index| switch (page.state) {
            .free => {},
            .reading => self.pollPage(page, index),
            .waiting_generation => self.queueGeneration(page),
        };
    }

    fn finishGeneratedPages(self: *Persistence) void {
        for (self.generations) |*generation| {
            if (!generation.active or
                !self.deps.blocks.ticketResidentChunk(generation.world, generation.chunk))
                continue;
            self.completeGenerated(generation.world, generation.chunk);
            generation.* = .{};
        }
    }

    fn flushDirtyChunks(self: *Persistence) void {
        if (self.checkpoint_pending) return;
        if (!self.runtime_staging) {
            const threshold = @min(self.configuration.runtime_checkpoint_chunks, self.staged_chunks.len);
            if (!self.dirtyThresholdReached(threshold) and !self.deps.blocks.residentPressure()) return;
            if (self.deps.access.checkpointProgress() != .ready) return;
            self.staged_chunk_count = 0;
            self.runtime_staging = true;
        }
        const complete = self.stageRuntimeSlice() catch
            @panic("failed to stage generated chunks");
        if (!complete) return;
        self.runtime_staging = false;
        if (self.staged_chunk_count == 0) return;
        switch (self.deps.access.beginCheckpoint()) {
            .ready, .pending => {
                self.checkpoint_pending = true;
            },
            .backpressured => {
                self.checkpoint_needs_begin = true;
                self.checkpoint_pending = true;
            },
            .missing, .too_small, .failed => @panic("failed to persist generated chunks"),
        }
    }

    fn dirtyThresholdReached(self: *const Persistence, threshold: usize) bool {
        var dirty: usize = 0;
        for (self.deps.blocks.active_resident_indices[0..self.deps.blocks.resident_chunk_count]) |index| {
            const resident = &self.deps.blocks.resident_chunks[index];
            if (!resident.valid or !(resident.dirty or resident.dirty_section_mask != 0)) continue;
            dirty += 1;
            if (dirty == threshold) return true;
        }
        return false;
    }

    fn pollPage(self: *Persistence, page: *Page, index: usize) void {
        const result = self.deps.access.pollRead(page.request);
        switch (result.status) {
            .pending => {},
            .ready => {
                if (result.bytes > self.pageBuffer(index).len)
                    self.failRead(page, "value exceeds the configured chunk page");
                const tail = lightning_rod.chunk_storage.decodeWithTail(
                    self.deps.blocks,
                    page.world,
                    page.chunk,
                    self.pageBuffer(index)[0..result.bytes],
                ) catch self.failRead(page, "chunk value is corrupt");
                if (tail.len != 0 and !self.decodeDerived(page.world, page.chunk, tail)) {
                    self.derived_rebuilds +%= 1;
                }
                _ = self.deps.blocks.ticketResidentChunk(page.world, page.chunk);
                self.read_hits +%= 1;
                page.* = .{};
            },
            .missing => {
                self.read_misses +%= 1;
                self.queueGeneration(page);
            },
            .backpressured => {},
            .too_small => self.failRead(page, "chunk page is too small"),
            .failed => self.failRead(page, "storage read failed"),
        }
    }

    fn failRead(_: *Persistence, page: *const Page, reason: []const u8) noreturn {
        std.debug.panic("{s} at chunk {d}, {d}", .{ reason, page.chunk.x, page.chunk.z });
    }

    fn queueGeneration(self: *Persistence, page: *Page) void {
        if (self.deps.blocks.ticketResidentChunk(page.world, page.chunk)) {
            self.completeGenerated(page.world, page.chunk);
            page.* = .{};
            return;
        }
        const index = self.freeGeneration() orelse {
            page.state = .waiting_generation;
            return;
        };
        if (!self.deps.blocks.requestChunkGeneration(page.world, page.chunk)) {
            page.state = .waiting_generation;
            return;
        }
        self.generations[index] = .{ .active = true, .world = page.world, .chunk = page.chunk };
        page.* = .{};
    }

    fn completeGenerated(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) void {
        if (!self.deps.blocks.markGeneratedChunkNew(world, chunk)) return;
        self.generated_chunks +%= 1;
    }

    fn stageDirtyChunks(self: *Persistence, writer: *lightning_rod.plugin_lifecycle.Checkpoint.NamespaceWriter) !void {
        self.staged_chunk_count = 0;
        for (self.deps.blocks.active_resident_indices[0..self.deps.blocks.resident_chunk_count]) |index| {
            if (self.staged_chunk_count == self.staged_chunks.len) return;
            const resident = &self.deps.blocks.resident_chunks[index];
            if (!resident.valid or !(resident.dirty or resident.dirty_section_mask != 0)) continue;
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
        for (0..self.configuration.staging_slice_limit) |_| {
            if (self.staged_chunk_count == self.staged_chunks.len) return true;
            if (lightning_rod.plugin_profiler.tickElapsedNanoseconds()) |elapsed|
                if (elapsed -| started >= self.configuration.staging_budget_ns) return false;
            const index = self.nextUnstagedDirty() orelse return true;
            const resident = &self.deps.blocks.resident_chunks[index];
            const revision = self.deps.blocks.chunkDirtyRevision(resident.world, resident.chunk);
            const bytes = try self.encodeChunk(resident.world, resident.chunk);
            const key = self.chunkKey(resident.world, resident.chunk) orelse return error.StaleWorldHandle;
            if (storage.stagePut(&key, bytes) != .ready) return error.PersistenceUnavailable;
            self.staged_chunks[self.staged_chunk_count] = .{ .world = resident.world, .chunk = resident.chunk, .revision = revision };
            self.staged_chunk_count += 1;
        }
        return self.staged_chunk_count == self.staged_chunks.len or self.nextUnstagedDirty() == null;
    }

    fn nextUnstagedDirty(self: *const Persistence) ?u16 {
        for (self.deps.blocks.active_resident_indices[0..self.deps.blocks.resident_chunk_count]) |index| {
            const resident = &self.deps.blocks.resident_chunks[index];
            if (!resident.valid or !(resident.dirty or resident.dirty_section_mask != 0)) continue;
            if (!self.chunkStaged(resident.world, resident.chunk)) return index;
        }
        return null;
    }

    fn chunkStaged(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) bool {
        for (self.staged_chunks[0..self.staged_chunk_count]) |staged|
            if (staged.world.eql(world) and lightning_rod.geometry.sameChunk(staged.chunk, chunk)) return true;
        return false;
    }

    fn completeCheckpoint(self: *Persistence) void {
        if (!self.checkpoint_pending) return;
        if (self.checkpoint_needs_begin) {
            switch (self.deps.access.beginCheckpoint()) {
                .ready, .pending => self.checkpoint_needs_begin = false,
                .backpressured => return,
                .missing, .too_small, .failed => @panic("failed to begin generated chunk checkpoint"),
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
            .missing, .too_small, .failed => @panic("generated chunk checkpoint failed"),
        }
    }

    fn namespace(self: *const Persistence) lightning_rod.persistence.Namespace {
        return self.deps.access.runtime();
    }

    fn findPage(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ?usize {
        for (self.pages, 0..) |page, index| if (page.state != .free and page.world.eql(world) and lightning_rod.geometry.sameChunk(page.chunk, chunk)) return index;
        return null;
    }

    fn freeGeneration(self: *const Persistence) ?usize {
        for (self.generations, 0..) |generation, index| if (!generation.active) return index;
        return null;
    }

    fn freePage(self: *const Persistence) ?usize {
        for (self.pages, 0..) |page, index| if (page.state == .free) return index;
        return null;
    }

    fn pageBuffer(self: *Persistence, page: usize) []u8 {
        const start = page * lightning_rod.chunk_storage.encoded_size;
        return self.page_bytes[start..][0..lightning_rod.chunk_storage.encoded_size];
    }

    fn encodeChunk(self: *Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ![]u8 {
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

    fn chunkKey(self: *const Persistence, world: lightning_rod.world_identity.Handle, chunk: lightning_rod.geometry.ChunkPos) ?[paging.key_bytes]u8 {
        const record = self.deps.worlds.getConst(world) orelse return null;
        var key: [paging.key_bytes]u8 = undefined;
        _ = paging.encode(&key, .{ .world = record.key, .chunk = chunk });
        return key;
    }

    fn persistedState(self: *Persistence) codec.PersistedState {
        return .{ .worlds = self.deps.worlds, .clock = self.deps.clock, .time = self.deps.time, .random = self.deps.random, .blocks = self.deps.blocks, .living = self.deps.living, .players = self.deps.players, .items = self.deps.items };
    }
};
