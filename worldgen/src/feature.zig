const std = @import("std");
const biome = @import("biome.zig");
const biome_access = @import("biome_access.zig");
const biome_temperature = @import("biome_temperature.zig");
const climate = @import("climate.zig");
const density = @import("density.zig");
const generated_state = @import("generated_state.zig");
const worldgen_noise = @import("noise.zig");
const random = @import("random.zig");
const data = @import("feature_data");

const GeneratedState = generated_state.GeneratedState;
const ChunkRandom = random.ChunkRandom;
const flower_noise_0 = init: {
    @setEvalBranchQuota(100_000);
    break :init worldgen_noise.LegacyDoublePerlin.init(2345, 0);
};
const flower_noise_negative_3 = init: {
    @setEvalBranchQuota(100_000);
    break :init worldgen_noise.LegacyDoublePerlin.init(2345, -3);
};
const flower_noise_negative_10 = init: {
    @setEvalBranchQuota(100_000);
    break :init worldgen_noise.LegacyDoublePerlin.init(2345, -10);
};

pub const width = 16;
pub const minimum_y = density.ChunkInterpolator.minimum_y;
pub const height = density.ChunkInterpolator.height;
pub const block_count = width * width * height;
pub const height_halo_side = width * 3;
pub const HeightHalo = [height_halo_side * height_halo_side]i16;

pub const DecoratorRandom = struct {
    population_seed: u64,
    source: ChunkRandom,

    pub fn init(world_seed: u64, chunk_x: i32, chunk_z: i32) DecoratorRandom {
        const population_seed = ChunkRandom.populationSeed(
            world_seed,
            chunk_x * width,
            chunk_z * width,
        );
        return .{
            .population_seed = population_seed,
            .source = ChunkRandom.init(population_seed),
        };
    }

    fn begin(self: *DecoratorRandom, index: usize, step: usize) *ChunkRandom {
        self.source.reseed(random.decoratorSeed(self.population_seed, index, step));
        return &self.source;
    }
};

pub const Region = struct {
    center_chunk_x: i32,
    center_chunk_z: i32,
    chunks: [9][]GeneratedState,
    biome_cache: *biome.Cache,
    height_upper_bounds: ?*const HeightHalo = null,

    pub fn state(self: *Region, x: i32, y: i32, z: i32) ?*GeneratedState {
        @setRuntimeSafety(false);
        if (y < minimum_y or y >= minimum_y + height) return null;
        const halo_x = x - (self.center_chunk_x - 1) * width;
        const halo_z = z - (self.center_chunk_z - 1) * width;
        if (halo_x < 0 or halo_x >= 3 * width or halo_z < 0 or halo_z >= 3 * width) return null;
        const local_x: usize = @intCast(halo_x);
        const local_z: usize = @intCast(halo_z);
        const chunk_index = (local_z >> 4) * 3 + (local_x >> 4);
        return &self.chunks[chunk_index][blockIndex(@intCast(local_x & 15), y, @intCast(local_z & 15))];
    }

    pub fn stateConst(self: *const Region, x: i32, y: i32, z: i32) ?GeneratedState {
        @setRuntimeSafety(false);
        if (y < minimum_y or y >= minimum_y + height) return null;
        const halo_x = x - (self.center_chunk_x - 1) * width;
        const halo_z = z - (self.center_chunk_z - 1) * width;
        if (halo_x < 0 or halo_x >= 3 * width or halo_z < 0 or halo_z >= 3 * width) return null;
        const local_x: usize = @intCast(halo_x);
        const local_z: usize = @intCast(halo_z);
        const chunk_index = (local_z >> 4) * 3 + (local_x >> 4);
        return self.chunks[chunk_index][blockIndex(@intCast(local_x & 15), y, @intCast(local_z & 15))];
    }
};

pub const BiomePlan = struct {
    current: [biome.overworld_cell_count]u8,
    ore_mask: u64 = 0,
    disk_mask: u64 = 0,
    icebergs: u8 = 0,
    monster_rooms: u8 = 0,
    underwater_magma: bool = false,
    pointed_dripstone: bool = false,
    glow_lichen: bool = false,
    forest_flowers: bool = false,
    flower_forest_flowers: bool = false,
    cave_vines: bool = false,
    flower_patches: u16 = 0,
    tall_birch_trees: bool = false,
    birch_trees: bool = false,
    oak_leaf_litter_trees: bool = false,
    basic_tree_selectors: u64 = 0,
    mushroom_island_vegetation: bool = false,
    forest_grass: bool = false,
    fluid_springs: u8 = 0,
    noise_grass: u8 = 0,
    surface_patches: u64 = 0,
    near_water_patches: u8 = 0,
    seagrass: u8 = 0,
    kelp: u8 = 0,
    simple_features: u16 = 0,

    pub fn prepare(
        self: *BiomePlan,
        planner: *BiomePlanner,
        sampler: *const climate.Sampler,
        region: *Region,
        chunk_x: i32,
        chunk_z: i32,
    ) void {
        self.* = .{ .current = undefined };
        @memcpy(
            &self.current,
            region.biome_cache.chunk(sampler, chunk_x, chunk_z),
        );
        const center = planner.summary(
            sampler,
            region.biome_cache,
            chunk_x,
            chunk_z,
        );
        self.forest_flowers = center.forest_flowers;
        self.icebergs = center.icebergs;
        self.monster_rooms = center.monster_rooms;
        self.flower_forest_flowers = center.flower_forest_flowers;
        self.cave_vines = center.cave_vines;
        self.flower_patches = center.flower_patches;
        self.tall_birch_trees = center.tall_birch_trees;
        self.birch_trees = center.birch_trees;
        self.oak_leaf_litter_trees = center.oak_leaf_litter_trees;
        self.basic_tree_selectors = center.basic_tree_selectors;
        self.mushroom_island_vegetation = center.mushroom_island_vegetation;
        self.forest_grass = center.forest_grass;
        self.noise_grass = center.noise_grass;
        self.surface_patches = center.surface_patches;
        self.simple_features = center.simple_features;
        var z = chunk_z - 1;
        while (z <= chunk_z + 1) : (z += 1) {
            var x = chunk_x - 1;
            while (x <= chunk_x + 1) : (x += 1)
                self.includeNeighbor(planner.summary(
                    sampler,
                    region.biome_cache,
                    x,
                    z,
                ));
        }
    }

    fn includeNeighbor(self: *BiomePlan, summary: *const BiomeSummary) void {
        self.ore_mask |= summary.ore_mask;
        self.disk_mask |= summary.disk_mask;
        self.underwater_magma = self.underwater_magma or
            summary.underwater_magma;
        self.pointed_dripstone = self.pointed_dripstone or
            summary.pointed_dripstone;
        self.glow_lichen = self.glow_lichen or summary.glow_lichen;
        self.fluid_springs |= summary.fluid_springs;
        self.near_water_patches |= summary.near_water_patches;
        self.seagrass |= summary.seagrass;
        self.kelp |= summary.kelp;
    }
};

const BiomeSummary = struct {
    ore_mask: u64 = 0,
    disk_mask: u64 = 0,
    icebergs: u8 = 0,
    monster_rooms: u8 = 0,
    underwater_magma: bool = false,
    pointed_dripstone: bool = false,
    glow_lichen: bool = false,
    forest_flowers: bool = false,
    flower_forest_flowers: bool = false,
    cave_vines: bool = false,
    flower_patches: u16 = 0,
    tall_birch_trees: bool = false,
    birch_trees: bool = false,
    oak_leaf_litter_trees: bool = false,
    basic_tree_selectors: u64 = 0,
    mushroom_island_vegetation: bool = false,
    forest_grass: bool = false,
    fluid_springs: u8 = 0,
    noise_grass: u8 = 0,
    surface_patches: u64 = 0,
    near_water_patches: u8 = 0,
    seagrass: u8 = 0,
    kelp: u8 = 0,
    simple_features: u16 = 0,
};

pub const BiomePlanner = struct {
    const capacity = 2_048;
    const Entry = struct {
        valid: bool = false,
        x: i32 = 0,
        z: i32 = 0,
        summary: BiomeSummary = .{},
    };

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,

    pub fn clear(self: *BiomePlanner) void {
        @memset(&self.entries, .{});
    }

    fn summary(
        self: *BiomePlanner,
        sampler: *const climate.Sampler,
        cache: *biome.Cache,
        x: i32,
        z: i32,
    ) *const BiomeSummary {
        const key = @as(u64, @as(u32, @bitCast(x))) |
            (@as(u64, @as(u32, @bitCast(z))) << 32);
        const slot: usize = @intCast(random.staffordMix13(key) & (capacity - 1));
        const entry = &self.entries[slot];
        if (entry.valid and entry.x == x and entry.z == z) return &entry.summary;
        entry.* = .{ .valid = true, .x = x, .z = z };
        fill(&entry.summary, cache.chunk(sampler, x, z));
        return &entry.summary;
    }
};

fn fill(
    self: *BiomeSummary,
    cells: *const [biome.overworld_cell_count]u8,
) void {
    for (cells) |biome_index| {
        self.ore_mask |= data.biome_ore_masks[biome_index];
        self.disk_mask |= data.biome_disk_masks[biome_index];
        self.icebergs |= data.biome_iceberg_masks[biome_index];
        self.monster_rooms |= data.biome_monster_room_masks[biome_index];
        self.underwater_magma = self.underwater_magma or
            data.biome_underwater_magma[biome_index];
        self.pointed_dripstone = self.pointed_dripstone or
            data.biome_pointed_dripstone[biome_index];
        self.glow_lichen = self.glow_lichen or data.biome_glow_lichen[biome_index];
        self.forest_flowers = self.forest_flowers or data.biome_forest_flowers[biome_index];
        self.flower_forest_flowers = self.flower_forest_flowers or
            data.biome_flower_forest_flowers[biome_index];
        self.cave_vines = self.cave_vines or data.biome_cave_vines[biome_index];
        self.flower_patches |= data.biome_flower_patch_masks[biome_index];
        self.tall_birch_trees = self.tall_birch_trees or data.biome_tall_birch_trees[biome_index];
        self.birch_trees = self.birch_trees or data.biome_birch_trees[biome_index];
        self.oak_leaf_litter_trees = self.oak_leaf_litter_trees or
            data.biome_oak_leaf_litter_trees[biome_index];
        self.basic_tree_selectors |= data.biome_basic_tree_selector_masks[biome_index];
        self.mushroom_island_vegetation = self.mushroom_island_vegetation or
            data.biome_mushroom_island_vegetation[biome_index];
        self.forest_grass = self.forest_grass or data.biome_patch_grass_forest[biome_index];
        self.fluid_springs |= data.biome_fluid_spring_masks[biome_index];
        self.noise_grass |= data.biome_noise_grass_patch_masks[biome_index];
        self.surface_patches |= data.biome_surface_patch_masks[biome_index];
        self.near_water_patches |= data.biome_near_water_patch_masks[biome_index];
        self.seagrass |= data.biome_seagrass_masks[biome_index];
        self.kelp |= data.biome_kelp_masks[biome_index];
        self.simple_features |= data.biome_simple_feature_masks[biome_index];
    }
}

pub fn applyLavaLakes(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    world_surface: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const mixer_seed = biome_access.mixerSeed(world_seed);
    for (data.lava_lakes, 0..) |config, lake_index| {
        const source = decorator_random.begin(config.index, config.step);
        if (@as(f64, source.nextF32()) >=
            1.0 / @as(f64, @floatFromInt(config.rarity))) continue;
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        var y = switch (config.placement) {
            .underground => source.nextBoundedI32(minimum_y + height),
            .surface => heightHaloAt(world_surface, first_x, first_z, x, z),
        };
        if (config.placement == .underground) {
            var scanned: u8 = 0;
            while (scanned < config.max_scan) : (scanned += 1) {
                if (lakeScanTarget(region, x, y, z)) break;
                y -= 1;
                if (y < minimum_y) break;
            }
            if (!lakeScanTarget(region, x, y, z)) continue;
            if (y > heightHaloAt(ocean_floor, first_x, first_z, x, z) +
                config.surface_maximum) continue;
        }
        const origin: Position = .{ .x = x, .y = y, .z = z };
        const biome_index = jitteredBiomeIndex(
            mixer_seed,
            climate_sampler,
            region,
            origin,
        );
        const lake_bit = @as(u8, 1) << @intCast(lake_index);
        if (data.biome_lava_lake_masks[biome_index] & lake_bit == 0) continue;
        _ = generateLavaLake(source, region, config, origin);
    }
}

pub fn applyIcebergs(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.icebergs, 0..) |config, iceberg_index| {
        if (biomes.icebergs & (@as(u8, 1) << @intCast(iceberg_index)) == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        if (source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
        const origin = Position{
            .x = first_x + source.nextBoundedI32(width),
            .y = 63,
            .z = first_z + source.nextBoundedI32(width),
        };
        const biome_index = biomeAt(&biomes.current, origin.x - first_x, 0, origin.z - first_z);
        if (data.biome_iceberg_masks[biome_index] &
            (@as(u8, 1) << @intCast(iceberg_index)) == 0) continue;
        generateIceberg(source, region, origin, config.state);
    }
}

const IcebergShape = struct {
    snowy: bool,
    angle: f64,
    radius: i32,
    ellipse_radius: i32,
    elliptical: bool,
    height: i32,
    underwater_height: i32,
    underwater_radius: i32,
};

fn generateIceberg(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    state: u16,
) void {
    const shape = createIcebergShape(source);
    placeIcebergAbove(source, region, origin, state, shape);
    cleanIceberg(region, origin, shape);
    placeIcebergBelow(source, region, origin, state, shape);
    const carve = if (shape.elliptical) source.nextF64() > 0.1 else source.nextF64() > 0.7;
    if (carve) carveIceberg(source, region, origin, shape);
}

fn createIcebergShape(source: *ChunkRandom) IcebergShape {
    const snowy = source.nextF64() > 0.7;
    const angle = source.nextF64() * 2.0 * std.math.pi;
    const radius = 11 - source.nextBoundedI32(5);
    const ellipse_radius = 3 + source.nextBoundedI32(3);
    const elliptical = source.nextF64() > 0.7;
    var iceberg_height = if (elliptical)
        source.nextBoundedI32(6) + 6
    else
        source.nextBoundedI32(15) + 3;
    if (!elliptical and source.nextF64() > 0.9)
        iceberg_height += source.nextBoundedI32(19) + 7;
    return .{
        .snowy = snowy,
        .angle = angle,
        .radius = radius,
        .ellipse_radius = ellipse_radius,
        .elliptical = elliptical,
        .height = iceberg_height,
        .underwater_height = @min(iceberg_height + source.nextBoundedI32(11), 18),
        .underwater_radius = @min(
            iceberg_height + source.nextBoundedI32(7) - source.nextBoundedI32(5),
            11,
        ),
    };
}

fn placeIcebergAbove(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    state: u16,
    shape: IcebergShape,
) void {
    const span = if (shape.elliptical) shape.radius else 11;
    var dx = -span;
    while (dx < span) : (dx += 1) {
        var dz = -span;
        while (dz < span) : (dz += 1) {
            var dy: i32 = 0;
            while (dy < shape.height) : (dy += 1) {
                const radius = if (shape.elliptical)
                    icebergEllipticalRadius(dy, shape.height, shape.underwater_radius)
                else
                    icebergRoundRadius(source, dy, shape.height, shape.underwater_radius);
                if (shape.elliptical or dx < radius)
                    placeIcebergAt(source, region, origin, state, shape, dx, dy, dz, radius, span);
            }
        }
    }
}

fn placeIcebergBelow(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    state: u16,
    shape: IcebergShape,
) void {
    const span = if (shape.elliptical) shape.radius else 11;
    var dx = -span;
    while (dx < span) : (dx += 1) {
        var dz = -span;
        while (dz < span) : (dz += 1) {
            var dy: i32 = -1;
            while (dy > -shape.underwater_height) : (dy -= 1) {
                const outer = if (shape.elliptical)
                    icebergCeil(@as(f32, @floatFromInt(span)) *
                        (1.0 - @as(f32, @floatFromInt(dy * dy)) /
                            @as(f32, @floatFromInt(shape.underwater_height * 8))))
                else
                    span;
                const radius = icebergUnderwaterRadius(
                    source,
                    -dy,
                    shape.underwater_height,
                    shape.underwater_radius,
                );
                if (dx < radius)
                    placeIcebergAt(source, region, origin, state, shape, dx, dy, dz, radius, outer);
            }
        }
    }
}

fn placeIcebergAt(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    state: u16,
    shape: IcebergShape,
    dx: i32,
    dy: i32,
    dz: i32,
    radius: i32,
    outer: i32,
) void {
    const distance = if (shape.elliptical)
        icebergDistance(dx, dz, .{ .x = 0, .y = 0, .z = 0 }, outer, icebergTopRadius(dy, shape.height, shape.ellipse_radius), shape.angle)
    else
        icebergRoundDistance(source, dx, dz, radius);
    if (distance >= 0.0) return;
    const edge = if (shape.elliptical) -0.5 else @as(f64, @floatFromInt(-6 - source.nextBoundedI32(3)));
    if (distance > edge and source.nextF64() > 0.9) return;
    placeIcebergBlock(source, region, .{ .x = origin.x + dx, .y = origin.y + dy, .z = origin.z + dz }, state, shape, shape.height - dy);
}

fn placeIcebergBlock(
    source: *ChunkRandom,
    region: *Region,
    position: Position,
    state: u16,
    shape: IcebergShape,
    remaining: i32,
) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!isAir(target.*) and target.block() != .snow_block and
        target.block() != .ice and !isWater(target.*)) return;
    const snow_allowed = !shape.elliptical or source.nextF64() > 0.05;
    const divisor: i32 = if (shape.elliptical) 3 else 2;
    const snow_limit = @as(f64, @floatFromInt(source.nextBoundedI32(
        @max(1, @divTrunc(shape.height, divisor)),
    ))) +
        @as(f64, @floatFromInt(shape.height)) * 0.6;
    if (shape.snowy and !isWater(target.*) and
        @as(f64, @floatFromInt(remaining)) <= snow_limit and snow_allowed)
        target.* = GeneratedState.fromFeature(data.iceberg_states[4])
    else
        target.* = GeneratedState.fromFeature(state);
}

fn icebergTopRadius(y: i32, height_value: i32, radius: i32) i32 {
    if (y > 0 and height_value - y <= 3) return radius - (4 - (height_value - y));
    return radius;
}

fn icebergRoundDistance(source: *ChunkRandom, x: i32, z: i32, radius: i32) f64 {
    const scale: f32 = 10.0 * std.math.clamp(source.nextF32(), 0.2, 0.8) /
        @as(f32, @floatFromInt(radius));
    return @as(f64, scale) + squareF64(x) + squareF64(z) - squareF64(radius);
}

fn icebergDistance(
    x: i32,
    z: i32,
    center: Position,
    radius_x: i32,
    radius_z: i32,
    angle: f64,
) f64 {
    if (radius_x == 0 or radius_z == 0) return std.math.inf(f64);
    const dx = @as(f64, @floatFromInt(x - center.x));
    const dz = @as(f64, @floatFromInt(z - center.z));
    const cosine = @cos(angle);
    const sine = @sin(angle);
    const first = (dx * cosine - dz * sine) / @as(f64, @floatFromInt(radius_x));
    const second = (dx * sine + dz * cosine) / @as(f64, @floatFromInt(radius_z));
    return first * first + second * second - 1.0;
}

fn icebergRoundRadius(source: *ChunkRandom, y: i32, height_value: i32, factor: i32) i32 {
    const scale: f32 = 3.5 - source.nextF32();
    var value = (1.0 - @as(f32, @floatFromInt(y * y)) /
        @as(f32, @floatFromInt(height_value)) / scale) * @as(f32, @floatFromInt(factor));
    if (height_value > 15 + source.nextBoundedI32(5)) {
        const adjusted = if (y < 3 + source.nextBoundedI32(6)) @divTrunc(y, 2) else y;
        value = (1.0 - @as(f32, @floatFromInt(adjusted)) /
            (@as(f32, @floatFromInt(height_value)) * scale * 0.4)) *
            @as(f32, @floatFromInt(factor));
    }
    return icebergCeil(value / 2.0);
}

fn icebergEllipticalRadius(y: i32, height_value: i32, factor: i32) i32 {
    const value = (1.0 - @as(f32, @floatFromInt(y * y)) /
        @as(f32, @floatFromInt(height_value))) * @as(f32, @floatFromInt(factor));
    return icebergCeil(value / 2.0);
}

fn icebergUnderwaterRadius(source: *ChunkRandom, y: i32, height_value: i32, factor: i32) i32 {
    const scale = 1.0 + source.nextF32() / 2.0;
    const value = (1.0 - @as(f32, @floatFromInt(y)) /
        (@as(f32, @floatFromInt(height_value)) * scale)) *
        @as(f32, @floatFromInt(factor));
    return icebergCeil(value / 2.0);
}

fn icebergCeil(value: f32) i32 {
    return @intFromFloat(@ceil(value));
}

fn squareF64(value: i32) f64 {
    const converted = @as(f64, @floatFromInt(value));
    return converted * converted;
}

fn cleanIceberg(region: *Region, origin: Position, shape: IcebergShape) void {
    const radius = if (shape.elliptical) shape.radius else @divTrunc(shape.underwater_radius, 2);
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            var dy: i32 = 0;
            while (dy <= shape.height) : (dy += 1)
                cleanIcebergBlock(region, .{ .x = origin.x + dx, .y = origin.y + dy, .z = origin.z + dz });
        }
    }
}

fn cleanIcebergBlock(region: *Region, position: Position) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!isIcebergMaterial(target.*) and target.block() != .snow) return;
    const below = region.state(position.x, position.y - 1, position.z);
    if (below != null and isAir(below.?.*)) {
        target.* = .air;
        if (region.state(position.x, position.y + 1, position.z)) |above| above.* = .air;
        return;
    }
    if (!isIcebergMaterial(target.*)) return;
    var exposed: u8 = 0;
    for ([_]Direction{ .west, .east, .north, .south }) |direction| {
        const neighbor = offsetPosition(position, direction, 1);
        const state = region.state(neighbor.x, neighbor.y, neighbor.z) orelse continue;
        exposed += @intFromBool(!isIcebergMaterial(state.*));
    }
    if (exposed >= 3) target.* = .air;
}

fn isIcebergMaterial(state: GeneratedState) bool {
    return state.block() == .packed_ice or state.block() == .snow_block or
        state.block() == .blue_ice;
}

fn carveIceberg(source: *ChunkRandom, region: *Region, origin: Position, shape: IcebergShape) void {
    const sign_x: i32 = if (source.nextBool()) -1 else 1;
    const sign_z: i32 = if (source.nextBool()) -1 else 1;
    var offset_x = source.nextBoundedI32(@max(@divTrunc(shape.underwater_radius, 2) - 2, 1));
    if (source.nextBool()) offset_x = @divTrunc(shape.underwater_radius, 2) + 1 -
        source.nextBoundedI32(@max(shape.underwater_radius - @divTrunc(shape.underwater_radius, 2) - 1, 1));
    var offset_z = source.nextBoundedI32(@max(@divTrunc(shape.underwater_radius, 2) - 2, 1));
    if (source.nextBool()) offset_z = @divTrunc(shape.underwater_radius, 2) + 1 -
        source.nextBoundedI32(@max(shape.underwater_radius - @divTrunc(shape.underwater_radius, 2) - 1, 1));
    if (shape.elliptical)
        offset_x = source.nextBoundedI32(@max(shape.radius - 5, 1));
    if (shape.elliptical) offset_z = offset_x;
    const center = Position{
        .x = sign_x * offset_x,
        .y = 0,
        .z = sign_z * offset_z,
    };
    const angle = if (shape.elliptical) shape.angle + std.math.pi / 2.0 else source.nextF64() * 2.0 * std.math.pi;
    carveIcebergLayers(source, region, origin, shape, center, angle, false);
    carveIcebergLayers(source, region, origin, shape, center, angle, true);
}

fn carveIcebergLayers(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    shape: IcebergShape,
    center: Position,
    angle: f64,
    underwater: bool,
) void {
    var y: i32 = if (underwater) -1 else 0;
    while (true) : (y += if (underwater) -1 else 1) {
        if (underwater) {
            if (y <= -shape.height + source.nextBoundedI32(5)) break;
        } else if (y >= shape.height - 3) break;
        const radius = if (underwater)
            icebergUnderwaterRadius(source, -y, shape.height, shape.underwater_radius)
        else
            icebergRoundRadius(source, y, shape.height, shape.underwater_radius);
        carveIcebergLayer(region, origin, center, angle, shape, radius, y, underwater);
    }
}

fn carveIcebergLayer(
    region: *Region,
    origin: Position,
    center: Position,
    angle: f64,
    shape: IcebergShape,
    radius: i32,
    y: i32,
    water: bool,
) void {
    const span = radius + 1 + @divTrunc(shape.radius, 3);
    const second = @min(radius - 3, 3) + @divTrunc(shape.ellipse_radius, 2) - 1;
    var dx = -span;
    while (dx < span) : (dx += 1) {
        var dz = -span;
        while (dz < span) : (dz += 1) {
            if (icebergDistance(dx, dz, center, span, second, angle) >= 0.0) continue;
            const target = region.state(origin.x + dx, origin.y + y, origin.z + dz) orelse continue;
            if (!isIcebergMaterial(target.*) and target.block() != .snow_block) continue;
            target.* = if (water) GeneratedState.fromFeature(data.iceberg_states[1]) else .air;
            if (!water) {
                if (region.state(origin.x + dx, origin.y + y + 1, origin.z + dz)) |above| {
                    if (above.block() == .snow) above.* = .air;
                }
            }
        }
    }
}

pub fn applyMonsterRooms(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.monster_rooms, 0..) |config, room_index| {
        if (biomes.monster_rooms & (@as(u8, 1) << @intCast(room_index)) == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        for (0..config.count) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const y = @as(i32, config.height_minimum) + source.nextBoundedI32(
                @as(i32, config.height_maximum) - config.height_minimum + 1,
            );
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_monster_room_masks[biome_index] &
                (@as(u8, 1) << @intCast(room_index)) == 0) continue;
            _ = generateMonsterRoom(source, region, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn generateMonsterRoom(source: *ChunkRandom, region: *Region, origin: Position) bool {
    const radius_x = source.nextBoundedI32(2) + 2;
    const radius_z = source.nextBoundedI32(2) + 2;
    if (!monsterRoomShellValid(region, origin, radius_x, radius_z)) return false;
    carveMonsterRoom(source, region, origin, radius_x, radius_z);
    placeMonsterRoomChests(source, region, origin, radius_x, radius_z);
    const spawner = region.state(origin.x, origin.y, origin.z) orelse return true;
    if (canDungeonReplace(spawner.*))
        spawner.* = GeneratedState.fromFeature(data.monster_room_states[3]);
    _ = source.nextBoundedI32(4);
    return true;
}

fn monsterRoomShellValid(
    region: *Region,
    origin: Position,
    radius_x: i32,
    radius_z: i32,
) bool {
    var openings: u8 = 0;
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dy: i32 = -1;
        while (dy <= 4) : (dy += 1) {
            var dz = -radius_z - 1;
            while (dz <= radius_z + 1) : (dz += 1) {
                const state = region.state(origin.x + dx, origin.y + dy, origin.z + dz) orelse
                    return false;
                if ((dy == -1 or dy == 4) and !isOpaqueFullCube(state.*)) return false;
                const wall = dx == -radius_x - 1 or dx == radius_x + 1 or
                    dz == -radius_z - 1 or dz == radius_z + 1;
                if (!wall or dy != 0 or !isAir(state.*)) continue;
                const above = region.state(origin.x + dx, origin.y + 1, origin.z + dz) orelse
                    return false;
                if (isAir(above.*)) openings += 1;
            }
        }
    }
    return openings >= 1 and openings <= 5;
}

fn carveMonsterRoom(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    radius_x: i32,
    radius_z: i32,
) void {
    var dx = -radius_x - 1;
    while (dx <= radius_x + 1) : (dx += 1) {
        var dy: i32 = 3;
        while (dy >= -1) : (dy -= 1) {
            var dz = -radius_z - 1;
            while (dz <= radius_z + 1) : (dz += 1) {
                const target = region.state(origin.x + dx, origin.y + dy, origin.z + dz) orelse
                    continue;
                if (!canDungeonReplace(target.*)) continue;
                const boundary = dx == -radius_x - 1 or dx == radius_x + 1 or
                    dz == -radius_z - 1 or dz == radius_z + 1 or dy == -1;
                if (!boundary) {
                    if (target.block() != .chest and target.block() != .spawner)
                        target.* = GeneratedState.fromFeature(data.monster_room_states[0]);
                    continue;
                }
                const below = region.state(origin.x + dx, origin.y + dy - 1, origin.z + dz);
                if (below == null or !isOpaqueFullCube(below.?.*)) {
                    target.* = GeneratedState.fromFeature(data.monster_room_states[0]);
                } else if (isOpaqueFullCube(target.*) and target.block() != .chest) {
                    const state = if (dy == -1 and source.nextBoundedI32(4) != 0)
                        data.monster_room_states[2]
                    else
                        data.monster_room_states[1];
                    target.* = GeneratedState.fromFeature(state);
                }
            }
        }
    }
}

fn placeMonsterRoomChests(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    radius_x: i32,
    radius_z: i32,
) void {
    for (0..2) |_| {
        for (0..3) |_| {
            const position = Position{
                .x = origin.x + source.nextBoundedI32(radius_x * 2 + 1) - radius_x,
                .y = origin.y,
                .z = origin.z + source.nextBoundedI32(radius_z * 2 + 1) - radius_z,
            };
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!isAir(target.*)) continue;
            const facing = dungeonChestFacing(region, position) orelse continue;
            target.* = GeneratedState.fromFeature(data.monster_room_states[4 + facing]);
            _ = source.nextI64();
            break;
        }
    }
}

fn dungeonChestFacing(region: *Region, position: Position) ?usize {
    const directions = [_]Direction{ .north, .east, .south, .west };
    var solid_count: u8 = 0;
    var solid_direction: usize = 0;
    for (directions, 0..) |direction, index| {
        const neighbor = offsetPosition(position, direction, 1);
        const state = region.state(neighbor.x, neighbor.y, neighbor.z) orelse continue;
        if (!isOpaqueFullCube(state.*)) continue;
        solid_count += 1;
        solid_direction = index;
    }
    if (solid_count != 1) return null;
    return (solid_direction + 2) & 3;
}

fn canDungeonReplace(state: GeneratedState) bool {
    return state.block() != .bedrock and state.block() != .barrier;
}

fn lakeScanTarget(region: *Region, x: i32, y: i32, z: i32) bool {
    if (y - 5 < minimum_y or y - 5 >= minimum_y + height) return false;
    const state = region.state(x, y, z) orelse return false;
    return !isAir(state.*);
}

fn generateLavaLake(
    source: *ChunkRandom,
    region: *Region,
    config: data.LavaLake,
    placement_origin: Position,
) bool {
    if (placement_origin.y <= minimum_y + 4) return false;
    const origin = addPosition(placement_origin, .{ .x = 0, .y = -4, .z = 0 });
    var cavity: [16 * 16 * 8]bool = @splat(false);
    buildLakeCavity(source, &cavity);
    if (!validateLakeCavity(region, config, origin, &cavity)) return false;
    const placed = fillLakeCavity(region, config, origin, &cavity);
    sealLakeCavity(source, region, config, origin, &cavity);
    return placed;
}

fn buildLakeCavity(source: *ChunkRandom, cavity: *[16 * 16 * 8]bool) void {
    const ellipsoid_count = 4 + source.nextBoundedI32(4);
    for (0..@intCast(ellipsoid_count)) |_| {
        const size_x = source.nextF64() * 6.0 + 3.0;
        const size_y = source.nextF64() * 4.0 + 2.0;
        const size_z = source.nextF64() * 6.0 + 3.0;
        const center_x = source.nextF64() * (16.0 - size_x - 2.0) + 1.0 + size_x / 2.0;
        const center_y = source.nextF64() * (8.0 - size_y - 4.0) + 2.0 + size_y / 2.0;
        const center_z = source.nextF64() * (16.0 - size_z - 2.0) + 1.0 + size_z / 2.0;
        for (1..15) |local_x| {
            for (1..15) |local_z| {
                for (1..7) |local_y| {
                    const dx = (@as(f64, @floatFromInt(local_x)) - center_x) / (size_x / 2.0);
                    const dy = (@as(f64, @floatFromInt(local_y)) - center_y) / (size_y / 2.0);
                    const dz = (@as(f64, @floatFromInt(local_z)) - center_z) / (size_z / 2.0);
                    if (dx * dx + dy * dy + dz * dz < 1.0)
                        cavity.*[lakeIndex(local_x, local_y, local_z)] = true;
                }
            }
        }
    }
}

fn validateLakeCavity(region: *Region, config: data.LavaLake, origin: Position, cavity: *const [16 * 16 * 8]bool) bool {
    for (0..16) |local_x| {
        for (0..16) |local_z| {
            for (0..8) |local_y| {
                if (!lakeBoundary(cavity, local_x, local_y, local_z)) continue;
                const target = region.state(
                    origin.x + @as(i32, @intCast(local_x)),
                    origin.y + @as(i32, @intCast(local_y)),
                    origin.z + @as(i32, @intCast(local_z)),
                ) orelse return false;
                if (local_y >= 4) {
                    if (isWater(target.*) or isLava(target.*)) return false;
                } else if (!isLakeSolid(target.*) and
                    target.featureIndex() != config.fluid)
                {
                    return false;
                }
            }
        }
    }
    return true;
}

fn fillLakeCavity(region: *Region, config: data.LavaLake, origin: Position, cavity: *const [16 * 16 * 8]bool) bool {
    var placed = false;
    for (0..16) |local_x| {
        for (0..16) |local_z| {
            for (0..8) |local_y| {
                if (!cavity.*[lakeIndex(local_x, local_y, local_z)]) continue;
                const target = region.state(
                    origin.x + @as(i32, @intCast(local_x)),
                    origin.y + @as(i32, @intCast(local_y)),
                    origin.z + @as(i32, @intCast(local_z)),
                ) orelse continue;
                if (!lakeCanReplace(target.*)) continue;
                target.* = GeneratedState.fromFeature(if (local_y >= 4) config.air else config.fluid);
                placed = true;
            }
        }
    }
    return placed;
}

fn sealLakeCavity(source: *ChunkRandom, region: *Region, config: data.LavaLake, origin: Position, cavity: *const [16 * 16 * 8]bool) void {
    for (0..16) |local_x| {
        for (0..16) |local_z| {
            for (0..8) |local_y| {
                if (!lakeBoundary(cavity, local_x, local_y, local_z)) continue;
                if (local_y >= 4 and source.nextBoundedI32(2) == 0) continue;
                const target = region.state(
                    origin.x + @as(i32, @intCast(local_x)),
                    origin.y + @as(i32, @intCast(local_y)),
                    origin.z + @as(i32, @intCast(local_z)),
                ) orelse continue;
                if (!isLakeSolid(target.*) or lakeBarrierCannotReplace(target.*)) continue;
                target.* = GeneratedState.fromFeature(config.barrier);
            }
        }
    }
}

fn lakeIndex(x: usize, y: usize, z: usize) usize {
    return (x * 16 + z) * 8 + y;
}

fn lakeBoundary(cavity: *const [16 * 16 * 8]bool, x: usize, y: usize, z: usize) bool {
    if (cavity[lakeIndex(x, y, z)]) return false;
    return (x < 15 and cavity[lakeIndex(x + 1, y, z)]) or
        (x > 0 and cavity[lakeIndex(x - 1, y, z)]) or
        (z < 15 and cavity[lakeIndex(x, y, z + 1)]) or
        (z > 0 and cavity[lakeIndex(x, y, z - 1)]) or
        (y < 7 and cavity[lakeIndex(x, y + 1, z)]) or
        (y > 0 and cavity[lakeIndex(x, y - 1, z)]);
}

fn lakeCanReplace(state: GeneratedState) bool {
    return featureCanReplace(state);
}

fn lakeBarrierCannotReplace(state: GeneratedState) bool {
    return !featureCanReplace(state) or state.isLogOrLeaves();
}

fn featureCanReplace(state: GeneratedState) bool {
    return !state.nameEquals("minecraft:bedrock") and
        !state.nameEquals("minecraft:spawner") and
        state.block() != .chest and
        state.block() != .end_portal_frame and
        !state.nameEquals("minecraft:reinforced_deepslate") and
        state.block() != .trial_spawner and
        state.block() != .vault;
}

fn isLakeSolid(state: GeneratedState) bool {
    if (isAir(state) or isWater(state) or isLava(state)) return false;
    return !state.nameEquals("minecraft:cave_air") and
        !state.nameEquals("minecraft:powder_snow") and
        state.block() != .snow;
}

pub fn applyUndergroundFeatures(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) !void {
    try applyOres(
        chunk_x,
        chunk_z,
        biomes,
        ocean_floor,
        decorator_random,
        region,
        0,
        26,
    );
    applyUnderwaterMagma(
        chunk_x,
        chunk_z,
        biomes,
        ocean_floor,
        decorator_random,
        region,
    );
    try applyOres(
        chunk_x,
        chunk_z,
        biomes,
        ocean_floor,
        decorator_random,
        region,
        27,
        29,
    );
    applyDisks(
        chunk_x,
        chunk_z,
        biomes,
        ocean_floor,
        decorator_random,
        region,
    );
    try applyOres(
        chunk_x,
        chunk_z,
        biomes,
        ocean_floor,
        decorator_random,
        region,
        33,
        34,
    );
}

const UndergroundBiomes = BiomePlan;

pub fn applyPointedDripstone(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    if (!biomes.pointed_dripstone) return;

    const config = data.pointed_dripstone;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const count = @as(u16, config.count_minimum) + @as(u16, @intCast(
        source.nextBoundedI32(
            @as(i32, config.count_maximum - config.count_minimum) + 1,
        ),
    ));
    const mixer_seed = biome_access.mixerSeed(world_seed);
    for (0..count) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = sampleHeight(source, config.height);
        const repetitions = config.repetitions_minimum +
            @as(u8, @intCast(source.nextBoundedI32(
                @as(i32, config.repetitions_maximum - config.repetitions_minimum) + 1,
            )));
        for (0..repetitions) |_| {
            const candidate: Position = .{
                .x = x + clampedNormalInt(
                    source,
                    config.xz_mean,
                    config.xz_deviation,
                    config.xz_minimum,
                    config.xz_maximum,
                ),
                .y = y + clampedNormalInt(
                    source,
                    config.y_mean,
                    config.y_deviation,
                    config.y_minimum,
                    config.y_maximum,
                ),
                .z = z + clampedNormalInt(
                    source,
                    config.xz_mean,
                    config.xz_deviation,
                    config.xz_minimum,
                    config.xz_maximum,
                ),
            };
            const candidate_biome = jitteredBiomeIndex(
                mixer_seed,
                climate_sampler,
                region,
                candidate,
            );
            if (!data.biome_pointed_dripstone[candidate_biome]) continue;
            const direction: Direction = if (source.nextBoundedI32(2) == 0) .down else .up;
            const support = scanForSolid(region, candidate, direction, config.search_range) orelse
                continue;
            const origin = addPosition(support, direction.opposite().offset());
            generateSmallDripstone(source, region, config, origin);
        }
    }
}

pub fn applyLargeDripstone(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) usize {
    if (!biomes.pointed_dripstone) return 0;

    const config = data.large_dripstone;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const count = config.count_minimum + @as(u8, @intCast(source.nextBoundedI32(
        @as(i32, config.count_maximum - config.count_minimum) + 1,
    )));
    const mixer_seed = biome_access.mixerSeed(world_seed);
    var placed: usize = 0;
    for (0..count) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const origin: Position = .{
            .x = x,
            .y = sampleHeight(source, config.height),
            .z = z,
        };
        const biome_index = jitteredBiomeIndex(
            mixer_seed,
            climate_sampler,
            region,
            origin,
        );
        if (!data.biome_pointed_dripstone[biome_index]) continue;
        placed += generateLargeDripstone(source, region, config, origin);
    }
    return placed;
}

pub fn applyAmethystGeodes(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    decorator_random: *DecoratorRandom,
    region: *Region,
) usize {
    const config = data.amethyst_geode;
    const source = decorator_random.begin(config.index, config.step);
    if (@as(f64, source.nextF32()) >= 1.0 / @as(f64, @floatFromInt(config.rarity)))
        return 0;
    const x = chunk_x * width + source.nextBoundedI32(width);
    const z = chunk_z * width + source.nextBoundedI32(width);
    const origin: Position = .{ .x = x, .y = sampleHeight(source, config.height), .z = z };
    return generateAmethystGeode(source, region, config, world_seed, origin);
}

const GeodePoint = struct {
    position: Position,
    offset: i32,
};

const GeodeShape = struct {
    points: [4]GeodePoint = undefined,
    point_count: usize,
    crack_points: [3]Position = undefined,
    crack_point_count: usize = 0,
    filling_threshold: f64,
    inner_threshold: f64,
    middle_threshold: f64,
    outer_threshold: f64,
    crack_threshold: f64,
    generate_crack: bool,
};

const GeodeValues = struct {
    layer: f64,
    crack: f64,
};

fn generateAmethystGeode(
    source: *ChunkRandom,
    region: *Region,
    config: data.AmethystGeode,
    world_seed: u64,
    origin: Position,
) usize {
    const point_count = @as(usize, config.distribution_points[0]) + @as(usize, @intCast(
        source.nextBoundedI32(
            @as(i32, config.distribution_points[1] - config.distribution_points[0]) + 1,
        ),
    ));
    const point_density = @as(f64, @floatFromInt(point_count)) /
        @as(f64, @floatFromInt(config.outer_wall_distance[1]));
    var shape = GeodeShape{
        .point_count = point_count,
        .filling_threshold = 1.0 / @sqrt(config.layer_thickness[0]),
        .inner_threshold = 1.0 / @sqrt(config.layer_thickness[1] + point_density),
        .middle_threshold = 1.0 / @sqrt(config.layer_thickness[2] + point_density),
        .outer_threshold = 1.0 / @sqrt(config.layer_thickness[3] + point_density),
        .crack_threshold = 1.0 / @sqrt(config.base_crack_size + source.nextF64() / 2.0 +
            if (point_count > 3) point_density else 0),
        .generate_crack = @as(f64, source.nextF32()) < config.crack_chance,
    };
    if (!prepareGeodeShape(source, region, config, origin, &shape)) return 0;
    var geode_noise = worldgen_noise.LegacyDoublePerlin.init(@bitCast(world_seed), -4);
    return fillGeode(source, region, config, origin, &shape, &geode_noise);
}

fn prepareGeodeShape(source: *ChunkRandom, region: *Region, config: data.AmethystGeode, origin: Position, shape: *GeodeShape) bool {
    var invalid_blocks: u8 = 0;
    for (shape.points[0..shape.point_count]) |*point| {
        point.* = .{
            .position = addPosition(origin, .{
                .x = uniformI32(source, config.outer_wall_distance),
                .y = uniformI32(source, config.outer_wall_distance),
                .z = uniformI32(source, config.outer_wall_distance),
            }),
            .offset = uniformI32(source, config.point_offset),
        };
        const state = region.state(point.position.x, point.position.y, point.position.z) orelse return false;
        invalid_blocks += @intFromBool(isAir(state.*) or geodeInvalidBlock(state.*));
        if (invalid_blocks > config.invalid_blocks_threshold) return false;
    }
    if (!shape.generate_crack) return true;
    shape.crack_points = geodeCrackPoints(source.nextBoundedI32(4), origin, @intCast(shape.point_count * 2 + 1));
    shape.crack_point_count = shape.crack_points.len;
    return true;
}

fn geodeCrackPoints(orientation: i32, origin: Position, extent: i32) [3]Position {
    const horizontal: Position = switch (orientation) {
        0 => .{ .x = extent, .y = 0, .z = 0 },
        1 => .{ .x = 0, .y = 0, .z = extent },
        2 => .{ .x = extent, .y = 0, .z = extent },
        else => .{ .x = 0, .y = 0, .z = 0 },
    };
    return .{
        addPosition(origin, addPosition(horizontal, .{ .x = 0, .y = 7, .z = 0 })),
        addPosition(origin, addPosition(horizontal, .{ .x = 0, .y = 5, .z = 0 })),
        addPosition(origin, addPosition(horizontal, .{ .x = 0, .y = 1, .z = 0 })),
    };
}

fn fillGeode(source: *ChunkRandom, region: *Region, config: data.AmethystGeode, origin: Position, shape: *const GeodeShape, noise: *worldgen_noise.LegacyDoublePerlin) usize {
    const generation_side: usize = @intCast(
        data.amethyst_geode.maximum_generation_offset -
            data.amethyst_geode.minimum_generation_offset + 1,
    );
    const generation_volume = generation_side * generation_side * generation_side;
    var potential_placements: [generation_volume]Position = undefined;
    var potential_count: usize = 0;
    var placed: usize = 0;
    var z = origin.z + config.minimum_generation_offset;
    while (z <= origin.z + config.maximum_generation_offset) : (z += 1) {
        var y = origin.y + config.minimum_generation_offset;
        while (y <= origin.y + config.maximum_generation_offset) : (y += 1) {
            var x = origin.x + config.minimum_generation_offset;
            while (x <= origin.x + config.maximum_generation_offset) : (x += 1) {
                const position: Position = .{ .x = x, .y = y, .z = z };
                const noise_value = noise.sample(
                    @floatFromInt(x),
                    @floatFromInt(y),
                    @floatFromInt(z),
                ) * config.noise_multiplier;
                const values = geodeValues(config, shape, position, noise_value);
                if (values.layer < shape.outer_threshold) continue;
                const target = region.state(x, y, z) orelse continue;
                placed += placeGeodeLayer(source, config, shape, values, target, position, &potential_placements, &potential_count);
            }
        }
    }

    placed += placeGeodeBuds(source, region, config, potential_placements[0..potential_count]);
    return placed;
}

fn geodeValues(config: data.AmethystGeode, shape: *const GeodeShape, position: Position, noise_value: f64) GeodeValues {
    var result = GeodeValues{ .layer = 0, .crack = 0 };
    for (shape.points[0..shape.point_count]) |point|
        result.layer += 1.0 / @sqrt(squaredDistance(position, point.position) + @as(f64, @floatFromInt(point.offset))) + noise_value;
    for (shape.crack_points[0..shape.crack_point_count]) |point|
        result.crack += 1.0 / @sqrt(squaredDistance(position, point) + @as(f64, @floatFromInt(config.crack_point_offset))) + noise_value;
    return result;
}

fn placeGeodeLayer(source: *ChunkRandom, config: data.AmethystGeode, shape: *const GeodeShape, values: GeodeValues, target: *GeneratedState, position: Position, potentials: []Position, potential_count: *usize) usize {
    if ((shape.generate_crack and values.crack >= shape.crack_threshold and values.layer < shape.filling_threshold) or
        values.layer >= shape.filling_threshold)
    {
        if (!featureCanReplace(target.*)) return 0;
        target.* = GeneratedState.fromBase(.air);
        return 1;
    } else if (values.layer >= shape.inner_threshold) {
        const alternate = @as(f64, source.nextF32()) < config.alternate_inner_layer_chance;
        const replaced = featureCanReplace(target.*);
        if (replaced)
            target.* = GeneratedState.fromFeature(if (alternate) config.alternate_inner_layer_state else config.inner_layer_state);
        if ((!config.placements_require_alternate or alternate) and
            @as(f64, source.nextF32()) < config.potential_placement_chance)
        {
            std.debug.assert(potential_count.* < potentials.len);
            potentials[potential_count.*] = position;
            potential_count.* += 1;
        }
        return @intFromBool(replaced);
    } else if (values.layer >= shape.middle_threshold) {
        if (!featureCanReplace(target.*)) return 0;
        target.* = GeneratedState.fromFeature(config.middle_layer_state);
    } else {
        if (!featureCanReplace(target.*)) return 0;
        target.* = GeneratedState.fromFeature(config.outer_layer_state);
    }
    return 1;
}

fn placeGeodeBuds(source: *ChunkRandom, region: *Region, config: data.AmethystGeode, potentials: []const Position) usize {
    const directions = [_]Direction{ .down, .up, .north, .south, .west, .east };
    var placed: usize = 0;
    for (potentials) |position| {
        const placement_index: usize = @intCast(source.nextBoundedI32(4));
        for (directions, 0..) |direction, direction_index| {
            const target_position = addPosition(position, direction.offset());
            const target = region.state(
                target_position.x,
                target_position.y,
                target_position.z,
            ) orelse continue;
            if (!isAir(target.*) and !isWater(target.*)) continue;
            const waterlogged: usize = @intFromBool(isWater(target.*));
            if (featureCanReplace(target.*)) {
                target.* = GeneratedState.fromFeature(
                    config.inner_placements[placement_index][direction_index][waterlogged],
                );
                placed += 1;
            }
            break;
        }
    }
    return placed;
}

fn uniformI32(source: *ChunkRandom, range: [2]u8) i32 {
    return @as(i32, range[0]) +
        source.nextBoundedI32(@as(i32, range[1] - range[0]) + 1);
}

fn squaredDistance(a: Position, b: Position) f64 {
    const x: f64 = @floatFromInt(a.x - b.x);
    const y: f64 = @floatFromInt(a.y - b.y);
    const z: f64 = @floatFromInt(a.z - b.z);
    return x * x + y * y + z * z;
}

fn geodeInvalidBlock(state: GeneratedState) bool {
    return state.nameEquals("minecraft:bedrock") or
        isWater(state) or isLava(state) or
        state.nameEquals("minecraft:ice") or
        state.nameEquals("minecraft:packed_ice") or
        state.nameEquals("minecraft:blue_ice");
}

pub fn applyDripstoneClusters(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    if (!biomes.pointed_dripstone) return;

    const config = data.dripstone_cluster;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const count = config.count_minimum + @as(u8, @intCast(source.nextBoundedI32(
        @as(i32, config.count_maximum - config.count_minimum) + 1,
    )));
    const mixer_seed = biome_access.mixerSeed(world_seed);
    for (0..count) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const origin: Position = .{
            .x = x,
            .y = sampleHeight(source, config.height),
            .z = z,
        };
        const biome_index = jitteredBiomeIndex(
            mixer_seed,
            climate_sampler,
            region,
            origin,
        );
        if (!data.biome_pointed_dripstone[biome_index]) continue;
        generateDripstoneCluster(source, region, config, origin);
    }
}

const CaveSurface = struct {
    ceiling: ?i32,
    floor: ?i32,
};

const LargeDripstoneWind = struct {
    reference_y: i32 = 0,
    x: f64 = 0,
    z: f64 = 0,
    enabled: bool = false,

    fn sample(
        source: *ChunkRandom,
        config: data.LargeDripstone,
        reference_y: i32,
    ) LargeDripstoneWind {
        const speed = uniformF32(source, config.wind_speed);
        const angle = source.nextF32() * @as(f32, std.math.pi);
        return .{
            .reference_y = reference_y,
            .x = @as(f64, largeDripstoneCos(angle) * speed),
            .z = @as(f64, largeDripstoneSin(angle) * speed),
            .enabled = true,
        };
    }

    fn modify(self: LargeDripstoneWind, position: Position) Position {
        if (!self.enabled) return position;
        const delta_y: f64 = @floatFromInt(self.reference_y - position.y);
        return .{
            .x = position.x + @as(i32, @intFromFloat(@floor(self.x * delta_y))),
            .y = position.y,
            .z = position.z + @as(i32, @intFromFloat(@floor(self.z * delta_y))),
        };
    }
};

const LargeDripstoneGenerator = struct {
    position: Position,
    stalagmite: bool,
    scale: i32,
    bluntness: f64,
    height_scale: f64,

    fn init(
        source: *ChunkRandom,
        position: Position,
        stalagmite: bool,
        scale: i32,
        bluntness: [2]f32,
        height_scale: [2]f32,
    ) LargeDripstoneGenerator {
        return .{
            .position = position,
            .stalagmite = stalagmite,
            .scale = scale,
            .bluntness = uniformF32(source, bluntness),
            .height_scale = uniformF32(source, height_scale),
        };
    }

    fn windEligible(self: LargeDripstoneGenerator, config: data.LargeDripstone) bool {
        return self.scale >= config.minimum_radius_for_wind and
            self.bluntness >= config.minimum_bluntness_for_wind;
    }

    fn baseScale(self: LargeDripstoneGenerator) i32 {
        return self.columnHeight(0);
    }

    fn columnHeight(self: LargeDripstoneGenerator, radius: f32) i32 {
        return @intFromFloat(scaleLargeDripstoneHeight(
            @floatCast(radius),
            @floatFromInt(self.scale),
            self.height_scale,
            self.bluntness,
        ));
    }

    fn findBase(
        self: *LargeDripstoneGenerator,
        region: *Region,
        wind: LargeDripstoneWind,
    ) bool {
        while (self.scale > 1) {
            var candidate = self.position;
            const attempts = @min(@as(i32, 10), self.baseScale());
            var attempt: i32 = 0;
            while (attempt < attempts) : (attempt += 1) {
                const state = region.state(candidate.x, candidate.y, candidate.z) orelse
                    return false;
                if (isLava(state.*)) return false;
                if (largeDripstoneBaseAllowed(region, wind.modify(candidate), self.scale)) {
                    self.position = candidate;
                    return true;
                }
                candidate.y += if (self.stalagmite) -1 else 1;
            }
            self.scale = @divTrunc(self.scale, 2);
        }
        return false;
    }

    fn generate(
        self: LargeDripstoneGenerator,
        source: *ChunkRandom,
        region: *Region,
        config: data.LargeDripstone,
        wind: LargeDripstoneWind,
    ) usize {
        var placed: usize = 0;
        var offset_x = -self.scale;
        while (offset_x <= self.scale) : (offset_x += 1) {
            var offset_z = -self.scale;
            while (offset_z <= self.scale) : (offset_z += 1) {
                const squared = offset_x * offset_x + offset_z * offset_z;
                const radius: f32 = @sqrt(@as(f32, @floatFromInt(squared)));
                if (radius > @as(f32, @floatFromInt(self.scale))) continue;
                var column_height = self.columnHeight(radius);
                if (column_height <= 0) continue;
                if (@as(f64, source.nextF32()) < 0.2) {
                    const multiplier = @as(f32, 0.8) + source.nextF32() * @as(f32, 0.2);
                    column_height = @intFromFloat(
                        @as(f32, @floatFromInt(column_height)) * multiplier,
                    );
                }

                var position = addPosition(
                    self.position,
                    .{ .x = offset_x, .y = 0, .z = offset_z },
                );
                const top_y = if (self.stalagmite)
                    worldSurfaceHeight(region, position.x, position.z)
                else
                    std.math.maxInt(i32);
                var started = false;
                var y_step: i32 = 0;
                while (y_step < column_height) : (y_step += 1) {
                    if (position.y >= top_y) break;
                    const modified = wind.modify(position);
                    const target = region.state(modified.x, modified.y, modified.z) orelse break;
                    if (largeDripstoneCanGenerateOrLava(target.*)) {
                        started = true;
                        target.* = GeneratedState.fromFeature(config.dripstone_block);
                        placed += 1;
                    } else if (started and targetMatches(target.*, .base_stone_overworld)) {
                        break;
                    }
                    position.y += if (self.stalagmite) 1 else -1;
                }
            }
        }
        return placed;
    }
};

fn generateLargeDripstone(
    source: *ChunkRandom,
    region: *Region,
    config: data.LargeDripstone,
    origin: Position,
) usize {
    const initial = region.state(origin.x, origin.y, origin.z) orelse return 0;
    if (!isAir(initial.*) and !isWater(initial.*)) return 0;
    const cave = findCaveSurface(region, origin, config.search_range) orelse return 0;
    const ceiling = cave.ceiling orelse return 0;
    const floor = cave.floor orelse return 0;
    const cave_height = ceiling - floor - 1;
    if (cave_height < 4) return 0;

    const scaled_maximum: i32 = @intFromFloat(
        @as(f32, @floatFromInt(cave_height)) * config.max_radius_to_cave_height_ratio,
    );
    const maximum_radius = std.math.clamp(
        scaled_maximum,
        @as(i32, config.radius_minimum),
        @as(i32, config.radius_maximum),
    );
    const radius = @as(i32, config.radius_minimum) + source.nextBoundedI32(
        maximum_radius - @as(i32, config.radius_minimum) + 1,
    );
    var stalactite = LargeDripstoneGenerator.init(
        source,
        .{ .x = origin.x, .y = ceiling - 1, .z = origin.z },
        false,
        radius,
        config.stalactite_bluntness,
        config.height_scale,
    );
    var stalagmite = LargeDripstoneGenerator.init(
        source,
        .{ .x = origin.x, .y = floor + 1, .z = origin.z },
        true,
        radius,
        config.stalagmite_bluntness,
        config.height_scale,
    );
    const wind = if (stalactite.windEligible(config) and stalagmite.windEligible(config))
        LargeDripstoneWind.sample(source, config, origin.y)
    else
        LargeDripstoneWind{};
    const generate_stalactite = stalactite.findBase(region, wind);
    const generate_stalagmite = stalagmite.findBase(region, wind);
    var placed: usize = 0;
    if (generate_stalactite) placed += stalactite.generate(source, region, config, wind);
    if (generate_stalagmite) placed += stalagmite.generate(source, region, config, wind);
    return placed;
}

fn uniformF32(source: *ChunkRandom, range: [2]f32) f32 {
    return range[0] + source.nextF32() * (range[1] - range[0]);
}

fn scaleLargeDripstoneHeight(
    radius_value: f64,
    scale: f64,
    height_scale: f64,
    bluntness: f64,
) f64 {
    const radius = @max(radius_value, bluntness);
    const value = radius / scale * 0.384;
    const power_four_thirds = std.math.pow(f64, value, 4.0 / 3.0);
    const power_two_thirds = std.math.pow(f64, value, 2.0 / 3.0);
    const logarithm = (1.0 / 3.0) * @log(value);
    const height_value = @max(
        height_scale * (0.75 * power_four_thirds - power_two_thirds - logarithm),
        0,
    );
    return height_value / 0.384 * scale;
}

fn largeDripstoneBaseAllowed(region: *Region, origin: Position, scale: i32) bool {
    const center = region.state(origin.x, origin.y, origin.z) orelse return false;
    if (largeDripstoneCanGenerateOrLava(center.*)) return false;
    const increment = @as(f32, 6.0) / @as(f32, @floatFromInt(scale));
    var angle: f32 = 0;
    while (angle < @as(f32, 2.0 * std.math.pi)) : (angle += increment) {
        const offset_x: i32 = @intFromFloat(
            largeDripstoneCos(angle) * @as(f32, @floatFromInt(scale)),
        );
        const offset_z: i32 = @intFromFloat(
            largeDripstoneSin(angle) * @as(f32, @floatFromInt(scale)),
        );
        const state = region.state(
            origin.x + offset_x,
            origin.y,
            origin.z + offset_z,
        ) orelse return false;
        if (largeDripstoneCanGenerateOrLava(state.*)) return false;
    }
    return true;
}

fn largeDripstoneCanGenerateOrLava(state: GeneratedState) bool {
    return isAir(state) or isWater(state) or isLava(state);
}

fn isLava(state: GeneratedState) bool {
    return state.block() == .lava;
}

fn largeDripstoneSin(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * @as(f32, 10_430.378));
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(
        @as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536),
    ));
}

fn largeDripstoneCos(value: f32) f32 {
    const scaled: i32 = @intFromFloat(
        value * @as(f32, 10_430.378) + @as(f32, 16_384),
    );
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(
        @as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536),
    ));
}

fn generateDripstoneCluster(
    source: *ChunkRandom,
    region: *Region,
    config: data.DripstoneCluster,
    origin: Position,
) void {
    const initial = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!isAir(initial.*) and !isWater(initial.*)) return;
    const maximum_height = config.column_height_minimum +
        source.nextBoundedI32(
            @as(i32, config.column_height_maximum - config.column_height_minimum) + 1,
        );
    const wetness = clampedNormalF32(source, config.wetness);
    const density_value = config.density[0] +
        source.nextF32() * (config.density[1] - config.density[0]);
    const radius_x = @as(i32, config.radius_minimum) + source.nextBoundedI32(
        @as(i32, config.radius_maximum - config.radius_minimum) + 1,
    );
    const radius_z = @as(i32, config.radius_minimum) + source.nextBoundedI32(
        @as(i32, config.radius_maximum - config.radius_minimum) + 1,
    );

    var offset_x = -radius_x;
    while (offset_x <= radius_x) : (offset_x += 1) {
        var offset_z = -radius_z;
        while (offset_z <= radius_z) : (offset_z += 1) {
            const edge_distance = @min(
                radius_x - @as(i32, @intCast(@abs(offset_x))),
                radius_z - @as(i32, @intCast(@abs(offset_z))),
            );
            const column_chance = clampedMapF32(
                @floatFromInt(edge_distance),
                0,
                @floatFromInt(config.edge_distance),
                config.edge_chance,
                1,
            );
            generateDripstoneColumn(
                source,
                region,
                config,
                .{
                    .origin = .{
                        .x = origin.x + offset_x,
                        .y = origin.y,
                        .z = origin.z + offset_z,
                    },
                    .offset_x = offset_x,
                    .offset_z = offset_z,
                    .wetness = wetness,
                    .chance = @floatCast(column_chance),
                    .maximum_height = maximum_height,
                    .density = density_value,
                },
            );
        }
    }
}

const DripstoneColumn = struct {
    origin: Position,
    offset_x: i32,
    offset_z: i32,
    wetness: f32,
    chance: f64,
    maximum_height: i32,
    density: f32,
};

const DripstoneColumnHeights = struct {
    stalactite: i32 = 0,
    stalagmite: i32 = 0,
};

fn generateDripstoneColumn(
    source: *ChunkRandom,
    region: *Region,
    config: data.DripstoneCluster,
    column: DripstoneColumn,
) void {
    var cave = findCaveSurface(region, column.origin, config.search_range) orelse return;
    if (cave.ceiling == null and cave.floor == null) return;
    const water_selected = source.nextF32() < column.wetness;
    if (water_selected and cave.floor != null and canClusterWaterSpawn(
        region,
        .{ .x = column.origin.x, .y = cave.floor.?, .z = column.origin.z },
    )) {
        region.state(column.origin.x, cave.floor.?, column.origin.z).?.* = GeneratedState.fromBase(.water);
        cave.floor.? -= 1;
    }
    var heights: DripstoneColumnHeights = .{};
    const ceiling_selected = source.nextF64() < column.chance;
    if (ceiling_selected and cave.ceiling != null and
        !isLavaAt(region, column.origin.x, cave.ceiling.?, column.origin.z))
    {
        const limit = if (cave.floor) |floor|
            @min(column.maximum_height, cave.ceiling.? - floor)
        else
            column.maximum_height;
        heights.stalactite = placeClusterCeiling(source, region, config, column, cave.ceiling.?, limit);
    }
    const floor_selected = source.nextF64() < column.chance;
    if (floor_selected and cave.floor != null and
        !isLavaAt(region, column.origin.x, cave.floor.?, column.origin.z))
    {
        placeClusterFloor(source, region, config, column.origin, cave.floor.?);
        heights.stalagmite = if (cave.ceiling != null)
            @max(
                0,
                heights.stalactite + source.nextBoundedI32(
                    @as(i32, config.max_height_difference) * 2 + 1,
                ) - config.max_height_difference,
            )
        else
            clusterColumnHeight(source, config, column.offset_x, column.offset_z, column.density, column.maximum_height);
    }
    if (cave.ceiling != null and cave.floor != null and
        cave.ceiling.? - heights.stalactite <= cave.floor.? + heights.stalagmite)
    {
        heights = meetDripstoneColumns(source, cave, heights);
    }
    const merge = source.nextBool() and heights.stalactite > 0 and
        heights.stalagmite > 0 and cave.ceiling != null and cave.floor != null and
        heights.stalactite + heights.stalagmite == cave.ceiling.? - cave.floor.? - 1;
    if (cave.ceiling) |ceiling| generateClusterPointed(
        region,
        config,
        .{ .x = column.origin.x, .y = ceiling - 1, .z = column.origin.z },
        .down,
        heights.stalactite,
        merge,
    );
    if (cave.floor) |floor| generateClusterPointed(
        region,
        config,
        .{ .x = column.origin.x, .y = floor + 1, .z = column.origin.z },
        .up,
        heights.stalagmite,
        merge,
    );
}

fn placeClusterCeiling(source: *ChunkRandom, region: *Region, config: data.DripstoneCluster, column: DripstoneColumn, ceiling: i32, limit: i32) i32 {
    const layer = @as(i32, config.layer_minimum) + source.nextBoundedI32(
        @as(i32, config.layer_maximum - config.layer_minimum) + 1,
    );
    placeDripstoneLayer(region, .{ .x = column.origin.x, .y = ceiling, .z = column.origin.z }, layer, .up);
    return clusterColumnHeight(source, config, column.offset_x, column.offset_z, column.density, limit);
}

fn placeClusterFloor(source: *ChunkRandom, region: *Region, config: data.DripstoneCluster, origin: Position, floor: i32) void {
    const layer = @as(i32, config.layer_minimum) + source.nextBoundedI32(
        @as(i32, config.layer_maximum - config.layer_minimum) + 1,
    );
    placeDripstoneLayer(region, .{ .x = origin.x, .y = floor, .z = origin.z }, layer, .down);
}

fn meetDripstoneColumns(source: *ChunkRandom, cave: CaveSurface, heights: DripstoneColumnHeights) DripstoneColumnHeights {
    const minimum = @max(cave.ceiling.? - heights.stalactite, cave.floor.? + 1);
    const maximum = @min(cave.floor.? + heights.stalagmite, cave.ceiling.? - 1) + 1;
    const meeting = minimum + source.nextBoundedI32(maximum - minimum + 1);
    return .{
        .stalactite = cave.ceiling.? - meeting,
        .stalagmite = meeting - 1 - cave.floor.?,
    };
}

fn findCaveSurface(region: *Region, origin: Position, range: u8) ?CaveSurface {
    const state = region.state(origin.x, origin.y, origin.z) orelse return null;
    if (!isAir(state.*) and !isWater(state.*)) return null;
    return .{
        .ceiling = scanCaveBoundary(region, origin, range, 1),
        .floor = scanCaveBoundary(region, origin, range, -1),
    };
}

fn scanCaveBoundary(region: *Region, origin: Position, range: u8, step: i32) ?i32 {
    var y = origin.y;
    var distance: u8 = 1;
    while (distance < range) : (distance += 1) {
        const state = region.state(origin.x, y, origin.z) orelse return null;
        if (!isAir(state.*) and !isWater(state.*)) break;
        y += step;
    }
    const boundary = region.state(origin.x, y, origin.z) orelse return null;
    return if (!isAir(boundary.*) and !isWater(boundary.*)) y else null;
}

fn clusterColumnHeight(
    source: *ChunkRandom,
    config: data.DripstoneCluster,
    offset_x: i32,
    offset_z: i32,
    density_value: f32,
    maximum_height: i32,
) i32 {
    if (source.nextF32() > density_value) return 0;
    const distance: i32 = @intCast(@abs(offset_x) + @abs(offset_z));
    const bias = clampedMapF32(
        @floatFromInt(distance),
        0,
        @floatFromInt(config.height_bias_distance),
        @as(f32, @floatFromInt(maximum_height)) / 2,
        0,
    );
    const sampled = clampedNormalF32(source, .{
        bias,
        @floatFromInt(config.height_deviation),
        0,
        @floatFromInt(maximum_height),
    });
    return @intFromFloat(sampled);
}

fn clampedNormalF32(source: *ChunkRandom, values: [4]f32) f32 {
    const gaussian: f32 = @floatCast(source.nextGaussian());
    return std.math.clamp(
        values[0] + gaussian * values[1],
        values[2],
        values[3],
    );
}

fn clampedMapF32(value: f32, from_a: f32, from_b: f32, to_a: f32, to_b: f32) f32 {
    if (value <= from_a) return to_a;
    if (value >= from_b) return to_b;
    return to_a + (value - from_a) / (from_b - from_a) * (to_b - to_a);
}

fn placeDripstoneLayer(
    region: *Region,
    origin: Position,
    count: i32,
    direction: Direction,
) void {
    var position = origin;
    var index: i32 = 0;
    while (index < count) : (index += 1) {
        const state = region.state(position.x, position.y, position.z) orelse return;
        if (!dripstoneCanReplace(state.*)) return;
        state.* = GeneratedState.fromFeature(data.pointed_dripstone.dripstone_block);
        position = addPosition(position, direction.offset());
    }
}

fn generateClusterPointed(
    region: *Region,
    config: data.DripstoneCluster,
    origin: Position,
    direction: Direction,
    length: i32,
    merge: bool,
) void {
    if (length <= 0) return;
    const support = addPosition(origin, direction.opposite().offset());
    const support_state = region.state(support.x, support.y, support.z) orelse return;
    if (!dripstoneCanReplace(support_state.*)) return;
    var position = origin;
    var remaining = length;
    if (remaining >= 3) {
        placeClusterPointedState(region, config, position, direction, 0);
        position = addPosition(position, direction.offset());
        remaining -= 1;
        while (remaining > 2) : (remaining -= 1) {
            placeClusterPointedState(region, config, position, direction, 1);
            position = addPosition(position, direction.offset());
        }
    }
    if (remaining >= 2) {
        placeClusterPointedState(region, config, position, direction, 2);
        position = addPosition(position, direction.offset());
        remaining -= 1;
    }
    if (remaining >= 1)
        placeClusterPointedState(region, config, position, direction, if (merge) 4 else 3);
}

fn placeClusterPointedState(
    region: *Region,
    config: data.DripstoneCluster,
    position: Position,
    direction: Direction,
    thickness: usize,
) void {
    const state = region.state(position.x, position.y, position.z) orelse return;
    const direction_base: usize = if (direction == .down) 0 else 5;
    const waterlogged: usize = @intFromBool(isWater(state.*));
    state.* = GeneratedState.fromFeature(config.pointed_states[direction_base + thickness][waterlogged]);
}

fn isLavaAt(region: *Region, x: i32, y: i32, z: i32) bool {
    const state = region.state(x, y, z) orelse return false;
    return isLava(state.*);
}

fn canClusterWaterSpawn(region: *Region, origin: Position) bool {
    const target = region.state(origin.x, origin.y, origin.z) orelse return false;
    if (isWater(target.*) or isDripstone(target.*)) return false;
    const above = region.state(origin.x, origin.y + 1, origin.z) orelse return false;
    if (isWater(above.*)) return false;
    const horizontal = [_]Direction{ .north, .south, .west, .east };
    for (horizontal) |direction| {
        const neighbor = addPosition(origin, direction.offset());
        const state = region.state(neighbor.x, neighbor.y, neighbor.z) orelse return false;
        if (!targetMatches(state.*, .base_stone_overworld) and !isWater(state.*))
            return false;
    }
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    return targetMatches(below.*, .base_stone_overworld) or isWater(below.*);
}

fn isDripstone(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index == data.pointed_dripstone.dripstone_block or
        isClusterPointedIndex(index);
}

fn isClusterPointedIndex(index: u16) bool {
    for (data.dripstone_cluster.pointed_states) |pair|
        if (index == pair[0] or index == pair[1]) return true;
    return false;
}

fn clampedNormalInt(
    source: *ChunkRandom,
    mean: f32,
    deviation: f32,
    minimum: i8,
    maximum: i8,
) i32 {
    const gaussian: f32 = @floatCast(source.nextGaussian());
    const value = std.math.clamp(
        mean + gaussian * deviation,
        @as(f32, @floatFromInt(minimum)),
        @as(f32, @floatFromInt(maximum)),
    );
    return @intFromFloat(value);
}

fn scanForSolid(
    region: *Region,
    origin: Position,
    direction: Direction,
    maximum_steps: u8,
) ?Position {
    var position = origin;
    const offset = direction.offset();
    const initial = region.state(position.x, position.y, position.z) orelse return null;
    if (!isAir(initial.*) and !isWater(initial.*)) return null;
    for (0..maximum_steps) |_| {
        const state = region.state(position.x, position.y, position.z) orelse return null;
        if (isOpaqueFullCube(state.*)) return position;
        position = addPosition(position, offset);
        const next = region.state(position.x, position.y, position.z) orelse return null;
        if (!isAir(next.*) and !isWater(next.*)) break;
    }
    const state = region.state(position.x, position.y, position.z) orelse return null;
    return if (isOpaqueFullCube(state.*)) position else null;
}

fn generateSmallDripstone(
    source: *ChunkRandom,
    region: *Region,
    config: data.PointedDripstone,
    origin: Position,
) void {
    const above = region.state(origin.x, origin.y + 1, origin.z) orelse return;
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return;
    const replace_above = dripstoneCanReplace(above.*);
    const replace_below = dripstoneCanReplace(below.*);
    const direction: Direction = if (replace_above and replace_below)
        if (source.nextBool()) .down else .up
    else if (replace_above)
        .down
    else if (replace_below)
        .up
    else
        return;

    const support = addPosition(origin, direction.opposite().offset());
    placeDripstoneBlock(region, config, support);
    const horizontal = [_]Direction{ .north, .east, .south, .west };
    for (horizontal) |spread_direction| {
        if (source.nextF32() > config.directional_spread_chance) continue;
        const radius_one = addPosition(support, spread_direction.offset());
        placeDripstoneBlock(region, config, radius_one);
        if (source.nextF32() > config.radius_two_chance) continue;
        const random_direction: Direction =
            @enumFromInt(source.nextBoundedI32(all_directions.len));
        const radius_two = addPosition(radius_one, random_direction.offset());
        placeDripstoneBlock(region, config, radius_two);
        if (source.nextF32() > config.radius_three_chance) continue;
        const final_direction: Direction =
            @enumFromInt(source.nextBoundedI32(all_directions.len));
        placeDripstoneBlock(
            region,
            config,
            addPosition(radius_two, final_direction.offset()),
        );
    }

    const next = addPosition(origin, direction.offset());
    const next_state = region.state(next.x, next.y, next.z) orelse return;
    const pointed_height: u8 = if (source.nextF32() < config.taller_chance and
        (isAir(next_state.*) or isWater(next_state.*))) 2 else 1;
    generatePointedDripstone(region, config, origin, direction, pointed_height);
}

fn placeDripstoneBlock(
    region: *Region,
    config: data.PointedDripstone,
    position: Position,
) void {
    const state = region.state(position.x, position.y, position.z) orelse return;
    if (!dripstoneCanReplace(state.*)) return;
    state.* = GeneratedState.fromFeature(config.dripstone_block);
}

fn generatePointedDripstone(
    region: *Region,
    config: data.PointedDripstone,
    origin: Position,
    direction: Direction,
    pointed_height: u8,
) void {
    const support = addPosition(origin, direction.opposite().offset());
    const support_state = region.state(support.x, support.y, support.z) orelse return;
    if (!dripstoneCanReplace(support_state.*)) return;
    const direction_base: usize = if (direction == .down) 0 else 2;
    var position = origin;
    if (pointed_height >= 2) {
        placePointedState(region, config, position, direction_base + 1);
        position = addPosition(position, direction.offset());
    }
    placePointedState(region, config, position, direction_base);
}

fn placePointedState(
    region: *Region,
    config: data.PointedDripstone,
    position: Position,
    state_index: usize,
) void {
    const state = region.state(position.x, position.y, position.z) orelse return;
    const waterlogged: usize = @intFromBool(isWater(state.*));
    state.* = GeneratedState.fromFeature(config.pointed_states[state_index][waterlogged]);
}

fn dripstoneCanReplace(state: GeneratedState) bool {
    if (state.featureIndex() == data.pointed_dripstone.dripstone_block)
        return true;
    return state.nameEquals("minecraft:stone") or
        state.nameEquals("minecraft:granite") or
        state.nameEquals("minecraft:diorite") or
        state.nameEquals("minecraft:andesite") or
        state.nameEquals("minecraft:tuff") or
        state.nameEquals("minecraft:deepslate[axis=y]");
}

fn addPosition(a: Position, b: Position) Position {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

pub fn applyFluidSprings(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const selected_mask = biomes.fluid_springs;
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.fluid_springs, 0..) |config, spring_index| {
        const spring_bit = @as(u8, 1) << @intCast(spring_index);
        if (selected_mask & spring_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        for (0..config.count) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const y = sampleHeight(source, config.height);
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_fluid_spring_masks[biome_index] & spring_bit == 0) continue;
            generateFluidSpring(region, config, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn generateFluidSpring(region: *Region, config: data.Spring, origin: Position) void {
    const above = region.state(origin.x, origin.y + 1, origin.z) orelse return;
    if (!springValidBlock(above.*, config.valid_blocks)) return;
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return;
    if (config.requires_block_below and
        !springValidBlock(below.*, config.valid_blocks)) return;
    const target = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!isAir(target.*) and !springValidBlock(target.*, config.valid_blocks)) return;

    const neighbors = [_]Position{
        .{ .x = origin.x - 1, .y = origin.y, .z = origin.z },
        .{ .x = origin.x + 1, .y = origin.y, .z = origin.z },
        .{ .x = origin.x, .y = origin.y, .z = origin.z - 1 },
        .{ .x = origin.x, .y = origin.y, .z = origin.z + 1 },
        .{ .x = origin.x, .y = origin.y - 1, .z = origin.z },
    };
    var rock_count: u8 = 0;
    var hole_count: u8 = 0;
    for (neighbors) |position| {
        const state = region.state(position.x, position.y, position.z) orelse return;
        if (springValidBlock(state.*, config.valid_blocks)) rock_count += 1;
        if (isAir(state.*)) hole_count += 1;
    }
    if (rock_count == config.rock_count and hole_count == config.hole_count)
        target.* = GeneratedState.fromFeature(config.state);
}

fn applyUnderwaterMagma(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const UndergroundBiomes,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    if (!biomes.underwater_magma) return;

    const config = data.underwater_magma;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const attempts = config.count.minimum + @as(u8, @intCast(source.nextBoundedI32(
        @as(i32, config.count.maximum - config.count.minimum) + 1,
    )));
    for (0..attempts) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = sampleHeight(source, config.height);
        const halo_x: usize = @intCast(x - first_x + width);
        const halo_z: usize = @intCast(z - first_z + width);
        if (y > ocean_floor[halo_z * height_halo_side + halo_x] +
            config.surface_maximum) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_underwater_magma[biome_index]) continue;
        generateUnderwaterMagma(source, config, region, .{ .x = x, .y = y, .z = z });
    }
}

fn generateUnderwaterMagma(
    source: *ChunkRandom,
    config: data.Magma,
    region: *Region,
    origin: Position,
) void {
    const origin_state = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!isWater(origin_state.*)) return;
    var floor_y = origin.y;
    var distance: u8 = 1;
    while (distance < config.floor_search_range) : (distance += 1) {
        const state = region.state(origin.x, floor_y, origin.z) orelse return;
        if (!isWater(state.*)) break;
        floor_y -= 1;
    }
    const floor = region.state(origin.x, floor_y, origin.z) orelse return;
    if (isWater(floor.*)) return;

    const radius: i32 = config.radius;
    var z = origin.z - radius;
    while (z <= origin.z + radius) : (z += 1) {
        var y = floor_y - radius;
        while (y <= floor_y + radius) : (y += 1) {
            var x = origin.x - radius;
            while (x <= origin.x + radius) : (x += 1) {
                if (source.nextF32() >= config.probability) continue;
                if (!validMagmaPosition(region, x, y, z)) continue;
                const state = region.state(x, y, z) orelse continue;
                state.* = GeneratedState.fromFeature(config.state);
            }
        }
    }
}

fn validMagmaPosition(region: *Region, x: i32, y: i32, z: i32) bool {
    const positions = [_]Position{
        .{ .x = x, .y = y, .z = z },
        .{ .x = x, .y = y - 1, .z = z },
        .{ .x = x, .y = y, .z = z - 1 },
        .{ .x = x + 1, .y = y, .z = z },
        .{ .x = x, .y = y, .z = z + 1 },
        .{ .x = x - 1, .y = y, .z = z },
    };
    for (positions) |position| {
        const state = region.state(position.x, position.y, position.z) orelse return false;
        if (isAir(state.*) or isWater(state.*)) return false;
    }
    return true;
}

fn applyOres(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const UndergroundBiomes,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    first_index: u8,
    end_index: u8,
) !void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.ores, 0..) |ore, ore_record_index| {
        if (ore.step != 6) continue;
        if (ore.index < first_index or ore.index >= end_index) continue;
        const feature_bit = @as(u64, 1) << @intCast(ore_record_index);
        if (biomes.ore_mask & feature_bit == 0) continue;
        const source = decorator_random.begin(ore.index, 6);
        const attempts: u8 = switch (ore.count.kind) {
            .constant => ore.count.minimum,
            .uniform => ore.count.minimum + @as(u8, @intCast(source.nextBoundedI32(
                @as(i32, ore.count.maximum - ore.count.minimum) + 1,
            ))),
            .rarity => if (source.nextF32() < 1.0 / @as(f32, @floatFromInt(ore.count.minimum)))
                @as(u8, 1)
            else
                @as(u8, 0),
        };
        for (0..attempts) |_| {
            const x = first_x + source.nextBoundedI32(16);
            const z = first_z + source.nextBoundedI32(16);
            const y = sampleHeight(source, ore.height);
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_ore_masks[biome_index] & feature_bit == 0) continue;
            _ = generateOre(
                source,
                ore,
                first_x,
                first_z,
                ocean_floor,
                region,
                .{ .x = x, .y = y, .z = z },
            );
        }
    }
}

pub fn applyInfestedOre(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) !void {
    const ore_record_index = data.ores.len - 1;
    const ore = data.ores[ore_record_index];
    std.debug.assert(ore.step == 7 and ore.index == 4);
    const feature_bit = @as(u64, 1) << @intCast(ore_record_index);
    if (biomes.ore_mask & feature_bit == 0) return;
    try applyOreFeature(chunk_x, chunk_z, biomes, ocean_floor, decorator_random, region, ore, feature_bit);
}

fn applyOreFeature(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    ore: data.Ore,
    feature_bit: u64,
) !void {
    const source = decorator_random.begin(ore.index, ore.step);
    for (0..ore.count.minimum) |_| {
        const x = chunk_x * width + source.nextBoundedI32(width);
        const z = chunk_z * width + source.nextBoundedI32(width);
        const y = sampleHeight(source, ore.height);
        const biome_index = biomeAt(&biomes.current, x - chunk_x * width, y, z - chunk_z * width);
        if (data.biome_ore_masks[biome_index] & feature_bit == 0) continue;
        _ = generateOre(source, ore, chunk_x * width, chunk_z * width, ocean_floor, region, .{ .x = x, .y = y, .z = z });
    }
}

fn applyDisks(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const UndergroundBiomes,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.disks) |disk| {
        const feature_bit = @as(u64, 1) << @intCast(disk.index);
        if (biomes.disk_mask & feature_bit == 0) continue;
        const source = decorator_random.begin(disk.index, 6);
        for (0..disk.count) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const halo_x: usize = @intCast(x - first_x + width);
            const halo_z: usize = @intCast(z - first_z + width);
            const y: i32 = ocean_floor[halo_z * height_halo_side + halo_x];
            const origin = region.state(x, y, z) orelse continue;
            if (disk.requires_water and !isWater(origin.*)) continue;
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_disk_masks[biome_index] & feature_bit == 0) continue;
            generateDisk(source, disk, region, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn generateDisk(
    source: *ChunkRandom,
    disk: data.Disk,
    region: *Region,
    origin: Position,
) void {
    const radius = @as(i32, disk.radius_minimum) + source.nextBoundedI32(
        @as(i32, disk.radius_maximum - disk.radius_minimum) + 1,
    );
    var z = origin.z - radius;
    while (z <= origin.z + radius) : (z += 1) {
        var x = origin.x - radius;
        while (x <= origin.x + radius) : (x += 1) {
            const dx = x - origin.x;
            const dz = z - origin.z;
            if (dx * dx + dz * dz > radius * radius) continue;
            var y = origin.y + disk.half_height;
            const lower = origin.y - disk.half_height;
            while (y >= lower) : (y -= 1) {
                const state = region.state(x, y, z) orelse continue;
                if (!diskTargetMatches(state.*, disk.targets)) continue;
                const output = diskOutputState(disk, region, x, y, z);
                state.* = GeneratedState.fromFeature(output);
            }
        }
    }
}

fn diskOutputState(disk: data.Disk, region: *Region, x: i32, y: i32, z: i32) u16 {
    const alternate = disk.state_above_air orelse return disk.state;
    return switch (disk.state_rule) {
        .below_air => if (isAirAt(region, x, y - 1, z)) alternate else disk.state,
        .above_open => if (isOpenAt(region, x, y + 1, z)) alternate else disk.state,
    };
}

fn isAirAt(region: *Region, x: i32, y: i32, z: i32) bool {
    const state = region.state(x, y, z) orelse return false;
    return isAir(state.*);
}

fn isOpenAt(region: *Region, x: i32, y: i32, z: i32) bool {
    const state = region.state(x, y, z) orelse return false;
    return !isOpaqueFullCube(state.*) and !isWater(state.*);
}

pub fn applyGlowLichen(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    if (!biomes.glow_lichen) return;

    const config = data.glow_lichen;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const attempts = config.count.minimum + @as(u8, @intCast(source.nextBoundedI32(
        @as(i32, config.count.maximum - config.count.minimum) + 1,
    )));
    for (0..attempts) |_| {
        const y = sampleHeight(source, config.height);
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const halo_x: usize = @intCast(x - first_x + width);
        const halo_z: usize = @intCast(z - first_z + width);
        if (y > ocean_floor[halo_z * height_halo_side + halo_x] +
            config.surface_maximum) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_glow_lichen[biome_index]) continue;
        _ = generateGlowLichen(source, region, .{ .x = x, .y = y, .z = z });
    }
}

pub fn applyForestFlowers(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    index: u8,
) void {
    if (index == data.flower_forest_flowers.index and biomes.flower_forest_flowers)
        applyForestFlowerFeature(
            data.flower_forest_flowers,
            &data.biome_flower_forest_flowers,
            chunk_x,
            chunk_z,
            biomes,
            decorator_random,
            region,
        );
    if (index == data.forest_flowers.index and biomes.forest_flowers)
        applyForestFlowerFeature(
            data.forest_flowers,
            &data.biome_forest_flowers,
            chunk_x,
            chunk_z,
            biomes,
            decorator_random,
            region,
        );
}

fn applyForestFlowerFeature(
    config: data.ForestFlowers,
    biome_mask: []const bool,
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    if (source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) return;
    const origin_x = first_x + source.nextBoundedI32(width);
    const origin_z = first_z + source.nextBoundedI32(width);
    const origin_y = motionBlockingHeight(region, origin_x, origin_z);
    const count_roll = @as(i32, config.count_minimum) + source.nextBoundedI32(
        @as(i32, config.count_maximum) - @as(i32, config.count_minimum) + 1,
    );
    const attempts: usize = @intCast(std.math.clamp(
        count_roll,
        @as(i32, config.count_clamp_minimum),
        @as(i32, config.count_clamp_maximum),
    ));
    for (0..attempts) |_| {
        const biome_index =
            biomeAt(&biomes.current, origin_x - first_x, origin_y, origin_z - first_z);
        if (!biome_mask[biome_index]) continue;
        const flower_index: usize = @intCast(source.nextBoundedI32(4));
        for (0..config.tries) |_| {
            const x = origin_x +
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1);
            const y = origin_y +
                source.nextBoundedI32(@as(i32, config.y_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.y_spread) + 1);
            const z = origin_z +
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1);
            const target = region.state(x, y, z) orelse continue;
            if (!isAir(target.*)) continue;
            const ground = region.state(x, y - 1, z) orelse continue;
            if (!shortGrassCanPlantOn(ground.*)) continue;
            if (flower_index < config.lower_states.len) {
                const upper = region.state(x, y + 1, z) orelse continue;
                if (!isAir(upper.*)) continue;
                target.* = GeneratedState.fromFeature(config.lower_states[flower_index]);
                upper.* = GeneratedState.fromFeature(config.upper_states[flower_index]);
            } else {
                target.* = GeneratedState.fromFeature(config.lily_state);
            }
        }
    }
}

pub fn applyCaveVines(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.cave_vines;
    if (!biomes.cave_vines) return;
    const source = decorator_random.begin(config.index, config.step);
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (0..config.count) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const sampled_y = @as(i32, config.height_minimum) + source.nextBoundedI32(
            @as(i32, config.height_maximum) - @as(i32, config.height_minimum) + 1,
        );
        const y = caveVineOrigin(region, x, sampled_y, z, config.search_range) orelse continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_cave_vines[biome_index]) continue;
        generateCaveVineColumn(source, region, x, y, z);
    }
}

fn caveVineOrigin(region: *Region, x: i32, start_y: i32, z: i32, search_range: u8) ?i32 {
    const initial = region.state(x, start_y, z) orelse return null;
    if (!isAir(initial.*)) return null;
    var y = start_y;
    for (0..search_range) |_| {
        const state = region.state(x, y, z) orelse return null;
        if (isOpaqueFullCube(state.*)) return y - 1;
        y += 1;
        const next = region.state(x, y, z) orelse return null;
        if (!isAir(next.*)) break;
    }
    const state = region.state(x, y, z) orelse return null;
    return if (isOpaqueFullCube(state.*)) y - 1 else null;
}

fn generateCaveVineColumn(source: *ChunkRandom, region: *Region, x: i32, y: i32, z: i32) void {
    const config = data.cave_vines;
    const provider = weightedIndex(source, &config.plant_height_weights);
    const range = config.plant_height_ranges[provider];
    var plant_height = @as(usize, range[0]) + @as(usize, @intCast(source.nextBoundedI32(
        @as(i32, range[1] - range[0]) + 1,
    )));
    var tip_height: usize = 1;
    const expected_height = plant_height + tip_height;
    var actual_height: usize = 0;
    while (actual_height < expected_height) : (actual_height += 1) {
        const state = region.state(x, y - @as(i32, @intCast(actual_height)) - 1, z) orelse break;
        if (!isAir(state.*)) break;
    }
    var missing = expected_height - actual_height;
    const removed_plants = @min(plant_height, missing);
    plant_height -= removed_plants;
    missing -= removed_plants;
    tip_height -= @min(tip_height, missing);
    for (0..plant_height) |offset| {
        const target = region.state(x, y - @as(i32, @intCast(offset)), z) orelse unreachable;
        target.* = GeneratedState.fromFeature(config.plant_states[
            @intFromBool(source.nextBoundedI32(5) == 4)
        ]);
    }
    if (tip_height == 0) return;
    const berries: usize = @intFromBool(source.nextBoundedI32(5) == 4);
    const age: usize = @intCast(source.nextBoundedI32(3));
    const tip = region.state(x, y - @as(i32, @intCast(plant_height)), z) orelse unreachable;
    tip.* = GeneratedState.fromFeature(config.tip_states[berries * 3 + age]);
}

fn weightedIndex(source: *ChunkRandom, weights: []const u8) usize {
    var total: i32 = 0;
    for (weights) |weight| total += weight;
    var roll = source.nextBoundedI32(total);
    for (weights, 0..) |weight, index| {
        roll -= weight;
        if (roll < 0) return index;
    }
    unreachable;
}

pub fn applyFlowerPatches(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    if (biomes.flower_patches == 0) return;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const count_noise = biome_temperature.Sampler.init();
    for (data.flower_patches, 0..) |config, config_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const bit = @as(u16, 1) << @intCast(config_index);
        if (biomes.flower_patches & bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        const count = flowerPatchCount(config, &count_noise, first_x, first_z);
        for (0..count) |_| {
            if (config.rarity > 1 and
                source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const y = switch (config.heightmap) {
                .world_surface_wg => worldSurfaceHeight(region, x, z),
                .motion_blocking => motionBlockingHeight(region, x, z),
                .motion_blocking_no_leaves => motionBlockingNoLeavesHeight(region, x, z),
            };
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_flower_patch_masks[biome_index] & bit == 0) continue;
            placeFlowerPatch(source, region, config, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn flowerPatchCount(
    config: data.FlowerPatch,
    noise_sampler: *const biome_temperature.Sampler,
    x: i32,
    z: i32,
) u8 {
    if (config.count_kind == .constant) return config.count_below;
    const value = noise_sampler.foliage.sample(
        @as(f64, @floatFromInt(x)) / 200,
        @as(f64, @floatFromInt(z)) / 200,
    );
    return if (value < config.count_noise) config.count_below else config.count_above;
}

fn placeFlowerPatch(
    source: *ChunkRandom,
    region: *Region,
    config: data.FlowerPatch,
    origin: Position,
) void {
    for (0..config.tries) |_| {
        const position: Position = .{
            .x = origin.x + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
            .y = origin.y + source.nextBoundedI32(@as(i32, config.y_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.y_spread) + 1),
            .z = origin.z + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
        };
        const target = region.state(position.x, position.y, position.z) orelse continue;
        if (!isAir(target.*)) continue;
        const selected = flowerState(source, config, position);
        const ground = region.state(position.x, position.y - 1, position.z) orelse continue;
        if (!shortGrassCanPlantOn(ground.*)) continue;
        if (config.upper_state) |upper_state| {
            if (selected == config.states[0]) {
                const upper = region.state(position.x, position.y + 1, position.z) orelse continue;
                if (!isAir(upper.*)) continue;
                upper.* = GeneratedState.fromFeature(upper_state);
            }
        }
        target.* = GeneratedState.fromFeature(selected);
    }
}

fn flowerState(source: *ChunkRandom, config: data.FlowerPatch, position: Position) u16 {
    return switch (config.provider) {
        .simple => config.states[0],
        .weighted => weightedFlowerState(source, config.states, config.weights, config.total_weight),
        .noise => noiseFlowerState(config, position),
        .dual_noise => dualNoiseFlowerState(config, position),
        .noise_threshold => thresholdFlowerState(source, config, position),
    };
}

fn weightedFlowerState(
    source: *ChunkRandom,
    states: [16]u16,
    weights: [16]u8,
    total_weight: u8,
) u16 {
    var roll = source.nextBoundedI32(total_weight);
    for (states, weights) |state, weight| {
        if (roll < weight) return state;
        roll -= weight;
    }
    unreachable;
}

fn noiseFlowerState(config: data.FlowerPatch, position: Position) u16 {
    const value = flower_noise_0.sample(
        @as(f64, @floatFromInt(position.x)) * config.scale,
        @as(f64, @floatFromInt(position.y)) * config.scale,
        @as(f64, @floatFromInt(position.z)) * config.scale,
    );
    return config.states[noiseStateIndex(value, config.state_count)];
}

fn dualNoiseFlowerState(config: data.FlowerPatch, position: Position) u16 {
    const slow_value = sampleFlowerNoise(&flower_noise_negative_10, position, config.slow_scale);
    const variety = clampedNoiseMap(
        slow_value,
        config.variety_minimum,
        config.variety_maximum + 1,
    );
    var choices: [4]u16 = undefined;
    for (choices[0..variety], 0..) |*choice, index| {
        const offset: Position = .{
            .x = position.x + @as(i32, @intCast(index)) * 54_545,
            .y = position.y,
            .z = position.z + @as(i32, @intCast(index)) * 34_234,
        };
        choice.* = config.states[
            noiseStateIndex(
                sampleFlowerNoise(&flower_noise_negative_10, offset, config.slow_scale),
                config.state_count,
            )
        ];
    }
    const value = sampleFlowerNoise(&flower_noise_negative_3, position, config.scale);
    return choices[noiseStateIndex(value, @intCast(variety))];
}

fn thresholdFlowerState(
    source: *ChunkRandom,
    config: data.FlowerPatch,
    position: Position,
) u16 {
    const value = sampleFlowerNoise(&flower_noise_0, position, config.scale);
    if (value < config.threshold)
        return config.states[@intCast(source.nextBoundedI32(config.low_count))];
    if (source.nextF32() >= config.high_chance)
        return config.states[@as(usize, config.low_count) + config.high_count];
    return config.states[
        @as(usize, config.low_count) +
            @as(usize, @intCast(source.nextBoundedI32(config.high_count)))
    ];
}

fn sampleFlowerNoise(
    sampler: *const worldgen_noise.LegacyDoublePerlin,
    position: Position,
    scale: f32,
) f64 {
    return sampler.sample(
        @as(f64, @floatFromInt(position.x)) * scale,
        @as(f64, @floatFromInt(position.y)) * scale,
        @as(f64, @floatFromInt(position.z)) * scale,
    );
}

fn noiseStateIndex(value: f64, count: u8) usize {
    const normalized = std.math.clamp((1 + value) / 2, 0, 0.9999);
    return @intFromFloat(normalized * @as(f64, @floatFromInt(count)));
}

fn clampedNoiseMap(value: f64, minimum: u8, maximum: u8) usize {
    const normalized = std.math.clamp((value + 1) / 2, 0, 1);
    const mapped = @as(f64, @floatFromInt(minimum)) + normalized *
        @as(f64, @floatFromInt(maximum - minimum));
    return @intFromFloat(mapped);
}

pub fn applyOakLeafLitterTrees(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.oak_leaf_litter_trees;
    if (!biomes.oak_leaf_litter_trees) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    const count_roll = source.nextBoundedI32(
        @as(i32, config.minimum_weight) + config.maximum_weight,
    );
    const attempts = if (count_roll < config.minimum_weight)
        config.count_minimum
    else
        config.count_maximum;
    for (0..attempts) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = oceanFloorHeight(region, x, z);
        if (worldSurfaceHeight(region, x, z) - y > 0) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_oak_leaf_litter_trees[biome_index]) continue;

        if (source.nextF32() < config.selectors[0]) {
            generateFallenTree(source, region, .{ .x = x, .y = y, .z = z }, .birch, 8);
            continue;
        }
        if (source.nextF32() < config.selectors[1]) {
            if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
            _ = generateLeafLitterTree(
                source,
                region,
                .{ .x = x, .y = y, .z = z },
                .birch,
                0,
                .{ .beehive_probability = config.beehive_probability, .leaf_litter = true },
            );
            continue;
        }
        if (source.nextF32() < config.selectors[2]) {
            if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
            _ = generateFancyLeafLitterTree(
                source,
                region,
                .{ .x = x, .y = y, .z = z },
                .{
                    .beehive_probability = config.beehive_probability,
                    .leaf_litter = true,
                },
            );
            continue;
        }
        if (source.nextF32() < config.selectors[3]) {
            generateFallenTree(source, region, .{ .x = x, .y = y, .z = z }, .oak, 7);
            continue;
        }
        if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
        _ = generateLeafLitterTree(
            source,
            region,
            .{ .x = x, .y = y, .z = z },
            .oak,
            0,
            .{ .beehive_probability = config.beehive_probability, .leaf_litter = true },
        );
    }
}

pub fn applyBirchTrees(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.birch_trees;
    if (!biomes.birch_trees) return;
    const source = decorator_random.begin(config.index, config.step);
    const roll = source.nextBoundedI32(
        @as(i32, config.minimum_weight) + config.maximum_weight,
    );
    const attempts = if (roll < config.minimum_weight)
        config.count_minimum
    else
        config.count_maximum;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (0..attempts) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = oceanFloorHeight(region, x, z);
        if (worldSurfaceHeight(region, x, z) != y) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_birch_trees[biome_index]) continue;
        const origin: Position = .{ .x = x, .y = y, .z = z };
        if (!saplingWouldSurvive(region, origin)) continue;
        if (source.nextF32() < config.fallen_chance) {
            generateFallenTree(source, region, origin, .birch, 8);
            continue;
        }
        if (!saplingWouldSurvive(region, origin)) continue;
        _ = generateLeafLitterTree(source, region, origin, .birch, 0, .{
            .beehive_probability = config.beehive_probability,
        });
    }
}

pub fn applyTallBirchTrees(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.tall_birch_trees;
    if (!biomes.tall_birch_trees) return;
    const source = decorator_random.begin(config.index, config.step);
    const count_roll = source.nextBoundedI32(
        @as(i32, config.minimum_weight) + config.maximum_weight,
    );
    const attempts = if (count_roll < config.minimum_weight)
        config.count_minimum
    else
        config.count_maximum;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (0..attempts) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = oceanFloorHeight(region, x, z);
        if (worldSurfaceHeight(region, x, z) != y) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (!data.biome_tall_birch_trees[biome_index]) continue;
        const origin: Position = .{ .x = x, .y = y, .z = z };
        if (source.nextF32() < config.selectors[0]) {
            generateFallenTree(source, region, origin, .birch, 15);
            continue;
        }
        if (source.nextF32() < config.selectors[1]) {
            if (!saplingWouldSurvive(region, origin)) continue;
            _ = generateLeafLitterTree(source, region, origin, .birch, 6, .{
                .beehive_probability = config.beehive_probability,
            });
            continue;
        }
        if (source.nextF32() < config.selectors[2]) {
            generateFallenTree(source, region, origin, .birch, 8);
            continue;
        }
        if (!saplingWouldSurvive(region, origin)) continue;
        _ = generateLeafLitterTree(source, region, origin, .birch, 0, .{
            .beehive_probability = config.beehive_probability,
        });
    }
}

pub fn applyBasicTreeSelectors(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    index: u8,
) void {
    var selector_mask = biomes.basic_tree_selectors;
    while (selector_mask != 0) {
        const selector_index: usize = @ctz(selector_mask);
        selector_mask &= selector_mask - 1;
        const config = data.basic_tree_selectors[selector_index];
        if (config.index != index) continue;
        applyBasicTreeSelector(
            config,
            selector_index,
            chunk_x,
            chunk_z,
            biomes,
            decorator_random,
            region,
        );
    }
}

pub fn applyMushroomIslandVegetation(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    feature_index: u8,
) void {
    const config = data.mushroom_island_vegetation;
    if (feature_index != config.index or !biomes.mushroom_island_vegetation) return;
    const source = decorator_random.begin(config.index, config.step);
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const x = first_x + source.nextBoundedI32(width);
    const z = first_z + source.nextBoundedI32(width);
    const y = motionBlockingHeight(region, x, z);
    const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
    if (!data.biome_mushroom_island_vegetation[biome_index]) return;
    generateHugeMushroom(source, region, .{ .x = x, .y = y, .z = z }, source.nextBool());
}

fn generateHugeMushroom(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    red: bool,
) void {
    var mushroom_height = source.nextBoundedI32(3) + 4;
    if (source.nextBoundedI32(12) == 0) mushroom_height *= 2;
    if (!hugeMushroomCanGenerate(region, origin, mushroom_height, red)) return;
    if (red)
        placeRedMushroomCap(region, origin, mushroom_height)
    else
        placeBrownMushroomCap(region, origin, mushroom_height);
    const stem = GeneratedState.fromFeature(data.mushroom_island_vegetation.stem_state);
    var dy: i32 = 0;
    while (dy < mushroom_height) : (dy += 1) {
        const target = region.state(origin.x, origin.y + dy, origin.z) orelse continue;
        if (hugeMushroomReplaceable(target.*)) target.* = stem;
    }
}

fn hugeMushroomCanGenerate(
    region: *Region,
    origin: Position,
    mushroom_height: i32,
    red: bool,
) bool {
    if (origin.y < minimum_y + 1 or origin.y + mushroom_height + 1 >= minimum_y + height)
        return false;
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (!isDirtTag(ground.*)) return false;
    var dy: i32 = 0;
    while (dy <= mushroom_height) : (dy += 1) {
        const radius: i32 = if (red)
            if (dy >= mushroom_height - 3) data.mushroom_island_vegetation.foliage_radius[1] else 0
        else if (dy <= 3)
            0
        else
            data.mushroom_island_vegetation.foliage_radius[0];
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                const target = region.state(origin.x + dx, origin.y + dy, origin.z + dz) orelse
                    return false;
                if (!isAir(target.*) and treeLeafDistance(target.*) == 0) return false;
            }
        }
    }
    return true;
}

fn placeBrownMushroomCap(region: *Region, origin: Position, mushroom_height: i32) void {
    const radius: i32 = data.mushroom_island_vegetation.foliage_radius[0];
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            const west = dx == -radius or (dz == -radius or dz == radius) and dx == 1 - radius;
            const east = dx == radius or (dz == -radius or dz == radius) and dx == radius - 1;
            const north = dz == -radius or (dx == -radius or dx == radius) and dz == 1 - radius;
            const south = dz == radius or (dx == -radius or dx == radius) and dz == radius - 1;
            if ((dx == -radius or dx == radius) and (dz == -radius or dz == radius)) continue;
            placeMushroomCap(region, .{ .x = origin.x + dx, .y = origin.y + mushroom_height, .z = origin.z + dz }, false, true, west, east, north, south);
        }
    }
}

fn placeRedMushroomCap(region: *Region, origin: Position, mushroom_height: i32) void {
    const radius: i32 = data.mushroom_island_vegetation.foliage_radius[1];
    var dy = mushroom_height - 3;
    while (dy <= mushroom_height) : (dy += 1) {
        const layer_radius = if (dy < mushroom_height) radius else radius - 1;
        const edge = radius - 2;
        var dx = -layer_radius;
        while (dx <= layer_radius) : (dx += 1) {
            var dz = -layer_radius;
            while (dz <= layer_radius) : (dz += 1) {
                const edge_x = dx == -layer_radius or dx == layer_radius;
                const edge_z = dz == -layer_radius or dz == layer_radius;
                if (dy < mushroom_height and edge_x == edge_z) continue;
                placeMushroomCap(region, .{ .x = origin.x + dx, .y = origin.y + dy, .z = origin.z + dz }, true, dy >= mushroom_height - 1, dx < -edge, dx > edge, dz < -edge, dz > edge);
            }
        }
    }
}

fn placeMushroomCap(
    region: *Region,
    position: Position,
    red: bool,
    up: bool,
    west: bool,
    east: bool,
    north: bool,
    south: bool,
) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!hugeMushroomReplaceable(target.*)) return;
    const bits = @as(usize, @intFromBool(east)) * 2 +
        @as(usize, @intFromBool(north)) * 4 +
        @as(usize, @intFromBool(south)) * 8 +
        @as(usize, @intFromBool(up)) * 16 +
        @as(usize, @intFromBool(west)) * 32;
    target.* = GeneratedState.fromFeature(data.mushroom_island_vegetation.cap_states[@intFromBool(red)][bits]);
}

fn hugeMushroomReplaceable(state: GeneratedState) bool {
    return isAir(state) or treeLeafDistance(state) != 0;
}

fn applyBasicTreeSelector(
    config: data.BasicTreeSelector,
    selector_index: usize,
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const source = decorator_random.begin(config.index, config.step);
    const attempts = basicTreeAttemptCount(source, config);
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (0..attempts) |_| {
        const x = first_x + source.nextBoundedI32(width);
        const z = first_z + source.nextBoundedI32(width);
        const y = oceanFloorHeight(region, x, z);
        if (worldSurfaceHeight(region, x, z) - y > config.max_water_depth) continue;
        const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
        if (data.biome_basic_tree_selector_masks[biome_index] &
            (@as(u64, 1) << @intCast(selector_index)) == 0) continue;
        const origin: Position = .{ .x = x, .y = y, .z = z };
        if (config.survival_filter and !saplingWouldSurvive(region, origin)) continue;
        var choice = config.default_choice;
        for (config.choices[0..config.choice_count], config.chances[0..config.choice_count]) |
            candidate,
            chance,
        | {
            if (source.nextF32() >= chance) continue;
            choice = candidate;
            break;
        }
        generateBasicTree(source, region, origin, choice);
    }
}

fn basicTreeAttemptCount(source: *ChunkRandom, config: data.BasicTreeSelector) usize {
    return switch (config.count_kind) {
        .weighted => if (source.nextBoundedI32(
            @as(i32, config.minimum_weight) + config.maximum_weight,
        ) < config.minimum_weight) config.count_minimum else config.count_maximum,
        .rarity => if (source.nextF32() <
            1.0 / @as(f32, @floatFromInt(config.rarity))) 1 else 0,
    };
}

fn generateBasicTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    kind: data.BasicTreeKind,
) void {
    switch (kind) {
        .fallen_oak => {
            if (saplingWouldSurvive(region, origin))
                generateFallenTree(source, region, origin, .oak, 7);
        },
        .fallen_birch => {
            if (saplingWouldSurvive(region, origin))
                generateFallenTree(source, region, origin, .birch, 8);
        },
        .fallen_spruce => {
            if (saplingWouldSurvive(region, origin))
                generateFallenTree(source, region, origin, .spruce, 10);
        },
        .fallen_jungle => {
            if (saplingWouldSurvive(region, origin))
                generateFallenTree(source, region, origin, .jungle, 11);
        },
        .oak, .oak_leaf_litter, .oak_bees_002, .oak_bees_005 => {
            if (!saplingWouldSurvive(region, origin)) return;
            _ = generateLeafLitterTree(source, region, origin, .oak, 0, .{
                .beehive_probability = switch (kind) {
                    .oak_bees_002 => 0.02,
                    .oak_bees_005 => 0.05,
                    else => 0,
                },
                .leaf_litter = kind == .oak_leaf_litter,
            });
        },
        .birch_bees_002, .super_birch_bees => {
            if (!saplingWouldSurvive(region, origin)) return;
            _ = generateLeafLitterTree(
                source,
                region,
                origin,
                .birch,
                if (kind == .super_birch_bees) 6 else 0,
                .{ .beehive_probability = if (kind == .super_birch_bees) 1 else 0.02 },
            );
        },
        .fancy_oak, .fancy_oak_bees_002, .fancy_oak_bees_005, .fancy_oak_bees => {
            if (!saplingWouldSurvive(region, origin)) return;
            _ = generateFancyLeafLitterTree(source, region, origin, .{
                .beehive_probability = switch (kind) {
                    .fancy_oak_bees_002 => 0.02,
                    .fancy_oak_bees_005 => 0.05,
                    .fancy_oak_bees => 1,
                    else => 0,
                },
            });
        },
        .spruce, .pine, .spruce_on_snow, .pine_on_snow => {
            const on_snow = kind == .spruce_on_snow or kind == .pine_on_snow;
            const pine = kind == .pine or kind == .pine_on_snow;
            _ = generateConiferTree(source, region, origin, pine, on_snow);
        },
        .swamp_oak => _ = generateSwampOakTree(source, region, origin),
        .acacia => _ = generateAcaciaTree(source, region, origin),
        .mega_pine => _ = generateMegaConiferTree(source, region, origin, false),
        .mega_spruce => _ = generateMegaConiferTree(source, region, origin, true),
        .jungle_tree => _ = generateJungleTree(source, region, origin, false),
        .jungle_bush => _ = generateJungleTree(source, region, origin, true),
        .mega_jungle => _ = generateMegaJungleTree(source, region, origin),
        .jungle_grass => generateSurfacePatch(source, region, jungleGrassPatch(), origin),
    }
}

fn jungleGrassPatch() data.SurfacePatch {
    inline for (data.surface_patches) |config|
        if (std.mem.eql(u8, config.name, "minecraft:patch_grass_jungle")) return config;
    unreachable;
}

pub fn applyForestGrassPatch(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    world_surface: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.patch_grass_forest;
    if (!biomes.forest_grass) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const source = decorator_random.begin(config.index, config.step);
    for (0..config.count) |_| {
        const origin_x = first_x + source.nextBoundedI32(width);
        const origin_z = first_z + source.nextBoundedI32(width);
        const halo_x: usize = @intCast(origin_x - first_x + width);
        const halo_z: usize = @intCast(origin_z - first_z + width);
        const origin_y: i32 = world_surface[halo_z * height_halo_side + halo_x];
        const biome_index =
            biomeAt(&biomes.current, origin_x - first_x, origin_y, origin_z - first_z);
        if (!data.biome_patch_grass_forest[biome_index]) continue;

        for (0..config.tries) |_| {
            const x = origin_x +
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1);
            const y = origin_y +
                source.nextBoundedI32(@as(i32, config.y_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.y_spread) + 1);
            const z = origin_z +
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1);
            const target = region.state(x, y, z) orelse continue;
            if (!isAir(target.*)) continue;
            const ground = region.state(x, y - 1, z) orelse continue;
            if (!shortGrassCanPlantOn(ground.*)) continue;
            target.* = GeneratedState.fromFeature(config.state);
        }
    }
}

pub fn applyNoiseGrassPatches(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    world_surface: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    const selected_mask = biomes.noise_grass;
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const temperature_noise = biome_temperature.Sampler.init();
    for (data.noise_grass_patches, 0..) |config, patch_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const patch_bit = @as(u8, 1) << @intCast(patch_index);
        if (selected_mask & patch_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        const noise_value = temperature_noise.foliage.sample(
            @as(f64, @floatFromInt(first_x)) / 200,
            @as(f64, @floatFromInt(first_z)) / 200,
        );
        const count = if (noise_value < config.noise_level)
            config.below_noise
        else
            config.above_noise;
        for (0..count) |_| {
            if (config.rarity > 1 and
                source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
            const origin_x = first_x + source.nextBoundedI32(width);
            const origin_z = first_z + source.nextBoundedI32(width);
            const halo_x: usize = @intCast(origin_x - first_x + width);
            const halo_z: usize = @intCast(origin_z - first_z + width);
            const origin_y = world_surface[halo_z * height_halo_side + halo_x];
            const biome_index =
                biomeAt(&biomes.current, origin_x - first_x, origin_y, origin_z - first_z);
            if (data.biome_noise_grass_patch_masks[biome_index] & patch_bit == 0) continue;
            const origin: Position = .{ .x = origin_x, .y = origin_y, .z = origin_z };
            if (config.double_plant) {
                generateDoublePlantPatch(source, region, config, origin);
            } else {
                generateShortGrassPatch(source, region, config.tries, config.xz_spread, config.y_spread, config.state, origin);
            }
        }
    }
}

fn generateDoublePlantPatch(
    source: *ChunkRandom,
    region: *Region,
    config: data.NoiseGrassPatch,
    origin: Position,
) void {
    for (0..config.tries) |_| {
        const position: Position = .{
            .x = origin.x + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
            .y = origin.y + source.nextBoundedI32(@as(i32, config.y_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.y_spread) + 1),
            .z = origin.z + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
        };
        generateDoublePlant(region, position, config.state, config.upper_state);
    }
}

fn generateShortGrassPatch(
    source: *ChunkRandom,
    region: *Region,
    tries: u8,
    xz_spread: u8,
    y_spread: u8,
    output_state: u16,
    origin: Position,
) void {
    for (0..tries) |_| {
        const x = origin.x +
            source.nextBoundedI32(@as(i32, xz_spread) + 1) -
            source.nextBoundedI32(@as(i32, xz_spread) + 1);
        const y = origin.y +
            source.nextBoundedI32(@as(i32, y_spread) + 1) -
            source.nextBoundedI32(@as(i32, y_spread) + 1);
        const z = origin.z +
            source.nextBoundedI32(@as(i32, xz_spread) + 1) -
            source.nextBoundedI32(@as(i32, xz_spread) + 1);
        const target = region.state(x, y, z) orelse continue;
        if (!isAir(target.*)) continue;
        const ground = region.state(x, y - 1, z) orelse continue;
        if (!shortGrassCanPlantOn(ground.*)) continue;
        target.* = GeneratedState.fromFeature(output_state);
    }
}

pub fn applySurfacePatches(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    const selected_mask = biomes.surface_patches;
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.surface_patches, 0..) |config, patch_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const patch_bit = @as(u64, 1) << @intCast(patch_index);
        if (selected_mask & patch_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        if (config.rarity > 1 and
            source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
        for (0..config.count) |_| {
            const origin_x = first_x + source.nextBoundedI32(width);
            const origin_z = first_z + source.nextBoundedI32(width);
            const origin_y = switch (config.heightmap) {
                .world_surface_wg => worldSurfaceHeight(region, origin_x, origin_z),
                .motion_blocking => motionBlockingHeight(region, origin_x, origin_z),
                .motion_blocking_no_leaves => unreachable,
            };
            const biome_index =
                biomeAt(&biomes.current, origin_x - first_x, origin_y, origin_z - first_z);
            if (data.biome_surface_patch_masks[biome_index] & patch_bit == 0) continue;
            generateSurfacePatch(source, region, config, .{
                .x = origin_x,
                .y = origin_y,
                .z = origin_z,
            });
        }
    }
}

fn generateSurfacePatch(
    source: *ChunkRandom,
    region: *Region,
    config: data.SurfacePatch,
    origin: Position,
) void {
    for (0..config.tries) |_| {
        const position: Position = .{
            .x = origin.x + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
            .y = origin.y + source.nextBoundedI32(@as(i32, config.y_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.y_spread) + 1),
            .z = origin.z + source.nextBoundedI32(@as(i32, config.xz_spread) + 1) -
                source.nextBoundedI32(@as(i32, config.xz_spread) + 1),
        };
        const target = region.state(position.x, position.y, position.z) orelse continue;
        if (!isAir(target.*)) continue;
        const ground = region.state(position.x, position.y - 1, position.z) orelse continue;
        if (config.placement == .cactus) {
            generateCactusColumn(source, region, position, config.states[0], config.states[1]);
            continue;
        }
        if (config.placement == .double_plant) {
            generateDoublePlant(region, position, config.states[0], config.states[1]);
            continue;
        }
        const state = selectSurfacePatchState(source, config);
        const can_place = switch (config.placement) {
            .dirt, .jungle_grass, .taiga_grass, .weighted_flower => shortGrassCanPlantOn(ground.*),
            .mushroom => mushroomCanPlantOn(ground.*),
            .grass_block => isGrassBlock(ground.*),
            .dry_grass, .dead_bush => dryPlantCanSurviveOn(ground.*),
            .waterlily => ground.block() == .water,
            .leaf_litter => isGrassBlock(ground.*),
            .double_plant, .cactus => unreachable,
        };
        if (!can_place) continue;
        if (config.placement == .jungle_grass and ground.block() == .podzol) continue;
        target.* = GeneratedState.fromFeature(state);
    }
}

fn selectSurfacePatchState(source: *ChunkRandom, config: data.SurfacePatch) u16 {
    return switch (config.placement) {
        .weighted_flower => if (source.nextBoundedI32(3) >= 2)
            config.states[1]
        else
            config.states[0],
        .dry_grass => if (source.nextBool()) config.states[1] else config.states[0],
        .jungle_grass => if (source.nextBoundedI32(4) == 3)
            config.states[1]
        else
            config.states[0],
        .taiga_grass => if (source.nextBoundedI32(5) == 0)
            config.states[0]
        else
            config.states[1],
        .leaf_litter => config.states[@intCast(source.nextBoundedI32(config.state_count))],
        else => config.states[0],
    };
}

fn generateDoublePlant(
    region: *Region,
    position: Position,
    lower_state: u16,
    upper_state: u16,
) void {
    const ground = region.state(position.x, position.y - 1, position.z) orelse return;
    if (!shortGrassCanPlantOn(ground.*)) return;
    const lower = region.state(position.x, position.y, position.z) orelse return;
    const upper = region.state(position.x, position.y + 1, position.z) orelse return;
    if (!isAir(lower.*) or !isAir(upper.*)) return;
    lower.* = GeneratedState.fromFeature(lower_state);
    upper.* = GeneratedState.fromFeature(upper_state);
}

fn generateCactusColumn(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    cactus_state: u16,
    flower_state: u16,
) void {
    if (!cactusCanSurvive(region, origin)) return;
    const sampled_maximum = source.nextBoundedI32(3) + 1;
    const requested_height = source.nextBoundedI32(sampled_maximum) + 1;
    const flower_height = @intFromBool(source.nextBoundedI32(4) == 3);
    var cactus_height: i32 = 0;
    while (cactus_height < requested_height) : (cactus_height += 1) {
        const target = region.state(
            origin.x,
            origin.y + cactus_height,
            origin.z,
        ) orelse break;
        if (!isAir(target.*)) break;
        target.* = GeneratedState.fromFeature(cactus_state);
    }
    if (cactus_height != requested_height or flower_height == 0) return;
    const flower = region.state(origin.x, origin.y + cactus_height, origin.z) orelse return;
    if (isAir(flower.*)) flower.* = GeneratedState.fromFeature(flower_state);
}

fn cactusCanSurvive(region: *Region, origin: Position) bool {
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (!isSandTag(below.*) and below.block() != .cactus) return false;
    const neighbors = [_]Position{
        .{ .x = origin.x - 1, .y = origin.y, .z = origin.z },
        .{ .x = origin.x + 1, .y = origin.y, .z = origin.z },
        .{ .x = origin.x, .y = origin.y, .z = origin.z - 1 },
        .{ .x = origin.x, .y = origin.y, .z = origin.z + 1 },
    };
    for (neighbors) |position| {
        const neighbor = region.state(position.x, position.y, position.z) orelse return false;
        if (blocksMovement(neighbor.*) or neighbor.block() == .lava) return false;
    }
    return true;
}

pub fn applyNearWaterPatches(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    const selected_mask = biomes.near_water_patches;
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.near_water_patches, 0..) |config, patch_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const patch_bit = @as(u8, 1) << @intCast(patch_index);
        if (selected_mask & patch_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        if (config.rarity > 1 and
            source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
        for (0..config.count) |_| {
            const origin_x = first_x + source.nextBoundedI32(width);
            const origin_z = first_z + source.nextBoundedI32(width);
            const origin_y = switch (config.heightmap) {
                .world_surface_wg => unreachable,
                .motion_blocking => motionBlockingHeight(region, origin_x, origin_z),
                .motion_blocking_no_leaves => motionBlockingNoLeavesHeight(region, origin_x, origin_z),
            };
            const biome_index =
                biomeAt(&biomes.current, origin_x - first_x, origin_y, origin_z - first_z);
            if (data.biome_near_water_patch_masks[biome_index] & patch_bit == 0) continue;
            const origin: Position = .{ .x = origin_x, .y = origin_y, .z = origin_z };
            if (config.placement == .firefly_bush_near_water and
                !nearWaterPlantCanPlace(region, origin)) continue;
            generateNearWaterPatch(source, region, config, origin);
        }
    }
}

pub fn applyAquaticVegetation(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    biomes: *const BiomePlan,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    const masks: AquaticFeatureMasks = .{
        .seagrass = biomes.seagrass,
        .kelp = biomes.kelp,
    };
    if (masks.seagrass == 0 and masks.kelp == 0) return;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const mixer_seed = biome_access.mixerSeed(world_seed);
    applySeagrass(masks.seagrass, first_x, first_z, mixer_seed, climate_sampler, ocean_floor, decorator_random, region, minimum_index, maximum_index);
    applyKelp(masks.kelp, first_x, first_z, mixer_seed, climate_sampler, ocean_floor, decorator_random, region, minimum_index, maximum_index);
}

const AquaticFeatureMasks = struct {
    seagrass: u8 = 0,
    kelp: u8 = 0,
};

fn applySeagrass(mask: u8, first_x: i32, first_z: i32, mixer_seed: i64, climate_sampler: *const climate.Sampler, ocean_floor: *const HeightHalo, decorator_random: *DecoratorRandom, region: *Region, minimum_index: u8, maximum_index: u8) void {
    for (data.seagrass, 0..) |config, feature_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const feature_bit = @as(u8, 1) << @intCast(feature_index);
        if (mask & feature_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        const origin_x = first_x + source.nextBoundedI32(width);
        const origin_z = first_z + source.nextBoundedI32(width);
        const origin_y = heightHaloAt(
            ocean_floor,
            first_x,
            first_z,
            origin_x,
            origin_z,
        );
        const origin_biome = jitteredBiomeIndex(
            mixer_seed,
            climate_sampler,
            region,
            .{ .x = origin_x, .y = origin_y, .z = origin_z },
        );
        if (data.biome_seagrass_masks[origin_biome] & feature_bit == 0) continue;

        for (0..config.count) |_| {
            const x = origin_x + source.nextBoundedI32(8) - source.nextBoundedI32(8);
            const z = origin_z + source.nextBoundedI32(8) - source.nextBoundedI32(8);
            const y = oceanFloorHeight(region, x, z);
            const target = region.state(x, y, z) orelse continue;
            if (!isWater(target.*)) continue;
            const tall = source.nextF64() < @as(f64, config.tall_probability);
            const ground = region.state(x, y - 1, z) orelse continue;
            if (!isOpaqueFullCube(ground.*)) continue;
            if (tall) {
                const upper = region.state(x, y + 1, z) orelse continue;
                if (!isWater(upper.*)) continue;
                target.* = GeneratedState.fromFeature(data.tall_seagrass_lower_state);
                upper.* = GeneratedState.fromFeature(data.tall_seagrass_upper_state);
            } else {
                target.* = GeneratedState.fromFeature(data.seagrass_state);
            }
        }
    }
}

fn applyKelp(mask: u8, first_x: i32, first_z: i32, mixer_seed: i64, climate_sampler: *const climate.Sampler, ocean_floor: *const HeightHalo, decorator_random: *DecoratorRandom, region: *Region, minimum_index: u8, maximum_index: u8) void {
    const foliage_noise = biome_temperature.Sampler.init();
    for (data.kelp, 0..) |config, feature_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const feature_bit = @as(u8, 1) << @intCast(feature_index);
        if (mask & feature_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        const noise = foliage_noise.foliage.sample(
            @as(f64, @floatFromInt(first_x)) / config.noise_factor,
            @as(f64, @floatFromInt(first_z)) / config.noise_factor,
        );
        const count_value = @ceil(noise * @as(f64, @floatFromInt(
            config.noise_to_count_ratio,
        )));
        if (count_value <= 0) continue;
        const count: usize = @intFromFloat(count_value);
        for (0..count) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const placement_y = heightHaloAt(ocean_floor, first_x, first_z, x, z);
            const placement_biome = jitteredBiomeIndex(
                mixer_seed,
                climate_sampler,
                region,
                .{ .x = x, .y = placement_y, .z = z },
            );
            if (data.biome_kelp_masks[placement_biome] & feature_bit == 0) continue;
            generateKelp(source, region, x, z);
        }
    }
}

fn generateKelp(source: *ChunkRandom, region: *Region, x: i32, z: i32) void {
    var y = oceanFloorHeight(region, x, z);
    const initial = region.state(x, y, z) orelse return;
    if (!isWater(initial.*)) return;
    const desired_height = 1 + source.nextBoundedI32(10);
    var offset: i32 = 0;
    while (offset <= desired_height) : ({
        y += 1;
        offset += 1;
    }) {
        const target = region.state(x, y, z) orelse return;
        const upper = region.state(x, y + 1, z) orelse return;
        const below = region.state(x, y - 1, z) orelse return;
        if (isWater(target.*) and isWater(upper.*) and kelpCanAttachTo(below.*)) {
            if (offset == desired_height) {
                target.* = GeneratedState.fromFeature(
                    data.kelp_states[@intCast(source.nextBoundedI32(4))],
                );
                return;
            }
            target.* = GeneratedState.fromFeature(data.kelp_plant_state);
            continue;
        }
        if (offset <= 0) return;
        const tip = region.state(x, y - 1, z) orelse return;
        const tip_below = region.state(x, y - 2, z) orelse return;
        if (!kelpCanAttachTo(tip_below.*) or isKelpTip(tip_below.*)) return;
        tip.* = GeneratedState.fromFeature(
            data.kelp_states[@intCast(source.nextBoundedI32(4))],
        );
        return;
    }
}

fn kelpCanAttachTo(state: GeneratedState) bool {
    return !state.nameEquals("minecraft:magma_block") and
        (isKelp(state) or isOpaqueFullCube(state));
}

fn isKelp(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index == data.kelp_plant_state or
        (index >= data.kelp_states[0] and index <= data.kelp_states[3]);
}

fn isKelpTip(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index >= data.kelp_states[0] and index <= data.kelp_states[3];
}

pub fn applyFreezeTopLayer(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    region: *Region,
) void {
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const mixer_seed = biome_access.mixerSeed(world_seed);
    const temperature_sampler = biome_temperature.Sampler.init();
    for (0..width) |local_x| {
        for (0..width) |local_z| {
            const x = first_x + @as(i32, @intCast(local_x));
            const z = first_z + @as(i32, @intCast(local_z));
            const top_y = motionBlockingHeight(region, x, z);
            const quart = biome_access.quartPosition(
                mixer_seed,
                .{ .x = x, .y = top_y, .z = z },
            );
            const biome_index = region.biome_cache.atQuart(
                climate_sampler,
                quart.x,
                quart.y,
                quart.z,
            );
            const biome_climate = biome.climateFor(biome_index);

            const below = region.state(x, top_y - 1, z) orelse continue;
            if (canFreezeWater(
                &temperature_sampler,
                biome_climate,
                below.*,
                x,
                top_y - 1,
                z,
            )) {
                below.* = GeneratedState.fromFeature(data.freeze_top_layer.ice_state);
            }

            const target = region.state(x, top_y, z) orelse continue;
            if (!canSetSnow(
                &temperature_sampler,
                biome_climate,
                target.*,
                below.*,
                x,
                top_y,
                z,
            )) continue;
            target.* = GeneratedState.fromFeature(data.freeze_top_layer.snow_state);
            makeSnowy(below);
        }
    }
}

pub fn applySimpleFeatures(
    chunk_x: i32,
    chunk_z: i32,
    biomes: *const BiomePlan,
    world_surface: *const HeightHalo,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    step: u8,
    first_index: u8,
    end_index: u8,
) void {
    if (biomes.simple_features == 0) return;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.simple_features, 0..) |config, config_index| {
        if (config.step != step or config.index < first_index or config.index >= end_index) continue;
        const feature_bit = @as(u16, 1) << @intCast(config_index);
        if (biomes.simple_features & feature_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        const attempts = simpleFeatureCount(config, source, first_x, first_z);
        for (0..attempts) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const y = simpleFeatureHeight(config, source, region, world_surface, ocean_floor, x, z);
            const biome_index = biomeAt(&biomes.current, x - first_x, y, z - first_z);
            if (data.biome_simple_feature_masks[biome_index] & feature_bit == 0) continue;
            generateSimpleFeature(config, source, region, .{ .x = x, .y = y, .z = z });
        }
    }
}

fn simpleFeatureCount(config: data.SimpleFeature, source: *ChunkRandom, x: i32, z: i32) usize {
    return switch (config.count_kind) {
        .constant => config.count_minimum,
        .uniform => @as(usize, config.count_minimum) + @as(usize, @intCast(source.nextBoundedI32(
            @as(i32, config.count_maximum - config.count_minimum) + 1,
        ))),
        .rarity => if (source.nextF32() < 1.0 / @as(f32, @floatFromInt(config.count_minimum))) 1 else 0,
        .noise => blk: {
            const foliage = biome_temperature.Sampler.init().foliage.sample(
                @as(f64, @floatFromInt(x)) / 80.0,
                @as(f64, @floatFromInt(z)) / 80.0,
            );
            break :blk @intFromFloat(@max(0.0, @ceil((foliage + 0.3) * 160.0)));
        },
    };
}

fn simpleFeatureHeight(config: data.SimpleFeature, source: *ChunkRandom, region: *Region, world_surface: *const HeightHalo, ocean_floor: *const HeightHalo, x: i32, z: i32) i32 {
    const first_x = region.center_chunk_x * width;
    const first_z = region.center_chunk_z * width;
    return switch (config.height_kind) {
        .world_surface_wg => heightHaloAt(world_surface, first_x, first_z, x, z) + config.height_minimum,
        .ocean_floor_wg => heightHaloAt(ocean_floor, first_x, first_z, x, z) + config.height_minimum,
        .motion_blocking => motionBlockingHeight(region, x, z) + config.height_minimum,
        .uniform => config.height_minimum + source.nextBoundedI32(
            @as(i32, config.height_maximum - config.height_minimum) + 1,
        ),
    };
}

fn generateSimpleFeature(config: data.SimpleFeature, source: *ChunkRandom, region: *Region, origin: Position) void {
    switch (config.kind) {
        .forest_rock => generateForestRock(source, region, origin, config.states[0]),
        .ice_spike => generateIceSpike(source, region, origin, config.states[0]),
        .ice_patch => generateIcePatch(source, region, origin, config.states[0]),
        .desert_well => generateDesertWell(source, region, origin, config.states),
        .blue_ice => generateBlueIce(source, region, origin, config.states[0]),
        .bamboo_podzol => generateBamboo(source, region, origin, config.states, true),
        .bamboo => generateBamboo(source, region, origin, config.states, false),
        .vines => generateVine(region, origin, config.states),
        .sea_pickle => generateSeaPickles(source, region, origin, config.states),
        .spore_blossom => generateSporeBlossom(region, origin, config.states[0]),
    }
}

fn generateSporeBlossom(region: *Region, origin: Position, output: u16) void {
    const first = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!isAir(first.*)) return;
    var distance: i32 = 0;
    while (distance <= 12) : (distance += 1) {
        const scan = region.state(origin.x, origin.y + distance, origin.z) orelse return;
        if (isAir(scan.*)) continue;
        if (!isOpaqueFullCube(scan.*) or distance == 0) return;
        const target = region.state(origin.x, origin.y + distance - 1, origin.z) orelse return;
        if (isAir(target.*)) target.* = GeneratedState.fromFeature(output);
        return;
    }
}

fn generateForestRock(source: *ChunkRandom, region: *Region, requested: Position, output: u16) void {
    var origin = requested;
    while (origin.y > minimum_y + 3) : (origin.y -= 1) {
        const below = region.state(origin.x, origin.y - 1, origin.z) orelse continue;
        if (!isAir(below.*) and (isDirtTag(below.*) or isBaseStone(below.*))) break;
    }
    if (origin.y <= minimum_y + 3) return;
    for (0..3) |_| {
        const radius_x: i32 = source.nextBoundedI32(2);
        const radius_y: i32 = source.nextBoundedI32(2);
        const radius_z: i32 = source.nextBoundedI32(2);
        const radius = @as(f32, @floatFromInt(radius_x + radius_y + radius_z)) / 3.0 + 0.5;
        var y = origin.y - radius_y;
        while (y <= origin.y + radius_y) : (y += 1) {
            var z = origin.z - radius_z;
            while (z <= origin.z + radius_z) : (z += 1) {
                var x = origin.x - radius_x;
                while (x <= origin.x + radius_x) : (x += 1) {
                    const dx = x - origin.x;
                    const dy = y - origin.y;
                    const dz = z - origin.z;
                    if (@as(f32, @floatFromInt(dx * dx + dy * dy + dz * dz)) > radius * radius) continue;
                    const state = region.state(x, y, z) orelse continue;
                    state.* = GeneratedState.fromFeature(output);
                }
            }
        }
        origin.x += -1 + source.nextBoundedI32(2);
        origin.y -= source.nextBoundedI32(2);
        origin.z += -1 + source.nextBoundedI32(2);
    }
}

fn generateBlueIce(source: *ChunkRandom, region: *Region, origin: Position, output: u16) void {
    if (origin.y > 62) return;
    const target = region.state(origin.x, origin.y, origin.z) orelse return;
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return;
    if (!isWater(target.*) and !isWater(below.*)) return;
    if (!hasNeighborNamed(region, origin, "minecraft:packed_ice", false)) return;
    target.* = GeneratedState.fromFeature(output);
    for (0..200) |_| {
        const dy = source.nextBoundedI32(5) - source.nextBoundedI32(6);
        var radius: i32 = 3;
        if (dy < 2) radius += @divTrunc(dy, 2);
        if (radius < 1) continue;
        const position: Position = .{
            .x = origin.x + source.nextBoundedI32(radius) - source.nextBoundedI32(radius),
            .y = origin.y + dy,
            .z = origin.z + source.nextBoundedI32(radius) - source.nextBoundedI32(radius),
        };
        const state = region.state(position.x, position.y, position.z) orelse continue;
        if (!isAir(state.*) and !isWater(state.*) and
            !state.nameEquals("minecraft:packed_ice") and !state.nameEquals("minecraft:ice")) continue;
        if (hasNeighborNamed(region, position, "minecraft:blue_ice", true))
            state.* = GeneratedState.fromFeature(output);
    }
}

fn hasNeighborNamed(region: *Region, origin: Position, comptime name: []const u8, include_down: bool) bool {
    const directions = [_]Position{
        .{ .x = 0, .y = -1, .z = 0 }, .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
    };
    for (directions, 0..) |direction, index| {
        if (!include_down and index == 0) continue;
        const neighbor = region.state(
            origin.x + direction.x,
            origin.y + direction.y,
            origin.z + direction.z,
        ) orelse continue;
        if (neighbor.nameEquals(name)) return true;
    }
    return false;
}

fn generateBamboo(source: *ChunkRandom, region: *Region, origin: Position, states: [5]u16, podzol: bool) void {
    const initial = region.state(origin.x, origin.y, origin.z) orelse return;
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return;
    if (!isAir(initial.*) or !bambooPlantableOn(ground.*)) return;
    const height_value = source.nextBoundedI32(12) + 5;
    if (podzol and source.nextF32() < 0.2) {
        const radius = source.nextBoundedI32(4) + 1;
        var z = origin.z - radius;
        while (z <= origin.z + radius) : (z += 1) {
            var x = origin.x - radius;
            while (x <= origin.x + radius) : (x += 1) {
                const dx = x - origin.x;
                const dz = z - origin.z;
                if (dx * dx + dz * dz > radius * radius) continue;
                const y = worldSurfaceHeight(region, x, z) - 1;
                const surface_state = region.state(x, y, z) orelse continue;
                if (isDirtTag(surface_state.*))
                    surface_state.* = GeneratedState.fromFeature(states[4]);
            }
        }
    }
    var y = origin.y;
    var placed: i32 = 0;
    while (placed < height_value) : (placed += 1) {
        const target = region.state(origin.x, y, origin.z) orelse break;
        if (!isAir(target.*)) break;
        target.* = GeneratedState.fromFeature(states[0]);
        y += 1;
    }
    if (placed < 3) return;
    setFeatureState(region, .{ .x = origin.x, .y = y, .z = origin.z }, states[1]);
    setFeatureState(region, .{ .x = origin.x, .y = y - 1, .z = origin.z }, states[2]);
    setFeatureState(region, .{ .x = origin.x, .y = y - 2, .z = origin.z }, states[3]);
}

fn bambooPlantableOn(state: GeneratedState) bool {
    return isDirtTag(state) or isSandTag(state) or state.nameEquals("minecraft:gravel") or
        state.nameEquals("minecraft:suspicious_gravel") or state.block() == .bamboo or
        state.block() == .bamboo_sapling;
}

fn setFeatureState(region: *Region, position: Position, state_index: u16) void {
    const state = region.state(position.x, position.y, position.z) orelse return;
    state.* = GeneratedState.fromFeature(state_index);
}

fn generateVine(region: *Region, origin: Position, states: [5]u16) void {
    const target = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!isAir(target.*)) return;
    const offsets = [_]Position{
        .{ .x = 0, .y = 1, .z = 0 }, .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 0, .y = 0, .z = 1 }, .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
    };
    for (offsets, states) |offset, state| {
        const neighbor = region.state(
            origin.x + offset.x,
            origin.y + offset.y,
            origin.z + offset.z,
        ) orelse continue;
        if (!isOpaqueFullCube(neighbor.*)) continue;
        target.* = GeneratedState.fromFeature(state);
        return;
    }
}

fn generateSeaPickles(source: *ChunkRandom, region: *Region, origin: Position, states: [5]u16) void {
    for (0..20) |_| {
        const x = origin.x + source.nextBoundedI32(8) - source.nextBoundedI32(8);
        const z = origin.z + source.nextBoundedI32(8) - source.nextBoundedI32(8);
        const y = oceanFloorHeight(region, x, z);
        const target = region.state(x, y, z) orelse continue;
        const below = region.state(x, y - 1, z) orelse continue;
        const state = states[@intCast(source.nextBoundedI32(4))];
        if (isWater(target.*) and isOpaqueFullCube(below.*))
            target.* = GeneratedState.fromFeature(state);
    }
}

fn generateDesertWell(source: *ChunkRandom, region: *Region, requested: Position, states: [5]u16) void {
    var origin = requested;
    origin.y += 1;
    while (origin.y > minimum_y + 2) : (origin.y -= 1) {
        const state = region.state(origin.x, origin.y, origin.z) orelse return;
        if (!isAir(state.*)) break;
    }
    const surface_state = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!surface_state.nameEquals("minecraft:sand")) return;
    var z = origin.z - 2;
    while (z <= origin.z + 2) : (z += 1) {
        var x = origin.x - 2;
        while (x <= origin.x + 2) : (x += 1) {
            const below_one = region.state(x, origin.y - 1, z) orelse return;
            const below_two = region.state(x, origin.y - 2, z) orelse return;
            if (isAir(below_one.*) and isAir(below_two.*)) return;
        }
    }
    desertWellFoundation(region, origin, states[1]);
    desertWellWaterAndSand(region, origin, states[0], states[3]);
    desertWellRim(region, origin, states[1], states[2]);
    desertWellRoofAndPosts(region, origin, states[1], states[2]);
    const offsets = [_]Position{
        .{ .x = 0, .y = 0, .z = 0 },  .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },  .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 },
    };
    const first = offsets[@intCast(source.nextBoundedI32(@intCast(offsets.len)))];
    const second = offsets[@intCast(source.nextBoundedI32(@intCast(offsets.len)))];
    setFeatureState(region, addPosition(origin, .{ .x = first.x, .y = -1, .z = first.z }), states[4]);
    setFeatureState(region, addPosition(origin, .{ .x = second.x, .y = -2, .z = second.z }), states[4]);
}

fn desertWellFoundation(region: *Region, origin: Position, sandstone: u16) void {
    var y = origin.y - 2;
    while (y <= origin.y) : (y += 1) {
        var z = origin.z - 2;
        while (z <= origin.z + 2) : (z += 1) {
            var x = origin.x - 2;
            while (x <= origin.x + 2) : (x += 1)
                setFeatureState(region, .{ .x = x, .y = y, .z = z }, sandstone);
        }
    }
}

fn desertWellWaterAndSand(region: *Region, origin: Position, sand: u16, water: u16) void {
    const horizontal = [_]Position{
        .{ .x = 0, .y = 0, .z = 0 },  .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = -1, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = 0, .y = 0, .z = -1 },
    };
    for (horizontal) |offset| {
        setFeatureState(region, addPosition(origin, offset), water);
        setFeatureState(region, addPosition(origin, .{ .x = offset.x, .y = -1, .z = offset.z }), sand);
    }
}

fn desertWellRim(region: *Region, origin: Position, sandstone: u16, slab: u16) void {
    var z = origin.z - 2;
    while (z <= origin.z + 2) : (z += 1) {
        var x = origin.x - 2;
        while (x <= origin.x + 2) : (x += 1) if (x == origin.x - 2 or x == origin.x + 2 or z == origin.z - 2 or z == origin.z + 2)
            setFeatureState(region, .{ .x = x, .y = origin.y + 1, .z = z }, sandstone);
    }
    const slabs = [_]Position{
        .{ .x = 2, .y = 1, .z = 0 }, .{ .x = -2, .y = 1, .z = 0 },
        .{ .x = 0, .y = 1, .z = 2 }, .{ .x = 0, .y = 1, .z = -2 },
    };
    for (slabs) |offset| setFeatureState(region, addPosition(origin, offset), slab);
}

fn desertWellRoofAndPosts(region: *Region, origin: Position, sandstone: u16, slab: u16) void {
    for ([_]i32{ -1, 0, 1 }) |z| for ([_]i32{ -1, 0, 1 }) |x| {
        setFeatureState(
            region,
            addPosition(origin, .{ .x = x, .y = 4, .z = z }),
            if (x == 0 and z == 0) sandstone else slab,
        );
    };
    for (1..4) |raw_y| {
        const y: i32 = @intCast(raw_y);
        for ([_][2]i32{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } }) |corner|
            setFeatureState(region, addPosition(origin, .{ .x = corner[0], .y = y, .z = corner[1] }), sandstone);
    }
}

fn generateIceSpike(source: *ChunkRandom, region: *Region, requested: Position, packed_ice: u16) void {
    var origin = requested;
    while (origin.y > minimum_y + 2) : (origin.y -= 1) {
        const state = region.state(origin.x, origin.y, origin.z) orelse return;
        if (!isAir(state.*)) break;
    }
    const base = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!base.nameEquals("minecraft:snow_block")) return;
    origin.y += source.nextBoundedI32(4);
    const spike_height = source.nextBoundedI32(4) + 7;
    const base_radius = @divTrunc(spike_height, 4) + source.nextBoundedI32(2);
    if (base_radius > 1 and source.nextBoundedI32(60) == 0)
        origin.y += 10 + source.nextBoundedI32(30);
    var relative_y: i32 = 0;
    while (relative_y < spike_height) : (relative_y += 1)
        generateIceSpikeLayer(source, region, origin, relative_y, spike_height, base_radius, packed_ice);
    generateIceSpikeRoots(source, region, origin, base_radius, packed_ice);
}

fn generateIcePatch(source: *ChunkRandom, region: *Region, origin: Position, packed_ice: u16) void {
    const initial = region.state(origin.x, origin.y, origin.z) orelse return;
    if (!initial.nameEquals("minecraft:snow_block")) return;
    const radius = 2 + source.nextBoundedI32(2);
    var z = origin.z - radius;
    while (z <= origin.z + radius) : (z += 1) {
        var x = origin.x - radius;
        while (x <= origin.x + radius) : (x += 1) {
            const dx = x - origin.x;
            const dz = z - origin.z;
            if (dx * dx + dz * dz > radius * radius) continue;
            var y = origin.y - 1;
            while (y <= origin.y + 1) : (y += 1) {
                const state = region.state(x, y, z) orelse continue;
                if (icePatchTarget(state.*))
                    state.* = GeneratedState.fromFeature(packed_ice);
            }
        }
    }
}

fn icePatchTarget(state: GeneratedState) bool {
    return isDirtTag(state) or state.nameEquals("minecraft:snow_block") or
        state.nameEquals("minecraft:ice");
}

fn generateIceSpikeLayer(source: *ChunkRandom, region: *Region, origin: Position, y: i32, height_value: i32, radius: i32, output: u16) void {
    const exact_radius = (1.0 - @as(f32, @floatFromInt(y)) /
        @as(f32, @floatFromInt(height_value))) * @as(f32, @floatFromInt(radius));
    const extent: i32 = @intFromFloat(@ceil(exact_radius));
    var z: i32 = -extent;
    while (z <= extent) : (z += 1) {
        const dz = @abs(@as(f32, @floatFromInt(z))) - 0.25;
        var x: i32 = -extent;
        while (x <= extent) : (x += 1) {
            const dx = @abs(@as(f32, @floatFromInt(x))) - 0.25;
            if (x != 0 or z != 0) if (dx * dx + dz * dz > exact_radius * exact_radius) continue;
            if ((x == -extent or x == extent or z == -extent or z == extent) and
                source.nextF32() > 0.75) continue;
            replaceWithPackedIce(region, .{ .x = origin.x + x, .y = origin.y + y, .z = origin.z + z }, output);
            if (y != 0 and extent > 1)
                replaceWithPackedIce(region, .{ .x = origin.x + x, .y = origin.y - y, .z = origin.z + z }, output);
        }
    }
}

fn generateIceSpikeRoots(source: *ChunkRandom, region: *Region, origin: Position, radius: i32, output: u16) void {
    const extent = std.math.clamp(radius - 1, 0, 1);
    var z: i32 = -extent;
    while (z <= extent) : (z += 1) {
        var x: i32 = -extent;
        while (x <= extent) : (x += 1) {
            var y = origin.y - 1;
            var remaining: i32 = if (@abs(x) == 1 and @abs(z) == 1)
                source.nextBoundedI32(5)
            else
                50;
            while (y > 50) {
                const state = region.state(origin.x + x, y, origin.z + z) orelse break;
                if (!iceSpikeReplaceable(state.*)) break;
                state.* = GeneratedState.fromFeature(output);
                y -= 1;
                remaining -= 1;
                if (remaining > 0) continue;
                y -= source.nextBoundedI32(5) + 1;
                remaining = source.nextBoundedI32(5);
            }
        }
    }
}

fn replaceWithPackedIce(region: *Region, position: Position, output: u16) void {
    const state = region.state(position.x, position.y, position.z) orelse return;
    if (iceSpikeReplaceable(state.*)) state.* = GeneratedState.fromFeature(output);
}

fn iceSpikeReplaceable(state: GeneratedState) bool {
    return isAir(state) or isDirtTag(state) or state.nameEquals("minecraft:snow_block") or
        state.nameEquals("minecraft:ice") or state.nameEquals("minecraft:packed_ice");
}

fn isBaseStone(state: GeneratedState) bool {
    return state == .stone or state.nameEquals("minecraft:stone") or
        state.nameEquals("minecraft:granite") or state.nameEquals("minecraft:diorite") or
        state.nameEquals("minecraft:andesite") or state.nameEquals("minecraft:tuff") or
        state.nameEquals("minecraft:deepslate[axis=y]");
}

fn canFreezeWater(
    temperatures: *const biome_temperature.Sampler,
    biome_climate: biome.Climate,
    state: GeneratedState,
    x: i32,
    y: i32,
    z: i32,
) bool {
    return temperatures.isCold(
        biome_climate.temperature,
        biome_climate.frozen,
        x,
        y,
        z,
    ) and isWater(state);
}

fn canSetSnow(
    temperatures: *const biome_temperature.Sampler,
    biome_climate: biome.Climate,
    target: GeneratedState,
    below: GeneratedState,
    x: i32,
    y: i32,
    z: i32,
) bool {
    if (!temperatures.isCold(
        biome_climate.temperature,
        biome_climate.frozen,
        x,
        y,
        z,
    )) return false;
    if (!isAir(target) and
        !target.nameEquals("minecraft:snow[layers=1]"))
        return false;
    return snowCanSurviveOn(below);
}

fn snowCanSurviveOn(state: GeneratedState) bool {
    if (state.nameEquals("minecraft:ice") or
        state.nameEquals("minecraft:packed_ice") or
        state.nameEquals("minecraft:barrier")) return false;
    if (state.nameEquals("minecraft:honey_block") or
        state.nameEquals("minecraft:soul_sand") or
        state.nameEquals("minecraft:mud")) return true;
    return hasFullTopFace(state);
}

fn hasFullTopFace(state: GeneratedState) bool {
    if (!blocksMovement(state) or isLeafLitter(state) or
        isNearWaterPlant(state)) return false;
    return state.block() != .snow;
}

fn isNearWaterPlant(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    for (data.near_water_patches) |patch|
        if (index == patch.state) return true;
    return false;
}

fn makeSnowy(state: *GeneratedState) void {
    const index = state.featureIndex();
    for (data.freeze_top_layer.snowy_states) |pair| {
        if (index) |feature_index| {
            if (feature_index != pair[0]) continue;
        } else if (!state.sameCanonicalName(GeneratedState.fromFeature(pair[0]))) {
            continue;
        }
        state.* = GeneratedState.fromFeature(pair[1]);
        return;
    }
}

fn generateNearWaterPatch(
    source: *ChunkRandom,
    region: *Region,
    config: data.NearWaterPatch,
    origin: Position,
) void {
    const horizontal_bound = @as(i32, config.xz_spread) + 1;
    const vertical_bound = @as(i32, config.y_spread) + 1;
    for (0..config.tries) |_| {
        const candidate: Position = .{
            .x = origin.x + source.nextBoundedI32(horizontal_bound) -
                source.nextBoundedI32(horizontal_bound),
            .y = origin.y + source.nextBoundedI32(vertical_bound) -
                source.nextBoundedI32(vertical_bound),
            .z = origin.z + source.nextBoundedI32(horizontal_bound) -
                source.nextBoundedI32(horizontal_bound),
        };
        const target = region.state(candidate.x, candidate.y, candidate.z) orelse continue;
        if (!isAir(target.*)) continue;
        switch (config.placement) {
            .sugar_cane => generateSugarCaneColumn(source, region, config, candidate),
            .firefly_bush, .firefly_bush_near_water => {
                if (!nearWaterPlantCanSurvive(region, candidate)) continue;
                target.* = GeneratedState.fromFeature(config.state);
            },
        }
    }
}

fn generateSugarCaneColumn(
    source: *ChunkRandom,
    region: *Region,
    config: data.NearWaterPatch,
    origin: Position,
) void {
    if (!sugarCaneCanPlace(region, origin) or !hasAdjacentWaterBelow(region, origin)) return;
    const range = @as(i32, config.column_maximum - config.column_minimum) + 1;
    const sampled_range = source.nextBoundedI32(range) + 1;
    var column_height =
        @as(i32, config.column_minimum) + source.nextBoundedI32(sampled_range);
    var dy: i32 = 1;
    while (dy < column_height) : (dy += 1) {
        const state = region.state(origin.x, origin.y + dy, origin.z) orelse {
            column_height = dy;
            break;
        };
        if (!isAir(state.*)) {
            column_height = dy;
            break;
        }
    }
    var placed_y: i32 = 0;
    while (placed_y < column_height) : (placed_y += 1) {
        const state = region.state(origin.x, origin.y + placed_y, origin.z) orelse break;
        state.* = GeneratedState.fromFeature(config.state);
    }
}

fn sugarCaneCanPlace(region: *Region, origin: Position) bool {
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (ground.nameEquals("minecraft:sugar_cane[age=0]"))
        return true;
    return (isDirtTag(ground.*) or isSandTag(ground.*)) and
        hasAdjacentWaterBelow(region, origin);
}

fn nearWaterPlantCanPlace(region: *Region, origin: Position) bool {
    const target = region.state(origin.x, origin.y, origin.z) orelse return false;
    if (!isAir(target.*)) return false;
    return nearWaterPlantCanSurvive(region, origin) and hasAdjacentWaterBelow(region, origin);
}

fn nearWaterPlantCanSurvive(region: *Region, origin: Position) bool {
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    return isDirtTag(ground.*) or
        ground.block() == .farmland;
}

fn hasAdjacentWaterBelow(region: *Region, origin: Position) bool {
    const y = origin.y - 1;
    const neighbors = [_]Position{
        .{ .x = origin.x + 1, .y = y, .z = origin.z },
        .{ .x = origin.x - 1, .y = y, .z = origin.z },
        .{ .x = origin.x, .y = y, .z = origin.z + 1 },
        .{ .x = origin.x, .y = y, .z = origin.z - 1 },
    };
    for (neighbors) |position| {
        const state = region.state(position.x, position.y, position.z) orelse continue;
        if (isWater(state.*)) return true;
    }
    return false;
}

fn isDirtTag(state: GeneratedState) bool {
    return state.nameEquals("minecraft:dirt") or
        state.nameEquals("minecraft:grass_block[snowy=false]") or
        state.nameEquals("minecraft:grass_block[snowy=true]") or
        state.nameEquals("minecraft:podzol[snowy=false]") or
        state.nameEquals("minecraft:podzol[snowy=true]") or
        state.nameEquals("minecraft:coarse_dirt") or
        state.nameEquals("minecraft:mycelium[snowy=false]") or
        state.nameEquals("minecraft:mycelium[snowy=true]") or
        state.nameEquals("minecraft:rooted_dirt") or
        state.nameEquals("minecraft:moss_block");
}

fn isSandTag(state: GeneratedState) bool {
    return state.nameEquals("minecraft:sand") or
        state.nameEquals("minecraft:red_sand");
}

fn dryPlantCanSurviveOn(state: GeneratedState) bool {
    if (isDirtTag(state) or isSandTag(state)) return true;
    const block = state.block();
    const id = @intFromEnum(block);
    return block == .terracotta or
        (id >= @intFromEnum(@TypeOf(block).white_terracotta) and
            id <= @intFromEnum(@TypeOf(block).black_terracotta));
}

const Position = struct { x: i32, y: i32, z: i32 };
const LeafLitterTreeKind = enum { oak, birch, spruce, jungle };
const TreeDecoration = struct {
    beehive_probability: f32,
    leaf_litter: bool = false,
    leaf_vine_probability: f32 = 0,
    trunk_vines: bool = false,
    cocoa_probability: f32 = 0,
};
const horizontal_directions = [_]Direction{ .north, .south, .west, .east };

fn generateFallenTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    kind: LeafLitterTreeKind,
    maximum_length: u8,
) void {
    placeTreeState(region, origin, fallenLogState(kind, .up));
    if (kind == .oak or kind == .jungle) decorateFallenOakStump(source, region, origin);

    const direction = horizontal_directions[@intCast(source.nextBoundedI32(4))];
    const minimum_length: i32 = switch (kind) {
        .oak => 4,
        .birch => 5,
        .spruce => 6,
        .jungle => 4,
    };
    const configured_length = minimum_length + source.nextBoundedI32(
        @as(i32, maximum_length) - minimum_length + 1,
    );
    var start = offsetPosition(
        origin,
        direction,
        2 + source.nextBoundedI32(2),
    );
    start.y += 1;
    for (0..6) |_| {
        if (fallenLogPositionValid(region, start)) break;
        start.y -= 1;
    }
    const length = configured_length - 2;
    if (!fallenLogFits(region, start, direction, length)) return;
    placeFallenLog(source, region, start, direction, length, kind);
}

fn fallenLogPositionValid(region: *Region, position: Position) bool {
    const target = region.state(position.x, position.y, position.z) orelse return false;
    const below = region.state(position.x, position.y - 1, position.z) orelse return false;
    return canTreeReplace(target.*) and hasFullTopFace(below.*);
}

fn fallenLogFits(
    region: *Region,
    start: Position,
    direction: Direction,
    length: i32,
) bool {
    var unsupported: u8 = 0;
    var position = start;
    var index: i32 = 0;
    while (index < length) : (index += 1) {
        const target = region.state(position.x, position.y, position.z) orelse return false;
        if (!canTreeReplace(target.*)) return false;
        const below = region.state(position.x, position.y - 1, position.z) orelse return false;
        unsupported = if (hasFullTopFace(below.*)) 0 else unsupported + 1;
        if (unsupported > 2) return false;
        position = offsetPosition(position, direction, 1);
    }
    return true;
}

fn placeFallenLog(
    source: *ChunkRandom,
    region: *Region,
    start: Position,
    direction: Direction,
    length: i32,
    kind: LeafLitterTreeKind,
) void {
    var logs: [16]Position = undefined;
    var position = start;
    const count: usize = @intCast(length);
    for (logs[0..count]) |*log| {
        placeTreeState(region, position, fallenLogState(kind, direction));
        log.* = position;
        position = offsetPosition(position, direction, 1);
    }
    var shuffled = logs;
    shufflePositions(source, shuffled[0..count]);
    for (shuffled[0..count]) |log| decorateFallenLog(source, region, log);
}

fn fallenLogState(kind: LeafLitterTreeKind, direction: Direction) u16 {
    const config = data.oak_leaf_litter_trees;
    return switch (kind) {
        .oak => if (direction.axis() == .x) config.log_x_state else if (direction.axis() == .z) config.log_z_state else config.log_state,
        .birch => if (direction.axis() == .x) config.birch_log_x_state else if (direction.axis() == .z) config.birch_log_z_state else config.birch_log_state,
        .spruce => if (direction.axis() == .x) config.spruce_log_x_state else if (direction.axis() == .z) config.spruce_log_z_state else config.spruce_log_state,
        .jungle => if (direction.axis() == .x) config.jungle_log_x_state else if (direction.axis() == .z) config.jungle_log_z_state else config.jungle_log_state,
    };
}

fn decorateFallenOakStump(source: *ChunkRandom, region: *Region, origin: Position) void {
    const directions = [_]Direction{ .west, .east, .north, .south };
    const states = [_]u16{
        data.oak_leaf_litter_trees.vine_east_state,
        data.oak_leaf_litter_trees.vine_west_state,
        data.oak_leaf_litter_trees.vine_south_state,
        data.oak_leaf_litter_trees.vine_north_state,
    };
    for (directions, states) |direction, state| {
        if (source.nextBoundedI32(3) == 0) continue;
        const position = offsetPosition(origin, direction, 1);
        const target = region.state(position.x, position.y, position.z) orelse continue;
        if (isAir(target.*)) target.* = GeneratedState.fromFeature(state);
    }
}

fn decorateFallenLog(source: *ChunkRandom, region: *Region, log: Position) void {
    _ = source.nextBoundedI32(1);
    const position = offsetPosition(log, .up, 1);
    const target = region.state(position.x, position.y, position.z);
    if (source.nextF32() > 0.1 or target == null or !isAir(target.?.*)) return;
    const state = if (source.nextBoundedI32(3) < 2)
        data.oak_leaf_litter_trees.red_mushroom_state
    else
        data.oak_leaf_litter_trees.brown_mushroom_state;
    target.?.* = GeneratedState.fromFeature(state);
}

fn shufflePositions(source: *ChunkRandom, positions: []Position) void {
    var count = positions.len;
    while (count > 1) {
        const selected: usize = @intCast(source.nextBoundedI32(@intCast(count)));
        count -= 1;
        std.mem.swap(Position, &positions[count], &positions[selected]);
    }
}

fn offsetPosition(position: Position, direction: Direction, distance: i32) Position {
    const offset = direction.offset();
    return .{
        .x = position.x + offset.x * distance,
        .y = position.y + offset.y * distance,
        .z = position.z + offset.z * distance,
    };
}

fn generateLeafLitterTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    kind: LeafLitterTreeKind,
    birch_height_rand_b: u8,
    decoration: TreeDecoration,
) bool {
    const config = data.oak_leaf_litter_trees;
    const base_height: u8 = switch (kind) {
        .oak => config.trunk_base_height,
        .birch => 5,
        .spruce, .jungle => unreachable,
    };
    const trunk_state: u16 = switch (kind) {
        .oak => config.log_state,
        .birch => config.birch_log_state,
        .spruce, .jungle => unreachable,
    };
    const leaf_state_base: u16 = switch (kind) {
        .oak => config.leaf_state_base,
        .birch => config.birch_leaf_state_base,
        .spruce, .jungle => unreachable,
    };
    const trunk_height = @as(i32, base_height) +
        source.nextBoundedI32(@as(i32, config.trunk_height_rand_a) + 1) +
        source.nextBoundedI32(@as(i32, if (kind == .birch)
            birch_height_rand_b
        else
            config.trunk_height_rand_b) + 1);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    const usable_height = treeUsableHeight(region, origin, trunk_height);
    if (usable_height < trunk_height) return false;

    var logs: [32]Position = undefined;
    var log_count: usize = 0;
    const below_position: Position = .{
        .x = origin.x,
        .y = origin.y - 1,
        .z = origin.z,
    };
    const below =
        region.state(below_position.x, below_position.y, below_position.z) orelse return false;
    if (isGrassBlock(below.*)) {
        below.* = GeneratedState.fromFeature(config.dirt_state);
        logs[log_count] = below_position;
        log_count += 1;
    }

    var dy: i32 = 0;
    while (dy < usable_height) : (dy += 1) {
        const position: Position = .{
            .x = origin.x,
            .y = origin.y + dy,
            .z = origin.z,
        };
        const state = region.state(position.x, position.y, position.z) orelse continue;
        if (!canTreeReplace(state.*)) continue;
        placeTreeState(region, position, trunk_state);
        logs[log_count] = position;
        log_count += 1;
    }
    if (log_count == 0) return false;

    var leaves: [128]Position = undefined;
    var leaf_count: usize = 0;
    const center: Position = .{
        .x = origin.x,
        .y = origin.y + usable_height,
        .z = origin.z,
    };
    var offset: i32 = 0;
    const lower_offset = -@as(i32, config.foliage_height);
    while (offset >= lower_offset) : (offset -= 1) {
        const radius: i32 = @max(
            @as(i32, config.foliage_radius) - 1 - @divTrunc(offset, 2),
            0,
        );
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                const corner = @abs(dx) == radius and @abs(dz) == radius;
                if (corner and (source.nextBoundedI32(2) == 0 or offset == 0)) continue;
                const position: Position = .{
                    .x = center.x + dx,
                    .y = center.y + offset,
                    .z = center.z + dz,
                };
                const state = region.state(position.x, position.y, position.z) orelse continue;
                if (!canTreeReplace(state.*)) continue;
                placeTreeState(region, position, leaf_state_base + 6);
                if (leaf_count < leaves.len) {
                    leaves[leaf_count] = position;
                    leaf_count += 1;
                }
            }
        }
    }

    finishStraightTree(
        source,
        region,
        logs[0..log_count],
        leaves[0..leaf_count],
        decoration,
    );
    return leaf_count != 0;
}

fn generateSwampOakTree(source: *ChunkRandom, region: *Region, origin: Position) bool {
    const config = data.oak_leaf_litter_trees;
    const trunk_height = 5 + source.nextBoundedI32(4) + source.nextBoundedI32(1);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    if (treeUsableHeight(region, origin, trunk_height) < trunk_height) return false;
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (!isDirtTag(ground.*)) return false;
    if (isGrassBlock(ground.*)) ground.* = GeneratedState.fromFeature(config.dirt_state);

    var logs: [32]Position = undefined;
    var log_count: usize = 0;
    var dy: i32 = 0;
    while (dy < trunk_height) : (dy += 1) {
        const position = Position{ .x = origin.x, .y = origin.y + dy, .z = origin.z };
        const target = region.state(position.x, position.y, position.z) orelse continue;
        if (!canTreeReplace(target.*)) continue;
        target.* = GeneratedState.fromFeature(config.log_state);
        logs[log_count] = position;
        log_count += 1;
    }
    if (log_count == 0) return false;
    var leaves: [256]Position = undefined;
    var leaf_count: usize = 0;
    const center = Position{ .x = origin.x, .y = origin.y + trunk_height, .z = origin.z };
    var offset: i32 = 0;
    while (offset >= -3) : (offset -= 1) {
        const radius = @max(2 - @divTrunc(offset, 2), 0);
        placeBlobLeafLayer(source, region, center, offset, radius, &leaves, &leaf_count);
    }
    finishStraightTree(source, region, logs[0..log_count], leaves[0..leaf_count], .{
        .beehive_probability = 0,
        .leaf_vine_probability = 0.25,
    });
    return leaf_count != 0;
}

fn generateAcaciaTree(source: *ChunkRandom, region: *Region, origin: Position) bool {
    const config = data.oak_leaf_litter_trees;
    const trunk_height = 5 + source.nextBoundedI32(3) + source.nextBoundedI32(3);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    if (treeUsableHeight(region, origin, trunk_height) < trunk_height) return false;
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (!isDirtTag(ground.*)) return false;
    if (isGrassBlock(ground.*)) ground.* = GeneratedState.fromFeature(config.dirt_state);

    var logs: [32]Position = undefined;
    var leaves: [256]Position = undefined;
    var log_count: usize = 0;
    var leaf_count: usize = 0;
    const directions = [_]Direction{ .north, .south, .west, .east };
    const main_direction = directions[@intCast(source.nextBoundedI32(4))];
    const bend_start = trunk_height - source.nextBoundedI32(4) - 1;
    var bend_remaining = 3 - source.nextBoundedI32(3);
    var main = origin;
    var main_top: ?Position = null;
    for (0..@intCast(trunk_height)) |level| {
        if (level >= bend_start and bend_remaining > 0) {
            main = offsetPosition(main, main_direction, 1);
            bend_remaining -= 1;
        }
        main.y = origin.y + @as(i32, @intCast(level));
        if (placeAcaciaLog(region, main, &logs, &log_count))
            main_top = offsetPosition(main, .up, 1);
    }
    if (main_top) |center| placeAcaciaFoliage(region, center, 1, &leaves, &leaf_count);
    generateAcaciaFork(source, region, origin, trunk_height, bend_start, main_direction, &logs, &log_count, &leaves, &leaf_count);
    if (log_count == 0) return false;
    finishStraightTree(source, region, logs[0..log_count], leaves[0..leaf_count], .{
        .beehive_probability = 0,
    });
    return true;
}

fn generateAcaciaFork(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    trunk_height: i32,
    bend_start: i32,
    main_direction: Direction,
    logs: *[32]Position,
    log_count: *usize,
    leaves: *[256]Position,
    leaf_count: *usize,
) void {
    const directions = [_]Direction{ .north, .south, .west, .east };
    const direction = directions[@intCast(source.nextBoundedI32(4))];
    if (direction == main_direction) return;
    var level = bend_start - source.nextBoundedI32(2) - 1;
    var remaining = 1 + source.nextBoundedI32(3);
    var position = origin;
    var top: ?Position = null;
    while (level < trunk_height and remaining > 0) : ({
        level += 1;
        remaining -= 1;
    }) {
        if (level < 1) continue;
        position = offsetPosition(position, direction, 1);
        position.y = origin.y + level;
        if (placeAcaciaLog(region, position, logs, log_count))
            top = offsetPosition(position, .up, 1);
    }
    if (top) |center| placeAcaciaFoliage(region, center, 0, leaves, leaf_count);
}

fn placeAcaciaLog(
    region: *Region,
    position: Position,
    logs: *[32]Position,
    count: *usize,
) bool {
    const target = region.state(position.x, position.y, position.z) orelse return false;
    if (!canTreeReplace(target.*)) return false;
    target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.acacia_log_state);
    std.debug.assert(count.* < logs.len);
    logs[count.*] = position;
    count.* += 1;
    return true;
}

fn placeAcaciaFoliage(
    region: *Region,
    center: Position,
    node_radius: i32,
    leaves: *[256]Position,
    count: *usize,
) void {
    placeAcaciaLeafLayer(region, center, -1, 2 + node_radius, leaves, count);
    placeAcaciaLeafLayer(region, center, 0, 1, leaves, count);
    placeAcaciaLeafLayer(region, center, 0, 1 + node_radius, leaves, count);
}

fn placeAcaciaLeafLayer(
    region: *Region,
    center: Position,
    offset_y: i32,
    radius: i32,
    leaves: *[256]Position,
    count: *usize,
) void {
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            const x = @abs(dx);
            const z = @abs(dz);
            const invalid = if (offset_y == 0)
                (x > 1 or z > 1) and x != 0 and z != 0
            else
                x == radius and z == radius and radius > 0;
            if (invalid) continue;
            const position = Position{ .x = center.x + dx, .y = center.y + offset_y, .z = center.z + dz };
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!canTreeReplace(target.*) or containsPosition(leaves[0..count.*], position)) continue;
            target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.acacia_leaf_state_base + 6);
            std.debug.assert(count.* < leaves.len);
            leaves[count.*] = position;
            count.* += 1;
        }
    }
}

fn containsPosition(positions: []const Position, candidate: Position) bool {
    for (positions) |position|
        if (position.x == candidate.x and position.y == candidate.y and position.z == candidate.z)
            return true;
    return false;
}

fn generateMegaConiferTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    spruce_crown: bool,
) bool {
    const config = data.oak_leaf_litter_trees;
    const trunk_height = 13 + source.nextBoundedI32(3) + source.nextBoundedI32(15);
    const crown_minimum: i32 = if (spruce_crown) 13 else 3;
    const crown_height = crown_minimum + source.nextBoundedI32(5);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    if (treeUsableHeight(region, origin, trunk_height) < trunk_height) return false;
    if (!megaTreeGround(region, origin, config.dirt_state)) return false;

    var logs: [128]Position = undefined;
    var leaves: [1024]Position = undefined;
    var log_count: usize = 0;
    var leaf_count: usize = 0;
    var dy: i32 = 0;
    while (dy < trunk_height) : (dy += 1) {
        placeMegaLog(region, .{ .x = origin.x, .y = origin.y + dy, .z = origin.z }, &logs, &log_count);
        if (dy >= trunk_height - 1) continue;
        placeMegaLog(region, .{ .x = origin.x + 1, .y = origin.y + dy, .z = origin.z }, &logs, &log_count);
        placeMegaLog(region, .{ .x = origin.x + 1, .y = origin.y + dy, .z = origin.z + 1 }, &logs, &log_count);
        placeMegaLog(region, .{ .x = origin.x, .y = origin.y + dy, .z = origin.z + 1 }, &logs, &log_count);
    }
    placeMegaPineFoliage(region, .{ .x = origin.x, .y = origin.y + trunk_height, .z = origin.z }, crown_height, &leaves, &leaf_count);
    alterMegaTreeGround(source, region, origin);
    finishStraightTree(source, region, logs[0..log_count], leaves[0..leaf_count], .{
        .beehive_probability = 0,
    });
    return log_count != 0;
}

fn generateJungleTree(source: *ChunkRandom, region: *Region, origin: Position, bush: bool) bool {
    const config = data.oak_leaf_litter_trees;
    const trunk_height = if (bush)
        1 + source.nextBoundedI32(1) + source.nextBoundedI32(1)
    else
        4 + source.nextBoundedI32(9) + source.nextBoundedI32(1);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    if (treeUsableHeight(region, origin, trunk_height) < trunk_height) return false;
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (!isDirtTag(ground.*)) return false;
    if (isGrassBlock(ground.*)) ground.* = GeneratedState.fromFeature(config.dirt_state);

    var logs: [32]Position = undefined;
    var leaves: [512]Position = undefined;
    var log_count: usize = 0;
    var leaf_count: usize = 0;
    for (0..@intCast(trunk_height)) |dy| {
        const position = Position{ .x = origin.x, .y = origin.y + @as(i32, @intCast(dy)), .z = origin.z };
        placeJungleLog(region, position, &logs, &log_count);
    }
    const center = Position{ .x = origin.x, .y = origin.y + trunk_height, .z = origin.z };
    if (bush)
        placeJungleBushFoliage(source, region, center, &leaves, &leaf_count)
    else
        placeJungleBlobFoliage(source, region, center, &leaves, &leaf_count);
    finishStraightTree(source, region, logs[0..log_count], leaves[0..leaf_count], if (bush) .{
        .beehive_probability = 0,
    } else .{
        .beehive_probability = 0,
        .leaf_vine_probability = 0.25,
        .trunk_vines = true,
        .cocoa_probability = 0.2,
    });
    return log_count != 0;
}

fn placeJungleLog(region: *Region, position: Position, logs: anytype, count: *usize) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!canTreeReplace(target.*)) return;
    target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.jungle_log_state);
    std.debug.assert(count.* < logs.len);
    logs[count.*] = position;
    count.* += 1;
}

fn placeJungleBlobFoliage(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    leaves: *[512]Position,
    count: *usize,
) void {
    var offset: i32 = 0;
    while (offset >= -3) : (offset -= 1) {
        const radius = @max(1 - @divTrunc(offset, 2), 0);
        placeJungleRandomLeafLayer(source, region, center, offset, radius, false, leaves, count);
    }
}

fn placeJungleBushFoliage(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    leaves: *[512]Position,
    count: *usize,
) void {
    var offset: i32 = 1;
    while (offset >= -1) : (offset -= 1)
        placeJungleRandomLeafLayer(source, region, center, offset, 1 - offset, false, leaves, count);
}

fn placeJungleRandomLeafLayer(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    offset_y: i32,
    radius: i32,
    giant: bool,
    leaves: *[512]Position,
    count: *usize,
) void {
    const extra: i32 = if (giant) 1 else 0;
    var dx = -radius;
    while (dx <= radius + extra) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius + extra) : (dz += 1) {
            const x = if (giant) @min(@abs(dx), @abs(dx - 1)) else @abs(dx);
            const z = if (giant) @min(@abs(dz), @abs(dz - 1)) else @abs(dz);
            if (x == radius and z == radius and source.nextBoundedI32(2) == 0) continue;
            placeJungleLeaf(region, .{ .x = center.x + dx, .y = center.y + offset_y, .z = center.z + dz }, leaves, count);
        }
    }
}

fn placeJungleLeaf(region: *Region, position: Position, leaves: anytype, count: *usize) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!canTreeReplace(target.*) or containsPosition(leaves[0..count.*], position)) return;
    target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.jungle_leaf_state_base + 6);
    std.debug.assert(count.* < leaves.len);
    leaves[count.*] = position;
    count.* += 1;
}

const JungleNode = struct { center: Position, radius: i32, giant: bool };

fn generateMegaJungleTree(source: *ChunkRandom, region: *Region, origin: Position) bool {
    const config = data.oak_leaf_litter_trees;
    const trunk_height = 10 + source.nextBoundedI32(3) + source.nextBoundedI32(20);
    if (origin.y < minimum_y + 1 or origin.y + trunk_height + 1 > minimum_y + height)
        return false;
    if (treeUsableHeight(region, origin, trunk_height) < trunk_height) return false;
    if (!megaTreeGround(region, origin, config.dirt_state)) return false;
    var logs: [256]Position = undefined;
    var leaves: [1024]Position = undefined;
    var nodes: [16]JungleNode = undefined;
    var log_count: usize = 0;
    var leaf_count: usize = 0;
    var node_count: usize = 1;
    nodes[0] = .{ .center = .{ .x = origin.x, .y = origin.y + trunk_height, .z = origin.z }, .radius = 0, .giant = true };
    placeMegaJungleTrunk(region, origin, trunk_height, &logs, &log_count);
    placeMegaJungleBranches(source, region, origin, trunk_height, &logs, &log_count, &nodes, &node_count);
    for (nodes[0..node_count]) |node|
        placeJungleNodeFoliage(source, region, node, &leaves, &leaf_count);
    finishStraightTree(source, region, logs[0..log_count], leaves[0..leaf_count], .{
        .beehive_probability = 0,
        .leaf_vine_probability = 0.25,
        .trunk_vines = true,
    });
    return log_count != 0;
}

fn placeMegaJungleTrunk(
    region: *Region,
    origin: Position,
    height_value: i32,
    logs: *[256]Position,
    count: *usize,
) void {
    var dy: i32 = 0;
    while (dy < height_value) : (dy += 1) {
        placeJungleLog(region, .{ .x = origin.x, .y = origin.y + dy, .z = origin.z }, logs, count);
        if (dy >= height_value - 1) continue;
        placeJungleLog(region, .{ .x = origin.x + 1, .y = origin.y + dy, .z = origin.z }, logs, count);
        placeJungleLog(region, .{ .x = origin.x + 1, .y = origin.y + dy, .z = origin.z + 1 }, logs, count);
        placeJungleLog(region, .{ .x = origin.x, .y = origin.y + dy, .z = origin.z + 1 }, logs, count);
    }
}

fn placeMegaJungleBranches(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    height_value: i32,
    logs: *[256]Position,
    log_count: *usize,
    nodes: *[16]JungleNode,
    node_count: *usize,
) void {
    var branch_y = height_value - 2 - source.nextBoundedI32(4);
    while (branch_y > @divTrunc(height_value, 2)) : (branch_y -= 2 + source.nextBoundedI32(4)) {
        const angle = source.nextF32() * std.math.tau;
        var end_x: i32 = 0;
        var end_z: i32 = 0;
        for (0..5) |step| {
            const distance: f32 = @floatFromInt(step);
            end_x = @intFromFloat(1.5 + @cos(angle) * distance);
            end_z = @intFromFloat(1.5 + @sin(angle) * distance);
            placeJungleLog(region, .{
                .x = origin.x + end_x,
                .y = origin.y + branch_y - 3 + @as(i32, @intCast(step / 2)),
                .z = origin.z + end_z,
            }, logs, log_count);
        }
        std.debug.assert(node_count.* < nodes.len);
        nodes[node_count.*] = .{
            .center = .{ .x = origin.x + end_x, .y = origin.y + branch_y, .z = origin.z + end_z },
            .radius = -2,
            .giant = false,
        };
        node_count.* += 1;
    }
}

fn placeJungleNodeFoliage(
    source: *ChunkRandom,
    region: *Region,
    node: JungleNode,
    leaves: *[1024]Position,
    count: *usize,
) void {
    const depth = if (node.giant) 2 else 1 + source.nextBoundedI32(2);
    var offset: i32 = 0;
    while (offset >= -depth) : (offset -= 1) {
        const radius = 2 + node.radius + 1 - offset;
        placeJungleCircularLayer(region, node.center, offset, radius, node.giant, leaves, count);
    }
}

fn placeJungleCircularLayer(
    region: *Region,
    center: Position,
    offset_y: i32,
    radius: i32,
    giant: bool,
    leaves: *[1024]Position,
    count: *usize,
) void {
    const extra: i32 = if (giant) 1 else 0;
    var dx = -radius;
    while (dx <= radius + extra) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius + extra) : (dz += 1) {
            const x = if (giant) @min(@abs(dx), @abs(dx - 1)) else @abs(dx);
            const z = if (giant) @min(@abs(dz), @abs(dz - 1)) else @abs(dz);
            if (x + z >= 7 or x * x + z * z > radius * radius) continue;
            placeJungleLeaf(region, .{ .x = center.x + dx, .y = center.y + offset_y, .z = center.z + dz }, leaves, count);
        }
    }
}

fn megaTreeGround(region: *Region, origin: Position, dirt_state: u16) bool {
    const offsets = [_]Position{
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 1, .y = -1, .z = 0 },
        .{ .x = 0, .y = -1, .z = 1 },
        .{ .x = 1, .y = -1, .z = 1 },
    };
    for (offsets) |offset| {
        const target = region.state(origin.x + offset.x, origin.y + offset.y, origin.z + offset.z) orelse return false;
        if (!isDirtTag(target.*)) return false;
        if (isGrassBlock(target.*)) target.* = GeneratedState.fromFeature(dirt_state);
    }
    return true;
}

fn placeMegaLog(region: *Region, position: Position, logs: *[128]Position, count: *usize) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    if (!canTreeReplace(target.*)) return;
    target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.spruce_log_state);
    std.debug.assert(count.* < logs.len);
    logs[count.*] = position;
    count.* += 1;
}

fn placeMegaPineFoliage(
    region: *Region,
    center: Position,
    crown_height: i32,
    leaves: *[1024]Position,
    count: *usize,
) void {
    var previous_radius: i32 = 0;
    var y = center.y - crown_height;
    while (y <= center.y) : (y += 1) {
        const distance = center.y - y;
        const radius = @as(i32, @intFromFloat(@floor(
            @as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(crown_height)) * 3.5,
        )));
        const layer_radius = if (distance > 0 and radius == previous_radius and (y & 1) == 0)
            radius + 1
        else
            radius;
        placeMegaPineLayer(region, .{ .x = center.x, .y = y, .z = center.z }, layer_radius, leaves, count);
        previous_radius = radius;
    }
}

fn placeMegaPineLayer(
    region: *Region,
    center: Position,
    radius: i32,
    leaves: *[1024]Position,
    count: *usize,
) void {
    var dx = -radius;
    while (dx <= radius + 1) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius + 1) : (dz += 1) {
            const x = @min(@abs(dx), @abs(dx - 1));
            const z = @min(@abs(dz), @abs(dz - 1));
            if (x + z >= 7 or x * x + z * z > radius * radius) continue;
            const position = Position{ .x = center.x + dx, .y = center.y, .z = center.z + dz };
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!canTreeReplace(target.*) or containsPosition(leaves[0..count.*], position)) continue;
            target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.spruce_leaf_state_base + 6);
            std.debug.assert(count.* < leaves.len);
            leaves[count.*] = position;
            count.* += 1;
        }
    }
}

fn alterMegaTreeGround(source: *ChunkRandom, region: *Region, origin: Position) void {
    const bases = [_]Position{
        .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 }, .{ .x = 1, .y = 0, .z = 1 },
    };
    const corners = [_]Position{
        .{ .x = -1, .y = 0, .z = -1 }, .{ .x = 2, .y = 0, .z = -1 },
        .{ .x = -1, .y = 0, .z = 2 },  .{ .x = 2, .y = 0, .z = 2 },
    };
    for (bases) |base| {
        for (corners) |corner| alterGroundArea(region, .{
            .x = origin.x + base.x + corner.x,
            .y = origin.y,
            .z = origin.z + base.z + corner.z,
        });
        for (0..5) |_| {
            const value = source.nextBoundedI32(64);
            const x = @mod(value, 8);
            const z = @divTrunc(value, 8);
            if (x != 0 and x != 7 and z != 0 and z != 7) continue;
            alterGroundArea(region, .{
                .x = origin.x + base.x - 3 + x,
                .y = origin.y,
                .z = origin.z + base.z - 3 + z,
            });
        }
    }
}

fn alterGroundArea(region: *Region, origin: Position) void {
    var dx: i32 = -2;
    while (dx <= 2) : (dx += 1) {
        var dz: i32 = -2;
        while (dz <= 2) : (dz += 1) {
            if (@abs(dx) == 2 and @abs(dz) == 2) continue;
            alterGroundColumn(region, .{ .x = origin.x + dx, .y = origin.y, .z = origin.z + dz });
        }
    }
}

fn alterGroundColumn(region: *Region, origin: Position) void {
    var dy: i32 = 2;
    while (dy >= -3) : (dy -= 1) {
        const target = region.state(origin.x, origin.y + dy, origin.z) orelse continue;
        if (isDirtTag(target.*)) {
            target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.podzol_state);
            return;
        }
        if (!isAir(target.*) and dy < 0) return;
    }
}

fn placeBlobLeafLayer(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    offset: i32,
    radius: i32,
    leaves: *[256]Position,
    leaf_count: *usize,
) void {
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            const corner = @abs(dx) == radius and @abs(dz) == radius;
            if (corner and (source.nextBoundedI32(2) == 0 or offset == 0)) continue;
            const position = Position{ .x = center.x + dx, .y = center.y + offset, .z = center.z + dz };
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!canTreeReplace(target.*)) continue;
            target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.leaf_state_base + 6);
            std.debug.assert(leaf_count.* < leaves.len);
            leaves[leaf_count.*] = position;
            leaf_count.* += 1;
        }
    }
}

fn finishStraightTree(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    leaves: []const Position,
    decoration: TreeDecoration,
) void {
    var decorations: [1024]Position = undefined;
    var decoration_count: usize = 0;
    if (decoration.cocoa_probability > 0)
        placeTreeCocoa(source, region, logs, decoration.cocoa_probability, &decorations, &decoration_count);
    if (decoration.trunk_vines)
        placeTrunkVines(source, region, logs, &decorations, &decoration_count);
    if (decoration.leaf_vine_probability > 0)
        placeLeafVines(source, region, leaves, decoration.leaf_vine_probability, &decorations, &decoration_count);
    placeTreeBeehive(source, region, logs, leaves, decoration.beehive_probability);
    if (!decoration.leaf_litter) {
        resolveLeafDistance(region, logs, leaves, decorations[0..decoration_count]);
        cleanupTallPlants(region, logs, leaves, decorations[0..decoration_count]);
        return;
    }
    placeLeafLitter(source, region, logs, 96, 4, 2, 12, &decorations, &decoration_count);
    placeLeafLitter(source, region, logs, 150, 2, 2, 16, &decorations, &decoration_count);
    resolveLeafDistance(region, logs, leaves, decorations[0..decoration_count]);
    cleanupTallPlants(region, logs, leaves, decorations[0..decoration_count]);
}

fn placeTreeCocoa(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    probability: f32,
    decorations: *[1024]Position,
    decoration_count: *usize,
) void {
    if (logs.len == 0 or source.nextF32() >= probability) return;
    var ordered: [256]Position = undefined;
    std.debug.assert(logs.len <= ordered.len);
    @memcpy(ordered[0..logs.len], logs);
    stableSortPositionsY(ordered[0..logs.len]);
    const base_y = ordered[0].y;
    const directions = [_]Direction{ .north, .east, .south, .west };
    for (ordered[0..logs.len]) |log| {
        if (log.y - base_y > 2) continue;
        for (directions, 0..) |facing, state_index| {
            if (source.nextF32() > 0.25) continue;
            const position = offsetPosition(log, facing.opposite(), 1);
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!isAir(target.*)) continue;
            const age: usize = @intCast(source.nextBoundedI32(3));
            target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.cocoa_states[state_index][age]);
            addDecoration(position, decorations, decoration_count);
        }
    }
}

fn placeTrunkVines(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    decorations: *[1024]Position,
    decoration_count: *usize,
) void {
    var ordered: [256]Position = undefined;
    std.debug.assert(logs.len <= ordered.len);
    @memcpy(ordered[0..logs.len], logs);
    stableSortPositionsY(ordered[0..logs.len]);
    const directions = [_]Direction{ .west, .east, .north, .south };
    const states = [_]u16{
        data.oak_leaf_litter_trees.vine_east_state,
        data.oak_leaf_litter_trees.vine_west_state,
        data.oak_leaf_litter_trees.vine_south_state,
        data.oak_leaf_litter_trees.vine_north_state,
    };
    for (ordered[0..logs.len]) |log| {
        for (directions, states) |direction, state| {
            if (source.nextBoundedI32(3) == 0) continue;
            const position = offsetPosition(log, direction, 1);
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!isAir(target.*)) continue;
            target.* = GeneratedState.fromFeature(state);
            addDecoration(position, decorations, decoration_count);
        }
    }
}

fn addDecoration(position: Position, decorations: *[1024]Position, count: *usize) void {
    if (containsPosition(decorations[0..count.*], position)) return;
    std.debug.assert(count.* < decorations.len);
    decorations[count.*] = position;
    count.* += 1;
}

fn placeLeafVines(
    source: *ChunkRandom,
    region: *Region,
    leaves: []const Position,
    probability: f32,
    decorations: *[1024]Position,
    decoration_count: *usize,
) void {
    var ordered: [512]Position = undefined;
    std.debug.assert(leaves.len <= ordered.len);
    @memcpy(ordered[0..leaves.len], leaves);
    stableSortPositionsY(ordered[0..leaves.len]);
    const directions = [_]Direction{ .west, .east, .north, .south };
    const states = [_]u16{
        data.oak_leaf_litter_trees.vine_east_state,
        data.oak_leaf_litter_trees.vine_west_state,
        data.oak_leaf_litter_trees.vine_south_state,
        data.oak_leaf_litter_trees.vine_north_state,
    };
    for (ordered[0..leaves.len]) |leaf| {
        for (directions, states) |direction, state| {
            if (source.nextF32() >= probability) continue;
            placeLeafVineColumn(region, offsetPosition(leaf, direction, 1), state, decorations, decoration_count);
        }
    }
}

fn placeLeafVineColumn(
    region: *Region,
    start: Position,
    state: u16,
    decorations: *[1024]Position,
    decoration_count: *usize,
) void {
    var position = start;
    var remaining: u8 = 5;
    while (remaining > 0) : (remaining -= 1) {
        const target = region.state(position.x, position.y, position.z) orelse return;
        if (!isAir(target.*)) return;
        target.* = GeneratedState.fromFeature(state);
        std.debug.assert(decoration_count.* < decorations.len);
        decorations[decoration_count.*] = position;
        decoration_count.* += 1;
        position.y -= 1;
    }
}

fn stableSortPositionsY(positions: []Position) void {
    var index: usize = 1;
    while (index < positions.len) : (index += 1) {
        const value = positions[index];
        var insertion = index;
        while (insertion > 0 and positions[insertion - 1].y > value.y) : (insertion -= 1)
            positions[insertion] = positions[insertion - 1];
        positions[insertion] = value;
    }
}

fn generateConiferTree(
    source: *ChunkRandom,
    region: *Region,
    initial_origin: Position,
    pine: bool,
    on_snow: bool,
) bool {
    const origin = if (on_snow)
        coniferSnowOrigin(region, initial_origin) orelse return false
    else
        initial_origin;
    if (!on_snow and !saplingWouldSurvive(region, origin)) return false;
    const requested_height = if (pine)
        6 + source.nextBoundedI32(5) + source.nextBoundedI32(1)
    else
        5 + source.nextBoundedI32(3) + source.nextBoundedI32(2);
    const foliage_height = if (pine)
        3 + source.nextBoundedI32(2)
    else
        @max(4, requested_height - 1 - source.nextBoundedI32(2));
    const bare_height = requested_height - foliage_height;
    const foliage_radius = if (pine)
        1 + source.nextBoundedI32(@max(bare_height + 1, 1))
    else
        2 + source.nextBoundedI32(2);
    if (origin.y < minimum_y + 1 or
        origin.y + requested_height + 1 > minimum_y + height) return false;
    if (treeUsableHeightLayers(region, origin, requested_height, 2, 0, 2) <
        requested_height) return false;

    var logs: [32]Position = undefined;
    const log_count = placeConiferTrunk(region, origin, requested_height, &logs) orelse
        return false;
    var leaves: [512]Position = undefined;
    var leaf_count: usize = 0;
    const center = Position{
        .x = origin.x,
        .y = origin.y + requested_height,
        .z = origin.z,
    };
    if (pine)
        generatePineFoliage(
            source,
            region,
            center,
            foliage_height,
            foliage_radius,
            &leaves,
            &leaf_count,
        )
    else
        generateSpruceFoliage(
            source,
            region,
            center,
            foliage_height,
            foliage_radius,
            &leaves,
            &leaf_count,
        );
    resolveLeafDistance(region, logs[0..log_count], leaves[0..leaf_count], &.{});
    cleanupTallPlants(region, logs[0..log_count], leaves[0..leaf_count], &.{});
    return log_count != 0 and leaf_count != 0;
}

fn placeConiferTrunk(
    region: *Region,
    origin: Position,
    height_requested: i32,
    logs: *[32]Position,
) ?usize {
    var count: usize = 0;
    const dirt_position = Position{ .x = origin.x, .y = origin.y - 1, .z = origin.z };
    const dirt = region.state(dirt_position.x, dirt_position.y, dirt_position.z) orelse
        return null;
    if (!isPlainTreeSoil(dirt.*)) {
        dirt.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.dirt_state);
        logs[count] = dirt_position;
        count += 1;
    }
    for (0..@intCast(height_requested)) |dy| {
        const position = Position{
            .x = origin.x,
            .y = origin.y + @as(i32, @intCast(dy)),
            .z = origin.z,
        };
        const target = region.state(position.x, position.y, position.z) orelse continue;
        if (!canTreeReplace(target.*)) continue;
        placeTreeState(region, position, data.oak_leaf_litter_trees.spruce_log_state);
        logs[count] = position;
        count += 1;
    }
    return count;
}

fn coniferSnowOrigin(region: *Region, initial: Position) ?Position {
    var origin = initial;
    var steps: u8 = 0;
    while (steps < 8) : (steps += 1) {
        const state = region.state(origin.x, origin.y, origin.z) orelse return null;
        if (!state.nameEquals("minecraft:powder_snow")) break;
        origin.y += 1;
    }
    const below = region.state(origin.x, origin.y - 1, origin.z) orelse return null;
    if (!below.nameEquals("minecraft:snow_block") and
        !below.nameEquals("minecraft:powder_snow")) return null;
    return origin;
}

fn isPlainTreeSoil(state: GeneratedState) bool {
    return isDirtTag(state) and !isGrassBlock(state) and
        !state.nameEquals("minecraft:mycelium[snowy=false]") and
        !state.nameEquals("minecraft:mycelium[snowy=true]");
}

fn generateSpruceFoliage(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    foliage_height: i32,
    maximum_radius: i32,
    leaves: *[512]Position,
    leaf_count: *usize,
) void {
    var radius = source.nextBoundedI32(2);
    var radius_limit: i32 = 1;
    var previous_radius: i32 = 0;
    var offset = source.nextBoundedI32(3);
    while (offset >= -foliage_height) : (offset -= 1) {
        placeConiferLeafSquare(region, center, offset, radius, leaves, leaf_count);
        if (radius >= radius_limit) {
            radius = previous_radius;
            previous_radius = 1;
            radius_limit = @min(radius_limit + 1, maximum_radius);
        } else radius += 1;
    }
}

fn generatePineFoliage(
    source: *ChunkRandom,
    region: *Region,
    center: Position,
    foliage_height: i32,
    base_radius: i32,
    leaves: *[512]Position,
    leaf_count: *usize,
) void {
    _ = source;
    var radius: i32 = 0;
    var offset: i32 = 1;
    while (offset >= 1 - foliage_height) : (offset -= 1) {
        placeConiferLeafSquare(region, center, offset, radius, leaves, leaf_count);
        if (radius >= 1 and offset == 2 - foliage_height)
            radius -= 1
        else if (radius < base_radius)
            radius += 1;
    }
}

fn placeConiferLeafSquare(
    region: *Region,
    center: Position,
    offset: i32,
    radius: i32,
    leaves: *[512]Position,
    leaf_count: *usize,
) void {
    var dx = -radius;
    while (dx <= radius) : (dx += 1) {
        var dz = -radius;
        while (dz <= radius) : (dz += 1) {
            if (@abs(dx) == radius and @abs(dz) == radius and radius > 0) continue;
            const position = Position{
                .x = center.x + dx,
                .y = center.y + offset,
                .z = center.z + dz,
            };
            const target = region.state(position.x, position.y, position.z) orelse continue;
            if (!canTreeReplace(target.*)) continue;
            placeTreeState(
                region,
                position,
                data.oak_leaf_litter_trees.spruce_leaf_state_base + 6,
            );
            appendUniquePosition(leaves, leaf_count, position);
        }
    }
}

fn treeUsableHeightLayers(
    region: *Region,
    origin: Position,
    requested: i32,
    limit: i32,
    lower_radius: i32,
    upper_radius: i32,
) i32 {
    var dy: i32 = 0;
    while (dy <= requested + 1) : (dy += 1) {
        const radius = if (dy < limit) lower_radius else upper_radius;
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                const state = region.state(
                    origin.x + dx,
                    origin.y + dy,
                    origin.z + dz,
                ) orelse return dy - 2;
                if (!canTreeReplace(state.*) and !isLog(state.*)) return dy - 2;
            }
        }
    }
    return requested;
}

fn placeTreeBeehive(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    leaves: []const Position,
    probability: f32,
) void {
    if (probability <= 0 or logs.len == 0 or source.nextF32() >= probability) return;
    var minimum_log_y = logs[0].y;
    var maximum_log_y = logs[0].y;
    for (logs[1..]) |log| {
        minimum_log_y = @min(minimum_log_y, log.y);
        maximum_log_y = @max(maximum_log_y, log.y);
    }
    const target_y = if (leaves.len != 0) target: {
        var minimum_leaf_y = leaves[0].y;
        for (leaves[1..]) |leaf| minimum_leaf_y = @min(minimum_leaf_y, leaf.y);
        break :target @max(minimum_leaf_y - 1, minimum_log_y + 1);
    } else @min(minimum_log_y + 1 + source.nextBoundedI32(3), maximum_log_y);
    var candidates: [768]Position = undefined;
    var candidate_count: usize = 0;
    const directions = [_]Direction{ .east, .south, .west };
    for (logs) |log| {
        if (log.y != target_y) continue;
        for (directions) |direction| {
            candidates[candidate_count] = offsetPosition(log, direction, 1);
            candidate_count += 1;
        }
    }
    shufflePositions(source, candidates[0..candidate_count]);
    for (candidates[0..candidate_count]) |candidate| {
        const target = region.state(candidate.x, candidate.y, candidate.z) orelse continue;
        const entrance_position = offsetPosition(candidate, .south, 1);
        const entrance = region.state(
            entrance_position.x,
            entrance_position.y,
            entrance_position.z,
        ) orelse continue;
        if (!isAir(target.*) or !isAir(entrance.*)) continue;
        target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.bee_nest_state);
        const bee_count = 2 + source.nextBoundedI32(2);
        for (0..@intCast(bee_count)) |_| _ = source.nextBoundedI32(599);
        break;
    }
}

const FancyNode = struct {
    center: Position,
    end_y: i32,
};

fn generateFancyLeafLitterTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    decoration: TreeDecoration,
) bool {
    const config = data.oak_leaf_litter_trees;
    const requested_height = 3 + source.nextBoundedI32(12) + source.nextBoundedI32(1);
    if (origin.y < minimum_y + 1 or origin.y + requested_height + 1 > minimum_y + height)
        return false;
    const usable_height = treeUsableHeightFancy(region, origin, requested_height);
    if (usable_height < requested_height and usable_height < 4) return false;

    var logs: [256]Position = undefined;
    var log_count: usize = 0;
    const below_position: Position = .{
        .x = origin.x,
        .y = origin.y - 1,
        .z = origin.z,
    };
    const below =
        region.state(below_position.x, below_position.y, below_position.z) orelse return false;
    if (isGrassBlock(below.*)) {
        below.* = GeneratedState.fromFeature(config.dirt_state);
        appendUniquePosition(&logs, &log_count, below_position);
    }

    const tree_height = usable_height + 2;
    const trunk_height: i32 = @intFromFloat(@floor(
        @as(f64, @floatFromInt(tree_height)) * 0.618,
    ));
    const branch_top_y = origin.y + trunk_height;
    var relative_y = tree_height - 5;
    var nodes: [64]FancyNode = undefined;
    var node_count: usize = 1;
    nodes[0] = .{
        .center = .{ .x = origin.x, .y = origin.y + relative_y, .z = origin.z },
        .end_y = branch_top_y,
    };

    while (relative_y >= 0) : (relative_y -= 1) {
        const radius = fancyBranchRadius(tree_height, relative_y);
        if (radius < 0) continue;
        const radial_distance =
            @as(f64, radius) * (@as(f64, source.nextF32()) + 0.328);
        const angle =
            @as(f64, source.nextF32() * @as(f32, 2.0)) * std.math.pi;
        const candidate: Position = .{
            .x = origin.x + @as(i32, @intFromFloat(@floor(
                radial_distance * @sin(angle) + 0.5,
            ))),
            .y = origin.y + relative_y - 1,
            .z = origin.z + @as(i32, @intFromFloat(@floor(
                radial_distance * @cos(angle) + 0.5,
            ))),
        };
        const candidate_top: Position = .{
            .x = candidate.x,
            .y = candidate.y + 5,
            .z = candidate.z,
        };
        if (!fancyBranch(region, &logs, &log_count, candidate, candidate_top, false))
            continue;
        const dx = origin.x - candidate.x;
        const dz = origin.z - candidate.z;
        const projected = @as(f64, @floatFromInt(candidate.y)) -
            @sqrt(@as(f64, @floatFromInt(dx * dx + dz * dz))) * 0.381;
        const branch_y = if (projected > @as(f64, @floatFromInt(branch_top_y)))
            branch_top_y
        else
            @as(i32, @intFromFloat(projected));
        const branch_start: Position = .{
            .x = origin.x,
            .y = branch_y,
            .z = origin.z,
        };
        if (!fancyBranch(region, &logs, &log_count, branch_start, candidate, false))
            continue;
        if (node_count < nodes.len) {
            nodes[node_count] = .{ .center = candidate, .end_y = branch_y };
            node_count += 1;
        }
    }

    _ = fancyBranch(
        region,
        &logs,
        &log_count,
        origin,
        .{ .x = origin.x, .y = origin.y + trunk_height, .z = origin.z },
        true,
    );
    for (nodes[0..node_count]) |node| {
        const branch_start: Position = .{
            .x = origin.x,
            .y = node.end_y,
            .z = origin.z,
        };
        if (samePosition(branch_start, node.center) or
            !fancyHighEnough(tree_height, node.end_y - origin.y)) continue;
        _ = fancyBranch(
            region,
            &logs,
            &log_count,
            branch_start,
            node.center,
            true,
        );
    }

    var leaves: [1024]Position = undefined;
    var leaf_count: usize = 0;
    for (nodes[0..node_count]) |node| {
        if (!fancyHighEnough(tree_height, node.end_y - origin.y)) continue;
        var offset: i32 = 4;
        while (offset >= 0) : (offset -= 1) {
            const radius: i32 = if (offset == 4 or offset == 0) 2 else 3;
            var dx = -radius;
            while (dx <= radius) : (dx += 1) {
                var dz = -radius;
                while (dz <= radius) : (dz += 1) {
                    const normalized_x = @as(f32, @floatFromInt(@abs(dx))) + 0.5;
                    const normalized_z = @as(f32, @floatFromInt(@abs(dz))) + 0.5;
                    if (normalized_x * normalized_x + normalized_z * normalized_z >
                        @as(f32, @floatFromInt(radius * radius))) continue;
                    const position: Position = .{
                        .x = node.center.x + dx,
                        .y = node.center.y + offset,
                        .z = node.center.z + dz,
                    };
                    const state =
                        region.state(position.x, position.y, position.z) orelse continue;
                    if (!canTreeReplace(state.*)) continue;
                    placeTreeState(region, position, config.leaf_state_base + 6);
                    appendUniquePosition(&leaves, &leaf_count, position);
                }
            }
        }
    }
    if (log_count == 0 or leaf_count == 0) return false;
    finishStraightTree(
        source,
        region,
        logs[0..log_count],
        leaves[0..leaf_count],
        decoration,
    );
    return true;
}

fn treeUsableHeightFancy(region: *Region, origin: Position, requested: i32) i32 {
    var dy: i32 = 0;
    while (dy <= requested + 1) : (dy += 1) {
        const state =
            region.state(origin.x, origin.y + dy, origin.z) orelse return dy - 2;
        if (!canTreeReplace(state.*) and !isLog(state.*)) return dy - 2;
    }
    return requested;
}

fn fancyBranchRadius(tree_height: i32, relative_y: i32) f32 {
    if (@as(f32, @floatFromInt(relative_y)) <
        @as(f32, @floatFromInt(tree_height)) * 0.3) return -1;
    const half = @as(f32, @floatFromInt(tree_height)) / 2.0;
    const delta = half - @as(f32, @floatFromInt(relative_y));
    var radius = @sqrt(half * half - delta * delta);
    if (delta == 0)
        radius = half
    else if (@abs(delta) >= half)
        return 0;
    return radius * 0.5;
}

fn fancyHighEnough(tree_height: i32, relative_y: i32) bool {
    return @as(f32, @floatFromInt(relative_y)) >=
        @as(f32, @floatFromInt(tree_height)) * 0.2;
}

fn fancyBranch(
    region: *Region,
    logs: *[256]Position,
    log_count: *usize,
    start: Position,
    end: Position,
    place: bool,
) bool {
    if (!place and samePosition(start, end)) return true;
    const offset: Position = .{
        .x = end.x - start.x,
        .y = end.y - start.y,
        .z = end.z - start.z,
    };
    const longest = @max(@abs(offset.x), @max(@abs(offset.y), @abs(offset.z)));
    const step_x = @as(f32, @floatFromInt(offset.x)) /
        @as(f32, @floatFromInt(longest));
    const step_y = @as(f32, @floatFromInt(offset.y)) /
        @as(f32, @floatFromInt(longest));
    const step_z = @as(f32, @floatFromInt(offset.z)) /
        @as(f32, @floatFromInt(longest));
    var step: i32 = 0;
    while (step <= longest) : (step += 1) {
        const position: Position = .{
            .x = start.x + @as(i32, @intFromFloat(@floor(
                @as(f32, 0.5) + @as(f32, @floatFromInt(step)) * step_x,
            ))),
            .y = start.y + @as(i32, @intFromFloat(@floor(
                @as(f32, 0.5) + @as(f32, @floatFromInt(step)) * step_y,
            ))),
            .z = start.z + @as(i32, @intFromFloat(@floor(
                @as(f32, 0.5) + @as(f32, @floatFromInt(step)) * step_z,
            ))),
        };
        const state = region.state(position.x, position.y, position.z) orelse return false;
        if (!place) {
            if (!canTreeReplace(state.*) and !isLog(state.*)) return false;
            continue;
        }
        if (!canTreeReplace(state.*)) continue;
        const dx = @abs(position.x - start.x);
        const dz = @abs(position.z - start.z);
        const axis_state = if (@max(dx, dz) == 0)
            data.oak_leaf_litter_trees.log_state
        else if (dx == @max(dx, dz))
            data.oak_leaf_litter_trees.log_x_state
        else
            data.oak_leaf_litter_trees.log_z_state;
        placeTreeState(region, position, axis_state);
        appendUniquePosition(logs, log_count, position);
    }
    return true;
}

fn appendUniquePosition(
    positions: anytype,
    count: *usize,
    position: Position,
) void {
    for (positions[0..count.*]) |existing|
        if (samePosition(existing, position)) return;
    std.debug.assert(count.* < positions.len);
    positions[count.*] = position;
    count.* += 1;
}

fn samePosition(left: Position, right: Position) bool {
    return left.x == right.x and left.y == right.y and left.z == right.z;
}

fn treeUsableHeight(region: *Region, origin: Position, requested: i32) i32 {
    var dy: i32 = 0;
    while (dy <= requested + 1) : (dy += 1) {
        const radius: i32 = if (dy < 1) 0 else 1;
        var dx = -radius;
        while (dx <= radius) : (dx += 1) {
            var dz = -radius;
            while (dz <= radius) : (dz += 1) {
                const state = region.state(
                    origin.x + dx,
                    origin.y + dy,
                    origin.z + dz,
                ) orelse return dy - 2;
                if (!canTreeReplace(state.*) and !isLog(state.*)) return dy - 2;
            }
        }
    }
    return requested;
}

fn placeLeafLitter(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    attempts: usize,
    radius: i32,
    height_radius: i32,
    state_count: i32,
    decorations: anytype,
    decoration_count: *usize,
) void {
    if (logs.len == 0) return;
    const y = logs[0].y;
    var minimum_x = logs[0].x;
    var maximum_x = logs[0].x;
    var minimum_z = logs[0].z;
    var maximum_z = logs[0].z;
    for (logs) |position| {
        if (position.y != y) continue;
        minimum_x = @min(minimum_x, position.x);
        maximum_x = @max(maximum_x, position.x);
        minimum_z = @min(minimum_z, position.z);
        maximum_z = @max(maximum_z, position.z);
    }
    minimum_x -= radius;
    maximum_x += radius;
    minimum_z -= radius;
    maximum_z += radius;
    const box_minimum_y = y - height_radius;
    const box_maximum_y = y + height_radius;
    for (0..attempts) |_| {
        const x = minimum_x + source.nextBoundedI32(maximum_x - minimum_x + 1);
        const candidate_y =
            box_minimum_y + source.nextBoundedI32(box_maximum_y - box_minimum_y + 1);
        const z = minimum_z + source.nextBoundedI32(maximum_z - minimum_z + 1);
        const ground = region.state(x, candidate_y, z) orelse continue;
        const target = region.state(x, candidate_y + 1, z) orelse continue;
        if (!isAir(target.*) or !isOpaqueFullCube(ground.*)) continue;
        if (motionBlockingNoLeavesHeight(region, x, z) > candidate_y + 1) continue;
        const selected: u8 = @intCast(source.nextBoundedI32(state_count));
        target.* = GeneratedState.fromFeature(data.oak_leaf_litter_trees.litter_state_base + selected);
        std.debug.assert(decoration_count.* < decorations.len);
        decorations[decoration_count.*] = .{ .x = x, .y = candidate_y + 1, .z = z };
        decoration_count.* += 1;
    }
}

fn resolveLeafDistance(
    region: *Region,
    logs: []const Position,
    leaves: []const Position,
    decorations: []const Position,
) void {
    if (logs.len == 0 or leaves.len == 0) return;
    var minimum = logs[0];
    var maximum = logs[0];
    for (logs) |position| expandBox(&minimum, &maximum, position);
    for (leaves) |position| expandBox(&minimum, &maximum, position);
    for (decorations) |position| expandBox(&minimum, &maximum, position);
    const size_x: usize = @intCast(maximum.x - minimum.x + 1);
    const size_y: usize = @intCast(maximum.y - minimum.y + 1);
    const size_z: usize = @intCast(maximum.z - minimum.z + 1);
    var occupied_storage: [8192]bool = undefined;
    const occupied = occupied_storage[0 .. size_x * size_y * size_z];
    @memset(occupied, false);
    for (decorations) |position|
        occupied[boxIndex(minimum, size_x, size_z, position)] = true;

    var queues: [7][1024]Position = undefined;
    var queue_counts = [_]usize{0} ** 7;
    var queue_capacities = [_]usize{0} ** 7;
    insertHashSetIterationOrder(
        &queues[0],
        &queue_counts[0],
        &queue_capacities[0],
        logs,
    );
    var distance: usize = 0;
    for (0..7 * queues[0].len) |_| {
        while (distance < 7 and queue_counts[distance] == 0)
            distance += 1;
        if (distance == 7) return;
        const position = queuePop(
            &queues[distance],
            &queue_counts[distance],
            queue_capacities[distance],
        );
        const index = boxIndex(minimum, size_x, size_z, position);
        if (distance != 0) {
            const state = region.state(position.x, position.y, position.z) orelse continue;
            const leaf_state_base = treeLeafStateBase(state.*) orelse continue;
            state.* = GeneratedState.fromFeature(
                leaf_state_base + @as(u8, @intCast(distance - 1)),
            );
        }
        occupied[index] = true;

        for (all_directions) |direction| {
            const offset = direction.offset();
            const neighbor_position: Position = .{
                .x = position.x + offset.x,
                .y = position.y + offset.y,
                .z = position.z + offset.z,
            };
            if (!boxContains(minimum, maximum, neighbor_position)) continue;
            const neighbor_index =
                boxIndex(minimum, size_x, size_z, neighbor_position);
            if (occupied[neighbor_index]) continue;
            const neighbor =
                region.state(neighbor_position.x, neighbor_position.y, neighbor_position.z) orelse
                continue;
            const optional_distance: ?usize = if (isLog(neighbor.*))
                0
            else blk: {
                const leaf_distance = treeLeafDistance(neighbor.*);
                break :blk if (leaf_distance == 0) null else leaf_distance;
            };
            const next_distance = @min(optional_distance orelse continue, distance + 1);
            if (next_distance >= 7) continue;
            queueInsert(
                &queues[next_distance],
                &queue_counts[next_distance],
                &queue_capacities[next_distance],
                neighbor_position,
            );
            distance = @min(distance, next_distance);
        }
    }
    unreachable;
}

fn expandBox(minimum: *Position, maximum: *Position, position: Position) void {
    minimum.x = @min(minimum.x, position.x);
    minimum.y = @min(minimum.y, position.y);
    minimum.z = @min(minimum.z, position.z);
    maximum.x = @max(maximum.x, position.x);
    maximum.y = @max(maximum.y, position.y);
    maximum.z = @max(maximum.z, position.z);
}

fn boxContains(minimum: Position, maximum: Position, position: Position) bool {
    return position.x >= minimum.x and position.x <= maximum.x and
        position.y >= minimum.y and position.y <= maximum.y and
        position.z >= minimum.z and position.z <= maximum.z;
}

fn boxIndex(
    minimum: Position,
    size_x: usize,
    size_z: usize,
    position: Position,
) usize {
    return @as(usize, @intCast(position.x - minimum.x)) +
        @as(usize, @intCast(position.z - minimum.z)) * size_x +
        @as(usize, @intCast(position.y - minimum.y)) * size_x * size_z;
}

fn queueInsert(
    queue: anytype,
    count: *usize,
    capacity: *usize,
    position: Position,
) void {
    for (queue[0..count.*]) |existing| {
        if (existing.x == position.x and existing.y == position.y and
            existing.z == position.z) return;
    }
    std.debug.assert(count.* < queue.len);
    queue[count.*] = position;
    count.* += 1;
    if (capacity.* == 0) capacity.* = 16;
    if (count.* > capacity.* * 3 / 4) capacity.* *= 2;
}

fn insertHashSetIterationOrder(
    queue: anytype,
    count: *usize,
    capacity: *usize,
    positions: []const Position,
) void {
    var source_capacity: usize = 16;
    while (positions.len > source_capacity * 3 / 4) source_capacity *= 2;
    for (0..source_capacity) |bucket| {
        for (positions) |position| {
            if (hashSetBucket(position, source_capacity) != bucket) continue;
            queueInsert(queue, count, capacity, position);
        }
    }
}

fn queuePop(queue: anytype, count: *usize, capacity: usize) Position {
    std.debug.assert(count.* != 0 and capacity != 0);
    var selected: usize = 0;
    var selected_bucket = hashSetBucket(queue[0], capacity);
    for (queue[1..count.*], 1..) |position, index| {
        const bucket = hashSetBucket(position, capacity);
        if (bucket >= selected_bucket) continue;
        selected = index;
        selected_bucket = bucket;
    }
    const position = queue[selected];
    var index = selected;
    while (index + 1 < count.*) : (index += 1)
        queue[index] = queue[index + 1];
    count.* -= 1;
    return position;
}

fn hashSetBucket(position: Position, capacity: usize) usize {
    const hash: u32 = @bitCast(
        (position.y +% position.z *% 31) *% 31 +% position.x,
    );
    const spread = hash ^ (hash >> 16);
    return @as(usize, spread) & (capacity - 1);
}

const Direction = enum(u3) {
    down,
    up,
    north,
    south,
    west,
    east,

    fn offset(self: Direction) Position {
        return switch (self) {
            .down => .{ .x = 0, .y = -1, .z = 0 },
            .up => .{ .x = 0, .y = 1, .z = 0 },
            .north => .{ .x = 0, .y = 0, .z = -1 },
            .south => .{ .x = 0, .y = 0, .z = 1 },
            .west => .{ .x = -1, .y = 0, .z = 0 },
            .east => .{ .x = 1, .y = 0, .z = 0 },
        };
    }

    fn opposite(self: Direction) Direction {
        return switch (self) {
            .down => .up,
            .up => .down,
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }

    fn faceBit(self: Direction) u7 {
        const bit: u3 = switch (self) {
            .down => 0,
            .up => 1,
            .north => 2,
            .east => 3,
            .south => 4,
            .west => 5,
        };
        return @as(u7, 1) << bit;
    }

    fn axis(self: Direction) enum { x, y, z } {
        return switch (self) {
            .down, .up => .y,
            .north, .south => .z,
            .west, .east => .x,
        };
    }
};

const lichen_directions = [_]Direction{ .up, .north, .east, .south, .west };
const all_directions = [_]Direction{ .down, .up, .north, .south, .west, .east };

fn generateGlowLichen(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
) bool {
    const origin_state = region.state(origin.x, origin.y, origin.z) orelse return false;
    if (!isAirOrWaterOrLichen(origin_state.*)) return false;
    var directions = lichen_directions;
    shuffleDirections(source, directions[0..]);
    if (placeGlowLichen(source, region, origin, origin_state, directions[0..]))
        return true;

    for (directions) |search_direction| {
        var search_directions: [5]Direction = undefined;
        var count: usize = 0;
        for (lichen_directions) |direction| {
            if (search_direction != .up and direction == search_direction.opposite()) continue;
            search_directions[count] = direction;
            count += 1;
        }
        shuffleDirections(source, search_directions[0..count]);
        const offset = search_direction.offset();
        const position: Position = .{
            .x = origin.x + offset.x,
            .y = origin.y + offset.y,
            .z = origin.z + offset.z,
        };
        const state = region.state(position.x, position.y, position.z) orelse continue;
        if (!isAirOrWaterOrLichen(state.*)) continue;
        if (placeGlowLichen(
            source,
            region,
            position,
            state,
            search_directions[0..count],
        )) return true;
    }
    return false;
}

fn placeGlowLichen(
    source: *ChunkRandom,
    region: *Region,
    position: Position,
    state: *GeneratedState,
    directions: []const Direction,
) bool {
    for (directions) |direction| {
        const offset = direction.offset();
        const support = region.state(
            position.x + offset.x,
            position.y + offset.y,
            position.z + offset.z,
        ) orelse continue;
        if (!lichenCanPlaceOn(support.*)) continue;
        const existing = lichenStateBits(state.*);
        if (existing) |bits| {
            if (bits & direction.faceBit() != 0) return false;
            state.* = GeneratedState.fromFeature(
                data.glow_lichen.state_base +
                    @as(u8, bits | direction.faceBit()),
            );
        } else {
            var bits: u7 = direction.faceBit();
            if (isWater(state.*)) bits |= 1 << 6;
            state.* = GeneratedState.fromFeature(data.glow_lichen.state_base + @as(u8, bits));
        }
        if (source.nextF32() < data.glow_lichen.spread_chance)
            spreadGlowLichen(source, region, position, direction);
        return true;
    }
    return false;
}

fn spreadGlowLichen(
    source: *ChunkRandom,
    region: *Region,
    position: Position,
    original_face: Direction,
) void {
    var directions = all_directions;
    shuffleDirections(source, directions[0..]);
    for (directions) |growth_direction| {
        if (growth_direction.axis() == original_face.axis()) continue;
        const origin_state = region.state(position.x, position.y, position.z) orelse return;
        const origin_bits = lichenStateBits(origin_state.*) orelse return;
        if (origin_bits & original_face.faceBit() == 0 or
            origin_bits & growth_direction.faceBit() != 0) continue;

        if (tryGrowLichen(region, position, growth_direction, .same_position, original_face)) return;
        if (tryGrowLichen(region, position, growth_direction, .same_plane, original_face)) return;
        if (tryGrowLichen(region, position, growth_direction, .wrap_around, original_face)) return;
    }
}

const GrowType = enum { same_position, same_plane, wrap_around };

fn tryGrowLichen(
    region: *Region,
    origin: Position,
    growth_direction: Direction,
    grow_type: GrowType,
    original_face: Direction,
) bool {
    const growth_offset = growth_direction.offset();
    const face: Direction = switch (grow_type) {
        .same_position => growth_direction,
        .same_plane => original_face,
        .wrap_around => growth_direction.opposite(),
    };
    const position: Position = switch (grow_type) {
        .same_position => origin,
        .same_plane => .{
            .x = origin.x + growth_offset.x,
            .y = origin.y + growth_offset.y,
            .z = origin.z + growth_offset.z,
        },
        .wrap_around => blk: {
            const face_offset = original_face.offset();
            break :blk .{
                .x = origin.x + growth_offset.x + face_offset.x,
                .y = origin.y + growth_offset.y + face_offset.y,
                .z = origin.z + growth_offset.z + face_offset.z,
            };
        },
    };
    const state = region.state(position.x, position.y, position.z) orelse return false;
    if (!isAirOrWaterOrLichen(state.*)) return false;
    if (lichenStateBits(state.*)) |bits|
        if (bits & face.faceBit() != 0) return false;
    const support_offset = face.offset();
    const support = region.state(
        position.x + support_offset.x,
        position.y + support_offset.y,
        position.z + support_offset.z,
    ) orelse return false;
    if (!lichenCanGrowOn(support.*)) return false;

    if (lichenStateBits(state.*)) |bits| {
        state.* = GeneratedState.fromFeature(
            data.glow_lichen.state_base + @as(u8, bits | face.faceBit()),
        );
    } else {
        var bits: u7 = face.faceBit();
        if (isWater(state.*)) bits |= 1 << 6;
        state.* = GeneratedState.fromFeature(data.glow_lichen.state_base + @as(u8, bits));
    }
    return true;
}

fn shuffleDirections(source: *ChunkRandom, directions: []Direction) void {
    var remaining = directions.len;
    while (remaining > 1) : (remaining -= 1) {
        const other: usize = @intCast(source.nextBoundedI32(@intCast(remaining)));
        std.mem.swap(Direction, &directions[remaining - 1], &directions[other]);
    }
}

fn sampleHeight(source: *ChunkRandom, provider: data.Height) i32 {
    const minimum = resolveOffset(provider.minimum_kind, provider.minimum);
    const maximum = resolveOffset(provider.maximum_kind, provider.maximum);
    if (minimum >= maximum) return minimum;
    const span = maximum - minimum;
    return switch (provider.kind) {
        .uniform => minimum + source.nextBoundedI32(span + 1),
        .trapezoid => blk: {
            const lower_half = @divTrunc(span, 2);
            const upper_half = span - lower_half;
            break :blk minimum +
                source.nextBoundedI32(upper_half + 1) +
                source.nextBoundedI32(lower_half + 1);
        },
        .very_biased_to_bottom => blk: {
            const inner: i32 = @intCast(provider.inner);
            if (maximum - minimum - inner + 1 <= 0) break :blk minimum;
            const upper = nextInclusive(source, minimum + inner, maximum);
            const middle = nextInclusive(source, minimum, upper - 1);
            break :blk nextInclusive(source, minimum, middle - 1 + inner);
        },
    };
}

fn nextInclusive(source: *ChunkRandom, minimum: i32, maximum: i32) i32 {
    if (minimum >= maximum) return minimum;
    return minimum + source.nextBoundedI32(maximum - minimum + 1);
}

fn resolveOffset(kind: data.OffsetKind, value: i32) i32 {
    return switch (kind) {
        .absolute => value,
        .above_bottom => minimum_y + value,
        .below_top => minimum_y + height - 1 - value,
    };
}

fn generateOre(
    source: *ChunkRandom,
    ore: data.Ore,
    first_x: i32,
    first_z: i32,
    ocean_floor: *const HeightHalo,
    region: *Region,
    origin: Position,
) usize {
    const bounds = prepareOreBounds(source, ore, origin);
    if (!hasOceanFloorAtOrAbove(
        first_x,
        first_z,
        ocean_floor,
        bounds.box_x,
        bounds.box_z,
        bounds.horizontal_size,
        bounds.box_y,
    )) return 0;
    var spheres = prepareOreSpheres(source, ore, bounds);
    pruneOreSpheres(spheres[0..ore.size]);
    return placeOreSpheres(source, ore, region, bounds, spheres[0..ore.size]);
}

const OreBounds = struct {
    x0: f64,
    x1: f64,
    y0: f64,
    y1: f64,
    z0: f64,
    z1: f64,
    box_x: i32,
    box_y: i32,
    box_z: i32,
    horizontal_size: usize,
    vertical_size: usize,
};

fn prepareOreBounds(source: *ChunkRandom, ore: data.Ore, origin: Position) OreBounds {
    const angle = source.nextF32() * @as(f32, std.math.pi);
    const extent = @as(f32, @floatFromInt(ore.size)) / 8.0;
    const sin_angle = @sin(@as(f64, angle));
    const cos_angle = @cos(@as(f64, angle));
    const bound = @as(i32, @intFromFloat(@ceil(extent)));
    const adjustment = @as(i32, @intFromFloat(@ceil(
        (@as(f32, @floatFromInt(ore.size)) / 16.0 * 2.0 + 1.0) / 2.0,
    )));
    return .{
        .x0 = @as(f64, @floatFromInt(origin.x)) + sin_angle * @as(f64, extent),
        .x1 = @as(f64, @floatFromInt(origin.x)) - sin_angle * @as(f64, extent),
        .y0 = @floatFromInt(origin.y + source.nextBoundedI32(3) - 2),
        .y1 = @floatFromInt(origin.y + source.nextBoundedI32(3) - 2),
        .z0 = @as(f64, @floatFromInt(origin.z)) + cos_angle * @as(f64, extent),
        .z1 = @as(f64, @floatFromInt(origin.z)) - cos_angle * @as(f64, extent),
        .box_x = origin.x - bound - adjustment,
        .box_y = origin.y - 2 - adjustment,
        .box_z = origin.z - bound - adjustment,
        .horizontal_size = @intCast(2 * (bound + adjustment)),
        .vertical_size = @intCast(2 * (2 + adjustment)),
    };
}

fn prepareOreSpheres(source: *ChunkRandom, ore: data.Ore, bounds: OreBounds) [64][4]f64 {
    var spheres: [64][4]f64 = undefined;
    std.debug.assert(ore.size <= spheres.len);
    for (0..ore.size) |index| {
        const progress = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(ore.size));
        const random_radius = source.nextF64() * @as(f64, @floatFromInt(ore.size)) / 16.0;
        const radius = (@as(f64, minecraftSin(progress * @as(f32, std.math.pi)) + 1.0) *
            random_radius + 1.0) / 2.0;
        spheres[index] = .{
            lerp(@floatCast(progress), bounds.x0, bounds.x1),
            lerp(@floatCast(progress), bounds.y0, bounds.y1),
            lerp(@floatCast(progress), bounds.z0, bounds.z1),
            radius,
        };
    }
    return spheres;
}

fn pruneOreSpheres(spheres: [][4]f64) void {
    for (0..spheres.len - 1) |left| {
        if (spheres[left][3] <= 0) continue;
        for (left + 1..spheres.len) |right| {
            if (spheres[right][3] <= 0) continue;
            const dx = spheres[left][0] - spheres[right][0];
            const dy = spheres[left][1] - spheres[right][1];
            const dz = spheres[left][2] - spheres[right][2];
            const dr = spheres[left][3] - spheres[right][3];
            if (dr * dr <= dx * dx + dy * dy + dz * dz) continue;
            if (dr > 0)
                spheres[right][3] = -1
            else
                spheres[left][3] = -1;
        }
    }
}

fn placeOreSpheres(source: *ChunkRandom, ore: data.Ore, region: *Region, bounds: OreBounds, spheres: []const [4]f64) usize {
    var visited_storage: [26 * 14 * 26]bool = undefined;
    const visited_length = bounds.horizontal_size * bounds.vertical_size * bounds.horizontal_size;
    std.debug.assert(visited_length <= visited_storage.len);
    const visited = visited_storage[0..visited_length];
    @memset(visited, false);
    var placed: usize = 0;
    for (spheres) |sphere|
        placed += placeOreSphere(source, ore, region, bounds, sphere, visited);
    return placed;
}

fn placeOreSphere(source: *ChunkRandom, ore: data.Ore, region: *Region, bounds: OreBounds, sphere: [4]f64, visited: []bool) usize {
    const radius = sphere[3];
    if (radius < 0) return 0;
    const minimum_x = @max(@as(i32, @intFromFloat(@floor(sphere[0] - radius))), bounds.box_x);
    const sphere_minimum_y = @max(@as(i32, @intFromFloat(@floor(sphere[1] - radius))), bounds.box_y);
    const minimum_z = @max(@as(i32, @intFromFloat(@floor(sphere[2] - radius))), bounds.box_z);
    const maximum_x = @max(@as(i32, @intFromFloat(@floor(sphere[0] + radius))), minimum_x);
    const maximum_y = @max(@as(i32, @intFromFloat(@floor(sphere[1] + radius))), sphere_minimum_y);
    const maximum_z = @max(@as(i32, @intFromFloat(@floor(sphere[2] + radius))), minimum_z);
    var placed: usize = 0;
    var x = minimum_x;
    while (x <= maximum_x) : (x += 1) {
        const dx = (@as(f64, @floatFromInt(x)) + 0.5 - sphere[0]) / radius;
        if (dx * dx >= 1) continue;
        placed += placeOreSphereColumn(source, ore, region, bounds, sphere, visited, x, sphere_minimum_y, maximum_y, minimum_z, maximum_z, dx);
    }
    return placed;
}

fn placeOreSphereColumn(source: *ChunkRandom, ore: data.Ore, region: *Region, bounds: OreBounds, sphere: [4]f64, visited: []bool, x: i32, sphere_minimum_y: i32, maximum_y: i32, minimum_z: i32, maximum_z: i32, dx: f64) usize {
    var placed: usize = 0;
    var y = sphere_minimum_y;
    while (y <= maximum_y) : (y += 1) {
        const dy = (@as(f64, @floatFromInt(y)) + 0.5 - sphere[1]) / sphere[3];
        if (dx * dx + dy * dy >= 1) continue;
        var z = minimum_z;
        while (z <= maximum_z) : (z += 1) {
            const dz = (@as(f64, @floatFromInt(z)) + 0.5 - sphere[2]) / sphere[3];
            if (dx * dx + dy * dy + dz * dz >= 1 or y < minimum_y or y >= minimum_y + height) continue;
            const visited_index = @as(usize, @intCast(x - bounds.box_x)) +
                @as(usize, @intCast(y - bounds.box_y)) * bounds.horizontal_size +
                @as(usize, @intCast(z - bounds.box_z)) * bounds.horizontal_size * bounds.vertical_size;
            if (visited[visited_index]) continue;
            visited[visited_index] = true;
            const state = region.state(x, y, z) orelse continue;
            for (ore.targets) |target| {
                if (!targetMatches(state.*, target.tag)) continue;
                if (!shouldPlace(source, ore.discard, x, y, z, region)) break;
                state.* = GeneratedState.fromFeature(target.state);
                placed += 1;
                break;
            }
        }
    }
    return placed;
}

fn hasOceanFloorAtOrAbove(
    first_x: i32,
    first_z: i32,
    ocean_floor: *const HeightHalo,
    box_x: i32,
    box_z: i32,
    horizontal_size: usize,
    minimum: i32,
) bool {
    var x = box_x;
    while (x <= box_x + @as(i32, @intCast(horizontal_size))) : (x += 1) {
        const halo_x: usize = @intCast(x - first_x + width);
        var z = box_z;
        while (z <= box_z + @as(i32, @intCast(horizontal_size))) : (z += 1) {
            const halo_z: usize = @intCast(z - first_z + width);
            if (minimum <= ocean_floor[halo_z * height_halo_side + halo_x]) return true;
        }
    }
    return false;
}

fn shouldPlace(
    source: *ChunkRandom,
    discard: f32,
    x: i32,
    y: i32,
    z: i32,
    region: *Region,
) bool {
    if (discard <= 0) return true;
    if (discard < 1 and source.nextF32() >= discard) return true;
    const offsets = [_]Position{
        .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = -1, .z = 0 },
        .{ .x = 0, .y = 1, .z = 0 },
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 0, .y = 0, .z = 1 },
    };
    for (offsets) |offset| {
        const neighbor_x = x + offset.x;
        const neighbor_y = y + offset.y;
        const neighbor_z = z + offset.z;
        const neighbor = region.state(neighbor_x, neighbor_y, neighbor_z) orelse continue;
        if (isAir(neighbor.*)) return false;
    }
    return true;
}

fn targetMatches(state: GeneratedState, tag: data.TargetTag) bool {
    const granite = GeneratedState.featureNamed("minecraft:granite");
    const diorite = GeneratedState.featureNamed("minecraft:diorite");
    const andesite = GeneratedState.featureNamed("minecraft:andesite");
    const tuff = GeneratedState.featureNamed("minecraft:tuff");
    const feature_stone = GeneratedState.featureNamed("minecraft:stone");
    const surface_stone = GeneratedState.surfaceNamed("minecraft:stone");
    const deepslate = GeneratedState.surfaceNamed("minecraft:deepslate[axis=y]");
    const stone = state == .stone or state == surface_stone or state == feature_stone;
    const stone_replaceable = stone or state == granite or
        state == diorite or state == andesite;
    return switch (tag) {
        .base_stone_overworld => stone_replaceable or state == deepslate or state == tuff,
        .stone_ore_replaceables => stone_replaceable,
        .deepslate_ore_replaceables => state == deepslate or state == tuff,
    };
}

fn isAir(state: GeneratedState) bool {
    return state == .air;
}

fn isWater(state: GeneratedState) bool {
    return switch (state) {
        .water => true,
        .stone, .air, .lava => false,
        _ => state.block() == .water,
    };
}

fn springValidBlock(state: GeneratedState, valid_blocks: []const []const u8) bool {
    const name = state.canonicalName();
    for (valid_blocks) |valid_block| {
        if (!std.mem.startsWith(u8, name, valid_block)) continue;
        if (name.len == valid_block.len or name[valid_block.len] == '[') return true;
    }
    return false;
}

fn worldSurfaceHeight(region: *Region, x: i32, z: i32) i32 {
    var y = heightScanUpperBound(region, x, z);
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (!isAir(state.*)) return y + 1;
    }
    return minimum_y;
}

fn oceanFloorHeight(region: *Region, x: i32, z: i32) i32 {
    var y = heightScanUpperBound(region, x, z);
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (blocksMovement(state.*)) return y + 1;
    }
    return minimum_y;
}

fn motionBlockingNoLeavesHeight(region: *Region, x: i32, z: i32) i32 {
    var y = heightScanUpperBound(region, x, z);
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (isWater(state.*) or isOpaqueFullCube(state.*)) return y + 1;
    }
    return minimum_y;
}

fn motionBlockingHeight(region: *Region, x: i32, z: i32) i32 {
    var y = heightScanUpperBound(region, x, z);
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (isWater(state.*) or isOpaqueFullCube(state.*) or
            treeLeafDistance(state.*) != 0) return y + 1;
    }
    return minimum_y;
}

fn heightScanUpperBound(region: *const Region, x: i32, z: i32) i32 {
    const bounds = region.height_upper_bounds orelse return minimum_y + height;
    const first_x = region.center_chunk_x * width;
    const first_z = region.center_chunk_z * width;
    return @min(heightHaloAt(bounds, first_x, first_z, x, z) + 48, minimum_y + height);
}

fn saplingWouldSurvive(region: *Region, origin: Position) bool {
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    return ground.nameEquals("minecraft:grass_block[snowy=false]") or
        ground.nameEquals("minecraft:dirt") or
        ground.nameEquals("minecraft:coarse_dirt") or
        ground.nameEquals("minecraft:podzol[snowy=false]") or
        ground.nameEquals("minecraft:rooted_dirt") or
        ground.nameEquals("minecraft:moss_block");
}

fn isGrassBlock(state: GeneratedState) bool {
    return state.nameEquals("minecraft:grass_block[snowy=false]");
}

fn shortGrassCanPlantOn(state: GeneratedState) bool {
    return state.nameEquals("minecraft:dirt") or
        state.nameEquals("minecraft:grass_block[snowy=false]") or
        state.nameEquals("minecraft:grass_block[snowy=true]") or
        state.nameEquals("minecraft:podzol[snowy=false]") or
        state.nameEquals("minecraft:podzol[snowy=true]") or
        state.nameEquals("minecraft:coarse_dirt") or
        state.nameEquals("minecraft:mycelium[snowy=false]") or
        state.nameEquals("minecraft:mycelium[snowy=true]") or
        state.nameEquals("minecraft:rooted_dirt") or
        state.nameEquals("minecraft:moss_block") or
        state.nameEquals("minecraft:muddy_mangrove_roots") or
        state.block() == .farmland;
}

fn mushroomCanPlantOn(state: GeneratedState) bool {
    return state.nameEquals("minecraft:mycelium[snowy=false]") or
        state.nameEquals("minecraft:mycelium[snowy=true]") or
        state.nameEquals("minecraft:podzol[snowy=false]") or
        state.nameEquals("minecraft:podzol[snowy=true]") or
        state.nameEquals("minecraft:nylium") or
        isOpaqueFullCube(state);
}

fn canTreeReplace(state: GeneratedState) bool {
    return isAir(state) or isWater(state) or treeLeafDistance(state) != 0 or
        lichenStateBits(state) != null or isForestFlower(state) or
        isForestGrass(state) or isLeafLitter(state) or
        isTreeReplaceableSurfacePatch(state);
}

fn isTreeReplaceableSurfacePatch(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    for (data.surface_patches) |patch| {
        if (patch.placement != .dirt and patch.placement != .weighted_flower) continue;
        if (surfacePatchContains(patch, index)) return true;
    }
    return false;
}

fn placeTreeState(region: *Region, position: Position, feature_state: u16) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    target.* = GeneratedState.fromFeature(feature_state);
}

fn cleanupTallPlants(
    region: *Region,
    logs: []const Position,
    leaves: []const Position,
    decorations: []const Position,
) void {
    if (logs.len == 0) return;
    var minimum = logs[0];
    var maximum = logs[0];
    for (logs) |position| expandBox(&minimum, &maximum, position);
    for (leaves) |position| expandBox(&minimum, &maximum, position);
    for (decorations) |position| expandBox(&minimum, &maximum, position);
    var y = minimum.y;
    while (y <= maximum.y) : (y += 1) {
        var x = minimum.x;
        while (x <= maximum.x) : (x += 1) {
            var z = minimum.z;
            while (z <= maximum.z) : (z += 1) {
                const state = region.state(x, y, z) orelse continue;
                const index = state.featureIndex() orelse continue;
                for (data.forest_flowers.lower_states, data.forest_flowers.upper_states) |
                    lower,
                    upper,
                | {
                    const counterpart_y = if (index == lower)
                        y + 1
                    else if (index == upper)
                        y - 1
                    else
                        continue;
                    const expected = if (index == lower) upper else lower;
                    const counterpart = region.state(x, counterpart_y, z) orelse {
                        state.* = GeneratedState.fromBase(.air);
                        break;
                    };
                    const valid = counterpart.featureIndex() == expected;
                    if (!valid) state.* = GeneratedState.fromBase(.air);
                    break;
                }
            }
        }
    }
}

fn isForestGrass(state: GeneratedState) bool {
    return state.featureIndex() == data.patch_grass_forest.state;
}

fn isForestFlower(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index == data.forest_flowers.lily_state or
        std.mem.indexOfScalar(u16, &data.forest_flowers.lower_states, index) != null or
        std.mem.indexOfScalar(u16, &data.forest_flowers.upper_states, index) != null;
}

fn isLog(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index == data.oak_leaf_litter_trees.log_state or
        index == data.oak_leaf_litter_trees.log_x_state or
        index == data.oak_leaf_litter_trees.log_z_state or
        index == data.oak_leaf_litter_trees.birch_log_state or
        index == data.oak_leaf_litter_trees.birch_log_x_state or
        index == data.oak_leaf_litter_trees.birch_log_z_state;
}

fn treeLeafDistance(state: GeneratedState) u8 {
    const state_base = treeLeafStateBase(state) orelse return 0;
    return @intCast(state.featureIndex().? - state_base + 1);
}

fn treeLeafStateBase(state: GeneratedState) ?u16 {
    const index = state.featureIndex() orelse return null;
    if (index >= data.oak_leaf_litter_trees.leaf_state_base and
        index < data.oak_leaf_litter_trees.leaf_state_base + 7)
        return data.oak_leaf_litter_trees.leaf_state_base;
    if (index >= data.oak_leaf_litter_trees.birch_leaf_state_base and
        index < data.oak_leaf_litter_trees.birch_leaf_state_base + 7)
        return data.oak_leaf_litter_trees.birch_leaf_state_base;
    return null;
}

fn isOpaqueFullCube(state: GeneratedState) bool {
    switch (state) {
        .stone, .lava => return true,
        .air, .water => return false,
        _ => {},
    }
    if (isAir(state) or isWater(state) or treeLeafDistance(state) != 0 or
        lichenStateBits(state) != null or isForestFlower(state) or
        isForestGrass(state) or isNonSolidSurfacePatch(state) or
        isNearWaterPlant(state) or isAquaticPlant(state) or isSimpleNonSolid(state)) return false;
    return state.block() != .leaf_litter;
}

fn blocksMovement(state: GeneratedState) bool {
    switch (state) {
        .stone => return true,
        .air, .water, .lava => return false,
        _ => {},
    }
    if (isAir(state) or isWater(state) or lichenStateBits(state) != null or
        isForestFlower(state) or isForestGrass(state) or isNonSolidSurfacePatch(state) or
        isLeafLitter(state) or isNearWaterPlant(state) or isAquaticPlant(state) or
        isSimpleNonSolid(state)) return false;
    return state.block() != .lava;
}

fn isSimpleNonSolid(state: GeneratedState) bool {
    return state.block() == .bamboo or state.block() == .bamboo_sapling or
        state.block() == .vine or state.block() == .sea_pickle;
}

fn isNonSolidSurfacePatch(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    for (data.surface_patches) |patch| {
        if (patch.placement == .grass_block) continue;
        if (surfacePatchContains(patch, index)) return true;
    }
    return false;
}

fn surfacePatchContains(patch: data.SurfacePatch, state: u16) bool {
    for (patch.states[0..patch.state_count]) |candidate|
        if (candidate == state) return true;
    return false;
}

fn isLeafLitter(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index >= data.oak_leaf_litter_trees.litter_state_base and
        index < data.oak_leaf_litter_trees.litter_state_base + 16;
}

fn isAquaticPlant(state: GeneratedState) bool {
    const index = state.featureIndex() orelse return false;
    return index == data.seagrass_state or
        index == data.tall_seagrass_lower_state or
        index == data.tall_seagrass_upper_state or
        index == data.kelp_plant_state or
        (index >= data.kelp_states[0] and index <= data.kelp_states[3]);
}

fn heightHaloAt(
    halo: *const HeightHalo,
    first_x: i32,
    first_z: i32,
    x: i32,
    z: i32,
) i32 {
    const halo_x: usize = @intCast(x - first_x + width);
    const halo_z: usize = @intCast(z - first_z + width);
    return halo[halo_z * height_halo_side + halo_x];
}

fn jitteredBiomeIndex(
    mixer_seed: i64,
    climate_sampler: *const climate.Sampler,
    region: *Region,
    position: Position,
) u8 {
    const quart = biome_access.quartPosition(
        mixer_seed,
        .{ .x = position.x, .y = position.y, .z = position.z },
    );
    return region.biome_cache.atQuart(
        climate_sampler,
        quart.x,
        quart.y,
        quart.z,
    );
}

fn isAirOrWaterOrLichen(state: GeneratedState) bool {
    return isAir(state) or isWater(state) or lichenStateBits(state) != null;
}

fn lichenStateBits(state: GeneratedState) ?u7 {
    const index = state.featureIndex() orelse return null;
    if (index < data.glow_lichen.state_base or
        index >= data.glow_lichen.state_base + 128)
        return null;
    return @intCast(index - data.glow_lichen.state_base);
}

fn lichenCanPlaceOn(state: GeneratedState) bool {
    inline for (data.glow_lichen.can_place_on) |allowed|
        if (state.nameEquals(allowed)) return true;
    return false;
}

fn lichenCanGrowOn(state: GeneratedState) bool {
    return !isAir(state) and !isWater(state) and lichenStateBits(state) == null;
}

fn diskTargetMatches(state: GeneratedState, targets: []const u8) bool {
    for (targets) |target|
        if (state.sameCanonicalName(GeneratedState.fromFeature(target))) return true;
    return false;
}

fn biomeAt(cells: *const [biome.overworld_cell_count]u8, local_x: i32, y: i32, local_z: i32) u8 {
    const quart_x: usize = @intCast(@divFloor(local_x, 4));
    const quart_z: usize = @intCast(@divFloor(local_z, 4));
    const clamped_y = std.math.clamp(y, minimum_y, minimum_y + height - 1);
    const quart_y: usize = @intCast(@divFloor(clamped_y - minimum_y, 4));
    const section = quart_y / 4;
    const section_y = quart_y % 4;
    return cells[
        section * biome.quart_cells_per_section +
            quart_x + quart_z * 4 + section_y * 16
    ];
}

fn minecraftSin(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(
        @as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536),
    ));
}

inline fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}

inline fn blockIndex(local_x: i32, y: i32, local_z: i32) usize {
    return @as(usize, @intCast(y - minimum_y)) * width * width +
        @as(usize, @intCast(local_z)) * width +
        @as(usize, @intCast(local_x));
}
