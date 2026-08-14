const std = @import("std");
const preallocated = @import("preallocated");
const registry = @import("registry_data");
const game_data = @import("../game_data.zig");
const config = @import("../config.zig").value;
const terrain = @import("../terrain.zig");
const diagnostics = @import("../diagnostics.zig");
const geometry = @import("geometry.zig");
const generator_api = @import("generator_api.zig");
const world_identity = @import("identity.zig");

const cache_line_size = 64;
const air_block_state = registry.block_air_default_state;
const dirt_block_default_state = registry.block_dirt_default_state;

pub fn isWaterBlockState(block_state: i32) bool {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return false;
    return registry.block_state_to_block[@intCast(block_state)] ==
        registry.block_state_to_block[@intCast(registry.state_water_level_0)];
}
pub const world_top_y: i16 = config.world_min_y + @as(i16, @intCast(config.overworld_section_count * 16)) - 1;

pub const blocks_per_section = 16 * 16 * 16;
const sparse_section_change_capacity = 32;
pub const random_tick_mask_unindexed = std.math.maxInt(u16);
pub const random_tick_mask_columns = random_tick_mask_unindexed - 1;
pub const random_tick_mixed_state = std.math.minInt(i32);

/// Simulation is allocated from anonymous memory in both the executable and
/// reload host. Initialization clears the whole value for simple, auditable
/// invariants, but these backing pools contain no live values until their free
/// lists hand out an entry. Return their full interior pages to Linux so a
/// sparse world pays in RSS only when it promotes a section or builds a mask.
fn discardColdPool(memory: []u8) void {
    const page_size = std.heap.page_size_min;
    const memory_start = @intFromPtr(memory.ptr);
    const memory_end = memory_start + memory.len;
    const start = std.mem.alignForward(usize, memory_start, page_size);
    const end = memory_end - (memory_end % page_size);
    if (start >= end) return;
    const pages: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
    std.posix.madvise(pages, end - start, std.posix.MADV.DONTNEED) catch {};
}

pub const ModifiedSection = struct {
    active: bool = false,
    dirty: bool = false,
    dense: bool = false,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    world: world_identity.Handle = world_identity.invalid,
    section: u8 = 0,
    page_index: u16 = 0,
    sparse_count: u8 = 0,
    modified_count: u16 = 0,
    random_tickable_count: u16 = 0,
    revision: u64 = 0,
    modified_bits: [blocks_per_section / 64]u64 = [_]u64{0} ** (blocks_per_section / 64),
    sparse_indices: [sparse_section_change_capacity]u16 = undefined,
    sparse_states: [sparse_section_change_capacity]i32 = undefined,
};

const resident_chunk_empty = std.math.maxInt(u16);
pub const no_modified_section_index = std.math.maxInt(u16);

pub const GeneratedHeightChunk = struct {
    valid: bool = false,
    dirty: bool = false,
    persistence_known: bool = false,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    world: world_identity.Handle = world_identity.invalid,
    last_used_tick: u64 = 0,
    ticket_generation: u64 = 0,
    revision: u64 = 0,
    content_revision: u64 = 0,
    modified_section_mask: u32 = 0,
    dirty_section_mask: u32 = 0,
    /// Direct bindings into `Blocks.modified_sections`. Block queries already
    /// hold a resident chunk, so probing a second hash table for every section
    /// defeats that locality. Open-address relocation keeps these bindings
    /// updated when an overlay is released.
    modified_section_indices: [config.overworld_section_count]u16 = [_]u16{no_modified_section_index} ** config.overworld_section_count,
    shape: terrain.ChunkShape = undefined,
    random_tick_sections: u32 = 0,
    heights: [16 * 16]i16 = undefined,
    grass_above_blocked: [4]u64 = undefined,
    base_grass_spread_possible: bool = false,
    random_tickable_counts: [config.overworld_section_count]u16 = undefined,
    /// One-based handles into Blocks.random_tick_masks. Zero means no base
    /// random ticks, maxInt-1 is the exact compact column representation, and
    /// maxInt means the bounded cache overflowed and callers must decode the
    /// authoritative state.
    random_tick_mask_handles: [config.overworld_section_count]u16 = [_]u16{0} ** config.overworld_section_count,
    /// A direct state for sections whose base random-tickable positions all
    /// share one state. Mixed sections retain the authoritative mask and use
    /// the normal section decoder only after a sampled bit hits.
    random_tick_uniform_states: [config.overworld_section_count]i32 = [_]i32{random_tick_mixed_state} ** config.overworld_section_count,
};

pub const GeneratedHeightRef = struct {
    index: u16,
    entry: *const GeneratedHeightChunk,
};

pub const ResidentChunkSource = enum { generated_unknown, generated_new, persisted };
pub const ChunkGenerationResult = enum { idle, pending, complete, backpressured };

pub const Blocks = struct {
    pub const id = "lightning_rod:blocks";

    pub const Configuration = struct {
        maximum_resident_chunks: usize = config.max_resident_chunks,
        maximum_modified_sections: usize = config.max_modified_sections,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_resident_chunks < 4 or self.maximum_resident_chunks >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_resident_chunks))
                return error.InvalidResidentChunkCapacity;
            if (self.maximum_modified_sections == 0 or
                self.maximum_modified_sections >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_modified_sections))
                return error.InvalidModifiedSectionCapacity;
        }
    };

    const no_generation_request = std.math.maxInt(u16);

    generator: ?generator_api.Service = null,
    modified_sections: []ModifiedSection = &.{},
    free_modified_sections: []u16 = &.{},
    free_modified_section_count: usize = 0,
    modified_section_pool_initialized: bool = false,
    section_pages: []align(cache_line_size) [blocks_per_section]i32 = &.{},
    free_section_pages: []u16 = &.{},
    modified_block_count: usize = 0,
    modified_section_count: usize = 0,
    free_section_page_count: usize = 0,
    page_pool_initialized: bool = false,
    next_section_revision: u64 = 1,
    block_mutation_sequence: u64 = 0,
    block_mutations: []geometry.BlockMutation = &.{},
    resident_chunks: []GeneratedHeightChunk = &.{},
    resident_shape_storage: []align(cache_line_size) u8 = &.{},
    resident_chunk_lookup: []u16 = &.{},
    free_resident_chunks: []u16 = &.{},
    active_resident_indices: []u16 = &.{},
    resident_active_positions: []u16 = &.{},
    free_resident_chunk_count: usize = 0,
    resident_chunk_count: usize = 0,
    resident_pool_initialized: bool = false,
    resident_pressure: bool = false,
    /// Changes when an existing resident binding or its contents can no longer
    /// be used through a previously validated hot projection. New chunks occupy
    /// free slots and therefore do not invalidate existing worksets.
    resident_binding_revision: u64 = 1,
    resident_ticket_generation: u64 = 1,
    resident_ticket_previous_generation: u64 = 0,
    random_tick_masks: []align(cache_line_size) [blocks_per_section / 64]u64 = &.{},
    free_random_tick_masks: []u16 = &.{},
    free_random_tick_mask_count: usize = 0,
    random_tick_mask_pool_initialized: bool = false,
    chunk_generation_requests: []geometry.WorldChunk = &.{},
    chunk_generation_request_lookup: []u16 = &.{},
    chunk_generation_request_count: usize = 0,
    chunk_generation_request_cursor: usize = 0,
    chunk_generation_active: bool = false,

    fn allocateStorage(self: *Blocks, allocator: std.mem.Allocator, configuration: Configuration) !void {
        try configuration.validate();
        self.* = .{};
        self.modified_sections = try preallocated.alloc(ModifiedSection, allocator, configuration.maximum_modified_sections);
        self.free_modified_sections = try preallocated.alloc(u16, allocator, configuration.maximum_modified_sections);
        self.section_pages = try preallocated.alignedAlloc([blocks_per_section]i32, allocator, .@"64", configuration.maximum_modified_sections);
        self.free_section_pages = try preallocated.alloc(u16, allocator, configuration.maximum_modified_sections);
        self.block_mutations = try preallocated.alloc(geometry.BlockMutation, allocator, config.max_block_mutation_history);
        self.resident_chunks = try preallocated.alloc(GeneratedHeightChunk, allocator, configuration.maximum_resident_chunks);
        self.resident_shape_storage = try preallocated.alignedAlloc(
            u8,
            allocator,
            .@"64",
            configuration.maximum_resident_chunks * terrain.chunk_storage_capacity,
        );
        self.resident_chunk_lookup = try preallocated.alloc(u16, allocator, configuration.maximum_resident_chunks * 2);
        self.free_resident_chunks = try preallocated.alloc(u16, allocator, configuration.maximum_resident_chunks);
        self.active_resident_indices = try preallocated.alloc(u16, allocator, configuration.maximum_resident_chunks);
        self.resident_active_positions = try preallocated.alloc(u16, allocator, configuration.maximum_resident_chunks);
        const random_tick_masks = @min(configuration.maximum_resident_chunks * 2, @as(usize, random_tick_mask_columns - 1));
        self.random_tick_masks = try preallocated.alignedAlloc([blocks_per_section / 64]u64, allocator, .@"64", random_tick_masks);
        self.free_random_tick_masks = try preallocated.alloc(u16, allocator, random_tick_masks);
        self.chunk_generation_requests =
            try preallocated.alloc(geometry.WorldChunk, allocator, configuration.maximum_resident_chunks);
        self.chunk_generation_request_lookup =
            try preallocated.alloc(u16, allocator, configuration.maximum_resident_chunks * 2);
        @memset(self.resident_chunk_lookup, resident_chunk_empty);
        self.resetStorageState();
    }

    pub fn resetInPlace(self: *Blocks) void {
        self.discardPools();
        self.resetStorageState();
    }

    fn discardPools(self: *Blocks) void {
        discardColdPool(std.mem.sliceAsBytes(self.modified_sections));
        discardColdPool(std.mem.sliceAsBytes(self.section_pages));
        discardColdPool(std.mem.sliceAsBytes(self.resident_chunks));
        discardColdPool(std.mem.sliceAsBytes(self.resident_shape_storage));
        discardColdPool(std.mem.sliceAsBytes(self.random_tick_masks));
    }

    pub fn create(allocator: std.mem.Allocator, configuration: Configuration) !*Blocks {
        const self = try allocator.create(Blocks);
        try self.allocateStorage(allocator, configuration);
        return self;
    }

    pub fn bindGenerator(self: *Blocks, generator: generator_api.Service) void {
        self.generator = generator;
    }

    fn resetStorageState(self: *Blocks) void {
        self.free_modified_section_count = 0;
        self.modified_section_pool_initialized = false;
        self.modified_block_count = 0;
        self.modified_section_count = 0;
        self.free_section_page_count = 0;
        self.page_pool_initialized = false;
        self.next_section_revision = 1;
        self.block_mutation_sequence = 0;
        self.free_resident_chunk_count = 0;
        self.resident_chunk_count = 0;
        self.resident_pool_initialized = false;
        self.resident_pressure = false;
        self.resident_binding_revision = 1;
        self.resident_ticket_generation = 1;
        self.resident_ticket_previous_generation = 0;
        self.free_random_tick_mask_count = 0;
        self.random_tick_mask_pool_initialized = false;
        self.chunk_generation_request_count = 0;
        self.chunk_generation_request_cursor = 0;
        self.chunk_generation_active = false;
        @memset(
            self.chunk_generation_request_lookup,
            no_generation_request,
        );
    }

    pub fn blockAt(self: *const Blocks, world: world_identity.Handle, pos: geometry.BlockPos) i32 {
        const chunk: geometry.ChunkPos = geometry.chunkForBlock(pos);
        const resident = self.residentChunk(world, chunk) orelse
            diagnostics.panic("world query touched non-resident chunk; load or generate it explicitly (chunk x, chunk z, block x, block y, block z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z), diagnostics.integer(pos.x), diagnostics.integer(pos.y), diagnostics.integer(pos.z) });
        return self.blockAtResident(resident, pos);
    }

    pub fn blockAtIfResident(self: *const Blocks, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        const resident = self.residentChunk(world, geometry.chunkForBlock(pos)) orelse return null;
        return self.blockAtResident(resident, pos);
    }

    pub fn blockMutation(self: *const Blocks, sequence: u64) geometry.BlockMutation {
        std.debug.assert(sequence != 0 and self.block_mutation_sequence -% sequence < config.max_block_mutation_history);
        return self.block_mutations[(sequence -% 1) % self.block_mutations.len];
    }

    pub fn blockMutationSequence(self: *const Blocks) u64 {
        return self.block_mutation_sequence;
    }

    pub fn modifiedSection(self: *const Blocks, resident: *const GeneratedHeightChunk, section: usize) ?*const ModifiedSection {
        const index = self.modifiedSectionIndex(resident, section) orelse return null;
        return &self.modified_sections[index];
    }

    pub fn modifiedSectionState(self: *const Blocks, entry: *const ModifiedSection, local_index: u16) i32 {
        return self.modifiedBlockState(entry, local_index);
    }

    /// Query with a chunk that the caller already resolved. Collision,
    /// visibility, and pathfinding walk many blocks in the same chunk; doing
    /// the resident hash lookup again for every block dominated those loops.
    pub fn blockAtResident(self: *const Blocks, resident: *const GeneratedHeightChunk, pos: geometry.BlockPos) i32 {
        std.debug.assert(geometry.sameChunk(resident.chunk, geometry.chunkForBlock(pos)));
        if (sectionIndexForY(pos.y)) |section| {
            if (resident.modified_section_mask & (@as(u32, 1) << @intCast(section)) != 0) {
                const table_index = self.modifiedSectionIndex(resident, section) orelse
                    diagnostics.panic("resident modified-section mask is stale (chunk x, chunk z, section)", &.{ diagnostics.integer(resident.chunk.x), diagnostics.integer(resident.chunk.z), diagnostics.integer(section) });
                return self.sectionBlockState(resident, section, localBlockIndex(pos), table_index);
            }
        }
        return terrain.blockAtFromShape(&resident.shape, pos.x, pos.y, pos.z);
    }

    /// Exact hot predicate for the resident compact base plus overlays. The
    /// compact base records whether the block immediately above each surface
    /// grass column blocks it. Any overlay touching that position takes the
    /// general logical-state path.
    pub fn grassAboveIsBlocked(self: *const Blocks, resident: *const GeneratedHeightChunk, grass: geometry.BlockPos) bool {
        const above = geometry.BlockPos{ .x = grass.x, .y = grass.y + 1, .z = grass.z };
        if (sectionIndexForY(above.y)) |section| {
            if (resident.modified_section_mask & (@as(u32, 1) << @intCast(section)) != 0) {
                const modified_index = self.modifiedSectionIndex(resident, section) orelse unreachable;
                const local_index = localBlockIndex(above);
                if (self.sectionBlockIsModified(modified_index, local_index))
                    return game_data.preventsGrassSurvival(self.modifiedBlockState(&self.modified_sections[modified_index], local_index));
            }
        }
        return game_data.preventsGrassSurvival(terrain.blockAtFromShape(
            &resident.shape,
            above.x,
            above.y,
            above.z,
        ));
    }

    /// Test the dirt-and-open-above predicate used by grass behavior. Chunk
    /// generation supplies a representation-neutral summary for the common
    /// no-candidate case; arbitrary bases and overlays use logical states.
    pub fn grassCanSpreadAt(self: *const Blocks, resident: *const GeneratedHeightChunk, candidate: geometry.BlockPos) bool {
        const candidate_section = sectionIndexForY(candidate.y) orelse return false;
        const above = geometry.BlockPos{ .x = candidate.x, .y = candidate.y + 1, .z = candidate.z };
        const above_section = sectionIndexForY(above.y) orelse return false;
        const relevant_sections = (@as(u32, 1) << @intCast(candidate_section)) |
            (@as(u32, 1) << @intCast(above_section));
        if (resident.modified_section_mask & relevant_sections == 0 and !resident.base_grass_spread_possible) return false;
        const candidate_modified = if (resident.modified_section_mask & (@as(u32, 1) << @intCast(candidate_section)) != 0)
            self.modifiedSectionIndex(resident, candidate_section)
        else
            null;
        const above_modified = if (above_section == candidate_section)
            candidate_modified
        else if (resident.modified_section_mask & (@as(u32, 1) << @intCast(above_section)) != 0)
            self.modifiedSectionIndex(resident, above_section)
        else
            null;
        const candidate_local = localBlockIndex(candidate);
        const above_local = localBlockIndex(above);
        const candidate_changed = if (candidate_modified) |index| self.sectionBlockIsModified(index, candidate_local) else false;
        const above_changed = if (above_modified) |index| self.sectionBlockIsModified(index, above_local) else false;
        if (!candidate_changed and !above_changed and !resident.base_grass_spread_possible) return false;
        const candidate_state = self.sectionBlockState(resident, candidate_section, candidate_local, candidate_modified);
        if (game_data.blockInfo(candidate_state).default_state != dirt_block_default_state) return false;
        return !game_data.preventsGrassSurvival(self.sectionBlockState(resident, above_section, above_local, above_modified));
    }

    /// Resolve a block from a resident authoritative section. A dense overlay
    /// page is cold storage for explicit changes and persistence; an unchanged
    /// sample must read the resident base rather than touching that page just
    /// because another block in the section changed. Callers therefore make
    /// no assumptions about how the base was generated or represented.
    pub fn sectionBlockState(
        self: *const Blocks,
        resident: *const GeneratedHeightChunk,
        section: usize,
        local_index: u16,
        modified_index: ?usize,
    ) i32 {
        std.debug.assert(section < config.overworld_section_count);
        std.debug.assert(local_index < blocks_per_section);
        if (modified_index) |index| {
            const entry = &self.modified_sections[index];
            std.debug.assert(entry.active);
            std.debug.assert(geometry.sameChunk(entry.chunk, resident.chunk));
            std.debug.assert(entry.section == section);
            if (self.sectionBlockIsModified(index, local_index))
                return self.modifiedBlockState(entry, local_index);
        }
        const local_x: i32 = local_index & 15;
        const local_z: i32 = (local_index >> 4) & 15;
        const local_y: usize = (local_index >> 8) & 15;
        return terrain.blockAtFromShape(
            &resident.shape,
            resident.chunk.x * 16 + local_x,
            sectionWorldY(section, local_y),
            resident.chunk.z * 16 + local_z,
        );
    }

    /// Query authoritative resident metadata before decoding a block state.
    /// Simulation plugins never infer tickability from terrain-generation
    /// rules.
    pub fn sectionBlockHasRandomTicks(
        self: *const Blocks,
        resident: *const GeneratedHeightChunk,
        section: usize,
        local_index: u16,
        modified_index: ?usize,
    ) bool {
        if (modified_index) |index| {
            if (self.sectionBlockIsModified(index, local_index))
                return isRandomTickableBlock(self.modifiedBlockState(&self.modified_sections[index], local_index));
        }
        const handle = resident.random_tick_mask_handles[section];
        if (handle == 0) return false;
        if (handle == random_tick_mask_columns) {
            const column: usize = local_index & 0xff;
            const local_y: usize = (local_index >> 8) & 15;
            return resident.heights[column] == sectionWorldY(section, local_y);
        }
        if (handle == random_tick_mask_unindexed)
            return isRandomTickableBlock(self.sectionBlockState(resident, section, local_index, null));
        const mask = &self.random_tick_masks[handle - 1];
        return mask[local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) != 0;
    }

    /// Fuses the overwhelmingly common random-tick mask miss with state
    /// resolution. This avoids decoding a base state twice and lets derived
    /// resident metadata answer uniform random-tick palettes directly.
    pub fn sectionRandomTickBlockState(
        self: *const Blocks,
        resident: *const GeneratedHeightChunk,
        section: usize,
        local_index: u16,
        modified_index: ?usize,
    ) ?i32 {
        if (modified_index) |index| {
            if (self.sectionBlockIsModified(index, local_index)) {
                const state = self.modifiedBlockState(&self.modified_sections[index], local_index);
                return if (isRandomTickableBlock(state)) state else null;
            }
        }
        const handle = resident.random_tick_mask_handles[section];
        if (handle == 0) return null;
        if (handle == random_tick_mask_columns) {
            const column: usize = local_index & 0xff;
            const local_y: usize = (local_index >> 8) & 15;
            if (resident.heights[column] != sectionWorldY(section, local_y)) return null;
            const uniform = resident.random_tick_uniform_states[section];
            return if (uniform != random_tick_mixed_state)
                uniform
            else
                self.sectionBlockState(resident, section, local_index, null);
        }
        if (handle == random_tick_mask_unindexed) {
            const state = self.sectionBlockState(resident, section, local_index, null);
            return if (isRandomTickableBlock(state)) state else null;
        }
        const mask = &self.random_tick_masks[handle - 1];
        if (mask[local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) == 0) return null;
        const uniform = resident.random_tick_uniform_states[section];
        return if (uniform != random_tick_mixed_state)
            uniform
        else
            self.sectionBlockState(resident, section, local_index, null);
    }

    pub fn sectionUsesRandomTickColumns(resident: *const GeneratedHeightChunk, section: usize) bool {
        return resident.random_tick_mask_handles[section] == random_tick_mask_columns;
    }

    /// Fast base-only companion to sectionRandomTickBlockState. Callers must
    /// first prove `sectionUsesRandomTickColumns` and that no overlay applies.
    pub fn columnRandomTickBlockState(
        self: *const Blocks,
        resident: *const GeneratedHeightChunk,
        section: usize,
        local_index: u16,
    ) ?i32 {
        const column: usize = local_index & 0xff;
        const local_y: usize = (local_index >> 8) & 15;
        if (resident.heights[column] != sectionWorldY(section, local_y)) return null;
        const uniform = resident.random_tick_uniform_states[section];
        return if (uniform != random_tick_mixed_state)
            uniform
        else
            self.sectionBlockState(resident, section, local_index, null);
    }

    fn modifiedBlockState(self: *const Blocks, entry: *const ModifiedSection, local_index: u16) i32 {
        if (entry.dense) return self.section_pages[entry.page_index][local_index];
        for (entry.sparse_indices[0..entry.sparse_count], 0..) |index, sparse_index| {
            if (index == local_index) return entry.sparse_states[sparse_index];
        }
        unreachable;
    }

    pub fn modifiedBlockStateAt(self: *const Blocks, table_index: usize, local_index: u16) i32 {
        return self.modifiedBlockState(&self.modified_sections[table_index], local_index);
    }

    pub fn generatedHeightChunkRef(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64) GeneratedHeightRef {
        if (self.residentChunkIndex(world, chunk)) |index| {
            const entry = &self.resident_chunks[index];
            entry.last_used_tick = tick;
            return .{ .index = @intCast(index), .entry = entry };
        }
        const shape = (self.generator orelse
            diagnostics.panic("world generator is not bound", &.{}))
            .generate(world, chunk) catch |err|
            diagnostics.panic(
                "failed to generate chunk (chunk x, chunk z, error)",
                &.{
                    diagnostics.integer(chunk.x),
                    diagnostics.integer(chunk.z),
                    diagnostics.text(@errorName(err)),
                },
            );
        const index = self.installResidentChunk(world, shape, tick, .generated_unknown) catch |err|
            diagnostics.panic("failed to generate resident chunk (chunk x, chunk z, error)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z), diagnostics.text(@errorName(err)) });
        return .{ .index = @intCast(index), .entry = &self.resident_chunks[index] };
    }

    pub fn requestChunkGeneration(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) void {
        if (self.residentChunk(world, chunk) != null) return;
        var probe = generatedHeightHash(world, chunk);
        var searched: usize = 0;
        while (searched < self.chunk_generation_request_lookup.len) : ({
            searched += 1;
            probe += 1;
        }) {
            const lookup_index =
                probe & (self.chunk_generation_request_lookup.len - 1);
            const encoded = self.chunk_generation_request_lookup[lookup_index];
            if (encoded == no_generation_request) {
                if (self.chunk_generation_request_count ==
                    self.chunk_generation_requests.len)
                    return;
                const index = self.chunk_generation_request_count;
                self.chunk_generation_request_count += 1;
                self.chunk_generation_requests[index] = .{ .world = world, .pos = chunk };
                self.chunk_generation_request_lookup[lookup_index] =
                    @intCast(index);
                return;
            }
            const pending = self.chunk_generation_requests[encoded];
            if (pending.world.eql(world) and geometry.sameChunk(pending.pos, chunk)) return;
        }
    }

    pub fn generateRequestedChunk(self: *Blocks, tick: u64) ChunkGenerationResult {
        if (self.chunk_generation_request_cursor ==
            self.chunk_generation_request_count)
            return .idle;
        const request = self.chunk_generation_requests[
            self.chunk_generation_request_cursor
        ];
        const world = request.world;
        const chunk = request.pos;
        if (self.residentChunk(world, chunk) != null) {
            self.chunk_generation_active = false;
            self.chunk_generation_request_cursor += 1;
            self.finishGenerationBatchIfDrained();
            return .complete;
        }
        if (self.resident_chunk_count == self.resident_chunks.len) {
            self.resident_pressure = true;
            return .backpressured;
        }
        const generated = (self.generator orelse
            diagnostics.panic("world generator is not bound", &.{}))
            .advance(world, chunk) catch |err|
            diagnostics.panic(
                "failed to generate terrain chunk (chunk x, chunk z, error)",
                &.{
                    diagnostics.integer(chunk.x),
                    diagnostics.integer(chunk.z),
                    diagnostics.text(@errorName(err)),
                },
            );
        const shape = generated orelse {
            self.chunk_generation_active = true;
            return .pending;
        };
        self.chunk_generation_active = false;
        _ = self.installResidentChunk(world, shape, tick, .generated_unknown) catch |err| switch (err) {
            error.ResidentChunkCapacity => {
                self.resident_pressure = true;
                return .backpressured;
            },
            else => diagnostics.panic(
                "failed to install generated resident chunk (chunk x, chunk z, error)",
                &.{
                    diagnostics.integer(chunk.x),
                    diagnostics.integer(chunk.z),
                    diagnostics.text(@errorName(err)),
                },
            ),
        };
        self.chunk_generation_request_cursor += 1;
        self.finishGenerationBatchIfDrained();
        return .complete;
    }

    pub fn beginChunkGenerationBatch(self: *Blocks) void {
        if (self.chunk_generation_active) {
            std.debug.assert(
                self.chunk_generation_request_cursor <
                    self.chunk_generation_request_count,
            );
            self.chunk_generation_requests[0] =
                self.chunk_generation_requests[
                    self.chunk_generation_request_cursor
                ];
            self.chunk_generation_request_count = 1;
        } else {
            self.chunk_generation_request_count = 0;
        }
        self.chunk_generation_request_cursor = 0;
        @memset(
            self.chunk_generation_request_lookup,
            no_generation_request,
        );
        if (self.chunk_generation_active)
            self.insertGenerationRequestLookup(0);
    }

    pub fn pendingChunkGenerationCount(self: *const Blocks) usize {
        return self.chunk_generation_request_count -
            self.chunk_generation_request_cursor;
    }

    fn finishGenerationBatchIfDrained(self: *Blocks) void {
        if (self.chunk_generation_request_cursor !=
            self.chunk_generation_request_count)
            return;
        self.chunk_generation_request_count = 0;
        self.chunk_generation_request_cursor = 0;
        self.chunk_generation_active = false;
        @memset(
            self.chunk_generation_request_lookup,
            no_generation_request,
        );
    }

    fn insertGenerationRequestLookup(self: *Blocks, request_index: u16) void {
        const request = self.chunk_generation_requests[request_index];
        var probe = generatedHeightHash(request.world, request.pos);
        for (0..self.chunk_generation_request_lookup.len) |_| {
            const lookup_index =
                probe & (self.chunk_generation_request_lookup.len - 1);
            if (self.chunk_generation_request_lookup[lookup_index] ==
                no_generation_request)
            {
                self.chunk_generation_request_lookup[lookup_index] =
                    request_index;
                return;
            }
            probe += 1;
        }
        unreachable;
    }

    /// Installs a complete generated or persisted chunk as canonical resident
    /// state. The shape is a compact complete representation of the terrain
    /// base; block queries never invoke the generator after this transition.
    pub fn installResidentChunk(self: *Blocks, world: world_identity.Handle, shape: terrain.ChunkShape, tick: u64, source: ResidentChunkSource) !usize {
        const chunk = geometry.ChunkPos{ .x = shape.chunk_x, .z = shape.chunk_z };
        const dirty = source == .generated_new;
        const persistence_known = source != .generated_unknown;
        if (self.residentChunkIndex(world, chunk)) |index| {
            const entry = &self.resident_chunks[index];
            const content_revision = self.takeSectionRevision();
            self.resident_binding_revision +%= 1;
            self.releaseResidentRandomTickMasks(entry);
            self.storeResidentShape(index, entry, shape, shape.storage);
            entry.last_used_tick = tick;
            entry.persistence_known = persistence_known;
            entry.dirty = dirty;
            entry.revision = if (dirty) content_revision else 0;
            entry.content_revision = content_revision;
            self.refreshResidentDerived(entry);
            return index;
        }
        self.ensureResidentPool();
        if (self.free_resident_chunk_count == 0) {
            self.resident_pressure = true;
            return error.ResidentChunkCapacity;
        }
        self.free_resident_chunk_count -= 1;
        const index: usize = self.free_resident_chunks[self.free_resident_chunk_count];
        const content_revision = self.takeSectionRevision();
        const entry = &self.resident_chunks[index];
        entry.* = .{
            .valid = true,
            .dirty = dirty,
            .persistence_known = persistence_known,
            .chunk = chunk,
            .world = world,
            .last_used_tick = tick,
            .revision = if (dirty) content_revision else 0,
            .content_revision = content_revision,
        };
        self.storeResidentShape(index, entry, shape, shape.storage);
        self.refreshResidentDerived(entry);
        try self.insertResidentLookup(world, chunk, index);
        self.active_resident_indices[self.resident_chunk_count] = @intCast(index);
        self.resident_active_positions[index] = @intCast(self.resident_chunk_count);
        self.resident_chunk_count += 1;
        return index;
    }

    fn storeResidentShape(
        self: *Blocks,
        index: usize,
        entry: *GeneratedHeightChunk,
        shape: terrain.ChunkShape,
        source: []const u8,
    ) void {
        std.debug.assert(shape.storage_len <= terrain.chunk_storage_capacity);
        const offset = index * terrain.chunk_storage_capacity;
        const storage = self.resident_shape_storage[offset..][0..terrain.chunk_storage_capacity];
        @memcpy(storage[0..shape.storage_len], source[0..shape.storage_len]);
        entry.shape = shape;
        entry.shape.storage = storage;
    }

    fn releaseResidentShape(_: *Blocks, entry: *GeneratedHeightChunk) void {
        entry.shape.storage = &.{};
    }

    fn refreshResidentDerived(self: *Blocks, entry: *GeneratedHeightChunk) void {
        entry.base_grass_spread_possible = entry.shape.grass_spread_possible;
        var masks: [config.overworld_section_count][terrain.random_tick_mask_words]u64 = undefined;
        entry.random_tick_sections = terrain.fillChunkRandomTickMasksFromShape(
            &entry.shape,
            &entry.heights,
            &entry.grass_above_blocked,
            &masks,
            &entry.random_tickable_counts,
        );
        entry.random_tick_mask_handles = [_]u16{0} ** config.overworld_section_count;
        entry.random_tick_uniform_states = [_]i32{random_tick_mixed_state} ** config.overworld_section_count;
        var section_mask = entry.random_tick_sections;
        while (section_mask != 0) {
            const section: usize = @intCast(@ctz(section_mask));
            section_mask &= section_mask - 1;
            var first_state: ?i32 = null;
            var mixed_states = false;
            for (masks[section], 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const bit: u6 = @intCast(@ctz(remaining));
                    remaining &= remaining - 1;
                    const local_index: u16 = @intCast(word_index * 64 + bit);
                    const local_x: i32 = local_index & 15;
                    const local_z: i32 = (local_index >> 4) & 15;
                    const y = sectionWorldY(section, (local_index >> 8) & 15);
                    const state = terrain.blockAtFromShape(
                        &entry.shape,
                        entry.chunk.x * 16 + local_x,
                        y,
                        entry.chunk.z * 16 + local_z,
                    );
                    if (first_state) |uniform_state| {
                        if (uniform_state != state) mixed_states = true;
                    } else first_state = state;
                }
            }
            entry.random_tick_uniform_states[section] = if (mixed_states) random_tick_mixed_state else first_state.?;
            var columns_are_exact = true;
            var expected_count: u16 = 0;
            for (entry.heights, 0..) |height, column| {
                if (@divFloor(@as(i32, height) - @as(i32, config.world_min_y), 16) != section) continue;
                expected_count += 1;
                const local_y: u16 = @intCast((@as(i32, height) - @as(i32, config.world_min_y)) & 15);
                const local_index: u16 = @intCast(column | (@as(usize, local_y) << 8));
                if (masks[section][local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) == 0) {
                    columns_are_exact = false;
                    break;
                }
            }
            if (expected_count != entry.random_tickable_counts[section]) columns_are_exact = false;
            if (columns_are_exact) {
                entry.random_tick_mask_handles[section] = random_tick_mask_columns;
                continue;
            }
            const handle = self.allocateRandomTickMask() orelse {
                entry.random_tick_mask_handles[section] = random_tick_mask_unindexed;
                continue;
            };
            entry.random_tick_mask_handles[section] = handle + 1;
            @memcpy(&self.random_tick_masks[handle], &masks[section]);
        }
    }

    fn allocateRandomTickMask(self: *Blocks) ?u16 {
        self.ensureRandomTickMaskPool();
        if (self.free_random_tick_mask_count == 0) return null;
        self.free_random_tick_mask_count -= 1;
        return self.free_random_tick_masks[self.free_random_tick_mask_count];
    }

    fn releaseResidentRandomTickMasks(self: *Blocks, entry: *GeneratedHeightChunk) void {
        for (&entry.random_tick_mask_handles) |*encoded| {
            if (encoded.* != 0 and encoded.* != random_tick_mask_unindexed and encoded.* != random_tick_mask_columns) {
                self.free_random_tick_masks[self.free_random_tick_mask_count] = encoded.* - 1;
                self.free_random_tick_mask_count += 1;
            }
            encoded.* = 0;
        }
    }

    fn ensureRandomTickMaskPool(self: *Blocks) void {
        if (self.random_tick_mask_pool_initialized) return;
        for (self.free_random_tick_masks, 0..) |*entry, index|
            entry.* = @intCast(self.free_random_tick_masks.len - 1 - index);
        self.free_random_tick_mask_count = self.free_random_tick_masks.len;
        self.random_tick_mask_pool_initialized = true;
    }

    pub fn residentChunk(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?*const GeneratedHeightChunk {
        const index = self.residentChunkIndex(world, chunk) orelse return null;
        return &self.resident_chunks[index];
    }

    pub fn residentChunkSlot(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?u16 {
        return @intCast(self.residentChunkIndex(world, chunk) orelse return null);
    }

    pub fn residentBindingRevision(self: *const Blocks) u64 {
        return self.resident_binding_revision;
    }

    pub fn residentChunkRef(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64) ?GeneratedHeightRef {
        const index = self.residentChunkIndex(world, chunk) orelse return null;
        const entry = &self.resident_chunks[index];
        entry.last_used_tick = tick;
        return .{ .index = @intCast(index), .entry = entry };
    }

    pub fn residentChunkMut(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?*GeneratedHeightChunk {
        const index = self.residentChunkIndex(world, chunk) orelse return null;
        return &self.resident_chunks[index];
    }

    pub fn residentChunkCount(self: *const Blocks) usize {
        return self.resident_chunk_count;
    }

    pub fn beginResidentTickets(self: *Blocks) void {
        self.resident_ticket_previous_generation = self.resident_ticket_generation;
        self.resident_ticket_generation +%= 1;
        if (self.resident_ticket_generation == 0) {
            for (self.active_resident_indices[0..self.resident_chunk_count]) |index|
                self.resident_chunks[index].ticket_generation = 0;
            self.resident_ticket_generation = 1;
            self.resident_ticket_previous_generation = 0;
        }
    }

    pub fn ticketResidentChunk(
        self: *Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
    ) bool {
        const resident = self.residentChunkMut(world, chunk) orelse return false;
        resident.ticket_generation = self.resident_ticket_generation;
        return true;
    }

    pub fn ticketResidentIndex(self: *Blocks, index: usize) bool {
        if (index >= self.resident_chunks.len or !self.resident_chunks[index].valid)
            return false;
        self.resident_chunks[index].ticket_generation = self.resident_ticket_generation;
        return true;
    }

    pub fn residentChunkTicketed(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
    ) bool {
        const resident = self.residentChunk(world, chunk) orelse return false;
        return self.ticketActive(resident);
    }

    pub fn evictUnticketedChunks(self: *Blocks) usize {
        var evicted: usize = 0;
        var position = self.resident_chunk_count;
        while (position != 0) {
            position -= 1;
            const index = self.active_resident_indices[position];
            const resident = self.resident_chunks[index];
            if (self.ticketActive(&resident) or !resident.persistence_known or
                self.chunkDirty(resident.world, resident.chunk)) continue;
            std.debug.assert(self.evictChunk(resident.world, resident.chunk));
            evicted += 1;
        }
        self.resident_pressure = false;
        return evicted;
    }

    pub fn releaseStreamedChunk(
        self: *Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
    ) ?u16 {
        const resident = self.residentChunk(world, chunk) orelse return null;
        if (self.ticketActive(resident) or
            !resident.persistence_known or self.chunkDirty(world, chunk)) return null;
        const index = self.residentChunkIndex(world, chunk) orelse unreachable;
        std.debug.assert(self.evictChunk(world, chunk));
        return @intCast(index);
    }

    fn ticketActive(self: *const Blocks, resident: *const GeneratedHeightChunk) bool {
        return resident.ticket_generation == self.resident_ticket_generation or
            (self.resident_ticket_previous_generation != 0 and
                resident.ticket_generation == self.resident_ticket_previous_generation);
    }

    pub fn residentPressure(self: *const Blocks) bool {
        return self.resident_pressure;
    }

    pub fn requestResidentEviction(self: *Blocks) void {
        self.resident_pressure = true;
    }

    pub fn clearResidentPressure(self: *Blocks) void {
        self.resident_pressure = false;
    }

    fn residentChunkIndex(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
        if (!self.resident_pool_initialized) return null;
        var probe = generatedHeightHash(world, chunk);
        var searched: usize = 0;
        while (searched < self.resident_chunk_lookup.len) : ({
            searched += 1;
            probe += 1;
        }) {
            const slot = self.resident_chunk_lookup[probe & (self.resident_chunk_lookup.len - 1)];
            if (slot == resident_chunk_empty) return null;
            const entry = &self.resident_chunks[slot];
            if (entry.valid and entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) return slot;
        }
        return null;
    }

    fn ensureResidentPool(self: *Blocks) void {
        if (self.resident_pool_initialized) return;
        @memset(self.resident_chunk_lookup, resident_chunk_empty);
        for (0..self.free_resident_chunks.len) |index|
            self.free_resident_chunks[index] = @intCast(self.free_resident_chunks.len - 1 - index);
        self.free_resident_chunk_count = self.free_resident_chunks.len;
        self.resident_pool_initialized = true;
    }

    fn insertResidentLookup(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, resident_index: usize) !void {
        var probe = generatedHeightHash(world, chunk);
        for (0..self.resident_chunk_lookup.len) |_| {
            const index = probe & (self.resident_chunk_lookup.len - 1);
            if (self.resident_chunk_lookup[index] == resident_chunk_empty) {
                self.resident_chunk_lookup[index] = @intCast(resident_index);
                return;
            }
            probe += 1;
        }
        return error.ResidentChunkLookupFull;
    }

    pub fn generatedHeightChunk(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64) *const GeneratedHeightChunk {
        return self.generatedHeightChunkRef(world, chunk, tick).entry;
    }

    pub fn ensureChunkAt(self: *Blocks, world: world_identity.Handle, x: i32, z: i32, tick: u64) void {
        _ = self.generatedHeightChunkRef(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }, tick);
    }

    pub fn blockRectangleResident(self: *const Blocks, world: world_identity.Handle, min_x: i32, max_x: i32, min_z: i32, max_z: i32) bool {
        var chunk_z = @divFloor(min_z, 16);
        const last_z = @divFloor(max_z, 16);
        while (chunk_z <= last_z) : (chunk_z += 1) {
            var chunk_x = @divFloor(min_x, 16);
            const last_x = @divFloor(max_x, 16);
            while (chunk_x <= last_x) : (chunk_x += 1) {
                if (self.residentChunk(world, .{ .x = chunk_x, .z = chunk_z }) == null) return false;
            }
        }
        return true;
    }

    /// Resolve a stable resident-chunk hint held by a plugin. Entries remain
    /// stable until explicit clean-chunk eviction.
    pub fn generatedHeightChunkHint(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64, hint: *u16) *const GeneratedHeightChunk {
        const index: usize = hint.*;
        if (index < self.resident_chunks.len) {
            const entry = &self.resident_chunks[index];
            if (entry.valid and entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) {
                entry.last_used_tick = tick;
                return entry;
            }
        }
        const resolved = self.generatedHeightChunkRef(world, chunk, tick);
        hint.* = resolved.index;
        return resolved.entry;
    }

    /// Resolve a resident hint without dirtying the chunk's LRU cache line.
    /// Long-lived simulation worksets already keep these chunks referenced;
    /// writing `last_used_tick` for every chunk on every tick needlessly
    /// turns a read-only traversal into thousands of scattered writes.
    pub fn generatedHeightChunkHintNoTouch(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64, hint: *u16) *const GeneratedHeightChunk {
        const index: usize = hint.*;
        if (index < self.resident_chunks.len) {
            const entry = &self.resident_chunks[index];
            if (entry.valid and entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) return entry;
        }
        const resolved = self.generatedHeightChunkRef(world, chunk, tick);
        hint.* = resolved.index;
        return resolved.entry;
    }

    pub fn setBlock(self: *Blocks, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !bool {
        std.debug.assert(world_identity.valid(world));
        std.debug.assert(self.modified_block_count <= self.modified_sections.len * blocks_per_section);
        std.debug.assert(self.modified_section_count <= self.modified_sections.len);
        const section = sectionIndexForY(pos.y) orelse return false;
        const chunk = geometry.chunkForBlock(pos);
        const generated_ref = self.generatedHeightChunkRef(world, chunk, 0);
        const local_index = localBlockIndex(pos);
        const resident = &self.resident_chunks[generated_ref.index];
        const generated = terrain.blockAtFromShape(&resident.shape, pos.x, pos.y, pos.z);
        if (self.modifiedSectionIndex(resident, section)) |table_index|
            return self.setModifiedBlock(world, resident, table_index, section, local_index, generated, pos, block_state);
        if (block_state == generated) return false;
        try self.createBlockModification(resident, section, local_index, generated, block_state);
        self.recordBlockMutation(world, pos, generated, block_state);
        std.debug.assert(self.blockAt(world, pos) == block_state);
        return true;
    }

    fn setModifiedBlock(self: *Blocks, world: world_identity.Handle, resident: *GeneratedHeightChunk, table_index: usize, section: usize, local_index: u16, generated: i32, pos: geometry.BlockPos, block_state: i32) !bool {
        const entry = &self.modified_sections[table_index];
        const previous = self.sectionBlockState(resident, section, local_index, table_index);
        if (previous == block_state) return false;
        const sparse_index = findSparseIndex(entry, local_index);
        if (!entry.dense and block_state != generated and sparse_index == null and
            entry.sparse_count == sparse_section_change_capacity) try self.promoteModifiedSection(entry);
        self.storeModifiedBlock(entry, local_index, sparse_index, generated, block_state);
        const revision = self.markSectionChanged(resident, entry, section);
        updateRandomTickCount(entry, previous, block_state);
        updateModifiedCount(self, entry, previous, generated, block_state);
        entry.revision = revision;
        const bit = @as(u64, 1) << @intCast(local_index & 63);
        if (block_state == generated)
            entry.modified_bits[local_index / 64] &= ~bit
        else
            entry.modified_bits[local_index / 64] |= bit;
        if (entry.modified_count == 0) self.releaseModifiedSection(resident, table_index);
        self.recordBlockMutation(world, pos, previous, block_state);
        std.debug.assert(self.blockAt(world, pos) == block_state);
        return true;
    }

    fn createBlockModification(self: *Blocks, resident: *GeneratedHeightChunk, section: usize, local_index: u16, generated: i32, block_state: i32) !void {
        const revision = self.takeSectionRevision();
        resident.dirty = true;
        resident.revision = revision;
        resident.content_revision = revision;
        resident.dirty_section_mask |= @as(u32, 1) << @intCast(section);
        const table_index = try self.createModifiedSection(resident, section);
        const entry = &self.modified_sections[table_index];
        entry.sparse_indices[0] = local_index;
        entry.sparse_states[0] = block_state;
        entry.sparse_count = 1;
        if (isRandomTickableBlock(generated) and !isRandomTickableBlock(block_state)) entry.random_tickable_count -= 1;
        if (!isRandomTickableBlock(generated) and isRandomTickableBlock(block_state)) entry.random_tickable_count += 1;
        entry.modified_count = 1;
        entry.modified_bits[local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
        entry.dirty = true;
        entry.revision = revision;
        self.modified_block_count += 1;
    }

    fn findSparseIndex(entry: *const ModifiedSection, local_index: u16) ?usize {
        if (entry.dense) return null;
        for (entry.sparse_indices[0..entry.sparse_count], 0..) |index, position|
            if (index == local_index) return position;
        return null;
    }

    fn storeModifiedBlock(self: *Blocks, entry: *ModifiedSection, local_index: u16, sparse_index: ?usize, generated: i32, block_state: i32) void {
        if (entry.dense) {
            self.section_pages[entry.page_index][local_index] = block_state;
            return;
        }
        if (block_state == generated) {
            const remove = sparse_index orelse unreachable;
            entry.sparse_count -= 1;
            entry.sparse_indices[remove] = entry.sparse_indices[entry.sparse_count];
            entry.sparse_states[remove] = entry.sparse_states[entry.sparse_count];
        } else if (sparse_index) |index| {
            entry.sparse_states[index] = block_state;
        } else {
            entry.sparse_indices[entry.sparse_count] = local_index;
            entry.sparse_states[entry.sparse_count] = block_state;
            entry.sparse_count += 1;
        }
    }

    fn markSectionChanged(self: *Blocks, resident: *GeneratedHeightChunk, entry: *ModifiedSection, section: usize) u64 {
        const revision = self.takeSectionRevision();
        resident.dirty = true;
        resident.revision = revision;
        resident.content_revision = revision;
        resident.dirty_section_mask |= @as(u32, 1) << @intCast(section);
        entry.dirty = true;
        return revision;
    }

    fn updateRandomTickCount(entry: *ModifiedSection, previous: i32, block_state: i32) void {
        const previous_tickable = isRandomTickableBlock(previous);
        const next_tickable = isRandomTickableBlock(block_state);
        if (previous_tickable and !next_tickable) entry.random_tickable_count -= 1;
        if (!previous_tickable and next_tickable) entry.random_tickable_count += 1;
    }

    fn updateModifiedCount(self: *Blocks, entry: *ModifiedSection, previous: i32, generated: i32, block_state: i32) void {
        if (previous == generated) {
            entry.modified_count += 1;
            self.modified_block_count += 1;
        } else if (block_state == generated) {
            entry.modified_count -= 1;
            self.modified_block_count -= 1;
        }
    }

    pub fn findModifiedSection(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize) ?usize {
        std.debug.assert(section < config.overworld_section_count);
        const resident = self.residentChunk(world, chunk) orelse return null;
        return self.modifiedSectionIndex(resident, section);
    }

    pub fn sectionContentRevision(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
        section: usize,
    ) ?u64 {
        const resident = self.residentChunk(world, chunk) orelse return null;
        const index = self.modifiedSectionIndex(resident, section) orelse return 0;
        const revision = self.modified_sections[index].revision;
        return if (revision == 0) resident.content_revision else revision;
    }

    pub fn modifiedSectionIndex(self: *const Blocks, resident: *const GeneratedHeightChunk, section: usize) ?usize {
        std.debug.assert(section < config.overworld_section_count);
        const encoded = resident.modified_section_indices[section];
        if (encoded == no_modified_section_index) return null;
        const index: usize = encoded;
        std.debug.assert(index < self.modified_sections.len);
        const entry = &self.modified_sections[index];
        std.debug.assert(entry.active and entry.world.eql(resident.world));
        std.debug.assert(geometry.sameChunk(entry.chunk, resident.chunk) and entry.section == section);
        return index;
    }

    pub fn sectionBlocks(self: *const Blocks, table_index: usize) *const [blocks_per_section]i32 {
        std.debug.assert(table_index < self.modified_sections.len);
        const entry = &self.modified_sections[table_index];
        std.debug.assert(entry.active and entry.dense);
        return &self.section_pages[entry.page_index];
    }

    pub fn copySectionBlocks(self: *const Blocks, table_index: usize, output: *[blocks_per_section]i32) void {
        const entry = &self.modified_sections[table_index];
        std.debug.assert(entry.active);
        if (entry.dense) {
            @memcpy(output, &self.section_pages[entry.page_index]);
            return;
        }
        const resident = self.residentChunk(entry.world, entry.chunk) orelse unreachable;
        terrain.fillSectionFromShape(&resident.shape, entry.section, output);
        for (entry.sparse_indices[0..entry.sparse_count], entry.sparse_states[0..entry.sparse_count]) |local_index, state|
            output[local_index] = state;
    }

    pub fn sectionBlockIsModified(self: *const Blocks, table_index: usize, local_index: u16) bool {
        const entry = &self.modified_sections[table_index];
        return entry.modified_bits[local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) != 0;
    }

    pub fn loadSection(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, blocks: *const [blocks_per_section]i32) !void {
        const resident = self.residentChunk(world, chunk) orelse return error.ChunkNotResident;
        try self.loadSectionFromShape(world, chunk, section, blocks, &resident.shape);
    }

    pub fn availableSectionPages(self: *const Blocks) usize {
        return if (self.page_pool_initialized) self.free_section_page_count else self.section_pages.len;
    }

    pub fn sectionStorageNeedsPage(section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) bool {
        return countModifiedBlocks(section, blocks, shape) > sparse_section_change_capacity;
    }

    pub fn loadSectionFromShape(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) !void {
        const resident = self.residentChunkMut(world, chunk) orelse return error.ChunkNotResident;
        if (self.modifiedSectionIndex(resident, section)) |table_index| {
            const entry = &self.modified_sections[table_index];
            self.modified_block_count -= entry.modified_count;
            const modified_count = countModifiedBlocks(section, blocks, shape);
            if (modified_count == 0) {
                self.releaseModifiedSection(resident, table_index);
                resident.content_revision = self.takeSectionRevision();
                self.invalidateResidentProjections();
                return;
            }
            try self.assignModifiedSection(entry, section, blocks, shape, modified_count);
            resident.dirty_section_mask &= ~(@as(u32, 1) << @intCast(section));
            resident.content_revision = self.takeSectionRevision();
            self.modified_block_count += modified_count;
            self.invalidateResidentProjections();
            return;
        }
        const modified_count = countModifiedBlocks(section, blocks, shape);
        if (modified_count == 0) return;
        const table_index = try self.createModifiedSection(resident, section);
        const entry = &self.modified_sections[table_index];
        self.assignModifiedSection(entry, section, blocks, shape, modified_count) catch |err| {
            self.releaseModifiedSection(resident, table_index);
            return err;
        };
        resident.content_revision = self.takeSectionRevision();
        self.modified_block_count += modified_count;
        self.invalidateResidentProjections();
    }

    fn assignModifiedSection(self: *Blocks, entry: *ModifiedSection, section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape, modified_count: u16) !void {
        if (entry.dense) {
            self.free_section_pages[self.free_section_page_count] = entry.page_index;
            self.free_section_page_count += 1;
        }
        entry.dense = false;
        entry.sparse_count = 0;
        entry.modified_count = modified_count;
        entry.random_tickable_count = countRandomTickableBlocks(blocks);
        entry.dirty = false;
        entry.revision = 0;
        buildModifiedBits(section, blocks, shape, &entry.modified_bits);
        if (modified_count <= sparse_section_change_capacity) {
            var generated: [blocks_per_section]i32 = undefined;
            terrain.fillSectionFromShape(shape, section, &generated);
            for (blocks, &generated, 0..) |state, base_state, local_index| {
                if (state == base_state) continue;
                const sparse_index = entry.sparse_count;
                entry.sparse_indices[sparse_index] = @intCast(local_index);
                entry.sparse_states[sparse_index] = state;
                entry.sparse_count += 1;
            }
            return;
        }
        self.ensurePagePool();
        if (self.free_section_page_count == 0) return error.WorldSectionCapacity;
        self.free_section_page_count -= 1;
        entry.page_index = self.free_section_pages[self.free_section_page_count];
        @memcpy(&self.section_pages[entry.page_index], blocks);
        entry.dense = true;
    }

    pub fn markChunkClean(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) void {
        const resident = self.residentChunkMut(world, chunk) orelse return;
        resident.dirty = false;
        var mask = resident.dirty_section_mask;
        while (mask != 0) {
            const section: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            const table_index = self.modifiedSectionIndex(resident, section) orelse continue;
            self.modified_sections[table_index].dirty = false;
        }
        resident.dirty_section_mask = 0;
    }

    pub fn markChunkCleanThrough(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, revision: u64) void {
        const resident = self.residentChunkMut(world, chunk) orelse return;
        resident.persistence_known = true;
        if (resident.dirty and resident.revision <= revision) resident.dirty = false;
        var mask = resident.dirty_section_mask;
        while (mask != 0) {
            const section: usize = @intCast(@ctz(mask));
            const bit = @as(u32, 1) << @intCast(section);
            mask &= mask - 1;
            const table_index = self.modifiedSectionIndex(resident, section) orelse {
                resident.dirty_section_mask &= ~bit;
                continue;
            };
            const entry = &self.modified_sections[table_index];
            if (entry.dirty and entry.revision <= revision) {
                entry.dirty = false;
                resident.dirty_section_mask &= ~bit;
            }
        }
    }

    pub fn chunkDirtyRevision(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) u64 {
        const resident = self.residentChunk(world, chunk) orelse return 0;
        var revision: u64 = 0;
        if (resident.dirty) revision = resident.revision;
        var mask = resident.dirty_section_mask;
        while (mask != 0) {
            const section: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            const table_index = self.modifiedSectionIndex(resident, section) orelse continue;
            const entry = self.modified_sections[table_index];
            if (entry.dirty) revision = @max(revision, entry.revision);
        }
        return revision;
    }

    pub fn chunkDirty(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        const resident = self.residentChunk(world, chunk) orelse return false;
        return resident.dirty or resident.dirty_section_mask != 0;
    }

    pub fn evictChunk(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        if (self.chunkDirty(world, chunk)) return false;
        var removed = false;
        const resident = self.residentChunkMut(world, chunk) orelse return false;
        var section_mask = resident.modified_section_mask;
        while (section_mask != 0) {
            const section: usize = @intCast(@ctz(section_mask));
            section_mask &= section_mask - 1;
            const table_index = self.modifiedSectionIndex(resident, section) orelse continue;
            const entry = self.modified_sections[table_index];
            self.modified_block_count -= entry.modified_count;
            self.releaseModifiedSection(resident, table_index);
            removed = true;
        }
        if (self.residentChunkIndex(world, chunk)) |resident_index| {
            self.resident_binding_revision +%= 1;
            self.removeResidentLookup(world, chunk, resident_index);
            self.releaseResidentRandomTickMasks(&self.resident_chunks[resident_index]);
            self.releaseResidentShape(&self.resident_chunks[resident_index]);
            const active_position: usize = self.resident_active_positions[resident_index];
            std.debug.assert(self.active_resident_indices[active_position] == resident_index);
            self.resident_chunk_count -= 1;
            if (active_position != self.resident_chunk_count) {
                const moved_index = self.active_resident_indices[self.resident_chunk_count];
                self.active_resident_indices[active_position] = moved_index;
                self.resident_active_positions[moved_index] = @intCast(active_position);
            }
            self.resident_chunks[resident_index] = .{};
            self.free_resident_chunks[self.free_resident_chunk_count] = @intCast(resident_index);
            self.free_resident_chunk_count += 1;
            removed = true;
        }
        return removed;
    }

    fn removeResidentLookup(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, resident_index: usize) void {
        const mask = self.resident_chunk_lookup.len - 1;
        var probe = generatedHeightHash(world, chunk);
        var found: ?usize = null;
        for (0..self.resident_chunk_lookup.len) |_| {
            const index = probe & mask;
            const slot = self.resident_chunk_lookup[index];
            if (slot == resident_chunk_empty) return;
            if (slot == resident_index) {
                found = index;
                break;
            }
            probe += 1;
        }
        var hole = found orelse return;
        self.resident_chunk_lookup[hole] = resident_chunk_empty;
        var scan = (hole + 1) & mask;
        for (0..self.resident_chunk_lookup.len) |_| {
            if (self.resident_chunk_lookup[scan] == resident_chunk_empty) return;
            const slot = self.resident_chunk_lookup[scan];
            const entry = self.resident_chunks[slot];
            const ideal = generatedHeightHash(entry.world, entry.chunk) & mask;
            if (probeDistance(ideal, hole, mask) < probeDistance(ideal, scan, mask)) {
                self.resident_chunk_lookup[hole] = slot;
                self.resident_chunk_lookup[scan] = resident_chunk_empty;
                hole = scan;
            }
            scan = (scan + 1) & mask;
        }
        unreachable;
    }

    fn countModifiedBlocks(section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) u16 {
        var generated: [blocks_per_section]i32 = undefined;
        terrain.fillSectionFromShape(shape, section, &generated);
        var count: u16 = 0;
        for (blocks, &generated) |block_state, generated_state| if (block_state != generated_state) {
            count += 1;
        };
        return count;
    }

    fn buildModifiedBits(section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape, output: *[blocks_per_section / 64]u64) void {
        var generated: [blocks_per_section]i32 = undefined;
        terrain.fillSectionFromShape(shape, section, &generated);
        @memset(output, 0);
        for (blocks, &generated, 0..) |block_state, generated_state, index| {
            if (block_state != generated_state)
                output[index / 64] |= @as(u64, 1) << @intCast(index & 63);
        }
    }

    fn countRandomTickableBlocks(blocks: *const [blocks_per_section]i32) u16 {
        var count: u16 = 0;
        for (blocks) |block_state| if (isRandomTickableBlock(block_state)) {
            count += 1;
        };
        return count;
    }

    fn takeSectionRevision(self: *Blocks) u64 {
        const revision = self.next_section_revision;
        self.next_section_revision +%= 1;
        if (self.next_section_revision == 0) self.next_section_revision = 1;
        return revision;
    }

    fn invalidateResidentProjections(self: *Blocks) void {
        self.resident_binding_revision +%= 1;
        if (self.resident_binding_revision == 0) self.resident_binding_revision = 1;
    }

    fn recordBlockMutation(self: *Blocks, world: world_identity.Handle, pos: geometry.BlockPos, previous_state: i32, block_state: i32) void {
        self.block_mutation_sequence +%= 1;
        if (self.block_mutation_sequence == 0) self.block_mutation_sequence = 1;
        self.block_mutations[(self.block_mutation_sequence - 1) % self.block_mutations.len] = .{
            .world = world,
            .pos = pos,
            .previous_state = previous_state,
            .block_state = block_state,
        };
    }

    fn createModifiedSection(self: *Blocks, resident: *GeneratedHeightChunk, section: usize) !usize {
        if (self.modified_section_count == self.modified_sections.len) return error.WorldSectionCapacity;
        self.ensureModifiedSectionPool();
        const chunk = resident.chunk;
        std.debug.assert(resident.modified_section_indices[section] == no_modified_section_index);
        std.debug.assert(self.free_modified_section_count != 0);
        self.free_modified_section_count -= 1;
        const index: usize = self.free_modified_sections[self.free_modified_section_count];
        self.modified_sections[index] = .{
            .active = true,
            .world = resident.world,
            .chunk = chunk,
            .section = @intCast(section),
            .random_tickable_count = resident.random_tickable_counts[section],
        };
        resident.modified_section_mask |= @as(u32, 1) << @intCast(section);
        resident.modified_section_indices[section] = @intCast(index);
        self.modified_section_count += 1;
        std.debug.assert(self.modifiedSectionIndex(resident, section) == index);
        return index;
    }

    fn promoteModifiedSection(self: *Blocks, entry: *ModifiedSection) !void {
        std.debug.assert(entry.active and !entry.dense);
        self.ensurePagePool();
        if (self.free_section_page_count == 0) return error.WorldSectionCapacity;
        self.free_section_page_count -= 1;
        const page_index = self.free_section_pages[self.free_section_page_count];
        const resident = self.residentChunk(entry.world, entry.chunk) orelse unreachable;
        terrain.fillSectionFromShape(&resident.shape, entry.section, &self.section_pages[page_index]);
        for (entry.sparse_indices[0..entry.sparse_count], entry.sparse_states[0..entry.sparse_count]) |local_index, state|
            self.section_pages[page_index][local_index] = state;
        entry.page_index = page_index;
        entry.dense = true;
        entry.sparse_count = 0;
    }

    fn releaseModifiedSection(self: *Blocks, resident: *GeneratedHeightChunk, table_index: usize) void {
        std.debug.assert(table_index < self.modified_sections.len);
        std.debug.assert(self.modified_sections[table_index].active);
        const released = self.modified_sections[table_index];
        std.debug.assert(resident.world.eql(released.world));
        std.debug.assert(geometry.sameChunk(resident.chunk, released.chunk));
        const section_bit = @as(u32, 1) << @intCast(released.section);
        resident.modified_section_mask &= ~section_bit;
        resident.dirty_section_mask &= ~section_bit;
        resident.modified_section_indices[released.section] = no_modified_section_index;
        self.modified_sections[table_index] = .{};
        self.free_modified_sections[self.free_modified_section_count] = @intCast(table_index);
        self.free_modified_section_count += 1;
        if (released.dense) {
            self.free_section_pages[self.free_section_page_count] = released.page_index;
            self.free_section_page_count += 1;
        }
        self.modified_section_count -= 1;
        std.debug.assert(self.free_section_page_count <= self.section_pages.len);
    }

    fn ensureModifiedSectionPool(self: *Blocks) void {
        if (self.modified_section_pool_initialized) return;
        for (self.free_modified_sections, 0..) |*entry, index|
            entry.* = @intCast(self.free_modified_sections.len - 1 - index);
        self.free_modified_section_count = self.free_modified_sections.len;
        self.modified_section_pool_initialized = true;
    }

    fn ensurePagePool(self: *Blocks) void {
        if (self.page_pool_initialized) return;
        for (self.free_section_pages, 0..) |*entry, index|
            entry.* = @intCast(self.free_section_pages.len - 1 - index);
        self.free_section_page_count = self.free_section_pages.len;
        self.page_pool_initialized = true;
    }

    pub fn fillGeneratedSection(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, output: *[blocks_per_section]i32) void {
        const resident = self.residentChunk(world, chunk) orelse
            diagnostics.panic("section materialization requested for non-resident chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        terrain.fillSectionFromShape(&resident.shape, section, output);
    }

    pub fn uniformSectionState(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
        section: usize,
    ) ?i32 {
        const resident = self.residentChunk(world, chunk) orelse return null;
        if (resident.modified_section_mask &
            (@as(u32, 1) << @intCast(section)) != 0)
            return null;
        return terrain.uniformSectionState(&resident.shape, section);
    }

    pub fn generatedSectionVisibility(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
        section: usize,
    ) ?terrain.SectionVisibility {
        const resident = self.residentChunk(world, chunk) orelse return null;
        if (resident.modified_section_mask &
            (@as(u32, 1) << @intCast(section)) != 0)
            return null;
        return resident.shape.section_visibility[section];
    }

    pub fn surfaceHeightAt(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.residentChunk(world, chunk) orelse
            diagnostics.panic("surface query requested for non-resident chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        return resident.shape.heights[@as(usize, @intCast(z & 15)) * 16 + @as(usize, @intCast(x & 15))];
    }

    pub fn highestGeneratedY(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.residentChunk(world, chunk) orelse
            diagnostics.panic("height query requested for non-resident chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        return terrain.highestYFromShape(&resident.shape, @intCast(x & 15), @intCast(z & 15));
    }

    pub fn highestBlockYAt(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.residentChunk(world, chunk) orelse
            diagnostics.panic("height query requested for non-resident chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        if (resident.modified_section_mask == 0)
            return terrain.highestYFromShape(
                &resident.shape,
                @intCast(x & 15),
                @intCast(z & 15),
            );
        const highest_modified_section: usize =
            31 - @clz(resident.modified_section_mask);
        var y = @max(
            @as(i32, terrain.highestYFromShape(
                &resident.shape,
                @intCast(x & 15),
                @intCast(z & 15),
            )),
            @as(i32, sectionWorldY(highest_modified_section, 15)),
        );
        while (y >= config.world_min_y) : (y -= 1) {
            if (self.blockAtResident(
                resident,
                .{ .x = x, .y = @intCast(y), .z = z },
            ) != air_block_state) return @intCast(y);
        }
        return config.world_min_y - 1;
    }
};

pub fn sectionIndexForY(y: i16) ?usize {
    if (y < config.world_min_y or y > world_top_y) return null;
    return @intCast(@divFloor(@as(i32, y) - @as(i32, config.world_min_y), 16));
}

pub fn generatedSectionMayContainBlocks(section: usize) bool {
    return terrain.sectionMayContainBlocks(section);
}

fn localBlockIndex(pos: geometry.BlockPos) u16 {
    const x: u16 = @intCast(pos.x & 15);
    const y: u16 = @intCast((@as(i32, pos.y) - @as(i32, config.world_min_y)) & 15);
    const z: u16 = @intCast(pos.z & 15);
    return x | (z << 4) | (y << 8);
}

pub fn localBlockIndexForPosition(pos: geometry.BlockPos) u16 {
    return localBlockIndex(pos);
}

fn generatedHeightHash(world: world_identity.Handle, chunk: geometry.ChunkPos) usize {
    std.debug.assert(world_identity.valid(world));
    var value: u64 = 0xd6e8_feb8_6659_fd93;
    value ^= @as(u32, @bitCast(world));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.x));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.z));
    value *%= 0xe703_7ed1_a0b4_28db;
    value ^= value >> 32;
    return @intCast(value);
}

fn isRandomTickableBlock(block_state: i32) bool {
    return registry.randomTickState(block_state).kind != .none;
}

fn probeDistance(ideal: usize, index: usize, mask: usize) usize {
    return (index -% ideal) & mask;
}

pub fn sectionWorldY(section: usize, local_y: usize) i16 {
    return config.world_min_y + @as(i16, @intCast(section * 16 + local_y));
}
