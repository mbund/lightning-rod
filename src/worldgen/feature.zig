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

    fn state(self: *Region, x: i32, y: i32, z: i32) ?*GeneratedState {
        if (y < minimum_y or y >= minimum_y + height) return null;
        const chunk_x = @divFloor(x, width);
        const chunk_z = @divFloor(z, width);
        const region_x = chunk_x - self.center_chunk_x + 1;
        const region_z = chunk_z - self.center_chunk_z + 1;
        if (region_x < 0 or region_x >= 3 or region_z < 0 or region_z >= 3) return null;
        const chunk_index: usize = @intCast(region_z * 3 + region_x);
        return &self.chunks[chunk_index][blockIndex(@mod(x, width), y, @mod(z, width))];
    }
};

fn fillBiomes(
    region: *Region,
    sampler: *const climate.Sampler,
    lookup: *biome.Lookup,
    chunk_x: i32,
    chunk_z: i32,
    output: *[biome.overworld_cell_count]u8,
) void {
    _ = lookup;
    @memcpy(output, region.biome_cache.chunk(sampler, chunk_x, chunk_z));
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
                    !std.mem.eql(u8, target.canonicalName(), data.state_names[config.fluid]))
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
                target.* = .{ .feature = if (local_y >= 4) config.air else config.fluid };
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
                target.* = .{ .feature = config.barrier };
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
    const name = state.canonicalName();
    return !featureCanReplace(state) or
        std.mem.indexOf(u8, name, "_leaves[") != null or
        std.mem.indexOf(u8, name, "_log[") != null;
}

fn featureCanReplace(state: GeneratedState) bool {
    const name = state.canonicalName();
    return !std.mem.eql(u8, name, "minecraft:bedrock") and
        !std.mem.eql(u8, name, "minecraft:spawner") and
        !std.mem.startsWith(u8, name, "minecraft:chest[") and
        !std.mem.startsWith(u8, name, "minecraft:end_portal_frame[") and
        !std.mem.eql(u8, name, "minecraft:reinforced_deepslate") and
        !std.mem.startsWith(u8, name, "minecraft:trial_spawner[") and
        !std.mem.startsWith(u8, name, "minecraft:vault[");
}

fn isLakeSolid(state: GeneratedState) bool {
    if (isAir(state) or isWater(state) or isLava(state)) return false;
    const name = state.canonicalName();
    return !std.mem.eql(u8, name, "minecraft:cave_air") and
        !std.mem.eql(u8, name, "minecraft:powder_snow") and
        !std.mem.startsWith(u8, name, "minecraft:snow[");
}

pub fn applyUndergroundFeatures(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) !void {
    try applyOres(
        chunk_x,
        chunk_z,
        climate_sampler,
        ocean_floor,
        decorator_random,
        region,
        0,
        26,
    );
    applyUnderwaterMagma(
        chunk_x,
        chunk_z,
        climate_sampler,
        ocean_floor,
        decorator_random,
        region,
    );
    try applyOres(
        chunk_x,
        chunk_z,
        climate_sampler,
        ocean_floor,
        decorator_random,
        region,
        27,
        29,
    );
    applyDisks(
        chunk_x,
        chunk_z,
        climate_sampler,
        ocean_floor,
        decorator_random,
        region,
    );
    try applyOres(
        chunk_x,
        chunk_z,
        climate_sampler,
        ocean_floor,
        decorator_random,
        region,
        33,
        34,
    );
}

pub fn applyPointedDripstone(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var selected = false;
    var neighbor_z = chunk_z - 1;
    while (!selected and neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (!selected and neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index| {
                if (!data.biome_pointed_dripstone[biome_index]) continue;
                selected = true;
                break;
            }
        }
    }
    if (!selected) return;

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
    decorator_random: *DecoratorRandom,
    region: *Region,
) usize {
    var selected = false;
    var neighbor_z = chunk_z - 1;
    while (!selected and neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (!selected and neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var cells: [biome.overworld_cell_count]u8 = undefined;
            var lookup = biome.Lookup{};
            fillBiomes(region, climate_sampler, &lookup, neighbor_x, neighbor_z, &cells);
            for (cells) |biome_index| {
                if (!data.biome_pointed_dripstone[biome_index]) continue;
                selected = true;
                break;
            }
        }
    }
    if (!selected) return 0;

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
        target.* = .{ .base = .air };
        return 1;
    } else if (values.layer >= shape.inner_threshold) {
        const alternate = @as(f64, source.nextF32()) < config.alternate_inner_layer_chance;
        const replaced = featureCanReplace(target.*);
        if (replaced)
            target.* = .{ .feature = if (alternate) config.alternate_inner_layer_state else config.inner_layer_state };
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
        target.* = .{ .feature = config.middle_layer_state };
    } else {
        if (!featureCanReplace(target.*)) return 0;
        target.* = .{ .feature = config.outer_layer_state };
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
                target.* = .{
                    .feature = config.inner_placements[placement_index][direction_index][waterlogged],
                };
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
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:bedrock") or
        isWater(state) or isLava(state) or
        std.mem.eql(u8, name, "minecraft:ice") or
        std.mem.eql(u8, name, "minecraft:packed_ice") or
        std.mem.eql(u8, name, "minecraft:blue_ice");
}

pub fn applyDripstoneClusters(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var selected = false;
    var neighbor_z = chunk_z - 1;
    while (!selected and neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (!selected and neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var cells: [biome.overworld_cell_count]u8 = undefined;
            var lookup = biome.Lookup{};
            fillBiomes(region, climate_sampler, &lookup, neighbor_x, neighbor_z, &cells);
            for (cells) |biome_index| {
                if (!data.biome_pointed_dripstone[biome_index]) continue;
                selected = true;
                break;
            }
        }
    }
    if (!selected) return;

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
                        target.* = .{ .feature = config.dripstone_block };
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
    return std.mem.startsWith(u8, state.canonicalName(), "minecraft:lava[");
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
        region.state(column.origin.x, cave.floor.?, column.origin.z).?.* = .{ .base = .water };
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
        state.* = .{ .feature = data.pointed_dripstone.dripstone_block };
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
    state.* = .{ .feature = config.pointed_states[direction_base + thickness][waterlogged] };
}

fn isLavaAt(region: *Region, x: i32, y: i32, z: i32) bool {
    const state = region.state(x, y, z) orelse return false;
    return std.mem.startsWith(u8, state.canonicalName(), "minecraft:lava[");
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
    return switch (state) {
        .feature => |index| index == data.pointed_dripstone.dripstone_block or
            isClusterPointedIndex(index),
        .base, .surface => false,
    };
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
    state.* = .{ .feature = config.dripstone_block };
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
    state.* = .{ .feature = config.pointed_states[state_index][waterlogged] };
}

fn dripstoneCanReplace(state: GeneratedState) bool {
    if (switch (state) {
        .feature => |index| index == data.pointed_dripstone.dripstone_block,
        .base, .surface => false,
    }) return true;
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:stone") or
        std.mem.eql(u8, name, "minecraft:granite") or
        std.mem.eql(u8, name, "minecraft:diorite") or
        std.mem.eql(u8, name, "minecraft:andesite") or
        std.mem.eql(u8, name, "minecraft:tuff") or
        std.mem.eql(u8, name, "minecraft:deepslate[axis=y]");
}

fn addPosition(a: Position, b: Position) Position {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

pub fn applyFluidSprings(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected_mask: u8 = 0;
    var neighbor_z = chunk_z - 1;
    while (neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index|
                selected_mask |= data.biome_fluid_spring_masks[biome_index];
        }
    }
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
            const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
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
        target.* = .{ .feature = config.state };
}

fn applyUnderwaterMagma(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected = false;
    var neighbor_z = chunk_z - 1;
    while (!selected and neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (!selected and neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index| {
                if (!data.biome_underwater_magma[biome_index]) continue;
                selected = true;
                break;
            }
        }
    }
    if (!selected) return;

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
        const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
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
                state.* = .{ .feature = config.state };
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
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
    first_index: u8,
    end_index: u8,
) !void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected_mask: u64 = 0;
    var neighbor_z = chunk_z - 1;
    while (neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index|
                selected_mask |= data.biome_ore_masks[biome_index];
        }
    }

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.ores) |ore| {
        if (ore.index < first_index or ore.index >= end_index) continue;
        const feature_bit = @as(u64, 1) << @intCast(ore.index);
        if (selected_mask & feature_bit == 0) continue;
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
            const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
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

fn applyDisks(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected_mask: u64 = 0;
    var neighbor_z = chunk_z - 1;
    while (neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index|
                selected_mask |= data.biome_disk_masks[biome_index];
        }
    }

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.disks) |disk| {
        const feature_bit = @as(u64, 1) << @intCast(disk.index);
        if (selected_mask & feature_bit == 0) continue;
        const source = decorator_random.begin(disk.index, 6);
        for (0..disk.count) |_| {
            const x = first_x + source.nextBoundedI32(width);
            const z = first_z + source.nextBoundedI32(width);
            const halo_x: usize = @intCast(x - first_x + width);
            const halo_z: usize = @intCast(z - first_z + width);
            const y: i32 = ocean_floor[halo_z * height_halo_side + halo_x];
            const origin = region.state(x, y, z) orelse continue;
            if (disk.requires_water and !isWater(origin.*)) continue;
            const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
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
                const output = if (disk.state_above_air) |above_air| blk: {
                    const below = region.state(x, y - 1, z);
                    break :blk if (below != null and isAir(below.?.*)) above_air else disk.state;
                } else disk.state;
                state.* = .{ .feature = output };
            }
        }
    }
}

pub fn applyGlowLichen(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected = false;
    var neighbor_z = chunk_z - 1;
    while (!selected and neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (!selected and neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index| {
                if (!data.biome_glow_lichen[biome_index]) continue;
                selected = true;
                break;
            }
        }
    }
    if (!selected) return;

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
        const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
        if (!data.biome_glow_lichen[biome_index]) continue;
        _ = generateGlowLichen(source, region, .{ .x = x, .y = y, .z = z });
    }
}

pub fn applyForestFlowers(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.forest_flowers;
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected = false;
    for (biomes) |biome_index| {
        if (!data.biome_forest_flowers[biome_index]) continue;
        selected = true;
        break;
    }
    if (!selected) return;

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
            biomeAt(&biomes, origin_x - first_x, origin_y, origin_z - first_z);
        if (!data.biome_forest_flowers[biome_index]) continue;
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
                target.* = .{ .feature = config.lower_states[flower_index] };
                upper.* = .{ .feature = config.upper_states[flower_index] };
            } else {
                target.* = .{ .feature = config.lily_state };
            }
        }
    }
}

pub fn applyOakLeafLitterTrees(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.oak_leaf_litter_trees;
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected = false;
    for (biomes) |biome_index| {
        if (!data.biome_oak_leaf_litter_trees[biome_index]) continue;
        selected = true;
        break;
    }
    if (!selected) return;

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
        const biome_index = biomeAt(&biomes, x - first_x, y, z - first_z);
        if (!data.biome_oak_leaf_litter_trees[biome_index]) continue;

        if (source.nextF32() < config.selectors[0]) continue;
        if (source.nextF32() < config.selectors[1]) {
            if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
            _ = generateLeafLitterTree(
                source,
                region,
                .{ .x = x, .y = y, .z = z },
                .birch,
            );
            continue;
        }
        if (source.nextF32() < config.selectors[2]) {
            if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
            _ = generateFancyLeafLitterTree(
                source,
                region,
                .{ .x = x, .y = y, .z = z },
            );
            continue;
        }
        if (source.nextF32() < config.selectors[3]) continue;
        if (!saplingWouldSurvive(region, .{ .x = x, .y = y, .z = z })) continue;
        _ = generateLeafLitterTree(
            source,
            region,
            .{ .x = x, .y = y, .z = z },
            .oak,
        );
    }
}

pub fn applyForestGrassPatch(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    world_surface: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const config = data.patch_grass_forest;
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected = false;
    for (biomes) |biome_index| {
        if (!data.biome_patch_grass_forest[biome_index]) continue;
        selected = true;
        break;
    }
    if (!selected) return;

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
            biomeAt(&biomes, origin_x - first_x, origin_y, origin_z - first_z);
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
            target.* = .{ .feature = config.state };
        }
    }
}

pub fn applyNoiseGrassPatches(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    world_surface: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);
    var selected_mask: u8 = 0;
    for (biomes) |biome_index|
        selected_mask |= data.biome_noise_grass_patch_masks[biome_index];
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const temperature_noise = biome_temperature.Sampler.init();
    for (data.noise_grass_patches, 0..) |config, patch_index| {
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
            const origin_x = first_x + source.nextBoundedI32(width);
            const origin_z = first_z + source.nextBoundedI32(width);
            const halo_x: usize = @intCast(origin_x - first_x + width);
            const halo_z: usize = @intCast(origin_z - first_z + width);
            const origin_y = world_surface[halo_z * height_halo_side + halo_x];
            const biome_index =
                biomeAt(&biomes, origin_x - first_x, origin_y, origin_z - first_z);
            if (data.biome_noise_grass_patch_masks[biome_index] & patch_bit == 0) continue;
            generateShortGrassPatch(
                source,
                region,
                config.tries,
                config.xz_spread,
                config.y_spread,
                config.state,
                .{ .x = origin_x, .y = origin_y, .z = origin_z },
            );
        }
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
        target.* = .{ .feature = output_state };
    }
}

pub fn applySurfacePatches(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
    minimum_index: u8,
    maximum_index: u8,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);
    var selected_mask: u8 = 0;
    for (biomes) |biome_index| selected_mask |= data.biome_surface_patch_masks[biome_index];
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.surface_patches, 0..) |config, patch_index| {
        if (config.index < minimum_index or config.index >= maximum_index) continue;
        const patch_bit = @as(u8, 1) << @intCast(patch_index);
        if (selected_mask & patch_bit == 0) continue;
        const source = decorator_random.begin(config.index, config.step);
        if (source.nextF32() >= 1.0 / @as(f32, @floatFromInt(config.rarity))) continue;
        const origin_x = first_x + source.nextBoundedI32(width);
        const origin_z = first_z + source.nextBoundedI32(width);
        const origin_y = motionBlockingHeight(region, origin_x, origin_z);
        const biome_index =
            biomeAt(&biomes, origin_x - first_x, origin_y, origin_z - first_z);
        if (data.biome_surface_patch_masks[biome_index] & patch_bit == 0) continue;

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
            const state = if (config.placement == .weighted_flower and
                source.nextBoundedI32(3) >= 2)
                config.state_b
            else
                config.state_a;
            const ground = region.state(x, y - 1, z) orelse continue;
            const can_place = switch (config.placement) {
                .dirt, .weighted_flower => shortGrassCanPlantOn(ground.*),
                .mushroom => mushroomCanPlantOn(ground.*),
                .grass_block => isGrassBlock(ground.*),
            };
            if (!can_place) continue;
            target.* = .{ .feature = state };
        }
    }
}

pub fn applyNearWaterPatches(
    chunk_x: i32,
    chunk_z: i32,
    climate_sampler: *const climate.Sampler,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    var biomes: [biome.overworld_cell_count]u8 = undefined;
    var lookup = biome.Lookup{};
    fillBiomes(region, climate_sampler, &lookup, chunk_x, chunk_z, &biomes);

    var selected_mask: u8 = 0;
    var neighbor_z = chunk_z - 1;
    while (neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var neighbor_lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &neighbor_lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index|
                selected_mask |= data.biome_near_water_patch_masks[biome_index];
        }
    }
    if (selected_mask == 0) return;

    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    for (data.near_water_patches, 0..) |config, patch_index| {
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
                biomeAt(&biomes, origin_x - first_x, origin_y, origin_z - first_z);
            if (data.biome_near_water_patch_masks[biome_index] & patch_bit == 0) continue;
            const origin: Position = .{ .x = origin_x, .y = origin_y, .z = origin_z };
            if (config.placement == .firefly_bush and
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
    ocean_floor: *const HeightHalo,
    decorator_random: *DecoratorRandom,
    region: *Region,
) void {
    const masks = aquaticFeatureMasks(climate_sampler, region, chunk_x, chunk_z);
    if (masks.seagrass == 0 and masks.kelp == 0) return;
    const first_x = chunk_x * width;
    const first_z = chunk_z * width;
    const mixer_seed = biome_access.mixerSeed(world_seed);
    applySeagrass(masks.seagrass, first_x, first_z, mixer_seed, climate_sampler, ocean_floor, decorator_random, region);
    applyKelp(masks.kelp, first_x, first_z, mixer_seed, climate_sampler, ocean_floor, decorator_random, region);
}

const AquaticFeatureMasks = struct {
    seagrass: u8 = 0,
    kelp: u8 = 0,
};

fn aquaticFeatureMasks(climate_sampler: *const climate.Sampler, region: *Region, chunk_x: i32, chunk_z: i32) AquaticFeatureMasks {
    var masks: AquaticFeatureMasks = .{};
    var neighbor_z = chunk_z - 1;
    while (neighbor_z <= chunk_z + 1) : (neighbor_z += 1) {
        var neighbor_x = chunk_x - 1;
        while (neighbor_x <= chunk_x + 1) : (neighbor_x += 1) {
            var neighbor_biomes: [biome.overworld_cell_count]u8 = undefined;
            var lookup = biome.Lookup{};
            fillBiomes(
                region,
                climate_sampler,
                &lookup,
                neighbor_x,
                neighbor_z,
                &neighbor_biomes,
            );
            for (neighbor_biomes) |biome_index| {
                masks.seagrass |= data.biome_seagrass_masks[biome_index];
                masks.kelp |= data.biome_kelp_masks[biome_index];
            }
        }
    }
    return masks;
}

fn applySeagrass(mask: u8, first_x: i32, first_z: i32, mixer_seed: i64, climate_sampler: *const climate.Sampler, ocean_floor: *const HeightHalo, decorator_random: *DecoratorRandom, region: *Region) void {
    for (data.seagrass, 0..) |config, feature_index| {
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
                target.* = .{ .feature = data.tall_seagrass_lower_state };
                upper.* = .{ .feature = data.tall_seagrass_upper_state };
            } else {
                target.* = .{ .feature = data.seagrass_state };
            }
        }
    }
}

fn applyKelp(mask: u8, first_x: i32, first_z: i32, mixer_seed: i64, climate_sampler: *const climate.Sampler, ocean_floor: *const HeightHalo, decorator_random: *DecoratorRandom, region: *Region) void {
    const foliage_noise = biome_temperature.Sampler.init();
    for (data.kelp, 0..) |config, feature_index| {
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
                target.* = .{
                    .feature = data.kelp_states[@intCast(source.nextBoundedI32(4))],
                };
                return;
            }
            target.* = .{ .feature = data.kelp_plant_state };
            continue;
        }
        if (offset <= 0) return;
        const tip = region.state(x, y - 1, z) orelse return;
        const tip_below = region.state(x, y - 2, z) orelse return;
        if (!kelpCanAttachTo(tip_below.*) or isKelpTip(tip_below.*)) return;
        tip.* = .{
            .feature = data.kelp_states[@intCast(source.nextBoundedI32(4))],
        };
        return;
    }
}

fn kelpCanAttachTo(state: GeneratedState) bool {
    return !std.mem.eql(u8, state.canonicalName(), "minecraft:magma_block") and
        (isKelp(state) or isOpaqueFullCube(state));
}

fn isKelp(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index == data.kelp_plant_state or
            (index >= data.kelp_states[0] and index <= data.kelp_states[3]),
        .base, .surface => false,
    };
}

fn isKelpTip(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index >= data.kelp_states[0] and
            index <= data.kelp_states[3],
        .base, .surface => false,
    };
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
                below.* = .{ .feature = data.freeze_top_layer.ice_state };
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
            target.* = .{ .feature = data.freeze_top_layer.snow_state };
            makeSnowy(below);
        }
    }
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
        !std.mem.eql(u8, target.canonicalName(), "minecraft:snow[layers=1]"))
        return false;
    return snowCanSurviveOn(below);
}

fn snowCanSurviveOn(state: GeneratedState) bool {
    const name = state.canonicalName();
    if (std.mem.eql(u8, name, "minecraft:ice") or
        std.mem.eql(u8, name, "minecraft:packed_ice") or
        std.mem.eql(u8, name, "minecraft:barrier")) return false;
    if (std.mem.eql(u8, name, "minecraft:honey_block") or
        std.mem.eql(u8, name, "minecraft:soul_sand") or
        std.mem.eql(u8, name, "minecraft:mud")) return true;
    return hasFullTopFace(state);
}

fn hasFullTopFace(state: GeneratedState) bool {
    if (!blocksMovement(state) or isLeafLitter(state) or
        isNearWaterPlant(state)) return false;
    return !std.mem.startsWith(u8, state.canonicalName(), "minecraft:snow[layers=");
}

fn isNearWaterPlant(state: GeneratedState) bool {
    const index = switch (state) {
        .feature => |feature_index| feature_index,
        .base, .surface => return false,
    };
    for (data.near_water_patches) |patch|
        if (index == patch.state) return true;
    return false;
}

fn makeSnowy(state: *GeneratedState) void {
    const index = switch (state.*) {
        .feature => |feature_index| feature_index,
        .base, .surface => null,
    };
    for (data.freeze_top_layer.snowy_states) |pair| {
        if (index) |feature_index| {
            if (feature_index != pair[0]) continue;
        } else if (!std.mem.eql(u8, state.canonicalName(), data.state_names[pair[0]])) {
            continue;
        }
        state.* = .{ .feature = pair[1] };
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
            .firefly_bush => {
                if (!nearWaterPlantCanSurvive(region, candidate)) continue;
                target.* = .{ .feature = config.state };
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
        state.* = .{ .feature = config.state };
    }
}

fn sugarCaneCanPlace(region: *Region, origin: Position) bool {
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    if (std.mem.eql(u8, ground.canonicalName(), "minecraft:sugar_cane[age=0]"))
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
        std.mem.startsWith(u8, ground.canonicalName(), "minecraft:farmland[");
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
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:dirt") or
        std.mem.eql(u8, name, "minecraft:grass_block[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:grass_block[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:coarse_dirt") or
        std.mem.eql(u8, name, "minecraft:mycelium[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:mycelium[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:rooted_dirt") or
        std.mem.eql(u8, name, "minecraft:moss_block");
}

fn isSandTag(state: GeneratedState) bool {
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:sand") or
        std.mem.eql(u8, name, "minecraft:red_sand");
}

const Position = struct { x: i32, y: i32, z: i32 };
const LeafLitterTreeKind = enum { oak, birch };

fn generateLeafLitterTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
    kind: LeafLitterTreeKind,
) bool {
    const config = data.oak_leaf_litter_trees;
    const base_height: u8 = switch (kind) {
        .oak => config.trunk_base_height,
        .birch => 5,
    };
    const trunk_state: u16 = switch (kind) {
        .oak => config.log_state,
        .birch => config.birch_log_state,
    };
    const leaf_state_base: u16 = switch (kind) {
        .oak => config.leaf_state_base,
        .birch => config.birch_leaf_state_base,
    };
    const trunk_height = @as(i32, base_height) +
        source.nextBoundedI32(@as(i32, config.trunk_height_rand_a) + 1) +
        source.nextBoundedI32(@as(i32, config.trunk_height_rand_b) + 1);
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
        below.* = .{ .feature = config.dirt_state };
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

    finishLeafLitterTree(
        source,
        region,
        logs[0..log_count],
        leaves[0..leaf_count],
    );
    return leaf_count != 0;
}

fn finishLeafLitterTree(
    source: *ChunkRandom,
    region: *Region,
    logs: []const Position,
    leaves: []const Position,
) void {
    _ = source.nextF32() < data.oak_leaf_litter_trees.beehive_probability;
    var decorations: [256]Position = undefined;
    var decoration_count: usize = 0;
    placeLeafLitter(source, region, logs, 96, 4, 2, 12, &decorations, &decoration_count);
    placeLeafLitter(source, region, logs, 150, 2, 2, 16, &decorations, &decoration_count);
    resolveLeafDistance(region, logs, leaves, decorations[0..decoration_count]);
    cleanupTallPlants(region, logs, leaves, decorations[0..decoration_count]);
}

const FancyNode = struct {
    center: Position,
    end_y: i32,
};

fn generateFancyLeafLitterTree(
    source: *ChunkRandom,
    region: *Region,
    origin: Position,
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
        below.* = .{ .feature = config.dirt_state };
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
    finishLeafLitterTree(
        source,
        region,
        logs[0..log_count],
        leaves[0..leaf_count],
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
    decorations: *[256]Position,
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
        target.* = .{ .feature = data.oak_leaf_litter_trees.litter_state_base + selected };
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

    var queues: [7][192]Position = undefined;
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
            state.* = .{ .feature = leaf_state_base +
                @as(u8, @intCast(distance - 1)) };
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
    queue: *[192]Position,
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
    queue: *[192]Position,
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

fn queuePop(queue: *[192]Position, count: *usize, capacity: usize) Position {
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
            state.* = .{ .feature = data.glow_lichen.state_base +
                @as(u8, bits | direction.faceBit()) };
        } else {
            var bits: u7 = direction.faceBit();
            if (isWater(state.*)) bits |= 1 << 6;
            state.* = .{ .feature = data.glow_lichen.state_base + @as(u8, bits) };
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
        state.* = .{ .feature = data.glow_lichen.state_base +
            @as(u8, bits | face.faceBit()) };
    } else {
        var bits: u7 = face.faceBit();
        if (isWater(state.*)) bits |= 1 << 6;
        state.* = .{ .feature = data.glow_lichen.state_base + @as(u8, bits) };
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
                state.* = .{ .feature = target.state };
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
    const name = state.canonicalName();
    return switch (tag) {
        .base_stone_overworld => std.mem.eql(u8, name, "minecraft:stone") or
            std.mem.eql(u8, name, "minecraft:granite") or
            std.mem.eql(u8, name, "minecraft:diorite") or
            std.mem.eql(u8, name, "minecraft:andesite") or
            std.mem.eql(u8, name, "minecraft:deepslate[axis=y]") or
            std.mem.eql(u8, name, "minecraft:tuff"),
        .stone_ore_replaceables => std.mem.eql(u8, name, "minecraft:stone") or
            std.mem.eql(u8, name, "minecraft:granite") or
            std.mem.eql(u8, name, "minecraft:diorite") or
            std.mem.eql(u8, name, "minecraft:andesite"),
        .deepslate_ore_replaceables => std.mem.eql(u8, name, "minecraft:deepslate[axis=y]") or
            std.mem.eql(u8, name, "minecraft:tuff"),
    };
}

fn isAir(state: GeneratedState) bool {
    return switch (state) {
        .base => |material| material == .air,
        .surface, .feature => false,
    };
}

fn isWater(state: GeneratedState) bool {
    return switch (state) {
        .base => |material| material == .water,
        .surface => false,
        .feature => std.mem.startsWith(u8, state.canonicalName(), "minecraft:water["),
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
    var y: i32 = minimum_y + height;
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (!isAir(state.*)) return y + 1;
    }
    return minimum_y;
}

fn oceanFloorHeight(region: *Region, x: i32, z: i32) i32 {
    var y: i32 = minimum_y + height;
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (blocksMovement(state.*)) return y + 1;
    }
    return minimum_y;
}

fn motionBlockingNoLeavesHeight(region: *Region, x: i32, z: i32) i32 {
    var y: i32 = minimum_y + height;
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (isWater(state.*) or isOpaqueFullCube(state.*)) return y + 1;
    }
    return minimum_y;
}

fn motionBlockingHeight(region: *Region, x: i32, z: i32) i32 {
    var y: i32 = minimum_y + height;
    while (y > minimum_y) {
        y -= 1;
        const state = region.state(x, y, z) orelse continue;
        if (isWater(state.*) or isOpaqueFullCube(state.*) or
            treeLeafDistance(state.*) != 0) return y + 1;
    }
    return minimum_y;
}

fn saplingWouldSurvive(region: *Region, origin: Position) bool {
    const ground = region.state(origin.x, origin.y - 1, origin.z) orelse return false;
    const name = ground.canonicalName();
    return std.mem.eql(u8, name, "minecraft:grass_block[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:dirt") or
        std.mem.eql(u8, name, "minecraft:coarse_dirt") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:rooted_dirt") or
        std.mem.eql(u8, name, "minecraft:moss_block");
}

fn isGrassBlock(state: GeneratedState) bool {
    return std.mem.eql(u8, state.canonicalName(), "minecraft:grass_block[snowy=false]");
}

fn shortGrassCanPlantOn(state: GeneratedState) bool {
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:dirt") or
        std.mem.eql(u8, name, "minecraft:grass_block[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:grass_block[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:coarse_dirt") or
        std.mem.eql(u8, name, "minecraft:mycelium[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:mycelium[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:rooted_dirt") or
        std.mem.eql(u8, name, "minecraft:moss_block") or
        std.mem.eql(u8, name, "minecraft:muddy_mangrove_roots") or
        std.mem.eql(u8, name, "minecraft:farmland[moisture=0]") or
        std.mem.startsWith(u8, name, "minecraft:farmland[moisture=");
}

fn mushroomCanPlantOn(state: GeneratedState) bool {
    const name = state.canonicalName();
    return std.mem.eql(u8, name, "minecraft:mycelium[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:mycelium[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=false]") or
        std.mem.eql(u8, name, "minecraft:podzol[snowy=true]") or
        std.mem.eql(u8, name, "minecraft:nylium") or
        isOpaqueFullCube(state);
}

fn canTreeReplace(state: GeneratedState) bool {
    return isAir(state) or isWater(state) or treeLeafDistance(state) != 0 or
        lichenStateBits(state) != null or isForestFlower(state) or
        isForestGrass(state) or isLeafLitter(state) or
        isTreeReplaceableSurfacePatch(state);
}

fn isTreeReplaceableSurfacePatch(state: GeneratedState) bool {
    const index = switch (state) {
        .feature => |feature_index| feature_index,
        .base, .surface => return false,
    };
    for (data.surface_patches) |patch| {
        if (patch.placement != .dirt and patch.placement != .weighted_flower) continue;
        if (index == patch.state_a or index == patch.state_b) return true;
    }
    return false;
}

fn placeTreeState(region: *Region, position: Position, feature_state: u16) void {
    const target = region.state(position.x, position.y, position.z) orelse return;
    target.* = .{ .feature = feature_state };
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
                const index = switch (state.*) {
                    .feature => |feature_index| feature_index,
                    .base, .surface => continue,
                };
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
                        state.* = .{ .base = .air };
                        break;
                    };
                    const valid = switch (counterpart.*) {
                        .feature => |feature_index| feature_index == expected,
                        .base, .surface => false,
                    };
                    if (!valid) state.* = .{ .base = .air };
                    break;
                }
            }
        }
    }
}

fn isForestGrass(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index == data.patch_grass_forest.state,
        .base, .surface => false,
    };
}

fn isForestFlower(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index == data.forest_flowers.lily_state or
            std.mem.indexOfScalar(u16, &data.forest_flowers.lower_states, index) != null or
            std.mem.indexOfScalar(u16, &data.forest_flowers.upper_states, index) != null,
        .base, .surface => false,
    };
}

fn isLog(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index == data.oak_leaf_litter_trees.log_state or
            index == data.oak_leaf_litter_trees.log_x_state or
            index == data.oak_leaf_litter_trees.log_z_state or
            index == data.oak_leaf_litter_trees.birch_log_state,
        .base, .surface => false,
    };
}

fn treeLeafDistance(state: GeneratedState) u8 {
    const state_base = treeLeafStateBase(state) orelse return 0;
    return switch (state) {
        .feature => |index| @intCast(index - state_base + 1),
        .base, .surface => unreachable,
    };
}

fn treeLeafStateBase(state: GeneratedState) ?u16 {
    return switch (state) {
        .feature => |index| if (index >= data.oak_leaf_litter_trees.leaf_state_base and
            index < data.oak_leaf_litter_trees.leaf_state_base + 7)
            data.oak_leaf_litter_trees.leaf_state_base
        else if (index >= data.oak_leaf_litter_trees.birch_leaf_state_base and
            index < data.oak_leaf_litter_trees.birch_leaf_state_base + 7)
            data.oak_leaf_litter_trees.birch_leaf_state_base
        else
            null,
        .base, .surface => null,
    };
}

fn isOpaqueFullCube(state: GeneratedState) bool {
    if (isAir(state) or isWater(state) or treeLeafDistance(state) != 0 or
        lichenStateBits(state) != null or isForestFlower(state) or
        isForestGrass(state) or isNonSolidSurfacePatch(state) or
        isNearWaterPlant(state) or isAquaticPlant(state)) return false;
    const name = state.canonicalName();
    return !std.mem.startsWith(u8, name, "minecraft:leaf_litter[");
}

fn blocksMovement(state: GeneratedState) bool {
    if (isAir(state) or isWater(state) or lichenStateBits(state) != null or
        isForestFlower(state) or isForestGrass(state) or isNonSolidSurfacePatch(state) or
        isLeafLitter(state) or isNearWaterPlant(state) or isAquaticPlant(state)) return false;
    const name = state.canonicalName();
    return !std.mem.startsWith(u8, name, "minecraft:lava[");
}

fn isNonSolidSurfacePatch(state: GeneratedState) bool {
    const index = switch (state) {
        .feature => |feature_index| feature_index,
        .base, .surface => return false,
    };
    for (data.surface_patches) |patch| {
        if (patch.placement == .grass_block) continue;
        if (index == patch.state_a or index == patch.state_b) return true;
    }
    return false;
}

fn isLeafLitter(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index >= data.oak_leaf_litter_trees.litter_state_base and
            index < data.oak_leaf_litter_trees.litter_state_base + 16,
        .base, .surface => false,
    };
}

fn isAquaticPlant(state: GeneratedState) bool {
    return switch (state) {
        .feature => |index| index == data.seagrass_state or
            index == data.tall_seagrass_lower_state or
            index == data.tall_seagrass_upper_state or
            index == data.kelp_plant_state or
            (index >= data.kelp_states[0] and index <= data.kelp_states[3]),
        .base, .surface => false,
    };
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
    return switch (state) {
        .feature => |index| if (index >= data.glow_lichen.state_base and
            index < data.glow_lichen.state_base + 128)
            @intCast(index - data.glow_lichen.state_base)
        else
            null,
        .base, .surface => null,
    };
}

fn lichenCanPlaceOn(state: GeneratedState) bool {
    const name = state.canonicalName();
    for (data.glow_lichen.can_place_on) |allowed|
        if (std.mem.eql(u8, name, allowed)) return true;
    return false;
}

fn lichenCanGrowOn(state: GeneratedState) bool {
    return !isAir(state) and !isWater(state) and lichenStateBits(state) == null;
}

fn diskTargetMatches(state: GeneratedState, targets: []const u8) bool {
    const name = state.canonicalName();
    for (targets) |target|
        if (std.mem.eql(u8, name, data.state_names[target])) return true;
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
