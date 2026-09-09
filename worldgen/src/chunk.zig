const std = @import("std");
const preallocated = @import("preallocated");
const aquifer = @import("aquifer.zig");
const biome = @import("biome.zig");
const biome_access = @import("biome_access.zig");
const carver = @import("carver.zig");
const climate = @import("climate.zig");
const density = @import("density.zig");
const feature = @import("feature.zig");
const feature_data = @import("feature_data");
const generated_state = @import("generated_state.zig");
const random = @import("random.zig");
const surface = @import("surface.zig");
const stronghold = @import("stronghold.zig");

pub const width = 16;
pub const minimum_y = density.ChunkInterpolator.minimum_y;
pub const height = density.ChunkInterpolator.height;
pub const block_count = width * width * height;

const GeneratedState = generated_state.GeneratedState;

pub const LocalPosition = struct {
    x: u4,
    y: i16,
    z: u4,
};

pub const View = struct {
    states: []const GeneratedState,

    pub fn init(states: []const GeneratedState) View {
        std.debug.assert(states.len == block_count);
        return .{ .states = states };
    }

    pub inline fn at(self: View, position: LocalPosition) GeneratedState {
        return self.states[blockIndex(position.x, position.y, position.z)];
    }
};

pub const Generator = struct {
    allocator: std.mem.Allocator,
    world_seed: u64,
    router: *density.Router,
    climate_sampler: *climate.Sampler,
    surface_sampler: *surface.Sampler,
    surface_biome_masks: [biome.names().len]u32,
    ore_splitter: random.Splitter,
    biome_cache: biome.Cache = .{},
    stronghold_locator: stronghold.Locator = .{},
    feature_biomes: feature.BiomePlanner = .{},
    surface_biome_access: biome_access.ChunkCache = undefined,
    base_scratch: BaseWork,
    ore_interpolation: density.ChunkInterpolator,
    carver_scratch: carver.Scratch,
    feature_material_scratch: []aquifer.Material,
    feature_region_scratch: []GeneratedState,

    pub fn init(allocator: std.mem.Allocator, world_seed: u64) !Generator {
        var result: Generator = undefined;
        try result.initWithFeatureScratch(allocator, world_seed, true);
        return result;
    }

    pub fn initForRegion(allocator: std.mem.Allocator, world_seed: u64) !Generator {
        var result: Generator = undefined;
        try result.initWithFeatureScratch(allocator, world_seed, false);
        return result;
    }

    pub fn initForRegionInto(self: *Generator, allocator: std.mem.Allocator, world_seed: u64) !void {
        try self.initWithFeatureScratch(allocator, world_seed, false);
    }

    fn initWithFeatureScratch(
        self: *Generator,
        allocator: std.mem.Allocator,
        world_seed: u64,
        allocate_feature_scratch: bool,
    ) !void {
        const router = try preallocated.create(density.Router, allocator);
        errdefer allocator.destroy(router);
        router.* = try density.Router.init(allocator, world_seed);
        errdefer router.deinit();
        const climate_sampler = try preallocated.create(climate.Sampler, allocator);
        errdefer allocator.destroy(climate_sampler);
        climate_sampler.* = climate.Sampler.init(world_seed);
        const surface_sampler = try preallocated.create(surface.Sampler, allocator);
        errdefer allocator.destroy(surface_sampler);
        surface_sampler.* = try surface.Sampler.init(allocator, world_seed);
        errdefer surface_sampler.deinit();
        var base_scratch = try BaseWork.initWithRouter(allocator, router, world_seed);
        errdefer base_scratch.deinit();
        var ore_interpolation = try density.ChunkInterpolator.initVeins(
            allocator,
            router,
            1024,
        );
        errdefer ore_interpolation.deinit();
        var carver_scratch = try carver.Scratch.init(allocator, router, world_seed);
        errdefer carver_scratch.deinit();
        const feature_material_scratch = if (allocate_feature_scratch)
            try preallocated.alloc(aquifer.Material, allocator, block_count)
        else
            @constCast(&[_]aquifer.Material{});
        errdefer if (feature_material_scratch.len != 0)
            allocator.free(feature_material_scratch);
        const feature_region_scratch = if (allocate_feature_scratch)
            try preallocated.alloc(GeneratedState, allocator, block_count * 8)
        else
            @constCast(&[_]GeneratedState{});
        errdefer if (feature_region_scratch.len != 0)
            allocator.free(feature_region_scratch);
        var base_random = random.Xoroshiro.init(world_seed);
        const base_splitter = base_random.splitter();
        var ore_random = base_splitter.splitString("minecraft:ore");
        var surface_biome_masks: [biome.names().len]u32 = undefined;
        for (biome.names(), &surface_biome_masks) |name, *mask|
            mask.* = surface.biomeMask(name);
        self.* = .{
            .allocator = allocator,
            .world_seed = world_seed,
            .router = router,
            .climate_sampler = climate_sampler,
            .surface_sampler = surface_sampler,
            .surface_biome_masks = surface_biome_masks,
            .ore_splitter = ore_random.splitter(),
            .base_scratch = base_scratch,
            .ore_interpolation = ore_interpolation,
            .carver_scratch = carver_scratch,
            .feature_material_scratch = feature_material_scratch,
            .feature_region_scratch = feature_region_scratch,
        };
    }

    pub fn deinit(self: *Generator) void {
        if (self.feature_region_scratch.len != 0)
            self.allocator.free(self.feature_region_scratch);
        if (self.feature_material_scratch.len != 0)
            self.allocator.free(self.feature_material_scratch);
        self.carver_scratch.deinit();
        self.ore_interpolation.deinit();
        self.base_scratch.deinit();
        self.surface_sampler.deinit();
        self.allocator.destroy(self.surface_sampler);
        self.allocator.destroy(self.climate_sampler);
        self.router.deinit();
        self.allocator.destroy(self.router);
        self.* = undefined;
    }

    pub fn reseed(self: *Generator, world_seed: u64) !void {
        if (self.world_seed == world_seed) return;
        try self.router.reseed(world_seed);
        self.climate_sampler.* = climate.Sampler.init(world_seed);
        self.surface_sampler.reseed(world_seed);
        self.base_scratch.interpolation.reseed(self.router);
        self.base_scratch.fluids.reseed(self.router, world_seed);
        self.ore_interpolation.reseed(self.router);
        self.carver_scratch.fluids.reseed(self.router, world_seed);
        var base = random.Xoroshiro.init(world_seed);
        var ore_random = base.splitter().splitString("minecraft:ore");
        self.ore_splitter = ore_random.splitter();
        self.biome_cache = .{};
        self.stronghold_locator.invalidate();
        self.feature_biomes.clear();
        self.world_seed = world_seed;
    }

    pub fn fillBaseMaterials(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []aquifer.Material,
    ) !void {
        if (output.len != block_count) return error.InvalidChunkOutputSize;
        self.prepareBaseMaterials(chunk_x, chunk_z);
        while (!self.advanceBaseMaterials(output)) {}
    }

    pub fn strongholdStarts(self: *Generator) *const [stronghold.Locator.count]stronghold.ChunkPos {
        self.stronghold_locator.prepare(self.world_seed, self.climate_sampler, &self.biome_cache);
        return &self.stronghold_locator.positions;
    }

    pub fn beginBaseMaterials(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
    ) !BaseWork {
        return BaseWork.init(self, chunk_x, chunk_z);
    }

    pub fn prepareBaseMaterials(self: *Generator, chunk_x: i32, chunk_z: i32) void {
        self.base_scratch.prepare(chunk_x, chunk_z);
    }

    pub fn advanceBaseMaterials(self: *Generator, output: []aquifer.Material) bool {
        return self.base_scratch.advance(output);
    }

    pub fn advanceBaseStates(
        self: *Generator,
        output: []GeneratedState,
        top_heights: *[width * width]i32,
    ) bool {
        return self.base_scratch.advanceStates(output, top_heights);
    }

    fn applyOreVeins(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []GeneratedState,
    ) !void {
        self.ore_interpolation.prepare(chunk_x, chunk_z);
        const first_x = chunk_x * width;
        const first_z = chunk_z * width;
        const first_cell_y: usize = @intCast(@divFloor(-60 - minimum_y, density.ChunkInterpolator.vertical_cell_size));
        const last_cell_y: usize = @intCast(@divFloor(50 - minimum_y, density.ChunkInterpolator.vertical_cell_size));
        var eligible: [last_cell_y - first_cell_y + 1][density.ChunkInterpolator.horizontal_cells][density.ChunkInterpolator.horizontal_cells]bool = undefined;
        for (&eligible, first_cell_y..) |*cell_layer, cell_y| {
            for (cell_layer, 0..) |*cell_row, cell_x| {
                for (cell_row, 0..) |*may_generate, cell_z|
                    may_generate.* = self.ore_interpolation.cellMayContainVein(cell_x, cell_y, cell_z);
            }
        }
        var y: i32 = -60;
        while (y <= 50) : (y += 1) {
            const cell_y: usize = @intCast(@divFloor(
                y - minimum_y,
                density.ChunkInterpolator.vertical_cell_size,
            ));
            for (0..width) |local_x| {
                const x = first_x + @as(i32, @intCast(local_x));
                var local_z: usize = 0;
                while (local_z < width) : (local_z += density.sample_lanes) {
                    const cell_x = local_x / density.ChunkInterpolator.horizontal_cell_size;
                    const cell_z = local_z / density.ChunkInterpolator.horizontal_cell_size;
                    if (!eligible[cell_y - first_cell_y][cell_x][cell_z]) continue;
                    self.applyOreVeinBatch(x, y, local_x, local_z, first_z, output);
                }
            }
        }
    }

    fn applyOreVeinBatch(self: *Generator, x: i32, y: i32, local_x: usize, first_local_z: usize, first_z: i32, output: []GeneratedState) void {
        var positions: [density.sample_lanes]density.Position = undefined;
        inline for (0..density.sample_lanes) |lane| positions[lane] = .{
            .x = x,
            .y = y,
            .z = first_z + @as(i32, @intCast(first_local_z + lane)),
        };
        const toggles: [density.sample_lanes]f64 = self.ore_interpolation.sampleVeinToggle4(positions);
        var sources: [density.sample_lanes]random.Xoroshiro = undefined;
        var candidates = [_]bool{false} ** density.sample_lanes;
        var any_candidate = false;
        for (0..density.sample_lanes) |lane| {
            const toggle = toggles[lane];
            const copper = toggle > 0;
            const minimum: i32 = if (copper) 0 else -60;
            const maximum: i32 = if (copper) 50 else -8;
            const distance_to_edge = @min(maximum - y, y - minimum);
            if (distance_to_edge < 0) continue;
            const edge_reduction = clampedMap(@floatFromInt(distance_to_edge), 0, 20, -0.2, 0);
            const magnitude = @abs(toggle);
            if (magnitude + edge_reduction < @as(f32, 0.4)) continue;
            sources[lane] = self.ore_splitter.splitPosition(x, y, positions[lane].z);
            if (sources[lane].nextF32() > 0.7) continue;
            candidates[lane] = true;
            any_candidate = true;
        }
        if (!any_candidate) return;
        const ridged: [density.sample_lanes]f64 = self.ore_interpolation.sampleVeinRidged4(positions);
        var rich = [_]bool{false} ** density.sample_lanes;
        var any_rich = false;
        for (0..density.sample_lanes) |lane| {
            if (!candidates[lane] or ridged[lane] >= 0) {
                candidates[lane] = false;
                continue;
            }
            const magnitude = @abs(toggles[lane]);
            const ore_chance = clampedMap(magnitude, @as(f32, 0.4), @as(f32, 0.6), @as(f32, 0.1), @as(f32, 0.3));
            rich[lane] = sources[lane].nextF32() < ore_chance;
            any_rich = any_rich or rich[lane];
        }
        const gaps: [density.sample_lanes]f64 = if (any_rich)
            self.ore_interpolation.sampleVeinGap4(positions)
        else
            @splat(0);
        for (0..density.sample_lanes) |lane| {
            if (!candidates[lane]) continue;
            const local_z = first_local_z + lane;
            const index = blockIndex(@intCast(local_x), y, @intCast(local_z));
            const copper = toggles[lane] > 0;
            const state = oreVeinState(copper, rich[lane] and gaps[lane] > -0.3, &sources[lane]);
            output[index] = GeneratedState.fromFeature(state);
        }
    }

    pub fn applySurface(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        base: []const aquifer.Material,
        output: []GeneratedState,
    ) !void {
        var top_heights: [width * width]i32 = undefined;
        var biome_halo: BiomeHalo = undefined;
        const preliminary_corners = density.preliminarySurfaceCorners(
            self.router,
            chunk_x,
            chunk_z,
        );
        try initializeSurface(base, output, &top_heights);
        self.prepareSurfaceBiomeHalo(chunk_x, chunk_z, &biome_halo);
        try self.applySurfaceColumns(
            chunk_x,
            chunk_z,
            output,
            &top_heights,
            &biome_halo,
            &preliminary_corners,
            0,
            width,
        );
        try self.finishSurface(chunk_x, chunk_z, output);
    }

    pub fn initializeSurface(
        base: []const aquifer.Material,
        output: []GeneratedState,
        top_heights: *[width * width]i32,
    ) !void {
        if (base.len != block_count or output.len != block_count)
            return error.InvalidChunkOutputSize;
        for (base, output) |material, *state| state.* = GeneratedState.fromBase(material);
        for (0..width) |local_z| {
            for (0..width) |local_x| {
                var y: i32 = minimum_y + height;
                while (y > minimum_y) {
                    y -= 1;
                    if (base[blockIndex(@intCast(local_x), y, @intCast(local_z))] != .air) break;
                }
                top_heights[local_z * width + local_x] = y + 1;
            }
        }
    }

    pub fn applySurfaceColumns(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []GeneratedState,
        top_heights: *[width * width]i32,
        biome_halo: *const BiomeHalo,
        preliminary_corners: *const [4]i32,
        first_local_x: usize,
        local_x_count: usize,
    ) !void {
        if (output.len != block_count or first_local_x > width or
            local_x_count > width - first_local_x)
            return error.InvalidChunkOutputSize;
        const first_x = chunk_x * width;
        const first_z = chunk_z * width;
        const mixer_seed = biome_access.mixerSeed(self.world_seed);
        if (first_local_x == 0)
            self.surface_biome_access.prepare(mixer_seed, chunk_x, chunk_z);
        for (first_local_x..first_local_x + local_x_count) |local_x| {
            var local_z: usize = 0;
            while (local_z < width) : (local_z += density.sample_lanes) {
                const depths = self.surface_sampler.columnDepths4(
                    first_x + @as(i32, @intCast(local_x)),
                    first_z + @as(i32, @intCast(local_z)),
                );
                inline for (0..density.sample_lanes) |lane| {
                    var column = self.prepareSurfaceColumn(
                        first_x,
                        first_z,
                        local_x,
                        local_z + lane,
                        depths.run[lane],
                        depths.surface_noise[lane],
                        depths.secondary[lane],
                        output,
                        top_heights,
                        biome_halo,
                        preliminary_corners,
                    );
                    self.applySurfaceColumn(&column, output, biome_halo, top_heights);
                    if (frozenOceanBiome(column.surface_biome_index))
                        self.applyFrozenOceanColumn(&column, output);
                }
            }
        }
    }

    fn prepareSurfaceColumn(self: *Generator, first_x: i32, first_z: i32, local_x: usize, local_z: usize, run_depth: i32, surface_noise: f64, secondary_depth: f64, output: []GeneratedState, top_heights: *[width * width]i32, biome_halo: *const BiomeHalo, preliminary_corners: *const [4]i32) SurfaceColumn {
        var column = SurfaceColumn.init(self, first_x, first_z, local_x, local_z, run_depth, surface_noise, secondary_depth, top_heights, biome_halo, preliminary_corners);
        if (std.mem.eql(u8, biome.name(column.surface_biome_index), "minecraft:eroded_badlands")) {
            if (self.surface_sampler.badlandsPillarHeight(column.x, column.z, column.initial_top)) |target| {
                if (placeBadlandsPillar(output, local_x, local_z, target))
                    top_heights[column.height_index] = target + 1;
            }
        }
        column.steep = columnIsSteep(top_heights, local_x, local_z);
        column.fillStoneDepth(output);
        return column;
    }

    fn applySurfaceColumn(self: *Generator, column: *const SurfaceColumn, output: []GeneratedState, biome_halo: *const BiomeHalo, top_heights: *const [width * width]i32) void {
        var stone_depth_above: i32 = 0;
        var fluid_height: i32 = std.math.minInt(i32);
        var y = top_heights[column.height_index];
        while (y > minimum_y) {
            y -= 1;
            const index = blockIndex(@intCast(column.local_x), y, @intCast(column.local_z));
            const material = generatedMaterial(output[index]);
            if (material == .air) {
                stone_depth_above = 0;
                fluid_height = std.math.minInt(i32);
                continue;
            }
            if (material == .water or material == .lava) {
                if (fluid_height == std.math.minInt(i32)) fluid_height = y + 1;
                continue;
            }
            stone_depth_above += 1;
            const context = self.surfaceContext(column, biome_halo, y, fluid_height, stone_depth_above);
            if (self.surface_sampler.apply(&context)) |replacement| switch (replacement) {
                .state => |state| output[index] = GeneratedState.fromSurface(state),
                .badlands => output[index] = GeneratedState.fromSurface(self.surface_sampler.terracottaBlock(column.x, y, column.z)),
            };
        }
    }

    fn surfaceContext(self: *Generator, column: *const SurfaceColumn, biome_halo: *const BiomeHalo, y: i32, fluid_height: i32, stone_depth_above: i32) surface.Context {
        const position = density.Position{ .x = column.x, .y = y, .z = column.z };
        var biome_mask: u32 = undefined;
        var temperature: f32 = undefined;
        var frozen: bool = undefined;
        if (y >= column.preliminary_surface) {
            const biome_index = biome_halo.at(self.surface_biome_access.quartPosition(position));
            const biome_climate = biome.climateFor(biome_index);
            biome_mask = self.surface_biome_masks[biome_index];
            temperature = biome_climate.temperature;
            frozen = biome_climate.frozen;
        }
        return .{
            .position = position,
            .biome_mask = biome_mask,
            .run_depth = column.run_depth,
            .surface_noise = column.surface_noise,
            .secondary_depth = column.secondary_depth,
            .fluid_height = fluid_height,
            .stone_depth_above = stone_depth_above,
            .stone_depth_below = column.below[@intCast(y - minimum_y)],
            .preliminary_surface = column.preliminary_surface,
            .temperature = temperature,
            .frozen = frozen,
            .steep = column.steep,
        };
    }

    fn applyFrozenOceanColumn(self: *Generator, column: *const SurfaceColumn, output: []GeneratedState) void {
        const surface_climate = biome.climateFor(column.surface_biome_index);
        const lower_surface = self.surface_sampler.lowerFrozenOceanSurface(surface_climate.temperature, surface_climate.frozen, column.x, column.z);
        var iceberg = self.surface_sampler.iceberg(column.x, column.z, lower_surface) orelse return;
        var snow_count: i32 = 0;
        var y = @max(column.initial_top, @as(i32, @intFromFloat(iceberg.upper)) + 1);
        while (y >= column.preliminary_surface) : (y -= 1) {
            const index = blockIndex(@intCast(column.local_x), y, @intCast(column.local_z));
            const state = output[index];
            const replace = if (isAir(state) and y < @as(i32, @intFromFloat(iceberg.upper)))
                iceberg.source.nextF64() > 0.01
            else if (isWater(state) and y > @as(i32, @intFromFloat(iceberg.lower)) and y < 63 and iceberg.lower != 0)
                iceberg.source.nextF64() > 0.15
            else
                false;
            if (!replace) continue;
            output[index] = GeneratedState.fromSurface(
                if (snow_count <= iceberg.snow_limit and y > iceberg.snow_height)
                    surface.Sampler.snowBlockState()
                else
                    surface.Sampler.packedIceState(),
            );
            snow_count += @intFromBool(snow_count <= iceberg.snow_limit and y > iceberg.snow_height);
        }
    }

    pub fn prepareSurfaceBiomeHalo(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: *BiomeHalo,
    ) void {
        output.fill(&self.biome_cache, self.climate_sampler, chunk_x, chunk_z);
    }

    pub fn finishSurface(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []GeneratedState,
    ) !void {
        if (output.len != block_count) return error.InvalidChunkOutputSize;
        try self.applyOreVeins(chunk_x, chunk_z, output);
    }

    pub fn applyCarvers(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []GeneratedState,
    ) !void {
        carver.applyWithScratch(
            &self.carver_scratch,
            self.world_seed,
            chunk_x,
            chunk_z,
            output,
        );
    }

    pub fn applyFeatures(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        output: []GeneratedState,
    ) !void {
        if (output.len != block_count) return error.InvalidChunkOutputSize;
        if (self.feature_material_scratch.len == 0 or self.feature_region_scratch.len == 0)
            return error.FeatureScratchUnavailable;
        var chunks: [9][]GeneratedState = undefined;
        var neighbor_index: usize = 0;
        for (0..3) |halo_z| {
            for (0..3) |halo_x| {
                const neighbor_x = chunk_x + @as(i32, @intCast(halo_x)) - 1;
                const neighbor_z = chunk_z + @as(i32, @intCast(halo_z)) - 1;
                const states = if (neighbor_x == chunk_x and neighbor_z == chunk_z)
                    output
                else blk: {
                    const first = neighbor_index * block_count;
                    const scratch = self.feature_region_scratch[first .. first + block_count];
                    neighbor_index += 1;
                    try self.fillBaseMaterials(neighbor_x, neighbor_z, self.feature_material_scratch);
                    try self.applySurface(neighbor_x, neighbor_z, self.feature_material_scratch, scratch);
                    try self.applyCarvers(neighbor_x, neighbor_z, scratch);
                    break :blk scratch;
                };
                chunks[halo_z * 3 + halo_x] = states;
            }
        }
        var region: feature.Region = .{
            .center_chunk_x = chunk_x,
            .center_chunk_z = chunk_z,
            .chunks = chunks,
            .biome_cache = &self.biome_cache,
        };
        try self.applyFeaturesToRegion(chunk_x, chunk_z, &region);
    }

    pub fn applyFeaturesToRegion(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        region: *feature.Region,
    ) !void {
        var work: FeatureWork = undefined;
        try self.initializeFeatureWork(chunk_x, chunk_z, region, &work);
        while (!try self.advanceFeatureWork(chunk_x, chunk_z, region, &work)) {}
    }

    pub fn initializeFeatureWork(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        region: *feature.Region,
        work: *FeatureWork,
    ) !void {
        if (region.center_chunk_x != chunk_x or region.center_chunk_z != chunk_z)
            return error.InvalidFeatureRegion;
        for (0..3) |halo_z| {
            for (0..3) |halo_x| {
                const states = region.chunks[halo_z * 3 + halo_x];
                if (states.len != block_count) return error.InvalidChunkOutputSize;
                fillHeightMaps(
                    states,
                    &work.ocean_floor,
                    &work.world_surface,
                    halo_x * width,
                    halo_z * width,
                );
            }
        }
        self.beginFeatureWork(chunk_x, chunk_z, region, work);
    }

    pub fn beginFeatureWork(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        region: *feature.Region,
        work: *FeatureWork,
    ) void {
        work.decorator_random = feature.DecoratorRandom.init(self.world_seed, chunk_x, chunk_z);
        work.biomes.prepare(
            &self.feature_biomes,
            self.climate_sampler,
            region,
            chunk_x,
            chunk_z,
        );
        @memset(&work.touched_y, minimum_y - 1);
        work.stage = .lava_lakes;
        work.vegetation_index = 0;
    }

    pub fn advanceFeatureWork(
        self: *Generator,
        chunk_x: i32,
        chunk_z: i32,
        region: *feature.Region,
        work: *FeatureWork,
    ) !bool {
        const stage = work.stage;
        var pass = FeaturePass{
            .generator = self,
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .region = region,
            .work = work,
        };
        switch (stage) {
            .lava_lakes => pass.lavaLakes(),
            .amethyst_geodes => pass.amethystGeodes(),
            .large_dripstone => pass.largeDripstone(),
            .local_modifications => pass.localModifications(),
            .underground_structures => pass.undergroundStructures(),
            .surface_structures => pass.surfaceStructures(),
            .underground => try pass.underground(),
            .dripstone_clusters => pass.dripstoneClusters(),
            .pointed_dripstone => pass.pointedDripstone(),
            .fluid_springs => try pass.fluidSprings(),
            .vegetation => if (!pass.vegetation()) return false,
            .freeze_top_layer => pass.freezeTopLayer(),
        }
        if (stage == .freeze_top_layer) return true;
        work.stage = @enumFromInt(@intFromEnum(stage) + 1);
        return false;
    }
};

pub const BaseWork = struct {
    interpolation: density.ChunkInterpolator,
    fluids: aquifer.Sampler,
    first_x: i32,
    first_z: i32,
    next_cell: u8 = 0,

    fn init(generator: *Generator, chunk_x: i32, chunk_z: i32) !BaseWork {
        var result = try initWithRouter(
            generator.allocator,
            generator.router,
            generator.world_seed,
        );
        result.prepare(chunk_x, chunk_z);
        return result;
    }

    fn initWithRouter(
        allocator: std.mem.Allocator,
        router: *density.Router,
        world_seed: u64,
    ) !BaseWork {
        var interpolation = try density.ChunkInterpolator.initFinal(
            allocator,
            router,
            1024,
        );
        errdefer interpolation.deinit();
        const fluids = try aquifer.Sampler.init(
            allocator,
            router,
            world_seed,
            0,
            0,
        );
        return .{
            .interpolation = interpolation,
            .fluids = fluids,
            .first_x = 0,
            .first_z = 0,
        };
    }

    pub fn prepare(self: *BaseWork, chunk_x: i32, chunk_z: i32) void {
        self.interpolation.prepare(chunk_x, chunk_z);
        self.fluids.prepare(chunk_x, chunk_z);
        self.first_x = chunk_x * width;
        self.first_z = chunk_z * width;
        self.next_cell = 0;
    }

    pub fn deinit(self: *BaseWork) void {
        self.fluids.deinit();
        self.interpolation.deinit();
        self.* = undefined;
    }

    pub fn advance(self: *BaseWork, output: []aquifer.Material) bool {
        return self.advanceInto(aquifer.Material, output, {});
    }

    pub fn advanceStates(
        self: *BaseWork,
        output: []GeneratedState,
        top_heights: *[width * width]i32,
    ) bool {
        return self.advanceInto(GeneratedState, output, top_heights);
    }

    fn advanceInto(
        self: *BaseWork,
        comptime Output: type,
        output: []Output,
        top_heights: if (Output == GeneratedState) *[width * width]i32 else void,
    ) bool {
        comptime std.debug.assert(Output == aquifer.Material or Output == GeneratedState);
        std.debug.assert(output.len == block_count);
        const horizontal_cells = density.ChunkInterpolator.horizontal_cells;
        std.debug.assert(self.next_cell < horizontal_cells * horizontal_cells);
        @setRuntimeSafety(false);
        while (self.next_cell < horizontal_cells * horizontal_cells) {
            const cell_x: usize = self.next_cell / horizontal_cells;
            const cell_z: usize = self.next_cell % horizontal_cells;
            self.fillCellColumn(Output, output, top_heights, cell_x, cell_z);
            self.next_cell += 1;
        }
        return true;
    }

    fn fillCellColumn(
        self: *BaseWork,
        comptime Output: type,
        output: []Output,
        top_heights: if (Output == GeneratedState) *[width * width]i32 else void,
        cell_x: usize,
        cell_z: usize,
    ) void {
        var cell_y: usize = density.ChunkInterpolator.vertical_cells;
        while (cell_y > 0) {
            cell_y -= 1;
            const bounds = self.interpolation.cellFinalDensityBounds(cell_x, cell_y, cell_z);
            if (bounds.minimum > 0) {
                fillSolidCell(Output, output, top_heights, cell_x, cell_y, cell_z);
                continue;
            }
            var negative_materials: [128]aquifer.Material = undefined;
            const negative_first = self.cellOrigin(cell_x, cell_y, cell_z);
            if (bounds.maximum <= 0 and
                self.fluids.negativeCellMaterials(negative_first, &negative_materials))
            {
                fillNegativeCell(
                    Output,
                    output,
                    top_heights,
                    cell_x,
                    cell_y,
                    cell_z,
                    &negative_materials,
                );
                continue;
            }
            self.fillExactCell(Output, output, top_heights, cell_x, cell_y, cell_z);
        }
    }

    fn cellOrigin(self: *const BaseWork, cell_x: usize, cell_y: usize, cell_z: usize) density.Position {
        return .{
            .x = self.first_x + @as(i32, @intCast(
                cell_x * density.ChunkInterpolator.horizontal_cell_size,
            )),
            .y = minimum_y + @as(i32, @intCast(
                cell_y * density.ChunkInterpolator.vertical_cell_size,
            )),
            .z = self.first_z + @as(i32, @intCast(
                cell_z * density.ChunkInterpolator.horizontal_cell_size,
            )),
        };
    }

    fn fillExactCell(
        self: *BaseWork,
        comptime Output: type,
        output: []Output,
        top_heights: if (Output == GeneratedState) *[width * width]i32 else void,
        cell_x: usize,
        cell_y: usize,
        cell_z: usize,
    ) void {
        comptime std.debug.assert(
            density.sample_lanes % density.ChunkInterpolator.horizontal_cell_size == 0,
        );
        const x_lanes = density.sample_lanes /
            density.ChunkInterpolator.horizontal_cell_size;
        var local_y: usize = density.ChunkInterpolator.vertical_cell_size;
        while (local_y > 0) {
            local_y -= 1;
            const y = minimum_y + @as(i32, @intCast(
                cell_y * density.ChunkInterpolator.vertical_cell_size + local_y,
            ));
            var local_x: usize = 0;
            while (local_x < density.ChunkInterpolator.horizontal_cell_size) : (local_x += x_lanes) {
                var positions: [density.sample_lanes]density.Position = undefined;
                inline for (0..density.sample_lanes) |lane| positions[lane] = .{
                    .x = self.first_x + @as(i32, @intCast(
                        cell_x * density.ChunkInterpolator.horizontal_cell_size +
                            local_x + lane / density.ChunkInterpolator.horizontal_cell_size,
                    )),
                    .y = y,
                    .z = self.first_z + @as(i32, @intCast(
                        cell_z * density.ChunkInterpolator.horizontal_cell_size +
                            lane % density.ChunkInterpolator.horizontal_cell_size,
                    )),
                };
                const densities = self.interpolation.sampleFinal4(positions);
                const materials = self.fluids.material4(positions, densities);
                inline for (positions, materials) |position, material| {
                    const local_position_x = position.x - self.first_x;
                    const local_position_z = position.z - self.first_z;
                    output[blockIndex(local_position_x, y, local_position_z)] = if (Output == GeneratedState)
                        GeneratedState.fromBase(material)
                    else
                        material;
                    if (Output == GeneratedState and material != .air) {
                        const height_index = @as(usize, @intCast(local_position_z)) * width +
                            @as(usize, @intCast(local_position_x));
                        top_heights[height_index] = @max(top_heights[height_index], y + 1);
                    }
                }
            }
        }
    }

    fn fillSolidCell(
        comptime Output: type,
        output: []Output,
        top_heights: if (Output == GeneratedState) *[width * width]i32 else void,
        cell_x: usize,
        cell_y: usize,
        cell_z: usize,
    ) void {
        const first_x = cell_x * density.ChunkInterpolator.horizontal_cell_size;
        const first_y = cell_y * density.ChunkInterpolator.vertical_cell_size;
        const first_z = cell_z * density.ChunkInterpolator.horizontal_cell_size;
        const value: Output = if (Output == GeneratedState)
            GeneratedState.fromBase(.stone)
        else
            .stone;
        for (0..density.ChunkInterpolator.vertical_cell_size) |local_y| {
            const y = minimum_y + @as(i32, @intCast(first_y + local_y));
            for (0..density.ChunkInterpolator.horizontal_cell_size) |local_z| {
                const index = blockIndex(@intCast(first_x), y, @intCast(first_z + local_z));
                @memset(output[index..][0..density.ChunkInterpolator.horizontal_cell_size], value);
            }
        }
        if (Output == GeneratedState) {
            const top = minimum_y + @as(i32, @intCast(first_y + density.ChunkInterpolator.vertical_cell_size));
            for (0..density.ChunkInterpolator.horizontal_cell_size) |local_z| {
                for (0..density.ChunkInterpolator.horizontal_cell_size) |local_x| {
                    const height_index = (first_z + local_z) * width + first_x + local_x;
                    top_heights[height_index] = @max(top_heights[height_index], top);
                }
            }
        }
    }

    fn fillNegativeCell(
        comptime Output: type,
        output: []Output,
        top_heights: if (Output == GeneratedState) *[width * width]i32 else void,
        cell_x: usize,
        cell_y: usize,
        cell_z: usize,
        materials: *const [128]aquifer.Material,
    ) void {
        const first_x = cell_x * density.ChunkInterpolator.horizontal_cell_size;
        const first_y = cell_y * density.ChunkInterpolator.vertical_cell_size;
        const first_z = cell_z * density.ChunkInterpolator.horizontal_cell_size;
        var material_index: usize = 0;
        for (0..density.ChunkInterpolator.vertical_cell_size) |local_y| {
            const y = minimum_y + @as(i32, @intCast(first_y + local_y));
            for (0..density.ChunkInterpolator.horizontal_cell_size) |local_x| {
                for (0..density.ChunkInterpolator.horizontal_cell_size) |local_z| {
                    const material = materials[material_index];
                    output[blockIndex(@intCast(first_x + local_x), y, @intCast(first_z + local_z))] =
                        if (Output == GeneratedState)
                            GeneratedState.fromBase(material)
                        else
                            material;
                    if (Output == GeneratedState and material != .air) {
                        const height_index = (first_z + local_z) * width + first_x + local_x;
                        top_heights[height_index] = @max(top_heights[height_index], y + 1);
                    }
                    material_index += 1;
                }
            }
        }
    }
};

pub const FeatureStage = enum(u8) {
    lava_lakes,
    amethyst_geodes,
    large_dripstone,
    local_modifications,
    underground_structures,
    surface_structures,
    underground,
    dripstone_clusters,
    pointed_dripstone,
    fluid_springs,
    vegetation,
    freeze_top_layer,
};

pub const FeatureWork = struct {
    ocean_floor: feature.HeightHalo,
    world_surface: feature.HeightHalo,
    touched_y: feature.HeightHalo,
    decorator_random: feature.DecoratorRandom,
    biomes: feature.BiomePlan,
    stage: FeatureStage,
    vegetation_index: u8,
};

const FeaturePass = struct {
    generator: *Generator,
    chunk_x: i32,
    chunk_z: i32,
    region: *feature.Region,
    work: *FeatureWork,

    fn lavaLakes(self: *FeaturePass) void {
        feature.applyLavaLakes(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, &self.work.ocean_floor, &self.work.world_surface, &self.work.decorator_random, self.region);
    }

    fn amethystGeodes(self: *FeaturePass) void {
        feature.applyIcebergs(
            self.chunk_x,
            self.chunk_z,
            &self.work.biomes,
            &self.work.decorator_random,
            self.region,
        );
        _ = feature.applyAmethystGeodes(self.generator.world_seed, self.chunk_x, self.chunk_z, &self.work.decorator_random, self.region);
    }

    fn largeDripstone(self: *FeaturePass) void {
        _ = feature.applyLargeDripstone(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, &self.work.biomes, &self.work.decorator_random, self.region);
    }

    fn localModifications(self: *FeaturePass) void {
        feature.applySimpleFeatures(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.world_surface, &self.work.ocean_floor, &self.work.decorator_random, self.region, 2, 0, std.math.maxInt(u8));
    }

    fn undergroundStructures(self: *FeaturePass) void {
        feature.applyMonsterRooms(
            self.chunk_x,
            self.chunk_z,
            &self.work.biomes,
            &self.work.decorator_random,
            self.region,
        );
    }

    fn surfaceStructures(self: *FeaturePass) void {
        stronghold.applyAt(
            self.generator.world_seed,
            self.generator.climate_sampler,
            &self.generator.biome_cache,
            self.region,
        );
        feature.applySimpleFeatures(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.world_surface, &self.work.ocean_floor, &self.work.decorator_random, self.region, 4, 0, std.math.maxInt(u8));
    }

    fn underground(self: *FeaturePass) !void {
        try feature.applyUndergroundFeatures(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.ocean_floor, &self.work.decorator_random, self.region);
    }

    fn dripstoneClusters(self: *FeaturePass) void {
        feature.applyDripstoneClusters(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, &self.work.biomes, &self.work.decorator_random, self.region);
    }

    fn pointedDripstone(self: *FeaturePass) void {
        feature.applyPointedDripstone(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, &self.work.biomes, &self.work.decorator_random, self.region);
    }

    fn fluidSprings(self: *FeaturePass) !void {
        try feature.applyInfestedOre(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.ocean_floor, &self.work.decorator_random, self.region);
        feature.applyFluidSprings(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region);
    }

    fn vegetation(self: *FeaturePass) bool {
        const index = self.work.vegetation_index;
        std.debug.assert(index < 106);
        if (index == feature_data.glow_lichen.index)
            feature.applyGlowLichen(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.ocean_floor, &self.work.decorator_random, self.region);
        feature.applyForestFlowers(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index);
        if (index == feature_data.cave_vines.index)
            feature.applyCaveVines(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region);
        feature.applyFlowerPatches(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index, index + 1);
        feature.applyBasicTreeSelectors(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index);
        feature.applyMushroomIslandVegetation(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index);
        if (index == feature_data.tall_birch_trees.index)
            feature.applyTallBirchTrees(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region);
        if (index == feature_data.birch_trees.index)
            feature.applyBirchTrees(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region);
        if (index == feature_data.oak_leaf_litter_trees.index)
            feature.applyOakLeafLitterTrees(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region);
        if (index == feature_data.patch_grass_forest.index)
            feature.applyForestGrassPatch(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.world_surface, &self.work.decorator_random, self.region);
        feature.applySurfacePatches(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index, index + 1);
        feature.applyNoiseGrassPatches(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.world_surface, &self.work.decorator_random, self.region, index, index + 1);
        feature.applyNearWaterPatches(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.decorator_random, self.region, index, index + 1);
        feature.applyAquaticVegetation(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, &self.work.biomes, &self.work.ocean_floor, &self.work.decorator_random, self.region, index, index + 1);
        feature.applySimpleFeatures(self.chunk_x, self.chunk_z, &self.work.biomes, &self.work.world_surface, &self.work.ocean_floor, &self.work.decorator_random, self.region, 9, index, index + 1);
        self.work.vegetation_index += 1;
        return self.work.vegetation_index == 106;
    }

    fn freezeTopLayer(self: *FeaturePass) void {
        feature.applyFreezeTopLayer(self.generator.world_seed, self.chunk_x, self.chunk_z, self.generator.climate_sampler, self.region);
    }
};

pub const BiomeHalo = struct {
    const side = 3;
    const chunk_count = side * side;

    center_x: i32,
    center_z: i32,
    chunks: [chunk_count][biome.overworld_cell_count]u8,

    fn fill(
        self: *BiomeHalo,
        cache: *biome.Cache,
        sampler: *const climate.Sampler,
        center_x: i32,
        center_z: i32,
    ) void {
        self.center_x = center_x;
        self.center_z = center_z;
        for (0..side) |local_z| {
            for (0..side) |local_x| {
                const chunk_x = center_x + @as(i32, @intCast(local_x)) - 1;
                const chunk_z = center_z + @as(i32, @intCast(local_z)) - 1;
                @memcpy(
                    &self.chunks[local_z * side + local_x],
                    cache.chunk(sampler, chunk_x, chunk_z),
                );
            }
        }
    }

    fn at(self: *const BiomeHalo, quart: density.Position) u8 {
        const chunk_x = @divFloor(quart.x, 4);
        const chunk_z = @divFloor(quart.z, 4);
        const halo_x = chunk_x - self.center_x + 1;
        const halo_z = chunk_z - self.center_z + 1;
        std.debug.assert(halo_x >= 0 and halo_x < side);
        std.debug.assert(halo_z >= 0 and halo_z < side);
        const local_x: usize = @intCast(@mod(quart.x, 4));
        const local_z: usize = @intCast(@mod(quart.z, 4));
        const local_y: usize = @intCast(quart.y - @divFloor(minimum_y, 4));
        const section = local_y / 4;
        const section_y = local_y % 4;
        const index = section * biome.quart_cells_per_section +
            local_x + local_z * 4 + section_y * 16;
        const halo_index: usize = @intCast(halo_z * side + halo_x);
        return self.chunks[halo_index][index];
    }
};

const SurfaceColumn = struct {
    local_x: usize,
    local_z: usize,
    x: i32,
    z: i32,
    height_index: usize,
    initial_top: i32,
    run_depth: i32,
    surface_noise: f64,
    secondary_depth: f64,
    preliminary_surface: i32,
    surface_biome_index: u8,
    steep: bool = false,
    below: [height]u16 = undefined,

    fn init(generator: *Generator, first_x: i32, first_z: i32, local_x: usize, local_z: usize, run_depth: i32, surface_noise: f64, secondary_depth: f64, top_heights: *const [width * width]i32, biome_halo: *const BiomeHalo, preliminary_corners: *const [4]i32) SurfaceColumn {
        const x = first_x + @as(i32, @intCast(local_x));
        const z = first_z + @as(i32, @intCast(local_z));
        const height_index = local_z * width + local_x;
        const initial_top = top_heights[height_index];
        const quart = generator.surface_biome_access.quartPosition(.{ .x = x, .y = initial_top, .z = z });
        return .{
            .local_x = local_x,
            .local_z = local_z,
            .x = x,
            .z = z,
            .height_index = height_index,
            .initial_top = initial_top,
            .run_depth = run_depth,
            .surface_noise = surface_noise,
            .secondary_depth = secondary_depth,
            .preliminary_surface = density.preliminarySurfaceHeightFromCorners(preliminary_corners, x, z, run_depth),
            .surface_biome_index = biome_halo.at(quart),
        };
    }

    fn fillStoneDepth(self: *SurfaceColumn, output: []const GeneratedState) void {
        var consecutive: u16 = 0;
        for (0..height) |local_y| {
            const index = local_y * width * width +
                self.local_z * width + self.local_x;
            consecutive = if (generatedMaterial(output[index]) == .stone)
                consecutive + 1
            else
                0;
            self.below[local_y] = consecutive;
        }
    }
};

fn frozenOceanBiome(index: u8) bool {
    const name = biome.name(index);
    return std.mem.eql(u8, name, "minecraft:frozen_ocean") or
        std.mem.eql(u8, name, "minecraft:deep_frozen_ocean");
}

fn columnIsSteep(heights: *const [width * width]i32, local_x: usize, local_z: usize) bool {
    const lower_z = if (local_z == 0) 0 else local_z - 1;
    const upper_z: usize = @min(local_z + 1, @as(usize, width - 1));
    if (heights[upper_z * width + local_x] >= heights[lower_z * width + local_x] + 4)
        return true;
    const lower_x = if (local_x == 0) 0 else local_x - 1;
    const upper_x: usize = @min(local_x + 1, @as(usize, width - 1));
    return heights[local_z * width + lower_x] >= heights[local_z * width + upper_x] + 4;
}

fn isAir(state: GeneratedState) bool {
    return state == .air;
}

fn isWater(state: GeneratedState) bool {
    return state == .water;
}

fn generatedMaterial(state: GeneratedState) aquifer.Material {
    return state.baseMaterial() orelse .stone;
}

fn oreVeinState(copper: bool, rich: bool, source: *random.Xoroshiro) u16 {
    if (!rich) return if (copper)
        feature_data.ore_veins.granite
    else
        feature_data.ore_veins.tuff;
    if (source.nextF32() < 0.02) return if (copper)
        feature_data.ore_veins.raw_copper_block
    else
        feature_data.ore_veins.raw_iron_block;
    return if (copper)
        feature_data.ore_veins.copper_ore
    else
        feature_data.ore_veins.iron_ore;
}

fn clampedMap(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
    const delta = std.math.clamp((value - from) / (to - from), 0, 1);
    return from_value + delta * (to_value - from_value);
}

fn fillHeightMaps(
    states: []const GeneratedState,
    ocean_floor: *feature.HeightHalo,
    world_surface: *feature.HeightHalo,
    first_x: usize,
    first_z: usize,
) void {
    for (0..width) |local_z| {
        for (0..width) |local_x| {
            const halo_index = (first_z + local_z) * feature.height_halo_side +
                first_x + local_x;
            const heights = columnHeights(states, local_x, local_z);
            world_surface[halo_index] = heights.world_surface;
            ocean_floor[halo_index] = heights.ocean_floor;
        }
    }
}

pub const ColumnHeights = struct {
    ocean_floor: i16,
    world_surface: i16,
};

pub fn columnHeights(
    states: []const GeneratedState,
    local_x: usize,
    local_z: usize,
) ColumnHeights {
    var result: ColumnHeights = .{
        .ocean_floor = minimum_y,
        .world_surface = minimum_y,
    };
    var y: i32 = minimum_y + height;
    while (y > minimum_y) {
        y -= 1;
        const state = states[blockIndex(@intCast(local_x), y, @intCast(local_z))];
        if (result.world_surface == minimum_y and !isAir(state))
            result.world_surface = @intCast(y + 1);
        const solid = state == .stone or state.kind() != .base;
        if (solid) {
            result.ocean_floor = @intCast(y + 1);
            break;
        }
    }
    return result;
}

pub fn fillChunkHeights(
    states: []const GeneratedState,
    ocean_floor: *[width * width]i16,
    world_surface: *[width * width]i16,
) void {
    for (0..width) |z| for (0..width) |x| {
        const heights = columnHeights(states, x, z);
        ocean_floor[z * width + x] = heights.ocean_floor;
        world_surface[z * width + x] = heights.world_surface;
    };
}

fn placeBadlandsPillar(
    output: []GeneratedState,
    local_x: usize,
    local_z: usize,
    target: i32,
) bool {
    if (target < minimum_y or target >= minimum_y + height) return false;
    var y = target;
    while (y >= minimum_y) : (y -= 1) {
        const material = generatedMaterial(
            output[blockIndex(@intCast(local_x), y, @intCast(local_z))],
        );
        if (material == .stone) break;
        if (material == .water) return false;
    }
    y = target;
    var placed = false;
    while (y >= minimum_y) : (y -= 1) {
        const index = blockIndex(@intCast(local_x), y, @intCast(local_z));
        if (!isAir(output[index])) break;
        output[index] = GeneratedState.fromBase(.stone);
        placed = true;
    }
    return placed;
}

pub inline fn blockIndex(local_x: i32, y: i32, local_z: i32) usize {
    std.debug.assert(local_x >= 0 and local_x < width);
    std.debug.assert(local_z >= 0 and local_z < width);
    std.debug.assert(y >= minimum_y and y < minimum_y + height);
    return @as(usize, @intCast(y - minimum_y)) * width * width +
        @as(usize, @intCast(local_z)) * width +
        @as(usize, @intCast(local_x));
}

test "base density and aquifers match Vanilla seed zero noise chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    try generator.fillBaseMaterials(7, 4, blocks);

    var stone: usize = 0;
    var air: usize = 0;
    var water: usize = 0;
    var lava: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (blocks) |material| switch (material) {
        .stone => {
            stone += 1;
            hash.update(&.{0});
        },
        .air => {
            air += 1;
            hash.update(&.{1});
        },
        .water => {
            water += 1;
            hash.update(&.{2});
        },
        .lava => {
            lava += 1;
            hash.update(&.{3});
        },
    };
    try std.testing.expectEqual(@as(usize, 29_662), stone);
    try std.testing.expectEqual(@as(usize, 67_006), air);
    try std.testing.expectEqual(@as(usize, 1_636), water);
    try std.testing.expectEqual(@as(usize, 0), lava);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x30, 0x8f, 0xb3, 0x18, 0x7e, 0x46, 0xb8, 0x12,
            0xad, 0x0c, 0x21, 0xe1, 0x68, 0x70, 0xe3, 0xa1,
            0x09, 0xbb, 0x7d, 0x0b, 0xb3, 0x9a, 0xd1, 0x65,
            0x36, 0xb6, 0xc5, 0x8f, 0x1b, 0x7d, 0xc4, 0xbc,
        },
        digest,
    );
}

test "seed zero cave boundary cell matches Vanilla" {
    var router = try density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    var interpolation = try density.ChunkInterpolator.init(std.testing.allocator, &router);
    defer interpolation.deinit();
    interpolation.prepare(7, 3);
    var fluids = try aquifer.Sampler.init(std.testing.allocator, &router, 0, 7, 3);
    defer fluids.deinit();
    const position: density.Position = .{ .x = 121, .y = -6, .z = 57 };
    const final_density = interpolation.sampleFinal(position);
    const material = fluids.material(position, final_density);
    if (material != .air)
        std.debug.print("cave boundary density={d} material={s}\n", .{ final_density, @tagName(material) });
    try std.testing.expectEqual(aquifer.Material.air, material);
}

test "surface stage matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(7, 4, blocks);
    try generator.applySurface(7, 4, blocks, states);
    const expected = [_]struct { name: []const u8, count: usize }{
        .{ .name = "minecraft:bedrock", .count = 770 },
        .{ .name = "minecraft:deepslate[axis=y]", .count = 16_345 },
        .{ .name = "minecraft:air", .count = 67_006 },
        .{ .name = "minecraft:water[level=0]", .count = 1_636 },
        .{ .name = "minecraft:stone", .count = 10_991 },
        .{ .name = "minecraft:sandstone", .count = 485 },
        .{ .name = "minecraft:sand", .count = 1_048 },
        .{ .name = "minecraft:dirt", .count = 12 },
        .{ .name = "minecraft:grass_block[snowy=false]", .count = 11 },
    };
    var counts = [_]usize{0} ** expected.len;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        for (expected, &counts) |entry, *count| {
            if (std.mem.eql(u8, name, entry.name)) {
                count.* += 1;
                break;
            }
        }
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var counts_match = true;
    for (expected, counts) |entry, count| {
        if (entry.count == count) continue;
        counts_match = false;
        std.debug.print(
            "surface count mismatch for {s}: expected {d}, found {d}\n",
            .{ entry.name, entry.count, count },
        );
    }
    try std.testing.expect(counts_match);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x40, 0xb9, 0xc8, 0xbc, 0x94, 0x1d, 0x87, 0x8b,
            0x8a, 0x76, 0x34, 0xae, 0xc5, 0xc3, 0xe0, 0xa8,
            0x58, 0x2b, 0x77, 0x88, 0xc4, 0xfd, 0x76, 0xd1,
            0xc2, 0x78, 0x65, 0x25, 0xc1, 0xf6, 0x71, 0x38,
        },
        digest,
    );
}

test "terracotta bands match Vanilla seed zero badlands chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(35, -103, blocks);
    try generator.applySurface(35, -103, blocks, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x5e, 0xb6, 0x00, 0xdf, 0x22, 0x6b, 0x02, 0xeb,
            0x30, 0xeb, 0x8e, 0xf0, 0xea, 0x7e, 0xf8, 0x8a,
            0xf6, 0x6e, 0xec, 0x0b, 0xce, 0x60, 0x65, 0x13,
            0xe9, 0xf2, 0x75, 0xdc, 0x7b, 0x97, 0xfc, 0xeb,
        },
        digest,
    );
}

test "frozen ocean iceberg matches Vanilla seed zero chunk" {
    try expectSurfaceHash(
        0,
        -140,
        143,
        .{
            0xd4, 0x89, 0x0c, 0x52, 0x01, 0x67, 0x64, 0xb6,
            0x8d, 0x9f, 0xa7, 0x81, 0xea, 0x79, 0x14, 0xc5,
            0xd1, 0xed, 0x07, 0x09, 0xa7, 0x2d, 0x9d, 0xea,
            0xdb, 0xc0, 0xa1, 0xa6, 0xb6, 0xf1, 0x33, 0xd2,
        },
    );
}

test "eroded badlands pillars match Vanilla seed zero chunk" {
    try expectSurfaceHash(
        0,
        1,
        -217,
        .{
            0x1a, 0xc9, 0x8c, 0xdc, 0x9a, 0x2a, 0x92, 0xbf,
            0x9e, 0xc5, 0x67, 0xb7, 0x3c, 0x52, 0xdd, 0x28,
            0x03, 0x8a, 0x16, 0xff, 0xf2, 0x6f, 0xf9, 0x9e,
            0xfe, 0x32, 0x62, 0xfc, 0xea, 0x15, 0x05, 0x5d,
        },
    );
}

test "cave carvers match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(7, 4, blocks);
    try generator.applySurface(7, 4, blocks, states);
    try generator.applyCarvers(7, 4, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x7c, 0x4d, 0x83, 0xc7, 0x71, 0x91, 0xef, 0xb7,
            0x80, 0x70, 0x35, 0x16, 0xf0, 0xde, 0x0b, 0x48,
            0x28, 0x97, 0x42, 0x41, 0xf5, 0x52, 0xeb, 0x8b,
            0xe7, 0x8c, 0xa3, 0x06, 0x94, 0xf1, 0xb7, 0xa7,
        },
        digest,
    );
}

test "canyon carver matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(5, 3, blocks);
    try generator.applySurface(5, 3, blocks, states);
    try generator.applyCarvers(5, 3, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xba, 0xea, 0xae, 0xb9, 0x50, 0x05, 0x46, 0x7b,
            0xfc, 0x96, 0x79, 0xa7, 0xfc, 0x1b, 0x52, 0xa3,
            0xd4, 0x05, 0xa2, 0x7e, 0xfb, 0xe2, 0xd8, 0x72,
            0x2d, 0xd7, 0xc1, 0x3d, 0xa1, 0xce, 0xb5, 0x6c,
        },
        digest,
    );
}

test "feature population matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(7, 4, blocks);
    try generator.applySurface(7, 4, blocks, states);
    try generator.applyCarvers(7, 4, states);
    try generator.applyFeatures(7, 4, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xba, 0xdf, 0x77, 0x98, 0x0e, 0xe7, 0x80, 0x4f,
            0xdd, 0xfa, 0x7b, 0x98, 0xa1, 0x84, 0xd1, 0xe4,
            0x2e, 0x6c, 0xdf, 0x6e, 0x75, 0x29, 0x9f, 0x44,
            0x58, 0x5d, 0xe5, 0x43, 0xa3, 0x6b, 0xf6, 0x97,
        },
        digest,
    );
}

test "desert cactus population matches Vanilla 1.21.8" {
    var generator = try Generator.init(std.testing.allocator, 14_320);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-6, 2, blocks);
    try generator.applySurface(-6, 2, blocks, states);
    try generator.applyCarvers(-6, 2, states);
    try generator.applyFeatures(-6, 2, states);

    var cactus_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        cactus_count += @intFromBool(state.block() == .cactus);
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 2), cactus_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x8e, 0xa0, 0x02, 0x94, 0xb1, 0x35, 0xbe, 0x0a,
            0x8f, 0x4d, 0xff, 0xaf, 0x76, 0xe9, 0x43, 0x9d,
            0x77, 0x73, 0x5d, 0x45, 0x48, 0xc2, 0x97, 0x76,
            0x73, 0xe6, 0x84, 0x21, 0x57, 0xf8, 0xc6, 0xa2,
        },
        digest,
    );
}

test "oak leaf litter population matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(7, 3, blocks);
    try generator.applySurface(7, 3, blocks, states);
    try generator.applyCarvers(7, 3, states);
    try generator.applyFeatures(7, 3, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x27, 0x2b, 0x61, 0x1e, 0xf0, 0xd5, 0xe8, 0xfc,
            0x0e, 0x58, 0x88, 0x03, 0x51, 0x88, 0xba, 0x31,
            0x33, 0x57, 0x6d, 0x74, 0x92, 0xf7, 0x71, 0x57,
            0x36, 0xfa, 0xd5, 0x5d, 0x4f, 0x72, 0x0c, 0xfb,
        },
        digest,
    );
}

test "forest vegetation population matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(201, 64, blocks);
    try generator.applySurface(201, 64, blocks, states);
    try generator.applyCarvers(201, 64, states);
    try generator.applyFeatures(201, 64, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xe0, 0xcd, 0xad, 0x20, 0xa2, 0xc6, 0x94, 0x36,
            0x80, 0x47, 0x48, 0x9f, 0xe5, 0x1c, 0x9f, 0x02,
            0x7a, 0x61, 0x8d, 0x14, 0x2e, 0x9b, 0xd2, 0xc7,
            0xa7, 0xa9, 0x4b, 0xfe, 0xfa, 0x91, 0x31, 0xb0,
        },
        digest,
    );
}

test "forest flowers fancy oak and copper vein match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(200, 63, blocks);
    try generator.applySurface(200, 63, blocks, states);
    try generator.applyCarvers(200, 63, states);
    try generator.applyFeatures(200, 63, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x6c, 0x46, 0x56, 0xcc, 0xc5, 0x95, 0x2a, 0xcf,
            0x38, 0x3b, 0xae, 0x55, 0x07, 0xad, 0x7f, 0x9d,
            0x41, 0x67, 0xd0, 0xcc, 0x61, 0xa2, 0x36, 0x00,
            0xd0, 0x3d, 0x6d, 0xff, 0x56, 0x66, 0x8d, 0x89,
        },
        digest,
    );
}

test "fluid springs and overlapping forest trees match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(199, 62, blocks);
    try generator.applySurface(199, 62, blocks, states);
    try generator.applyCarvers(199, 62, states);
    try generator.applyFeatures(199, 62, states);

    try std.testing.expectEqualStrings(
        "minecraft:lava[level=0]",
        states[blockIndex(12, -18, 14)].canonicalName(),
    );
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xc2, 0x7b, 0x6d, 0x23, 0x51, 0x56, 0xcc, 0x86,
            0xd8, 0xd5, 0xde, 0xf6, 0x08, 0xd9, 0x21, 0x51,
            0x32, 0x8a, 0xd1, 0xae, 0xeb, 0x76, 0xf3, 0xb1,
            0x42, 0xf4, 0xf0, 0xdc, 0x03, 0x33, 0x3a, 0x29,
        },
        digest,
    );
}

test "frozen shoreline and firefly bushes match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(232, 50, blocks);
    try generator.applySurface(232, 50, blocks, states);
    try generator.applyCarvers(232, 50, states);
    try generator.applyFeatures(232, 50, states);

    var ice_count: usize = 0;
    var snow_count: usize = 0;
    var firefly_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:ice")) ice_count += 1;
        if (std.mem.eql(u8, name, "minecraft:snow[layers=1]")) snow_count += 1;
        if (std.mem.eql(u8, name, "minecraft:firefly_bush")) firefly_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 226), ice_count);
    try std.testing.expectEqual(@as(usize, 26), snow_count);
    try std.testing.expectEqual(@as(usize, 4), firefly_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xbe, 0x9b, 0x2b, 0xf0, 0x6e, 0x54, 0x5d, 0x5f,
            0x03, 0x7d, 0x3d, 0x14, 0x25, 0xfd, 0x87, 0xfc,
            0xbc, 0xd9, 0x67, 0xee, 0x4d, 0x45, 0xd9, 0x52,
            0xf2, 0x70, 0x9c, 0x37, 0xec, 0x61, 0xd7, 0xd1,
        },
        digest,
    );
}

test "plains grass and pointed dripstone match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-92, -256, blocks);
    try generator.applySurface(-92, -256, blocks, states);
    try generator.applyCarvers(-92, -256, states);
    try generator.applyFeatures(-92, -256, states);

    var grass_count: usize = 0;
    var dripstone_block_count: usize = 0;
    var pointed_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:short_grass")) grass_count += 1;
        if (std.mem.eql(u8, name, "minecraft:dripstone_block"))
            dripstone_block_count += 1;
        if (std.mem.startsWith(u8, name, "minecraft:pointed_dripstone["))
            pointed_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 36), grass_count);
    try std.testing.expectEqual(@as(usize, 13), dripstone_block_count);
    try std.testing.expectEqual(@as(usize, 3), pointed_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x12, 0x84, 0x57, 0xe1, 0x0d, 0x8f, 0x29, 0x89,
            0xee, 0x4b, 0x23, 0x2e, 0x87, 0x06, 0x41, 0x03,
            0x02, 0xea, 0x9f, 0xb5, 0x34, 0x00, 0xdd, 0x6b,
            0x3a, 0xe0, 0x48, 0x25, 0xd9, 0xe6, 0x48, 0xc2,
        },
        digest,
    );
}

test "dripstone cluster and shared decorator random match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-38, -256, blocks);
    try generator.applySurface(-38, -256, blocks, states);
    try generator.applyCarvers(-38, -256, states);
    try generator.applyFeatures(-38, -256, states);

    var dripstone_block_count: usize = 0;
    var pointed_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:dripstone_block"))
            dripstone_block_count += 1;
        if (std.mem.startsWith(u8, name, "minecraft:pointed_dripstone["))
            pointed_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 140), dripstone_block_count);
    try std.testing.expectEqual(@as(usize, 25), pointed_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xa4, 0x68, 0x28, 0x05, 0xdc, 0x3b, 0x49, 0x86,
            0xcf, 0xe5, 0x96, 0x65, 0xfa, 0x66, 0x94, 0x98,
            0xd3, 0x59, 0x67, 0x26, 0x82, 0x57, 0x60, 0x91,
            0x45, 0x6b, 0x58, 0xe7, 0x81, 0xcb, 0x25, 0x6f,
        },
        digest,
    );
}

test "large dripstone matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-40, -255, blocks);
    try generator.applySurface(-40, -255, blocks, states);
    try generator.applyCarvers(-40, -255, states);
    try generator.applyFeatures(-40, -255, states);

    var dripstone_block_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:dripstone_block"))
            dripstone_block_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 378), dripstone_block_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xe4, 0x88, 0x02, 0xa6, 0xe8, 0xa3, 0x13, 0x15,
            0xef, 0x55, 0xfa, 0x69, 0xaf, 0xc9, 0xfe, 0x65,
            0xf5, 0xc6, 0x69, 0x9a, 0xb4, 0x6a, 0xe7, 0x6d,
            0x3c, 0xe1, 0xfa, 0x81, 0xa4, 0x99, 0xee, 0xa1,
        },
        digest,
    );
}

test "amethyst geode matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-31, -32, blocks);
    try generator.applySurface(-31, -32, blocks, states);
    try generator.applyCarvers(-31, -32, states);
    try generator.applyFeatures(-31, -32, states);

    var smooth_basalt_count: usize = 0;
    var calcite_count: usize = 0;
    var amethyst_count: usize = 0;
    var budding_count: usize = 0;
    var bud_or_cluster_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:smooth_basalt"))
            smooth_basalt_count += 1;
        if (std.mem.eql(u8, name, "minecraft:calcite"))
            calcite_count += 1;
        if (std.mem.eql(u8, name, "minecraft:amethyst_block"))
            amethyst_count += 1;
        if (std.mem.eql(u8, name, "minecraft:budding_amethyst"))
            budding_count += 1;
        if (std.mem.indexOf(u8, name, "amethyst_bud") != null or
            std.mem.startsWith(u8, name, "minecraft:amethyst_cluster["))
        {
            bud_or_cluster_count += 1;
        }
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 189), smooth_basalt_count);
    try std.testing.expectEqual(@as(usize, 157), calcite_count);
    try std.testing.expectEqual(@as(usize, 122), amethyst_count);
    try std.testing.expectEqual(@as(usize, 9), budding_count);
    try std.testing.expectEqual(@as(usize, 4), bud_or_cluster_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x94, 0xfb, 0xad, 0x48, 0x97, 0xf2, 0xe7, 0xf8,
            0x08, 0x82, 0x6b, 0xe3, 0x5c, 0xb2, 0xf5, 0x11,
            0x7a, 0xca, 0x12, 0x84, 0x71, 0xe5, 0x12, 0x5e,
            0x0d, 0xf4, 0xe1, 0x2f, 0x17, 0xc9, 0xab, 0xa5,
        },
        digest,
    );
}

test "underground lava lake matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(16, -16, blocks);
    try generator.applySurface(16, -16, blocks, states);
    try generator.applyCarvers(16, -16, states);
    try generator.applyFeatures(16, -16, states);

    var lava_count: usize = 0;
    var cave_air_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:lava[level=0]"))
            lava_count += 1;
        if (std.mem.eql(u8, name, "minecraft:cave_air"))
            cave_air_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 79), lava_count);
    try std.testing.expectEqual(@as(usize, 151), cave_air_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0xa4, 0x44, 0xf8, 0xa9, 0x28, 0x6d, 0xb7, 0x1d,
            0x77, 0x65, 0xa2, 0x0b, 0xeb, 0xe1, 0x4b, 0x22,
            0xe4, 0x71, 0x89, 0x16, 0xd2, 0xb0, 0xc7, 0x8a,
            0x6d, 0xb7, 0xd3, 0x97, 0x55, 0x27, 0x97, 0xaf,
        },
        digest,
    );
}

test "surface lava lake matches Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(54, -128, blocks);
    try generator.applySurface(54, -128, blocks, states);
    try generator.applyCarvers(54, -128, states);
    try generator.applyFeatures(54, -128, states);

    var lava_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:lava[level=0]"))
            lava_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 34), lava_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x73, 0xaf, 0xe4, 0xde, 0xa2, 0x77, 0xe7, 0xe8,
            0xcb, 0x7d, 0x0c, 0x49, 0x74, 0x51, 0xd7, 0x61,
            0x2b, 0x6f, 0xcc, 0x78, 0x5e, 0x95, 0x1d, 0x38,
            0x91, 0x45, 0x4e, 0x51, 0x48, 0x8e, 0xb3, 0xf6,
        },
        digest,
    );
}

test "ocean seagrass and kelp match Vanilla seed zero chunk" {
    var generator = try Generator.init(std.testing.allocator, 0);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(-250, -256, blocks);
    try generator.applySurface(-250, -256, blocks, states);
    try generator.applyCarvers(-250, -256, states);
    try generator.applyFeatures(-250, -256, states);

    var kelp_plant_count: usize = 0;
    var kelp_tip_count: usize = 0;
    var seagrass_count: usize = 0;
    var tall_seagrass_lower_count: usize = 0;
    var tall_seagrass_upper_count: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        if (std.mem.eql(u8, name, "minecraft:kelp_plant")) kelp_plant_count += 1;
        if (std.mem.startsWith(u8, name, "minecraft:kelp[age=")) kelp_tip_count += 1;
        if (std.mem.eql(u8, name, "minecraft:seagrass")) seagrass_count += 1;
        if (std.mem.eql(u8, name, "minecraft:tall_seagrass[half=lower]"))
            tall_seagrass_lower_count += 1;
        if (std.mem.eql(u8, name, "minecraft:tall_seagrass[half=upper]"))
            tall_seagrass_upper_count += 1;
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    try std.testing.expectEqual(@as(usize, 108), kelp_plant_count);
    try std.testing.expectEqual(@as(usize, 20), kelp_tip_count);
    try std.testing.expectEqual(@as(usize, 19), seagrass_count);
    try std.testing.expectEqual(@as(usize, 12), tall_seagrass_lower_count);
    try std.testing.expectEqual(@as(usize, 12), tall_seagrass_upper_count);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x06, 0xe5, 0x99, 0xb7, 0x9c, 0x84, 0x72, 0x64,
            0xf4, 0x7c, 0xd7, 0x4e, 0x18, 0xa3, 0x84, 0xac,
            0x2c, 0x76, 0x8c, 0x39, 0x91, 0x5c, 0x79, 0x4f,
            0x60, 0x60, 0x95, 0x0f, 0x34, 0x3f, 0x48, 0xc3,
        },
        digest,
    );
}

fn expectSurfaceHash(
    seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    expected: [32]u8,
) !void {
    var generator = try Generator.init(std.testing.allocator, seed);
    defer generator.deinit();
    const blocks = try std.testing.allocator.alloc(aquifer.Material, block_count);
    defer std.testing.allocator.free(blocks);
    const states = try std.testing.allocator.alloc(GeneratedState, block_count);
    defer std.testing.allocator.free(states);
    try generator.fillBaseMaterials(chunk_x, chunk_z, blocks);
    try generator.applySurface(chunk_x, chunk_z, blocks, states);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (states) |state| {
        const name = state.canonicalName();
        var length: [4]u8 = undefined;
        std.mem.writeInt(u32, &length, @intCast(name.len), .big);
        hash.update(&length);
        hash.update(name);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(expected, digest);
}
