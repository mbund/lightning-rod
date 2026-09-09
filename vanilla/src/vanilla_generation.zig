const std = @import("std");
const lightning_rod = @import("lightning_rod");
const terrain = @import("vanilla_terrain.zig");

pub const Overworld = struct {
    pub const id = "minecraft:overworld";
    pub const Configuration = struct {
        batch_side: usize = 3,
        base_chunks_per_slice: usize = 1,
        feature_steps_per_slice: usize = 128,
    };
    pub const default_configuration: Configuration = .{};

    batch_side: usize = 3,
    base_chunks_per_slice: usize = 1,
    feature_steps_per_slice: usize = 128,
    generator: terrain.Generator = undefined,

    pub fn configured(configuration: Configuration) Overworld {
        return .{
            .batch_side = configuration.batch_side,
            .base_chunks_per_slice = configuration.base_chunks_per_slice,
            .feature_steps_per_slice = configuration.feature_steps_per_slice,
        };
    }

    pub fn initialize(self: *Overworld, allocator: std.mem.Allocator) !void {
        if (self.base_chunks_per_slice == 0 or self.feature_steps_per_slice == 0)
            return error.InvalidTerrainSlice;
        try self.generator.initInto(allocator, 0, self.batch_side);
    }

    pub fn generate(self: *Overworld, seed: u64, chunk: lightning_rod.geometry.ChunkPos) !lightning_rod.terrain.ChunkShape {
        try self.generator.reseed(seed);
        return try self.generator.generate(chunk.x, chunk.z);
    }

    pub fn advance(
        self: *Overworld,
        seed: u64,
        chunk: lightning_rod.geometry.ChunkPos,
        sink: lightning_rod.generator_api.Sink,
    ) !lightning_rod.generator_api.Advance {
        try self.generator.reseed(seed);
        return if (try self.generator.advanceSlice(
            chunk.x,
            chunk.z,
            self.base_chunks_per_slice,
            self.feature_steps_per_slice,
            sink,
        )) .complete else .pending;
    }
};

fn VanillaDimension(comptime Dimension: type, comptime stable_id: []const u8) type {
    const Biome = Dimension.Generator.Biome;
    const biome_count = @typeInfo(Biome).@"enum".fields.len;
    return struct {
        pub const id = stable_id;
        pub const Configuration = struct { enabled: bool = true };
        pub const default_configuration: Configuration = .{};

        enabled: bool = true,
        area: Dimension.Area = undefined,
        states: []Dimension.Generator.BlockType = &.{},
        state_ids: []i32 = &.{},
        biome_ids: [biome_count]u8 = undefined,
        storage: [lightning_rod.terrain.chunk_storage_capacity]u8 = undefined,

        pub fn configured(configuration: Configuration) @This() {
            return .{ .enabled = configuration.enabled };
        }

        pub fn initialize(self: *@This(), allocator: std.mem.Allocator) !void {
            if (!self.enabled) return;
            self.area = try Dimension.Area.init(allocator, 0, 1);
            self.states = try lightning_rod.preallocated.alloc(Dimension.Generator.BlockType, allocator, Dimension.block_count);
            self.state_ids = try lightning_rod.preallocated.alloc(i32, allocator, Dimension.state_count);
            for (self.state_ids, 0..) |*state, index|
                state.* = lightning_rod.registry_data.blockStateId(Dimension.stateName(index)) orelse return error.UnknownGeneratedBlockState;
            inline for (@typeInfo(Biome).@"enum".fields) |field| {
                const biome: Biome = @enumFromInt(field.value);
                self.biome_ids[field.value] = terrain.biomeId(biome.canonicalName()) orelse return error.UnknownGeneratedBiome;
            }
        }

        pub fn generate(self: *@This(), seed: u64, chunk: lightning_rod.geometry.ChunkPos) !lightning_rod.terrain.ChunkShape {
            if (!self.enabled)
                return try lightning_rod.terrain.buildVoidChunkShape(
                    &self.storage,
                    chunk.x,
                    chunk.z,
                );
            try self.area.generator.reseed(seed);
            try self.area.generate(chunk.x, chunk.z, 1, self.states);
            return try terrain.buildDimensionChunkShape(
                Dimension,
                &self.area.generator,
                &self.storage,
                self.states,
                self.state_ids,
                &self.biome_ids,
                chunk.x,
                chunk.z,
            );
        }
    };
}

pub const Nether = VanillaDimension(terrain.vanilla_worldgen.nether, "minecraft:nether");
pub const End = VanillaDimension(terrain.vanilla_worldgen.end, "minecraft:end");

pub const Default = lightning_rod.world_generation.Registry(.{
    Overworld{},
    Nether{},
    End{},
    lightning_rod.world_generation.Void{},
    lightning_rod.world_generation.Flat{},
});

test "Overworld adapter initializes and incrementally completes its first chunk" {
    var overworld = Overworld{};
    try overworld.initialize(std.testing.allocator);
    defer overworld.generator.deinit();
    try overworld.generator.reseed(0x6d_62_75_6e_64_00_00_01);
    for (0..2_048) |_| {
        const shape = (try overworld.generator.advance(0, 0)) orelse continue;
        try std.testing.expectEqual(@as(i32, 0), shape.chunk_x);
        try std.testing.expectEqual(@as(i32, 0), shape.chunk_z);
        return;
    }
    return error.TerrainGenerationDidNotComplete;
}
