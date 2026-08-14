const entity_store = @import("../world/entities.zig");
const input_store = @import("../world/inputs.zig");
const player_store = @import("../world/players.zig");
const block_store = @import("../world/blocks.zig");
const vanilla_time = @import("../world/time.zig");
const game_rules = @import("../world/game_rules.zig");
const world_random = @import("../world/random.zig");
const world_clock = @import("../world/clock.zig");
const world_store = @import("../world/worlds.zig");
const world_identity = @import("../world/identity.zig");
const world_dimensions = @import("../world/dimensions.zig");
const world_generation = @import("../world/generation.zig");
const std = @import("std");
const test_generator = @import("world_generator.zig");

const test_world_descriptions = [_]world_store.Description{
    .{ .key = .{ .value = 1 }, .name = "test:overworld", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Overworld), .generator = world_generation.Default.generatorId(world_generation.Overworld), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = .{ .value = 2 }, .name = "test:nether", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Nether), .generator = world_generation.Default.generatorId(world_generation.Void), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = .{ .value = 3 }, .name = "test:end", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.End), .generator = world_generation.Default.generatorId(world_generation.Flat), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
};

pub const State = struct {
    const storage_capacity = 2 * 1024 * 1024 * 1024;

    storage_owner: std.mem.Allocator = undefined,
    storage_memory: []align(64) u8 = &.{},
    storage: std.heap.FixedBufferAllocator = undefined,
    worlds: world_store.Worlds = world_store.Worlds.configure(.{ .initial = &test_world_descriptions }),
    dimensions: world_dimensions.Vanilla = .{},
    world: world_identity.Handle = world_identity.invalid,
    clock: world_clock.Clock = .{},
    time: vanilla_time.Time = .{},
    rules: game_rules.GameRules = .{},
    random: world_random.Random = .{},
    inputs: input_store.Inputs = .{},
    containers: player_store.Containers = .{},
    blocks: block_store.Blocks = .{},
    generator: test_generator.Generator = .{},
    living: entity_store.LivingEntities = .{},
    players: player_store.Players = .{},
    items: entity_store.ItemEntities = .{},

    pub fn init(self: *State, allocator: std.mem.Allocator, seed: u64) !void {
        self.* = .{};
        const pointer = allocator.rawAlloc(storage_capacity, .@"64", @returnAddress()) orelse
            return error.OutOfMemory;
        self.storage_owner = allocator;
        self.storage_memory = @alignCast(pointer[0..storage_capacity]);
        self.storage = std.heap.FixedBufferAllocator.init(self.storage_memory);
        errdefer allocator.rawFree(self.storage_memory, .@"64", @returnAddress());
        const storage = self.storage.allocator();
        try self.worlds.init(storage);
        try self.dimensions.init(&self.worlds);
        self.world = self.worlds.find(.{ .value = 1 }).?;
        self.random.random = world_random.DeterministicRng.init(seed);
        try self.inputs.init(storage);
        try self.containers.init(storage);
        try self.players.init(storage);
        try self.items.init(storage);
        try test_generator.initBlocks(&self.blocks, &self.generator, storage, seed);
        try self.living.init(storage);
    }

    pub fn deinit(self: *State) void {
        self.storage_owner.rawFree(self.storage_memory, .@"64", @returnAddress());
        self.* = undefined;
    }
};
