const std = @import("std");
const registry = @import("registry_data");
const block_store = @import("blocks.zig");
const generator_api = @import("generator_api.zig");
const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const preallocated = @import("preallocated");
const terrain = @import("../terrain.zig");
const world_store = @import("worlds.zig");

pub const Overworld = struct {
    pub const id = "minecraft:overworld";

    base_chunk_cache_capacity: usize = 128,
    generator: terrain.Generator = undefined,

    fn initialize(self: *Overworld, allocator: std.mem.Allocator) !void {
        self.generator = try terrain.Generator.init(allocator, 0, self.base_chunk_cache_capacity);
    }

    pub fn generate(
        self: *Overworld,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        try self.generator.reseed(seed);
        return self.generator.generate(chunk.x, chunk.z);
    }

    pub fn advance(
        self: *Overworld,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !?terrain.ChunkShape {
        try self.generator.reseed(seed);
        return self.generator.advance(chunk.x, chunk.z);
    }
};

pub const Flat = struct {
    pub const id = "minecraft:flat";

    surface_y: i16 = 64,
    surface_state: i32 = registry.block_grass_block_default_state,
    underground_state: i32 = registry.block_stone_default_state,
    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn generate(
        self: *Flat,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        _ = seed;
        return terrain.buildFlatChunkShape(
            &self.storage,
            chunk.x,
            chunk.z,
            self.surface_y,
            self.surface_state,
            self.underground_state,
        );
    }
};

pub const Void = struct {
    pub const id = "minecraft:void";

    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn generate(
        self: *Void,
        seed: u64,
        chunk: geometry.ChunkPos,
    ) !terrain.ChunkShape {
        _ = seed;
        return terrain.buildVoidChunkShape(&self.storage, chunk.x, chunk.z);
    }
};

pub fn Registry(comptime configured: anytype) type {
    comptime validate(configured);
    const Algorithms = algorithmStorage(@TypeOf(configured));
    const defaults = algorithmDefaults(Algorithms, configured);
    return struct {
        const Self = @This();
        pub const id = "lightning_rod:world_generation";
        pub const Configuration = Algorithms;
        pub const default_configuration = defaults;

        algorithms: Algorithms = defaults,
        worlds: *world_store.Worlds = undefined,

        pub fn create(
            allocator: std.mem.Allocator,
            worlds: *world_store.Worlds,
            blocks: *block_store.Blocks,
            configuration: Configuration,
        ) !*Self {
            const self = try preallocated.create(Self, allocator);
            self.algorithms = configuration;
            self.worlds = worlds;
            inline for (&self.algorithms) |*algorithm| {
                const Algorithm = @TypeOf(algorithm.*);
                if (@hasDecl(Algorithm, "initialize")) try algorithm.initialize(allocator);
            }
            blocks.bindGenerator(.{
                .context = self,
                .generate_fn = dispatch,
                .advance_fn = dispatchAdvance,
            });
            return self;
        }

        pub fn generatorId(comptime Algorithm: type) identity.GeneratorId {
            return @enumFromInt(algorithmIndex(@TypeOf(configured), Algorithm));
        }

        pub fn stableId(generator: identity.GeneratorId) ?[]const u8 {
            inline for (configured, 0..) |algorithm, index|
                if (@intFromEnum(generator) == index) return @TypeOf(algorithm).id;
            return null;
        }

        fn dispatch(
            context: *anyopaque,
            world: identity.Handle,
            chunk: geometry.ChunkPos,
        ) anyerror!terrain.ChunkShape {
            const self: *Self = @ptrCast(@alignCast(context));
            const description = self.worlds.get(world) orelse
                return error.StaleWorldHandle;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index)
                    return algorithm.generate(description.seed, chunk);
            }
            return error.UnknownWorldGenerator;
        }

        fn dispatchAdvance(
            context: *anyopaque,
            world: identity.Handle,
            chunk: geometry.ChunkPos,
        ) anyerror!?terrain.ChunkShape {
            const self: *Self = @ptrCast(@alignCast(context));
            const description = self.worlds.get(world) orelse
                return error.StaleWorldHandle;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index) {
                    const Algorithm = @TypeOf(algorithm.*);
                    if (@hasDecl(Algorithm, "advance"))
                        return algorithm.advance(description.seed, chunk);
                    return try algorithm.generate(description.seed, chunk);
                }
            }
            return error.UnknownWorldGenerator;
        }
    };
}

fn algorithmStorage(comptime Configured: type) type {
    const fields = @typeInfo(Configured).@"struct".fields;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| types[index] = field.type;
    return std.meta.Tuple(&types);
}

fn algorithmDefaults(comptime Algorithms: type, comptime configured: anytype) Algorithms {
    var result: Algorithms = undefined;
    inline for (@typeInfo(Algorithms).@"struct".fields, 0..) |field, index|
        @field(result, field.name) = configured[index];
    return result;
}

pub const Default = Registry(.{ Overworld{}, Void{}, Flat{} });

fn algorithmIndex(comptime Algorithms: type, comptime Algorithm: type) usize {
    inline for (@typeInfo(Algorithms).@"struct".fields, 0..) |field, index|
        if (field.type == Algorithm) return index;
    @compileError("world generator is absent from the configured registry: " ++ @typeName(Algorithm));
}

fn validate(comptime configured: anytype) void {
    if (configured.len == 0) @compileError("a world-generation registry cannot be empty");
    if (configured.len > std.math.maxInt(u16)) @compileError("too many world generators");
    inline for (configured, 0..) |algorithm, index| {
        const Algorithm = @TypeOf(algorithm);
        if (!@hasDecl(Algorithm, "id") or Algorithm.id.len == 0)
            @compileError("world generator must declare a stable non-empty id");
        if (!@hasDecl(Algorithm, "generate"))
            @compileError(Algorithm.id ++ " must implement generate");
        inline for (0..index) |previous_index|
            if (std.mem.eql(u8, Algorithm.id, @TypeOf(configured[previous_index]).id))
                @compileError("duplicate world generator id: " ++ Algorithm.id);
    }
}

test "generator ids follow the configured tuple" {
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(Default.generatorId(Overworld)));
    try std.testing.expectEqual(@as(u16, 1), @intFromEnum(Default.generatorId(Void)));
    try std.testing.expectEqualStrings("minecraft:flat", Default.stableId(Default.generatorId(Flat)).?);
}
