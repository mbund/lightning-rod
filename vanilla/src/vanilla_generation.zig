const std = @import("std");
const lightning_rod = @import("lightning_rod");
const terrain = @import("vanilla_terrain");

pub const Overworld = struct {
    pub const id = "minecraft:overworld";
    pub const transient_workspace_bytes = 24 * 1024 * 1024;
    pub const Configuration = struct {};
    pub const default_configuration: Configuration = .{};

    generator: terrain.Generator = undefined,

    pub fn configured(_: Configuration) Overworld {
        return .{};
    }

    pub fn initialize(self: *Overworld, allocator: std.mem.Allocator) !void {
        try self.generator.initInto(allocator, 0, 5);
    }

    pub fn deinitialize(self: *Overworld) void {
        self.generator.deinit();
    }

    pub fn generate(self: *Overworld, seed: u64, chunk: lightning_rod.geometry.ChunkPos) !lightning_rod.terrain.ChunkShape {
        try self.generator.reseed(seed);
        return try self.generator.generate(chunk.x, chunk.z);
    }

    pub fn prepare(self: *Overworld, seed: u64) !void {
        try self.generator.reseed(seed);
    }

    pub fn stageName(self: *const Overworld) []const u8 {
        return @tagName(self.generator.generationStage());
    }

    pub fn step(self: *Overworld, seed: u64, chunk: lightning_rod.geometry.ChunkPos) !?lightning_rod.terrain.ChunkShape {
        try self.generator.reseed(seed);
        return self.generator.advance(chunk.x, chunk.z);
    }

};

fn VanillaDimension(comptime Dimension: type, comptime stable_id: []const u8) type {
    const Biome = Dimension.Generator.Biome;
    const biome_count = @typeInfo(Biome).@"enum".fields.len;
    return struct {
        pub const id = stable_id;
        pub const transient_workspace_bytes = 16 * 1024 * 1024;
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

        pub fn deinitialize(self: *@This()) void {
            if (self.enabled) self.area.deinit();
            self.states = &.{};
            self.state_ids = &.{};
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

test "Overworld adapter fits its production workspace with startup and local batches" {
    var storage: [Overworld.transient_workspace_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var overworld = Overworld{};
    try overworld.initialize(fixed.allocator());
    defer overworld.generator.deinit();
    try overworld.prepare(0x6d_62_75_6e_64_00_00_01);
    var startup_emitted: usize = 0;
    for (0..32_768) |_| {
        const shape = (try overworld.step(0x6d_62_75_6e_64_00_00_01, .{ .x = 0, .z = 0 })) orelse continue;
        try std.testing.expectEqual(@as(i32, 0), shape.chunk_x);
        try std.testing.expectEqual(@as(i32, 0), shape.chunk_z);
        startup_emitted += 1;
        if (startup_emitted == 1) break;
    }
    try std.testing.expectEqual(@as(usize, 1), startup_emitted);

    var emitted: usize = 0;
    for (0..32_768) |_| {
        const shape = (try overworld.step(0x6d_62_75_6e_64_00_00_01, .{ .x = 1, .z = 0 })) orelse continue;
        try std.testing.expect(@abs(shape.chunk_x) <= 2);
        try std.testing.expect(@abs(shape.chunk_z) <= 2);
        emitted += 1;
        if (shape.chunk_x == 1 and shape.chunk_z == 0) {
            try std.testing.expectEqual(@as(usize, 25), emitted);
            try std.testing.expect(fixed.end_index <= storage.len);
            return;
        }
    }
    return error.TerrainGenerationDidNotComplete;
}
