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
const geometry = @import("../world/geometry.zig");
const player_lifecycle = @import("../player_lifecycle.zig");
const living_entities = @import("../living_entities.zig");
const std = @import("std");
const test_generator = @import("world_generator.zig");

pub const SavedPlayers = struct {
    records: [16]player_store.CorePlayer = undefined,
    count: usize = 0,

    pub fn interface(self: *SavedPlayers) player_store.SavedPlayerStorage {
        return .{ .context = self, .load_fn = load, .save_fn = save };
    }

    fn load(raw: *anyopaque, uuid: u128, name: []const u8, output: *player_store.CorePlayer) player_store.SavedPlayerLoadError!bool {
        const self: *SavedPlayers = @ptrCast(@alignCast(raw));
        for (self.records[0..self.count]) |record| {
            if (record.uuid != uuid) continue;
            output.* = record;
            return true;
        }
        if (uuid != 0) return false;
        for (self.records[0..self.count]) |record| {
            if (!std.mem.eql(u8, record.name_slice(), name)) continue;
            output.* = record;
            return true;
        }
        return false;
    }

    fn save(raw: *anyopaque, _: std.Io, player: *const player_store.CorePlayer) player_store.SavedPlayerSaveError!void {
        const self: *SavedPlayers = @ptrCast(@alignCast(raw));
        for (self.records[0..self.count]) |*record| {
            if (record.uuid != player.uuid) continue;
            record.* = player.*;
            return;
        }
        if (self.count == self.records.len) return error.StorageUnavailable;
        self.records[self.count] = player.*;
        self.count += 1;
    }
};

const test_world_descriptions = [_]world_store.Description{
    .{ .key = .{ .value = 1 }, .name = "test:overworld", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Overworld), .generator = @enumFromInt(0), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = .{ .value = 2 }, .name = "test:nether", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.Nether), .generator = @enumFromInt(0), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
    .{ .key = .{ .value = 3 }, .name = "test:end", .dimension = world_dimensions.Vanilla.dimensionId(world_dimensions.End), .generator = @enumFromInt(0), .seed = 1, .spawn_x = 0, .spawn_y = 64, .spawn_z = 0 },
};

pub const State = struct {
    const storage_capacity = 128 * 1024 * 1024;

    storage_owner: std.mem.Allocator = undefined,
    storage_memory: []align(64) u8 = &.{},
    storage: std.heap.FixedBufferAllocator = undefined,
    saved_players: SavedPlayers = .{},
    worlds: *world_store.Worlds = undefined,
    dimensions: *world_dimensions.Vanilla = undefined,
    world: world_identity.Handle = world_identity.invalid,
    clock: world_clock.Clock = .{},
    time: vanilla_time.Time = .{},
    rules: game_rules.GameRules = .{},
    random: world_random.Random = .{},
    events: *player_lifecycle.Events = undefined,
    inputs: input_store.Inputs = undefined,
    containers: player_store.Containers = undefined,
    blocks: block_store.Blocks = undefined,
    generator: test_generator.Generator = .{},
    living: entity_store.LivingEntities = undefined,
    players: player_store.Players = undefined,
    items: entity_store.ItemEntities = undefined,

    pub fn init(self: *State, allocator: std.mem.Allocator, seed: u64) !void {
        self.* = .{};
        const pointer = allocator.rawAlloc(storage_capacity, .@"64", @returnAddress()) orelse
            return error.OutOfMemory;
        self.storage_owner = allocator;
        self.storage_memory = @alignCast(pointer[0..storage_capacity]);
        self.storage = std.heap.FixedBufferAllocator.init(self.storage_memory);
        errdefer allocator.rawFree(self.storage_memory, .@"64", @returnAddress());
        const storage = self.storage.allocator();
        self.worlds = try world_store.Worlds.init(storage, .{ .initial = &test_world_descriptions, .maximum_worlds = 4 });
        self.dimensions = try world_dimensions.Vanilla.init(storage, .{ .worlds = self.worlds }, .{});
        self.world = self.worlds.find(.{ .value = 1 }).?;
        self.random.random = world_random.DeterministicRng.init(seed);
        self.events = try player_lifecycle.Events.init(storage, .{});
        self.players = (try player_store.Players.init(storage, .{ .events = self.events, .worlds = self.worlds }, .{
            .initial_world = .{ .value = 1 },
            .maximum_connections = 8,
            .maximum_players = 4,
        })).*;
        try self.players.bindSavedPlayerStorage(self.saved_players.interface());
        self.inputs = (try input_store.Inputs.init(storage, .{ .events = self.events, .players = &self.players }, .{
            .maximum_block_requests = 32,
            .maximum_inventory_clicks = 32,
            .maximum_creative_slot_changes = 32,
        })).*;
        self.containers = (try player_store.Containers.init(storage, .{ .events = self.events, .players = &self.players }, .{})).*;
        self.items = (try entity_store.ItemEntities.init(storage, .{
            .maximum_entities = 64,
            .spatial_bucket_count = 64,
            .first_entity_id = @intCast(self.players.records.len + 1),
        })).*;
        self.blocks = (try test_generator.createBlocks(&self.generator, storage, seed)).*;
        self.generator.mode = .flat;
        self.living = (try entity_store.LivingEntities.init(storage, .{
            .maximum_entities = 64,
            .maximum_search_nodes = 512,
            .maximum_path_nodes = 128,
            .first_entity_id = @intCast(self.players.records.len + self.items.active.len + 1),
        })).*;
    }

    pub fn deinit(self: *State) void {
        self.storage_owner.rawFree(self.storage_memory, .@"64", @returnAddress());
        self.* = undefined;
    }

    pub fn spawnLiving(
        self: *State,
        entity_type: living_entities.EntityType,
        position: geometry.Vec3,
        baby: bool,
        persistent: bool,
    ) !living_entities.Handle {
        const block = geometry.BlockPos{
            .x = geometry.blockCoord(position.x),
            .y = @intCast(geometry.blockCoord(position.y)),
            .z = geometry.blockCoord(position.z),
        };
        _ = self.blocks.materializeGeneratedChunk(self.world, geometry.chunkForBlock(block), self.clock.tick);
        return self.living.spawn(&self.random, &self.blocks, self.world, entity_type, position, baby, persistent);
    }
};
