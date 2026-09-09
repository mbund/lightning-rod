const std = @import("std");
const biome_access = @import("biome_access.zig");
const minecraft = @import("minecraft_registry");

pub const width = 16;
pub const Block = union(enum) {
    solid,
    air,
    cave_air,
    fluid,
    surface: u16,
    feature: minecraft.State,
};

pub const NoCarvers = struct {
    pub const enabled = false;
};

pub const NoFeatures = struct {
    pub const enabled = false;
    pub const region_side = 1;
};

pub fn Dimension(
    comptime density: type,
    comptime data: type,
    comptime surface: type,
    comptime biomes: type,
    comptime carvers: type,
    comptime features: type,
    comptime world_height: usize,
) type {
    return struct {
        pub const minimum_y = density.ChunkInterpolator.minimum_y;
        pub const terrain_height = density.ChunkInterpolator.height;
        pub const height = world_height;
        pub const block_count = width * width * height;
        const terrain_block_count = width * width * terrain_height;
        pub const default_block = data.default_block;
        pub const default_fluid = data.default_fluid;
        pub const Surface = surface;
        pub const state_count = 4 + surface.state_count;

        pub fn canonicalName(block: Block) []const u8 {
            return switch (block) {
                .solid => default_block,
                .air => "minecraft:air",
                .cave_air => "minecraft:cave_air",
                .fluid => default_fluid,
                .surface => |state| surface.stateName(state),
                .feature => |state| state.canonicalName(),
            };
        }

        pub fn stateCode(block: Block) usize {
            return switch (block) {
                .solid => 0,
                .air => 1,
                .cave_air => 2,
                .fluid => 3,
                .surface => |state| 4 + state,
                .feature => unreachable,
            };
        }

        pub fn stateName(code: usize) []const u8 {
            std.debug.assert(code < state_count);
            return switch (code) {
                0 => default_block,
                1 => "minecraft:air",
                2 => "minecraft:cave_air",
                3 => default_fluid,
                else => surface.stateName(@intCast(code - 4)),
            };
        }

        pub const Generator = struct {
            pub const BlockType = Block;
            pub const Biome = @TypeOf(biomes.at(@as(*density.Router, undefined), 0, 0, 0));
            allocator: std.mem.Allocator,
            world_seed: u64,
            biome_seed: i64,
            router: *density.Router,
            interpolation: density.ChunkInterpolator,
            structure_interpolation: if (features.enabled) density.ChunkInterpolator else void,
            surfaces: surface.Sampler,
            carver_mask: if (carvers.enabled) []bool else void,
            feature_blocks: if (features.enabled) []Block else void,
            feature_scratch: if (features.enabled) *features.Scratch else void,

            pub fn init(allocator: std.mem.Allocator, seed: u64) !Generator {
                const router = try allocator.create(density.Router);
                errdefer allocator.destroy(router);
                router.* = try density.Router.init(allocator, seed);
                errdefer router.deinit();
                var interpolation = try density.ChunkInterpolator.initFinal(
                    allocator,
                    router,
                    256,
                );
                errdefer interpolation.deinit();
                var structure_interpolation = if (features.enabled)
                    try density.ChunkInterpolator.initFinal(allocator, router, 256)
                else {};
                errdefer if (features.enabled) structure_interpolation.deinit();
                var surfaces = try surface.Sampler.init(allocator, seed);
                errdefer surfaces.deinit();
                const carver_mask = if (carvers.enabled)
                    try allocator.alloc(bool, terrain_block_count)
                else {};
                errdefer if (carvers.enabled) allocator.free(carver_mask);
                const feature_blocks = if (features.enabled)
                    try allocator.alloc(Block, block_count * features.region_side * features.region_side)
                else {};
                errdefer if (features.enabled) allocator.free(feature_blocks);
                const feature_scratch = if (features.enabled)
                    try allocator.create(features.Scratch)
                else {};
                return .{
                    .allocator = allocator,
                    .world_seed = seed,
                    .biome_seed = biome_access.mixerSeed(seed),
                    .router = router,
                    .interpolation = interpolation,
                    .structure_interpolation = structure_interpolation,
                    .surfaces = surfaces,
                    .carver_mask = carver_mask,
                    .feature_blocks = feature_blocks,
                    .feature_scratch = feature_scratch,
                };
            }

            pub fn deinit(self: *Generator) void {
                if (features.enabled) self.allocator.destroy(self.feature_scratch);
                if (features.enabled) self.allocator.free(self.feature_blocks);
                if (carvers.enabled) self.allocator.free(self.carver_mask);
                self.surfaces.deinit();
                if (features.enabled) self.structure_interpolation.deinit();
                self.interpolation.deinit();
                self.router.deinit();
                self.allocator.destroy(self.router);
                self.* = undefined;
            }

            pub fn reseed(self: *Generator, seed: u64) !void {
                if (self.world_seed == seed) return;
                try self.router.reseed(seed);
                self.interpolation.reseed(self.router);
                if (features.enabled) self.structure_interpolation.reseed(self.router);
                self.surfaces.reseed(seed);
                self.world_seed = seed;
                self.biome_seed = biome_access.mixerSeed(seed);
            }

            pub fn generate(self: *Generator, chunk_x: i32, chunk_z: i32, output: []Block) !void {
                try self.generateSurface(chunk_x, chunk_z, output);
                if (carvers.enabled)
                    carvers.apply(self.world_seed, chunk_x, chunk_z, output[0..terrain_block_count], self.carver_mask);
            }

            pub fn generateFeatures(self: *Generator, chunk_x: i32, chunk_z: i32, output: []Block) !void {
                if (!features.enabled) return self.generate(chunk_x, chunk_z, output);
                for (0..features.region_side) |region_z| for (0..features.region_side) |region_x| {
                    const offset_x = @as(i32, @intCast(region_x)) - 1;
                    const offset_z = @as(i32, @intCast(region_z)) - 1;
                    const first = (region_z * features.region_side + region_x) * block_count;
                    try self.generate(chunk_x + offset_x, chunk_z + offset_z, self.feature_blocks[first..][0..block_count]);
                };
                if (@hasDecl(features, "applyStructures")) {
                    features.applyStructures(self, self.world_seed, chunk_x, chunk_z, self.feature_scratch, self.feature_blocks);
                    features.applyDecorations(self, self.world_seed, chunk_x, chunk_z, self.feature_scratch, self.feature_blocks);
                } else {
                    features.apply(self, self.world_seed, chunk_x, chunk_z, self.feature_scratch, self.feature_blocks);
                }
                const center = (features.region_side * features.region_side / 2) * block_count;
                @memcpy(output, self.feature_blocks[center..][0..block_count]);
            }

            pub fn generateSurface(self: *Generator, chunk_x: i32, chunk_z: i32, output: []Block) !void {
                try self.generateDensity(chunk_x, chunk_z, output);
                self.applySurface(chunk_x, chunk_z, output);
            }

            pub fn generateDensity(self: *Generator, chunk_x: i32, chunk_z: i32, output: []Block) !void {
                if (output.len != block_count) return error.InvalidChunkOutputSize;
                @memset(output, .air);
                if (features.enabled and @hasDecl(features, "prepareDensity"))
                    features.prepareDensity(self, self.world_seed, chunk_x, chunk_z, self.feature_scratch);
                self.interpolation.prepare(chunk_x, chunk_z);
                const first_x = chunk_x * width;
                const first_z = chunk_z * width;
                for (0..terrain_height) |local_y| {
                    const y = minimum_y + @as(i32, @intCast(local_y));
                    for (0..width) |local_x| {
                        const x = first_x + @as(i32, @intCast(local_x));
                        var local_z: usize = 0;
                        while (local_z < width) : (local_z += density.vector_lanes) {
                            std.debug.assert(local_z + density.vector_lanes <= width);
                            std.debug.assert(@mod(local_z, density.ChunkInterpolator.horizontal_cell_size) + density.vector_lanes <= density.ChunkInterpolator.horizontal_cell_size);
                            var positions: [density.vector_lanes]density.Position = undefined;
                            inline for (0..density.vector_lanes) |lane| positions[lane] = .{
                                .x = x,
                                .y = y,
                                .z = first_z + @as(i32, @intCast(local_z + lane)),
                            };
                            var values: [density.vector_lanes]f64 = self.interpolation.sampleFinal4(positions);
                            if (features.enabled and @hasDecl(features, "adjustDensity"))
                                features.adjustDensity(self.feature_scratch, positions, &values);
                            inline for (0..density.vector_lanes) |lane| {
                                output[blockIndex(local_x, local_y, local_z + lane)] = if (values[lane] > 0)
                                    .solid
                                else if (y < data.sea_level)
                                    .fluid
                                else
                                    .air;
                            }
                        }
                    }
                }
            }

            pub fn generateColumnWithoutStructureAdaptation(
                self: *Generator,
                x: i32,
                z: i32,
                output: []Block,
            ) !void {
                if (output.len != terrain_height) return error.InvalidColumnOutputSize;
                if (!features.enabled) return error.StructureQueriesUnavailable;
                self.structure_interpolation.prepare(@divFloor(x, width), @divFloor(z, width));
                for (output, 0..) |*block, local_y| {
                    const y = minimum_y + @as(i32, @intCast(local_y));
                    const value = self.structure_interpolation.sampleFinal(.{ .x = x, .y = y, .z = z });
                    block.* = if (value > 0)
                        .solid
                    else if (y < data.sea_level)
                        .fluid
                    else
                        .air;
                }
            }

            pub fn biomeAtQuart(self: *Generator, quart_x: i32, quart_y: i32, quart_z: i32) @TypeOf(biomes.at(self.router, 0, 0, 0)) {
                return biomes.at(self.router, quart_x * 4, quart_y * 4, quart_z * 4);
            }

            pub fn biomeAtBlock(self: *Generator, x: i32, y: i32, z: i32) @TypeOf(biomes.at(self.router, 0, 0, 0)) {
                const quart = biome_access.quartPositionFor(
                    self.biome_seed,
                    x,
                    y,
                    z,
                    minimum_y,
                    height,
                );
                return biomes.at(self.router, quart.x * 4, quart.y * 4, quart.z * 4);
            }

            fn applySurface(self: *Generator, chunk_x: i32, chunk_z: i32, output: []Block) void {
                const first_x = chunk_x * width;
                const first_z = chunk_z * width;
                for (0..width) |local_z| for (0..width) |local_x| {
                    const x = first_x + @as(i32, @intCast(local_x));
                    const z = first_z + @as(i32, @intCast(local_z));
                    const preliminary_surface = density.estimateSurfaceHeight(self.router, x, z);
                    self.applySurfaceColumn(output, local_x, local_z, x, z, preliminary_surface);
                };
            }

            fn applySurfaceColumn(self: *Generator, output: []Block, local_x: usize, local_z: usize, x: i32, z: i32, preliminary_surface: i32) void {
                var below: [terrain_height]u16 = undefined;
                var consecutive: u16 = 0;
                for (0..terrain_height) |local_y| {
                    const block = output[blockIndex(local_x, local_y, local_z)];
                    consecutive = switch (block) {
                        .solid => consecutive + 1,
                        else => 0,
                    };
                    below[local_y] = consecutive;
                }
                const run_depth = self.surfaces.runDepth(x, z);
                const surface_noise = self.surfaces.surfaceNoise(x, z);
                const secondary_depth = self.surfaces.secondaryDepth(x, z);
                var stone_depth_above: i32 = 0;
                var fluid_height: i32 = std.math.minInt(i32);
                var local_y: usize = terrain_height;
                while (local_y > 0) {
                    local_y -= 1;
                    const index = blockIndex(local_x, local_y, local_z);
                    switch (output[index]) {
                        .air, .cave_air => {
                            stone_depth_above = 0;
                            fluid_height = std.math.minInt(i32);
                        },
                        .fluid => if (comptime std.mem.eql(u8, default_fluid, "minecraft:air")) {
                            stone_depth_above = 0;
                            fluid_height = std.math.minInt(i32);
                        } else if (fluid_height == std.math.minInt(i32)) {
                            fluid_height = minimum_y + @as(i32, @intCast(local_y)) + 1;
                        },
                        .solid, .surface, .feature => {
                            stone_depth_above += 1;
                            const y = minimum_y + @as(i32, @intCast(local_y));
                            const biome_mask = self.biomeMaskAt(x, y, z);
                            const context: surface.Context = .{
                                .position = .{ .x = x, .y = y, .z = z },
                                .biome_mask = biome_mask,
                                .run_depth = run_depth,
                                .surface_noise = surface_noise,
                                .secondary_depth = secondary_depth,
                                .fluid_height = fluid_height,
                                .stone_depth_above = stone_depth_above,
                                .stone_depth_below = below[local_y],
                                .preliminary_surface = preliminary_surface,
                                .temperature = 0,
                                .frozen = false,
                                .steep = false,
                            };
                            if (self.surfaces.apply(&context)) |replacement| switch (replacement) {
                                .state => |state| output[index] = .{ .surface = state },
                                .badlands => unreachable,
                            };
                        },
                    }
                }
            }

            fn biomeMaskAt(self: *Generator, x: i32, y: i32, z: i32) u32 {
                const quart = biome_access.quartPositionFor(
                    self.biome_seed,
                    x,
                    y,
                    z,
                    minimum_y,
                    height,
                );
                return surface.biomeMask(biomes.at(
                    self.router,
                    quart.x * 4,
                    quart.y * 4,
                    quart.z * 4,
                ).canonicalName());
            }
        };

        pub const Area = struct {
            allocator: std.mem.Allocator,
            generator: Generator,
            states: []Block,
            maximum_side: u8,

            pub fn init(allocator: std.mem.Allocator, seed: u64, maximum_side: u8) !Area {
                if (maximum_side == 0 or maximum_side > 64) return error.InvalidAreaSide;
                var generator = try Generator.init(allocator, seed);
                errdefer generator.deinit();
                const stored_side = @as(usize, maximum_side) + 4;
                const states = try allocator.alloc(Block, stored_side * stored_side * block_count);
                return .{
                    .allocator = allocator,
                    .generator = generator,
                    .states = states,
                    .maximum_side = maximum_side,
                };
            }

            pub fn deinit(self: *Area) void {
                self.allocator.free(self.states);
                self.generator.deinit();
                self.* = undefined;
            }

            pub fn generate(self: *Area, minimum_x: i32, minimum_z: i32, side: u8, output: []Block) !void {
                if (side == 0 or side > self.maximum_side) return error.InvalidAreaSide;
                if (output.len != @as(usize, side) * side * block_count) return error.InvalidAreaOutputSize;
                const stored_side = @as(usize, side) + 4;
                try self.generateTerrain(minimum_x, minimum_z, stored_side);
                if (features.enabled) self.generateFeatureSources(minimum_x, minimum_z, stored_side);
                for (0..side) |z| for (0..side) |x| {
                    const source = chunkSlice(self.states, stored_side, x + 2, z + 2);
                    const first = (z * side + x) * block_count;
                    @memcpy(output[first..][0..block_count], source);
                };
            }

            fn generateTerrain(self: *Area, minimum_x: i32, minimum_z: i32, stored_side: usize) !void {
                for (0..stored_side) |z| for (0..stored_side) |x| {
                    const chunk_x = minimum_x + @as(i32, @intCast(x)) - 2;
                    const chunk_z = minimum_z + @as(i32, @intCast(z)) - 2;
                    try self.generator.generate(chunk_x, chunk_z, chunkSlice(self.states, stored_side, x, z));
                };
            }

            fn generateFeatureSources(self: *Area, minimum_x: i32, minimum_z: i32, stored_side: usize) void {
                std.debug.assert(features.region_side == 3);
                for (1..stored_side - 1) |z| for (1..stored_side - 1) |x| {
                    copyFeatureRegion(&self.generator, self.states, stored_side, x, z, false);
                    const chunk_x = minimum_x + @as(i32, @intCast(x)) - 2;
                    const chunk_z = minimum_z + @as(i32, @intCast(z)) - 2;
                    if (@hasDecl(features, "applyStructures")) {
                        features.applyStructures(&self.generator, self.generator.world_seed, chunk_x, chunk_z, self.generator.feature_scratch, self.generator.feature_blocks);
                        features.applyDecorations(&self.generator, self.generator.world_seed, chunk_x, chunk_z, self.generator.feature_scratch, self.generator.feature_blocks);
                    } else {
                        features.apply(&self.generator, self.generator.world_seed, chunk_x, chunk_z, self.generator.feature_scratch, self.generator.feature_blocks);
                    }
                    copyFeatureRegion(&self.generator, self.states, stored_side, x, z, true);
                };
            }
        };

        fn copyFeatureRegion(generator: *Generator, states: []Block, stored_side: usize, center_x: usize, center_z: usize, write_back: bool) void {
            for (0..3) |z| for (0..3) |x| {
                const stored = chunkSlice(states, stored_side, center_x + x - 1, center_z + z - 1);
                const first = (z * 3 + x) * block_count;
                const staged = generator.feature_blocks[first..][0..block_count];
                if (write_back) @memcpy(stored, staged) else @memcpy(staged, stored);
            };
        }

        fn chunkSlice(states: []Block, side: usize, x: usize, z: usize) []Block {
            std.debug.assert(x < side and z < side);
            const first = (z * side + x) * block_count;
            return states[first..][0..block_count];
        }

        pub inline fn blockIndex(local_x: usize, local_y: usize, local_z: usize) usize {
            std.debug.assert(local_x < width);
            std.debug.assert(local_y < height);
            std.debug.assert(local_z < width);
            return local_y * width * width + local_z * width + local_x;
        }
    };
}
