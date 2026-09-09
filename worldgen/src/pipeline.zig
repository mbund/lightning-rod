const std = @import("std");
const aquifer = @import("aquifer.zig");
const chunk = @import("chunk.zig");
const generated_state = @import("generated_state.zig");

pub const Stages = struct {
    density: bool = true,
    surface: bool = true,
    carvers: bool = true,
    features: bool = true,
    structures: bool = false,

    pub fn validate(comptime self: Stages) void {
        if (self.surface and !self.density)
            @compileError("surface generation requires density generation");
        if (self.carvers and !self.surface)
            @compileError("carvers require surface generation");
        if (self.features and !self.surface)
            @compileError("features require surface generation");
    }
};

pub fn Pipeline(comptime stages: Stages) type {
    stages.validate();
    return struct {
        const Self = @This();
        pub const enabled = stages;

        allocator: std.mem.Allocator,
        generator: if (stages.density) chunk.Generator else void,
        materials: if (stages.density) []aquifer.Material else void,

        pub fn init(allocator: std.mem.Allocator, seed: u64) !Self {
            if (!stages.density) return .{
                .allocator = allocator,
                .generator = {},
                .materials = {},
            };
            var generator = if (stages.features)
                try chunk.Generator.init(allocator, seed)
            else
                try chunk.Generator.initForRegion(allocator, seed);
            errdefer generator.deinit();
            const materials = try allocator.alloc(aquifer.Material, chunk.block_count);
            return .{
                .allocator = allocator,
                .generator = generator,
                .materials = materials,
            };
        }

        pub fn deinit(self: *Self) void {
            if (stages.density) {
                self.allocator.free(self.materials);
                self.generator.deinit();
            }
            self.* = undefined;
        }

        pub fn reseed(self: *Self, seed: u64) !void {
            if (stages.density) try self.generator.reseed(seed);
        }

        pub fn generate(self: *Self, chunk_x: i32, chunk_z: i32, output: []generated_state.GeneratedState) !void {
            std.debug.assert(output.len == chunk.block_count);
            if (!stages.density) return;
            try self.generator.fillBaseMaterials(chunk_x, chunk_z, self.materials);
            if (stages.surface) {
                try self.generator.applySurface(chunk_x, chunk_z, self.materials, output);
            } else {
                for (self.materials, output) |material, *state|
                    state.* = generated_state.GeneratedState.fromBase(material);
            }
            if (stages.carvers) try self.generator.applyCarvers(chunk_x, chunk_z, output);
            if (stages.features) try self.generator.applyFeatures(chunk_x, chunk_z, output);
        }
    };
}

pub const Complete = Pipeline(.{});
pub const Terrain = Pipeline(.{ .carvers = false, .features = false, .structures = false });
pub const StructurePlacement = Pipeline(.{
    .density = false,
    .surface = false,
    .carvers = false,
    .features = false,
});

pub fn Area(comptime stages: Stages, comptime side: usize) type {
    stages.validate();
    if (side == 0 or side > 64) @compileError("area side must be between 1 and 64 chunks");
    const border = if (stages.features) 2 else 0;
    const stored_side = side + border * 2;
    const stored_chunks = stored_side * stored_side;
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        generator: chunk.Generator,
        materials: []aquifer.Material,
        states: []generated_state.GeneratedState,

        pub fn init(allocator: std.mem.Allocator, seed: u64) !Self {
            var generator = try chunk.Generator.initForRegion(allocator, seed);
            errdefer generator.deinit();
            const materials = try allocator.alloc(aquifer.Material, chunk.block_count);
            errdefer allocator.free(materials);
            const states = try allocator.alloc(generated_state.GeneratedState, stored_chunks * chunk.block_count);
            return .{ .allocator = allocator, .generator = generator, .materials = materials, .states = states };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.states);
            self.allocator.free(self.materials);
            self.generator.deinit();
            self.* = undefined;
        }

        pub fn reseed(self: *Self, seed: u64) !void {
            try self.generator.reseed(seed);
        }

        pub fn generate(self: *Self, minimum_x: i32, minimum_z: i32, output: []generated_state.GeneratedState) !void {
            std.debug.assert(output.len == side * side * chunk.block_count);
            try self.generateTerrain(minimum_x, minimum_z);
            if (stages.features) try self.generateFeatures(minimum_x, minimum_z);
            for (0..side) |z| for (0..side) |x| {
                const source = self.chunkAt(x + border, z + border);
                const first = (z * side + x) * chunk.block_count;
                @memcpy(output[first..][0..chunk.block_count], source);
            };
        }

        fn generateTerrain(self: *Self, minimum_x: i32, minimum_z: i32) !void {
            for (0..stored_side) |z| for (0..stored_side) |x| {
                const chunk_x = minimum_x + @as(i32, @intCast(x)) - border;
                const chunk_z = minimum_z + @as(i32, @intCast(z)) - border;
                const output = self.chunkAt(x, z);
                try self.generator.fillBaseMaterials(chunk_x, chunk_z, self.materials);
                if (stages.surface) {
                    try self.generator.applySurface(chunk_x, chunk_z, self.materials, output);
                } else for (self.materials, output) |material, *state| {
                    state.* = generated_state.GeneratedState.fromBase(material);
                }
                if (stages.carvers) try self.generator.applyCarvers(chunk_x, chunk_z, output);
            };
        }

        fn generateFeatures(self: *Self, minimum_x: i32, minimum_z: i32) !void {
            for (1..stored_side - 1) |z| for (1..stored_side - 1) |x| {
                var region: @import("feature.zig").Region = .{
                    .center_chunk_x = minimum_x + @as(i32, @intCast(x)) - border,
                    .center_chunk_z = minimum_z + @as(i32, @intCast(z)) - border,
                    .chunks = undefined,
                    .biome_cache = &self.generator.biome_cache,
                };
                for (0..3) |rz| {
                    for (0..3) |rx|
                        region.chunks[rz * 3 + rx] = self.chunkAt(x + rx - 1, z + rz - 1);
                }
                try self.generator.applyFeaturesToRegion(region.center_chunk_x, region.center_chunk_z, &region);
            };
        }

        fn chunkAt(self: *Self, x: usize, z: usize) []generated_state.GeneratedState {
            const first = (z * stored_side + x) * chunk.block_count;
            return self.states[first..][0..chunk.block_count];
        }
    };
}

test "compile-time pipelines omit unused generator state" {
    try std.testing.expect(@sizeOf(StructurePlacement) < @sizeOf(Complete));
}

test "batched density area matches independent chunks" {
    const allocator = std.testing.allocator;
    const Density = Pipeline(.{ .surface = false, .carvers = false, .features = false, .structures = false });
    const DensityArea = Area(.{ .surface = false, .carvers = false, .features = false, .structures = false }, 2);
    var independent = try Density.init(allocator, 42);
    defer independent.deinit();
    var area = try DensityArea.init(allocator, 42);
    defer area.deinit();
    const expected = try allocator.alloc(generated_state.GeneratedState, chunk.block_count);
    defer allocator.free(expected);
    const actual = try allocator.alloc(generated_state.GeneratedState, chunk.block_count * 4);
    defer allocator.free(actual);
    try area.generate(-1, 3, actual);
    for (0..2) |z| for (0..2) |x| {
        try independent.generate(-1 + @as(i32, @intCast(x)), 3 + @as(i32, @intCast(z)), expected);
        const first = (z * 2 + x) * chunk.block_count;
        try std.testing.expectEqualSlices(generated_state.GeneratedState, expected, actual[first..][0..chunk.block_count]);
    };
}
