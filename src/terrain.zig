const std = @import("std");
const preallocated = @import("preallocated");
const config = @import("config.zig").value;
const registry = @import("registry_data");
const game_data = @import("game_data.zig");
pub const vanilla_worldgen = @import("worldgen");

pub const blocks_per_section = 16 * 16 * 16;
pub const maximum_generated_y: i16 = config.world_min_y +
    @as(i16, @intCast(config.overworld_section_count * 16)) - 1;
pub const chunk_storage_capacity = 64 * 1024;

pub const random_tick_mask_words = blocks_per_section / 64;
pub const biome_cells_per_section = vanilla_worldgen.biome.quart_cells_per_section;

pub const SectionShape = struct {
    palette_offset: u32 = 0,
    data_offset: u32 = 0,
    palette_count: u16 = 0,
    bits_per_block: u4 = 0,
};

pub const Generator = struct {
    const feature_origin_side = 3;
    const feature_origin_count = feature_origin_side * feature_origin_side;
    const feature_workspace_width = 5;
    const feature_workspace_rows = 3;
    const feature_workspace_count = feature_workspace_width * feature_workspace_rows;
    const feature_workspace_radius_x = feature_workspace_width / 2;
    const FeatureOrigin = struct { x: i32, z: i32 };
    const GeneratedState = vanilla_worldgen.generated_state.GeneratedState;
    const Material = vanilla_worldgen.aquifer.Material;

    const BaseChunkCacheEntry = struct {
        chunk_x: i32 = 0,
        chunk_z: i32 = 0,
        last_used: u64 = 0,
        valid: bool = false,
    };

    vanilla: vanilla_worldgen.chunk.Generator,
    surface_states: []i32,
    feature_states: []i32,
    base_chunk_cache: []BaseChunkCacheEntry,
    base_chunk_storage: []GeneratedState,
    feature_workspace_storage: []GeneratedState,
    material_scratch: []Material,
    feature_work: vanilla_worldgen.chunk.FeatureWork = undefined,
    shape_storage: [chunk_storage_capacity]u8 = undefined,
    cache_clock: u64 = 0,
    generation: Generation = .{},

    pub const GenerationStage = enum {
        idle,
        halo,
        base,
        surface,
        features_begin,
        features,
        encode,
    };

    const Generation = struct {
        stage: GenerationStage = .idle,
        target_x: i32 = 0,
        target_z: i32 = 0,
        halo_index: u8 = 0,
        feature_origin_index: u8 = 0,
        base_chunk_index: usize = 0,
        workspace_min_z: i32 = 0,
        workspace_first_row: u8 = 0,
        load_min_z: i32 = 0,
        load_first_row: u8 = 0,
        load_row_count: u8 = 0,
        features_started: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, seed: u64, base_chunk_cache_capacity: usize) !Generator {
        if (base_chunk_cache_capacity == 0)
            return error.InvalidBaseChunkCacheCapacity;
        var vanilla = try vanilla_worldgen.chunk.Generator.init(allocator, seed);
        errdefer vanilla.deinit();
        const surface_states = try preallocated.alloc(
            i32,
            allocator,
            vanilla_worldgen.surface.stateCount(),
        );
        errdefer allocator.free(surface_states);
        const feature_states = try preallocated.alloc(
            i32,
            allocator,
            vanilla_worldgen.generated_state.featureStateCount(),
        );
        errdefer allocator.free(feature_states);
        const base_chunk_cache = try preallocated.alloc(
            BaseChunkCacheEntry,
            allocator,
            base_chunk_cache_capacity,
        );
        errdefer allocator.free(base_chunk_cache);
        @memset(base_chunk_cache, .{});
        const base_chunk_storage = try preallocated.alloc(
            GeneratedState,
            allocator,
            base_chunk_cache_capacity * vanilla_worldgen.chunk.block_count,
        );
        errdefer allocator.free(base_chunk_storage);
        const feature_workspace_storage = try preallocated.alloc(
            GeneratedState,
            allocator,
            feature_workspace_count * vanilla_worldgen.chunk.block_count,
        );
        errdefer allocator.free(feature_workspace_storage);
        const material_scratch = try preallocated.alloc(
            Material,
            allocator,
            vanilla_worldgen.chunk.block_count,
        );
        errdefer allocator.free(material_scratch);
        for (surface_states, 0..) |*state, index| {
            const name = vanilla_worldgen.surface.stateName(@intCast(index));
            state.* = registry.blockStateId(name) orelse return error.UnknownGeneratedBlockState;
        }
        for (feature_states, 0..) |*state, index| {
            const generated: vanilla_worldgen.generated_state.GeneratedState =
                .{ .feature = @intCast(index) };
            state.* = registry.blockStateId(generated.canonicalName()) orelse
                return error.UnknownGeneratedBlockState;
        }
        return .{
            .vanilla = vanilla,
            .surface_states = surface_states,
            .feature_states = feature_states,
            .base_chunk_cache = base_chunk_cache,
            .base_chunk_storage = base_chunk_storage,
            .feature_workspace_storage = feature_workspace_storage,
            .material_scratch = material_scratch,
        };
    }

    pub fn reseed(self: *Generator, seed: u64) !void {
        if (self.vanilla.world_seed == seed) return;
        std.debug.assert(self.generation.stage == .idle);
        try self.vanilla.reseed(seed);
        @memset(self.base_chunk_cache, .{});
        self.cache_clock = 0;
    }

    pub fn deinit(self: *Generator) void {
        const allocator = self.vanilla.allocator;
        allocator.free(self.material_scratch);
        allocator.free(self.feature_workspace_storage);
        allocator.free(self.base_chunk_storage);
        allocator.free(self.base_chunk_cache);
        allocator.free(self.feature_states);
        allocator.free(self.surface_states);
        self.vanilla.deinit();
        self.* = undefined;
    }

    pub fn generate(self: *Generator, chunk_x: i32, chunk_z: i32) !ChunkShape {
        self.cancel();
        while (true) {
            if (try self.advance(chunk_x, chunk_z)) |shape| return shape;
        }
    }

    pub fn cancel(self: *Generator) void {
        self.generation = .{};
    }

    pub fn generationStage(self: *const Generator) GenerationStage {
        return self.generation.stage;
    }

    pub fn featureStage(self: *const Generator) ?vanilla_worldgen.chunk.FeatureStage {
        if (self.generation.stage != .features) return null;
        return self.feature_work.stage;
    }

    pub fn advance(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
    ) !?ChunkShape {
        if (self.generation.stage == .idle) self.generation = .{
            .stage = .halo,
            .target_x = chunk_x,
            .target_z = chunk_z,
            .workspace_min_z = chunk_z - 2,
            .load_min_z = chunk_z - 2,
            .load_row_count = feature_workspace_rows,
        };
        std.debug.assert(
            self.generation.target_x == chunk_x and
                self.generation.target_z == chunk_z,
        );
        return switch (self.generation.stage) {
            .idle => unreachable,
            .halo => self.advanceHalo(),
            .base => self.advanceBase(),
            .surface => try self.advanceSurface(),
            .features_begin => try self.beginFeatures(),
            .features => try self.advanceFeatures(),
            .encode => self.finishGeneration(),
        };
    }

    fn advanceHalo(self: *Generator) ?ChunkShape {
        const load_count = self.generation.load_row_count * feature_workspace_width;
        while (self.generation.halo_index < load_count) {
            const index = self.generation.halo_index;
            const chunk_x = self.generation.target_x +
                @as(i32, @intCast(index % feature_workspace_width)) -
                feature_workspace_radius_x;
            const chunk_z = self.generation.load_min_z +
                @as(i32, @intCast(index / feature_workspace_width));
            if (self.baseChunkIndex(chunk_x, chunk_z)) |cached| {
                self.touchBaseChunk(cached);
                self.copyBaseChunkToWorkspace(index, cached);
                self.generation.halo_index += 1;
                continue;
            }
            self.generation.base_chunk_index = self.baseChunkVictim();
            self.vanilla.prepareBaseMaterials(chunk_x, chunk_z);
            self.generation.stage = .base;
            return null;
        }
        self.generation.stage = .features_begin;
        return null;
    }

    fn advanceBase(self: *Generator) ?ChunkShape {
        const states = self.baseChunkStates(
            self.generation.base_chunk_index,
        );
        if (self.vanilla.advanceBaseMaterials(self.material_scratch))
            self.generation.stage = .surface;
        _ = states;
        return null;
    }

    fn advanceSurface(self: *Generator) !?ChunkShape {
        const index = self.generation.halo_index;
        const chunk_x = self.generation.target_x +
            @as(i32, @intCast(index % feature_workspace_width)) -
            feature_workspace_radius_x;
        const chunk_z = self.generation.load_min_z +
            @as(i32, @intCast(index / feature_workspace_width));
        const states = self.baseChunkStates(
            self.generation.base_chunk_index,
        );
        try self.finishBaseChunk(chunk_x, chunk_z, states);
        self.cache_clock +%= 1;
        self.base_chunk_cache[self.generation.base_chunk_index] = .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .last_used = self.cache_clock,
            .valid = true,
        };
        self.copyBaseChunkToWorkspace(
            index,
            self.generation.base_chunk_index,
        );
        self.generation.halo_index += 1;
        self.generation.stage = .halo;
        return null;
    }

    fn finishBaseChunk(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        states: []vanilla_worldgen.generated_state.GeneratedState,
    ) !void {
        var heights: [16 * 16]i32 = undefined;
        try vanilla_worldgen.chunk.Generator.initializeSurface(
            self.material_scratch,
            states,
            &heights,
        );
        var biomes: vanilla_worldgen.chunk.BiomeHalo = undefined;
        self.vanilla.prepareSurfaceBiomeHalo(chunk_x, chunk_z, &biomes);
        const corners = vanilla_worldgen.density.preliminarySurfaceCorners(
            self.vanilla.router,
            chunk_x,
            chunk_z,
        );
        try self.vanilla.applySurfaceColumns(
            chunk_x,
            chunk_z,
            states,
            &heights,
            &biomes,
            &corners,
            0,
            16,
        );
        try self.vanilla.finishSurface(chunk_x, chunk_z, states);
        try self.vanilla.applyCarvers(chunk_x, chunk_z, states);
    }

    fn beginFeatures(self: *Generator) !?ChunkShape {
        if (!self.generation.features_started) {
            self.generation.feature_origin_index = 0;
            self.generation.features_started = true;
        }
        try self.initializeFeatureOrigin();
        self.generation.stage = .features;
        return null;
    }

    fn advanceFeatures(self: *Generator) !?ChunkShape {
        const origin = self.featureOrigin();
        var region = self.featureRegion(
            self.generation.target_x,
            self.generation.target_z,
            origin.x,
            origin.z,
        );
        if (try self.vanilla.advanceFeatureWork(
            origin.x,
            origin.z,
            &region,
            &self.feature_work,
        )) {
            self.generation.feature_origin_index += 1;
            if (self.generation.feature_origin_index == feature_origin_count) {
                self.generation.stage = .encode;
            } else if (self.generation.feature_origin_index % feature_origin_side == 0) {
                self.beginFeatureRow();
            } else {
                try self.initializeFeatureOrigin();
            }
        }
        return null;
    }

    fn beginFeatureRow(self: *Generator) void {
        self.generation.workspace_min_z += 1;
        self.generation.workspace_first_row =
            (self.generation.workspace_first_row + 1) % feature_workspace_rows;
        self.generation.load_min_z = self.generation.workspace_min_z + 2;
        self.generation.load_first_row =
            (self.generation.workspace_first_row + 2) % feature_workspace_rows;
        self.generation.load_row_count = 1;
        self.generation.halo_index = 0;
        self.generation.stage = .halo;
    }

    fn initializeFeatureOrigin(self: *Generator) !void {
        const origin = self.featureOrigin();
        var region = self.featureRegion(
            self.generation.target_x,
            self.generation.target_z,
            origin.x,
            origin.z,
        );
        try self.vanilla.initializeFeatureWork(
            origin.x,
            origin.z,
            &region,
            &self.feature_work,
        );
    }

    fn featureOrigin(self: *const Generator) FeatureOrigin {
        const index = self.generation.feature_origin_index;
        std.debug.assert(index < feature_origin_count);
        return .{
            .x = self.generation.target_x +
                @as(i32, @intCast(index % feature_origin_side)) - 1,
            .z = self.generation.target_z +
                @as(i32, @intCast(index / feature_origin_side)) - 1,
        };
    }

    fn finishGeneration(self: *Generator) !?ChunkShape {
        const target_row = self.workspaceRow(self.generation.target_z);
        const first = (target_row * feature_workspace_width + 2) *
            vanilla_worldgen.chunk.block_count;
        const center = self.feature_workspace_storage[first .. first + vanilla_worldgen.chunk.block_count];
        const result = try self.encodeShape(
            self.generation.target_x,
            self.generation.target_z,
            center,
        );
        self.generation = .{};
        return result;
    }

    pub fn generateFlat(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        surface_y: i16,
        surface_state: i32,
        underground_state: i32,
    ) !ChunkShape {
        return buildFlatChunkShape(
            &self.shape_storage,
            chunk_x,
            chunk_z,
            surface_y,
            surface_state,
            underground_state,
        );
    }

    pub fn generateVoid(self: *Generator, chunk_x: i32, chunk_z: i32) !ChunkShape {
        return buildVoidChunkShape(&self.shape_storage, chunk_x, chunk_z);
    }

    pub fn hasBaseChunk(self: *const Generator, chunk_x: i32, chunk_z: i32) bool {
        return self.baseChunkIndex(chunk_x, chunk_z) != null;
    }

    pub fn prepareBaseChunk(
        self: *Generator,
        target_x: i32,
        target_z: i32,
        chunk_x: i32,
        chunk_z: i32,
    ) !void {
        _ = target_x;
        _ = target_z;
        if (self.baseChunkIndex(chunk_x, chunk_z)) |index| {
            self.touchBaseChunk(index);
            return;
        }
        const entry_index = self.baseChunkVictim();
        const states = self.baseChunkStates(entry_index);
        self.vanilla.prepareBaseMaterials(chunk_x, chunk_z);
        while (!self.vanilla.advanceBaseMaterials(self.material_scratch)) {}

        var top_heights: [16 * 16]i32 = undefined;
        try vanilla_worldgen.chunk.Generator.initializeSurface(
            self.material_scratch,
            states,
            &top_heights,
        );
        var biome_halo: vanilla_worldgen.chunk.BiomeHalo = undefined;
        self.vanilla.prepareSurfaceBiomeHalo(chunk_x, chunk_z, &biome_halo);
        const preliminary_corners =
            vanilla_worldgen.density.preliminarySurfaceCorners(
                self.vanilla.router,
                chunk_x,
                chunk_z,
            );
        try self.vanilla.applySurfaceColumns(
            chunk_x,
            chunk_z,
            states,
            &top_heights,
            &biome_halo,
            &preliminary_corners,
            0,
            16,
        );
        try self.vanilla.finishSurface(chunk_x, chunk_z, states);
        try self.vanilla.applyCarvers(chunk_x, chunk_z, states);

        self.cache_clock +%= 1;
        self.base_chunk_cache[entry_index] = .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .last_used = self.cache_clock,
            .valid = true,
        };
    }

    fn copyBaseChunkToWorkspace(
        self: *Generator,
        load_index: usize,
        base_chunk_index: usize,
    ) void {
        const load_row = load_index / feature_workspace_width;
        const workspace_row = (self.generation.load_first_row + load_row) %
            feature_workspace_rows;
        const workspace_index = workspace_row * feature_workspace_width +
            load_index % feature_workspace_width;
        const first = workspace_index * vanilla_worldgen.chunk.block_count;
        @memcpy(
            self.feature_workspace_storage[first .. first + vanilla_worldgen.chunk.block_count],
            self.baseChunkStates(base_chunk_index),
        );
    }

    fn workspaceRow(self: *const Generator, chunk_z: i32) usize {
        const logical = chunk_z - self.generation.workspace_min_z;
        std.debug.assert(logical >= 0 and logical < feature_workspace_rows);
        return (self.generation.workspace_first_row +
            @as(usize, @intCast(logical))) % feature_workspace_rows;
    }

    fn featureRegion(
        self: *Generator,
        target_x: i32,
        target_z: i32,
        origin_x: i32,
        origin_z: i32,
    ) vanilla_worldgen.feature.Region {
        const offset_x = origin_x - target_x;
        std.debug.assert(@abs(offset_x) <= 1 and @abs(origin_z - target_z) <= 1);
        var chunks: [feature_origin_count][]GeneratedState = undefined;
        for (&chunks, 0..) |*chunk, index| {
            const workspace_x: usize = @intCast(
                offset_x + @as(i32, @intCast(index % 3)) + 1,
            );
            const chunk_z = origin_z + @as(i32, @intCast(index / 3)) - 1;
            const workspace_index = self.workspaceRow(chunk_z) *
                feature_workspace_width + workspace_x;
            const first = workspace_index * vanilla_worldgen.chunk.block_count;
            chunk.* = self.feature_workspace_storage[first .. first + vanilla_worldgen.chunk.block_count];
        }
        return .{
            .center_chunk_x = origin_x,
            .center_chunk_z = origin_z,
            .chunks = chunks,
            .biome_cache = &self.vanilla.biome_cache,
        };
    }

    fn encodeShape(self: *Generator, chunk_x: i32, chunk_z: i32, states: []const GeneratedState) !ChunkShape {
        var shape: ChunkShape = .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .heights = undefined,
            .storage = &self.shape_storage,
        };
        @memcpy(
            &shape.biomes,
            self.vanilla.biome_cache.chunk(
                self.vanilla.climate_sampler,
                chunk_x,
                chunk_z,
            ),
        );
        var block_states: [blocks_per_section]i32 = undefined;
        for (0..config.overworld_section_count) |section| {
            for (&block_states, 0..) |*block_state, local_index| {
                const local_x: i32 = @intCast(local_index & 15);
                const local_z: i32 = @intCast((local_index >> 4) & 15);
                const local_y: i32 = @intCast(local_index >> 8);
                const y = @as(i32, config.world_min_y) +
                    @as(i32, @intCast(section * 16)) + local_y;
                const generated = states[
                    vanilla_worldgen.chunk.blockIndex(
                        local_x,
                        y,
                        local_z,
                    )
                ];
                block_state.* = self.stateId(generated);
            }
            try shape.encodeSection(section, &block_states);
        }
        shape.rebuildHeights();
        return shape;
    }

    fn baseChunkIndex(self: *const Generator, chunk_x: i32, chunk_z: i32) ?usize {
        for (self.base_chunk_cache, 0..) |entry, index| {
            if (entry.valid and entry.chunk_x == chunk_x and entry.chunk_z == chunk_z)
                return index;
        }
        return null;
    }

    fn baseChunkStates(self: *Generator, index: usize) []GeneratedState {
        const first = index * vanilla_worldgen.chunk.block_count;
        return self.base_chunk_storage[first .. first + vanilla_worldgen.chunk.block_count];
    }

    fn touchBaseChunk(self: *Generator, index: usize) void {
        self.cache_clock +%= 1;
        self.base_chunk_cache[index].last_used = self.cache_clock;
    }

    fn baseChunkVictim(self: *const Generator) usize {
        var victim: ?usize = null;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.base_chunk_cache, 0..) |entry, index| {
            if (!entry.valid) return index;
            if (entry.last_used < oldest) {
                oldest = entry.last_used;
                victim = index;
            }
        }
        return victim orelse unreachable;
    }

    fn stateId(
        self: *const Generator,
        generated: vanilla_worldgen.generated_state.GeneratedState,
    ) i32 {
        return switch (generated) {
            .base => |material| switch (material) {
                .stone => registry.block_stone_default_state,
                .air => registry.block_air_default_state,
                .water => registry.state_water_level_0,
                .lava => registry.state_lava_level_0,
            },
            .surface => |index| self.surface_states[index],
            .feature => |index| self.feature_states[index],
        };
    }
};

pub fn fillChunkRandomTickMasksFromShape(
    shape: *const ChunkShape,
    heights: *[16 * 16]i16,
    grass_above_blocked: *[4]u64,
    masks: *[config.overworld_section_count][random_tick_mask_words]u64,
    counts: *[config.overworld_section_count]u16,
) u32 {
    @memset(masks, [_]u64{0} ** random_tick_mask_words);
    @memset(counts, 0);
    grass_above_blocked.* = [_]u64{0} ** 4;
    return fillRandomTickMasks(shape, heights, grass_above_blocked, masks, counts);
}

fn fillRandomTickMasks(
    shape: *const ChunkShape,
    heights: *[16 * 16]i16,
    grass_above_blocked: *[4]u64,
    masks: *[config.overworld_section_count][random_tick_mask_words]u64,
    counts: *[config.overworld_section_count]u16,
) u32 {
    heights.* = shape.heights;
    for (shape.heights, 0..) |height, column| {
        if (height < config.world_min_y or height >= maximum_generated_y) continue;
        const relative: usize = @intCast(height + 1 - config.world_min_y);
        const above = shape.sectionBlockState(
            relative / 16,
            @intCast((column & 15) | ((column >> 4) << 4) | ((relative & 15) << 8)),
        );
        if (game_data.preventsGrassSurvival(above))
            grass_above_blocked[column / 64] |= @as(u64, 1) << @intCast(column & 63);
    }
    var blocks: [blocks_per_section]i32 = undefined;
    var section_mask: u32 = 0;
    for (0..config.overworld_section_count) |section| {
        fillSectionFromShape(shape, section, &blocks);
        var total: u16 = 0;
        for (blocks, 0..) |block_state, local_index| {
            if (registry.randomTickState(block_state).kind == .none) continue;
            masks[section][local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
            total += 1;
        }
        counts[section] = total;
        if (total != 0) section_mask |= @as(u32, 1) << @intCast(section);
    }
    return section_mask;
}

pub const SectionVisibility = enum(u2) {
    transparent,
    solid,
    mixed,
};

pub const ChunkShape = struct {
    chunk_x: i32,
    chunk_z: i32,
    heights: [16 * 16]i16,
    /// True when the generated base contains dirt with a non-blocking block
    /// above it. Consumers use this metadata instead of inferring facts from
    /// the current generator's terrain rules.
    grass_spread_possible: bool = false,
    sections: [config.overworld_section_count]SectionShape =
        [_]SectionShape{.{}} ** config.overworld_section_count,
    section_visibility: [config.overworld_section_count]SectionVisibility =
        [_]SectionVisibility{.mixed} ** config.overworld_section_count,
    storage_len: u32 = 0,
    storage: []u8 = &.{},
    biomes: [vanilla_worldgen.biome.overworld_cell_count]u8 = undefined,

    fn encodeSection(
        self: *ChunkShape,
        section: usize,
        blocks: *const [blocks_per_section]i32,
    ) !void {
        var palette: [256]i32 = undefined;
        var indices: [blocks_per_section]u8 = undefined;
        var all_transparent = true;
        var all_opaque = true;
        var palette_count: usize = 0;
        for (blocks, 0..) |block_state, block_index| {
            var palette_index: usize = 0;
            while (palette_index < palette_count and
                palette[palette_index] != block_state) : (palette_index += 1)
            {}
            if (palette_index == palette_count) {
                if (palette_count == palette.len) return error.GeneratedSectionPaletteCapacity;
                palette[palette_count] = block_state;
                palette_count += 1;
            }
            indices[block_index] = @intCast(palette_index);
            const info = game_data.blockInfo(block_state);
            all_transparent = all_transparent and
                info.visually_transparent;
            all_opaque = all_opaque and
                !info.visually_transparent and info.filtered_light >= 15;
        }
        self.section_visibility[section] =
            if (all_transparent)
                .transparent
            else if (all_opaque)
                .solid
            else
                .mixed;

        const bits: u4 = if (palette_count <= 1)
            0
        else
            @intCast(std.math.log2_int_ceil(usize, palette_count));
        const palette_bytes = palette_count * @sizeOf(i32);
        const data_bytes = (@as(usize, bits) * blocks_per_section + 7) / 8;
        const required = @as(usize, self.storage_len) + palette_bytes + data_bytes;
        if (required > self.storage.len) return error.GeneratedChunkStorageCapacity;
        const descriptor = &self.sections[section];
        descriptor.* = .{
            .palette_offset = self.storage_len,
            .data_offset = self.storage_len + @as(u32, @intCast(palette_bytes)),
            .palette_count = @intCast(palette_count),
            .bits_per_block = bits,
        };
        var cursor: usize = self.storage_len;
        for (palette[0..palette_count]) |block_state| {
            std.mem.writeInt(i32, self.storage[cursor..][0..4], block_state, .little);
            cursor += 4;
        }
        @memset(self.storage[cursor..][0..data_bytes], 0);
        if (bits != 0) {
            const mask: u16 = (@as(u16, 1) << bits) - 1;
            for (indices, 0..) |palette_index, block_index| {
                const bit_offset = block_index * @as(usize, bits);
                const byte_offset = cursor + bit_offset / 8;
                const shift: u4 = @intCast(bit_offset & 7);
                const encoded = (@as(u16, palette_index) & mask) << shift;
                self.storage[byte_offset] |= @truncate(encoded);
                if (shift + bits > 8)
                    self.storage[byte_offset + 1] |= @truncate(encoded >> 8);
            }
        }
        self.storage_len = @intCast(required);
    }

    fn encodeUniformSection(
        self: *ChunkShape,
        section: usize,
        block_state: i32,
    ) !void {
        const required = @as(usize, self.storage_len) + @sizeOf(i32);
        if (required > self.storage.len) return error.GeneratedChunkStorageCapacity;
        self.sections[section] = .{
            .palette_offset = self.storage_len,
            .data_offset = self.storage_len + @sizeOf(i32),
            .palette_count = 1,
            .bits_per_block = 0,
        };
        std.mem.writeInt(
            i32,
            self.storage[self.storage_len..][0..@sizeOf(i32)],
            block_state,
            .little,
        );
        const info = game_data.blockInfo(block_state);
        self.section_visibility[section] =
            if (info.visually_transparent)
                .transparent
            else if (info.filtered_light >= 15)
                .solid
            else
                .mixed;
        self.storage_len = @intCast(required);
    }

    pub inline fn sectionPaletteCount(
        self: *const ChunkShape,
        section: usize,
    ) usize {
        return self.sections[section].palette_count;
    }

    pub inline fn sectionPaletteState(
        self: *const ChunkShape,
        section: usize,
        palette_index: usize,
    ) i32 {
        const descriptor = self.sections[section];
        std.debug.assert(palette_index < descriptor.palette_count);
        const offset = @as(usize, descriptor.palette_offset) +
            palette_index * @sizeOf(i32);
        return std.mem.readInt(
            i32,
            self.storage[offset..][0..4],
            .little,
        );
    }

    pub inline fn sectionPaletteIndex(
        self: *const ChunkShape,
        section: usize,
        local_index: u16,
    ) u16 {
        const descriptor = self.sections[section];
        var palette_index: u16 = 0;
        if (descriptor.bits_per_block != 0) {
            const bit_offset = @as(usize, local_index) *
                @as(usize, descriptor.bits_per_block);
            const byte_offset = @as(usize, descriptor.data_offset) + bit_offset / 8;
            const shift: u4 = @intCast(bit_offset & 7);
            var encoded: u16 = self.storage[byte_offset];
            if (shift + descriptor.bits_per_block > 8)
                encoded |= @as(u16, self.storage[byte_offset + 1]) << 8;
            const mask: u16 = (@as(u16, 1) << descriptor.bits_per_block) - 1;
            palette_index = (encoded >> shift) & mask;
        }
        std.debug.assert(palette_index < descriptor.palette_count);
        return palette_index;
    }

    pub inline fn sectionBlockState(
        self: *const ChunkShape,
        section: usize,
        local_index: u16,
    ) i32 {
        return self.sectionPaletteState(
            section,
            self.sectionPaletteIndex(section, local_index),
        );
    }

    pub fn rebuildSectionVisibility(self: *ChunkShape) void {
        for (0..config.overworld_section_count) |section| {
            var all_transparent = true;
            var all_opaque = true;
            for (0..blocks_per_section) |block_index| {
                const block_state = self.sectionBlockState(
                    section,
                    @intCast(block_index),
                );
                const info = game_data.blockInfo(block_state);
                all_transparent = all_transparent and
                    info.visually_transparent;
                all_opaque = all_opaque and
                    !info.visually_transparent and
                    info.filtered_light >= 15;
            }
            self.section_visibility[section] =
                if (all_transparent)
                    .transparent
                else if (all_opaque)
                    .solid
                else
                    .mixed;
        }
    }

    fn rebuildHeights(self: *ChunkShape) void {
        // Full Vanilla chunks can contain dirt candidates below foliage and
        // other non-heightmap blocks. Keep the summary conservative; the
        // authoritative query checks the candidate and its neighbor exactly.
        self.grass_spread_possible = true;
        for (0..16) |local_z| {
            for (0..16) |local_x| {
                var highest = @as(i32, config.world_min_y) - 1;
                var section = config.overworld_section_count;
                search: while (section > 0) {
                    section -= 1;
                    var local_y: usize = 16;
                    while (local_y > 0) {
                        local_y -= 1;
                        const local_index: u16 = @intCast(
                            local_x | (local_z << 4) | (local_y << 8),
                        );
                        const block_state = self.sectionBlockState(section, local_index);
                        if (block_state == registry.block_air_default_state) continue;
                        highest = @as(i32, config.world_min_y) +
                            @as(i32, @intCast(section * 16 + local_y));
                        break :search;
                    }
                }
                self.heights[local_z * 16 + local_x] = @intCast(highest);
            }
        }
    }
};

pub fn highestYFromShape(shape: *const ChunkShape, local_x: usize, local_z: usize) i16 {
    std.debug.assert(local_x < 16 and local_z < 16);
    return shape.heights[local_z * 16 + local_x];
}

test "neighbor feature origins survive chunk encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator = try Generator.init(
        arena.allocator(),
        0x6d62_756e_6400_0001,
        9,
    );
    const block_count = vanilla_worldgen.chunk.block_count;
    const storage = try arena.allocator().alloc(
        vanilla_worldgen.generated_state.GeneratedState,
        9 * block_count,
    );
    var chunks: [9][]vanilla_worldgen.generated_state.GeneratedState = undefined;
    for (&chunks, 0..) |*chunk, index| {
        const chunk_x = @as(i32, @intCast(index % 3)) - 1;
        const chunk_z = @as(i32, @intCast(index / 3)) - 1;
        try generator.prepareBaseChunk(0, 0, chunk_x, chunk_z);
        const source = generator.baseChunkIndex(chunk_x, chunk_z) orelse unreachable;
        chunk.* = storage[index * block_count .. (index + 1) * block_count];
        @memcpy(chunk.*, generator.baseChunkStates(source));
    }
    var region: vanilla_worldgen.feature.Region = .{
        .center_chunk_x = 0,
        .center_chunk_z = 0,
        .chunks = chunks,
        .biome_cache = &generator.vanilla.biome_cache,
    };
    try generator.vanilla.applyFeaturesToRegion(0, 0, &region);
    const expected = try arena.allocator().dupe(
        vanilla_worldgen.generated_state.GeneratedState,
        chunks[5],
    );
    const actual = try generator.generate(1, 0);
    var compared: usize = 0;
    for (0..8) |local_x| for (0..16) |local_z| {
        var y: i32 = vanilla_worldgen.chunk.minimum_y;
        while (y < vanilla_worldgen.chunk.minimum_y + vanilla_worldgen.chunk.height) : (y += 1) {
            const index = vanilla_worldgen.chunk.blockIndex(@intCast(local_x), y, @intCast(local_z));
            if (!generatedTreeState(expected[index])) continue;
            compared += 1;
            try std.testing.expectEqual(
                generator.stateId(expected[index]),
                blockAtFromShape(&actual, 16 + @as(i32, @intCast(local_x)), @intCast(y), @intCast(local_z)),
            );
        }
    };
    try std.testing.expect(compared != 0);
}

fn generatedTreeState(
    state: vanilla_worldgen.generated_state.GeneratedState,
) bool {
    const name = state.canonicalName();
    return std.mem.indexOf(u8, name, "_leaves[") != null or
        std.mem.indexOf(u8, name, "_log[") != null;
}

/// Query an already-generated chunk. This performs no hashing, noise, or
/// generator calls; the chunk shape is the compact canonical base stored by
/// the resident world and persisted with the chunk.
pub fn blockAtFromShape(shape: *const ChunkShape, x: i32, y: i16, z: i32) i32 {
    const min_x = shape.chunk_x * 16;
    const min_z = shape.chunk_z * 16;
    std.debug.assert(x >= min_x and x < min_x + 16 and z >= min_z and z < min_z + 16);
    const local_x: usize = @intCast(x - min_x);
    const local_z: usize = @intCast(z - min_z);
    if (y < config.world_min_y or
        y >= config.world_min_y + @as(i16, @intCast(config.overworld_section_count * 16)))
        return registry.block_air_default_state;
    const relative_y: usize = @intCast(y - config.world_min_y);
    const local_index: u16 = @intCast(
        local_x | (local_z << 4) | ((relative_y & 15) << 8),
    );
    return shape.sectionBlockState(relative_y / 16, local_index);
}

pub fn fillSectionFromShape(shape: *const ChunkShape, section: usize, output: *[blocks_per_section]i32) void {
    std.debug.assert(section < config.overworld_section_count);
    for (output, 0..) |*block_state, local_index|
        block_state.* = shape.sectionBlockState(section, @intCast(local_index));
}

pub fn uniformSectionState(
    shape: *const ChunkShape,
    section: usize,
) ?i32 {
    if (section >= config.overworld_section_count) return null;
    const descriptor = shape.sections[section];
    if (descriptor.palette_count != 1) return null;
    return std.mem.readInt(
        i32,
        shape.storage[descriptor.palette_offset..][0..@sizeOf(i32)],
        .little,
    );
}

pub fn fillSectionBiomesFromShape(
    shape: *const ChunkShape,
    section: usize,
    output: *[biome_cells_per_section]u8,
) void {
    std.debug.assert(section < config.overworld_section_count);
    @memcpy(
        output,
        shape.biomes[section * biome_cells_per_section ..][0..biome_cells_per_section],
    );
}

pub fn biomeNames() []const []const u8 {
    return vanilla_worldgen.biome.names();
}

pub fn buildFlatChunkShape(
    storage: []u8,
    chunk_x: i32,
    chunk_z: i32,
    surface_y: i16,
    surface_state: i32,
    underground_state: i32,
) !ChunkShape {
    if (!validBlockState(surface_state) or !validBlockState(underground_state))
        return error.InvalidBlockState;
    if (surface_y < config.world_min_y or surface_y > maximum_generated_y)
        return error.InvalidSurfaceHeight;
    var shape: ChunkShape = .{
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
        .heights = [_]i16{surface_y} ** (16 * 16),
        .grass_spread_possible = false,
        .storage = storage,
    };
    var blocks: [blocks_per_section]i32 = undefined;
    const surface = @as(i32, surface_y);
    for (0..config.overworld_section_count) |section| {
        const bottom = @as(i32, config.world_min_y) +
            @as(i32, @intCast(section * 16));
        const top = bottom + 15;
        if (top < surface) {
            try shape.encodeUniformSection(section, underground_state);
            continue;
        }
        if (bottom > surface) {
            try shape.encodeUniformSection(
                section,
                registry.block_air_default_state,
            );
            continue;
        }
        for (&blocks, 0..) |*block_state, local_index| {
            const y = bottom + @as(i32, @intCast(local_index >> 8));
            block_state.* = if (y < surface)
                underground_state
            else if (y == surface)
                surface_state
            else
                registry.block_air_default_state;
        }
        try shape.encodeSection(section, &blocks);
    }
    @memset(&shape.biomes, plainsBiomeId());
    return shape;
}

pub fn buildVoidChunkShape(
    storage: []u8,
    chunk_x: i32,
    chunk_z: i32,
) !ChunkShape {
    var shape: ChunkShape = .{
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
        .heights = [_]i16{config.world_min_y - 1} ** (16 * 16),
        .grass_spread_possible = false,
        .storage = storage,
    };
    for (0..config.overworld_section_count) |section|
        try shape.encodeUniformSection(section, registry.block_air_default_state);
    @memset(&shape.biomes, plainsBiomeId());
    return shape;
}

pub fn validBlockState(block_state: i32) bool {
    return block_state >= 0 and block_state <= registry.maximum_block_state;
}

pub fn plainsBiomeId() u8 {
    for (biomeNames(), 0..) |name, index| {
        if (std.mem.eql(u8, name, "minecraft:plains"))
            return @intCast(index);
    }
    unreachable;
}

pub fn sectionMayContainBlocks(section: usize) bool {
    return section < config.overworld_section_count;
}

pub fn uniformSectionBlockStateFromShape(
    shape: *const ChunkShape,
    section: usize,
) ?i32 {
    return uniformSectionState(shape, section);
}

test "random tick masks include every tickable block" {
    var storage: [chunk_storage_capacity]u8 = undefined;
    const shape = try buildFlatChunkShape(
        &storage,
        0,
        0,
        64,
        registry.block_grass_block_default_state,
        registry.block_stone_default_state,
    );
    var heights: [16 * 16]i16 = undefined;
    var blocked: [4]u64 = undefined;
    var masks: [config.overworld_section_count][random_tick_mask_words]u64 = undefined;
    var counts: [config.overworld_section_count]u16 = undefined;
    const sections = fillChunkRandomTickMasksFromShape(&shape, &heights, &blocked, &masks, &counts);
    for (masks, counts, 0..) |section_mask, count, section| {
        var observed: u16 = 0;
        for (section_mask, 0..) |word, word_index| {
            observed += @popCount(word);
            var remaining = word;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                const local_index: u16 = @intCast(word_index * 64 + bit);
                const state = blockAtFromShape(
                    &shape,
                    shape.chunk_x * 16 + @as(i32, local_index & 15),
                    config.world_min_y + @as(i16, @intCast(section * 16 + (local_index >> 8))),
                    shape.chunk_z * 16 + @as(i32, (local_index >> 4) & 15),
                );
                try std.testing.expect(registry.randomTickState(state).kind != .none);
            }
        }
        try std.testing.expectEqual(count, observed);
        try std.testing.expectEqual(count != 0, sections & (@as(u32, 1) << @intCast(section)) != 0);
    }
    for (0..config.overworld_section_count) |section| {
        for (0..blocks_per_section) |index| {
            const local_index: u16 = @intCast(index);
            const state = blockAtFromShape(
                &shape,
                shape.chunk_x * 16 + @as(i32, local_index & 15),
                config.world_min_y + @as(i16, @intCast(section * 16 + (local_index >> 8))),
                shape.chunk_z * 16 + @as(i32, (local_index >> 4) & 15),
            );
            if (registry.randomTickState(state).kind == .none) continue;
            try std.testing.expect(masks[section][local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) != 0);
        }
    }
}
