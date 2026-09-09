const std = @import("std");
const registry = @import("registry_data");
const block_store = @import("blocks.zig");
const generator_api = @import("generator_api.zig");
const geometry = @import("geometry.zig");
const identity = @import("identity.zig");
const preallocated = @import("preallocated");
const terrain = @import("../terrain.zig");
const world_store = @import("worlds.zig");

pub const Flat = struct {
    pub const id = "minecraft:flat";
    pub const Configuration = struct {
        surface_y: i16 = 64,
        surface_state: i32 = registry.block_grass_block_default_state,
        underground_state: i32 = registry.block_stone_default_state,
    };
    pub const default_configuration: Configuration = .{};

    surface_y: i16 = 64,
    surface_state: i32 = registry.block_grass_block_default_state,
    underground_state: i32 = registry.block_stone_default_state,
    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn configured(configuration: Configuration) Flat {
        return .{
            .surface_y = configuration.surface_y,
            .surface_state = configuration.surface_state,
            .underground_state = configuration.underground_state,
        };
    }

    pub fn initialize(_: *Flat, _: std.mem.Allocator) !void {}

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
    pub const Configuration = struct {};
    pub const default_configuration: Configuration = .{};

    storage: [terrain.chunk_storage_capacity]u8 = undefined,

    pub fn configured(_: Configuration) Void {
        return .{};
    }

    pub fn initialize(_: *Void, _: std.mem.Allocator) !void {}

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
    const ConfigurationTuple = configurationStorage(Algorithms);
    const defaults = configurationDefaults(ConfigurationTuple, configured);
    return struct {
        const Self = @This();
        pub const id = "lightning_rod:world_generation";
        pub const Dependencies = struct {
            worlds: *world_store.Worlds,
            blocks: *block_store.Blocks,
        };
        pub const Configuration = ConfigurationTuple;
        pub const default_configuration = defaults;

        deps: Dependencies,
        algorithms: Algorithms,

        pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Self {
            const self = try preallocated.create(Self, allocator);
            self.* = .{
                .deps = deps,
                .algorithms = configureAlgorithms(Algorithms, configuration),
            };
            inline for (&self.algorithms) |*algorithm| try algorithm.initialize(allocator);
            deps.blocks.bindGenerator(.{
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
            const description = self.deps.worlds.get(world) orelse
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
            sink: generator_api.Sink,
        ) anyerror!generator_api.Advance {
            const self: *Self = @ptrCast(@alignCast(context));
            const description = self.deps.worlds.get(world) orelse
                return error.StaleWorldHandle;
            inline for (&self.algorithms, 0..) |*algorithm, index| {
                if (@intFromEnum(description.generator) == index) {
                    const Algorithm = @TypeOf(algorithm.*);
                    if (@hasDecl(Algorithm, "advance"))
                        return algorithm.advance(description.seed, chunk, sink);
                    try sink.emit(try algorithm.generate(description.seed, chunk));
                    return .complete;
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

fn configurationStorage(comptime Algorithms: type) type {
    const fields = @typeInfo(Algorithms).@"struct".fields;
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index|
        types[index] = if (@hasDecl(field.type, "Configuration")) field.type.Configuration else struct {};
    return std.meta.Tuple(&types);
}

fn configurationDefaults(comptime Configuration: type, comptime configured: anytype) Configuration {
    var result: Configuration = undefined;
    inline for (@typeInfo(Configuration).@"struct".fields, 0..) |field, index| {
        const Algorithm = @TypeOf(configured[index]);
        @field(result, field.name) = if (@hasDecl(Algorithm, "default_configuration"))
            Algorithm.default_configuration
        else
            .{};
    }
    return result;
}

fn configureAlgorithms(comptime Algorithms: type, configuration: anytype) Algorithms {
    var result: Algorithms = undefined;
    inline for (@typeInfo(Algorithms).@"struct".fields, 0..) |field, index|
        @field(result, field.name) = if (@hasDecl(field.type, "configured"))
            field.type.configured(configuration[index])
        else
            .{};
    return result;
}

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
        if (!@hasDecl(Algorithm, "initialize"))
            @compileError(Algorithm.id ++ " must implement initialize");
        inline for (0..index) |previous_index|
            if (std.mem.eql(u8, Algorithm.id, @TypeOf(configured[previous_index]).id))
                @compileError("duplicate world generator id: " ++ Algorithm.id);
    }
}
