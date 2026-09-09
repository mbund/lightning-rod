const std = @import("std");
const preallocated = @import("preallocated");
const registry = @import("registry_data");
const game_data = @import("../game_data.zig");
const terrain = @import("../terrain.zig");
const diagnostics = @import("../diagnostics.zig");
const geometry = @import("geometry.zig");
const limits = @import("limits.zig");
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
pub const world_top_y: i16 = limits.top_y;

pub const blocks_per_section = 16 * 16 * 16;
const sparse_section_change_capacity = 32;
pub const random_tick_mask_unindexed = std.math.maxInt(u16);
pub const random_tick_mask_columns = random_tick_mask_unindexed - 1;
pub const random_tick_mixed_state = std.math.minInt(i32);

pub const ModifiedSection = struct {
    active: bool = false,
    dirty: bool = false,
    dense: bool = false,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    world: world_identity.Handle = world_identity.invalid,
    section: u8 = 0,
    dense_index: u16 = 0,
    sparse_count: u8 = 0,
    modified_count: u16 = 0,
    random_tickable_count: u16 = 0,
    revision: u64 = 0,
    modified_bits: [blocks_per_section / 64]u64 = [_]u64{0} ** (blocks_per_section / 64),
    sparse_indices: [sparse_section_change_capacity]u16 = undefined,
    sparse_states: [sparse_section_change_capacity]i32 = undefined,
};

const materialization_empty = std.math.maxInt(u16);
pub const no_modified_section_index = std.math.maxInt(u16);

test "materialization owns fixed buffers and replaces a full cache without extra pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
        .maximum_block_mutations = 16,
    });
    var storage: [terrain.chunk_storage_capacity]u8 = undefined;
    var shape = terrain.ChunkShape{
        .chunk_x = 0,
        .chunk_z = 0,
        .heights = @splat(0),
        .biomes = @splat(0),
        .storage = &storage,
    };
    for (0..limits.section_count) |section| try shape.encodeUniformSection(section, registry.block_stone_default_state);
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    var slots: [4]usize = undefined;
    for (&slots, 0..) |*slot, x| {
        shape.chunk_x = @intCast(x);
        slot.* = try blocks.installMaterialization(world, shape, 0, .persisted);
        try std.testing.expectEqual(@intFromPtr(&blocks.shape_storage[slot.*]), @intFromPtr(blocks.materialized_chunks[slot.*].shape.storage.ptr));
    }
    shape.chunk_x = 4;
    try std.testing.expectError(error.MaterializationCapacity, blocks.installMaterialization(world, shape, 0, .persisted));
    const own = blocks.materialized_chunks[slots[2]].shape;
    try std.testing.expectEqual(slots[2], try blocks.installMaterialization(world, own, 1, .persisted));
    try std.testing.expectEqual(registry.block_stone_default_state, blocks.materialized_chunks[slots[2]].shape.sectionPaletteState(0, 0));
    shape.storage_len = 0;
    for (0..limits.section_count) |section| try shape.encodeUniformSection(section, registry.block_air_default_state);
    shape.chunk_x = 1;
    _ = try blocks.installMaterialization(world, shape, 1, .persisted);
    var copied = blocks.materialized_chunks[slots[1]].shape;
    copied.chunk_x = 2;
    _ = try blocks.installMaterialization(world, copied, 1, .persisted);
    try std.testing.expectEqual(registry.block_air_default_state, blocks.materialized_chunks[slots[2]].shape.sectionPaletteState(0, 0));
    try std.testing.expectEqual(registry.block_stone_default_state, blocks.materialized_chunks[slots[0]].shape.sectionPaletteState(0, 0));
    try std.testing.expect(blocks.evictChunk(world, .{ .x = 2, .z = 0 }));
    shape.chunk_x = 4;
    try std.testing.expectEqual(slots[2], try blocks.installMaterialization(world, shape, 2, .persisted));
    try std.testing.expect(blocks.materializedChunk(world, .{ .x = 2, .z = 0 }) == null);
    try std.testing.expect(blocks.materializedChunk(world, .{ .x = 4, .z = 0 }) != null);
}

test "render materialization defers random tick derivation until a mutation needs it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = try Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 4,
        .maximum_block_mutations = 16,
    });
    var storage: [terrain.chunk_storage_capacity]u8 = undefined;
    var shape = try terrain.buildFlatChunkShape(
        &storage,
        0,
        0,
        64,
        registry.block_grass_block_default_state,
        registry.block_stone_default_state,
    );
    // This is conservative metadata: retaining `true` does not require eager mask work.
    shape.grass_spread_possible = true;
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const index = try blocks.installMaterialization(world, shape, 0, .persisted);
    const resident = &blocks.materialized_chunks[index];
    try std.testing.expect(!resident.random_tick_derived);
    try std.testing.expectEqual(shape.heights, resident.heights);
    try std.testing.expectEqual(shape.grass_spread_possible, resident.base_grass_spread_possible);
    try std.testing.expectEqual(blocks.free_random_tick_masks.len, blocks.free_random_tick_mask_count);

    try std.testing.expect(try blocks.setBlock(world, .{ .x = 0, .y = 64, .z = 0 }, registry.block_air_default_state));
    try std.testing.expect(resident.random_tick_derived);
    const section = sectionIndexForY(64).?;
    try std.testing.expect(resident.random_tick_sections & (@as(u32, 1) << @intCast(section)) != 0);
    try std.testing.expectEqual(@as(?i32, null), blocks.sectionRandomTickBlockState(resident, section, localBlockIndex(.{ .x = 0, .y = 64, .z = 0 }), blocks.modifiedSectionIndex(resident, section)));
}

pub const MaterializedChunk = struct {
    valid: bool = false,
    dirty: bool = false,
    chunk: geometry.ChunkPos = .{ .x = 0, .z = 0 },
    world: world_identity.Handle = world_identity.invalid,
    last_used_tick: u64 = 0,
    revision: u64 = 0,
    content_revision: u64 = 0,
    binding_revision: u64 = 0,
    modified_section_mask: u32 = 0,
    dirty_section_mask: u32 = 0,
    modified_section_indices: [limits.section_count]u16 = [_]u16{no_modified_section_index} ** limits.section_count,
    shape: terrain.ChunkShape = undefined,
    random_tick_derived: bool = false,
    random_tick_sections: u32 = 0,
    heights: [16 * 16]i16 = undefined,
    grass_above_blocked: [4]u64 = undefined,
    base_grass_spread_possible: bool = false,
    random_tickable_counts: [limits.section_count]u16 = undefined,
    random_tick_mask_handles: [limits.section_count]u16 = [_]u16{0} ** limits.section_count,
    random_tick_uniform_states: [limits.section_count]i32 = [_]i32{random_tick_mixed_state} ** limits.section_count,
};

pub const MaterializedChunkRef = struct {
    index: u16,
    entry: *const MaterializedChunk,
};

pub const MaterializationSource = enum { generated, persisted };

pub const MutationCursor = struct {
    sequence: u64,

    pub fn next(self: *MutationCursor, blocks: *const Blocks) error{HistoryLost}!?geometry.BlockMutation {
        const pending = blocks.block_mutation_sequence -% self.sequence;
        if (pending == 0) return null;
        if (pending > blocks.block_mutations.len) return error.HistoryLost;
        self.sequence +%= 1;
        if (self.sequence == 0) self.sequence = 1;
        return blocks.blockMutation(self.sequence);
    }
};

pub const Materialization = struct {
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    content_revision: u64,
    binding_revision: u64,
    source: MaterializationSource,
};

pub const MaterializationCursor = struct {
    sequence: u64,

    pub fn next(self: *MaterializationCursor, blocks: *const Blocks) error{HistoryLost}!?Materialization {
        const pending = blocks.chunk_change_sequence -% self.sequence;
        if (pending == 0) return null;
        if (pending > blocks.materializations.len) return error.HistoryLost;
        self.sequence +%= 1;
        if (self.sequence == 0) self.sequence = 1;
        return blocks.materializations[(self.sequence -% 1) % blocks.materializations.len];
    }
};
pub const GenerationMetrics = generator_api.Metrics;
pub const MutationWrite = struct {
    world: world_identity.Handle,
    pos: geometry.BlockPos,
    block_state: i32,
};

pub const Blocks = struct {
    pub const id = "lightning_rod:blocks";

    /// A persisted revision must leave room for a worst-case canonical reload.
    /// `loadSectionFromShape` can advance the shared revision allocator once for
    /// every section before `finishPersistedMaterialization` restores this
    /// logical value.  Keeping that headroom makes a valid checksummed record
    /// incapable of exhausting the allocator midway through installation.
    pub const maximum_persisted_content_revision: u64 =
        std.math.maxInt(u64) - @as(u64, limits.section_count) - 2;

    pub const Configuration = struct {
        maximum_transient_chunks: usize = 32,
        maximum_modified_sections: usize = 64,
        maximum_block_mutations: usize = 4096,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_transient_chunks < 4 or self.maximum_transient_chunks >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_transient_chunks))
                return error.InvalidMaterializationCapacity;
            if (self.maximum_modified_sections == 0 or
                self.maximum_modified_sections >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_modified_sections))
                return error.InvalidModifiedSectionCapacity;
            if (self.maximum_block_mutations == 0)
                return error.InvalidMutationCapacity;
        }
    };
    generator: ?generator_api.Service = null,
    modified_sections: []ModifiedSection = &.{},
    free_modified_sections: []u16 = &.{},
    free_modified_section_count: usize = 0,
    dense_sections: []align(cache_line_size) [blocks_per_section]i32 = &.{},
    free_dense_sections: []u16 = &.{},
    modified_block_count: usize = 0,
    modified_section_count: usize = 0,
    free_dense_section_count: usize = 0,
    next_section_revision: u64 = 1,
    block_mutation_sequence: u64 = 0,
    block_mutations: []geometry.BlockMutation = &.{},
    chunk_change_sequence: u64 = 0,
    materializations: []Materialization = &.{},
    materialized_chunks: []MaterializedChunk = &.{},
    shape_storage: []align(64) [terrain.chunk_storage_capacity]u8 = &.{},
    materialization_lookup: []u16 = &.{},
    free_materializations: []u16 = &.{},
    active_materialization_indices: []u16 = &.{},
    materialization_active_positions: []u16 = &.{},
    free_materialization_count: usize = 0,
    materialization_count: usize = 0,
    materialization_pressure: bool = false,
    materialization_binding_revision: u64 = 1,
    random_tick_masks: []align(cache_line_size) [blocks_per_section / 64]u64 = &.{},
    free_random_tick_masks: []u16 = &.{},
    free_random_tick_mask_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Blocks {
        const self = try allocator.create(Blocks);
        try configuration.validate();
        self.* = .{};
        self.shape_storage = try preallocated.alignedAlloc(
            [terrain.chunk_storage_capacity]u8,
            allocator,
            .@"64",
            configuration.maximum_transient_chunks,
        );
        self.modified_sections = try preallocated.alloc(ModifiedSection, allocator, configuration.maximum_modified_sections);
        self.free_modified_sections = try preallocated.alloc(u16, allocator, configuration.maximum_modified_sections);
        self.dense_sections = try preallocated.alignedAlloc([blocks_per_section]i32, allocator, .@"64", configuration.maximum_modified_sections);
        self.free_dense_sections = try preallocated.alloc(u16, allocator, configuration.maximum_modified_sections);
        self.block_mutations = try preallocated.alloc(geometry.BlockMutation, allocator, configuration.maximum_block_mutations);
        self.materializations = try preallocated.alloc(Materialization, allocator, configuration.maximum_block_mutations);
        self.materialized_chunks = try preallocated.alloc(MaterializedChunk, allocator, configuration.maximum_transient_chunks);
        self.materialization_lookup = try preallocated.alloc(u16, allocator, configuration.maximum_transient_chunks * 2);
        self.free_materializations = try preallocated.alloc(u16, allocator, configuration.maximum_transient_chunks);
        self.active_materialization_indices = try preallocated.alloc(u16, allocator, configuration.maximum_transient_chunks);
        self.materialization_active_positions = try preallocated.alloc(u16, allocator, configuration.maximum_transient_chunks);
        const random_tick_masks = @min(configuration.maximum_transient_chunks * 2, @as(usize, random_tick_mask_columns - 1));
        self.random_tick_masks = try preallocated.alignedAlloc([blocks_per_section / 64]u64, allocator, .@"64", random_tick_masks);
        self.free_random_tick_masks = try preallocated.alloc(u16, allocator, random_tick_masks);
        self.resetStorageState();
        return self;
    }

    pub fn bindGenerator(self: *Blocks, generator: generator_api.Service) void {
        self.generator = generator;
    }

    fn resetStorageState(self: *Blocks) void {
        for (self.free_modified_sections, 0..) |*entry, index|
            entry.* = @intCast(self.free_modified_sections.len - 1 - index);
        self.free_modified_section_count = self.free_modified_sections.len;
        self.modified_block_count = 0;
        self.modified_section_count = 0;
        for (self.free_dense_sections, 0..) |*entry, index|
            entry.* = @intCast(self.free_dense_sections.len - 1 - index);
        self.free_dense_section_count = self.free_dense_sections.len;
        self.next_section_revision = 1;
        self.block_mutation_sequence = 0;
        self.chunk_change_sequence = 0;
        for (self.free_materializations, 0..) |*entry, index|
            entry.* = @intCast(self.free_materializations.len - 1 - index);
        self.free_materialization_count = self.free_materializations.len;
        self.materialization_count = 0;
        self.materialization_pressure = false;
        self.materialization_binding_revision = 1;
        for (self.free_random_tick_masks, 0..) |*entry, index|
            entry.* = @intCast(self.free_random_tick_masks.len - 1 - index);
        self.free_random_tick_mask_count = self.free_random_tick_masks.len;
        @memset(self.materialization_lookup, materialization_empty);
    }

    pub fn blockAt(self: *const Blocks, world: world_identity.Handle, pos: geometry.BlockPos) i32 {
        const chunk: geometry.ChunkPos = geometry.chunkForBlock(pos);
        const resident = self.materializedChunk(world, chunk) orelse
            diagnostics.panic("world query touched non-materialized chunk; load or generate it explicitly (chunk x, chunk z, block x, block y, block z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z), diagnostics.integer(pos.x), diagnostics.integer(pos.y), diagnostics.integer(pos.z) });
        return self.blockAtMaterialized(resident, pos);
    }

    pub fn blockAtIfMaterialized(self: *const Blocks, world: world_identity.Handle, pos: geometry.BlockPos) ?i32 {
        const resident = self.materializedChunk(world, geometry.chunkForBlock(pos)) orelse return null;
        return self.blockAtMaterialized(resident, pos);
    }

    pub fn blockMutation(self: *const Blocks, sequence: u64) geometry.BlockMutation {
        std.debug.assert(sequence != 0 and self.block_mutation_sequence -% sequence < self.block_mutations.len);
        return self.block_mutations[(sequence -% 1) % self.block_mutations.len];
    }

    /// Call only after storage owns the complete replacement record.
    pub fn acceptStoredMutations(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, mutations: []const geometry.BlockMutation) void {
        if (self.materializedChunk(world, chunk) != null) {
            self.markChunkClean(world, chunk);
            std.debug.assert(self.evictChunk(world, chunk));
        }
        for (mutations) |mutation| {
            std.debug.assert(mutation.world.eql(world) and geometry.sameChunk(geometry.chunkForBlock(mutation.pos), chunk));
            if (mutation.previous_state != mutation.block_state)
                self.recordBlockMutation(world, mutation.pos, mutation.previous_state, mutation.block_state);
        }
    }

    pub fn blockMutationSequence(self: *const Blocks) u64 {
        return self.block_mutation_sequence;
    }

    pub fn mutationCursor(self: *const Blocks) MutationCursor {
        return .{ .sequence = self.block_mutation_sequence };
    }

    pub fn mutationCursorFrom(_: *const Blocks, sequence: u64) MutationCursor {
        return .{ .sequence = sequence };
    }

    pub fn materializationCursor(self: *const Blocks) MaterializationCursor {
        return .{ .sequence = self.chunk_change_sequence };
    }

    pub fn materializationCursorFrom(_: *const Blocks, sequence: u64) MaterializationCursor {
        return .{ .sequence = sequence };
    }

    pub fn materialized(self: *const Blocks, event: Materialization) ?*const MaterializedChunk {
        const resident = self.materializedChunk(event.world, event.chunk) orelse return null;
        if (resident.content_revision != event.content_revision or resident.binding_revision != event.binding_revision) return null;
        return resident;
    }

    pub fn modifiedSection(self: *const Blocks, resident: *const MaterializedChunk, section: usize) ?*const ModifiedSection {
        const index = self.modifiedSectionIndex(resident, section) orelse return null;
        return &self.modified_sections[index];
    }

    pub fn modifiedSectionState(self: *const Blocks, entry: *const ModifiedSection, local_index: u16) i32 {
        return self.modifiedBlockState(entry, local_index);
    }

    pub fn blockAtMaterialized(self: *const Blocks, resident: *const MaterializedChunk, pos: geometry.BlockPos) i32 {
        std.debug.assert(geometry.sameChunk(resident.chunk, geometry.chunkForBlock(pos)));
        if (sectionIndexForY(pos.y)) |section| {
            if (resident.modified_section_mask & (@as(u32, 1) << @intCast(section)) != 0) {
                const table_index = self.modifiedSectionIndex(resident, section) orelse
                    diagnostics.panic("materialized modified-section mask is stale (chunk x, chunk z, section)", &.{ diagnostics.integer(resident.chunk.x), diagnostics.integer(resident.chunk.z), diagnostics.integer(section) });
                return self.sectionBlockState(resident, section, localBlockIndex(pos), table_index);
            }
        }
        return terrain.blockAtFromShape(&resident.shape, pos.x, pos.y, pos.z);
    }

    pub fn grassAboveIsBlocked(self: *const Blocks, resident: *const MaterializedChunk, grass: geometry.BlockPos) bool {
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

    pub fn grassCanSpreadAt(self: *const Blocks, resident: *const MaterializedChunk, candidate: geometry.BlockPos) bool {
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

    pub fn sectionBlockState(
        self: *const Blocks,
        resident: *const MaterializedChunk,
        section: usize,
        local_index: u16,
        modified_index: ?usize,
    ) i32 {
        std.debug.assert(section < limits.section_count);
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

    pub fn sectionBlockHasRandomTicks(
        self: *const Blocks,
        resident: *const MaterializedChunk,
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

    pub fn sectionRandomTickBlockState(
        self: *const Blocks,
        resident: *const MaterializedChunk,
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

    pub fn sectionUsesRandomTickColumns(resident: *const MaterializedChunk, section: usize) bool {
        return resident.random_tick_mask_handles[section] == random_tick_mask_columns;
    }

    pub fn columnRandomTickBlockState(
        self: *const Blocks,
        resident: *const MaterializedChunk,
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
        if (entry.dense) return self.denseSection(entry.dense_index)[local_index];
        for (entry.sparse_indices[0..entry.sparse_count], 0..) |index, sparse_index| {
            if (index == local_index) return entry.sparse_states[sparse_index];
        }
        unreachable;
    }

    pub fn modifiedBlockStateAt(self: *const Blocks, table_index: usize, local_index: u16) i32 {
        return self.modifiedBlockState(&self.modified_sections[table_index], local_index);
    }

    pub fn materializeGeneratedChunk(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64) MaterializedChunkRef {
        if (self.materializedChunkIndex(world, chunk)) |index| {
            const entry = &self.materialized_chunks[index];
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
        const index = self.installMaterialization(world, shape, tick, .generated) catch |err|
            diagnostics.panic("failed to materialize generated chunk (chunk x, chunk z, error)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z), diagnostics.text(@errorName(err)) });
        return .{ .index = @intCast(index), .entry = &self.materialized_chunks[index] };
    }

    pub fn requestChunkGeneration(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        if (self.materializedChunk(world, chunk) != null) return true;
        const generator = self.generator orelse return false;
        return generator.request(world, chunk, .simulation);
    }

    pub fn requestStreamingChunkGeneration(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        if (self.materializedChunk(world, chunk) != null) return true;
        const generator = self.generator orelse return false;
        return generator.request(world, chunk, .streaming);
    }

    pub fn generationRequestCapacity(self: *const Blocks) usize {
        return if (self.generator) |generator| generator.capacity() else 0;
    }

    pub fn generationMetrics(self: *const Blocks) GenerationMetrics {
        return if (self.generator) |generator| generator.metrics() else .{
            .calls = 0,
            .nanoseconds = 0,
            .maximum_nanoseconds = 0,
            .emitted = 0,
            .installed = 0,
            .materialization_nanoseconds = 0,
        };
    }

    pub fn pendingChunkGenerationCount(self: *const Blocks) usize {
        return if (self.generator) |generator| generator.pending() else 0;
    }

    pub fn hasMaterializationCapacity(self: *Blocks) bool {
        if (self.free_materialization_count != 0 and self.materialization_count != self.materialized_chunks.len) return true;
        self.materialization_pressure = true;
        return false;
    }

    pub fn installMaterialization(self: *Blocks, world: world_identity.Handle, shape: terrain.ChunkShape, tick: u64, source: MaterializationSource) !usize {
        return self.installMaterializationWithRevision(world, shape, tick, source, self.takeSectionRevision(), true);
    }

    /// Installs validated canonical bytes without exposing a materialization
    /// event until every persisted modified section has been restored.
    pub fn installPersistedMaterialization(self: *Blocks, world: world_identity.Handle, shape: terrain.ChunkShape, tick: u64, content_revision: u64) !usize {
        try self.observeContentRevision(content_revision);
        if (self.next_section_revision > maximum_persisted_content_revision + 1)
            return error.ContentRevisionExhausted;
        return self.installMaterializationWithRevision(world, shape, tick, .persisted, content_revision, false);
    }

    pub fn finishPersistedMaterialization(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, content_revision: u64) void {
        const entry = self.materializedChunkMut(world, chunk) orelse unreachable;
        std.debug.assert(entry.content_revision != 0 and content_revision != 0);
        entry.content_revision = content_revision;
        entry.revision = 0;
        entry.dirty = false;
        var mask = entry.modified_section_mask;
        while (mask != 0) {
            const section: usize = @intCast(@ctz(mask));
            mask &= mask - 1;
            const table_index = self.modifiedSectionIndex(entry, section) orelse unreachable;
            self.modified_sections[table_index].dirty = false;
            self.modified_sections[table_index].revision = 0;
        }
        entry.dirty_section_mask = 0;
        self.recordMaterialization(world, chunk, entry.content_revision, entry.binding_revision, .persisted);
    }

    pub fn nextContentRevision(self: *Blocks, previous: u64) !u64 {
        try self.observeContentRevision(previous);
        if (self.next_section_revision > maximum_persisted_content_revision)
            return error.ContentRevisionExhausted;
        return self.takeSectionRevision();
    }

    fn installMaterializationWithRevision(self: *Blocks, world: world_identity.Handle, shape: terrain.ChunkShape, tick: u64, source: MaterializationSource, content_revision: u64, publish: bool) !usize {
        std.debug.assert(content_revision != 0);
        const chunk = geometry.ChunkPos{ .x = shape.chunk_x, .z = shape.chunk_z };
        const dirty = source == .generated;
        if (self.materializedChunkIndex(world, chunk)) |index| {
            const entry = &self.materialized_chunks[index];
            self.releaseMaterializedRandomTickMasks(entry);
            self.storeMaterializedShape(index, shape);
            entry.last_used_tick = tick;
            entry.dirty = dirty;
            entry.revision = if (dirty) content_revision else 0;
            entry.content_revision = content_revision;
            entry.binding_revision = self.takeMaterializationBindingRevision();
            if (publish) self.recordMaterialization(world, chunk, content_revision, entry.binding_revision, source);
            return index;
        }
        if (self.free_materialization_count == 0) {
            self.materialization_pressure = true;
            return error.MaterializationCapacity;
        }
        self.free_materialization_count -= 1;
        const index: usize = self.free_materializations[self.free_materialization_count];
        const entry = &self.materialized_chunks[index];
        entry.* = .{
            .valid = true,
            .dirty = dirty,
            .chunk = chunk,
            .world = world,
            .last_used_tick = tick,
            .revision = if (dirty) content_revision else 0,
            .content_revision = content_revision,
            .binding_revision = self.takeMaterializationBindingRevision(),
        };
        self.storeMaterializedShape(index, shape);
        try self.insertMaterializationLookup(world, chunk, index);
        self.active_materialization_indices[self.materialization_count] = @intCast(index);
        self.materialization_active_positions[index] = @intCast(self.materialization_count);
        self.materialization_count += 1;
        if (publish) self.recordMaterialization(world, chunk, content_revision, entry.binding_revision, source);
        return index;
    }

    fn storeMaterializedShape(
        self: *Blocks,
        index: usize,
        shape: terrain.ChunkShape,
    ) void {
        std.debug.assert(shape.storage_len <= terrain.chunk_storage_capacity);
        const entry = &self.materialized_chunks[index];
        const storage = &self.shape_storage[index];
        const destination = storage[0..shape.storage_len];
        const source = shape.storage[0..shape.storage_len];
        if (@intFromPtr(destination.ptr) < @intFromPtr(source.ptr)) {
            std.mem.copyForwards(u8, destination, source);
        } else if (@intFromPtr(destination.ptr) > @intFromPtr(source.ptr)) {
            std.mem.copyBackwards(u8, destination, source);
        }
        entry.shape = shape;
        entry.shape.storage = storage;
        entry.heights = shape.heights;
        entry.base_grass_spread_possible = shape.grass_spread_possible;
    }

    fn buildRandomTickDerived(self: *Blocks, entry: *MaterializedChunk) void {
        std.debug.assert(entry.valid and !entry.random_tick_derived);
        var masks: [limits.section_count][terrain.random_tick_mask_words]u64 = undefined;
        entry.random_tick_sections = terrain.fillChunkRandomTickMasksFromShape(
            &entry.shape,
            &entry.heights,
            &entry.grass_above_blocked,
            &masks,
            &entry.random_tickable_counts,
        );
        entry.random_tick_mask_handles = [_]u16{0} ** limits.section_count;
        entry.random_tick_uniform_states = [_]i32{random_tick_mixed_state} ** limits.section_count;
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
                if (@divFloor(@as(i32, height) - @as(i32, limits.min_y), 16) != section) continue;
                expected_count += 1;
                const local_y: u16 = @intCast((@as(i32, height) - @as(i32, limits.min_y)) & 15);
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
        entry.random_tick_derived = true;
    }

    fn ensureRandomTickDerived(self: *Blocks, entry: *MaterializedChunk) void {
        if (!entry.random_tick_derived) self.buildRandomTickDerived(entry);
    }

    pub fn ensureMaterializedRandomTickDerived(self: *Blocks, index: u16) *const MaterializedChunk {
        const entry = &self.materialized_chunks[index];
        std.debug.assert(entry.valid);
        self.ensureRandomTickDerived(entry);
        return entry;
    }

    fn allocateRandomTickMask(self: *Blocks) ?u16 {
        if (self.free_random_tick_mask_count == 0) return null;
        self.free_random_tick_mask_count -= 1;
        return self.free_random_tick_masks[self.free_random_tick_mask_count];
    }

    fn releaseMaterializedRandomTickMasks(self: *Blocks, entry: *MaterializedChunk) void {
        for (&entry.random_tick_mask_handles) |*encoded| {
            if (encoded.* != 0 and encoded.* != random_tick_mask_unindexed and encoded.* != random_tick_mask_columns) {
                self.free_random_tick_masks[self.free_random_tick_mask_count] = encoded.* - 1;
                self.free_random_tick_mask_count += 1;
            }
            encoded.* = 0;
        }
        entry.random_tick_derived = false;
    }

    pub fn materializedChunk(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?*const MaterializedChunk {
        const index = self.materializedChunkIndex(world, chunk) orelse return null;
        return &self.materialized_chunks[index];
    }

    pub fn materializedChunkSlot(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?u16 {
        return @intCast(self.materializedChunkIndex(world, chunk) orelse return null);
    }

    pub fn materializationBindingRevision(self: *const Blocks) u64 {
        return self.materialization_binding_revision;
    }

    pub fn materializedChunkRef(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, tick: u64) ?MaterializedChunkRef {
        const index = self.materializedChunkIndex(world, chunk) orelse return null;
        const entry = &self.materialized_chunks[index];
        entry.last_used_tick = tick;
        return .{ .index = @intCast(index), .entry = entry };
    }

    pub fn materializedChunkMut(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?*MaterializedChunk {
        const index = self.materializedChunkIndex(world, chunk) orelse return null;
        return &self.materialized_chunks[index];
    }

    pub fn materializedChunkCount(self: *const Blocks) usize {
        return self.materialization_count;
    }

    pub fn materializationCapacity(self: *const Blocks) usize {
        return self.materialized_chunks.len;
    }

    pub fn modifiedSectionCount(self: *const Blocks) usize {
        return self.modified_section_count;
    }

    pub fn modifiedSectionCapacity(self: *const Blocks) usize {
        return self.modified_sections.len;
    }

    pub fn modifiedBlockCount(self: *const Blocks) usize {
        return self.modified_block_count;
    }

    pub fn releaseUnusedMaterializations(self: *Blocks) usize {
        return self.releaseMaterializationsRetaining(null, null);
    }

    pub fn releaseMaterializationsRetaining(
        self: *Blocks,
        context: ?*const anyopaque,
        retain: ?*const fn (*const anyopaque, world_identity.Handle, geometry.ChunkPos) bool,
    ) usize {
        var evicted: usize = 0;
        var position = self.materialization_count;
        while (position != 0) {
            position -= 1;
            const index = self.active_materialization_indices[position];
            const resident = self.materialized_chunks[index];
            if (self.chunkDirty(resident.world, resident.chunk)) continue;
            if (retain) |function| if (function(context.?, resident.world, resident.chunk)) continue;
            std.debug.assert(self.evictChunk(resident.world, resident.chunk));
            evicted += 1;
        }
        self.materialization_pressure = false;
        return evicted;
    }

    pub fn materializationPressure(self: *const Blocks) bool {
        return self.materialization_pressure;
    }

    pub fn requestMaterializationRelease(self: *Blocks) void {
        self.materialization_pressure = true;
    }

    pub fn clearMaterializationPressure(self: *Blocks) void {
        self.materialization_pressure = false;
    }

    fn materializedChunkIndex(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
        if (self.materialization_lookup.len == 0) return null;
        var probe = generatedHeightHash(world, chunk);
        var searched: usize = 0;
        while (searched < self.materialization_lookup.len) : ({
            searched += 1;
            probe += 1;
        }) {
            const slot = self.materialization_lookup[probe & (self.materialization_lookup.len - 1)];
            if (slot == materialization_empty) return null;
            const entry = &self.materialized_chunks[slot];
            if (entry.valid and entry.world.eql(world) and geometry.sameChunk(entry.chunk, chunk)) return slot;
        }
        return null;
    }

    fn insertMaterializationLookup(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, resident_index: usize) !void {
        var probe = generatedHeightHash(world, chunk);
        for (0..self.materialization_lookup.len) |_| {
            const index = probe & (self.materialization_lookup.len - 1);
            if (self.materialization_lookup[index] == materialization_empty) {
                self.materialization_lookup[index] = @intCast(resident_index);
                return;
            }
            probe += 1;
        }
        return error.MaterializationLookupFull;
    }

    pub fn ensureChunkAt(self: *Blocks, world: world_identity.Handle, x: i32, z: i32, tick: u64) void {
        _ = self.materializeGeneratedChunk(world, .{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) }, tick);
    }

    pub fn blockRectangleMaterialized(self: *const Blocks, world: world_identity.Handle, min_x: i32, max_x: i32, min_z: i32, max_z: i32) bool {
        var chunk_z = @divFloor(min_z, 16);
        const last_z = @divFloor(max_z, 16);
        while (chunk_z <= last_z) : (chunk_z += 1) {
            var chunk_x = @divFloor(min_x, 16);
            const last_x = @divFloor(max_x, 16);
            while (chunk_x <= last_x) : (chunk_x += 1) {
                if (self.materializedChunk(world, .{ .x = chunk_x, .z = chunk_z }) == null) return false;
            }
        }
        return true;
    }

    fn sameMutationSection(a: MutationWrite, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize) bool {
        return a.world.eql(world) and geometry.sameChunk(geometry.chunkForBlock(a.pos), chunk) and sectionIndexForY(a.pos.y) == section;
    }

    fn sameMutationPosition(a: geometry.BlockPos, b: geometry.BlockPos) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    fn isFirstSectionWrite(writes: []const MutationWrite, index: usize, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize) bool {
        for (writes[0..index]) |candidate| if (sameMutationSection(candidate, world, chunk, section)) return false;
        return true;
    }

    fn isFinalSectionWrite(writes: []const MutationWrite, index: usize, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize) bool {
        const candidate = writes[index];
        if (!sameMutationSection(candidate, world, chunk, section)) return false;
        return isFinalMutationWrite(writes, index);
    }

    fn isFinalMutationWrite(writes: []const MutationWrite, index: usize) bool {
        const candidate = writes[index];
        for (writes[index + 1 ..]) |later|
            if (later.world.eql(candidate.world) and sameMutationPosition(later.pos, candidate.pos)) return false;
        return true;
    }

    pub fn prepareBlockWrites(self: *const Blocks, writes: []const MutationWrite) !void {
        var required_sections: usize = 0;
        for (writes, 0..) |write, first_index| {
            const section = sectionIndexForY(write.pos.y) orelse continue;
            const chunk = geometry.chunkForBlock(write.pos);
            if (!isFirstSectionWrite(writes, first_index, write.world, chunk, section)) continue;
            const resident = self.materializedChunk(write.world, chunk) orelse return error.ChunkNotMaterialized;
            const existing = self.modifiedSectionIndex(resident, section);
            var final_count: i32 = if (existing) |index| self.modified_sections[index].modified_count else 0;
            for (writes, 0..) |candidate, candidate_index| {
                if (!isFinalSectionWrite(writes, candidate_index, write.world, chunk, section)) continue;
                const local_index = localBlockIndex(candidate.pos);
                const generated = terrain.blockAtFromShape(&resident.shape, candidate.pos.x, candidate.pos.y, candidate.pos.z);
                const current = self.sectionBlockState(resident, section, local_index, existing);
                if (current == generated and candidate.block_state != generated) final_count += 1;
                if (current != generated and candidate.block_state == generated) final_count -= 1;
            }
            std.debug.assert(final_count >= 0 and final_count <= blocks_per_section);
            if (existing == null and final_count != 0) required_sections += 1;
        }
        if (required_sections > self.modified_sections.len - self.modified_section_count) return error.WorldSectionCapacity;
    }

    pub fn commitPreparedBlockWrites(self: *Blocks, writes: []const MutationWrite, changed: []bool) usize {
        std.debug.assert(writes.len == changed.len);
        var count: usize = 0;
        for (writes, changed, 0..) |write, *was_changed, index| {
            if (!isFinalMutationWrite(writes, index)) {
                was_changed.* = false;
                continue;
            }
            was_changed.* = self.setBlockPrepared(write.world, write.pos, write.block_state) catch |err|
                diagnostics.panic("prepared block write failed (x, y, z, error)", &.{ diagnostics.integer(write.pos.x), diagnostics.integer(write.pos.y), diagnostics.integer(write.pos.z), diagnostics.text(@errorName(err)) });
            count += @intFromBool(was_changed.*);
        }
        return count;
    }

    pub fn setBlock(self: *Blocks, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !bool {
        const writes = [_]MutationWrite{.{ .world = world, .pos = pos, .block_state = block_state }};
        try self.prepareBlockWrites(&writes);
        var changed: [1]bool = undefined;
        _ = self.commitPreparedBlockWrites(&writes, &changed);
        return changed[0];
    }

    fn setBlockPrepared(self: *Blocks, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) !bool {
        std.debug.assert(world_identity.valid(world));
        std.debug.assert(self.modified_block_count <= self.modified_sections.len * blocks_per_section);
        std.debug.assert(self.modified_section_count <= self.modified_sections.len);
        const section = sectionIndexForY(pos.y) orelse return false;
        const chunk = geometry.chunkForBlock(pos);
        const resident = self.materializedChunkMut(world, chunk) orelse return error.ChunkNotMaterialized;
        const local_index = localBlockIndex(pos);
        const generated = terrain.blockAtFromShape(&resident.shape, pos.x, pos.y, pos.z);
        if (self.modifiedSectionIndex(resident, section)) |table_index|
            return self.setModifiedBlock(world, resident, table_index, section, local_index, generated, pos, block_state);
        if (block_state == generated) return false;
        try self.createBlockModification(resident, section, local_index, generated, block_state);
        self.recordBlockMutation(world, pos, generated, block_state);
        std.debug.assert(self.blockAt(world, pos) == block_state);
        return true;
    }

    fn setModifiedBlock(self: *Blocks, world: world_identity.Handle, resident: *MaterializedChunk, table_index: usize, section: usize, local_index: u16, generated: i32, pos: geometry.BlockPos, block_state: i32) !bool {
        const entry = &self.modified_sections[table_index];
        const previous = self.sectionBlockState(resident, section, local_index, table_index);
        if (previous == block_state) return false;
        const sparse_index = findSparseIndex(entry, local_index);
        if (!entry.dense and block_state != generated and sparse_index == null and
            entry.sparse_count == sparse_section_change_capacity) self.promoteModifiedSection(entry);
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

    fn createBlockModification(self: *Blocks, resident: *MaterializedChunk, section: usize, local_index: u16, generated: i32, block_state: i32) !void {
        const table_index = try self.createModifiedSection(resident, section);
        const revision = self.takeSectionRevision();
        resident.dirty = true;
        resident.revision = revision;
        resident.content_revision = revision;
        resident.dirty_section_mask |= @as(u32, 1) << @intCast(section);
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
            self.denseSection(entry.dense_index)[local_index] = block_state;
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

    fn markSectionChanged(self: *Blocks, resident: *MaterializedChunk, entry: *ModifiedSection, section: usize) u64 {
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
        std.debug.assert(section < limits.section_count);
        const resident = self.materializedChunk(world, chunk) orelse return null;
        return self.modifiedSectionIndex(resident, section);
    }

    pub fn sectionContentRevision(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
        section: usize,
    ) ?u64 {
        const resident = self.materializedChunk(world, chunk) orelse return null;
        const index = self.modifiedSectionIndex(resident, section) orelse return 0;
        const revision = self.modified_sections[index].revision;
        return if (revision == 0) resident.content_revision else revision;
    }

    pub fn modifiedSectionIndex(self: *const Blocks, resident: *const MaterializedChunk, section: usize) ?usize {
        std.debug.assert(section < limits.section_count);
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
        return self.denseSection(entry.dense_index);
    }

    pub fn modifiedSectionIsDense(self: *const Blocks, table_index: usize) bool {
        std.debug.assert(table_index < self.modified_sections.len);
        return self.modified_sections[table_index].active and self.modified_sections[table_index].dense;
    }

    fn denseSection(self: *const Blocks, index: u16) *[blocks_per_section]i32 {
        std.debug.assert(index < self.dense_sections.len);
        return &self.dense_sections[index];
    }

    pub fn copySectionBlocks(self: *const Blocks, table_index: usize, output: *[blocks_per_section]i32) void {
        const entry = &self.modified_sections[table_index];
        std.debug.assert(entry.active);
        if (entry.dense) {
            @memcpy(output, self.denseSection(entry.dense_index));
            return;
        }
        const resident = self.materializedChunk(entry.world, entry.chunk) orelse unreachable;
        terrain.fillSectionFromShape(&resident.shape, entry.section, output);
        for (entry.sparse_indices[0..entry.sparse_count], entry.sparse_states[0..entry.sparse_count]) |local_index, state|
            output[local_index] = state;
    }

    pub fn sectionBlockIsModified(self: *const Blocks, table_index: usize, local_index: u16) bool {
        const entry = &self.modified_sections[table_index];
        return entry.modified_bits[local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) != 0;
    }

    pub fn loadSection(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, blocks: *const [blocks_per_section]i32) !void {
        const resident = self.materializedChunk(world, chunk) orelse return error.ChunkNotMaterialized;
        try self.loadSectionFromShape(world, chunk, section, blocks, &resident.shape);
    }

    pub fn availableDenseSections(self: *const Blocks) usize {
        return self.free_dense_section_count;
    }

    pub fn sectionDiffersFromShape(section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) bool {
        return countModifiedBlocks(section, blocks, shape) != 0;
    }

    pub fn sectionRequiresDenseStorage(section: usize, section_blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) bool {
        return countModifiedBlocks(section, section_blocks, shape) > sparse_section_change_capacity;
    }

    pub fn loadSectionFromShape(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape) !void {
        const resident = self.materializedChunkMut(world, chunk) orelse return error.ChunkNotMaterialized;
        if (self.modifiedSectionIndex(resident, section)) |table_index| {
            const entry = &self.modified_sections[table_index];
            const modified_count = countModifiedBlocks(section, blocks, shape);
            if (modified_count > sparse_section_change_capacity and !entry.dense and self.free_dense_section_count == 0)
                return error.WorldSectionCapacity;
            self.modified_block_count -= entry.modified_count;
            if (modified_count == 0) {
                self.releaseModifiedSection(resident, table_index);
                resident.content_revision = self.takeSectionRevision();
                self.invalidateMaterializedProjections();
                return;
            }
            self.assignModifiedSection(entry, section, blocks, shape, modified_count);
            resident.dirty_section_mask &= ~(@as(u32, 1) << @intCast(section));
            resident.content_revision = self.takeSectionRevision();
            self.modified_block_count += modified_count;
            self.invalidateMaterializedProjections();
            return;
        }
        const modified_count = countModifiedBlocks(section, blocks, shape);
        if (modified_count == 0) return;
        if (modified_count > sparse_section_change_capacity and self.free_dense_section_count == 0)
            return error.WorldSectionCapacity;
        const table_index = try self.createModifiedSection(resident, section);
        const entry = &self.modified_sections[table_index];
        self.assignModifiedSection(entry, section, blocks, shape, modified_count);
        resident.content_revision = self.takeSectionRevision();
        self.modified_block_count += modified_count;
        self.invalidateMaterializedProjections();
    }

    fn assignModifiedSection(self: *Blocks, entry: *ModifiedSection, section: usize, blocks: *const [blocks_per_section]i32, shape: *const terrain.ChunkShape, modified_count: u16) void {
        if (entry.dense) {
            self.free_dense_sections[self.free_dense_section_count] = entry.dense_index;
            self.free_dense_section_count += 1;
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
        std.debug.assert(self.free_dense_section_count != 0);
        self.free_dense_section_count -= 1;
        entry.dense_index = self.free_dense_sections[self.free_dense_section_count];
        @memcpy(self.denseSection(entry.dense_index), blocks);
        entry.dense = true;
    }

    pub fn markChunkClean(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) void {
        const resident = self.materializedChunkMut(world, chunk) orelse return;
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

    pub fn markChunkForPersistence(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        const resident = self.materializedChunkMut(world, chunk) orelse return false;
        resident.dirty = true;
        resident.revision = @max(resident.revision, resident.content_revision);
        return true;
    }

    pub fn markGeneratedChunkNew(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        const resident = self.materializedChunkMut(world, chunk) orelse return false;
        if (resident.dirty) return true;
        const revision = self.takeSectionRevision();
        resident.dirty = true;
        resident.revision = revision;
        return true;
    }

    pub fn markChunkCleanThrough(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, revision: u64) void {
        const resident = self.materializedChunkMut(world, chunk) orelse return;
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
        const resident = self.materializedChunk(world, chunk) orelse return 0;
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
        const resident = self.materializedChunk(world, chunk) orelse return false;
        return resident.dirty or resident.dirty_section_mask != 0;
    }

    pub fn evictChunk(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos) bool {
        if (self.chunkDirty(world, chunk)) return false;
        var removed = false;
        const resident = self.materializedChunkMut(world, chunk) orelse return false;
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
        if (self.materializedChunkIndex(world, chunk)) |resident_index| {
            _ = self.takeMaterializationBindingRevision();
            self.removeMaterializationLookup(world, chunk, resident_index);
            self.releaseMaterializedRandomTickMasks(&self.materialized_chunks[resident_index]);
            const active_position: usize = self.materialization_active_positions[resident_index];
            std.debug.assert(self.active_materialization_indices[active_position] == resident_index);
            self.materialization_count -= 1;
            if (active_position != self.materialization_count) {
                const moved_index = self.active_materialization_indices[self.materialization_count];
                self.active_materialization_indices[active_position] = moved_index;
                self.materialization_active_positions[moved_index] = @intCast(active_position);
            }
            self.materialized_chunks[resident_index] = .{};
            self.free_materializations[self.free_materialization_count] = @intCast(resident_index);
            self.free_materialization_count += 1;
            removed = true;
        }
        return removed;
    }

    fn removeMaterializationLookup(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, resident_index: usize) void {
        const mask = self.materialization_lookup.len - 1;
        var probe = generatedHeightHash(world, chunk);
        var found: ?usize = null;
        for (0..self.materialization_lookup.len) |_| {
            const index = probe & mask;
            const slot = self.materialization_lookup[index];
            if (slot == materialization_empty) return;
            if (slot == resident_index) {
                found = index;
                break;
            }
            probe += 1;
        }
        var hole = found orelse return;
        self.materialization_lookup[hole] = materialization_empty;
        var scan = (hole + 1) & mask;
        for (0..self.materialization_lookup.len) |_| {
            if (self.materialization_lookup[scan] == materialization_empty) return;
            const slot = self.materialization_lookup[scan];
            const entry = self.materialized_chunks[slot];
            const ideal = generatedHeightHash(entry.world, entry.chunk) & mask;
            if (probeDistance(ideal, hole, mask) < probeDistance(ideal, scan, mask)) {
                self.materialization_lookup[hole] = slot;
                self.materialization_lookup[scan] = materialization_empty;
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
        if (self.next_section_revision == 0 or self.next_section_revision == std.math.maxInt(u64))
            diagnostics.panic("content revision exhausted", &.{});
        const revision = self.next_section_revision;
        self.next_section_revision = revision + 1;
        return revision;
    }

    fn observeContentRevision(self: *Blocks, revision: u64) !void {
        if (revision == 0 or revision > maximum_persisted_content_revision) return error.InvalidContentRevision;
        if (self.next_section_revision == 0) return error.ContentRevisionExhausted;
        if (self.next_section_revision <= revision) self.next_section_revision = revision + 1;
    }

    fn takeMaterializationBindingRevision(self: *Blocks) u64 {
        if (self.materialization_binding_revision == 0)
            diagnostics.panic("materialization binding revision exhausted", &.{});
        const revision = self.materialization_binding_revision;
        self.materialization_binding_revision = if (revision == std.math.maxInt(u64)) 0 else revision + 1;
        return revision;
    }

    fn invalidateMaterializedProjections(self: *Blocks) void {
        _ = self.takeMaterializationBindingRevision();
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

    fn recordMaterialization(self: *Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, content_revision: u64, binding_revision: u64, source: MaterializationSource) void {
        self.chunk_change_sequence +%= 1;
        if (self.chunk_change_sequence == 0) self.chunk_change_sequence = 1;
        self.materializations[(self.chunk_change_sequence -% 1) % self.materializations.len] = .{
            .world = world,
            .chunk = chunk,
            .content_revision = content_revision,
            .binding_revision = binding_revision,
            .source = source,
        };
    }

    fn createModifiedSection(self: *Blocks, resident: *MaterializedChunk, section: usize) !usize {
        if (self.modified_section_count == self.modified_sections.len) return error.WorldSectionCapacity;
        self.ensureRandomTickDerived(resident);
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

    fn promoteModifiedSection(self: *Blocks, entry: *ModifiedSection) void {
        std.debug.assert(entry.active and !entry.dense);
        std.debug.assert(self.free_dense_section_count != 0);
        self.free_dense_section_count -= 1;
        const dense_index = self.free_dense_sections[self.free_dense_section_count];
        const resident = self.materializedChunk(entry.world, entry.chunk) orelse unreachable;
        const dense = self.denseSection(dense_index);
        terrain.fillSectionFromShape(&resident.shape, entry.section, dense);
        for (entry.sparse_indices[0..entry.sparse_count], entry.sparse_states[0..entry.sparse_count]) |local_index, state|
            dense[local_index] = state;
        entry.dense_index = dense_index;
        entry.dense = true;
        entry.sparse_count = 0;
    }

    fn releaseModifiedSection(self: *Blocks, resident: *MaterializedChunk, table_index: usize) void {
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
            self.free_dense_sections[self.free_dense_section_count] = released.dense_index;
            self.free_dense_section_count += 1;
        }
        self.modified_section_count -= 1;
        std.debug.assert(self.free_dense_section_count <= self.dense_sections.len);
    }

    pub fn fillGeneratedSection(self: *const Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, section: usize, output: *[blocks_per_section]i32) void {
        const resident = self.materializedChunk(world, chunk) orelse
            diagnostics.panic("section materialization requested for non-materialized chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        terrain.fillSectionFromShape(&resident.shape, section, output);
    }

    pub fn uniformSectionState(
        self: *const Blocks,
        world: world_identity.Handle,
        chunk: geometry.ChunkPos,
        section: usize,
    ) ?i32 {
        const resident = self.materializedChunk(world, chunk) orelse return null;
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
        const resident = self.materializedChunk(world, chunk) orelse return null;
        if (resident.modified_section_mask &
            (@as(u32, 1) << @intCast(section)) != 0)
            return null;
        return resident.shape.section_visibility[section];
    }

    pub fn surfaceHeightAt(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.materializedChunk(world, chunk) orelse
            diagnostics.panic("surface query requested for non-materialized chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        return resident.shape.heights[@as(usize, @intCast(z & 15)) * 16 + @as(usize, @intCast(x & 15))];
    }

    pub fn highestGeneratedY(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.materializedChunk(world, chunk) orelse
            diagnostics.panic("height query requested for non-materialized chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
        return terrain.highestYFromShape(&resident.shape, @intCast(x & 15), @intCast(z & 15));
    }

    pub fn highestBlockYAt(self: *const Blocks, world: world_identity.Handle, x: i32, z: i32) i16 {
        const chunk = geometry.ChunkPos{ .x = @divFloor(x, 16), .z = @divFloor(z, 16) };
        const resident = self.materializedChunk(world, chunk) orelse
            diagnostics.panic("height query requested for non-materialized chunk (chunk x, chunk z)", &.{ diagnostics.integer(chunk.x), diagnostics.integer(chunk.z) });
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
        while (y >= limits.min_y) : (y -= 1) {
            if (self.blockAtMaterialized(
                resident,
                .{ .x = x, .y = @intCast(y), .z = z },
            ) != air_block_state) return @intCast(y);
        }
        return limits.min_y - 1;
    }
};

pub fn sectionIndexForY(y: i16) ?usize {
    if (y < limits.min_y or y > world_top_y) return null;
    return @intCast(@divFloor(@as(i32, y) - @as(i32, limits.min_y), 16));
}

pub fn generatedSectionMayContainBlocks(section: usize) bool {
    return terrain.sectionMayContainBlocks(section);
}

fn localBlockIndex(pos: geometry.BlockPos) u16 {
    const x: u16 = @intCast(pos.x & 15);
    const y: u16 = @intCast((@as(i32, pos.y) - @as(i32, limits.min_y)) & 15);
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
    return limits.min_y + @as(i16, @intCast(section * 16 + local_y));
}
