const std = @import("std");
const lightning_rod = @import("lightning_rod");
const preallocated = lightning_rod.preallocated;
const limits = lightning_rod.world_limits;
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
pub const vanilla_worldgen = @import("worldgen");
pub const SectionShape = lightning_rod.terrain.SectionShape;
pub const SectionVisibility = lightning_rod.terrain.SectionVisibility;
pub const ChunkShape = lightning_rod.terrain.ChunkShape;

pub const blocks_per_section = lightning_rod.terrain.blocks_per_section;
pub const maximum_generated_y = lightning_rod.terrain.maximum_generated_y;
pub const chunk_storage_capacity = lightning_rod.terrain.chunk_storage_capacity;
pub const biome_registry_count = lightning_rod.terrain.biome_registry_count;
const base_cache_chunk_capacity = 16 * 1024;
const base_cache_workspace_count = 8;

pub const random_tick_mask_words = lightning_rod.terrain.random_tick_mask_words;
pub const biome_cells_per_section = lightning_rod.terrain.biome_cells_per_section;
pub const biome_cells_per_chunk = lightning_rod.terrain.biome_cells_per_chunk;

pub const Generator = struct {
    pub const maximum_batch_side = 32;
    const workspace_rows = 3;
    const FeatureOrigin = struct { x: i32, z: i32 };
    const ChunkHeights = struct {
        ocean_floor: [16 * 16]i16,
        world_surface: [16 * 16]i16,
    };
    const GeneratedState = vanilla_worldgen.generated_state.GeneratedState;
    const CachedBaseChunk = struct {
        valid: bool = false,
        chunk_x: i32 = 0,
        chunk_z: i32 = 0,
        stamp: u64 = 0,
        storage_len: u32 = 0,
        sections: [limits.section_count]SectionShape =
            [_]SectionShape{.{}} ** limits.section_count,
        heights: ChunkHeights = undefined,
    };

    vanilla: vanilla_worldgen.chunk.Generator,
    state_ids: []i32,
    batch_side: usize,
    workspace_side: usize,
    feature_workspace_storage: []GeneratedState,
    feature_heights: []ChunkHeights,
    base_cache: []CachedBaseChunk,
    base_cache_storage: []u8,
    base_cache_stamp: u64 = 0,
    workspace_z: [workspace_rows]i32 = @splat(std.math.minInt(i32)),
    top_heights: [16 * 16]i32 = undefined,
    dirty_columns: [9][4]u64 = @splat(@splat(0)),
    dirty_origin: FeatureOrigin = .{ .x = 0, .z = 0 },
    feature_work: vanilla_worldgen.chunk.FeatureWork = undefined,
    shape_storage: [chunk_storage_capacity]u8 = undefined,
    requested_shape_storage: [chunk_storage_capacity]u8 = undefined,
    requested_shape: ChunkShape = undefined,
    generation: Generation = .{},

    pub const GenerationStage = enum {
        idle,
        base_prepare,
        base,
        surface,
        ores,
        carvers,
        features_begin,
        features,
        encode,
    };

    const Generation = struct {
        stage: GenerationStage = .idle,
        batch_min_x: i32 = 0,
        batch_min_z: i32 = 0,
        requested_output: usize = 0,
        base_z: i32 = 0,
        base_x: usize = 0,
        feature_z: i32 = -1,
        feature_x: usize = 0,
        output_z: usize = 0,
        output_x: usize = 0,
        requested_shape_ready: bool = false,
        requested_shape_emitted: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, seed: u64, batch_side: usize) !Generator {
        var result: Generator = undefined;
        try result.initInto(allocator, seed, batch_side);
        return result;
    }

    pub fn initInto(self: *Generator, allocator: std.mem.Allocator, seed: u64, batch_side: usize) !void {
        if (batch_side == 0 or batch_side > maximum_batch_side)
            return error.InvalidTerrainBatchSide;
        try self.vanilla.initForRegionInto(allocator, seed);
        errdefer self.vanilla.deinit();
        const state_ids = try preallocated.alloc(
            i32,
            allocator,
            vanilla_worldgen.generated_state.stateCount(),
        );
        errdefer allocator.free(state_ids);
        const workspace_side = batch_side + 4;
        const feature_workspace_storage = try preallocated.alloc(
            GeneratedState,
            allocator,
            workspace_side * workspace_rows *
                vanilla_worldgen.chunk.block_count,
        );
        errdefer allocator.free(feature_workspace_storage);
        const feature_heights = try preallocated.alloc(
            ChunkHeights,
            allocator,
            workspace_side * workspace_rows,
        );
        errdefer allocator.free(feature_heights);
        const base_cache = try preallocated.alloc(
            CachedBaseChunk,
            allocator,
            workspace_side * workspace_rows * base_cache_workspace_count,
        );
        errdefer allocator.free(base_cache);
        @memset(base_cache, .{});
        const base_cache_storage = try preallocated.alloc(
            u8,
            allocator,
            base_cache.len * base_cache_chunk_capacity,
        );
        errdefer allocator.free(base_cache_storage);
        for (state_ids, 0..) |*state, index| {
            const generated: GeneratedState = @enumFromInt(index);
            state.* = registry.blockStateId(generated.canonicalName()) orelse
                return error.UnknownGeneratedBlockState;
        }
        self.state_ids = state_ids;
        self.batch_side = batch_side;
        self.workspace_side = workspace_side;
        self.feature_workspace_storage = feature_workspace_storage;
        self.feature_heights = feature_heights;
        self.base_cache = base_cache;
        self.base_cache_storage = base_cache_storage;
        self.base_cache_stamp = 0;
        self.workspace_z = @splat(std.math.minInt(i32));
        self.dirty_columns = @splat(@splat(0));
        self.dirty_origin = .{ .x = 0, .z = 0 };
        self.generation = .{};
    }

    pub fn reseed(self: *Generator, seed: u64) !void {
        if (self.vanilla.world_seed == seed) return;
        std.debug.assert(self.generation.stage == .idle);
        try self.vanilla.reseed(seed);
        @memset(self.base_cache, .{});
        self.base_cache_stamp = 0;
    }

    pub fn deinit(self: *Generator) void {
        const allocator = self.vanilla.allocator;
        allocator.free(self.base_cache_storage);
        allocator.free(self.base_cache);
        allocator.free(self.feature_heights);
        allocator.free(self.feature_workspace_storage);
        allocator.free(self.state_ids);
        self.vanilla.deinit();
        self.* = undefined;
    }

    pub fn generate(self: *Generator, chunk_x: i32, chunk_z: i32) !ChunkShape {
        self.cancel();
        while (true) {
            if (try self.advance(chunk_x, chunk_z)) |shape| {
                if (shape.chunk_x == chunk_x and shape.chunk_z == chunk_z)
                    return shape;
            }
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

    pub fn maximumCachedBaseBytes(self: *const Generator) usize {
        var maximum: usize = 0;
        for (self.base_cache) |entry| {
            if (!entry.valid) continue;
            maximum = @max(maximum, entry.storage_len);
        }
        return maximum;
    }

    pub fn advance(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
    ) !?ChunkShape {
        if (self.generation.stage == .idle)
            self.beginBatch(chunk_x, chunk_z);
        std.debug.assert(
            self.generation.batch_min_x +
                @as(i32, @intCast(self.generation.requested_output % self.batch_side)) == chunk_x and
                self.generation.batch_min_z +
                    @as(i32, @intCast(self.generation.requested_output / self.batch_side)) == chunk_z,
        );
        return switch (self.generation.stage) {
            .idle => unreachable,
            .base_prepare => self.prepareBaseChunk(),
            .base => self.advanceBase(),
            .surface => try self.advanceSurface(),
            .ores => try self.advanceOres(),
            .carvers => try self.advanceCarvers(),
            .features_begin => try self.beginFeatures(),
            .features => try self.advanceFeatures(),
            .encode => self.finishGeneration(),
        };
    }

    pub fn advanceSlice(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        base_chunks: usize,
        feature_steps: usize,
        sink: lightning_rod.generator_api.Sink,
    ) !bool {
        std.debug.assert(base_chunks > 0 and feature_steps > 0);
        var completed_bases: usize = 0;
        var completed_features: usize = 0;
        while (true) {
            const stage = self.generation.stage;
            const requested_shape_emitted = self.generation.requested_shape_emitted;
            if (try self.advance(chunk_x, chunk_z)) |shape| {
                const requested = shape.chunk_x == chunk_x and shape.chunk_z == chunk_z;
                if (!requested or !requested_shape_emitted) try sink.emit(shape);
            }
            if (self.generation.stage == .idle) return true;
            if (self.generation.requested_shape_ready and
                !self.generation.requested_shape_emitted)
            {
                try sink.emit(self.requested_shape);
                self.generation.requested_shape_emitted = true;
            }
            if (stage == .carvers) {
                completed_bases += 1;
                if (completed_bases == base_chunks) return false;
            }
            if (stage == .features) {
                completed_features += 1;
                if (completed_features == feature_steps) return false;
            }
        }
    }

    fn beginBatch(self: *Generator, chunk_x: i32, chunk_z: i32) void {
        const side: i32 = @intCast(self.batch_side);
        const batch_min_x = @divFloor(chunk_x, side) * side;
        const batch_min_z = @divFloor(chunk_z, side) * side;
        @memset(&self.dirty_columns, @splat(0));
        @memset(&self.workspace_z, std.math.minInt(i32));
        self.generation = .{
            .stage = .base_prepare,
            .batch_min_x = batch_min_x,
            .batch_min_z = batch_min_z,
            .requested_output = @intCast(
                (chunk_z - batch_min_z) * side + chunk_x - batch_min_x,
            ),
            .base_z = batch_min_z - 2,
        };
        self.beginBaseRow(batch_min_z - 2);
    }

    fn prepareBaseChunk(self: *Generator) ?ChunkShape {
        const position = self.baseChunkPosition();
        const workspace = self.workspaceIndex(position.x, position.z);
        if (self.findCachedBaseChunk(position)) |cache_index| {
            self.base_cache_stamp += 1;
            self.base_cache[cache_index].stamp = self.base_cache_stamp;
            self.decodeCachedBaseChunk(cache_index, workspace);
            self.advanceBasePosition();
            return null;
        }
        @memset(&self.top_heights, vanilla_worldgen.chunk.minimum_y);
        self.vanilla.prepareBaseMaterials(position.x, position.z);
        self.generation.stage = .base;
        return null;
    }

    fn advanceBase(self: *Generator) ?ChunkShape {
        if (self.vanilla.advanceBaseStates(
            self.workspaceStates(self.workspaceIndex(
                self.baseChunkPosition().x,
                self.baseChunkPosition().z,
            )),
            &self.top_heights,
        ))
            self.generation.stage = .surface;
        return null;
    }

    fn advanceSurface(self: *Generator) !?ChunkShape {
        const position = self.baseChunkPosition();
        const index = self.workspaceIndex(position.x, position.z);
        try self.applySurface(
            position.x,
            position.z,
            self.workspaceStates(index),
            &self.top_heights,
        );
        self.generation.stage = .ores;
        return null;
    }

    fn advanceOres(self: *Generator) !?ChunkShape {
        const position = self.baseChunkPosition();
        const index = self.workspaceIndex(position.x, position.z);
        try self.vanilla.finishSurface(position.x, position.z, self.workspaceStates(index));
        self.generation.stage = .carvers;
        return null;
    }

    fn advanceCarvers(self: *Generator) !?ChunkShape {
        const position = self.baseChunkPosition();
        const index = self.workspaceIndex(position.x, position.z);
        try self.vanilla.applyCarvers(position.x, position.z, self.workspaceStates(index));
        vanilla_worldgen.chunk.fillChunkHeights(
            self.workspaceStates(index),
            &self.feature_heights[index].ocean_floor,
            &self.feature_heights[index].world_surface,
        );
        try self.cacheBaseChunk(index, position);
        self.advanceBasePosition();
        return null;
    }

    fn advanceBasePosition(self: *Generator) void {
        self.generation.base_x += 1;
        if (self.generation.base_x < self.workspace_side) {
            self.generation.stage = .base_prepare;
            return;
        }
        if (self.generation.base_z < self.generation.batch_min_z) {
            self.beginBaseRow(self.generation.base_z + 1);
            return;
        }
        self.generation.stage = .features_begin;
    }

    fn beginBaseRow(self: *Generator, chunk_z: i32) void {
        const slot: usize = @intCast(@mod(chunk_z, workspace_rows));
        self.workspace_z[slot] = chunk_z;
        self.generation.base_z = chunk_z;
        self.generation.base_x = 0;
        self.generation.stage = .base_prepare;
    }

    fn applySurface(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        states: []vanilla_worldgen.generated_state.GeneratedState,
        heights: *[16 * 16]i32,
    ) !void {
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
            heights,
            &biomes,
            &corners,
            0,
            16,
        );
    }

    fn finishBaseChunk(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        states: []GeneratedState,
        heights: *[16 * 16]i32,
    ) !void {
        try self.applySurface(chunk_x, chunk_z, states, heights);
        try self.vanilla.finishSurface(chunk_x, chunk_z, states);
        try self.vanilla.applyCarvers(chunk_x, chunk_z, states);
    }

    fn beginFeatures(self: *Generator) !?ChunkShape {
        try self.initializeFeatureOrigin();
        self.generation.stage = .features;
        return null;
    }

    fn advanceFeatures(self: *Generator) !?ChunkShape {
        const origin = self.featureOrigin();
        var region = self.featureRegion(origin.x, origin.z);
        if (!try self.vanilla.advanceFeatureWork(
            origin.x,
            origin.z,
            &region,
            &self.feature_work,
        )) return null;
        self.generation.feature_x += 1;
        if (self.generation.feature_x < self.batch_side + 2) {
            try self.initializeFeatureOrigin();
            return null;
        }
        self.refreshDirtyHeights();
        if (self.generation.feature_z >= 1) {
            self.generation.output_z = @intCast(self.generation.feature_z - 1);
            self.generation.output_x = 0;
            self.generation.stage = .encode;
        } else {
            self.beginNextFeatureRow();
        }
        return null;
    }

    fn initializeFeatureOrigin(self: *Generator) !void {
        const origin = self.featureOrigin();
        self.refreshDirtyHeights();
        self.loadFeatureHeights(origin, &self.feature_work);
        var region = self.featureRegion(origin.x, origin.z);
        self.vanilla.beginFeatureWork(
            origin.x,
            origin.z,
            &region,
            &self.feature_work,
        );
    }

    fn featureOrigin(self: *const Generator) FeatureOrigin {
        std.debug.assert(self.generation.feature_x < self.batch_side + 2);
        std.debug.assert(self.generation.feature_z >= -1);
        return .{
            .x = self.generation.batch_min_x - 1 +
                @as(i32, @intCast(self.generation.feature_x)),
            .z = self.generation.batch_min_z + self.generation.feature_z,
        };
    }

    fn finishGeneration(self: *Generator) !?ChunkShape {
        if (self.generation.output_x == self.batch_side)
            return self.finishOutputRow();
        const output_x = self.generation.output_x;
        const output_z = self.generation.output_z;
        const output = output_z * self.batch_side + output_x;
        const chunk_x = self.generation.batch_min_x + @as(i32, @intCast(output_x));
        const chunk_z = self.generation.batch_min_z + @as(i32, @intCast(output_z));
        const workspace_index = self.workspaceIndex(chunk_x, chunk_z);
        const requested = output == self.generation.requested_output;
        const shape = try self.encodeShape(
            if (requested) &self.requested_shape_storage else &self.shape_storage,
            chunk_x,
            chunk_z,
            self.workspaceStates(workspace_index),
            &self.feature_heights[workspace_index],
        );
        self.generation.output_x += 1;
        if (!requested) return shape;
        self.requested_shape = shape;
        self.generation.requested_shape_ready = true;
        return null;
    }

    fn finishOutputRow(self: *Generator) ?ChunkShape {
        if (self.generation.output_z + 1 < self.batch_side) {
            self.beginNextFeatureRow();
            return null;
        }
        std.debug.assert(self.generation.requested_shape_ready);
        const requested = self.requested_shape;
        self.generation = .{};
        return requested;
    }

    fn beginNextFeatureRow(self: *Generator) void {
        self.generation.feature_z += 1;
        self.generation.feature_x = 0;
        self.beginBaseRow(
            self.generation.batch_min_z + self.generation.feature_z + 1,
        );
    }

    pub fn generateFlat(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        surface_y: i16,
        surface_state: i32,
        underground_state: i32,
    ) !ChunkShape {
        return lightning_rod.terrain.buildFlatChunkShape(
            &self.shape_storage,
            chunk_x,
            chunk_z,
            surface_y,
            surface_state,
            underground_state,
        );
    }

    pub fn generateVoid(self: *Generator, chunk_x: i32, chunk_z: i32) !ChunkShape {
        return lightning_rod.terrain.buildVoidChunkShape(
            &self.shape_storage,
            chunk_x,
            chunk_z,
        );
    }

    fn featureRegion(
        self: *Generator,
        origin_x: i32,
        origin_z: i32,
    ) vanilla_worldgen.feature.Region {
        self.dirty_origin = .{ .x = origin_x, .z = origin_z };
        var chunks: [9][]GeneratedState = undefined;
        for (&chunks, 0..) |*chunk, index| {
            const chunk_x = origin_x + @as(i32, @intCast(index % 3)) - 1;
            const chunk_z = origin_z + @as(i32, @intCast(index / 3)) - 1;
            chunk.* = self.workspaceStates(self.workspaceIndex(chunk_x, chunk_z));
        }
        return .{
            .center_chunk_x = origin_x,
            .center_chunk_z = origin_z,
            .chunks = chunks,
            .biome_cache = &self.vanilla.biome_cache,
            .dirty_columns = &self.dirty_columns,
            .height_upper_bounds = &self.feature_work.world_surface,
            .touched_y = &self.feature_work.touched_y,
        };
    }

    fn loadFeatureHeights(
        self: *const Generator,
        origin: FeatureOrigin,
        work: *vanilla_worldgen.chunk.FeatureWork,
    ) void {
        for (0..3) |region_z| for (0..3) |region_x| {
            const workspace = self.workspaceIndex(
                origin.x + @as(i32, @intCast(region_x)) - 1,
                origin.z + @as(i32, @intCast(region_z)) - 1,
            );
            const heights = &self.feature_heights[workspace];
            for (0..16) |local_z| {
                const destination = (region_z * 16 + local_z) * 48 + region_x * 16;
                const source = local_z * 16;
                @memcpy(work.ocean_floor[destination..][0..16], heights.ocean_floor[source..][0..16]);
                @memcpy(work.world_surface[destination..][0..16], heights.world_surface[source..][0..16]);
            }
        };
    }

    fn refreshDirtyHeights(self: *Generator) void {
        for (&self.dirty_columns, 0..) |*words, region_index| {
            if (words[0] | words[1] | words[2] | words[3] == 0) continue;
            const chunk_x = self.dirty_origin.x + @as(i32, @intCast(region_index % 3)) - 1;
            const chunk_z = self.dirty_origin.z + @as(i32, @intCast(region_index / 3)) - 1;
            const workspace = self.workspaceIndex(chunk_x, chunk_z);
            for (words, 0..) |*word, word_index| while (word.* != 0) {
                const bit: usize = @intCast(@ctz(word.*));
                word.* &= word.* - 1;
                const column = word_index * 64 + bit;
                const heights = vanilla_worldgen.chunk.columnHeights(
                    self.workspaceStates(workspace),
                    column & 15,
                    column >> 4,
                );
                self.feature_heights[workspace].ocean_floor[column] = heights.ocean_floor;
                self.feature_heights[workspace].world_surface[column] = heights.world_surface;
            };
        }
    }

    fn workspaceIndex(self: *const Generator, chunk_x: i32, chunk_z: i32) usize {
        const x = chunk_x - (self.generation.batch_min_x - 2);
        std.debug.assert(x >= 0 and x < self.workspace_side);
        const slot: usize = @intCast(@mod(chunk_z, workspace_rows));
        std.debug.assert(self.workspace_z[slot] == chunk_z);
        return slot * self.workspace_side + @as(usize, @intCast(x));
    }

    fn encodeShape(
        self: *Generator,
        storage: []u8,
        chunk_x: i32,
        chunk_z: i32,
        states: []const GeneratedState,
        heights: *const ChunkHeights,
    ) !ChunkShape {
        var shape: ChunkShape = .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .heights = undefined,
            .grass_spread_possible = true,
            .storage = storage,
        };
        for (&shape.heights, heights.world_surface) |*height, world_surface|
            height.* = world_surface - 1;
        @memcpy(
            &shape.biomes,
            self.vanilla.biome_cache.chunk(
                self.vanilla.climate_sampler,
                chunk_x,
                chunk_z,
            ),
        );
        for (0..limits.section_count) |section| {
            const first = section * blocks_per_section;
            try self.encodeGeneratedSection(
                &shape,
                section,
                states[first..][0..blocks_per_section],
            );
        }
        return shape;
    }

    fn encodeGeneratedSection(
        self: *const Generator,
        shape: *ChunkShape,
        section: usize,
        states: *const [blocks_per_section]GeneratedState,
    ) !void {
        const generated_count = comptime vanilla_worldgen.generated_state.stateCount();
        var palette_by_generated =
            [_]u16{std.math.maxInt(u16)} ** generated_count;
        var palette: [256]i32 = undefined;
        var indices: [blocks_per_section]u8 = undefined;
        var palette_count: usize = 0;
        var all_transparent = true;
        var all_opaque = true;
        for (states, 0..) |state, block_index| {
            const generated_index = @intFromEnum(state);
            var palette_index = palette_by_generated[generated_index];
            if (palette_index == std.math.maxInt(u16)) {
                if (palette_count == palette.len)
                    return error.GeneratedSectionPaletteCapacity;
                palette_index = @intCast(palette_count);
                palette_by_generated[generated_index] = palette_index;
                palette[palette_count] = self.state_ids[generated_index];
                palette_count += 1;
            }
            indices[block_index] = @intCast(palette_index);
            const info = game_data.blockInfo(self.state_ids[generated_index]);
            all_transparent = all_transparent and info.visually_transparent;
            all_opaque = all_opaque and
                !info.visually_transparent and info.filtered_light >= 15;
        }
        try shape.writeSection(
            section,
            palette[0..palette_count],
            &indices,
            if (all_transparent)
                .transparent
            else if (all_opaque)
                .solid
            else
                .mixed,
        );
    }

    fn baseChunkPosition(self: *const Generator) FeatureOrigin {
        std.debug.assert(self.generation.base_x < self.workspace_side);
        return .{
            .x = self.generation.batch_min_x - 2 +
                @as(i32, @intCast(self.generation.base_x)),
            .z = self.generation.base_z,
        };
    }

    fn workspaceStates(self: *Generator, index: usize) []GeneratedState {
        std.debug.assert(index < self.workspace_side * workspace_rows);
        const first = index * vanilla_worldgen.chunk.block_count;
        return self.feature_workspace_storage[first .. first + vanilla_worldgen.chunk.block_count];
    }

    fn findCachedBaseChunk(
        self: *const Generator,
        position: FeatureOrigin,
    ) ?usize {
        for (self.base_cache, 0..) |entry, index| {
            if (entry.valid and entry.chunk_x == position.x and
                entry.chunk_z == position.z)
                return index;
        }
        return null;
    }

    fn cacheBaseChunk(
        self: *Generator,
        workspace_index: usize,
        position: FeatureOrigin,
    ) !void {
        const cache_index = self.replacementBaseCacheIndex();
        const entry = &self.base_cache[cache_index];
        entry.* = .{
            .valid = true,
            .chunk_x = position.x,
            .chunk_z = position.z,
            .heights = self.feature_heights[workspace_index],
        };
        const storage = self.baseCacheStorage(cache_index);
        for (0..limits.section_count) |section|
            try self.encodeCachedBaseSection(
                entry,
                storage,
                section,
                self.workspaceStates(workspace_index),
            );
        self.base_cache_stamp += 1;
        entry.stamp = self.base_cache_stamp;
    }

    fn replacementBaseCacheIndex(self: *const Generator) usize {
        var oldest_index: usize = 0;
        var oldest_stamp = self.base_cache[0].stamp;
        for (self.base_cache, 0..) |entry, index| {
            if (!entry.valid) return index;
            if (entry.stamp < oldest_stamp) {
                oldest_index = index;
                oldest_stamp = entry.stamp;
            }
        }
        return oldest_index;
    }

    fn baseCacheStorage(self: *Generator, cache_index: usize) []u8 {
        std.debug.assert(cache_index < self.base_cache.len);
        const first = cache_index * base_cache_chunk_capacity;
        return self.base_cache_storage[first .. first + base_cache_chunk_capacity];
    }

    fn encodeCachedBaseSection(
        self: *Generator,
        entry: *CachedBaseChunk,
        storage: []u8,
        section: usize,
        states: []const GeneratedState,
    ) !void {
        var codes: [blocks_per_section]u16 = undefined;
        for (&codes, 0..) |*code, local_index| {
            const x: i32 = @intCast(local_index & 15);
            const z: i32 = @intCast((local_index >> 4) & 15);
            const y = @as(i32, limits.min_y) +
                @as(i32, @intCast(section * 16 + (local_index >> 8)));
            code.* = generatedStateCode(states[
                vanilla_worldgen.chunk.blockIndex(x, y, z)
            ]);
        }
        try encodeCachedCodes(entry, storage, section, &codes);
        _ = self;
    }

    fn decodeCachedBaseChunk(
        self: *Generator,
        cache_index: usize,
        workspace_index: usize,
    ) void {
        const entry = &self.base_cache[cache_index];
        const storage = self.baseCacheStorage(cache_index);
        const states = self.workspaceStates(workspace_index);
        for (0..limits.section_count) |section| {
            for (0..blocks_per_section) |local_index| {
                const x: i32 = @intCast(local_index & 15);
                const z: i32 = @intCast((local_index >> 4) & 15);
                const y = @as(i32, limits.min_y) +
                    @as(i32, @intCast(section * 16 + (local_index >> 8)));
                states[vanilla_worldgen.chunk.blockIndex(x, y, z)] =
                    generatedStateFromCode(cachedCode(entry, storage, section, local_index));
            }
        }
        self.feature_heights[workspace_index] = entry.heights;
    }

    fn stateId(
        self: *const Generator,
        generated: vanilla_worldgen.generated_state.GeneratedState,
    ) i32 {
        return self.state_ids[@intFromEnum(generated)];
    }
};

fn encodeCachedCodes(
    entry: *Generator.CachedBaseChunk,
    storage: []u8,
    section: usize,
    codes: *const [blocks_per_section]u16,
) !void {
    const generated_state_count: usize = comptime 4 +
        vanilla_worldgen.surface.stateCount() +
        vanilla_worldgen.generated_state.featureStateCount();
    var palette: [256]u16 = undefined;
    var palette_by_code = [_]u16{std.math.maxInt(u16)} ** generated_state_count;
    var indices: [blocks_per_section]u8 = undefined;
    var palette_count: usize = 0;
    for (codes, 0..) |code, index| {
        std.debug.assert(code < palette_by_code.len);
        var palette_index = palette_by_code[code];
        if (palette_index == std.math.maxInt(u16)) {
            if (palette_count == palette.len) return error.GeneratedSectionPaletteCapacity;
            palette[palette_count] = code;
            palette_index = @intCast(palette_count);
            palette_by_code[code] = palette_index;
            palette_count += 1;
        }
        indices[index] = @intCast(palette_index);
    }
    try writeCachedSection(entry, storage, section, palette[0..palette_count], &indices);
}

fn writeCachedSection(
    entry: *Generator.CachedBaseChunk,
    storage: []u8,
    section: usize,
    palette: []const u16,
    indices: *const [blocks_per_section]u8,
) !void {
    const bits: u4 = if (palette.len <= 1)
        0
    else
        @intCast(std.math.log2_int_ceil(usize, palette.len));
    const palette_bytes = palette.len * @sizeOf(u16);
    const data_bytes = (@as(usize, bits) * blocks_per_section + 7) / 8;
    const required = @as(usize, entry.storage_len) + palette_bytes + data_bytes;
    if (required > storage.len) return error.GeneratedChunkStorageCapacity;
    entry.sections[section] = .{
        .palette_offset = entry.storage_len,
        .data_offset = entry.storage_len + @as(u32, @intCast(palette_bytes)),
        .palette_count = @intCast(palette.len),
        .bits_per_block = bits,
    };
    var cursor: usize = entry.storage_len;
    for (palette) |code| {
        std.mem.writeInt(u16, storage[cursor..][0..2], code, .little);
        cursor += 2;
    }
    @memset(storage[cursor..][0..data_bytes], 0);
    if (bits != 0) packCachedIndices(storage[cursor..][0..data_bytes], indices, bits);
    entry.storage_len = @intCast(required);
}

fn packCachedIndices(
    storage: []u8,
    indices: *const [blocks_per_section]u8,
    bits: u4,
) void {
    switch (bits) {
        1 => packCachedIndices1(storage, indices),
        2 => packCachedIndices2(storage, indices),
        4 => packCachedIndices4(storage, indices),
        8 => @memcpy(storage, indices),
        else => packCachedIndicesGeneric(storage, indices, bits),
    }
}

fn packCachedIndices1(storage: []u8, indices: *const [blocks_per_section]u8) void {
    std.debug.assert(storage.len == blocks_per_section / 8);
    for (storage, 0..) |*byte, index| {
        const first = index * 8;
        byte.* = indices[first] |
            indices[first + 1] << 1 |
            indices[first + 2] << 2 |
            indices[first + 3] << 3 |
            indices[first + 4] << 4 |
            indices[first + 5] << 5 |
            indices[first + 6] << 6 |
            indices[first + 7] << 7;
    }
}

fn packCachedIndices2(storage: []u8, indices: *const [blocks_per_section]u8) void {
    std.debug.assert(storage.len == blocks_per_section / 4);
    for (storage, 0..) |*byte, index| {
        const first = index * 4;
        byte.* = indices[first] |
            indices[first + 1] << 2 |
            indices[first + 2] << 4 |
            indices[first + 3] << 6;
    }
}

fn packCachedIndices4(storage: []u8, indices: *const [blocks_per_section]u8) void {
    std.debug.assert(storage.len == blocks_per_section / 2);
    for (storage, 0..) |*byte, index| {
        const first = index * 2;
        byte.* = indices[first] | indices[first + 1] << 4;
    }
}

fn packCachedIndicesGeneric(
    storage: []u8,
    indices: *const [blocks_per_section]u8,
    bits: u4,
) void {
    for (indices, 0..) |palette_index, block_index| {
        const bit_offset = block_index * @as(usize, bits);
        const byte_offset = bit_offset / 8;
        const shift: u4 = @intCast(bit_offset & 7);
        const encoded = @as(u16, palette_index) << shift;
        storage[byte_offset] |= @truncate(encoded);
        if (shift + bits > 8) storage[byte_offset + 1] |= @truncate(encoded >> 8);
    }
}

fn cachedCode(
    entry: *const Generator.CachedBaseChunk,
    storage: []const u8,
    section: usize,
    local_index: usize,
) u16 {
    const descriptor = entry.sections[section];
    var palette_index: u16 = 0;
    if (descriptor.bits_per_block != 0) {
        const bit_offset = local_index * @as(usize, descriptor.bits_per_block);
        const byte_offset = @as(usize, descriptor.data_offset) + bit_offset / 8;
        const shift: u4 = @intCast(bit_offset & 7);
        var encoded: u16 = storage[byte_offset];
        if (shift + descriptor.bits_per_block > 8)
            encoded |= @as(u16, storage[byte_offset + 1]) << 8;
        const mask: u16 = (@as(u16, 1) << descriptor.bits_per_block) - 1;
        palette_index = (encoded >> shift) & mask;
    }
    std.debug.assert(palette_index < descriptor.palette_count);
    const offset = @as(usize, descriptor.palette_offset) + palette_index * 2;
    return std.mem.readInt(u16, storage[offset..][0..2], .little);
}

fn generatedStateCode(state: Generator.GeneratedState) u16 {
    return @intFromEnum(state);
}

fn generatedStateFromCode(code: u16) Generator.GeneratedState {
    const state: Generator.GeneratedState = @enumFromInt(code);
    _ = state.kind();
    return state;
}

test "neighbor feature origins survive chunk encoding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator = try Generator.init(
        arena.allocator(),
        0x6d62_756e_6400_0001,
        4,
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
        chunk.* = storage[index * block_count .. (index + 1) * block_count];
        var heights: [16 * 16]i32 = undefined;
        @memset(&heights, vanilla_worldgen.chunk.minimum_y);
        generator.vanilla.prepareBaseMaterials(chunk_x, chunk_z);
        var base_complete = false;
        for (0..512) |_| {
            if (generator.vanilla.advanceBaseStates(chunk.*, &heights)) {
                base_complete = true;
                break;
            }
        }
        try std.testing.expect(base_complete);
        try generator.finishBaseChunk(chunk_x, chunk_z, chunk.*, &heights);
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
                lightning_rod.terrain.blockAtFromShape(
                    &actual,
                    16 + @as(i32, @intCast(local_x)),
                    @intCast(y),
                    @intCast(local_z),
                ),
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

pub fn biomeNames() []const []const u8 {
    return registry.biome_names;
}

pub fn buildDimensionChunkShape(
    comptime Dimension: type,
    generator: *Dimension.Generator,
    storage: []u8,
    states: []const Dimension.Generator.BlockType,
    state_ids: []const i32,
    biome_ids: []const u8,
    chunk_x: i32,
    chunk_z: i32,
) !ChunkShape {
    std.debug.assert(states.len == Dimension.block_count);
    std.debug.assert(state_ids.len == Dimension.state_count);
    var shape: ChunkShape = .{
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
        .heights = [_]i16{limits.min_y - 1} ** (16 * 16),
        .storage = storage,
    };
    var section_blocks: [blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
        const bottom = @as(i32, limits.min_y) + @as(i32, @intCast(section * 16));
        if (bottom + 15 < Dimension.minimum_y or bottom >= Dimension.minimum_y + Dimension.height) {
            try shape.encodeUniformSection(section, registry.block_air_default_state);
            continue;
        }
        for (&section_blocks, 0..) |*block_state, local_index| {
            const x = local_index & 15;
            const z = (local_index >> 4) & 15;
            const y = bottom + @as(i32, @intCast(local_index >> 8));
            if (y < Dimension.minimum_y or y >= Dimension.minimum_y + Dimension.height) {
                block_state.* = registry.block_air_default_state;
                continue;
            }
            const block = states[Dimension.blockIndex(x, @intCast(y - Dimension.minimum_y), z)];
            block_state.* = switch (block) {
                .feature => |state| @intCast(state.id),
                else => state_ids[Dimension.stateCode(block)],
            };
            if (!isAirName(Dimension.canonicalName(block))) {
                const column = z * 16 + x;
                shape.heights[column] = @max(shape.heights[column], @as(i16, @intCast(y)));
            }
        }
        try shape.encodeSection(section, &section_blocks);
    }
    fillDimensionBiomes(Dimension, generator, biome_ids, chunk_x, chunk_z, &shape.biomes);
    return shape;
}

fn fillDimensionBiomes(
    comptime Dimension: type,
    generator: *Dimension.Generator,
    biome_ids: []const u8,
    chunk_x: i32,
    chunk_z: i32,
    output: *[biome_cells_per_chunk]u8,
) void {
    const first_quart_x = chunk_x * 4;
    const first_quart_z = chunk_z * 4;
    const first_quart_y = @divFloor(@as(i32, limits.min_y), 4);
    for (0..limits.section_count) |section| for (0..4) |local_y| {
        const quart_y = first_quart_y + @as(i32, @intCast(section * 4 + local_y));
        for (0..4) |local_z| for (0..4) |local_x| {
            const biome = generator.biomeAtQuart(
                first_quart_x + @as(i32, @intCast(local_x)),
                quart_y,
                first_quart_z + @as(i32, @intCast(local_z)),
            );
            output[
                section * biome_cells_per_section +
                    local_x + local_z * 4 + local_y * 16
            ] = biome_ids[@intFromEnum(biome)];
        };
    };
}

fn isAirName(name: []const u8) bool {
    return std.mem.eql(u8, name, "minecraft:air") or
        std.mem.eql(u8, name, "minecraft:cave_air") or
        std.mem.eql(u8, name, "minecraft:void_air");
}

pub fn biomeId(name: []const u8) ?u8 {
    return registry.biomeId(name);
}
