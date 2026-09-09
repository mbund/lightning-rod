const std = @import("std");
const preallocated = @import("preallocated");
const density = @import("density.zig");
const random = @import("random.zig");

pub const Material = enum(u8) {
    stone,
    air,
    water,
    lava,
};

const FluidLevel = struct {
    max_y: i32,
    material: Material,

    fn materialAt(self: FluidLevel, y: i32) Material {
        return if (y < self.max_y) self.material else .air;
    }
};

const HeightCacheEntry = struct {
    occupied: bool = false,
    key: u64 = 0,
    value: i32 = 0,
};

const FluidCacheEntry = struct {
    occupied: bool = false,
    grid_x: i32 = 0,
    grid_y: i32 = 0,
    grid_z: i32 = 0,
    value: FluidLevel = undefined,
};

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    router: *density.Router,
    aquifer_splitter: random.Splitter,
    start_x: i32,
    start_y: i32,
    start_z: i32,
    size_x: usize,
    size_y: usize,
    size_z: usize,
    positions: []density.Position,
    levels: []FluidLevel,
    level_initialized: []bool,
    uniform_levels: []FluidLevel,
    uniform_level_state: []u8,
    fluid_cache: []FluidCacheEntry,
    height_cache: []HeightCacheEntry,

    const minimum_height_cell = -32_512;
    const sea_level = 63;
    const lava_level = -54;
    const height_cache_ways = 4;
    const height_cache_capacity = 32_768;
    const fluid_cache_ways = 4;
    const fluid_cache_capacity = 32_768;
    const LaneWork = struct {
        closest_positions: [3]density.Position = undefined,
        closest_distances: [3]i32 = undefined,
        first_level: FluidLevel = undefined,
        first_similarity: f64 = 0,
        material: Material = .air,
        needs_barrier: bool = false,
    };
    const ClosestBatch = struct {
        positions: [density.sample_lanes][3]density.Position,
        distances: [density.sample_lanes][3]i32,
    };
    const Closest = struct {
        positions: [3]density.Position,
        distances: [3]i32,
    };
    const surface_offsets = [_][2]i8{
        .{ 0, 0 },
        .{ -2, -1 },
        .{ -1, -1 },
        .{ 0, -1 },
        .{ 1, -1 },
        .{ -3, 0 },
        .{ -2, 0 },
        .{ -1, 0 },
        .{ 1, 0 },
        .{ -2, 1 },
        .{ -1, 1 },
        .{ 0, 1 },
        .{ 1, 1 },
    };

    pub fn init(
        allocator: std.mem.Allocator,
        router: *density.Router,
        world_seed: u64,
        chunk_x: i32,
        chunk_z: i32,
    ) !Sampler {
        const start_x = chunk_x - 1;
        const end_x = chunk_x + 1;
        const start_y = @divFloor(density.ChunkInterpolator.minimum_y, 12) - 1;
        const end_y = @divFloor(
            density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height,
            12,
        ) + 1;
        const start_z = chunk_z - 1;
        const end_z = chunk_z + 1;
        const size_x: usize = @intCast(end_x - start_x + 1);
        const size_y: usize = @intCast(end_y - start_y + 1);
        const size_z: usize = @intCast(end_z - start_z + 1);
        const count = size_x * size_y * size_z;
        const positions = try preallocated.alloc(density.Position, allocator, count);
        errdefer allocator.free(positions);
        const levels = try preallocated.alloc(FluidLevel, allocator, count);
        errdefer allocator.free(levels);
        const level_initialized = try preallocated.alloc(bool, allocator, count);
        errdefer allocator.free(level_initialized);
        @memset(level_initialized, false);
        const uniform_levels = try preallocated.alloc(FluidLevel, allocator, count);
        errdefer allocator.free(uniform_levels);
        const uniform_level_state = try preallocated.alloc(u8, allocator, count);
        errdefer allocator.free(uniform_level_state);
        @memset(uniform_level_state, 0);
        const fluid_cache = try preallocated.alloc(FluidCacheEntry, allocator, fluid_cache_capacity);
        errdefer allocator.free(fluid_cache);
        @memset(fluid_cache, .{});
        const height_cache = try preallocated.alloc(HeightCacheEntry, allocator, height_cache_capacity);
        errdefer allocator.free(height_cache);
        @memset(height_cache, .{});

        var base = random.Xoroshiro.init(world_seed);
        const base_splitter = base.splitter();
        var aquifer_random = base_splitter.splitString("minecraft:aquifer");
        const aquifer_splitter = aquifer_random.splitter();
        var result: Sampler = .{
            .allocator = allocator,
            .router = router,
            .aquifer_splitter = aquifer_splitter,
            .start_x = start_x,
            .start_y = start_y,
            .start_z = start_z,
            .size_x = size_x,
            .size_y = size_y,
            .size_z = size_z,
            .positions = positions,
            .levels = levels,
            .level_initialized = level_initialized,
            .uniform_levels = uniform_levels,
            .uniform_level_state = uniform_level_state,
            .fluid_cache = fluid_cache,
            .height_cache = height_cache,
        };
        result.prepare(chunk_x, chunk_z);
        return result;
    }

    pub fn prepare(self: *Sampler, chunk_x: i32, chunk_z: i32) void {
        self.start_x = chunk_x - 1;
        self.start_z = chunk_z - 1;
        @memset(self.level_initialized, false);
        @memset(self.uniform_level_state, 0);
        for (0..self.size_y) |offset_y| {
            for (0..self.size_z) |offset_z| {
                for (0..self.size_x) |offset_x| {
                    const grid_x = self.start_x + @as(i32, @intCast(offset_x));
                    const grid_y = self.start_y + @as(i32, @intCast(offset_y));
                    const grid_z = self.start_z + @as(i32, @intCast(offset_z));
                    var source = self.aquifer_splitter.splitPosition(grid_x, grid_y, grid_z);
                    self.positions[self.index(grid_x, grid_y, grid_z)] = .{
                        .x = grid_x * 16 + source.nextBoundedI32(10),
                        .y = grid_y * 12 + source.nextBoundedI32(9),
                        .z = grid_z * 16 + source.nextBoundedI32(10),
                    };
                }
            }
        }
    }

    pub fn reseed(self: *Sampler, router: *density.Router, world_seed: u64) void {
        var base = random.Xoroshiro.init(world_seed);
        var aquifer_random = base.splitter().splitString("minecraft:aquifer");
        self.router = router;
        self.aquifer_splitter = aquifer_random.splitter();
        @memset(self.level_initialized, false);
        @memset(self.uniform_level_state, 0);
        @memset(self.fluid_cache, .{});
        @memset(self.height_cache, .{});
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.height_cache);
        self.allocator.free(self.fluid_cache);
        self.allocator.free(self.uniform_level_state);
        self.allocator.free(self.uniform_levels);
        self.allocator.free(self.level_initialized);
        self.allocator.free(self.levels);
        self.allocator.free(self.positions);
        self.* = undefined;
    }

    pub fn material(self: *Sampler, position: density.Position, final_density: f64) Material {
        @setRuntimeSafety(false);
        if (final_density > 0) return .stone;
        const default_level = defaultFluidLevel(position.y);
        if (default_level.materialAt(position.y) == .lava) return .lava;
        const closest = self.closestLevels(position);
        return self.materialFromLevels(position, final_density, closest.positions, closest.distances);
    }

    fn closestLevels(self: *Sampler, position: density.Position) Closest {
        const scaled_x = @divFloor(position.x - 5, 16);
        const scaled_y = @divFloor(position.y + 1, 12);
        const scaled_z = @divFloor(position.z - 5, 16);
        var closest_positions: [3]density.Position = undefined;
        var closest_distances = [_]i32{std.math.maxInt(i32)} ** 3;
        for (0..2) |offset_x| {
            for ([_]i32{ -1, 0, 1 }) |offset_y| {
                for (0..2) |offset_z| {
                    const candidate = self.positions[
                        self.index(
                            scaled_x + @as(i32, @intCast(offset_x)),
                            scaled_y + offset_y,
                            scaled_z + @as(i32, @intCast(offset_z)),
                        )
                    ];
                    const dx = candidate.x - position.x;
                    const dy = candidate.y - position.y;
                    const dz = candidate.z - position.z;
                    const distance = dx * dx + dy * dy + dz * dz;
                    if (closest_distances[2] >= distance) {
                        closest_positions[2] = candidate;
                        closest_distances[2] = distance;
                    }
                    if (closest_distances[1] >= distance) {
                        closest_positions[2] = closest_positions[1];
                        closest_distances[2] = closest_distances[1];
                        closest_positions[1] = candidate;
                        closest_distances[1] = distance;
                    }
                    if (closest_distances[0] >= distance) {
                        closest_positions[1] = closest_positions[0];
                        closest_distances[1] = closest_distances[0];
                        closest_positions[0] = candidate;
                        closest_distances[0] = distance;
                    }
                }
            }
        }
        return .{ .positions = closest_positions, .distances = closest_distances };
    }

    fn materialFromLevels(self: *Sampler, position: density.Position, final_density: f64, closest_positions: [3]density.Position, closest_distances: [3]i32) Material {
        const first_level = self.waterLevel(closest_positions[0]);
        const first_similarity = similarity(closest_distances[0], closest_distances[1]);
        const material_at_position = first_level.materialAt(position.y);
        if (first_similarity <= 0) return material_at_position;
        if (material_at_position == .water and defaultFluidLevel(position.y - 1).materialAt(position.y - 1) == .lava)
            return material_at_position;

        const barrier = self.router.sampleBarrier(position);
        const second_level = self.waterLevel(closest_positions[1]);
        const first_barrier = first_similarity * calculateBarrier(position.y, barrier, first_level, second_level);
        if (final_density + first_barrier > 0) return .stone;

        const third_level = self.waterLevel(closest_positions[2]);
        const second_similarity = similarity(closest_distances[0], closest_distances[2]);
        if (second_similarity > 0) {
            const second_barrier = first_similarity * second_similarity *
                calculateBarrier(position.y, barrier, first_level, third_level);
            if (final_density + second_barrier > 0) return .stone;
        }
        const third_similarity = similarity(closest_distances[1], closest_distances[2]);
        if (third_similarity > 0) {
            const third_barrier = first_similarity * third_similarity *
                calculateBarrier(position.y, barrier, second_level, third_level);
            if (final_density + third_barrier > 0) return .stone;
        }
        return material_at_position;
    }

    pub fn material4(
        self: *Sampler,
        positions: [density.sample_lanes]density.Position,
        final_densities: @Vector(density.sample_lanes, f64),
    ) [density.sample_lanes]Material {
        const density_values: [density.sample_lanes]f64 = final_densities;
        var result: [density.sample_lanes]Material = undefined;
        var work: [density.sample_lanes]LaneWork = undefined;
        var needs_cells = [_]bool{false} ** density.sample_lanes;
        if (classifyLanes(positions, density_values, &result, &work, &needs_cells) == 0)
            return result;
        if (self.resolveUniformLevels(positions, &needs_cells, &result) == 0)
            return result;
        const closest = self.findClosestBatch(positions);
        const barrier_count = self.prepareBarrierWork(
            positions,
            closest,
            needs_cells,
            &result,
            &work,
        );
        if (barrier_count == 0) return result;
        const barrier_values = self.sampleBarriers(positions, work, barrier_count);
        for (0..density.sample_lanes) |lane| {
            if (!work[lane].needs_barrier) continue;
            result[lane] = self.resolveBarrierLane(
                positions[lane],
                density_values[lane],
                barrier_values[lane],
                work[lane],
            );
        }
        return result;
    }

    pub fn negativeCellMaterials(
        self: *Sampler,
        first: density.Position,
        output: *[128]Material,
    ) bool {
        var output_index: usize = 0;
        for (0..8) |local_y| {
            const y = first.y + @as(i32, @intCast(local_y));
            for (0..4) |local_x| {
                const x = first.x + @as(i32, @intCast(local_x));
                for (0..4) |local_z| {
                    const z = first.z + @as(i32, @intCast(local_z));
                    const default = defaultFluidLevel(y).materialAt(y);
                    if (default == .lava) {
                        output[output_index] = .lava;
                    } else {
                        const level = self.uniformCandidateLevel(
                            @divFloor(x - 5, 16),
                            @divFloor(y + 1, 12),
                            @divFloor(z - 5, 16),
                        ) orelse return false;
                        output[output_index] = level.materialAt(y);
                    }
                    output_index += 1;
                }
            }
        }
        return true;
    }

    fn resolveUniformLevels(
        self: *Sampler,
        positions: [density.sample_lanes]density.Position,
        needs_cells: *[density.sample_lanes]bool,
        result: *[density.sample_lanes]Material,
    ) usize {
        var remaining: usize = 0;
        for (positions, 0..) |position, lane| {
            if (!needs_cells[lane]) continue;
            const level = self.uniformCandidateLevel(
                @divFloor(position.x - 5, 16),
                @divFloor(position.y + 1, 12),
                @divFloor(position.z - 5, 16),
            );
            if (level) |uniform| {
                result[lane] = uniform.materialAt(position.y);
                needs_cells[lane] = false;
            } else {
                remaining += 1;
            }
        }
        return remaining;
    }

    fn uniformCandidateLevel(self: *Sampler, grid_x: i32, grid_y: i32, grid_z: i32) ?FluidLevel {
        const cache_index = self.index(grid_x, grid_y, grid_z);
        if (self.uniform_level_state[cache_index] != 0)
            return if (self.uniform_level_state[cache_index] == 2)
                self.uniform_levels[cache_index]
            else
                null;
        var first: ?FluidLevel = null;
        for (0..2) |offset_x| for ([_]i32{ -1, 0, 1 }) |offset_y| for (0..2) |offset_z| {
            const candidate = self.positions[
                self.index(
                    grid_x + @as(i32, @intCast(offset_x)),
                    grid_y + offset_y,
                    grid_z + @as(i32, @intCast(offset_z)),
                )
            ];
            const level = self.waterLevel(candidate);
            if (first) |expected| {
                if (level.max_y != expected.max_y or level.material != expected.material) {
                    self.uniform_level_state[cache_index] = 1;
                    return null;
                }
            } else {
                first = level;
            }
        };
        self.uniform_levels[cache_index] = first.?;
        self.uniform_level_state[cache_index] = 2;
        return first;
    }

    fn classifyLanes(
        positions: [density.sample_lanes]density.Position,
        densities: [density.sample_lanes]f64,
        result: *[density.sample_lanes]Material,
        work: *[density.sample_lanes]LaneWork,
        needs_cells: *[density.sample_lanes]bool,
    ) usize {
        var count: usize = 0;
        for (positions, densities, 0..) |position, value, lane| {
            work[lane].needs_barrier = false;
            if (value > 0) {
                result[lane] = .stone;
            } else if (defaultFluidLevel(position.y).materialAt(position.y) == .lava) {
                result[lane] = .lava;
            } else {
                needs_cells[lane] = true;
                count += 1;
            }
        }
        return count;
    }

    fn findClosestBatch(self: *Sampler, positions: [density.sample_lanes]density.Position) ClosestBatch {
        const grid_x = @divFloor(positions[0].x - 5, 16);
        const grid_y = @divFloor(positions[0].y + 1, 12);
        const grid_z = @divFloor(positions[0].z - 5, 16);
        var uniform_grid = true;
        inline for (1..density.sample_lanes) |lane| {
            uniform_grid = uniform_grid and
                @divFloor(positions[lane].x - 5, 16) == grid_x and
                @divFloor(positions[lane].y + 1, 12) == grid_y and
                @divFloor(positions[lane].z - 5, 16) == grid_z;
        }
        if (uniform_grid)
            return self.findClosestUniformGrid(positions, grid_x, grid_y, grid_z);
        const V = @Vector(density.sample_lanes, i32);
        var position_x_values: [density.sample_lanes]i32 = undefined;
        var position_y_values: [density.sample_lanes]i32 = undefined;
        var position_z_values: [density.sample_lanes]i32 = undefined;
        var grid_x_values: [density.sample_lanes]i32 = undefined;
        var grid_y_values: [density.sample_lanes]i32 = undefined;
        var grid_z_values: [density.sample_lanes]i32 = undefined;
        for (positions, 0..) |position, lane| {
            position_x_values[lane] = position.x;
            position_y_values[lane] = position.y;
            position_z_values[lane] = position.z;
            grid_x_values[lane] = @divFloor(position.x - 5, 16);
            grid_y_values[lane] = @divFloor(position.y + 1, 12);
            grid_z_values[lane] = @divFloor(position.z - 5, 16);
        }
        const query = [3]V{ position_x_values, position_y_values, position_z_values };
        var nearest: [3][3]V = @splat(@splat(@splat(0)));
        var distances: [3]V = @splat(@splat(std.math.maxInt(i32)));
        for (0..2) |offset_x| {
            for ([_]i32{ -1, 0, 1 }) |offset_y| {
                for (0..2) |offset_z| {
                    var candidate_values: [3][density.sample_lanes]i32 = undefined;
                    for (0..density.sample_lanes) |lane| {
                        const candidate = self.positions[
                            self.index(
                                grid_x_values[lane] +
                                    @as(i32, @intCast(offset_x)),
                                grid_y_values[lane] + offset_y,
                                grid_z_values[lane] +
                                    @as(i32, @intCast(offset_z)),
                            )
                        ];
                        candidate_values[0][lane] = candidate.x;
                        candidate_values[1][lane] = candidate.y;
                        candidate_values[2][lane] = candidate.z;
                    }
                    const candidate = [3]V{
                        candidate_values[0],
                        candidate_values[1],
                        candidate_values[2],
                    };
                    const delta = [3]V{
                        candidate[0] - query[0],
                        candidate[1] - query[1],
                        candidate[2] - query[2],
                    };
                    insertClosestBatch(&distances, &nearest, candidate, delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2]);
                }
            }
        }
        return closestBatchFromVectors(distances, nearest);
    }

    fn findClosestUniformGrid(
        self: *Sampler,
        positions: [density.sample_lanes]density.Position,
        grid_x: i32,
        grid_y: i32,
        grid_z: i32,
    ) ClosestBatch {
        const V = @Vector(density.sample_lanes, i32);
        var query_values: [3][density.sample_lanes]i32 = undefined;
        for (positions, 0..) |position, lane| {
            query_values[0][lane] = position.x;
            query_values[1][lane] = position.y;
            query_values[2][lane] = position.z;
        }
        const query = [3]V{ query_values[0], query_values[1], query_values[2] };
        var nearest: [3][3]V = @splat(@splat(@splat(0)));
        var distances: [3]V = @splat(@splat(std.math.maxInt(i32)));
        for (0..2) |offset_x| for ([_]i32{ -1, 0, 1 }) |offset_y| for (0..2) |offset_z| {
            const value = self.positions[
                self.index(
                    grid_x + @as(i32, @intCast(offset_x)),
                    grid_y + offset_y,
                    grid_z + @as(i32, @intCast(offset_z)),
                )
            ];
            const candidate = [3]V{ @splat(value.x), @splat(value.y), @splat(value.z) };
            const delta = [3]V{
                candidate[0] - query[0],
                candidate[1] - query[1],
                candidate[2] - query[2],
            };
            insertClosestBatch(
                &distances,
                &nearest,
                candidate,
                delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2],
            );
        };
        return closestBatchFromVectors(distances, nearest);
    }

    fn closestBatchFromVectors(
        distances: [3]@Vector(density.sample_lanes, i32),
        nearest: [3][3]@Vector(density.sample_lanes, i32),
    ) ClosestBatch {
        var result: ClosestBatch = undefined;
        for (0..3) |rank| {
            const distance_values: [density.sample_lanes]i32 = distances[rank];
            const x_values: [density.sample_lanes]i32 = nearest[rank][0];
            const y_values: [density.sample_lanes]i32 = nearest[rank][1];
            const z_values: [density.sample_lanes]i32 = nearest[rank][2];
            for (0..density.sample_lanes) |lane| {
                result.distances[lane][rank] = distance_values[lane];
                result.positions[lane][rank] = .{ .x = x_values[lane], .y = y_values[lane], .z = z_values[lane] };
            }
        }
        return result;
    }

    fn insertClosestBatch(
        distances: *[3]@Vector(density.sample_lanes, i32),
        positions: *[3][3]@Vector(density.sample_lanes, i32),
        candidate: [3]@Vector(density.sample_lanes, i32),
        distance: @Vector(density.sample_lanes, i32),
    ) void {
        const replace_third = distances[2] >= distance;
        distances[2] = @select(i32, replace_third, distance, distances[2]);
        inline for (0..3) |axis|
            positions[2][axis] = @select(i32, replace_third, candidate[axis], positions[2][axis]);

        const replace_second = distances[1] >= distance;
        distances[2] = @select(i32, replace_second, distances[1], distances[2]);
        distances[1] = @select(i32, replace_second, distance, distances[1]);
        inline for (0..3) |axis| {
            positions[2][axis] = @select(i32, replace_second, positions[1][axis], positions[2][axis]);
            positions[1][axis] = @select(i32, replace_second, candidate[axis], positions[1][axis]);
        }

        const replace_first = distances[0] >= distance;
        distances[1] = @select(i32, replace_first, distances[0], distances[1]);
        distances[0] = @select(i32, replace_first, distance, distances[0]);
        inline for (0..3) |axis| {
            positions[1][axis] = @select(i32, replace_first, positions[0][axis], positions[1][axis]);
            positions[0][axis] = @select(i32, replace_first, candidate[axis], positions[0][axis]);
        }
    }

    fn prepareBarrierWork(self: *Sampler, positions: [density.sample_lanes]density.Position, closest: ClosestBatch, needs_cells: [density.sample_lanes]bool, result: *[density.sample_lanes]Material, work: *[density.sample_lanes]LaneWork) usize {
        var count: usize = 0;
        for (0..density.sample_lanes) |lane| {
            if (!needs_cells[lane]) continue;
            const position = positions[lane];
            const first_level = self.waterLevel(closest.positions[lane][0]);
            const first_similarity = similarity(closest.distances[lane][0], closest.distances[lane][1]);
            const material_at_position = first_level.materialAt(position.y);
            if (first_similarity <= 0 or
                (material_at_position == .water and
                    defaultFluidLevel(position.y - 1).materialAt(position.y - 1) == .lava))
            {
                result[lane] = material_at_position;
                work[lane].needs_barrier = false;
                continue;
            }
            work[lane] = .{
                .closest_positions = closest.positions[lane],
                .closest_distances = closest.distances[lane],
                .first_level = first_level,
                .first_similarity = first_similarity,
                .material = material_at_position,
                .needs_barrier = true,
            };
            count += 1;
        }
        return count;
    }

    fn sampleBarriers(self: *Sampler, positions: [density.sample_lanes]density.Position, work: [density.sample_lanes]LaneWork, barrier_count: usize) [density.sample_lanes]f64 {
        var barrier_values: [density.sample_lanes]f64 = undefined;
        if (barrier_count == 1) {
            for (0..density.sample_lanes) |lane| {
                if (work[lane].needs_barrier)
                    barrier_values[lane] = self.router.sampleBarrier(positions[lane])
                else
                    barrier_values[lane] = 0;
            }
        } else {
            barrier_values = self.router.sampleBarrier4(positions);
        }
        return barrier_values;
    }

    fn resolveBarrierLane(self: *Sampler, position: density.Position, final_density: f64, barrier: f64, work: LaneWork) Material {
        const second_level = self.waterLevel(work.closest_positions[1]);
        const first = work.first_similarity * calculateBarrier(position.y, barrier, work.first_level, second_level);
        if (final_density + first > 0) return .stone;
        const third_level = self.waterLevel(work.closest_positions[2]);
        const second_similarity = similarity(work.closest_distances[0], work.closest_distances[2]);
        if (second_similarity > 0) {
            const second = work.first_similarity * second_similarity *
                calculateBarrier(position.y, barrier, work.first_level, third_level);
            if (final_density + second > 0) return .stone;
        }
        const third_similarity = similarity(work.closest_distances[1], work.closest_distances[2]);
        if (third_similarity > 0) {
            const third = work.first_similarity * third_similarity *
                calculateBarrier(position.y, barrier, second_level, third_level);
            if (final_density + third > 0) return .stone;
        }
        return work.material;
    }

    fn waterLevel(self: *Sampler, position: density.Position) FluidLevel {
        const grid_x = @divFloor(position.x, 16);
        const grid_y = @divFloor(position.y, 12);
        const grid_z = @divFloor(position.z, 16);
        const cache_index = self.index(grid_x, grid_y, grid_z);
        if (!self.level_initialized[cache_index]) {
            self.levels[cache_index] = self.cachedFluidLevel(
                grid_x,
                grid_y,
                grid_z,
                position,
            );
            self.level_initialized[cache_index] = true;
        }
        return self.levels[cache_index];
    }

    fn cachedFluidLevel(
        self: *Sampler,
        grid_x: i32,
        grid_y: i32,
        grid_z: i32,
        position: density.Position,
    ) FluidLevel {
        const hash = random.staffordMix13(
            @as(u64, @as(u32, @bitCast(grid_x))) *%
                0x9e3779b97f4a7c15 ^
                @as(u64, @as(u32, @bitCast(grid_y))) *%
                    0xbf58476d1ce4e5b9 ^
                @as(u64, @as(u32, @bitCast(grid_z))) *%
                    0x94d049bb133111eb,
        );
        const set_count = fluid_cache_capacity / fluid_cache_ways;
        const first_slot: usize =
            @intCast((hash & (set_count - 1)) * fluid_cache_ways);
        var target_slot =
            first_slot +
            @as(usize, @intCast((hash >> 32) & (fluid_cache_ways - 1)));
        for (self.fluid_cache[first_slot..][0..fluid_cache_ways], first_slot..) |entry, slot| {
            if (entry.occupied and
                entry.grid_x == grid_x and
                entry.grid_y == grid_y and
                entry.grid_z == grid_z)
                return entry.value;
            if (!entry.occupied) target_slot = slot;
        }
        const value = self.calculateFluidLevel(position);
        self.fluid_cache[target_slot] = .{
            .occupied = true,
            .grid_x = grid_x,
            .grid_y = grid_y,
            .grid_z = grid_z,
            .value = value,
        };
        return value;
    }

    fn calculateFluidLevel(self: *Sampler, position: density.Position) FluidLevel {
        const fallback = defaultFluidLevel(position.y);
        const upper_y = position.y + 12;
        const lower_y = position.y - 12;
        var map_y = false;
        var minimum_surface: i32 = std.math.maxInt(i32);
        for (surface_offsets) |offset| {
            const x = position.x + @as(i32, offset[0]) * 16;
            const z = position.z + @as(i32, offset[1]) * 16;
            const surface = self.estimateSurfaceHeight(x, z);
            const surface_plus_eight = surface +% 8;
            const center = offset[0] == 0 and offset[1] == 0;
            if (center and lower_y > surface_plus_eight) return fallback;
            const above_surface = upper_y > surface_plus_eight;
            if (above_surface or center) {
                const nearby = defaultFluidLevel(surface_plus_eight);
                if (nearby.materialAt(surface_plus_eight) != .air) {
                    if (center) map_y = true;
                    if (above_surface) return nearby;
                }
            }
            minimum_surface = @min(minimum_surface, surface);
        }

        const fluid_y = self.fluidBlockY(position, fallback, minimum_surface, map_y);
        return .{
            .max_y = fluid_y,
            .material = self.fluidMaterial(position, fallback, fluid_y),
        };
    }

    fn fluidBlockY(
        self: *Sampler,
        position: density.Position,
        fallback: FluidLevel,
        surface_height: i32,
        map_y: bool,
    ) i32 {
        const deep_dark = self.router.sampleErosion(position) < @as(f64, @floatCast(@as(f32, -0.225))) and
            self.router.sampleDepth(position) > @as(f64, @floatCast(@as(f32, 0.9)));
        var lower: f64 = -1;
        var upper: f64 = -1;
        if (!deep_dark) {
            const distance_to_surface = surface_height +% 8 -% position.y;
            const surface_factor = if (map_y)
                clampedMap(@floatFromInt(distance_to_surface), 0, 64, 1, 0)
            else
                0;
            const floodedness = std.math.clamp(self.router.sampleFluidLevelFloodedness(position), -1, 1);
            const high_threshold = mapRange(surface_factor, 1, 0, -0.3, 0.8);
            const low_threshold = mapRange(surface_factor, 1, 0, -0.8, 0.4);
            lower = floodedness - low_threshold;
            upper = floodedness - high_threshold;
        }
        if (upper > 0) return fallback.max_y;
        if (lower > 0) return self.noiseBasedFluidLevel(position, surface_height);
        return minimum_height_cell;
    }

    fn noiseBasedFluidLevel(self: *Sampler, position: density.Position, surface_height: i32) i32 {
        const grid_y = @divFloor(position.y, 40);
        const local_y = grid_y * 40 + 20;
        const sample = self.router.sampleFluidLevelSpread(.{
            .x = @divFloor(position.x, 16),
            .y = grid_y,
            .z = @divFloor(position.z, 16),
        }) * 10;
        const quantized = @as(i32, @intFromFloat(@floor(sample / 3))) * 3;
        return @min(surface_height, local_y + quantized);
    }

    fn fluidMaterial(
        self: *Sampler,
        position: density.Position,
        fallback: FluidLevel,
        level: i32,
    ) Material {
        if (level <= -10 and level != minimum_height_cell and fallback.material != .lava) {
            const sample = self.router.sampleLava(.{
                .x = @divFloor(position.x, 64),
                .y = @divFloor(position.y, 40),
                .z = @divFloor(position.z, 64),
            });
            if (@abs(sample) > 0.3) return .lava;
        }
        return fallback.material;
    }

    fn estimateSurfaceHeight(self: *Sampler, block_x: i32, block_z: i32) i32 {
        const x = @divFloor(block_x, 4) * 4;
        const z = @divFloor(block_z, 4) * 4;
        const key = @as(u64, @as(u32, @bitCast(x))) |
            (@as(u64, @as(u32, @bitCast(z))) << 32);
        const mixed = random.staffordMix13(key);
        const set_count = height_cache_capacity / height_cache_ways;
        const first_slot: usize = @intCast((mixed & (set_count - 1)) * height_cache_ways);
        var target_slot = first_slot + @as(usize, @intCast((mixed >> 32) & (height_cache_ways - 1)));
        for (self.height_cache[first_slot..][0..height_cache_ways], first_slot..) |entry, slot| {
            if (entry.occupied and entry.key == key) return entry.value;
            if (!entry.occupied) target_slot = slot;
        }
        var y: i32 = density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height;
        const minimum_y = density.ChunkInterpolator.minimum_y;
        const batch_span =
            @as(i32, density.sample_lanes) *
            density.ChunkInterpolator.vertical_cell_size;
        while (y - batch_span +
            density.ChunkInterpolator.vertical_cell_size >= minimum_y)
        {
            var positions: [density.sample_lanes]density.Position = undefined;
            inline for (0..density.sample_lanes) |lane| {
                positions[lane] = .{
                    .x = x,
                    .y = y - @as(i32, lane) *
                        density.ChunkInterpolator.vertical_cell_size,
                    .z = z,
                };
            }
            const samples =
                self.router.sampleInitialDensityWithoutJaggedness4(positions);
            inline for (0..density.sample_lanes) |lane| {
                if (samples[lane] > 0.390625) {
                    const result = positions[lane].y;
                    self.height_cache[target_slot] =
                        .{ .occupied = true, .key = key, .value = result };
                    return result;
                }
            }
            y -= batch_span;
        }
        const result = while (y >= minimum_y) : (y -= density.ChunkInterpolator.vertical_cell_size) {
            if (self.router.sampleInitialDensityWithoutJaggedness(.{ .x = x, .y = y, .z = z }) > 0.390625)
                break y;
        } else std.math.maxInt(i32);
        self.height_cache[target_slot] = .{ .occupied = true, .key = key, .value = result };
        return result;
    }

    fn index(self: *const Sampler, grid_x: i32, grid_y: i32, grid_z: i32) usize {
        const x: usize = @intCast(grid_x - self.start_x);
        const y: usize = @intCast(grid_y - self.start_y);
        const z: usize = @intCast(grid_z - self.start_z);
        std.debug.assert(x < self.size_x and y < self.size_y and z < self.size_z);
        @setRuntimeSafety(false);
        return (y * self.size_z + z) * self.size_x + x;
    }
};

fn defaultFluidLevel(y: i32) FluidLevel {
    return if (y < Sampler.lava_level)
        .{ .max_y = Sampler.lava_level, .material = .lava }
    else
        .{ .max_y = Sampler.sea_level, .material = .water };
}

fn similarity(first: i32, second: i32) f64 {
    return 1 - @as(f64, @floatFromInt(@abs(second - first))) / 25;
}

fn calculateBarrier(y: i32, barrier: f64, first: FluidLevel, second: FluidLevel) f64 {
    const first_material = first.materialAt(y);
    const second_material = second.materialAt(y);
    if ((first_material == .lava and second_material == .water) or
        (first_material == .water and second_material == .lava))
        return 2;
    const level_difference = @abs(first.max_y - second.max_y);
    if (level_difference == 0) return 0;
    const average = 0.5 * @as(f64, @floatFromInt(first.max_y + second.max_y));
    const position = @as(f64, @floatFromInt(y)) + 0.5 - average;
    const half_difference = @as(f64, @floatFromInt(level_difference)) / 2;
    const distance = half_difference - @abs(position);
    const pressure = if (position > 0)
        if (distance > 0) distance / 1.5 else distance / 2.5
    else blk: {
        const shifted = 3 + distance;
        break :blk if (shifted > 0) shifted / 3 else shifted / 10;
    };
    return 2 * (pressure + if (pressure >= -2 and pressure <= 2) barrier else 0);
}

inline fn mapRange(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
    return from_value + (value - from) / (to - from) * (to_value - from_value);
}

inline fn clampedMap(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
    if (value <= from) return from_value;
    if (value >= to) return to_value;
    return mapRange(value, from, to, from_value, to_value);
}

test "aquifer noise-derived levels match Vanilla seed zero references" {
    var router = try density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    var aquifer = try Sampler.init(std.testing.allocator, &router, 0, 7, 4);
    defer aquifer.deinit();
    try std.testing.expectEqual(@as(i32, -103), aquifer.noiseBasedFluidLevel(.{ .x = -100, .y = -100, .z = -100 }, 200));
    try std.testing.expectEqual(@as(i32, -100), aquifer.noiseBasedFluidLevel(.{ .x = -50, .y = -100, .z = 100 }, 200));
    try std.testing.expectEqual(@as(i32, 20), aquifer.noiseBasedFluidLevel(.{ .x = 0, .y = 0, .z = 50 }, 200));
    try std.testing.expectEqual(@as(i32, 57), aquifer.noiseBasedFluidLevel(.{ .x = 100, .y = 50, .z = 0 }, 200));
}

test "aquifer lava selection matches Vanilla seed zero references" {
    var router = try density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    var aquifer = try Sampler.init(std.testing.allocator, &router, 0, 7, 4);
    defer aquifer.deinit();
    const level: FluidLevel = .{ .max_y = 0, .material = .water };
    try std.testing.expectEqual(
        Material.water,
        aquifer.fluidMaterial(.{ .x = -100, .y = -100, .z = -100 }, level, -10),
    );
    try std.testing.expectEqual(
        Material.lava,
        aquifer.fluidMaterial(.{ .x = -100, .y = -100, .z = -50 }, level, -10),
    );
}

test "complete aquifer material selection matches Vanilla seed zero references" {
    var router = try density.Router.init(std.testing.allocator, 0);
    defer router.deinit();
    var aquifer = try Sampler.init(std.testing.allocator, &router, 0, 7, 4);
    defer aquifer.deinit();
    try std.testing.expectEqual(
        Material.stone,
        aquifer.material(.{ .x = 112, .y = -60, .z = 64 }, 0.04861063447117113),
    );
    try std.testing.expectEqual(
        Material.air,
        aquifer.material(.{ .x = 112, .y = 80, .z = 64 }, -0.28931054817132484),
    );
    try std.testing.expectEqual(
        Material.water,
        aquifer.material(.{ .x = 126, .y = 60, .z = 72 }, -0.04738820166968918),
    );
}
