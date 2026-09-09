const lightning_rod = @import("lightning_rod");
const block_store = lightning_rod.blocks;
const players = lightning_rod.players;
const sessions = lightning_rod.sessions;
const geometry = lightning_rod.geometry;
const world_clock = lightning_rod.clock;
const std = @import("std");
const registry = lightning_rod.registry_data;
const preallocated = lightning_rod.preallocated;
const plugin_profiler = lightning_rod.plugin_profiler;
const world_limits = lightning_rod.world_limits;
const game_data = lightning_rod.game_data;
const terrain = lightning_rod.terrain;
const light_projection = lightning_rod.light_projection;
const lighting_volume = lightning_rod.lighting_volume;
const diagnostics = lightning_rod.diagnostics;
const world_identity = lightning_rod.world_identity;
const vanilla_lighting = @This();
const vanilla_persistence = @import("vanilla_persistence.zig");

const protocol_sections = light_projection.protocol_section_count;
const world_sections = light_projection.world_section_count;
const all_protocol_sections: u32 =
    (@as(u32, 1) << protocol_sections) - 1;
const top_protocol_section = protocol_sections - 1;
const no_page: u16 = 0;
const source_work_empty_generation: u32 = 0;
const persisted_magic = "LRLT";
const persisted_version: u8 = 1;

const SourceMutation = struct {
    world: world_identity.Handle,
    pos: geometry.BlockPos,
    previous_emission: u8,
    current_emission: u8,
};

const SourceSectionKey = struct {
    world: world_identity.Handle,
    chunk_x: i32,
    chunk_z: i32,
    section: u8,
};

const SourceWorkSection = struct {
    key: SourceSectionKey = .{
        .world = world_identity.invalid,
        .chunk_x = 0,
        .chunk_z = 0,
        .section = 0,
    },
    chunk_index: u16 = 0,
    invalid: [64]u64 = @splat(0),
    settled: [64]u64 = @splat(0),
    pending_planes: [4][64]u64 = @splat(@splat(0)),
    pending_words: [16]u64 = @splat(0),
};

const SourceWorkLookup = struct {
    generation: u32 = source_work_empty_generation,
    key: SourceSectionKey = .{
        .world = world_identity.invalid,
        .chunk_x = 0,
        .chunk_z = 0,
        .section = 0,
    },
    index: u16 = 0,
};

const ChunkState = struct {
    valid: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    position: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    source_revision: u64 = 0,
    revision: u64 = 0,
    sky_mask: u32 = 0,
    sky_full_mask: u32 = 0,
    block_mask: u32 = 0,
    sky_pages: [protocol_sections]u16 =
        [_]u16{no_page} ** protocol_sections,
    block_pages: [protocol_sections]u16 =
        [_]u16{no_page} ** protocol_sections,
    sky_changed_mask: u32 = 0,
    block_changed_mask: u32 = 0,
    dirty: bool = false,
};

pub const Lighting = struct {
    pub const id = "minecraft:lighting";
    pub const Trace = enum { propagation, output };
    pub const Dependencies = struct {
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *players.Players,
        sessions: *sessions.Sessions,
        paging: ?*vanilla_persistence.Persistence,
    };

    pub const maximum_fully_projected_chunks =
        (std.math.maxInt(u16) - 1) / (protocol_sections * 2);

    pub const Configuration = struct {
        source_mutations: usize = 512,

        pub fn validate(self: Configuration) !void {
            if (self.source_mutations == 0 or !std.math.isPowerOfTwo(self.source_mutations))
                return error.InvalidLightingCapacity;
        }
    };

    pub fn requiredLightPages(maximum_cached_chunks: usize) usize {
        return maximum_cached_chunks * protocol_sections * 2;
    }

    started: bool = false,
    mutation_sequence: u64 = 0,
    next_revision: u64 = 1,
    chunks: []ChunkState = &.{},
    chunk_occupancy: []u64 = &.{},
    pages: []align(64) [light_projection.bytes_per_section]u8 = &.{},
    free_pages: []u16 = &.{},
    free_page_count: usize = 0,
    page_pool_initialized: bool = false,
    dirty_chunks: []u16 = &.{},
    dirty_chunk_count: usize = 0,
    rebuild_chunks: []u16 = &.{},
    rebuild_chunk_count: usize = 0,
    rebuild_occupancy: []u64 = &.{},
    block_states: []i32 = &.{},
    attenuation: []u8 = &.{},
    sky_sources: []u8 = &.{},
    sky_frontier: []u8 = &.{},
    block_emission: []u8 = &.{},
    block_sources: []u8 = &.{},
    topology: *lighting_volume.Topology = undefined,
    solver: *lighting_volume.Scratch = undefined,
    sky_result: *lighting_volume.Result = undefined,
    block_result: *lighting_volume.Result = undefined,
    section_scratch: *[light_projection.bytes_per_section]u8 = undefined,
    source_mutations: []SourceMutation = &.{},
    source_work_sections: []SourceWorkSection = &.{},
    source_work_lookup: []SourceWorkLookup = &.{},
    source_work_count: usize = 0,
    source_work_generation: u32 = 0,
    projection_scratch: light_projection.Chunk = undefined,
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, settings: Configuration) !*Lighting {
        try settings.validate();
        const maximum_cached_chunks = deps.blocks.resident_chunks.len;
        if (maximum_cached_chunks == 0 or maximum_cached_chunks > maximum_fully_projected_chunks)
            return error.InvalidLightingCapacity;
        const self = try allocator.create(Lighting);
        self.* = .{ .deps = deps };
        try allocateBuffers(self, allocator, maximum_cached_chunks, settings.source_mutations);
        if (deps.paging) |paging| paging.setDerivedChunkCodec(.{
            .context = self,
            .encode = encodePersistedAdapter,
            .decode = decodePersistedAdapter,
        });
        return self;
    }

    pub fn tick(self: *Lighting, temporary: std.mem.Allocator) void {
        const lighting = self.context();
        var propagation = plugin_profiler.beginTrace(Trace.propagation);
        consumeMutations(lighting);
        propagation.end();
        var output = plugin_profiler.beginTrace(Trace.output);
        self.flushChanges(temporary);
        output.end();
    }

    pub fn flushChanges(self: *Lighting, temporary: std.mem.Allocator) void {
        flushContext(self.context(), temporary);
    }

    pub fn skyLightAt(self: *Lighting, world: world_identity.Handle, position: geometry.BlockPos) u8 {
        return self.context().skyLightAt(world, position);
    }

    pub fn blockLightAt(self: *Lighting, world: world_identity.Handle, position: geometry.BlockPos) u8 {
        return self.context().blockLightAt(world, position);
    }

    pub fn chunk(self: *Lighting, world: world_identity.Handle, position: geometry.ChunkPos) *const light_projection.Chunk {
        return self.context().chunk(world, position);
    }

    pub fn cachedChunk(self: *Lighting, world: world_identity.Handle, position: geometry.ChunkPos) ?*const light_projection.Chunk {
        return self.context().cachedChunk(world, position);
    }

    pub fn encodePersisted(self: *Lighting, world: world_identity.Handle, position: geometry.ChunkPos, output: []u8) ?[]u8 {
        const projection = self.chunk(world, position);
        if (output.len < persisted_magic.len + 1 + protocol_sections * 2) return null;
        @memcpy(output[0..persisted_magic.len], persisted_magic);
        output[persisted_magic.len] = persisted_version;
        var index = persisted_magic.len + 1;
        for (0..protocol_sections) |section| {
            index = encodePersistedSection(output, index, projection.sky_mask, projection.sky[section], section, true) orelse return null;
            index = encodePersistedSection(output, index, projection.block_mask, projection.block[section], section, false) orelse return null;
        }
        return output[0..index];
    }

    pub fn decodePersisted(self: *Lighting, world: world_identity.Handle, position: geometry.ChunkPos, bytes: []const u8) bool {
        if (!validatePersisted(bytes)) return false;
        const resident = self.deps.blocks.residentChunkRef(world, position, self.deps.clock.tick) orelse return false;
        const projection = &self.chunks[resident.index];
        if (occupied(self.chunk_occupancy, resident.index)) {
            if (projection.dirty) return false;
            releaseChunkPages(self, projection);
        }
        projection.* = .{ .valid = true, .world = world, .position = position, .source_revision = resident.entry.content_revision };
        setOccupied(self.chunk_occupancy, resident.index);
        decodePersistedSections(self, projection, bytes, resident.index);
        projection.revision = takeRevision(self);
        return true;
    }

    pub fn releaseResidentChunk(
        self: *Lighting,
        resident_index: u16,
        world: world_identity.Handle,
        position: geometry.ChunkPos,
    ) void {
        std.debug.assert(resident_index < self.chunks.len);
        const projection = &self.chunks[resident_index];
        if (!occupied(self.chunk_occupancy, resident_index) or
            !projection.valid or projection.dirty or
            !projection.world.eql(world) or
            !geometry.sameChunk(projection.position, position)) return;
        discardChunkProjection(self, resident_index);
    }

    fn context(self: *Lighting) Context {
        return .{ .state = self, .clock = self.deps.clock, .blocks = self.deps.blocks };
    }
};

fn encodePersistedAdapter(context: *anyopaque, world: world_identity.Handle, position: geometry.ChunkPos, output: []u8) ?[]u8 {
    const self: *Lighting = @ptrCast(@alignCast(context));
    return self.encodePersisted(world, position, output);
}

fn decodePersistedAdapter(context: *anyopaque, world: world_identity.Handle, position: geometry.ChunkPos, bytes: []const u8) bool {
    const self: *Lighting = @ptrCast(@alignCast(context));
    return self.decodePersisted(world, position, bytes);
}

fn encodePersistedSection(output: []u8, start: usize, mask: u32, section: light_projection.Section, index: usize, sky: bool) ?usize {
    if (start == output.len) return null;
    const bit = @as(u32, 1) << @intCast(index);
    if (mask & bit == 0) {
        output[start] = 0;
        return start + 1;
    }
    const bytes = section.bytes() orelse {
        if (!sky) return null;
        output[start] = 1;
        return start + 1;
    };
    if (output.len - start - 1 < bytes.len) return null;
    output[start] = 2;
    @memcpy(output[start + 1 ..][0..bytes.len], bytes);
    return start + 1 + bytes.len;
}

fn validatePersisted(bytes: []const u8) bool {
    if (bytes.len < persisted_magic.len + 1 or !std.mem.eql(u8, bytes[0..persisted_magic.len], persisted_magic) or bytes[persisted_magic.len] != persisted_version)
        return false;
    var index = persisted_magic.len + 1;
    for (0..protocol_sections) |_| {
        index = validatePersistedSection(bytes, index, true) orelse return false;
        index = validatePersistedSection(bytes, index, false) orelse return false;
    }
    return index == bytes.len;
}

fn validatePersistedSection(bytes: []const u8, start: usize, sky: bool) ?usize {
    if (start == bytes.len) return null;
    return switch (bytes[start]) {
        0 => start + 1,
        1 => if (sky) start + 1 else null,
        2 => if (bytes.len - start - 1 >= light_projection.bytes_per_section)
            start + 1 + light_projection.bytes_per_section
        else
            null,
        else => null,
    };
}

fn decodePersistedSections(state: *Lighting, projection: *ChunkState, bytes: []const u8, chunk_index: u16) void {
    var index = persisted_magic.len + 1;
    for (0..protocol_sections) |section| {
        index = decodePersistedSection(state, projection, bytes, index, section, true, chunk_index);
        index = decodePersistedSection(state, projection, bytes, index, section, false, chunk_index);
    }
    std.debug.assert(index == bytes.len);
}

fn decodePersistedSection(state: *Lighting, projection: *ChunkState, bytes: []const u8, start: usize, section: usize, sky: bool, chunk_index: u16) usize {
    const tag = bytes[start];
    if (tag == 0) return start + 1;
    const bit = @as(u32, 1) << @intCast(section);
    if (sky) projection.sky_mask |= bit else projection.block_mask |= bit;
    if (tag == 1) {
        std.debug.assert(sky);
        projection.sky_full_mask |= bit;
        return start + 1;
    }
    const handle = allocatePage(state, chunk_index);
    const pages = if (sky) &projection.sky_pages else &projection.block_pages;
    pages[section] = handle;
    @memcpy(&state.pages[handle - 1], bytes[start + 1 ..][0..light_projection.bytes_per_section]);
    return start + 1 + light_projection.bytes_per_section;
}

const Context = struct {
    state: *Lighting,
    clock: *world_clock.Clock,
    blocks: *block_store.Blocks,

    pub fn skyLightAt(self: Context, world: world_identity.Handle, pos: geometry.BlockPos) u8 {
        const section = block_store.sectionIndexForY(pos.y) orelse return 0;
        const resident = self.blocks.residentChunk(
            world,
            geometry.chunkForBlock(pos),
        ) orelse return 0;
        const chunk_index = self.ensureChunk(world, resident.chunk);
        const projection = &self.state.chunks[chunk_index];
        const protocol_section = section + 1;
        const handle = projection.sky_pages[protocol_section];
        if (handle != no_page)
            return getNibble(
                &self.state.pages[handle - 1],
                block_store.localBlockIndexForPosition(pos),
            );
        return if (projection.sky_full_mask &
            (@as(u32, 1) << @intCast(protocol_section)) != 0) 15 else 0;
    }

    pub fn blockLightAt(self: Context, world: world_identity.Handle, pos: geometry.BlockPos) u8 {
        const section = block_store.sectionIndexForY(pos.y) orelse return 0;
        const resident = self.blocks.residentChunk(
            world,
            geometry.chunkForBlock(pos),
        ) orelse return 0;
        const chunk_index = self.ensureChunk(world, resident.chunk);
        const handle = self.state.chunks[chunk_index]
            .block_pages[section + 1];
        if (handle == no_page) return 0;
        return getNibble(
            &self.state.pages[handle - 1],
            block_store.localBlockIndexForPosition(pos),
        );
    }

    pub fn chunk(
        self: Context,
        world: world_identity.Handle,
        position: geometry.ChunkPos,
    ) *const light_projection.Chunk {
        return chunkView(self.state, self.ensureChunk(world, position));
    }

    pub fn cachedChunk(
        self: Context,
        world: world_identity.Handle,
        position: geometry.ChunkPos,
    ) ?*const light_projection.Chunk {
        const resident = self.blocks.residentChunkRef(
            world,
            position,
            self.clock.tick,
        ) orelse return null;
        const projection = &self.state.chunks[resident.index];
        if (!occupied(self.state.chunk_occupancy, resident.index) or
            !projection.valid or
            !projection.world.eql(world) or
            !geometry.sameChunk(projection.position, position) or
            projection.source_revision != resident.entry.content_revision)
            return null;
        return chunkView(self.state, resident.index);
    }

    fn ensureChunk(self: Context, world: world_identity.Handle, position: geometry.ChunkPos) u16 {
        const resident = self.blocks.generatedHeightChunkRef(
            world,
            position,
            self.clock.tick,
        );
        const projection = &self.state.chunks[resident.index];
        if (occupied(self.state.chunk_occupancy, resident.index) and
            projection.valid and projection.world.eql(world) and
            geometry.sameChunk(projection.position, position) and
            projection.source_revision == resident.entry.content_revision)
            return resident.index;

        const was_same = occupied(
            self.state.chunk_occupancy,
            resident.index,
        ) and projection.valid and projection.world.eql(world) and
            geometry.sameChunk(projection.position, position);
        if (!was_same) {
            releaseChunkPages(self.state, projection);
            projection.* = .{
                .valid = true,
                .world = world,
                .position = position,
            };
            setOccupied(self.state.chunk_occupancy, resident.index);
        }
        rebuildChunk(self, resident.index, resident.entry, was_same);
        if (!was_same)
            refreshProjectedNeighbors(self, world, resident.entry.chunk);
        return resident.index;
    }
};

fn flushContext(service: Context, temporary: std.mem.Allocator) void {
    emitDirtyChunks(service.state, temporary);
    reclaimDetachedChunks(service);
}

fn emitDirtyChunks(state: *Lighting, temporary: std.mem.Allocator) void {
    for (state.dirty_chunks[0..state.dirty_chunk_count]) |index| {
        const chunk = &state.chunks[index];
        if (chunk.sky_changed_mask != 0 or chunk.block_changed_mask != 0) {
            sendLight(state, temporary, chunk.world, .{
                .chunk = chunkView(state, index),
                .sky_changed_mask = chunk.sky_changed_mask,
                .block_changed_mask = chunk.block_changed_mask,
            });
        }
        chunk.sky_changed_mask = 0;
        chunk.block_changed_mask = 0;
        chunk.dirty = false;
    }
    state.dirty_chunk_count = 0;
}

fn sendLight(
    state: *Lighting,
    temporary: std.mem.Allocator,
    world: world_identity.Handle,
    update: light_projection.Update,
) void {
    const recipients = temporary.alloc(players.Session, state.deps.players.activeSlots().len) catch return;
    var count: usize = 0;
    for (state.deps.players.activeSlots()) |slot| {
        if (!state.deps.players.records[slot].world.eql(world)) continue;
        recipients[count] = state.deps.players.session(slot) orelse continue;
        count += 1;
    }
    const Arguments = struct { update: light_projection.Update };
    const Encoder = struct {
        fn encode(raw: *const anyopaque, protocol: sessions.Protocol, output: []u8) ?sessions.EncodedPacket {
            const arguments: *const Arguments = @ptrCast(@alignCast(raw));
            const payload = lightning_rod.protocol_versions.staticCall(
                "encodeUpdateLight",
                protocol.value,
                .{ output, arguments.update },
            ) catch return null;
            if (payload.len == 0) return null;
            return .{ .payload = payload };
        }
    };
    const arguments = Arguments{ .update = update };
    _ = state.deps.sessions.tryFanout(temporary, recipients[0..count], .other, .{
        .phase = .play,
        .maximum_payload_bytes = lightning_rod.chunk_packet.maximum_payload_bytes,
        .context = &arguments,
        .encode = Encoder.encode,
    }) catch {};
}

fn reclaimDetachedChunks(service: Context) void {
    for (service.state.chunks, 0..) |*projection, index| {
        if (!occupied(service.state.chunk_occupancy, index) or
            !projection.valid or projection.dirty) continue;
        const resident = service.blocks.residentChunkRef(
            projection.world,
            projection.position,
            service.clock.tick,
        ) orelse {
            discardChunkProjection(service.state, @intCast(index));
            continue;
        };
        if (resident.index != index)
            discardChunkProjection(service.state, @intCast(index));
    }
}

fn allocateBuffers(state: *Lighting, allocator: std.mem.Allocator, maximum_cached_chunks: usize, source_mutations: usize) !void {
    const light_pages = Lighting.requiredLightPages(maximum_cached_chunks);
    if (light_pages >= std.math.maxInt(u16)) return error.InvalidLightingCapacity;
    state.chunks = try preallocated.alloc(
        ChunkState,
        allocator,
        maximum_cached_chunks,
    );
    @memset(state.chunks, .{});
    state.chunk_occupancy = try preallocated.alloc(
        u64,
        allocator,
        (maximum_cached_chunks + 63) / 64,
    );
    @memset(state.chunk_occupancy, 0);
    state.pages = try preallocated.alignedAlloc(
        [light_projection.bytes_per_section]u8,
        allocator,
        .@"64",
        light_pages,
    );
    state.free_pages = try preallocated.alloc(u16, allocator, light_pages);
    state.dirty_chunks = try preallocated.alloc(
        u16,
        allocator,
        maximum_cached_chunks,
    );
    state.rebuild_chunks = try preallocated.alloc(
        u16,
        allocator,
        maximum_cached_chunks,
    );
    state.rebuild_occupancy = try preallocated.alloc(
        u64,
        allocator,
        (maximum_cached_chunks + 63) / 64,
    );
    @memset(state.rebuild_occupancy, 0);
    try allocateSolverBuffers(state, allocator, source_mutations);
}

fn allocateSolverBuffers(state: *Lighting, allocator: std.mem.Allocator, source_mutations: usize) !void {
    state.block_states = try preallocated.alloc(
        i32,
        allocator,
        lighting_volume.cell_count,
    );
    state.attenuation = try preallocated.alloc(
        u8,
        allocator,
        lighting_volume.cell_count,
    );
    state.sky_sources = try preallocated.alloc(
        u8,
        allocator,
        lighting_volume.cell_count,
    );
    state.sky_frontier = try preallocated.alloc(
        u8,
        allocator,
        lighting_volume.cell_count,
    );
    state.block_sources = try preallocated.alloc(
        u8,
        allocator,
        lighting_volume.cell_count,
    );
    state.block_emission = try preallocated.alloc(
        u8,
        allocator,
        lighting_volume.cell_count,
    );
    state.topology = try preallocated.create(lighting_volume.Topology, allocator);
    state.solver = try preallocated.create(lighting_volume.Scratch, allocator);
    state.sky_result = try preallocated.create(lighting_volume.Result, allocator);
    state.block_result = try preallocated.create(lighting_volume.Result, allocator);
    state.section_scratch = try preallocated.create(
        [light_projection.bytes_per_section]u8,
        allocator,
    );
    state.source_mutations = try preallocated.alloc(
        SourceMutation,
        allocator,
        source_mutations,
    );
    state.source_work_sections = try preallocated.alloc(
        SourceWorkSection,
        allocator,
        source_mutations * 32,
    );
    state.source_work_lookup = try preallocated.alloc(
        SourceWorkLookup,
        allocator,
        source_mutations * 64,
    );
    @memset(state.source_work_lookup, .{});
}

fn consumeMutations(service: Context) void {
    const state = service.state;
    const latest = service.blocks.blockMutationSequence();
    if (!state.started) {
        state.started = true;
        state.mutation_sequence = latest;
        return;
    }
    if (latest == state.mutation_sequence) return;
    const batch = collectMutations(service, latest);
    state.mutation_sequence = latest;
    if (batch.dense) {
        rebuildMutations(service, batch.first, latest, batch.history_lost);
    } else if (batch.source_count != 0) {
        updateBlockSourcesIncrementally(service, state.source_mutations[0..batch.source_count]);
    }
    synchronizeProjectionRevisions(service, batch.first, latest);
}

const MutationBatch = struct {
    first: u64,
    source_count: usize,
    dense: bool,
    history_lost: bool,
};

fn collectMutations(service: Context, latest: u64) MutationBatch {
    const state = service.state;
    const available = @min(
        latest,
        @as(u64, service.blocks.block_mutations.len),
    );
    const first_sequence = @max(
        state.mutation_sequence +| 1,
        latest - available + 1,
    );
    const history_was_lost =
        latest -| state.mutation_sequence >
        service.blocks.block_mutations.len;
    var dense = history_was_lost;
    var source_mutation_count: usize = 0;
    const mutation_count: usize = @intCast(latest - first_sequence + 1);
    std.debug.assert(mutation_count <= service.blocks.block_mutations.len);
    for (0..mutation_count) |offset| {
        const sequence = first_sequence + offset;
        const mutation = service.blocks.blockMutation(sequence);
        const previous = game_data.blockInfo(mutation.previous_state);
        const current = game_data.blockInfo(mutation.block_state);
        const same_attenuation =
            previous.filtered_light == current.filtered_light;
        const same_faces = std.meta.eql(
            game_data.lightFaceOcclusion(mutation.previous_state).*,
            game_data.lightFaceOcclusion(mutation.block_state).*,
        );
        if (!same_attenuation or !same_faces) {
            dense = true;
            continue;
        }
        if (previous.emitted_light == current.emitted_light) continue;
        if (source_mutation_count == state.source_mutations.len) {
            dense = true;
            continue;
        }
        state.source_mutations[source_mutation_count] = .{
            .world = mutation.world,
            .pos = mutation.pos,
            .previous_emission = previous.emitted_light,
            .current_emission = current.emitted_light,
        };
        source_mutation_count += 1;
    }
    return .{ .first = first_sequence, .source_count = source_mutation_count, .dense = dense, .history_lost = history_was_lost };
}

fn rebuildMutations(service: Context, first: u64, latest: u64, history_lost: bool) void {
    const state = service.state;
    scheduleDenseMutationRebuilds(service, first, latest, history_lost);
    for (state.rebuild_chunks[0..state.rebuild_chunk_count]) |index|
        invalidateChunkLight(state, index);
    for (0..2) |_| {
        for (state.rebuild_chunks[0..state.rebuild_chunk_count]) |index| {
            const projection = &state.chunks[index];
            if (!occupied(state.chunk_occupancy, index) or !projection.valid) continue;
            const resident = service.blocks.residentChunk(projection.world, projection.position) orelse continue;
            rebuildChunk(service, index, resident, true);
        }
    }
}

fn scheduleDenseMutationRebuilds(
    service: Context,
    first_sequence: u64,
    latest: u64,
    history_was_lost: bool,
) void {
    const state = service.state;
    state.rebuild_chunk_count = 0;
    @memset(state.rebuild_occupancy, 0);
    if (history_was_lost) {
        for (state.chunks, 0..) |chunk, index| {
            if (!occupied(state.chunk_occupancy, index) or !chunk.valid)
                continue;
            setOccupied(state.rebuild_occupancy, index);
            state.rebuild_chunks[state.rebuild_chunk_count] =
                @intCast(index);
            state.rebuild_chunk_count += 1;
        }
        return;
    }

    const mutation_count: usize = @intCast(latest - first_sequence + 1);
    std.debug.assert(mutation_count <= service.blocks.block_mutations.len);
    for (0..mutation_count) |offset| {
        const sequence = first_sequence + offset;
        const mutation = service.blocks.blockMutation(sequence);
        const previous = game_data.blockInfo(mutation.previous_state);
        const current = game_data.blockInfo(mutation.block_state);
        if (previous.emitted_light == current.emitted_light and
            previous.filtered_light == current.filtered_light and
            std.meta.eql(
                game_data.lightFaceOcclusion(mutation.previous_state).*,
                game_data.lightFaceOcclusion(mutation.block_state).*,
            ))
            continue;
        const center = geometry.chunkForBlock(mutation.pos);
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1)
                scheduleResidentChunk(service, mutation.world, .{
                    .x = center.x + dx,
                    .z = center.z + dz,
                });
        }
    }
}

fn synchronizeProjectionRevisions(
    service: Context,
    first_sequence: u64,
    latest: u64,
) void {
    const mutation_count: usize = @intCast(latest - first_sequence + 1);
    std.debug.assert(mutation_count <= service.blocks.block_mutations.len);
    for (0..mutation_count) |offset| {
        const sequence = first_sequence + offset;
        const mutation = service.blocks.blockMutation(sequence);
        const resident = service.blocks.residentChunkRef(
            mutation.world,
            geometry.chunkForBlock(mutation.pos),
            service.clock.tick,
        ) orelse continue;
        const index = resident.index;
        if (!occupied(service.state.chunk_occupancy, index)) continue;
        const projection = &service.state.chunks[index];
        if (!projection.valid or !projection.world.eql(mutation.world) or
            !geometry.sameChunk(projection.position, resident.entry.chunk))
            continue;
        projection.source_revision = resident.entry.content_revision;
    }
}

const NeighborStep = struct {
    dx: i32,
    dy: i16,
    dz: i32,
    source_face: usize,
    target_face: usize,
};

const neighbor_steps = [_]NeighborStep{
    .{ .dx = -1, .dy = 0, .dz = 0, .source_face = 0, .target_face = 1 },
    .{ .dx = 1, .dy = 0, .dz = 0, .source_face = 1, .target_face = 0 },
    .{ .dx = 0, .dy = -1, .dz = 0, .source_face = 2, .target_face = 3 },
    .{ .dx = 0, .dy = 1, .dz = 0, .source_face = 3, .target_face = 2 },
    .{ .dx = 0, .dy = 0, .dz = -1, .source_face = 4, .target_face = 5 },
    .{ .dx = 0, .dy = 0, .dz = 1, .source_face = 5, .target_face = 4 },
};

fn updateBlockSourcesIncrementally(
    service: Context,
    mutations: []const SourceMutation,
) void {
    beginSourceWork(service.state);

    for (mutations) |mutation| {
        if (mutation.previous_emission <= mutation.current_emission)
            continue;
        const cell = sourceCell(service, mutation.world, mutation.pos, true) orelse continue;
        const old_level = blockLightAtCell(service.state, cell);
        if (old_level != 0)
            setPendingLevel(cell.section, cell.local_index, old_level);
    }
    invalidateRemovedSources(service);
    relightInvalidatedCells(service);

    clearSourceFrontier(service.state);
    for (mutations) |mutation| {
        const block_state =
            service.blocks.blockAtIfResident(mutation.world, mutation.pos) orelse continue;
        const emitted = game_data.blockInfo(block_state).emitted_light;
        if (emitted == 0) continue;
        const cell = sourceCell(service, mutation.world, mutation.pos, true) orelse continue;
        if (emitted > blockLightAtCell(service.state, cell))
            setPendingLevel(cell.section, cell.local_index, emitted);
    }
    propagateAddedSources(service);
    compactSourceWorkPages(service.state);
}

const SourceCell = struct {
    section: *SourceWorkSection,
    local_index: u16,
};

fn beginSourceWork(state: *Lighting) void {
    state.source_work_count = 0;
    state.source_work_generation +%= 1;
    if (state.source_work_generation == source_work_empty_generation) {
        @memset(state.source_work_lookup, .{});
        state.source_work_generation = 1;
    }
}

fn sourceCell(
    service: Context,
    world: world_identity.Handle,
    pos: geometry.BlockPos,
    create: bool,
) ?SourceCell {
    const section = block_store.sectionIndexForY(pos.y) orelse return null;
    const key = SourceSectionKey{
        .world = world,
        .chunk_x = geometry.chunkCoord(pos.x),
        .chunk_z = geometry.chunkCoord(pos.z),
        .section = @intCast(section),
    };
    const work = findSourceWorkSection(service, key, create) orelse
        return null;
    return .{
        .section = work,
        .local_index = block_store.localBlockIndexForPosition(pos),
    };
}

fn findSourceWorkSection(
    service: Context,
    key: SourceSectionKey,
    create: bool,
) ?*SourceWorkSection {
    const state = service.state;
    const mask = state.source_work_lookup.len - 1;
    var lookup_index = sourceSectionHash(key) & mask;
    for (0..state.source_work_lookup.len) |_| {
        const lookup = &state.source_work_lookup[lookup_index];
        if (lookup.generation != state.source_work_generation) {
            if (!create) return null;
            if (state.source_work_count == state.source_work_sections.len)
                diagnostics.panic(
                    "incremental lighting section capacity exhausted",
                    &.{diagnostics.integer(state.source_work_count)},
                );
            const resident = service.blocks.residentChunkRef(
                key.world,
                .{ .x = key.chunk_x, .z = key.chunk_z },
                service.clock.tick,
            ) orelse return null;
            if (!occupied(state.chunk_occupancy, resident.index))
                return null;
            const projection = &state.chunks[resident.index];
            if (!projection.valid or !projection.world.eql(key.world) or
                !geometry.sameChunk(projection.position, resident.entry.chunk))
                return null;

            const index = state.source_work_count;
            state.source_work_count += 1;
            state.source_work_sections[index] = .{
                .key = key,
                .chunk_index = resident.index,
            };
            lookup.* = .{
                .generation = state.source_work_generation,
                .key = key,
                .index = @intCast(index),
            };
            return &state.source_work_sections[index];
        }
        if (sameSourceSection(lookup.key, key))
            return &state.source_work_sections[lookup.index];
        lookup_index = (lookup_index + 1) & mask;
    }
    diagnostics.panic("incremental lighting lookup capacity exhausted", &.{});
}

fn sourceSectionHash(key: SourceSectionKey) usize {
    var value: u64 =
        @as(u32, @bitCast(key.chunk_x)) |
        (@as(u64, @as(u32, @bitCast(key.chunk_z))) << 32);
    value ^= @as(u64, key.section) *% 0x9e37_79b9_7f4a_7c15;
    value ^= @as(u64, @as(u32, @bitCast(key.world))) *% 0xd6e8_feb8_6659_fd93;
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    value ^= value >> 31;
    return @intCast(value);
}

fn sameSourceSection(a: SourceSectionKey, b: SourceSectionKey) bool {
    return a.world.eql(b.world) and a.chunk_x == b.chunk_x and
        a.chunk_z == b.chunk_z and
        a.section == b.section;
}

fn pendingLevel(section: *const SourceWorkSection, local_index: u16) u8 {
    const word_index: usize = local_index >> 6;
    const bit = @as(u64, 1) << @intCast(local_index & 63);
    var level: u8 = 0;
    inline for (0..4) |plane| {
        if (section.pending_planes[plane][word_index] & bit != 0)
            level |= @as(u8, 1) << plane;
    }
    return level;
}

fn pendingMask(
    section: *const SourceWorkSection,
    level: u8,
    word_index: usize,
) u64 {
    var mask: u64 = std.math.maxInt(u64);
    inline for (0..4) |plane| {
        if (level & (@as(u8, 1) << plane) != 0)
            mask &= section.pending_planes[plane][word_index]
        else
            mask &= ~section.pending_planes[plane][word_index];
    }
    return mask;
}

fn setPendingLevel(
    section: *SourceWorkSection,
    local_index: u16,
    level: u8,
) void {
    std.debug.assert(level != 0 and level <= 15);
    const old_level = pendingLevel(section, local_index);
    if (old_level >= level) return;
    const word_index: usize = local_index >> 6;
    const bit = @as(u64, 1) << @intCast(local_index & 63);
    if (old_level != 0) {
        inline for (0..4) |plane|
            section.pending_planes[plane][word_index] &= ~bit;
        if (pendingMask(section, old_level, word_index) == 0)
            section.pending_words[old_level] &=
                ~(@as(u64, 1) << @intCast(word_index));
    }
    inline for (0..4) |plane| {
        if (level & (@as(u8, 1) << plane) != 0)
            section.pending_planes[plane][word_index] |= bit;
    }
    section.pending_words[level] |=
        @as(u64, 1) << @intCast(word_index);
}

fn takePendingWord(
    section: *SourceWorkSection,
    level: u8,
    word_index: usize,
) u64 {
    const mask = pendingMask(section, level, word_index);
    inline for (0..4) |plane|
        section.pending_planes[plane][word_index] &= ~mask;
    section.pending_words[level] &=
        ~(@as(u64, 1) << @intCast(word_index));
    return mask;
}

fn clearSourceFrontier(state: *Lighting) void {
    for (state.source_work_sections[0..state.source_work_count]) |*section| {
        @memset(&section.settled, 0);
        @memset(&section.pending_planes, @splat(0));
        @memset(&section.pending_words, 0);
    }
}

fn invalidateRemovedSources(service: Context) void {
    const state = service.state;
    var level: u8 = 15;
    while (level != 0) : (level -= 1) {
        var section_index: usize = 0;
        while (section_index < state.source_work_count) : (section_index += 1) {
            const section = &state.source_work_sections[section_index];
            while (section.pending_words[level] != 0) {
                const word_index: usize =
                    @intCast(@ctz(section.pending_words[level]));
                var cells = takePendingWord(section, level, word_index);
                while (cells != 0) {
                    const bit_index: u6 = @intCast(@ctz(cells));
                    cells &= cells - 1;
                    const local_index: u16 =
                        @intCast(word_index * 64 + bit_index);
                    if (bitSet(&section.invalid, local_index)) continue;
                    const current = blockLightAtCell(state, .{
                        .section = section,
                        .local_index = local_index,
                    });
                    if (current == 0) continue;
                    invalidateSourceCell(service, section, local_index, current);
                }
            }
        }
    }
}

fn invalidateSourceCell(
    service: Context,
    section: *SourceWorkSection,
    local_index: u16,
    current: u8,
) void {
    setBit(&section.invalid, local_index);
    setBlockLightAtCell(service.state, section, local_index, 0);
    const pos = sourcePosition(section.key, local_index);
    for (neighbor_steps) |step| {
        const target_pos = offsetPosition(pos, step);
        const target = sourceCell(service, section.key.world, target_pos, true) orelse
            continue;
        if (bitSet(&target.section.invalid, target.local_index)) continue;
        const target_level = blockLightAtCell(service.state, target);
        if (target_level == 0) continue;
        const target_state = service.blocks.blockAtIfResident(section.key.world, target_pos) orelse
            continue;
        if (game_data.blockInfo(target_state).emitted_light >= target_level) continue;
        if (propagatedLevel(
            service,
            section.key.world,
            pos,
            current,
            target_pos,
            step,
        ) == target_level)
            setPendingLevel(target.section, target.local_index, target_level);
    }
}

fn relightInvalidatedCells(service: Context) void {
    const state = service.state;
    clearSourceFrontier(state);
    var section_index: usize = 0;
    while (section_index < state.source_work_count) : (section_index += 1) {
        const section = &state.source_work_sections[section_index];
        for (section.invalid, 0..) |word_bits, word_index| {
            var cells = word_bits;
            while (cells != 0) {
                const bit_index: u6 = @intCast(@ctz(cells));
                cells &= cells - 1;
                const local_index: u16 =
                    @intCast(word_index * 64 + bit_index);
                const pos = sourcePosition(section.key, local_index);
                const block_state =
                    service.blocks.blockAtIfResident(section.key.world, pos) orelse continue;
                var desired: u8 =
                    game_data.blockInfo(block_state).emitted_light;
                for (neighbor_steps) |step| {
                    const neighbor_pos = offsetPosition(pos, step);
                    const neighbor = sourceCell(
                        service,
                        section.key.world,
                        neighbor_pos,
                        true,
                    ) orelse continue;
                    if (bitSet(
                        &neighbor.section.invalid,
                        neighbor.local_index,
                    ))
                        continue;
                    const neighbor_level =
                        blockLightAtCell(state, neighbor);
                    if (neighbor_level == 0) continue;
                    desired = @max(
                        desired,
                        propagatedLevel(
                            service,
                            section.key.world,
                            neighbor_pos,
                            neighbor_level,
                            pos,
                            reverseStep(step),
                        ),
                    );
                }
                if (desired != 0)
                    setPendingLevel(section, local_index, desired);
            }
        }
    }
    propagateFrontier(service, true);
}

fn propagateAddedSources(service: Context) void {
    propagateFrontier(service, false);
}

fn propagateFrontier(service: Context, invalid_only: bool) void {
    const state = service.state;
    var level: u8 = 15;
    while (level != 0) : (level -= 1) {
        var section_index: usize = 0;
        while (section_index < state.source_work_count) : (section_index += 1) {
            const section = &state.source_work_sections[section_index];
            while (section.pending_words[level] != 0) {
                const word_index: usize =
                    @intCast(@ctz(section.pending_words[level]));
                var cells = takePendingWord(section, level, word_index);
                while (cells != 0) {
                    const bit_index: u6 = @intCast(@ctz(cells));
                    cells &= cells - 1;
                    propagateCell(service, section, @intCast(word_index * 64 + bit_index), level, invalid_only);
                }
            }
        }
    }
}

fn propagateCell(service: Context, section: *SourceWorkSection, local_index: u16, level: u8, invalid_only: bool) void {
    if (bitSet(&section.settled, local_index)) return;
    if (invalid_only and !bitSet(&section.invalid, local_index)) return;
    setBit(&section.settled, local_index);
    const cell = SourceCell{ .section = section, .local_index = local_index };
    const current = blockLightAtCell(service.state, cell);
    if (current < level) setBlockLightAtCell(service.state, section, local_index, level);
    const propagation_level = @max(current, level);
    if (propagation_level <= 1) return;
    const pos = sourcePosition(section.key, local_index);
    for (neighbor_steps) |step| {
        const target_pos = offsetPosition(pos, step);
        const target = sourceCell(service, section.key.world, target_pos, true) orelse continue;
        if (invalid_only and !bitSet(&target.section.invalid, target.local_index)) continue;
        if (bitSet(&target.section.settled, target.local_index)) continue;
        const candidate = propagatedLevel(service, section.key.world, pos, propagation_level, target_pos, step);
        if (candidate > blockLightAtCell(service.state, target))
            setPendingLevel(target.section, target.local_index, candidate);
    }
}

fn propagatedLevel(
    service: Context,
    world: world_identity.Handle,
    source_pos: geometry.BlockPos,
    source_level: u8,
    target_pos: geometry.BlockPos,
    step: NeighborStep,
) u8 {
    if (source_level <= 1) return 0;
    const source_state =
        service.blocks.blockAtIfResident(world, source_pos) orelse return 0;
    const target_state =
        service.blocks.blockAtIfResident(world, target_pos) orelse return 0;
    if (game_data.blockInfo(source_state).emitted_light == 0) {
        const source_faces = game_data.lightFaceOcclusion(source_state);
        const target_faces = game_data.lightFaceOcclusion(target_state);
        if (lighting_volume.facesSeal(
            source_faces[step.source_face],
            target_faces[step.target_face],
        ))
            return 0;
    }
    const loss = @max(
        @as(u8, 1),
        game_data.blockInfo(target_state).filtered_light,
    );
    return source_level -| loss;
}

fn reverseStep(step: NeighborStep) NeighborStep {
    return .{
        .dx = -step.dx,
        .dy = -step.dy,
        .dz = -step.dz,
        .source_face = step.target_face,
        .target_face = step.source_face,
    };
}

fn offsetPosition(pos: geometry.BlockPos, step: NeighborStep) geometry.BlockPos {
    return .{
        .x = pos.x + step.dx,
        .y = pos.y + step.dy,
        .z = pos.z + step.dz,
    };
}

fn sourcePosition(key: SourceSectionKey, local_index: u16) geometry.BlockPos {
    return .{
        .x = key.chunk_x * 16 + @as(i32, local_index & 15),
        .y = @intCast(
            @as(i32, world_limits.min_y) +
                @as(i32, key.section) * 16 +
                @as(i32, (local_index >> 8) & 15),
        ),
        .z = key.chunk_z * 16 +
            @as(i32, (local_index >> 4) & 15),
    };
}

fn blockLightAtCell(state: *const Lighting, cell: SourceCell) u8 {
    const handle = state.chunks[cell.section.chunk_index]
        .block_pages[@as(usize, cell.section.key.section) + 1];
    if (handle == no_page) return 0;
    return getNibble(
        &state.pages[handle - 1],
        cell.local_index,
    );
}

fn setBlockLightAtCell(
    state: *Lighting,
    section: *SourceWorkSection,
    local_index: u16,
    level: u8,
) void {
    const chunk = &state.chunks[section.chunk_index];
    const protocol_section = @as(usize, section.key.section) + 1;
    var handle = chunk.block_pages[protocol_section];
    if (handle == no_page) {
        if (level == 0) return;
        handle = allocatePage(state, section.chunk_index);
        chunk.block_pages[protocol_section] = handle;
        chunk.block_mask |=
            @as(u32, 1) << @intCast(protocol_section);
    }
    const page = &state.pages[handle - 1];
    if (getNibble(page, local_index) == level) return;
    setNibble(page, local_index, level);
    const bit = @as(u32, 1) << @intCast(protocol_section);
    if (chunk.block_changed_mask & bit == 0) {
        chunk.block_changed_mask |= bit;
        chunk.revision = takeRevision(state);
        markDirty(state, section.chunk_index);
    }
}

fn compactSourceWorkPages(state: *Lighting) void {
    for (state.source_work_sections[0..state.source_work_count]) |*section| {
        const chunk = &state.chunks[section.chunk_index];
        const protocol_section = @as(usize, section.key.section) + 1;
        const handle = chunk.block_pages[protocol_section];
        if (handle == no_page) continue;
        if (!allBytes(&state.pages[handle - 1], 0)) continue;
        releasePage(state, handle);
        chunk.block_pages[protocol_section] = no_page;
        chunk.block_mask &=
            ~(@as(u32, 1) << @intCast(protocol_section));
    }
}

fn bitSet(words: *const [64]u64, local_index: u16) bool {
    return words[local_index >> 6] &
        (@as(u64, 1) << @intCast(local_index & 63)) != 0;
}

fn setBit(words: *[64]u64, local_index: u16) void {
    words[local_index >> 6] |=
        @as(u64, 1) << @intCast(local_index & 63);
}

fn refreshProjectedNeighbors(
    service: Context,
    world: world_identity.Handle,
    center: geometry.ChunkPos,
) void {
    const boundaries = [_]HorizontalBoundary{
        .{
            .dx = -1,
            .dz = 0,
            .source_face = 0,
            .target_face = 1,
        },
        .{
            .dx = 1,
            .dz = 0,
            .source_face = 1,
            .target_face = 0,
        },
        .{
            .dx = 0,
            .dz = -1,
            .source_face = 4,
            .target_face = 5,
        },
        .{
            .dx = 0,
            .dz = 1,
            .source_face = 5,
            .target_face = 4,
        },
    };
    const source_ref = service.blocks.residentChunkRef(
        world,
        center,
        service.clock.tick,
    ) orelse return;
    for (boundaries) |boundary| {
        const position = geometry.ChunkPos{
            .x = center.x + boundary.dx,
            .z = center.z + boundary.dz,
        };
        const resident = service.blocks.residentChunkRef(
            world,
            position,
            service.clock.tick,
        ) orelse continue;
        const index = resident.index;
        const projection = &service.state.chunks[index];
        if (!occupied(service.state.chunk_occupancy, index) or
            !projection.valid or !projection.world.eql(world) or
            !geometry.sameChunk(projection.position, position) or
            !boundaryCanIncreaseLight(
                service,
                source_ref,
                resident,
                boundary,
            ))
            continue;
        rebuildChunk(service, index, resident.entry, true);
    }
}

const HorizontalBoundary = struct {
    dx: i32,
    dz: i32,
    source_face: usize,
    target_face: usize,
};

const BoundaryCoordinates = struct {
    source_x: i32,
    target_x: i32,
    source_z: i32,
    target_z: i32,
};

fn boundaryCanIncreaseLight(
    service: Context,
    source: block_store.GeneratedHeightRef,
    target: block_store.GeneratedHeightRef,
    boundary: HorizontalBoundary,
) bool {
    const source_light = &service.state.chunks[source.index];
    const target_light = &service.state.chunks[target.index];
    for (0..world_sections) |section| {
        if (uniformBoundaryCanIncrease(
            service,
            source,
            target,
            source_light,
            target_light,
            boundary,
            section,
        )) |increases| {
            if (increases) return true;
            continue;
        }
        if (boundarySectionCanIncrease(service, source, target, source_light, target_light, boundary, section)) return true;
    }
    return false;
}

fn boundarySectionCanIncrease(
    service: Context,
    source: block_store.GeneratedHeightRef,
    target: block_store.GeneratedHeightRef,
    source_light: *const ChunkState,
    target_light: *const ChunkState,
    boundary: HorizontalBoundary,
    section: usize,
) bool {
    for (0..16) |local_y| {
        const y = section * 16 + local_y;
        for (0..16) |axis| {
            const coordinates = boundaryCoordinates(boundary, @intCast(axis));
            const source_pos = boundaryBlockPosition(source.entry.chunk, coordinates.source_x, coordinates.source_z, y);
            const target_pos = boundaryBlockPosition(target.entry.chunk, coordinates.target_x, coordinates.target_z, y);
            const source_state = service.blocks.blockAtResident(source.entry, source_pos);
            const target_state = service.blocks.blockAtResident(target.entry, target_pos);
            if (game_data.blockInfo(source_state).emitted_light == 0 and
                lighting_volume.facesSeal(
                    game_data.lightFaceOcclusion(source_state)[boundary.source_face],
                    game_data.lightFaceOcclusion(target_state)[boundary.target_face],
                )) continue;
            const source_index = boundaryLocalIndex(coordinates.source_x, coordinates.source_z, local_y);
            const target_index = boundaryLocalIndex(coordinates.target_x, coordinates.target_z, local_y);
            const loss = @max(@as(u8, 1), game_data.blockInfo(target_state).filtered_light);
            if (projectedLevel(service.state, source_light, true, section, source_index) -| loss >
                projectedLevel(service.state, target_light, true, section, target_index)) return true;
            if (projectedLevel(service.state, source_light, false, section, source_index) -| loss >
                projectedLevel(service.state, target_light, false, section, target_index)) return true;
        }
    }
    return false;
}

fn boundaryCoordinates(boundary: HorizontalBoundary, axis: i32) BoundaryCoordinates {
    return .{
        .source_x = if (boundary.dx == 0) axis else if (boundary.dx < 0) 0 else 15,
        .target_x = if (boundary.dx == 0) axis else if (boundary.dx < 0) 15 else 0,
        .source_z = if (boundary.dz == 0) axis else if (boundary.dz < 0) 0 else 15,
        .target_z = if (boundary.dz == 0) axis else if (boundary.dz < 0) 15 else 0,
    };
}

fn boundaryBlockPosition(chunk: geometry.ChunkPos, x: i32, z: i32, y: usize) geometry.BlockPos {
    return .{
        .x = chunk.x * 16 + x,
        .y = @intCast(@as(i32, world_limits.min_y) + @as(i32, @intCast(y))),
        .z = chunk.z * 16 + z,
    };
}

fn boundaryLocalIndex(x: i32, z: i32, y: usize) u16 {
    return @intCast(x | (z << 4) | (@as(i32, @intCast(y)) << 8));
}

fn uniformBoundaryCanIncrease(
    service: Context,
    source: block_store.GeneratedHeightRef,
    target: block_store.GeneratedHeightRef,
    source_light: *const ChunkState,
    target_light: *const ChunkState,
    boundary: HorizontalBoundary,
    section: usize,
) ?bool {
    if (service.blocks.modifiedSectionIndex(source.entry, section) != null or
        service.blocks.modifiedSectionIndex(target.entry, section) != null)
        return null;
    const source_state = terrainUniformSection(
        &source.entry.shape,
        section,
    ) orelse return null;
    const target_state = terrainUniformSection(
        &target.entry.shape,
        section,
    ) orelse return null;
    const protocol_section = section + 1;
    if (source_light.sky_pages[protocol_section] != no_page or
        source_light.block_pages[protocol_section] != no_page or
        target_light.sky_pages[protocol_section] != no_page or
        target_light.block_pages[protocol_section] != no_page)
        return null;

    const source_info = game_data.blockInfo(source_state);
    const target_info = game_data.blockInfo(target_state);
    if (source_info.emitted_light == 0 and
        lighting_volume.facesSeal(
            game_data.lightFaceOcclusion(source_state)[
                boundary.source_face
            ],
            game_data.lightFaceOcclusion(target_state)[
                boundary.target_face
            ],
        ))
        return false;
    const loss = @max(@as(u8, 1), target_info.filtered_light);
    const source_sky: u8 = if (source_light.sky_full_mask &
        (@as(u32, 1) << @intCast(protocol_section)) != 0)
        15
    else
        0;
    const target_sky: u8 = if (target_light.sky_full_mask &
        (@as(u32, 1) << @intCast(protocol_section)) != 0)
        15
    else
        0;
    return source_sky -| loss > target_sky;
}

fn projectedLevel(
    state: *const Lighting,
    chunk: *const ChunkState,
    sky: bool,
    section: usize,
    local_index: u16,
) u8 {
    const protocol_section = section + 1;
    const handle = if (sky)
        chunk.sky_pages[protocol_section]
    else
        chunk.block_pages[protocol_section];
    if (handle != no_page)
        return getNibble(&state.pages[handle - 1], local_index);
    if (sky and chunk.sky_full_mask &
        (@as(u32, 1) << @intCast(protocol_section)) != 0)
        return 15;
    return 0;
}

fn invalidateChunkLight(state: *Lighting, index: u16) void {
    const chunk = &state.chunks[index];
    if (!chunk.valid) return;
    chunk.sky_changed_mask |= chunk.sky_mask;
    chunk.block_changed_mask |= chunk.block_mask;
    for (&chunk.sky_pages) |*handle| {
        releasePage(state, handle.*);
        handle.* = no_page;
    }
    for (&chunk.block_pages) |*handle| {
        releasePage(state, handle.*);
        handle.* = no_page;
    }
    chunk.sky_mask = 0;
    chunk.sky_full_mask = 0;
    chunk.block_mask = 0;
    markDirty(state, index);
}

fn scheduleResidentChunk(service: Context, world: world_identity.Handle, position: geometry.ChunkPos) void {
    const resident = service.blocks.residentChunkRef(
        world,
        position,
        service.clock.tick,
    ) orelse return;
    if (!occupied(service.state.chunk_occupancy, resident.index)) return;
    if (occupied(service.state.rebuild_occupancy, resident.index)) return;
    setOccupied(service.state.rebuild_occupancy, resident.index);
    service.state.rebuild_chunks[service.state.rebuild_chunk_count] =
        resident.index;
    service.state.rebuild_chunk_count += 1;
}

fn rebuildChunk(
    service: Context,
    chunk_index: u16,
    resident: *const block_store.GeneratedHeightChunk,
    report_changes: bool,
) void {
    const state = service.state;
    if (buildColumnarLight(service, resident)) {
        const chunk = &state.chunks[chunk_index];
        chunk.valid = true;
        chunk.world = resident.world;
        chunk.position = resident.chunk;
        chunk.source_revision = resident.content_revision;
        applyResults(state, chunk_index, report_changes);
        return;
    }
    const volume = volumeData(state);
    const uniform_topology_sections = populateVolume(service, resident, volume);
    solveVolume(service, resident, volume, uniform_topology_sections);
    const chunk = &state.chunks[chunk_index];
    chunk.valid = true;
    chunk.world = resident.world;
    chunk.position = resident.chunk;
    chunk.source_revision = resident.content_revision;
    applyResults(state, chunk_index, report_changes);
}

const VolumeData = struct {
    states: *[lighting_volume.cell_count]i32,
    attenuation: *[lighting_volume.cell_count]u8,
    sky_sources: *[lighting_volume.cell_count]u8,
    sky_frontier: *[lighting_volume.cell_count]u8,
    block_emission: *[lighting_volume.cell_count]u8,
    block_sources: *[lighting_volume.cell_count]u8,
};

fn volumeData(state: *Lighting) VolumeData {
    return .{
        .states = @ptrCast(state.block_states.ptr),
        .attenuation = @ptrCast(state.attenuation.ptr),
        .sky_sources = @ptrCast(state.sky_sources.ptr),
        .sky_frontier = @ptrCast(state.sky_frontier.ptr),
        .block_emission = @ptrCast(state.block_emission.ptr),
        .block_sources = @ptrCast(state.block_sources.ptr),
    };
}

fn populateVolume(service: Context, resident: *const block_store.GeneratedHeightChunk, volume: VolumeData) u32 {
    var uniform_topology_sections: u32 = 0;
    for (0..world_sections) |section| {
        const modified = service.blocks.modifiedSectionIndex(resident, section);
        if (modified == null) {
            if (terrainUniformSection(&resident.shape, section)) |uniform| {
                const first = section * 4096;
                const info = game_data.blockInfo(uniform);
                @memset(volume.states[first..][0..4096], uniform);
                @memset(volume.attenuation[first..][0..4096], info.filtered_light);
                @memset(volume.block_emission[first..][0..4096], info.emitted_light);
                if (info.filtered_light >= 15 or
                    lighting_volume.allFacesEmpty(game_data.lightFaceOcclusion(uniform).*))
                    uniform_topology_sections |= @as(u32, 1) << @intCast(section);
                continue;
            }
            populateGeneratedSection(&resident.shape, section, volume);
            continue;
        }
        for (0..4096) |local_index| {
            const volume_index = section * 4096 + local_index;
            const block_state = service.blocks.sectionBlockState(
                resident,
                section,
                @intCast(local_index),
                modified,
            );
            const info = game_data.blockInfo(block_state);
            volume.states[volume_index] = block_state;
            volume.attenuation[volume_index] = info.filtered_light;
            volume.block_emission[volume_index] = info.emitted_light;
        }
    }
    return uniform_topology_sections;
}

fn populateGeneratedSection(shape: *const terrain.ChunkShape, section: usize, volume: VolumeData) void {
    var states: [256]i32 = undefined;
    var attenuation: [256]u8 = undefined;
    var emission: [256]u8 = undefined;
    const palette_count = shape.sectionPaletteCount(section);
    for (0..palette_count) |index| {
        const block_state = shape.sectionPaletteState(section, index);
        const info = game_data.blockInfo(block_state);
        states[index] = block_state;
        attenuation[index] = info.filtered_light;
        emission[index] = info.emitted_light;
    }
    const first = section * block_store.blocks_per_section;
    for (0..block_store.blocks_per_section) |local_index| {
        const palette_index = shape.sectionPaletteIndex(section, @intCast(local_index));
        const volume_index = first + local_index;
        volume.states[volume_index] = states[palette_index];
        volume.attenuation[volume_index] = attenuation[palette_index];
        volume.block_emission[volume_index] = emission[palette_index];
    }
}

fn solveVolume(service: Context, resident: *const block_store.GeneratedHeightChunk, volume: VolumeData, uniform_sections: u32) void {
    const state = service.state;
    if (containsLight(volume.block_emission)) {
        @memcpy(volume.block_sources, volume.block_emission);
        seedEmissiveNeighbors(volume.block_emission, volume.attenuation, volume.block_sources);
    } else {
        @memset(volume.block_sources, 0);
    }
    state.topology.* = lighting_volume.Topology.buildPrepared(
        volume.attenuation,
        volume.states,
        uniform_sections,
        game_data.lightFaceOcclusion,
    );
    const sky_work_height = skyWorkHeight(resident);
    seedDirectSky(volume.attenuation, volume.sky_sources, state.sky_result, sky_work_height);
    seedNeighborBoundaries(
        service,
        resident,
        volume.states,
        volume.attenuation,
        volume.sky_sources,
        volume.block_sources,
    );
    const has_sky_frontier = seedSkyFrontier(
        volume.attenuation,
        volume.sky_sources,
        volume.sky_frontier,
        @min(lighting_volume.height, sky_work_height + 1),
    );
    if (has_sky_frontier)
        lighting_volume.solveWithBaselineResult(state.topology, state.sky_result, volume.sky_frontier, state.solver, state.sky_result);
    if (containsLight(volume.block_sources))
        lighting_volume.solve(state.topology, volume.block_sources, state.solver, state.block_result)
    else
        state.block_result.* = .{};
}

fn skyWorkHeight(resident: *const block_store.GeneratedHeightChunk) usize {
    var highest = @as(i32, world_limits.min_y) - 1;
    for (resident.heights) |height| highest = @max(highest, height);
    if (resident.modified_section_mask != 0) {
        const section: usize = 31 - @clz(resident.modified_section_mask);
        highest = @max(highest, block_store.sectionWorldY(section, 15));
    }
    return @intCast(std.math.clamp(
        highest - @as(i32, world_limits.min_y) + 1,
        0,
        lighting_volume.height,
    ));
}

fn buildColumnarLight(
    service: Context,
    resident: *const block_store.GeneratedHeightChunk,
) bool {
    if (!isColumnarOpaque(service, resident) or neighborHasBlockLight(service, resident.world, resident.chunk)) return false;
    service.state.sky_result.* = .{};
    service.state.block_result.* = .{};
    const I16x16 = @Vector(16, i16);
    const words_per_layer = 4;
    for (0..lighting_volume.height) |local_y| {
        const y: I16x16 = @splat(@as(i16, world_limits.min_y) + @as(i16, @intCast(local_y)));
        for (0..words_per_layer) |group| {
            var word: u64 = 0;
            inline for (0..4) |row| {
                const first = (group * 4 + row) * 16;
                const heights: I16x16 = resident.heights[first..][0..16].*;
                const visible: u16 = @bitCast(y > heights);
                word |= @as(u64, visible) << @intCast(row * 16);
            }
            const word_index = local_y * words_per_layer + group;
            inline for (0..4) |plane| service.state.sky_result.planes[plane][word_index] = word;
        }
    }
    return true;
}

fn isColumnarOpaque(service: Context, resident: *const block_store.GeneratedHeightChunk) bool {
    var minimum_height = resident.heights[0];
    var maximum_height = resident.heights[0];
    for (resident.heights[1..]) |height| {
        minimum_height = @min(minimum_height, height);
        maximum_height = @max(maximum_height, height);
    }
    for (0..world_sections) |section| {
        if (service.blocks.modifiedSectionIndex(resident, section) != null)
            return false;
        const bottom = block_store.sectionWorldY(section, 0);
        const top = block_store.sectionWorldY(section, 15);
        if (top <= minimum_height and resident.shape.section_visibility[section] != .solid)
            return false;
        if (bottom > maximum_height and resident.shape.section_visibility[section] != .transparent)
            return false;
    }
    for (0..world_sections) |section| {
        const palette_count = resident.shape.sectionPaletteCount(section);
        var air_palette: ?u16 = null;
        for (0..palette_count) |palette_index| {
            const block_state = resident.shape.sectionPaletteState(
                section,
                palette_index,
            );
            if (block_state == registry.block_air_default_state) {
                air_palette = @intCast(palette_index);
                continue;
            }
            const info = game_data.blockInfo(block_state);
            if (info.filtered_light < 15 or info.emitted_light != 0)
                return false;
        }

        const bottom = block_store.sectionWorldY(section, 0);
        const top = block_store.sectionWorldY(section, 15);
        if (palette_count == 1) {
            if (air_palette != null) {
                if (bottom <= maximum_height) return false;
            } else if (top > minimum_height) return false;
            continue;
        }

        const air = air_palette orelse return false;
        for (0..block_store.blocks_per_section) |local_index| {
            const column = ((local_index >> 4) & 15) * 16 +
                (local_index & 15);
            const y = bottom + @as(i16, @intCast(local_index >> 8));
            const palette_index = resident.shape.sectionPaletteIndex(
                section,
                @intCast(local_index),
            );
            if ((y > resident.heights[column]) !=
                (palette_index == air)) return false;
        }
    }
    return true;
}

fn neighborHasBlockLight(
    service: Context,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
) bool {
    const offsets = [_]geometry.ChunkPos{
        .{ .x = -1, .z = 0 },
        .{ .x = 1, .z = 0 },
        .{ .x = 0, .z = -1 },
        .{ .x = 0, .z = 1 },
    };
    for (offsets) |offset| {
        const position = geometry.ChunkPos{
            .x = chunk.x + offset.x,
            .z = chunk.z + offset.z,
        };
        const resident = service.blocks.residentChunkRef(
            world,
            position,
            service.clock.tick,
        ) orelse continue;
        if (!occupied(service.state.chunk_occupancy, resident.index))
            continue;
        const projection = &service.state.chunks[resident.index];
        if (projection.valid and projection.world.eql(world) and
            geometry.sameChunk(projection.position, position) and
            projection.block_mask != 0)
            return true;
    }
    return false;
}

fn seedEmissiveNeighbors(
    emission: *const [lighting_volume.cell_count]u8,
    attenuation: *const [lighting_volume.cell_count]u8,
    sources: *[lighting_volume.cell_count]u8,
) void {
    for (0..lighting_volume.height) |y| {
        for (0..16) |z| {
            for (0..16) |x| {
                const cell = lighting_volume.cellIndex(x, y, z);
                const emitted = emission[cell];
                if (emitted <= 1) continue;
                if (x != 0)
                    seedFromEmission(sources, attenuation, cell - 1, emitted);
                if (x != 15)
                    seedFromEmission(sources, attenuation, cell + 1, emitted);
                if (z != 0)
                    seedFromEmission(sources, attenuation, cell - 16, emitted);
                if (z != 15)
                    seedFromEmission(sources, attenuation, cell + 16, emitted);
                if (y != 0)
                    seedFromEmission(sources, attenuation, cell - 256, emitted);
                if (y + 1 != lighting_volume.height)
                    seedFromEmission(sources, attenuation, cell + 256, emitted);
            }
        }
    }
}

fn terrainUniformSection(
    shape: *const terrain.ChunkShape,
    section: usize,
) ?i32 {
    return terrain.uniformSectionBlockStateFromShape(
        shape,
        section,
    );
}

fn containsLight(values: *const [lighting_volume.cell_count]u8) bool {
    const lanes = 32;
    const V = @Vector(lanes, u8);
    const zero: V = @splat(0);
    var index: usize = 0;
    while (index + lanes <= values.len) : (index += lanes) {
        const batch: V = values[index..][0..lanes].*;
        if (@reduce(.Or, batch != zero)) return true;
    }
    while (index < values.len) : (index += 1)
        if (values[index] != 0) return true;
    return false;
}

fn seedFromEmission(
    sources: *[lighting_volume.cell_count]u8,
    attenuation: *const [lighting_volume.cell_count]u8,
    target: usize,
    emitted: u8,
) void {
    sources[target] = @max(
        sources[target],
        emitted -| @max(@as(u8, 1), attenuation[target]),
    );
}

fn seedSkyFrontier(
    attenuation: *const [lighting_volume.cell_count]u8,
    direct: *const [lighting_volume.cell_count]u8,
    frontier: *[lighting_volume.cell_count]u8,
    work_height: usize,
) bool {
    @memset(frontier, 0);
    var any = false;
    for (0..work_height) |y| {
        for (0..16) |z| {
            for (0..16) |x| {
                const cell = lighting_volume.cellIndex(x, y, z);
                const level = direct[cell];
                if (level <= 1) continue;
                var exposes_shadow = false;
                if (x != 0)
                    exposes_shadow = exposes_shadow or
                        direct[cell - 1] +
                            @max(@as(u8, 1), attenuation[cell - 1]) <
                            level;
                if (x != 15)
                    exposes_shadow = exposes_shadow or
                        direct[cell + 1] +
                            @max(@as(u8, 1), attenuation[cell + 1]) <
                            level;
                if (z != 0)
                    exposes_shadow = exposes_shadow or
                        direct[cell - 16] +
                            @max(@as(u8, 1), attenuation[cell - 16]) <
                            level;
                if (z != 15)
                    exposes_shadow = exposes_shadow or
                        direct[cell + 16] +
                            @max(@as(u8, 1), attenuation[cell + 16]) <
                            level;
                if (y != 0)
                    exposes_shadow = exposes_shadow or
                        direct[cell - 256] +
                            @max(@as(u8, 1), attenuation[cell - 256]) <
                            level;
                if (y + 1 != lighting_volume.height)
                    exposes_shadow = exposes_shadow or
                        direct[cell + 256] +
                            @max(@as(u8, 1), attenuation[cell + 256]) <
                            level;
                if (exposes_shadow) {
                    frontier[cell] = level;
                    any = true;
                }
            }
        }
    }
    return any;
}

fn seedDirectSky(
    attenuation: *const [lighting_volume.cell_count]u8,
    sources: *[lighting_volume.cell_count]u8,
    result: *lighting_volume.Result,
    work_height: usize,
) void {
    @memset(sources, 0);
    result.* = .{};
    const first_full_cell = work_height * 16 * 16;
    @memset(sources[first_full_cell..], 15);
    const first_full_word = first_full_cell / 64;
    inline for (0..4) |plane|
        @memset(
            result.planes[plane][first_full_word..],
            std.math.maxInt(u64),
        );
    var levels: [16 * 16]u8 = @splat(15);
    var y = work_height;
    while (y != 0) {
        y -= 1;
        const first = y * 16 * 16;
        for (0..16 * 16) |column| {
            const cell = first + column;
            const opacity = attenuation[cell];
            if (opacity != 0)
                levels[column] -|= @max(@as(u8, 1), opacity);
            sources[cell] = levels[column];
            result.setLevel(cell, levels[column]);
        }
    }
}

fn seedNeighborBoundaries(
    service: Context,
    resident: *const block_store.GeneratedHeightChunk,
    states: *const [lighting_volume.cell_count]i32,
    attenuation: *const [lighting_volume.cell_count]u8,
    sky_sources: *[lighting_volume.cell_count]u8,
    block_sources: *[lighting_volume.cell_count]u8,
) void {
    const edges = [_]NeighborEdge{
        .{ .dx = -1, .dz = 0, .direction = 0, .opposite = 1 },
        .{ .dx = 1, .dz = 0, .direction = 1, .opposite = 0 },
        .{ .dx = 0, .dz = -1, .direction = 4, .opposite = 5 },
        .{ .dx = 0, .dz = 1, .direction = 5, .opposite = 4 },
    };
    for (edges) |edge|
        seedNeighborEdge(service, resident, states, attenuation, sky_sources, block_sources, edge);
}

const NeighborEdge = struct {
    dx: i32,
    dz: i32,
    direction: usize,
    opposite: usize,
};

fn seedNeighborEdge(
    service: Context,
    resident: *const block_store.GeneratedHeightChunk,
    states: *const [lighting_volume.cell_count]i32,
    attenuation: *const [lighting_volume.cell_count]u8,
    sky_sources: *[lighting_volume.cell_count]u8,
    block_sources: *[lighting_volume.cell_count]u8,
    edge: NeighborEdge,
) void {
    const position = geometry.ChunkPos{ .x = resident.chunk.x + edge.dx, .z = resident.chunk.z + edge.dz };
    const neighbor_ref = service.blocks.residentChunkRef(resident.world, position, service.clock.tick) orelse return;
    if (!occupied(service.state.chunk_occupancy, neighbor_ref.index)) return;
    const projection = &service.state.chunks[neighbor_ref.index];
    if (!projection.valid or !projection.world.eql(resident.world) or !geometry.sameChunk(projection.position, position)) return;
    for (0..world_sections) |section| {
        if (uniformNeighborBoundaryCannotSeed(
            service,
            resident,
            neighbor_ref.entry,
            projection,
            edge.direction,
            edge.opposite,
            section,
        )) continue;
        seedNeighborSection(
            service,
            neighbor_ref.entry,
            projection,
            states,
            attenuation,
            sky_sources,
            block_sources,
            edge,
            section,
        );
    }
}

fn seedNeighborSection(
    service: Context,
    neighbor: *const block_store.GeneratedHeightChunk,
    projection: *const ChunkState,
    states: *const [lighting_volume.cell_count]i32,
    attenuation: *const [lighting_volume.cell_count]u8,
    sky_sources: *[lighting_volume.cell_count]u8,
    block_sources: *[lighting_volume.cell_count]u8,
    edge: NeighborEdge,
    section: usize,
) void {
    const modified = service.blocks.modifiedSectionIndex(neighbor, section);
    for (0..16) |local_y| for (0..16) |axis| {
        const coordinates = neighborCoordinates(edge, axis);
        const local_index: u16 = @intCast(
            coordinates.neighbor_x | (coordinates.neighbor_z << 4) | (local_y << 8),
        );
        const neighbor_block = service.blocks.sectionBlockState(neighbor, section, local_index, modified);
        const cell = lighting_volume.cellIndex(coordinates.x, section * 16 + local_y, coordinates.z);
        if (game_data.blockInfo(neighbor_block).emitted_light == 0 and
            lighting_volume.facesSeal(
                game_data.lightFaceOcclusion(states[cell])[edge.direction],
                game_data.lightFaceOcclusion(neighbor_block)[edge.opposite],
            )) continue;
        const loss = @max(@as(u8, 1), attenuation[cell]);
        const sky = projection.sky_pages[section + 1];
        const sky_level = if (sky != no_page)
            getNibble(&service.state.pages[sky - 1], local_index)
        else if (projection.sky_full_mask & (@as(u32, 1) << @intCast(section + 1)) != 0)
            @as(u8, 15)
        else
            @as(u8, 0);
        const block = projection.block_pages[section + 1];
        const block_level = if (block != no_page)
            getNibble(&service.state.pages[block - 1], local_index)
        else
            @as(u8, 0);
        sky_sources[cell] = @max(sky_sources[cell], sky_level -| loss);
        block_sources[cell] = @max(block_sources[cell], block_level -| loss);
    };
}

const NeighborCoordinates = struct { x: usize, z: usize, neighbor_x: usize, neighbor_z: usize };

fn neighborCoordinates(edge: NeighborEdge, axis: usize) NeighborCoordinates {
    const x: usize = if (edge.dx < 0) 0 else if (edge.dx > 0) 15 else axis;
    const z: usize = if (edge.dz < 0) 0 else if (edge.dz > 0) 15 else axis;
    return .{
        .x = x,
        .z = z,
        .neighbor_x = if (edge.dx < 0) 15 else if (edge.dx > 0) 0 else x,
        .neighbor_z = if (edge.dz < 0) 15 else if (edge.dz > 0) 0 else z,
    };
}

fn uniformNeighborBoundaryCannotSeed(
    service: Context,
    resident: *const block_store.GeneratedHeightChunk,
    neighbor: *const block_store.GeneratedHeightChunk,
    projection: *const ChunkState,
    direction: usize,
    opposite: usize,
    section: usize,
) bool {
    if (service.blocks.modifiedSectionIndex(resident, section) != null or
        service.blocks.modifiedSectionIndex(neighbor, section) != null)
        return false;
    const target_state = terrainUniformSection(
        &resident.shape,
        section,
    ) orelse return false;
    const source_state = terrainUniformSection(
        &neighbor.shape,
        section,
    ) orelse return false;
    const protocol_section = section + 1;
    if (projection.sky_pages[protocol_section] != no_page or
        projection.block_pages[protocol_section] != no_page)
        return false;
    if (game_data.blockInfo(source_state).emitted_light == 0 and
        lighting_volume.facesSeal(
            game_data.lightFaceOcclusion(target_state)[direction],
            game_data.lightFaceOcclusion(source_state)[opposite],
        ))
        return true;
    const target_sky = service.state.sky_result.uniformSection(
        section,
    ) orelse return false;
    const source_sky: u8 = if (projection.sky_full_mask &
        (@as(u32, 1) << @intCast(protocol_section)) != 0)
        15
    else
        0;
    const loss = @max(
        @as(u8, 1),
        game_data.blockInfo(target_state).filtered_light,
    );
    return source_sky -| loss <= target_sky;
}

fn applyResults(
    state: *Lighting,
    chunk_index: u16,
    report_changes: bool,
) void {
    const chunk = &state.chunks[chunk_index];
    const top_bit = @as(u32, 1) << top_protocol_section;
    const previous_sky_mask = chunk.sky_mask;
    const previous_sky_full = chunk.sky_full_mask;
    const previous_block_mask = chunk.block_mask;
    chunk.sky_mask |= top_bit;
    chunk.sky_full_mask |= top_bit;

    for (0..world_sections) |section| {
        const protocol_section = section + 1;
        applySkyResult(state, chunk_index, section, protocol_section, report_changes);
        applyBlockResult(state, chunk_index, section, protocol_section, report_changes);
    }
    if (report_changes and
        (previous_sky_mask != chunk.sky_mask or
            previous_sky_full != chunk.sky_full_mask))
        chunk.sky_changed_mask |=
            previous_sky_mask | chunk.sky_mask |
            previous_sky_full | chunk.sky_full_mask;
    if (report_changes and previous_block_mask != chunk.block_mask)
        chunk.block_changed_mask |=
            previous_block_mask | chunk.block_mask;
    chunk.revision = takeRevision(state);
}

fn applySkyResult(state: *Lighting, chunk_index: u16, section: usize, protocol_section: usize, report_changes: bool) void {
    if (state.sky_result.uniformSection(section)) |level| {
        if (level == 0 or level == 15) {
            applyUniformSection(state, chunk_index, true, protocol_section, level, report_changes);
            return;
        }
    }
    state.sky_result.writeSection(section, state.section_scratch);
    applySection(state, chunk_index, true, protocol_section, state.section_scratch, report_changes);
}

fn applyBlockResult(state: *Lighting, chunk_index: u16, section: usize, protocol_section: usize, report_changes: bool) void {
    if (state.block_result.uniformSection(section)) |level| {
        if (level == 0) {
            applyUniformSection(state, chunk_index, false, protocol_section, 0, report_changes);
            return;
        }
    }
    state.block_result.writeSection(section, state.section_scratch);
    applySection(state, chunk_index, false, protocol_section, state.section_scratch, report_changes);
}

fn applyUniformSection(
    state: *Lighting,
    chunk_index: u16,
    sky: bool,
    protocol_section: usize,
    level: u8,
    report_changes: bool,
) void {
    std.debug.assert(level == 0 or sky and level == 15);
    const chunk = &state.chunks[chunk_index];
    const bit = @as(u32, 1) << @intCast(protocol_section);
    const pages = if (sky) &chunk.sky_pages else &chunk.block_pages;
    var changed = false;
    if (pages[protocol_section] != no_page) {
        releasePage(state, pages[protocol_section]);
        pages[protocol_section] = no_page;
        changed = true;
    }
    if (sky) {
        const full = level == 15;
        const was_present = chunk.sky_mask & bit != 0;
        const was_full = chunk.sky_full_mask & bit != 0;
        if (full) {
            chunk.sky_mask |= bit;
            chunk.sky_full_mask |= bit;
        } else {
            chunk.sky_mask &= ~bit;
            chunk.sky_full_mask &= ~bit;
        }
        changed = changed or was_present != full or was_full != full;
    } else {
        changed = changed or chunk.block_mask & bit != 0;
        chunk.block_mask &= ~bit;
    }
    if (!changed or !report_changes) return;
    if (sky)
        chunk.sky_changed_mask |= bit
    else
        chunk.block_changed_mask |= bit;
    markDirty(state, chunk_index);
}

fn applySection(
    state: *Lighting,
    chunk_index: u16,
    sky: bool,
    protocol_section: usize,
    bytes: *const [light_projection.bytes_per_section]u8,
    report_changes: bool,
) void {
    const chunk = &state.chunks[chunk_index];
    const bit = @as(u32, 1) << @intCast(protocol_section);
    const uniform_zero = allBytes(bytes, 0);
    const uniform_full = sky and allBytes(bytes, 0xff);
    const pages = if (sky) &chunk.sky_pages else &chunk.block_pages;
    var changed = false;

    if (uniform_zero or uniform_full) {
        if (pages[protocol_section] != no_page) {
            releasePage(state, pages[protocol_section]);
            pages[protocol_section] = no_page;
            changed = true;
        }
        if (sky) {
            const old_mask = chunk.sky_mask & bit != 0;
            const old_full = chunk.sky_full_mask & bit != 0;
            if (uniform_full) {
                chunk.sky_mask |= bit;
                chunk.sky_full_mask |= bit;
            } else {
                chunk.sky_mask &= ~bit;
                chunk.sky_full_mask &= ~bit;
            }
            changed = changed or old_mask != uniform_full or
                old_full != uniform_full;
        } else {
            changed = changed or chunk.block_mask & bit != 0;
            chunk.block_mask &= ~bit;
        }
    } else {
        var handle = pages[protocol_section];
        if (handle == no_page) {
            handle = allocatePage(state, chunk_index);
            pages[protocol_section] = handle;
            changed = true;
        }
        const page = &state.pages[handle - 1];
        if (!std.mem.eql(u8, page, bytes)) {
            @memcpy(page, bytes);
            changed = true;
        }
        if (sky) {
            chunk.sky_mask |= bit;
            chunk.sky_full_mask &= ~bit;
        } else {
            chunk.block_mask |= bit;
        }
    }

    if (changed and report_changes) {
        if (sky)
            chunk.sky_changed_mask |= bit
        else
            chunk.block_changed_mask |= bit;
        markDirty(state, chunk_index);
    }
}

fn allBytes(
    bytes: *const [light_projection.bytes_per_section]u8,
    value: u8,
) bool {
    for (bytes) |byte| if (byte != value) return false;
    return true;
}

fn markDirty(state: *Lighting, chunk_index: u16) void {
    const chunk = &state.chunks[chunk_index];
    if (chunk.dirty) return;
    if (state.dirty_chunk_count == state.dirty_chunks.len)
        diagnostics.panic("lighting dirty chunk capacity exhausted", &.{});
    state.dirty_chunks[state.dirty_chunk_count] = chunk_index;
    state.dirty_chunk_count += 1;
    chunk.dirty = true;
}

fn chunkView(
    state: *Lighting,
    index: u16,
) *const light_projection.Chunk {
    const chunk = &state.chunks[index];
    var sky = [_]light_projection.Section{.{}} ** protocol_sections;
    var block = [_]light_projection.Section{.{}} ** protocol_sections;
    for (0..protocol_sections) |section| {
        if (chunk.sky_pages[section] != no_page)
            sky[section].ptr = &state.pages[chunk.sky_pages[section] - 1];
        if (chunk.block_pages[section] != no_page)
            block[section].ptr =
                &state.pages[chunk.block_pages[section] - 1];
    }
    state.projection_scratch = .{
        .chunk_x = chunk.position.x,
        .chunk_z = chunk.position.z,
        .revision = chunk.revision,
        .sky_mask = chunk.sky_mask,
        .block_mask = chunk.block_mask,
        .empty_sky_mask = all_protocol_sections & ~chunk.sky_mask,
        .empty_block_mask = all_protocol_sections & ~chunk.block_mask,
        .sky = sky,
        .block = block,
    };
    return &state.projection_scratch;
}

fn allocatePage(state: *Lighting, protected_chunk: u16) u16 {
    if (!state.page_pool_initialized) {
        for (0..state.free_pages.len) |index|
            state.free_pages[index] =
                @intCast(state.free_pages.len - 1 - index);
        state.free_page_count = state.free_pages.len;
        state.page_pool_initialized = true;
    }
    if (state.free_page_count == 0)
        reclaimLightingPages(state, protected_chunk);
    if (state.free_page_count == 0)
        diagnostics.panic(
            "lighting page capacity exhausted while building resident chunk",
            &.{diagnostics.integer(protected_chunk)},
        );
    state.free_page_count -= 1;
    const index = state.free_pages[state.free_page_count];
    @memset(&state.pages[index], 0);
    return index + 1;
}

fn reclaimLightingPages(state: *Lighting, protected_chunk: u16) void {
    for (state.chunks, 0..) |*chunk, index| {
        if (index == protected_chunk or chunk.dirty or
            !occupied(state.chunk_occupancy, index) or !chunk.valid)
            continue;
        if (!chunkOwnsPage(chunk)) continue;
        discardChunkProjection(state, @intCast(index));
        std.debug.assert(state.free_page_count != 0);
        return;
    }
}

fn chunkOwnsPage(chunk: *const ChunkState) bool {
    for (chunk.sky_pages) |handle| if (handle != no_page) return true;
    for (chunk.block_pages) |handle| if (handle != no_page) return true;
    return false;
}

fn discardChunkProjection(state: *Lighting, index: u16) void {
    std.debug.assert(index < state.chunks.len);
    const chunk = &state.chunks[index];
    std.debug.assert(!chunk.dirty);
    releaseChunkPages(state, chunk);
    chunk.* = .{};
    clearOccupied(state.chunk_occupancy, index);
}

fn releaseChunkPages(state: *Lighting, chunk: *ChunkState) void {
    if (!chunk.valid) return;
    for (chunk.sky_pages) |handle| releasePage(state, handle);
    for (chunk.block_pages) |handle| releasePage(state, handle);
}

fn releasePage(state: *Lighting, handle: u16) void {
    if (handle == no_page) return;
    std.debug.assert(handle <= state.pages.len);
    std.debug.assert(state.free_page_count < state.free_pages.len);
    state.free_pages[state.free_page_count] = handle - 1;
    state.free_page_count += 1;
}

fn occupied(words: []const u64, index: usize) bool {
    return words[index >> 6] &
        (@as(u64, 1) << @intCast(index & 63)) != 0;
}

fn setOccupied(words: []u64, index: usize) void {
    words[index >> 6] |=
        @as(u64, 1) << @intCast(index & 63);
}

fn clearOccupied(words: []u64, index: usize) void {
    words[index >> 6] &=
        ~(@as(u64, 1) << @intCast(index & 63));
}

fn takeRevision(state: *Lighting) u64 {
    const revision = state.next_revision;
    state.next_revision +%= 1;
    if (state.next_revision == 0) state.next_revision = 1;
    return revision;
}

fn getNibble(
    page: *const [light_projection.bytes_per_section]u8,
    local_index: u16,
) u8 {
    const byte = page[local_index >> 1];
    const shift: u3 = @intCast((local_index & 1) * 4);
    return (byte >> shift) & 0x0f;
}

fn setNibble(
    page: *[light_projection.bytes_per_section]u8,
    local_index: u16,
    level: u8,
) void {
    const shift: u3 = @intCast((local_index & 1) * 4);
    const mask = @as(u8, 0x0f) << shift;
    page[local_index >> 1] =
        (page[local_index >> 1] & ~mask) |
        ((level & 0x0f) << shift);
}

test "skylight seeds vertically and spreads beneath a roof" {
    var states: [lighting_volume.cell_count]i32 =
        @splat(registry.block_air_default_state);
    var attenuation: [lighting_volume.cell_count]u8 = @splat(0);
    var sources: [lighting_volume.cell_count]u8 = undefined;
    var frontier: [lighting_volume.cell_count]u8 = undefined;
    const roof_y = 16;
    attenuation[lighting_volume.cellIndex(8, roof_y, 8)] = 15;
    states[lighting_volume.cellIndex(8, roof_y, 8)] =
        registry.block_stone_default_state;
    var direct_result: lighting_volume.Result = .{};
    seedDirectSky(
        &attenuation,
        &sources,
        &direct_result,
        lighting_volume.height,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        sources[lighting_volume.cellIndex(8, roof_y - 1, 8)],
    );
    const topology = lighting_volume.Topology.build(
        &attenuation,
        &states,
        game_data.lightFaceOcclusion,
    );
    var scratch: lighting_volume.Scratch = .{};
    var result: lighting_volume.Result = .{};
    _ = seedSkyFrontier(
        &attenuation,
        &sources,
        &frontier,
        lighting_volume.height,
    );
    lighting_volume.solveWithBaselineResult(
        &topology,
        &direct_result,
        &frontier,
        &scratch,
        &result,
    );
    try std.testing.expectEqual(
        @as(u8, 14),
        result.level(lighting_volume.cellIndex(8, roof_y - 1, 8)),
    );
}

test "released resident chunks return their lighting pages" {
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const position = geometry.ChunkPos{ .x = 7, .z = -3 };
    var chunks = [_]ChunkState{ .{}, .{} };
    var occupancy = [_]u64{0};
    var pages: [4][light_projection.bytes_per_section]u8 align(64) = undefined;
    var free_pages: [4]u16 = undefined;
    var state = Lighting{
        .chunks = &chunks,
        .chunk_occupancy = &occupancy,
        .pages = &pages,
        .free_pages = &free_pages,
        .deps = undefined,
    };

    for (0..1_024) |_| {
        state.chunks[1] = .{ .valid = true, .world = world, .position = position };
        setOccupied(state.chunk_occupancy, 1);
        state.chunks[1].sky_pages[1] = allocatePage(&state, 1);
        state.chunks[1].block_pages[1] = allocatePage(&state, 1);
        state.releaseResidentChunk(1, world, position);
        try std.testing.expectEqual(@as(usize, 4), state.free_page_count);
        try std.testing.expect(!occupied(state.chunk_occupancy, 1));
        try std.testing.expect(!state.chunks[1].valid);
    }
}

test "page reclamation skips projections without allocated pages" {
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    var chunks = [_]ChunkState{
        .{ .valid = true, .world = world, .position = .{ .x = 0, .z = 0 } },
        .{ .valid = true, .world = world, .position = .{ .x = 1, .z = 0 } },
        .{
            .valid = true,
            .world = world,
            .position = .{ .x = 2, .z = 0 },
            .sky_pages = init: {
                var handles = [_]u16{no_page} ** protocol_sections;
                handles[1] = 1;
                handles[2] = 2;
                break :init handles;
            },
        },
        .{ .valid = true, .world = world, .position = .{ .x = 3, .z = 0 } },
    };
    var occupancy = [_]u64{0b1111};
    var pages: [2][light_projection.bytes_per_section]u8 align(64) = undefined;
    var free_pages: [2]u16 = undefined;
    var state = Lighting{
        .chunks = &chunks,
        .chunk_occupancy = &occupancy,
        .pages = &pages,
        .free_pages = &free_pages,
        .page_pool_initialized = true,
        .deps = undefined,
    };

    const handle = allocatePage(&state, 3);

    try std.testing.expect(handle == 1 or handle == 2);
    try std.testing.expect(state.chunks[0].valid);
    try std.testing.expect(state.chunks[1].valid);
    try std.testing.expect(!state.chunks[2].valid);
    try std.testing.expect(state.chunks[3].valid);
    try std.testing.expectEqual(@as(usize, 1), state.free_page_count);
}

test "materialized lighting round trips without solving again" {
    const test_generator = lightning_rod.test_support.world_generator;
    const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
    const position = geometry.ChunkPos{ .x = 3, .z = 4 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source_blocks = try block_store.Blocks.init(arena.allocator(), .{ .maximum_resident_chunks = 4, .maximum_modified_sections = 4 });
    const destination_blocks = try block_store.Blocks.init(arena.allocator(), .{ .maximum_resident_chunks = 4, .maximum_modified_sections = 4 });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 91);
    generator.bind(source_blocks);
    const generated = source_blocks.generatedHeightChunkRef(test_world, position, 1).entry;
    _ = try destination_blocks.installResidentChunk(test_world, generated.shape, 1, .persisted);
    const State = struct {
        var clock: world_clock.Clock = .{};
        var players_state: players.Players = undefined;
        var sessions_state: sessions.Sessions = undefined;
    };
    const source = try Lighting.init(arena.allocator(), .{ .clock = &State.clock, .blocks = source_blocks, .players = &State.players_state, .sessions = &State.sessions_state, .paging = null }, .{});
    const destination = try Lighting.init(arena.allocator(), .{ .clock = &State.clock, .blocks = destination_blocks, .players = &State.players_state, .sessions = &State.sessions_state, .paging = null }, .{});
    var first: [protocol_sections * (light_projection.bytes_per_section * 2 + 2) + 5]u8 = undefined;
    var second: [first.len]u8 = undefined;
    const encoded = source.encodePersisted(test_world, position, &first).?;
    try std.testing.expect(destination.decodePersisted(test_world, position, encoded));
    const restored = destination.encodePersisted(test_world, position, &second).?;
    try std.testing.expectEqualSlices(u8, encoded, restored);
}
