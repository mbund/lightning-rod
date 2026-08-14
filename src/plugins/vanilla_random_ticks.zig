const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const geometry = lightning_rod.geometry;
const vanilla_time = lightning_rod.time;
const game_rules = lightning_rod.game_rules;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const test_state = lightning_rod.test_support.state;
const preallocated = lightning_rod.preallocated;
const plugin_profiler = lightning_rod.plugin_profiler;
const config = lightning_rod.config.value;
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
const collision = lightning_rod.collision;
const terrain = lightning_rod.terrain;
const block_writer = lightning_rod.block_writer;
const leaf_behavior = @import("../vanilla/leaf_behavior.zig");
const diagnostics = lightning_rod.diagnostics;
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;

const leaf_directions = leaf_behavior.directions;
const offsetBlock = leaf_behavior.offset;
const leafDistance = leaf_behavior.distance;
const withLeafDistance = leaf_behavior.withDistance;
const isOakLeaves = leaf_behavior.isOak;
const isDecayingOakLeaves = leaf_behavior.isDecayingOak;
const spawnOakLeafDrops = leaf_behavior.spawnOakDrops;
const connectedLeafDistance = leaf_behavior.connectedDistance;

const active_chunks = @import("../vanilla/active_chunks.zig");
const Packets = lightning_rod.Packets;
const ChunkInterval = active_chunks.Interval;
const activeChunkRowBounds = active_chunks.rowBounds;
const chunkRowIntervals = active_chunks.rowIntervals;

pub const ScheduledBlockTicks = struct {
    pub const id = "minecraft:scheduled_block_ticks";

    initialized: bool = false,
    count: u16 = 0,
    sequence: u32 = 0,
    entries: []ScheduledBlockTick = &.{},
    lookup: []ScheduledBlockTickKey = &.{},

    pub fn create(allocator: std.mem.Allocator) !*ScheduledBlockTicks {
        const self = try allocator.create(ScheduledBlockTicks);
        self.* = .{};
        self.entries = try preallocated.alloc(ScheduledBlockTick, allocator, 4096);
        self.lookup = try preallocated.alloc(ScheduledBlockTickKey, allocator, 8192);
        @memset(self.lookup, .{});
        return self;
    }

    fn apply(self: *ScheduledBlockTicks, simulation: *Dependencies, random_ticks: *RandomTicks, outputs: *Packets) void {
        if (!self.initialized) initializeScheduledBlockTicks(simulation, self);
        runScheduledBlockTicks(simulation, self, random_ticks, outputs);
    }
};

pub const CropGrowth = struct {
    pub const id = "minecraft:crop_growth";

    pub fn create(allocator: std.mem.Allocator) !*CropGrowth {
        const self = try allocator.create(CropGrowth);
        self.* = .{};
        return self;
    }

    fn apply(_: *CropGrowth, tick: *RandomTickInvocation) void {
        switch (tick.behavior.kind) {
            .crop => randomTickCrop(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
            .stem => randomTickStem(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
            .cocoa => randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 5, tick.outputs, tick.changes),
            .nether_wart => randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 10, tick.outputs, tick.changes),
            .sweet_berry_bush => if (baseLightAt(tick.simulation, offsetBlock(tick.pos, .{ .x = 0, .y = 1, .z = 0 })) >= 9)
                randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 5, tick.outputs, tick.changes),
            else => unreachable,
        }
    }
};

pub const PlantGrowth = struct {
    pub const id = "minecraft:plant_growth";

    pub fn create(allocator: std.mem.Allocator) !*PlantGrowth {
        const self = try allocator.create(PlantGrowth);
        self.* = .{};
        return self;
    }

    fn apply(_: *PlantGrowth, tick: *RandomTickInvocation) void {
        switch (tick.behavior.kind) {
            .cactus => randomTickColumnPlant(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.age, cactus_block_id, cactus_default_state, tick.outputs, tick.changes),
            .sugar_cane => randomTickColumnPlant(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.age, sugar_cane_block_id, sugar_cane_default_state, tick.outputs, tick.changes),
            .kelp => randomTickKelp(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
            .bamboo => randomTickBamboo(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes),
            .bamboo_sapling => randomTickBambooSapling(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes),
            .chorus_flower => randomTickChorusFlower(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
            .mangrove_propagule => if (tick.behavior.next_age >= 0) applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, tick.outputs, tick.changes),
            .sapling => randomTickSapling(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
            else => unreachable,
        }
    }
};

pub const PlantSpread = struct {
    pub const id = "minecraft:plant_spread";

    pub fn create(allocator: std.mem.Allocator) !*PlantSpread {
        const self = try allocator.create(PlantSpread);
        self.* = .{};
        return self;
    }

    fn apply(_: *PlantSpread, tick: *RandomTickInvocation) void {
        switch (tick.behavior.kind) {
            .spreadable => randomTickBlock(tick.simulation, tick.scheduler, tick.origin_chunk_index, tick.origin, tick.pos, tick.can_spread, tick.outputs, tick.changes),
            .mushroom => randomTickMushroom(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes),
            .vine => randomTickVine(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
            .nylium => if (game_data.blockInfo(tick.simulation.blocks.blockAt(tick.simulation.world, offsetBlock(tick.pos, .{ .x = 0, .y = 1, .z = 0 }))).filtered_light >= 15)
                applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, registry.block_netherrack_default_state, tick.outputs, tick.changes),
            else => unreachable,
        }
    }
};

pub const FarmlandHydration = struct {
    pub const id = "minecraft:farmland_hydration";

    pub fn create(allocator: std.mem.Allocator) !*FarmlandHydration {
        const self = try allocator.create(FarmlandHydration);
        self.* = .{};
        return self;
    }

    fn apply(_: *FarmlandHydration, tick: *RandomTickInvocation) void {
        switch (tick.behavior.kind) {
            .farmland => randomTickFarmland(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.moisture, tick.outputs, tick.changes),
            .mud => {},
            .pointed_dripstone => randomTickPointedDripstone(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
            else => unreachable,
        }
    }
};

pub const LeafDecay = struct {
    pub const id = "minecraft:leaf_decay";

    pub fn create(allocator: std.mem.Allocator) !*LeafDecay {
        const self = try allocator.create(LeafDecay);
        self.* = .{};
        return self;
    }

    fn apply(_: *LeafDecay, tick: *RandomTickInvocation) void {
        if (isDecayingOakLeaves(tick.block_state)) decayLeaves(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
    }
};

pub const FireAndLava = struct {
    pub const id = "minecraft:fire_and_lava";

    pub fn create(allocator: std.mem.Allocator) !*FireAndLava {
        const self = try allocator.create(FireAndLava);
        self.* = .{};
        return self;
    }

    fn apply(_: *FireAndLava, tick: *RandomTickInvocation) void {
        randomTickLava(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
    }
};

pub const IceAndSnow = struct {
    pub const id = "minecraft:ice_and_snow";

    pub fn create(allocator: std.mem.Allocator) !*IceAndSnow {
        const self = try allocator.create(IceAndSnow);
        self.* = .{};
        return self;
    }

    fn apply(_: *IceAndSnow, tick: *RandomTickInvocation) void {
        if (tick.behavior.kind == .ice)
            randomTickIce(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes)
        else
            randomTickSnow(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
    }
};

pub const CopperWeathering = struct {
    pub const id = "minecraft:copper_weathering";

    pub fn create(allocator: std.mem.Allocator) !*CopperWeathering {
        const self = try allocator.create(CopperWeathering);
        self.* = .{};
        return self;
    }

    fn apply(_: *CopperWeathering, tick: *RandomTickInvocation) void {
        randomTickCopper(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes);
    }
};

pub const RandomBlockEvents = struct {
    pub const id = "minecraft:random_block_events";

    pub fn create(allocator: std.mem.Allocator) !*RandomBlockEvents {
        const self = try allocator.create(RandomBlockEvents);
        self.* = .{};
        return self;
    }

    fn apply(_: *RandomBlockEvents, tick: *RandomTickInvocation) void {
        switch (tick.behavior.kind) {
            .redstone_ore => applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, tick.block_state + 1, tick.outputs, tick.changes),
            .nether_portal => randomTickNetherPortal(tick.simulation, tick.pos, tick.outputs),
            .turtle_egg => randomTickTurtleEgg(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
            .budding_amethyst => randomTickBuddingAmethyst(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes),
            else => unreachable,
        }
    }
};

const Behaviors = struct {
    scheduled: *ScheduledBlockTicks,
    crops: *CropGrowth,
    growth: *PlantGrowth,
    spread: *PlantSpread,
    farmland: *FarmlandHydration,
    leaves: *LeafDecay,
    fire_and_lava: *FireAndLava,
    ice_and_snow: *IceAndSnow,
    copper: *CopperWeathering,
    block_events: *RandomBlockEvents,
};

const Dependencies = struct {
    world: world_identity.Handle = world_identity.invalid,
    seed: u64 = 0,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    scheduled: ?*ScheduledBlockTicks = null,

    fn fromTestState(game: *test_state.State) Dependencies {
        return .{
            .world = game.world,
            .seed = game.worlds.get(game.world).?.seed,
            .clock = &game.clock,
            .time = &game.time,
            .rules = &game.rules,
            .random = &game.random,
            .blocks = &game.blocks,
            .players = &game.players,
            .living = &game.living,
            .items = &game.items,
        };
    }

    fn activePlayerSlots(self: *const Dependencies) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    fn spawnLiving(
        self: *Dependencies,
        entity_type: living_entities.EntityType,
        position: geometry.Vec3,
        baby: bool,
        persistent: bool,
    ) !living_entities.Handle {
        return self.living.spawn(
            self.random,
            self.blocks,
            self.world,
            entity_type,
            position,
            baby,
            persistent,
        );
    }

    fn spawn_item_entity(
        self: *Dependencies,
        position: geometry.Vec3,
        velocity: geometry.Vec3,
        stack: player_store.HotbarStack,
    ) !usize {
        return self.items.spawn(
            self.random,
            self.blocks,
            self.world,
            position,
            velocity,
            stack,
        );
    }
};

const random_tick_action_mask_unindexed = std.math.maxInt(u16);
const random_tick_inactive_position = std.math.maxInt(u16);
const random_tick_active_radius = fullRadius(config.simulation_distance_chunks);
const random_tick_ticket_radius = random_tick_active_radius + 1;
const random_tick_ticket_side: usize = @intCast(random_tick_ticket_radius * 2 + 1);
const random_tick_ticket_cells = random_tick_ticket_side * random_tick_ticket_side;

/// Vanilla 1.21.8 ChunkLevels thresholds. Player simulation tickets begin at
/// max(0, ENTITY_TICKING - simulation_distance) and propagate one level per
/// Chebyshev chunk step.
const VanillaChunkLevelType = enum { inaccessible, full, block_ticking, entity_ticking };

fn playerSimulationTicketLevel(simulation_distance: i32) u8 {
    return @intCast(@max(0, 31 - simulation_distance));
}

fn chunkLevelTypeAtDistance(simulation_distance: i32, distance: i32) VanillaChunkLevelType {
    const level = @as(i32, playerSimulationTicketLevel(simulation_distance)) + distance;
    if (level <= 31) return .entity_ticking;
    if (level == 32) return .block_ticking;
    if (level == 33) return .full;
    return .inaccessible;
}

fn entityTickingRadius(simulation_distance: i32) i32 {
    return @min(simulation_distance, 31);
}

fn fullRadius(simulation_distance: i32) i32 {
    return @min(simulation_distance + 2, 33);
}

test "1.21.8 simulation tickets preserve entity block full and inaccessible rings" {
    try std.testing.expectEqual(@as(u8, 21), playerSimulationTicketLevel(10));
    try std.testing.expectEqual(VanillaChunkLevelType.entity_ticking, chunkLevelTypeAtDistance(10, 10));
    try std.testing.expectEqual(VanillaChunkLevelType.block_ticking, chunkLevelTypeAtDistance(10, 11));
    try std.testing.expectEqual(VanillaChunkLevelType.full, chunkLevelTypeAtDistance(10, 12));
    try std.testing.expectEqual(VanillaChunkLevelType.inaccessible, chunkLevelTypeAtDistance(10, 13));

    try std.testing.expectEqual(@as(u8, 0), playerSimulationTicketLevel(32));
    try std.testing.expectEqual(@as(i32, 31), entityTickingRadius(32));
    try std.testing.expectEqual(@as(i32, 33), fullRadius(32));
    try std.testing.expectEqual(VanillaChunkLevelType.entity_ticking, chunkLevelTypeAtDistance(32, 31));
    try std.testing.expectEqual(VanillaChunkLevelType.block_ticking, chunkLevelTypeAtDistance(32, 32));
    try std.testing.expectEqual(VanillaChunkLevelType.full, chunkLevelTypeAtDistance(32, 33));
    try std.testing.expectEqual(VanillaChunkLevelType.inaccessible, chunkLevelTypeAtDistance(32, 34));
}

const RandomTickCenter = struct {
    slot: u16,
    chunk_x: i32,
    chunk_z: i32,
};

const RandomTickChunk = struct {
    chunk: geometry.ChunkPos,
    random_key: u32,
    generated_cache_hint: u16,
    observed_content_revision: u64,
    level_type: VanillaChunkLevelType,
    projection_initialized: bool,
    exact_grass_neighborhood: bool,
    base_grass_candidate_source: bool,
    observed_modified_section_mask: u32,
    section_mask: u32,
    action_section_mask: u32,
    base_section_mask: u32,
    grass_section_mask: u32,
    ticking_position: u16,
    _padding: [16]u8,
};

const RandomTickGrassProjection = struct {
    heights: [16 * 16]i16,
    grass_above_blocked: [4]u64,
    _padding: [32]u8,
};

const RandomTickGeneralProjection = struct {
    mask_handles: [config.overworld_section_count]u16,
    uniform_states: [config.overworld_section_count]i32,
    action_mask_handles: [config.overworld_section_count]u16,
};

comptime {
    if (@sizeOf(RandomTickChunk) != 64) @compileError("random tick chunk header must occupy one cache line");
    if (@sizeOf(RandomTickGrassProjection) != 576) @compileError("random tick grass projection layout changed");
    if (@sizeOf(RandomTickGeneralProjection) != 192) @compileError("random tick general projection must occupy three cache lines");
}

pub const RandomTicks = struct {
    pub const id = "minecraft:random_ticks";
    pub const Trace = RandomTickTrace;

    pub const Configuration = struct {
        maximum_ticking_chunks: usize = config.max_resident_chunks,

        pub fn validate(self: Configuration, blocks: *const block_store.Blocks) !void {
            if (self.maximum_ticking_chunks == 0 or self.maximum_ticking_chunks > blocks.resident_chunks.len or
                self.maximum_ticking_chunks >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_ticking_chunks))
                return error.InvalidRandomTickChunkCapacity;
        }
    };

    topology_initialized: bool = false,
    overflow: bool = false,
    resident_binding_revision: u64 = 0,
    center_count: usize = 0,
    centers: []RandomTickCenter = &.{},
    ticking_chunk_count: usize = 0,
    chunk_count: usize = 0,
    topology_generation: u32 = 0,
    chunk_pool_initialized: bool = false,
    free_chunk_count: usize = 0,
    free_chunk_indices: []u16 = &.{},
    active_chunk_indices: []u16 = &.{},
    previous_exact_neighborhoods: []bool = &.{},
    chunk_was_active: []bool = &.{},
    chunk_topology_generations: []u32 = &.{},
    chunk_ticket_generations: []u32 = &.{},
    chunk_allocated: []bool = &.{},
    ticket_grid_initialized: []bool = &.{},
    ticket_grid_center_x: []i32 = &.{},
    ticket_grid_center_z: []i32 = &.{},
    ticket_grid_seen_generation: []u32 = &.{},
    ticket_grid_missing: []u16 = &.{},
    ticket_grid_prefetch_cursor: []u16 = &.{},
    ticket_grid_handles: [][random_tick_ticket_cells]u16 = &.{},
    ticket_grid_scratch: []u16 = &.{},
    observed_mutation_sequence: u64 = 0,
    chunks: []align(64) RandomTickChunk = &.{},
    grass: []align(64) RandomTickGrassProjection = &.{},
    general: []align(64) RandomTickGeneralProjection = &.{},
    // Zero means empty; populated slots store chunk_index + 1.
    lookup: []u16 = &.{},
    action_mask_count: usize = 0,
    action_mask_pool_initialized: bool = false,
    free_action_mask_count: usize = 0,
    free_action_masks: []u16 = &.{},
    action_masks: [][block_store.blocks_per_section / 64]u64 = &.{},
    action_chunk_positions: []align(64) u64 = &.{},
    scheduled: *ScheduledBlockTicks,
    crops: *CropGrowth,
    growth: *PlantGrowth,
    spread: *PlantSpread,
    farmland: *FarmlandHydration,
    leaves: *LeafDecay,
    fire_and_lava: *FireAndLava,
    ice_and_snow: *IceAndSnow,
    copper: *CopperWeathering,
    block_events: *RandomBlockEvents,
    worlds: *world_store.Worlds,
    clock: *world_clock.Clock,
    time: *vanilla_time.Time,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, scheduled: *ScheduledBlockTicks, crops: *CropGrowth, growth: *PlantGrowth, spread: *PlantSpread, farmland: *FarmlandHydration, leaves: *LeafDecay, fire_and_lava: *FireAndLava, ice_and_snow: *IceAndSnow, copper: *CopperWeathering, block_events: *RandomBlockEvents, worlds: *world_store.Worlds, clock: *world_clock.Clock, time: *vanilla_time.Time, rules: *game_rules.GameRules, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, outputs: *Packets, configuration: Configuration) !*RandomTicks {
        try configuration.validate(blocks);
        const self = try allocator.create(RandomTicks);
        self.* = .{ .scheduled = scheduled, .crops = crops, .growth = growth, .spread = spread, .farmland = farmland, .leaves = leaves, .fire_and_lava = fire_and_lava, .ice_and_snow = ice_and_snow, .copper = copper, .block_events = block_events, .worlds = worlds, .clock = clock, .time = time, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .outputs = outputs };
        try allocateBuffers(self, allocator, configuration.maximum_ticking_chunks);
        return self;
    }

    pub fn tick(self: *RandomTicks, _: std.mem.Allocator) void {
        const scheduled = self.scheduled;
        const crops = self.crops;
        const growth = self.growth;
        const spread = self.spread;
        const farmland = self.farmland;
        const leaves = self.leaves;
        const fire_and_lava = self.fire_and_lava;
        const ice_and_snow = self.ice_and_snow;
        const copper = self.copper;
        const block_events = self.block_events;
        const worlds = self.worlds;
        const clock = self.clock;
        const time = self.time;
        const rules = self.rules;
        const random = self.random;
        const blocks = self.blocks;
        const players = self.players;
        const living = self.living;
        const items = self.items;
        const outputs = self.outputs;
        const behaviors = Behaviors{ .scheduled = scheduled, .crops = crops, .growth = growth, .spread = spread, .farmland = farmland, .leaves = leaves, .fire_and_lava = fire_and_lava, .ice_and_snow = ice_and_snow, .copper = copper, .block_events = block_events };
        var simulation = Dependencies{ .clock = clock, .time = time, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .scheduled = scheduled };
        for (worlds.active()) |world| {
            simulation.world = world;
            simulation.seed = worlds.get(world).?.seed;
            runRandomTicks(&simulation, self, &behaviors, outputs);
        }
    }
};

const ScheduledBlockTickKind = enum(u8) { fire, water_cauldron };

const ScheduledBlockTick = struct {
    due: u64,
    sequence: u32,
    pos: geometry.BlockPos,
    kind: ScheduledBlockTickKind,
};

const ScheduledBlockTickKey = struct {
    pos: geometry.BlockPos = .{ .x = 0, .y = std.math.minInt(i16), .z = 0 },
    kind: ScheduledBlockTickKind = .fire,
};

fn scheduledKeyEmpty(key: ScheduledBlockTickKey) bool {
    return key.pos.y == std.math.minInt(i16);
}

fn scheduledKeyEqual(key: ScheduledBlockTickKey, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) bool {
    return key.kind == kind and key.pos.x == pos.x and key.pos.y == pos.y and key.pos.z == pos.z;
}

fn scheduledKeyHash(pos: geometry.BlockPos, kind: ScheduledBlockTickKind) usize {
    var value: u64 = @as(u32, @bitCast(pos.x));
    value ^= @as(u64, @as(u16, @bitCast(pos.y))) << 32;
    value ^= @as(u64, @as(u32, @bitCast(pos.z))) *% 0x9e37_79b9;
    value ^= @as(u64, @intFromEnum(kind)) *% 0xd6e8_feb8_6659_fd93;
    value ^= value >> 32;
    value *%= 0xd6e8_feb8_6659_fd93;
    value ^= value >> 32;
    return @intCast(value);
}

fn lookupProbeDistance(ideal: usize, index: usize, mask: usize) usize {
    return (index -% ideal) & mask;
}

fn insertScheduledKey(state: *ScheduledBlockTicks, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) bool {
    const mask = state.lookup.len - 1;
    var probe = scheduledKeyHash(pos, kind);
    for (0..state.lookup.len) |_| {
        const index = probe & mask;
        const key = state.lookup[index];
        if (scheduledKeyEmpty(key)) {
            state.lookup[index] = .{ .pos = pos, .kind = kind };
            return true;
        }
        if (scheduledKeyEqual(key, pos, kind)) return false;
        probe += 1;
    }
    diagnostics.panic("scheduled block tick lookup capacity exhausted", &.{});
}

fn removeScheduledKey(state: *ScheduledBlockTicks, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) void {
    const mask = state.lookup.len - 1;
    var probe = scheduledKeyHash(pos, kind);
    var found: ?usize = null;
    for (0..state.lookup.len) |_| {
        const index = probe & mask;
        const key = state.lookup[index];
        if (scheduledKeyEmpty(key)) return;
        if (scheduledKeyEqual(key, pos, kind)) {
            found = index;
            break;
        }
        probe += 1;
    }
    var hole = found orelse return;
    state.lookup[hole] = .{};
    var scan = (hole + 1) & mask;
    for (0..state.lookup.len) |_| {
        if (scheduledKeyEmpty(state.lookup[scan])) return;
        const key = state.lookup[scan];
        const ideal = scheduledKeyHash(key.pos, key.kind) & mask;
        if (lookupProbeDistance(ideal, hole, mask) < lookupProbeDistance(ideal, scan, mask)) {
            state.lookup[hole] = key;
            state.lookup[scan] = .{};
            hole = scan;
        }
        scan = (scan + 1) & mask;
    }
    diagnostics.panic("scheduled block tick lookup invariant violated", &.{});
}

fn scheduledTickBefore(a: ScheduledBlockTick, b: ScheduledBlockTick) bool {
    return a.due < b.due or (a.due == b.due and a.sequence < b.sequence);
}

fn scheduleBlockTick(state: *ScheduledBlockTicks, due: u64, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) void {
    if (!insertScheduledKey(state, pos, kind)) return;
    if (state.count == state.entries.len)
        diagnostics.panic("scheduled block tick capacity exhausted (x, y, z)", &.{ diagnostics.integer(pos.x), diagnostics.integer(pos.y), diagnostics.integer(pos.z) });
    var index: usize = state.count;
    state.count += 1;
    state.sequence +%= 1;
    state.entries[index] = .{ .due = due, .sequence = state.sequence, .pos = pos, .kind = kind };
    for (0..std.math.log2_int_ceil(usize, state.entries.len + 1)) |_| {
        if (index == 0) break;
        const parent = (index - 1) / 2;
        if (!scheduledTickBefore(state.entries[index], state.entries[parent])) break;
        std.mem.swap(ScheduledBlockTick, &state.entries[index], &state.entries[parent]);
        index = parent;
    }
}

fn popScheduledBlockTick(state: *ScheduledBlockTicks) ScheduledBlockTick {
    const result = state.entries[0];
    removeScheduledKey(state, result.pos, result.kind);
    state.count -= 1;
    if (state.count == 0) return result;
    state.entries[0] = state.entries[state.count];
    var index: usize = 0;
    for (0..std.math.log2_int_ceil(usize, state.entries.len + 1)) |_| {
        const left = index * 2 + 1;
        if (left >= state.count) break;
        const right = left + 1;
        const child = if (right < state.count and scheduledTickBefore(state.entries[right], state.entries[left])) right else left;
        if (!scheduledTickBefore(state.entries[child], state.entries[index])) break;
        std.mem.swap(ScheduledBlockTick, &state.entries[index], &state.entries[child]);
        index = child;
    }
    return result;
}

fn scheduledTicks(simulation: *Dependencies) *ScheduledBlockTicks {
    return simulation.scheduled orelse
        diagnostics.panic("random tick behavior requires scheduled block ticks", &.{});
}

fn scheduleFire(simulation: *Dependencies, pos: geometry.BlockPos) void {
    scheduleBlockTick(scheduledTicks(simulation), simulation.clock.tick + 30 + simulation.random.random.nextIntBoundedComptime(10), pos, .fire);
}

fn initializeScheduledBlockTicks(simulation: *Dependencies, state: *ScheduledBlockTicks) void {
    state.initialized = true;
    for (simulation.blocks.active_resident_indices[0..simulation.blocks.resident_chunk_count]) |resident_index| {
        const resident = &simulation.blocks.resident_chunks[resident_index];
        var sections = resident.modified_section_mask;
        while (sections != 0) {
            const section_index: usize = @intCast(@ctz(sections));
            sections &= sections - 1;
            const table_index = resident.modified_section_indices[section_index];
            if (table_index == block_store.no_modified_section_index) continue;
            const section = &simulation.blocks.modified_sections[table_index];
            for (section.modified_bits, 0..) |word, word_index| {
                var remaining = word;
                while (remaining != 0) {
                    const bit: u6 = @intCast(@ctz(remaining));
                    remaining &= remaining - 1;
                    const local_index: u16 = @intCast(word_index * 64 + bit);
                    if (blockId(simulation.blocks.modifiedBlockStateAt(table_index, local_index)) != fire_block_id) continue;
                    scheduleFire(simulation, .{
                        .x = section.chunk.x * 16 + @as(i32, local_index & 15),
                        .y = block_store.sectionWorldY(section.section, (local_index >> 8) & 15),
                        .z = section.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
                    });
                }
            }
        }
    }
}

fn runScheduledBlockTicks(simulation: *Dependencies, state: *ScheduledBlockTicks, random_ticks: *RandomTicks, outputs: *Packets) void {
    var changes: usize = 0;
    for (0..state.entries.len) |_| {
        if (state.count == 0 or state.entries[0].due > simulation.clock.tick) break;
        const scheduled = popScheduledBlockTick(state);
        switch (scheduled.kind) {
            .fire => tickFire(simulation, random_ticks, scheduled.pos, outputs, &changes),
            .water_cauldron => {
                if (blockId(simulation.blocks.blockAt(simulation.world, scheduled.pos)) == cauldron_block_id)
                    applyRandomTickChange(simulation, random_ticks, scheduled.pos, water_cauldron_level_one, outputs, &changes);
            },
        }
        if (changes == config.max_random_tick_block_changes_per_tick) return;
    } else diagnostics.panic("scheduled block tick heap failed to drain within capacity", &.{});
}

const RandomTickTrace = enum {
    topology_check,
    topology_rebuild,
    topology_ticket_grids,
    topology_activation,
    topology_retirement,
    topology_neighborhoods,
    mutation_reconcile,
    chunk_walk,
    action_chunks,
    action_sections,
    coordinate_probes,
    action_hits,
    unindexed_sections,
    leaf_decays,
    leaf_sapling_rolls,
    leaf_sapling_spawns,
    leaf_drop_spawn_failures,
    leaf_drop_capacity_failures,
};

const RandomTickWorkload = struct {
    action_chunks: usize = 0,
    action_sections: usize = 0,
    coordinate_probes: usize = 0,
    action_hits: usize = 0,
    unindexed_sections: usize = 0,
};

const RandomTickSampleVector = @Vector(4, u32);

fn mixRandomTickVector(input: RandomTickSampleVector) RandomTickSampleVector {
    var value = input;
    value ^= value >> @as(RandomTickSampleVector, @splat(16));
    value *%= @as(RandomTickSampleVector, @splat(0x7feb_352d));
    value ^= value >> @as(RandomTickSampleVector, @splat(15));
    value *%= @as(RandomTickSampleVector, @splat(0x846c_a68b));
    value ^= value >> @as(RandomTickSampleVector, @splat(16));
    return value;
}

fn mixRandomTickScalar(input: u32) u32 {
    var value = input;
    value ^= value >> 16;
    value *%= 0x7feb_352d;
    value ^= value >> 15;
    value *%= 0x846c_a68b;
    value ^= value >> 16;
    return value;
}

fn randomTickChunkKey(seed: u64, chunk: geometry.ChunkPos) u32 {
    return mixRandomTickScalar(@truncate(seed ^ (seed >> 32))) ^
        mixRandomTickScalar(@as(u32, @bitCast(chunk.x))) ^
        std.math.rotl(u32, mixRandomTickScalar(@as(u32, @bitCast(chunk.z))), 16);
}

fn randomTickSampleTickKey(tick: u64) u32 {
    return mixRandomTickScalar(@truncate(tick ^ (tick >> 32)));
}

fn randomTickSamplesForTickKey(chunk_key: u32, tick_key: u32, section: usize, first_sample: u16) [4]u16 {
    const section_key = @as(u32, @intCast(section)) *% 0x9e37_79b9;
    const first_key = @as(u32, first_sample) *% 0x85eb_ca6b;
    const lanes = RandomTickSampleVector{
        0x243f_6a88,
        0x85a3_08d3,
        0x1319_8a2e,
        0x0370_7344,
    };
    const mixed: [4]u32 = mixRandomTickVector(@as(RandomTickSampleVector, @splat(chunk_key ^ tick_key ^ section_key ^ first_key)) ^ lanes);
    return .{
        @truncate(mixed[0]),
        @truncate(mixed[1]),
        @truncate(mixed[2]),
        @truncate(mixed[3]),
    };
}

fn randomTickSamples(chunk_key: u32, tick: u64, section: usize, first_sample: u16) [4]u16 {
    return randomTickSamplesForTickKey(chunk_key, randomTickSampleTickKey(tick), section, first_sample);
}

fn randomTickEventSeed(seed: u64, tick: u64, chunk_key: u32, section: usize, sample: u16) u64 {
    var value = seed ^ (tick *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, chunk_key) << 17) ^
        (@as(u64, section) << 8) ^ sample;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

test "SIMD random tick samples match scalar lane generation" {
    const key: u32 = 0x1234_5678;
    const tick: u64 = 0xfedc_ba98_7654;
    const section: usize = 7;
    const first_sample: u16 = 4;
    const actual = randomTickSamples(key, tick, section, first_sample);
    const tick_key = mixRandomTickScalar(@truncate(tick ^ (tick >> 32)));
    const section_key = @as(u32, @intCast(section)) *% 0x9e37_79b9;
    const first_key = @as(u32, first_sample) *% 0x85eb_ca6b;
    const lanes = [_]u32{ 0x243f_6a88, 0x85a3_08d3, 0x1319_8a2e, 0x0370_7344 };
    for (lanes, actual) |lane, sample|
        try std.testing.expectEqual(@as(u16, @truncate(mixRandomTickScalar(key ^ tick_key ^ section_key ^ first_key ^ lane))), sample);
}

test "literal random tick samples retain coordinate order and duplicates" {
    const chunk_key: u32 = 0x7365_7269;
    const section: usize = 16;
    const samples = randomTickSamples(chunk_key, 4673, section, 0);
    try std.testing.expectEqual(
        samples[0] & (block_store.blocks_per_section - 1),
        samples[1] & (block_store.blocks_per_section - 1),
    );
}

fn randomTickTopologyMatches(simulation: *const Dependencies, state: *const RandomTicks) bool {
    if (!state.topology_initialized) return false;
    var center_index: usize = 0;
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator) continue;
        if (center_index == state.center_count) return false;
        const center = state.centers[center_index];
        if (center.slot != slot or
            center.chunk_x != @divFloor(geometry.blockCoord(player.position.x), 16) or
            center.chunk_z != @divFloor(geometry.blockCoord(player.position.z), 16)) return false;
        center_index += 1;
    }
    return center_index == state.center_count;
}

fn randomTickChunkHash(chunk: geometry.ChunkPos) usize {
    var value: u64 = 0xd6e8_feb8_6659_fd93;
    value ^= @as(u32, @bitCast(chunk.x));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.z));
    value *%= 0xe703_7ed1_a0b4_28db;
    value ^= value >> 32;
    return @intCast(value);
}

fn ensureRandomTickChunkPool(state: *RandomTicks) void {
    if (state.chunk_pool_initialized) return;
    for (0..state.free_chunk_indices.len) |index|
        state.free_chunk_indices[index] = @intCast(state.free_chunk_indices.len - 1 - index);
    state.free_chunk_count = state.free_chunk_indices.len;
    state.chunk_pool_initialized = true;
}

fn ensureRandomTickActionMaskPool(state: *RandomTicks) void {
    if (state.action_mask_pool_initialized) return;
    for (0..state.free_action_masks.len) |index|
        state.free_action_masks[index] = @intCast(state.free_action_masks.len - 1 - index);
    state.free_action_mask_count = state.free_action_masks.len;
    state.action_mask_pool_initialized = true;
}

fn allocateRandomTickActionMask(state: *RandomTicks) ?u16 {
    ensureRandomTickActionMaskPool(state);
    if (state.free_action_mask_count == 0) return null;
    if (state.free_action_mask_count > state.free_action_masks.len)
        diagnostics.panic("random tick action-mask free count is corrupt (free count, capacity)", &.{ diagnostics.integer(state.free_action_mask_count), diagnostics.integer(state.free_action_masks.len) });
    state.free_action_mask_count -= 1;
    const index = state.free_action_masks[state.free_action_mask_count];
    if (index >= state.action_masks.len)
        diagnostics.panic("random tick action-mask free list contains invalid index (index, capacity)", &.{ diagnostics.integer(index), diagnostics.integer(state.action_masks.len) });
    state.action_mask_count += 1;
    return index + 1;
}

fn releaseRandomTickActionMask(state: *RandomTicks, handle: *u16) void {
    if (handle.* == 0 or handle.* == random_tick_action_mask_unindexed) {
        handle.* = 0;
        return;
    }
    if (handle.* > state.action_masks.len)
        diagnostics.panic("invalid random tick action-mask handle (handle, capacity)", &.{ diagnostics.integer(handle.*), diagnostics.integer(state.action_masks.len) });
    std.debug.assert(state.free_action_mask_count < state.free_action_masks.len);
    std.debug.assert(state.action_mask_count != 0);
    state.free_action_masks[state.free_action_mask_count] = handle.* - 1;
    state.free_action_mask_count += 1;
    state.action_mask_count -= 1;
    handle.* = 0;
}

fn releaseRandomTickActionMasks(state: *RandomTicks, chunk_index: usize) void {
    for (&state.general[chunk_index].action_mask_handles) |*handle| releaseRandomTickActionMask(state, handle);
    state.chunks[chunk_index].action_section_mask = 0;
}

fn updateRandomTickActionChunkPosition(state: *RandomTicks, chunk_index: usize) void {
    const active = state.chunks[chunk_index];
    if (active.ticking_position == random_tick_inactive_position) return;
    const position: usize = active.ticking_position;
    const bit = @as(u64, 1) << @intCast(position & 63);
    if (active.action_section_mask == 0)
        state.action_chunk_positions[position / 64] &= ~bit
    else
        state.action_chunk_positions[position / 64] |= bit;
}

fn randomTickActionMaskIsEmpty(mask: *const [block_store.blocks_per_section / 64]u64) bool {
    for (mask) |word| if (word != 0) return false;
    return true;
}

fn refreshRandomTickSections(active: *RandomTickChunk, generated: *const block_store.GeneratedHeightChunk) void {
    active.section_mask = generated.random_tick_sections;
    active.observed_modified_section_mask = generated.modified_section_mask;
}

fn baseSectionSupportsProjectedGrass(simulation: *const Dependencies, generated: *const block_store.GeneratedHeightChunk, section: usize) bool {
    const handle = generated.random_tick_mask_handles[section];
    if (handle == 0) return false;
    if (handle == block_store.random_tick_mask_columns)
        return generated.random_tick_uniform_states[section] == registry.block_grass_block_default_state;

    if (handle != block_store.random_tick_mask_unindexed) {
        for (simulation.blocks.random_tick_masks[handle - 1], 0..) |word, word_index| {
            var remaining = word;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                const local_index: u16 = @intCast(word_index * 64 + bit);
                const block_state = simulation.blocks.sectionBlockState(generated, section, local_index, null);
                if (block_state == registry.block_grass_block_default_state) continue;
                if (isOakLeaves(block_state) and !isDecayingOakLeaves(block_state)) continue;
                return false;
            }
        }
        return true;
    }

    for (0..block_store.blocks_per_section) |index| {
        const local_index: u16 = @intCast(index);
        const block_state = simulation.blocks.sectionBlockState(generated, section, local_index, null);
        if (registry.randomTickState(block_state).kind == .none or block_state == registry.block_grass_block_default_state) continue;
        if (isOakLeaves(block_state) and !isDecayingOakLeaves(block_state)) continue;
        return false;
    }
    return true;
}

fn initializeRandomTickProjection(simulation: *const Dependencies, state: *RandomTicks, active_index: usize, generated: *const block_store.GeneratedHeightChunk) void {
    const active = &state.chunks[active_index];
    const grass = &state.grass[active_index];
    const general = &state.general[active_index];
    active.base_section_mask = generated.random_tick_sections;
    active.grass_section_mask = 0;
    active.action_section_mask = 0;
    grass.heights = generated.heights;
    grass.grass_above_blocked = generated.grass_above_blocked;
    general.mask_handles = generated.random_tick_mask_handles;
    general.uniform_states = generated.random_tick_uniform_states;
    general.action_mask_handles = [_]u16{0} ** config.overworld_section_count;
    var sections = active.base_section_mask;
    while (sections != 0) {
        const section: usize = @intCast(@ctz(sections));
        sections &= sections - 1;
        if (baseSectionSupportsProjectedGrass(simulation, generated, section)) {
            active.grass_section_mask |= @as(u32, 1) << @intCast(section);
        }
    }
    refreshRandomTickModifiedProjection(simulation, state, active_index, generated);
}

fn refreshRandomTickModifiedProjection(simulation: *const Dependencies, state: *RandomTicks, chunk_index: usize, generated: *const block_store.GeneratedHeightChunk) void {
    const active = &state.chunks[chunk_index];
    refreshRandomTickSections(active, generated);
    for (0..config.overworld_section_count) |section| {
        const encoded = generated.modified_section_indices[section];
        if (encoded != block_store.no_modified_section_index) {
            const modified = &simulation.blocks.modified_sections[encoded];
            const section_bit = @as(u32, 1) << @intCast(section);
            if (modified.random_tickable_count == 0)
                active.section_mask &= ~section_bit
            else
                active.section_mask |= section_bit;
        }
    }
    refreshRandomTickActionProjection(simulation, state, chunk_index, generated);
}

fn findRandomTickChunkInLookup(state: *const RandomTicks, lookup: []const u16, chunk: geometry.ChunkPos) ?usize {
    const mask = lookup.len - 1;
    var slot = randomTickChunkHash(chunk) & mask;
    for (0..lookup.len) |_| {
        const encoded = lookup[slot];
        if (encoded == 0) return null;
        const index = encoded - 1;
        const existing = state.chunks[index].chunk;
        if (existing.x == chunk.x and existing.z == chunk.z) return index;
        slot = (slot + 1) & mask;
    }
    return null;
}

fn findRandomTickChunk(state: *const RandomTicks, chunk: geometry.ChunkPos) ?usize {
    return findRandomTickChunkInLookup(state, state.lookup, chunk);
}

fn insertRandomTickChunkLookup(state: *const RandomTicks, lookup: []u16, chunk_index: usize) void {
    const mask = lookup.len - 1;
    var slot = randomTickChunkHash(state.chunks[chunk_index].chunk) & mask;
    for (0..lookup.len) |_| {
        if (lookup[slot] == 0) {
            lookup[slot] = @intCast(chunk_index + 1);
            return;
        }
        slot = (slot + 1) & mask;
    }
    diagnostics.panic("random tick chunk lookup capacity exhausted", &.{});
}

fn removeRandomTickChunkLookup(state: *const RandomTicks, lookup: []u16, chunk_index: usize) void {
    const mask = lookup.len - 1;
    const chunk = state.chunks[chunk_index].chunk;
    var slot = randomTickChunkHash(chunk) & mask;
    const encoded: u16 = @intCast(chunk_index + 1);
    for (0..lookup.len) |_| {
        if (lookup[slot] == encoded) break;
        if (lookup[slot] == 0)
            diagnostics.panic("random tick chunk lookup entry missing", &.{});
        slot = (slot + 1) & mask;
    } else diagnostics.panic("random tick chunk lookup probe exhausted", &.{});
    lookup[slot] = 0;
    var cursor = (slot + 1) & mask;
    for (0..lookup.len) |_| {
        if (lookup[cursor] == 0) return;
        const displaced_index: usize = lookup[cursor] - 1;
        lookup[cursor] = 0;
        insertRandomTickChunkLookup(state, lookup, displaced_index);
        cursor = (cursor + 1) & mask;
    }
    diagnostics.panic("random tick chunk lookup cluster is not terminated", &.{});
}

fn releaseRandomTickChunk(state: *RandomTicks, chunk_index: usize) void {
    if (state.chunks[chunk_index].projection_initialized)
        releaseRandomTickActionMasks(state, chunk_index);
    removeRandomTickChunkLookup(state, state.lookup, chunk_index);
    state.chunk_topology_generations[chunk_index] = 0;
    state.chunk_ticket_generations[chunk_index] = 0;
    state.chunk_allocated[chunk_index] = false;
    state.chunks[chunk_index] = undefined;
    state.grass[chunk_index] = undefined;
    state.general[chunk_index] = undefined;
    std.debug.assert(state.free_chunk_count < state.free_chunk_indices.len);
    state.free_chunk_indices[state.free_chunk_count] = @intCast(chunk_index);
    state.free_chunk_count += 1;
}

test "retiring an uninitialized prefetched chunk does not poison the action mask pool" {
    const simulation = try std.heap.page_allocator.create(test_state.State);
    defer std.heap.page_allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 0x7072_6566_6574_6368);
    defer simulation.deinit();
    var dependencies = Dependencies.fromTestState(simulation);

    const state = try std.heap.page_allocator.create(RandomTicks);
    defer std.heap.page_allocator.destroy(state);
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());
    ensureRandomTickActionMaskPool(state);

    const chunk = geometry.ChunkPos{ .x = 41, .z = -27 };
    const chunk_index = resolveRandomTickChunk(&dependencies, state, chunk).?;
    try std.testing.expect(!state.chunks[chunk_index].projection_initialized);
    try std.testing.expectEqual(state.action_masks.len, state.free_action_mask_count);
    try std.testing.expectEqual(@as(usize, 0), state.action_mask_count);

    releaseRandomTickChunk(state, chunk_index);

    try std.testing.expectEqual(state.action_masks.len, state.free_action_mask_count);
    try std.testing.expectEqual(@as(usize, 0), state.action_mask_count);
    try std.testing.expectEqual(@as(?usize, null), findRandomTickChunk(state, chunk));
}

const RandomTickActivation = enum {
    active,
    not_resident,
    capacity,
};

fn randomTickNeighborhoodResident(simulation: *const Dependencies, chunk: geometry.ChunkPos) bool {
    var chunk_z = chunk.z - 1;
    while (chunk_z <= chunk.z + 1) : (chunk_z += 1) {
        var chunk_x = chunk.x - 1;
        while (chunk_x <= chunk.x + 1) : (chunk_x += 1) {
            if (simulation.blocks.residentChunk(simulation.world, .{ .x = chunk_x, .z = chunk_z }) == null) return false;
        }
    }
    return true;
}

fn activateRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, chunk_index: usize, level_type: VanillaChunkLevelType) RandomTickActivation {
    const existing = &state.chunks[chunk_index];
    const chunk = existing.chunk;
    existing.level_type = level_type;
    state.chunk_was_active[chunk_index] = state.chunk_topology_generations[chunk_index] != 0;
    state.chunk_topology_generations[chunk_index] = state.topology_generation;

    const hint: usize = existing.generated_cache_hint;
    const resident = if (hint < simulation.blocks.resident_chunks.len and
        simulation.blocks.resident_chunks[hint].valid and
        geometry.sameChunk(simulation.blocks.resident_chunks[hint].chunk, chunk))
        &simulation.blocks.resident_chunks[hint]
    else resident: {
        const generated = simulation.blocks.residentChunkRef(simulation.world, chunk, simulation.clock.tick) orelse {
            if (existing.projection_initialized) {
                releaseRandomTickActionMasks(state, chunk_index);
                existing.projection_initialized = false;
            }
            return .not_resident;
        };
        existing.generated_cache_hint = generated.index;
        break :resident generated.entry;
    };

    if (!randomTickNeighborhoodResident(simulation, chunk)) return .not_resident;
    if (state.chunk_count == state.active_chunk_indices.len) return .capacity;
    state.active_chunk_indices[state.chunk_count] = @intCast(chunk_index);
    state.chunk_count += 1;

    if (!existing.projection_initialized) {
        existing.observed_content_revision = resident.content_revision;
        initializeRandomTickProjection(simulation, state, chunk_index, resident);
        existing.projection_initialized = true;
        return .active;
    }

    if (existing.observed_content_revision != resident.content_revision) {
        releaseRandomTickActionMasks(state, chunk_index);
        existing.observed_content_revision = resident.content_revision;
        initializeRandomTickProjection(simulation, state, chunk_index, resident);
    }
    return .active;
}

fn activeRandomTickResident(simulation: *const Dependencies, active: *const RandomTickChunk) *const block_store.GeneratedHeightChunk {
    const hint: usize = active.generated_cache_hint;
    if (hint >= simulation.blocks.resident_chunks.len)
        diagnostics.panic("random-tick resident binding is out of range (chunk x, chunk z, resident index, capacity)", &.{
            diagnostics.integer(active.chunk.x),
            diagnostics.integer(active.chunk.z),
            diagnostics.integer(hint),
            diagnostics.integer(simulation.blocks.resident_chunks.len),
        });
    const resident = &simulation.blocks.resident_chunks[hint];
    if (!resident.valid or !geometry.sameChunk(resident.chunk, active.chunk))
        diagnostics.panic("random-tick resident binding points at another chunk (expected x, expected z, resident index, actual x, actual z, valid)", &.{
            diagnostics.integer(active.chunk.x),
            diagnostics.integer(active.chunk.z),
            diagnostics.integer(hint),
            diagnostics.integer(resident.chunk.x),
            diagnostics.integer(resident.chunk.z),
            diagnostics.integer(@intFromBool(resident.valid)),
        });
    return resident;
}

test "active random tick chunks rebind after their resident slot is recycled" {
    const simulation = try std.heap.page_allocator.create(test_state.State);
    defer std.heap.page_allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 0x7265_6269_6e64);
    defer simulation.deinit();
    simulation.generator.mode = .flat;
    var dependencies = Dependencies.fromTestState(simulation);

    const state = try std.heap.page_allocator.create(RandomTicks);
    defer std.heap.page_allocator.destroy(state);
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());
    state.topology_generation = 1;

    const original = geometry.ChunkPos{ .x = 4, .z = -7 };
    const replacement = geometry.ChunkPos{ .x = -91, .z = 53 };
    var neighbor_z = original.z - 1;
    while (neighbor_z <= original.z + 1) : (neighbor_z += 1) {
        var neighbor_x = original.x - 1;
        while (neighbor_x <= original.x + 1) : (neighbor_x += 1)
            _ = simulation.blocks.generatedHeightChunkRef(simulation.world, .{ .x = neighbor_x, .z = neighbor_z }, 0);
    }
    const chunk_index = resolveRandomTickChunk(&dependencies, state, original).?;
    try std.testing.expectEqual(RandomTickActivation.active, activateRandomTickChunk(&dependencies, state, chunk_index, .entity_ticking));
    const recycled_slot = state.chunks[chunk_index].generated_cache_hint;
    try std.testing.expect(simulation.blocks.evictChunk(original));
    const replacement_ref = simulation.blocks.generatedHeightChunkRef(simulation.world, replacement, 1);
    try std.testing.expectEqual(recycled_slot, replacement_ref.index);
    try std.testing.expect(!geometry.sameChunk(replacement_ref.entry.chunk, original));

    state.topology_generation = 2;
    state.chunk_count = 0;
    try std.testing.expectEqual(RandomTickActivation.not_resident, activateRandomTickChunk(&dependencies, state, chunk_index, .entity_ticking));
    try std.testing.expectEqual(@as(usize, 0), state.chunk_count);

    _ = simulation.blocks.generatedHeightChunkRef(simulation.world, original, 2);
    state.topology_generation = 3;
    try std.testing.expectEqual(RandomTickActivation.active, activateRandomTickChunk(&dependencies, state, chunk_index, .entity_ticking));
    const rebound = activeRandomTickResident(&dependencies, &state.chunks[chunk_index]);
    try std.testing.expect(geometry.sameChunk(rebound.chunk, original));
    try std.testing.expect(!geometry.sameChunk(rebound.chunk, replacement));
}

fn resolveRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, chunk: geometry.ChunkPos) ?usize {
    ensureRandomTickChunkPool(state);
    if (findRandomTickChunk(state, chunk)) |chunk_index| return chunk_index;
    if (state.free_chunk_count == 0) return null;
    state.free_chunk_count -= 1;
    const chunk_index: usize = state.free_chunk_indices[state.free_chunk_count];
    const resident = simulation.blocks.residentChunkRef(simulation.world, chunk, simulation.clock.tick);
    state.chunks[chunk_index] = .{
        .chunk = chunk,
        .random_key = randomTickChunkKey(simulation.seed, chunk),
        .generated_cache_hint = if (resident) |generated| generated.index else std.math.maxInt(u16),
        .observed_content_revision = if (resident) |generated| generated.entry.content_revision else 0,
        .level_type = .full,
        .projection_initialized = false,
        .exact_grass_neighborhood = false,
        .base_grass_candidate_source = false,
        .observed_modified_section_mask = 0,
        .section_mask = 0,
        .action_section_mask = 0,
        .base_section_mask = 0,
        .grass_section_mask = 0,
        .ticking_position = random_tick_inactive_position,
        ._padding = undefined,
    };
    state.chunk_allocated[chunk_index] = true;
    insertRandomTickChunkLookup(state, state.lookup, chunk_index);
    return chunk_index;
}

fn insertRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, chunk: geometry.ChunkPos, level_type: VanillaChunkLevelType) bool {
    const chunk_index = resolveRandomTickChunk(simulation, state, chunk) orelse return false;
    const existing = &state.chunks[chunk_index];
    if (state.chunk_topology_generations[chunk_index] == state.topology_generation) {
        if (@intFromEnum(level_type) > @intFromEnum(existing.level_type)) existing.level_type = level_type;
        return true;
    }
    return activateRandomTickChunk(simulation, state, chunk_index, level_type) != .capacity;
}

fn markModifiedNeighborhood(state: *RandomTicks, chunk: geometry.ChunkPos) void {
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const neighbor = geometry.ChunkPos{ .x = chunk.x + dx, .z = chunk.z + dz };
            if (findRandomTickChunk(state, neighbor)) |index| state.chunks[index].exact_grass_neighborhood = true;
        }
    }
}

fn chunkHasGrassSpreadCandidate(simulation: *const Dependencies, active: *const RandomTickChunk) bool {
    const resident: *const block_store.GeneratedHeightChunk = &simulation.blocks.resident_chunks[active.generated_cache_hint];
    if (resident.base_grass_spread_possible) return true;
    var sections = resident.modified_section_mask;
    while (sections != 0) {
        const section: usize = @intCast(@ctz(sections));
        sections &= sections - 1;
        const modified_index = resident.modified_section_indices[section];
        if (modified_index == block_store.no_modified_section_index) continue;
        const modified = &simulation.blocks.modified_sections[modified_index];
        for (modified.modified_bits, 0..) |word, word_index| {
            var remaining = word;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                const local_index: u16 = @intCast(word_index * 64 + bit);
                const pos = geometry.BlockPos{
                    .x = active.chunk.x * 16 + @as(i32, local_index & 15),
                    .y = block_store.sectionWorldY(section, (local_index >> 8) & 15),
                    .z = active.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
                };
                if (simulation.blocks.grassCanSpreadAt(resident, pos)) return true;
                if (pos.y > config.world_min_y) {
                    const below = geometry.BlockPos{ .x = pos.x, .y = pos.y - 1, .z = pos.z };
                    if (simulation.blocks.grassCanSpreadAt(resident, below)) return true;
                }
            }
        }
    }
    return false;
}

fn refreshRandomTickActionBlock(simulation: *const Dependencies, state: *RandomTicks, pos: geometry.BlockPos) void {
    const chunk = geometry.chunkForBlock(pos);
    const active_index = findRandomTickChunk(state, chunk) orelse return;
    const active = &state.chunks[active_index];
    if (!active.projection_initialized) return;
    const resident = residentForRandomTickTicket(simulation, active) orelse return;
    const section = block_store.sectionIndexForY(pos.y) orelse return;
    const local_index = block_store.localBlockIndexForPosition(pos);
    const encoded = resident.modified_section_indices[section];
    const modified_index: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
    const block_state = simulation.blocks.sectionBlockState(resident, section, local_index, modified_index);
    const actionable = randomTickBlockIsActionable(simulation, state, active_index, resident, section, local_index, block_state);
    const section_bit = @as(u32, 1) << @intCast(section);
    var action_handle = state.general[active_index].action_mask_handles[section];
    if (action_handle == 0 and !actionable) {
        refreshRandomTickSectionPresence(simulation, active, resident, section, modified_index);
        active.action_section_mask &= active.section_mask;
        updateRandomTickActionChunkPosition(state, active_index);
        return;
    }
    if (action_handle == 0) {
        if (allocateRandomTickActionMask(state)) |handle| {
            action_handle = handle;
            @memset(&state.action_masks[action_handle - 1], 0);
            state.general[active_index].action_mask_handles[section] = action_handle;
        } else {
            action_handle = random_tick_action_mask_unindexed;
            state.general[active_index].action_mask_handles[section] = action_handle;
        }
        active.action_section_mask |= section_bit;
    }
    if (action_handle == random_tick_action_mask_unindexed) {
        refreshRandomTickModifiedProjection(simulation, state, active_index, resident);
        return;
    }
    const action_mask = &state.action_masks[action_handle - 1];
    const word = local_index / 64;
    const bit = @as(u64, 1) << @intCast(local_index & 63);
    const was_actionable = action_mask[word] & bit != 0;
    if (was_actionable != actionable) {
        if (actionable) {
            action_mask[word] |= bit;
            active.action_section_mask |= section_bit;
        } else {
            action_mask[word] &= ~bit;
            if (randomTickActionMaskIsEmpty(action_mask)) {
                releaseRandomTickActionMask(state, &state.general[active_index].action_mask_handles[section]);
                active.action_section_mask &= ~section_bit;
            }
        }
    }
    refreshRandomTickSectionPresence(simulation, active, resident, section, modified_index);
    active.action_section_mask &= active.section_mask;
    updateRandomTickActionChunkPosition(state, active_index);
}

fn refreshRandomTickSectionPresence(simulation: *const Dependencies, active: *RandomTickChunk, resident: *const block_store.GeneratedHeightChunk, section: usize, modified_index: ?usize) void {
    const section_bit = @as(u32, 1) << @intCast(section);
    const has_random_ticks = if (modified_index) |index|
        simulation.blocks.modified_sections[index].random_tickable_count != 0
    else
        active.base_section_mask & section_bit != 0;
    if (has_random_ticks)
        active.section_mask |= section_bit
    else
        active.section_mask &= ~section_bit;
    active.observed_modified_section_mask = resident.modified_section_mask;
}

fn refreshGrassActionsNearCandidate(simulation: *const Dependencies, state: *RandomTicks, candidate: geometry.BlockPos) void {
    var y_offset: i16 = -1;
    while (y_offset <= 3) : (y_offset += 1) {
        var z_offset: i32 = -1;
        while (z_offset <= 1) : (z_offset += 1) {
            var x_offset: i32 = -1;
            while (x_offset <= 1) : (x_offset += 1) {
                const origin = geometry.BlockPos{ .x = candidate.x + x_offset, .y = candidate.y + y_offset, .z = candidate.z + z_offset };
                if (!player_store.validBuildY(origin.y)) continue;
                const resident = simulation.blocks.residentChunk(simulation.world, geometry.chunkForBlock(origin)) orelse continue;
                const section = block_store.sectionIndexForY(origin.y) orelse continue;
                const encoded = resident.modified_section_indices[section];
                const modified_index: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
                const local_index = block_store.localBlockIndexForPosition(origin);
                const block_state = simulation.blocks.sectionBlockState(resident, section, local_index, modified_index);
                if (registry.randomTickState(block_state).kind != .spreadable) continue;
                refreshRandomTickActionBlock(simulation, state, origin);
            }
        }
    }
}

fn initializeRandomTickNeighborhoods(simulation: *const Dependencies, state: *RandomTicks) void {
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = &state.chunks[chunk_index];
        state.previous_exact_neighborhoods[chunk_index] = active.exact_grass_neighborhood;
        if (!state.chunk_was_active[chunk_index])
            active.base_grass_candidate_source = chunkHasGrassSpreadCandidate(simulation, active);
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        if (!state.chunk_was_active[chunk_index] and active.base_grass_candidate_source)
            markModifiedNeighborhood(state, active.chunk);
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        if (state.chunk_was_active[chunk_index] or active.exact_grass_neighborhood) continue;
        var dz: i32 = -1;
        while (dz <= 1 and !state.chunks[chunk_index].exact_grass_neighborhood) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const neighbor = geometry.ChunkPos{ .x = active.chunk.x + dx, .z = active.chunk.z + dz };
                const neighbor_index = findRandomTickChunk(state, neighbor) orelse continue;
                if (!state.chunks[neighbor_index].base_grass_candidate_source) continue;
                state.chunks[chunk_index].exact_grass_neighborhood = true;
                break;
            }
        }
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        if (active.exact_grass_neighborhood == state.previous_exact_neighborhoods[chunk_index]) continue;
        const resident = &simulation.blocks.resident_chunks[active.generated_cache_hint];
        refreshRandomTickActionProjection(simulation, state, chunk_index, resident);
    }
    state.observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
}

fn blockCanBeGrassCandidate(block_state: i32) bool {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return false;
    return game_data.blockInfo(block_state).default_state == registry.block_dirt_default_state;
}

fn blockObstructsGrass(block_state: i32) bool {
    return block_state >= 0 and block_state < registry.block_state_to_block.len and game_data.preventsGrassSurvival(block_state);
}

fn reconcileRandomTickMutation(simulation: *const Dependencies, state: *RandomTicks, mutation: geometry.BlockMutation) void {
    const chunk = geometry.chunkForBlock(mutation.pos);
    const candidate_changed = blockCanBeGrassCandidate(mutation.previous_state) != blockCanBeGrassCandidate(mutation.block_state);
    const spreadable_changed = registry.randomTickState(mutation.previous_state).kind == .spreadable or
        registry.randomTickState(mutation.block_state).kind == .spreadable;
    var obstruction_candidate: ?geometry.BlockPos = null;
    if (mutation.pos.y > config.world_min_y and blockObstructsGrass(mutation.previous_state) != blockObstructsGrass(mutation.block_state)) {
        const below = geometry.BlockPos{ .x = mutation.pos.x, .y = mutation.pos.y - 1, .z = mutation.pos.z };
        const below_state = simulation.blocks.blockAt(simulation.world, below);
        if (blockCanBeGrassCandidate(below_state) or registry.randomTickState(below_state).kind == .spreadable)
            obstruction_candidate = below;
    }
    if (candidate_changed or spreadable_changed or obstruction_candidate != null) markModifiedNeighborhood(state, chunk);

    refreshRandomTickActionBlock(simulation, state, mutation.pos);
    if (candidate_changed) refreshGrassActionsNearCandidate(simulation, state, mutation.pos);
    if (obstruction_candidate) |candidate| refreshGrassActionsNearCandidate(simulation, state, candidate);
}

fn reconcilePendingRandomTickMutations(simulation: *const Dependencies, state: *RandomTicks) bool {
    const latest = simulation.blocks.block_mutation_sequence;
    const pending = latest -% state.observed_mutation_sequence;
    if (pending > config.max_block_mutation_history) return false;
    for (0..@as(usize, @intCast(pending))) |_| {
        state.observed_mutation_sequence +%= 1;
        if (state.observed_mutation_sequence == 0) state.observed_mutation_sequence = 1;
        reconcileRandomTickMutation(simulation, state, simulation.blocks.blockMutation(state.observed_mutation_sequence));
    }
    return true;
}

fn reconcileLatestRandomTickMutation(simulation: *const Dependencies, state: *RandomTicks) void {
    const latest = simulation.blocks.block_mutation_sequence;
    if (latest == state.observed_mutation_sequence) return;
    if (!reconcilePendingRandomTickMutations(simulation, state)) {
        state.topology_initialized = false;
    }
}

fn finishRandomTickTopologyRebuild(state: *RandomTicks) void {
    for (0..state.chunks.len) |chunk_index| {
        if (!state.chunk_allocated[chunk_index]) continue;
        if (state.chunk_topology_generations[chunk_index] == state.topology_generation or
            state.chunk_ticket_generations[chunk_index] == state.topology_generation) continue;
        releaseRandomTickChunk(state, chunk_index);
    }
}

fn prepareRandomTickTicketGrid(simulation: *Dependencies, state: *RandomTicks, center: RandomTickCenter) bool {
    const slot: usize = center.slot;
    std.debug.assert(slot < state.ticket_grid_handles.len);
    state.ticket_grid_seen_generation[slot] = state.topology_generation;
    if (state.ticket_grid_initialized[slot] and
        state.ticket_grid_center_x[slot] == center.chunk_x and
        state.ticket_grid_center_z[slot] == center.chunk_z) return true;

    const initialized = state.ticket_grid_initialized[slot];
    const delta_x = center.chunk_x - state.ticket_grid_center_x[slot];
    const delta_z = center.chunk_z - state.ticket_grid_center_z[slot];
    var local_z: usize = 0;
    while (local_z < random_tick_ticket_side) : (local_z += 1) {
        const chunk_z = center.chunk_z - random_tick_ticket_radius + @as(i32, @intCast(local_z));
        var local_x: usize = 0;
        while (local_x < random_tick_ticket_side) : (local_x += 1) {
            const old_x = @as(i32, @intCast(local_x)) + delta_x;
            const old_z = @as(i32, @intCast(local_z)) + delta_z;
            var handle = if (initialized and
                old_x >= 0 and old_x < random_tick_ticket_side and
                old_z >= 0 and old_z < random_tick_ticket_side)
                state.ticket_grid_handles[slot][@as(usize, @intCast(old_z)) * random_tick_ticket_side + @as(usize, @intCast(old_x))]
            else
                0;
            const active_cell = local_x != 0 and local_x + 1 != random_tick_ticket_side and
                local_z != 0 and local_z + 1 != random_tick_ticket_side;
            if (handle == 0 and active_cell) {
                const chunk_x = center.chunk_x - random_tick_ticket_radius + @as(i32, @intCast(local_x));
                const chunk_index = resolveRandomTickChunk(simulation, state, .{ .x = chunk_x, .z = chunk_z }) orelse return false;
                handle = @intCast(chunk_index + 1);
            }
            state.ticket_grid_scratch[local_z * random_tick_ticket_side + local_x] = handle;
        }
    }
    @memcpy(&state.ticket_grid_handles[slot], state.ticket_grid_scratch);
    var missing: u16 = 0;
    for (state.ticket_grid_handles[slot]) |handle| missing += @intFromBool(handle == 0);
    state.ticket_grid_missing[slot] = missing;
    state.ticket_grid_prefetch_cursor[slot] = 0;
    state.ticket_grid_center_x[slot] = center.chunk_x;
    state.ticket_grid_center_z[slot] = center.chunk_z;
    state.ticket_grid_initialized[slot] = true;
    return true;
}

fn retainRandomTickTicketGrid(state: *RandomTicks, slot: usize) void {
    const grid = &state.ticket_grid_handles[slot];
    for (0..random_tick_ticket_side) |local_x| {
        const north = grid[local_x];
        const south = grid[(random_tick_ticket_side - 1) * random_tick_ticket_side + local_x];
        if (north != 0) state.chunk_ticket_generations[north - 1] = state.topology_generation;
        if (south != 0) state.chunk_ticket_generations[south - 1] = state.topology_generation;
    }
    for (1..random_tick_ticket_side - 1) |local_z| {
        const west = grid[local_z * random_tick_ticket_side];
        const east = grid[(local_z + 1) * random_tick_ticket_side - 1];
        if (west != 0) state.chunk_ticket_generations[west - 1] = state.topology_generation;
        if (east != 0) state.chunk_ticket_generations[east - 1] = state.topology_generation;
    }
}

fn maintainRandomTickPrefetch(simulation: *Dependencies, state: *RandomTicks) void {
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = &state.chunks[chunk_index];
        const resident_index: usize = active.generated_cache_hint;
        if (resident_index >= simulation.blocks.resident_chunks.len) continue;
        const resident = &simulation.blocks.resident_chunks[resident_index];
        if (resident.valid and geometry.sameChunk(resident.chunk, active.chunk))
            _ = simulation.blocks.ticketResidentIndex(resident_index);
    }
    for (state.centers[0..state.center_count]) |center| {
        var budget: usize = 5;
        const slot: usize = center.slot;
        var remaining: usize = random_tick_ticket_cells;
        while (budget != 0 and state.ticket_grid_missing[slot] != 0 and remaining != 0) : (remaining -= 1) {
            const index: usize = state.ticket_grid_prefetch_cursor[slot];
            state.ticket_grid_prefetch_cursor[slot] = @intCast((index + 1) % random_tick_ticket_cells);
            if (state.ticket_grid_handles[slot][index] != 0) continue;
            const local_x = index % random_tick_ticket_side;
            const local_z = index / random_tick_ticket_side;
            const chunk = geometry.ChunkPos{
                .x = center.chunk_x - random_tick_ticket_radius + @as(i32, @intCast(local_x)),
                .z = center.chunk_z - random_tick_ticket_radius + @as(i32, @intCast(local_z)),
            };
            const chunk_index = resolveRandomTickChunk(simulation, state, chunk) orelse return;
            state.ticket_grid_handles[slot][index] = @intCast(chunk_index + 1);
            state.chunk_ticket_generations[chunk_index] = state.topology_generation;
            state.ticket_grid_missing[slot] -= 1;
            budget -= 1;
        }
    }
}

fn activateRandomTickTicketHandle(simulation: *Dependencies, state: *RandomTicks, encoded: u16, level_type: VanillaChunkLevelType) bool {
    std.debug.assert(encoded != 0);
    const chunk_index: usize = encoded - 1;
    const active = &state.chunks[chunk_index];
    if (state.chunk_topology_generations[chunk_index] == state.topology_generation) {
        if (@intFromEnum(level_type) > @intFromEnum(active.level_type)) active.level_type = level_type;
        return true;
    }
    return activateRandomTickChunk(simulation, state, chunk_index, level_type) != .capacity;
}

fn activateRandomTickTicketRing(simulation: *Dependencies, state: *RandomTicks, grid: *const [random_tick_ticket_cells]u16, radius: usize, level_type: VanillaChunkLevelType) bool {
    const center: usize = random_tick_ticket_radius;
    const first = center - radius;
    const last = center + radius;
    for (first..last + 1) |local_x| {
        if (!activateRandomTickTicketHandle(simulation, state, grid[first * random_tick_ticket_side + local_x], level_type)) return false;
        if (!activateRandomTickTicketHandle(simulation, state, grid[last * random_tick_ticket_side + local_x], level_type)) return false;
    }
    for (first + 1..last) |local_z| {
        if (!activateRandomTickTicketHandle(simulation, state, grid[local_z * random_tick_ticket_side + first], level_type)) return false;
        if (!activateRandomTickTicketHandle(simulation, state, grid[local_z * random_tick_ticket_side + last], level_type)) return false;
    }
    return true;
}

fn rebuildRandomTickActionChunkPositions(state: *RandomTicks) void {
    @memset(state.action_chunk_positions, 0);
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index|
        state.chunks[chunk_index].ticking_position = random_tick_inactive_position;
    for (state.active_chunk_indices[0..state.ticking_chunk_count], 0..) |chunk_index, position| {
        state.chunks[chunk_index].ticking_position = @intCast(position);
        updateRandomTickActionChunkPosition(state, chunk_index);
    }
}

fn rebuildRandomTickChunks(simulation: *Dependencies, state: *RandomTicks, radius: i32) void {
    const previous_center_count = state.center_count;
    var previous_center_slots: [config.max_players]u16 = undefined;
    for (state.centers[0..previous_center_count], 0..) |center, index| previous_center_slots[index] = center.slot;
    beginTopologyRebuild(simulation, state);
    collectRandomTickCenters(simulation, state, previous_center_slots[0..previous_center_count]);
    if (!prepareRandomTickGrids(simulation, state) or !activateRandomTickTickets(simulation, state, radius)) {
        state.overflow = true;
        return;
    }
    {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_retirement);
        defer trace.end();
        finishRandomTickTopologyRebuild(state);
    }
    {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_neighborhoods);
        defer trace.end();
        initializeRandomTickNeighborhoods(simulation, state);
    }
    rebuildRandomTickActionChunkPositions(state);
}

fn beginTopologyRebuild(simulation: *Dependencies, state: *RandomTicks) void {
    state.topology_generation +%= 1;
    if (state.topology_generation == 0) {
        @memset(state.chunk_topology_generations, 0);
        @memset(state.chunk_ticket_generations, 0);
        @memset(state.ticket_grid_initialized, false);
        @memset(state.ticket_grid_seen_generation, 0);
        state.topology_generation = 1;
    }
    state.resident_binding_revision = simulation.blocks.resident_binding_revision;
    state.topology_initialized = true;
    state.overflow = false;
    @memset(state.action_chunk_positions, 0);
    for (0..state.chunks.len) |chunk_index| {
        if (state.chunk_allocated[chunk_index]) state.chunks[chunk_index].ticking_position = random_tick_inactive_position;
    }
    state.center_count = 0;
    state.ticking_chunk_count = 0;
    state.chunk_count = 0;
}

fn collectRandomTickCenters(simulation: *Dependencies, state: *RandomTicks, previous_slots: []const u16) void {
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator) continue;
        const center_x = @divFloor(geometry.blockCoord(player.position.x), 16);
        const center_z = @divFloor(geometry.blockCoord(player.position.z), 16);
        state.centers[state.center_count] = .{ .slot = slot, .chunk_x = center_x, .chunk_z = center_z };
        state.ticket_grid_seen_generation[slot] = state.topology_generation;
        state.center_count += 1;
    }
    for (previous_slots) |slot| {
        if (state.ticket_grid_seen_generation[slot] != state.topology_generation)
            state.ticket_grid_initialized[slot] = false;
    }
}

fn prepareRandomTickGrids(simulation: *Dependencies, state: *RandomTicks) bool {
    var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_ticket_grids);
    defer trace.end();
    for (state.centers[0..state.center_count]) |center| {
        if (!prepareRandomTickTicketGrid(simulation, state, center)) return false;
        retainRandomTickTicketGrid(state, center.slot);
    }
    return true;
}

fn activateRandomTickTickets(simulation: *Dependencies, state: *RandomTicks, radius: i32) bool {
    var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_activation);
    defer trace.end();
    const offset: usize = @intCast(random_tick_ticket_radius - radius);
    const side: usize = @intCast(radius * 2 + 1);
    for (state.centers[0..state.center_count]) |center| {
        const grid = &state.ticket_grid_handles[center.slot];
        for (0..side) |local_z| {
            const row = (offset + local_z) * random_tick_ticket_side + offset;
            for (grid[row..][0..side]) |handle|
                if (!activateRandomTickTicketHandle(simulation, state, handle, .entity_ticking)) return false;
        }
    }
    state.ticking_chunk_count = state.chunk_count;
    for (state.centers[0..state.center_count]) |center| {
        const grid = &state.ticket_grid_handles[center.slot];
        if (!activateRandomTickTicketRing(simulation, state, grid, @intCast(radius + 1), .block_ticking) or
            !activateRandomTickTicketRing(simulation, state, grid, @intCast(radius + 2), .full)) return false;
    }
    return true;
}

test "random tick tickets never generate non-resident chunks" {
    const simulation = try std.heap.page_allocator.create(test_state.State);
    defer std.heap.page_allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 0x7265_7369_6465_6e74);
    defer simulation.deinit();
    simulation.generator.mode = .flat;
    simulation.players.records[0].state = .play;
    simulation.players.records[0].position = .{ .x = 0.5, .y = 65, .z = 0.5 };
    simulation.players.rebuildActive();

    const state = try std.heap.page_allocator.create(RandomTicks);
    defer std.heap.page_allocator.destroy(state);
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());
    var dependencies = Dependencies.fromTestState(simulation);

    rebuildRandomTickChunks(&dependencies, state, entityTickingRadius(config.simulation_distance_chunks));

    try std.testing.expect(!state.overflow);
    try std.testing.expectEqual(@as(usize, 0), state.chunk_count);
    try std.testing.expectEqual(@as(usize, 0), state.ticking_chunk_count);
    try std.testing.expectEqual(@as(usize, 0), simulation.blocks.residentChunkCount());
}

fn runRandomTickSection(
    simulation: *Dependencies,
    state: *RandomTicks,
    behaviors: *const Behaviors,
    active_index: usize,
    section: usize,
    outputs: *Packets,
    changes: *usize,
    workload: *RandomTickWorkload,
    sample_tick_key: u32,
) bool {
    const active = &state.chunks[active_index];
    const resident = activeRandomTickResident(simulation, active);
    var modified_index: ?usize = undefined;
    var modified_index_initialized = false;
    var observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
    workload.action_sections += 1;
    workload.coordinate_probes += simulation.rules.random_tick_speed;
    if (state.general[active_index].action_mask_handles[section] == random_tick_action_mask_unindexed)
        workload.unindexed_sections += 1;
    var first_sample: u16 = 0;
    while (first_sample < simulation.rules.random_tick_speed) : (first_sample += 4) {
        const samples = randomTickSamplesForTickKey(active.random_key, sample_tick_key, section, first_sample);
        const lane_count: u16 = @min(4, simulation.rules.random_tick_speed - first_sample);
        for (samples[0..lane_count], 0..) |sample_bits, lane| {
            const local_index = sample_bits & (block_store.blocks_per_section - 1);
            const action_handle = state.general[active_index].action_mask_handles[section];
            if (action_handle != 0 and action_handle != random_tick_action_mask_unindexed) {
                const word = state.action_masks[action_handle - 1][local_index / 64];
                if (word & (@as(u64, 1) << @intCast(local_index & 63)) == 0) continue;
            }
            if (!modified_index_initialized) {
                const encoded = resident.modified_section_indices[section];
                modified_index = if (encoded == block_store.no_modified_section_index) null else encoded;
                modified_index_initialized = true;
            }
            const selected_state = simulation.blocks.sectionBlockState(resident, section, local_index, modified_index);
            if (selected_state < 0 or selected_state >= registry.block_state_to_block.len)
                diagnostics.panic("invalid selected random-tick state (state, chunk x, chunk z, section, local index)", &.{ diagnostics.integer(selected_state), diagnostics.integer(active.chunk.x), diagnostics.integer(active.chunk.z), diagnostics.integer(section), diagnostics.integer(local_index) });
            if ((action_handle == 0 or action_handle == random_tick_action_mask_unindexed) and
                !randomTickBlockIsActionable(simulation, state, active_index, resident, section, local_index, selected_state)) continue;
            workload.action_hits += 1;
            const saved_random = simulation.random.random;
            simulation.random.random = world_random.DeterministicRng.init(randomTickEventSeed(
                simulation.seed,
                simulation.clock.tick,
                active.random_key,
                section,
                first_sample + @as(u16, @intCast(lane)),
            ));
            const stopped = randomTickSelectedBlock(simulation, state, behaviors, active_index, resident, active.chunk, section, local_index, selected_state, true, outputs, changes);
            simulation.random.random = saved_random;
            if (stopped) return true;
            if (simulation.blocks.block_mutation_sequence != observed_mutation_sequence) {
                observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
                const encoded = resident.modified_section_indices[section];
                modified_index = if (encoded == block_store.no_modified_section_index) null else encoded;
            }
        }
    }
    return false;
}

fn runRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, active_index: usize, outputs: *Packets, changes: *usize, workload: *RandomTickWorkload, sample_tick_key: u32) bool {
    workload.action_chunks += 1;
    var processed_sections: u32 = 0;
    var remaining_sections = state.chunks[active_index].action_section_mask;
    while (remaining_sections != 0) {
        const section: usize = @intCast(@ctz(remaining_sections));
        const section_bit = @as(u32, 1) << @intCast(section);
        processed_sections |= section_bit;
        if (runRandomTickSection(simulation, state, behaviors, active_index, section, outputs, changes, workload, sample_tick_key)) return true;
        remaining_sections = state.chunks[active_index].action_section_mask & ~processed_sections;
    }
    return false;
}

fn nextRandomTickActionChunkPosition(state: *const RandomTicks, first: usize) ?usize {
    if (first >= state.ticking_chunk_count) return null;
    var word_index = first / 64;
    var word = state.action_chunk_positions[word_index] &
        (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(first & 63)));
    while (word_index < state.action_chunk_positions.len and
        word_index * 64 < state.ticking_chunk_count)
    {
        if (word != 0) {
            const position = word_index * 64 + @ctz(word);
            return if (position < state.ticking_chunk_count) position else null;
        }
        word_index += 1;
        word = state.action_chunk_positions[word_index];
    }
    return null;
}

test "ordered action chunk traversal observes later additions without revisiting earlier positions" {
    const state = try std.heap.page_allocator.create(RandomTicks);
    defer std.heap.page_allocator.destroy(state);
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());
    state.ticking_chunk_count = 130;
    state.action_chunk_positions[0] = (@as(u64, 1) << 1);
    state.action_chunk_positions[1] = (@as(u64, 1) << (70 - 64));
    try std.testing.expectEqual(@as(?usize, 1), nextRandomTickActionChunkPosition(state, 0));

    state.action_chunk_positions[0] |= (@as(u64, 1) << 0) | (@as(u64, 1) << 50);
    try std.testing.expectEqual(@as(?usize, 50), nextRandomTickActionChunkPosition(state, 2));
    try std.testing.expectEqual(@as(?usize, 70), nextRandomTickActionChunkPosition(state, 51));
    try std.testing.expectEqual(@as(?usize, null), nextRandomTickActionChunkPosition(state, 71));
}

fn runRandomTicks(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, outputs: *Packets) void {
    const radius = entityTickingRadius(config.simulation_distance_chunks);
    if (activeChunkRowBounds(simulation.players, simulation.world, radius) == null) return;
    behaviors.scheduled.apply(simulation, state, outputs);
    if (!simulation.rules.do_random_ticks) return;
    // ServerChunkLoadingManager.forEachBlockTickingChunk in 1.21.8 iterates
    // the simulation propagator's ENTITY_TICKING set (level <= 31).
    const topology_matches = topology_matches: {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_check);
        defer trace.end();
        break :topology_matches randomTickTopologyMatches(simulation, state);
    };
    if (!topology_matches or state.resident_binding_revision != simulation.blocks.resident_binding_revision) {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_rebuild);
        defer trace.end();
        rebuildRandomTickChunks(simulation, state, radius);
    }
    if (!state.overflow and state.observed_mutation_sequence != simulation.blocks.block_mutation_sequence) {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.mutation_reconcile);
        defer trace.end();
        if (!reconcilePendingRandomTickMutations(simulation, state)) rebuildRandomTickChunks(simulation, state, radius);
    }
    if (!state.overflow) maintainRandomTickPrefetch(simulation, state);
    const can_spread = true;
    var changes: usize = 0;
    var workload: RandomTickWorkload = .{};
    const sample_tick_key = randomTickSampleTickKey(simulation.clock.tick);
    defer {
        plugin_profiler.countTrace(RandomTickTrace.action_chunks, workload.action_chunks);
        plugin_profiler.countTrace(RandomTickTrace.action_sections, workload.action_sections);
        plugin_profiler.countTrace(RandomTickTrace.coordinate_probes, workload.coordinate_probes);
        plugin_profiler.countTrace(RandomTickTrace.action_hits, workload.action_hits);
        plugin_profiler.countTrace(RandomTickTrace.unindexed_sections, workload.unindexed_sections);
    }
    var chunk_walk_trace = plugin_profiler.beginTrace(RandomTickTrace.chunk_walk);
    defer chunk_walk_trace.end();
    if (!state.overflow) {
        var first_position: usize = 0;
        for (0..state.active_chunk_indices.len) |_| {
            const position = nextRandomTickActionChunkPosition(state, first_position) orelse break;
            first_position = position + 1;
            const active_index = state.active_chunk_indices[position];
            if (runRandomTickChunk(simulation, state, behaviors, active_index, outputs, &changes, &workload, sample_tick_key)) return;
        } else diagnostics.panic("random tick action walk exceeded its chunk capacity", &.{});
        return;
    }

    runRandomTicksOverflow(simulation, state, behaviors, outputs, &changes, radius, can_spread);
}

fn runRandomTicksOverflow(
    simulation: *Dependencies,
    state: *RandomTicks,
    behaviors: *const Behaviors,
    outputs: *Packets,
    changes: *usize,
    radius: i32,
    can_spread: bool,
) void {
    const bounds = activeChunkRowBounds(simulation.players, simulation.world, radius) orelse return;
    var intervals: [config.max_players]ChunkInterval = undefined;
    var chunk_z = bounds.first;
    while (chunk_z <= bounds.last) : (chunk_z += 1) {
        const interval_count = chunkRowIntervals(simulation.players, simulation.world, chunk_z, radius, &intervals);
        if (interval_count == 0) continue;
        var interval_index: usize = 0;
        var first_x = intervals[0].first;
        var last_x = intervals[0].last;
        for (0..interval_count) |_| {
            interval_index += 1;
            if (interval_index < interval_count and intervals[interval_index].first <= last_x +| 1) {
                last_x = @max(last_x, intervals[interval_index].last);
                continue;
            }
            var chunk_x = first_x;
            while (chunk_x <= last_x) : (chunk_x += 1) {
                const chunk = geometry.ChunkPos{ .x = chunk_x, .z = chunk_z };
                if (randomTickOverflowChunk(simulation, state, behaviors, chunk, randomTickChunkKey(simulation.seed, chunk), can_spread, outputs, changes)) return;
            }
            if (interval_index == interval_count) break;
            first_x = intervals[interval_index].first;
            last_x = intervals[interval_index].last;
        }
    }
}

fn grassHasSpreadCandidateNear(simulation: *const Dependencies, state: *const RandomTicks, active_index: usize, origin: geometry.BlockPos) bool {
    var y_offset: i16 = -3;
    while (y_offset <= 1) : (y_offset += 1) {
        var z_offset: i32 = -1;
        while (z_offset <= 1) : (z_offset += 1) {
            var x_offset: i32 = -1;
            while (x_offset <= 1) : (x_offset += 1) {
                const candidate = geometry.BlockPos{ .x = origin.x + x_offset, .y = origin.y + y_offset, .z = origin.z + z_offset };
                if (!player_store.validBuildY(candidate.y)) continue;
                const resident = randomTickResidentFor(simulation, state, active_index, candidate) orelse continue;
                if (simulation.blocks.grassCanSpreadAt(resident, candidate)) return true;
            }
        }
    }
    return false;
}

fn randomTickBlockIsActionable(
    simulation: *const Dependencies,
    state: *const RandomTicks,
    active_index: ?usize,
    resident: *const block_store.GeneratedHeightChunk,
    section: usize,
    local_index: u16,
    block_state: i32,
) bool {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return false;
    const behavior: *const registry.RandomTickState = registry.randomTickState(block_state);
    return switch (behavior.kind) {
        .none, .mud => false,
        .leaves => isDecayingOakLeaves(block_state),
        .spreadable => blk: {
            const pos = geometry.BlockPos{
                .x = resident.chunk.x * 16 + @as(i32, local_index & 15),
                .y = block_store.sectionWorldY(section, (local_index >> 8) & 15),
                .z = resident.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
            };
            if (simulation.blocks.grassAboveIsBlocked(resident, pos)) break :blk true;
            if (active_index == null) break :blk true;
            const index = active_index.?;
            if (!state.chunks[index].exact_grass_neighborhood) break :blk false;
            break :blk grassHasSpreadCandidateNear(simulation, state, index, pos);
        },
        else => true,
    };
}

fn countRandomTickActions(simulation: *const Dependencies, state: *const RandomTicks, active_index: ?usize, resident: *const block_store.GeneratedHeightChunk, section: usize, modified_index: ?usize, output: ?*[block_store.blocks_per_section / 64]u64) u16 {
    if (output) |mask| @memset(mask, 0);
    const section_bit = @as(u32, 1) << @intCast(section);
    if (active_index != null and modified_index == null and state.chunks[active_index.?].grass_section_mask & section_bit != 0) {
        const index = active_index.?;
        var count: u16 = 0;
        for (resident.heights, 0..) |height, column| {
            const local_y: u16 = @intCast((@as(i32, height) - @as(i32, config.world_min_y)) & 15);
            if (height != block_store.sectionWorldY(section, local_y)) continue;
            const blocked = state.grass[index].grass_above_blocked[column / 64] & (@as(u64, 1) << @intCast(column & 63)) != 0;
            const local_index: u16 = @intCast(column | (@as(usize, local_y) << 8));
            const pos = geometry.BlockPos{
                .x = resident.chunk.x * 16 + @as(i32, local_index & 15),
                .y = block_store.sectionWorldY(section, local_y),
                .z = resident.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
            };
            if (blocked or (state.chunks[index].exact_grass_neighborhood and grassHasSpreadCandidateNear(simulation, state, index, pos))) {
                if (output) |mask| {
                    mask[local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
                }
                count += 1;
            }
        }
        return count;
    }

    var count: u16 = 0;
    for (0..block_store.blocks_per_section) |raw_index| {
        const local_index: u16 = @intCast(raw_index);
        const block_state = simulation.blocks.sectionRandomTickBlockState(resident, section, local_index, modified_index) orelse continue;
        if (randomTickBlockIsActionable(simulation, state, active_index, resident, section, local_index, block_state)) {
            if (output) |mask| mask[local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
            count += 1;
        }
    }
    return count;
}

fn refreshRandomTickActionProjection(simulation: *const Dependencies, state: *RandomTicks, active_index: usize, resident: *const block_store.GeneratedHeightChunk) void {
    const active = &state.chunks[active_index];
    active.action_section_mask = 0;
    var scratch: [block_store.blocks_per_section / 64]u64 = undefined;
    for (0..config.overworld_section_count) |section| {
        const section_bit = @as(u32, 1) << @intCast(section);
        const handle = &state.general[active_index].action_mask_handles[section];
        if (active.section_mask & section_bit == 0) {
            releaseRandomTickActionMask(state, handle);
            continue;
        }
        const encoded = resident.modified_section_indices[section];
        const modified_index: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
        const count = countRandomTickActions(simulation, state, active_index, resident, section, modified_index, &scratch);
        if (count == 0) {
            releaseRandomTickActionMask(state, handle);
            continue;
        }
        active.action_section_mask |= section_bit;
        if (handle.* == 0 or handle.* == random_tick_action_mask_unindexed) {
            releaseRandomTickActionMask(state, handle);
            handle.* = allocateRandomTickActionMask(state) orelse random_tick_action_mask_unindexed;
        }
        if (handle.* != random_tick_action_mask_unindexed)
            @memcpy(&state.action_masks[handle.* - 1], &scratch);
    }
    updateRandomTickActionChunkPosition(state, active_index);
}

fn randomTickOverflowChunk(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, chunk: geometry.ChunkPos, chunk_key: u32, can_spread: bool, outputs: *Packets, changes: *usize) bool {
    if (!randomTickNeighborhoodResident(simulation, chunk)) return false;
    const generated_heights = simulation.blocks.residentChunk(simulation.world, chunk) orelse return false;
    var remaining_sections = generated_heights.random_tick_sections | generated_heights.modified_section_mask;
    var observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
    while (remaining_sections != 0) {
        const section: usize = @intCast(@ctz(remaining_sections));
        remaining_sections &= remaining_sections - 1;
        const section_bit = @as(u32, 1) << @intCast(section);
        var modified_index: ?usize = if (generated_heights.modified_section_mask & section_bit == 0)
            null
        else
            simulation.blocks.modifiedSectionIndex(generated_heights, section);

        var first_sample: u16 = 0;
        while (first_sample < simulation.rules.random_tick_speed) : (first_sample += 4) {
            const samples = randomTickSamples(chunk_key, simulation.clock.tick, section, first_sample);
            const lane_count: u16 = @min(4, simulation.rules.random_tick_speed - first_sample);
            for (samples[0..lane_count], 0..) |sample_bits, lane| {
                const local_index = sample_bits & (block_store.blocks_per_section - 1);
                const selected_state = simulation.blocks.sectionBlockState(generated_heights, section, local_index, modified_index);
                if (selected_state < 0 or selected_state >= registry.block_state_to_block.len)
                    diagnostics.panic("invalid selected random-tick state (state, chunk x, chunk z, section, local index)", &.{ diagnostics.integer(selected_state), diagnostics.integer(chunk.x), diagnostics.integer(chunk.z), diagnostics.integer(section), diagnostics.integer(local_index) });
                if (!randomTickBlockIsActionable(simulation, state, null, generated_heights, section, local_index, selected_state)) continue;
                const block_state: ?i32 = selected_state;
                const saved_random = simulation.random.random;
                simulation.random.random = world_random.DeterministicRng.init(randomTickEventSeed(
                    simulation.seed,
                    simulation.clock.tick,
                    chunk_key,
                    section,
                    first_sample + @as(u16, @intCast(lane)),
                ));
                const stopped = randomTickSelectedBlock(simulation, state, behaviors, null, generated_heights, chunk, section, local_index, block_state, can_spread, outputs, changes);
                simulation.random.random = saved_random;
                if (stopped) return true;
                if (simulation.blocks.block_mutation_sequence != observed_mutation_sequence) {
                    observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
                    const encoded = generated_heights.modified_section_indices[section];
                    modified_index = if (encoded == block_store.no_modified_section_index) null else encoded;
                    const processed = if (section == 31)
                        std.math.maxInt(u32)
                    else
                        (@as(u32, 1) << @intCast(section + 1)) - 1;
                    remaining_sections = (generated_heights.random_tick_sections | generated_heights.modified_section_mask) & ~processed;
                }
            }
        }
        // A behavior can add or remove a later tickable section. Vanilla sees
        // the authoritative ascending section set immediately, but never
        // revisits an earlier section in the same chunk.
        if (simulation.blocks.block_mutation_sequence != observed_mutation_sequence) {
            const processed = if (section == 31)
                std.math.maxInt(u32)
            else
                (@as(u32, 1) << @intCast(section + 1)) - 1;
            observed_mutation_sequence = simulation.blocks.block_mutation_sequence;
            remaining_sections = (generated_heights.random_tick_sections | generated_heights.modified_section_mask) & ~processed;
        }
    }
    return false;
}

test "overflow random ticks defer chunks without a resident neighborhood" {
    const simulation = try std.heap.page_allocator.create(test_state.State);
    defer std.heap.page_allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 0x7061_6769_6e67_5f72);
    defer simulation.deinit();

    var dependencies = Dependencies.fromTestState(simulation);
    var state: RandomTicks = undefined;
    var behaviors: Behaviors = undefined;
    var outputs: Packets = undefined;
    var changes: usize = 0;
    try std.testing.expect(!randomTickOverflowChunk(
        &dependencies,
        &state,
        &behaviors,
        .{ .x = -1, .z = -2 },
        0,
        true,
        &outputs,
        &changes,
    ));
}

const RandomTickInvocation = struct {
    simulation: *Dependencies,
    scheduler: *RandomTicks,
    origin_chunk_index: ?usize,
    origin: *const block_store.GeneratedHeightChunk,
    pos: geometry.BlockPos,
    block_state: i32,
    behavior: *const registry.RandomTickState,
    can_spread: bool,
    outputs: *Packets,
    changes: *usize,
};

fn randomTickSelectedBlock(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, active_index: ?usize, generated: *const block_store.GeneratedHeightChunk, chunk: geometry.ChunkPos, section: usize, local_index: u16, selected: ?i32, can_spread: bool, outputs: *Packets, changes: *usize) bool {
    if (selected == null) {
        @branchHint(.likely);
        return false;
    }
    const block_state: i32 = selected.?;
    const pos = geometry.BlockPos{
        .x = chunk.x * 16 + @as(i32, @intCast(local_index & 15)),
        .y = block_store.sectionWorldY(section, (local_index >> 8) & 15),
        .z = chunk.z * 16 + @as(i32, @intCast((local_index >> 4) & 15)),
    };
    const behavior: *const registry.RandomTickState = registry.randomTickState(block_state);
    var tick = RandomTickInvocation{ .simulation = simulation, .scheduler = state, .origin_chunk_index = active_index, .origin = generated, .pos = pos, .block_state = block_state, .behavior = behavior, .can_spread = can_spread, .outputs = outputs, .changes = changes };
    switch (behavior.kind) {
        .none => {},
        .crop, .stem, .cocoa, .nether_wart, .sweet_berry_bush => behaviors.crops.apply(&tick),
        .cactus, .sugar_cane, .kelp, .bamboo, .bamboo_sapling, .chorus_flower, .mangrove_propagule, .sapling => behaviors.growth.apply(&tick),
        .spreadable, .mushroom, .vine, .nylium => behaviors.spread.apply(&tick),
        .farmland, .mud, .pointed_dripstone => behaviors.farmland.apply(&tick),
        .leaves => behaviors.leaves.apply(&tick),
        .lava => behaviors.fire_and_lava.apply(&tick),
        .ice, .snow => behaviors.ice_and_snow.apply(&tick),
        .copper => behaviors.copper.apply(&tick),
        .redstone_ore, .nether_portal, .turtle_egg, .budding_amethyst => behaviors.block_events.apply(&tick),
    }
    return (changes.* == config.max_random_tick_block_changes_per_tick);
}

const farmland_block_id = registry.block_state_to_block[@intCast(registry.state_farmland_moisture_0)];
const water_block_id = registry.block_state_to_block[@intCast(registry.state_water_level_0)];
const cactus_default_state = registry.state_cactus_age_0;
const cactus_block_id = registry.block_state_to_block[@intCast(cactus_default_state)];
const sugar_cane_default_state = registry.state_sugar_cane_age_0;
const sugar_cane_block_id = registry.block_state_to_block[@intCast(sugar_cane_default_state)];
const kelp_plant_default_state = registry.state_kelp_plant;
const bamboo_default_state = registry.state_bamboo_none_stage_0;
const bamboo_small_state = registry.state_bamboo_small_stage_0;
const bamboo_large_state = registry.state_bamboo_large_stage_0;
const bamboo_block_id = registry.block_state_to_block[@intCast(bamboo_default_state)];
const chorus_plant_default_state = registry.state_chorus_plant_empty;
const chorus_flower_dead_state = registry.state_chorus_flower_age_5;
const end_stone_block_id = registry.block_state_to_block[@intCast(registry.state_end_stone)];
const chorus_plant_block_id = registry.block_state_to_block[@intCast(chorus_plant_default_state)];
const fire_default_state = registry.state_fire_age_0_empty;
const fire_block_id = registry.block_state_to_block[@intCast(fire_default_state)];
const netherrack_block_id = registry.block_state_to_block[@intCast(registry.state_netherrack)];
const cauldron_block_id = registry.block_state_to_block[@intCast(registry.state_cauldron)];
const water_cauldron_level_one = registry.state_water_cauldron_level_1;
const clay_default_state = registry.state_clay;
const mud_block_id = registry.block_state_to_block[@intCast(registry.state_mud)];
const pointed_dripstone_min_state = game_data.blockInfo(registry.state_pointed_dripstone_tip_down_dry).min_state;
const vine_min_state = game_data.blockInfo(registry.state_vine_empty).min_state;
const sand_block_id = registry.block_state_to_block[@intCast(registry.state_sand)];
const pumpkin_stem_block_id = registry.block_state_to_block[@intCast(registry.state_pumpkin_stem_age_0)];
const melon_stem_block_id = registry.block_state_to_block[@intCast(registry.state_melon_stem_age_0)];
const pumpkin_default_state = registry.state_pumpkin;
const melon_default_state = registry.state_melon;
const attached_pumpkin_stem_min_state = game_data.blockInfo(registry.state_attached_pumpkin_stem_north).min_state;
const attached_melon_stem_min_state = game_data.blockInfo(registry.state_attached_melon_stem_north).min_state;
const small_amethyst_min_state = game_data.blockInfo(registry.state_small_amethyst_bud_north_dry).min_state;
const medium_amethyst_min_state = game_data.blockInfo(registry.state_medium_amethyst_bud_north_dry).min_state;
const large_amethyst_min_state = game_data.blockInfo(registry.state_large_amethyst_bud_north_dry).min_state;
const amethyst_cluster_min_state = game_data.blockInfo(registry.state_amethyst_cluster_north_dry).min_state;

fn applyRandomTickChange(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) void {
    const blocks = block_writer.Writer.init(simulation.blocks, outputs);
    if (!(blocks.set(simulation.world, pos, block_state) catch false)) return;
    if (blockId(block_state) == fire_block_id) scheduleFire(simulation, pos);
    changes.* += 1;
    reconcileLatestRandomTickMutation(simulation, state);
}

fn randomTickAgeChance(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, next_state: i32, bound: u32, outputs: *Packets, changes: *usize) void {
    if (next_state >= 0 and simulation.random.random.nextIntBounded(bound) == 0)
        applyRandomTickChange(simulation, state, pos, next_state, outputs, changes);
}

fn cropAvailableMoisture(simulation: *Dependencies, pos: geometry.BlockPos, crop_block_id: u16) f32 {
    var moisture: f32 = 1;
    var z_offset: i32 = -1;
    while (z_offset <= 1) : (z_offset += 1) {
        var x_offset: i32 = -1;
        while (x_offset <= 1) : (x_offset += 1) {
            const farmland_pos = geometry.BlockPos{ .x = pos.x + x_offset, .y = pos.y - 1, .z = pos.z + z_offset };
            const farmland_state = simulation.blocks.blockAt(simulation.world, farmland_pos);
            var contribution: f32 = 0;
            if (blockId(farmland_state) == farmland_block_id) {
                contribution = if (registry.randomTickState(farmland_state).moisture > 0) 3 else 1;
                if (x_offset != 0 or z_offset != 0) contribution /= 4;
            }
            moisture += contribution;
        }
    }
    const west_or_east = blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x - 1, .y = pos.y, .z = pos.z })) == crop_block_id or
        blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x + 1, .y = pos.y, .z = pos.z })) == crop_block_id;
    const north_or_south = blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
        blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y, .z = pos.z + 1 })) == crop_block_id;
    if (west_or_east and north_or_south) {
        moisture /= 2;
    } else {
        const diagonal = blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x - 1, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
            blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x + 1, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
            blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x + 1, .y = pos.y, .z = pos.z + 1 })) == crop_block_id or
            blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x - 1, .y = pos.y, .z = pos.z + 1 })) == crop_block_id;
        if (diagonal) moisture /= 2;
    }
    return moisture;
}

fn randomTickCrop(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (blockId(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != farmland_block_id) {
        applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        return;
    }
    if (behavior.next_age < 0 or baseLightAt(simulation, pos) < 9) return;
    const current = simulation.blocks.blockAt(simulation.world, pos);
    const moisture = cropAvailableMoisture(simulation, pos, blockId(current));
    const bound: u32 = @intFromFloat(@floor(25.0 / moisture) + 1.0);
    if (simulation.random.random.nextIntBounded(bound) == 0)
        applyRandomTickChange(simulation, state, pos, behavior.next_age, outputs, changes);
}

fn randomTickFarmland(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, moisture: i8, outputs: *Packets, changes: *usize) void {
    if (farmlandHasWater(simulation, pos)) {
        if (moisture < 7) applyRandomTickChange(simulation, state, pos, block_state + 7 - moisture, outputs, changes);
        return;
    }
    if (moisture > 0) {
        applyRandomTickChange(simulation, state, pos, block_state - 1, outputs, changes);
        return;
    }
    if (!blockMaintainsFarmland(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y + 1, .z = pos.z })))
        applyRandomTickChange(simulation, state, pos, registry.block_dirt_default_state, outputs, changes);
}

fn farmlandHasWater(simulation: *Dependencies, pos: geometry.BlockPos) bool {
    var y_offset: i16 = 0;
    while (y_offset <= 1) : (y_offset += 1) {
        var z_offset: i32 = -4;
        while (z_offset <= 4) : (z_offset += 1) {
            var x_offset: i32 = -4;
            while (x_offset <= 4) : (x_offset += 1) {
                if (blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x + x_offset, .y = pos.y + y_offset, .z = pos.z + z_offset })) == water_block_id)
                    return true;
            }
        }
    }
    return false;
}

fn blockMaintainsFarmland(block_state: i32) bool {
    return switch (registry.randomTickState(block_state).kind) {
        .crop, .stem => true,
        else => false,
    };
}

fn randomTickColumnPlant(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, age: i8, plant_block_id: u16, default_state: i32, outputs: *Packets, changes: *usize) void {
    const above = geometry.BlockPos{ .x = pos.x, .y = pos.y + 1, .z = pos.z };
    if (simulation.blocks.blockAt(simulation.world, above) != registry.block_air_default_state) return;
    var height: u8 = 1;
    while (height < 3 and blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y - @as(i16, height), .z = pos.z })) == plant_block_id) : (height += 1) {}
    if (height >= 3) return;
    if (age == 15) {
        applyRandomTickChange(simulation, state, above, default_state, outputs, changes);
        if (changes.* < config.max_random_tick_block_changes_per_tick)
            applyRandomTickChange(simulation, state, pos, block_state - 15, outputs, changes);
    } else {
        applyRandomTickChange(simulation, state, pos, block_state + 1, outputs, changes);
    }
}

fn blockLightAt(simulation: *Dependencies, pos: geometry.BlockPos) u8 {
    var light = game_data.blockInfo(simulation.blocks.blockAt(simulation.world, pos)).emitted_light;
    for (leaf_directions) |direction| {
        const emitted = game_data.blockInfo(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, direction))).emitted_light;
        light = @max(light, emitted -| 1);
    }
    return light;
}

fn baseLightAt(simulation: *Dependencies, pos: geometry.BlockPos) u8 {
    const above = simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 }));
    return @max(blockLightAt(simulation, pos), if (game_data.blockInfo(above).filtered_light < 15) @as(u8, 15) else 0);
}

fn randomTickStem(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (baseLightAt(simulation, pos) < 9) return;
    const moisture = cropAvailableMoisture(simulation, pos, blockId(block_state));
    const bound: u32 = @intFromFloat(@floor(25.0 / moisture) + 1.0);
    if (simulation.random.random.nextIntBounded(bound) != 0) return;
    if (behavior.next_age >= 0) {
        applyRandomTickChange(simulation, state, pos, behavior.next_age, outputs, changes);
        return;
    }
    const direction_index = simulation.random.random.nextIntBoundedComptime(4);
    const directions = [_]geometry.BlockPos{
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 },
        .{ .x = 1, .y = 0, .z = 0 },
    };
    const fruit_pos = offsetBlock(pos, directions[direction_index]);
    if (simulation.blocks.blockAt(simulation.world, fruit_pos) != registry.block_air_default_state) return;
    const below = simulation.blocks.blockAt(simulation.world, offsetBlock(fruit_pos, .{ .x = 0, .y = -1, .z = 0 }));
    const below_id = blockId(below);
    if (below_id != farmland_block_id and below_id != registry.block_dirt_id and below_id != registry.block_grass_block_id) return;
    const pumpkin = blockId(block_state) == pumpkin_stem_block_id;
    if (!pumpkin and blockId(block_state) != melon_stem_block_id) return;
    applyRandomTickChange(simulation, state, fruit_pos, if (pumpkin) pumpkin_default_state else melon_default_state, outputs, changes);
    if (changes.* < config.max_random_tick_block_changes_per_tick)
        applyRandomTickChange(simulation, state, pos, (if (pumpkin) attached_pumpkin_stem_min_state else attached_melon_stem_min_state) + @as(i32, @intCast(direction_index)), outputs, changes);
}

fn randomTickMushroom(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) void {
    if (!mushroomCanRemainAt(simulation, pos)) {
        applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        return;
    }
    if (simulation.random.random.nextIntBoundedComptime(25) != 0) return;
    var remaining: u8 = 5;
    var y: i16 = pos.y - 1;
    while (y <= pos.y + 1) : (y += 1) {
        var z = pos.z - 4;
        while (z <= pos.z + 4) : (z += 1) {
            var x = pos.x - 4;
            while (x <= pos.x + 4) : (x += 1) {
                if (blockId(simulation.blocks.blockAt(simulation.world, .{ .x = x, .y = y, .z = z })) != blockId(block_state)) continue;
                remaining -= 1;
                if (remaining == 0) return;
            }
        }
    }
    var origin = pos;
    var candidate = geometry.BlockPos{
        .x = pos.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
        .y = pos.y + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))) - @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))),
        .z = pos.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
    };
    for (0..4) |_| {
        if (mushroomCanPlaceAt(simulation, candidate)) origin = candidate;
        candidate = .{
            .x = origin.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            .y = origin.y + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))) - @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))),
            .z = origin.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
        };
    }
    if (mushroomCanPlaceAt(simulation, candidate))
        applyRandomTickChange(simulation, state, candidate, block_state, outputs, changes);
}

fn mushroomCanRemainAt(simulation: *Dependencies, pos: geometry.BlockPos) bool {
    const below = simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    if (registry.blockBehaviorFlags(below).mushroom_substrate) return true;
    return game_data.blockInfo(below).filtered_light == 15 and baseLightAt(simulation, pos) < 13;
}

fn mushroomCanPlaceAt(simulation: *Dependencies, pos: geometry.BlockPos) bool {
    if (!player_store.validBuildY(pos.y) or simulation.blocks.blockAt(simulation.world, pos) != registry.block_air_default_state) return false;
    const below = simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    if (registry.blockBehaviorFlags(below).mushroom_substrate) return true;
    return game_data.blockInfo(below).filtered_light == 15 and baseLightAt(simulation, pos) < 13;
}

fn vineState(faces: u5) i32 {
    var offset: i32 = 0;
    if (faces & 0b00001 == 0) offset += 16;
    if (faces & 0b00010 == 0) offset += 8;
    if (faces & 0b00100 == 0) offset += 4;
    if (faces & 0b01000 == 0) offset += 2;
    if (faces & 0b10000 == 0) offset += 1;
    return vine_min_state + offset;
}

fn randomTickVine(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (simulation.random.random.nextIntBoundedComptime(4) != 0) return;
    const direction = simulation.random.random.nextIntBoundedComptime(6);
    if (direction == 0) {
        const below = offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 });
        const below_state = simulation.blocks.blockAt(simulation.world, below);
        if (below_state != registry.block_air_default_state and blockId(below_state) != blockId(vine_min_state)) return;
        var faces: u5 = if (below_state == registry.block_air_default_state) behavior.vine_faces else registry.randomTickState(below_state).vine_faces;
        for (0..4) |face| {
            if (simulation.random.random.nextIntBoundedComptime(2) == 0) faces &= ~(@as(u5, 1) << @intCast(face));
        }
        if (faces != 0) applyRandomTickChange(simulation, state, below, vineState(faces), outputs, changes);
        return;
    }
    if (direction == 1) {
        const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
        if (simulation.blocks.blockAt(simulation.world, above) != registry.block_air_default_state) return;
        var faces = behavior.vine_faces & 0b10111;
        for (0..4) |face| {
            if (simulation.random.random.nextIntBoundedComptime(2) == 0) faces &= ~(@as(u5, 1) << @intCast(face));
        }
        if (faces != 0) applyRandomTickChange(simulation, state, above, vineState(faces), outputs, changes);
        return;
    }
    const horizontal = [_]geometry.BlockPos{
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 },
    };
    const face_bits = [_]u5{ 0b00010, 0b00001, 0b00100, 0b10000 };
    const index = direction - 2;
    if (behavior.vine_faces & face_bits[index] != 0) return;
    const target = offsetBlock(pos, horizontal[index]);
    if (game_data.blockInfo(simulation.blocks.blockAt(simulation.world, target)).filtered_light == 15) {
        applyRandomTickChange(simulation, state, pos, vineState(behavior.vine_faces | face_bits[index]), outputs, changes);
        return;
    }
    if (simulation.blocks.blockAt(simulation.world, target) != registry.block_air_default_state) return;
    const clockwise = (index + 1) & 3;
    const counterclockwise = (index + 3) & 3;
    if (behavior.vine_faces & face_bits[clockwise] != 0 and game_data.blockInfo(simulation.blocks.blockAt(simulation.world, offsetBlock(target, horizontal[clockwise]))).filtered_light == 15) {
        applyRandomTickChange(simulation, state, target, vineState(face_bits[clockwise]), outputs, changes);
    } else if (behavior.vine_faces & face_bits[counterclockwise] != 0 and game_data.blockInfo(simulation.blocks.blockAt(simulation.world, offsetBlock(target, horizontal[counterclockwise]))).filtered_light == 15) {
        applyRandomTickChange(simulation, state, target, vineState(face_bits[counterclockwise]), outputs, changes);
    }
}

fn randomTickKelp(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (behavior.next_age < 0 or simulation.random.random.nextDouble() >= 0.14) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (blockId(simulation.blocks.blockAt(simulation.world, above)) != water_block_id) return;
    applyRandomTickChange(simulation, state, pos, kelp_plant_default_state, outputs, changes);
    if (changes.* < config.max_random_tick_block_changes_per_tick)
        applyRandomTickChange(simulation, state, above, behavior.next_age, outputs, changes);
}

fn bambooState(age: i8, leaves: i8, stage: i8) i32 {
    return bamboo_default_state + @as(i32, age) * 6 + @as(i32, leaves) * 2 + stage;
}

fn randomTickBambooSapling(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    if (simulation.random.random.nextIntBoundedComptime(3) != 0) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (simulation.blocks.blockAt(simulation.world, above) == registry.block_air_default_state and baseLightAt(simulation, above) >= 9)
        applyRandomTickChange(simulation, state, above, bamboo_small_state, outputs, changes);
}

fn randomTickBamboo(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) void {
    if (simulation.random.random.nextIntBoundedComptime(3) != 0) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (simulation.blocks.blockAt(simulation.world, above) != registry.block_air_default_state or baseLightAt(simulation, above) < 9) return;
    var height: i16 = 1;
    while (height < 16 and blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y - height, .z = pos.z })) == bamboo_block_id) : (height += 1) {}
    if (height >= 16) return;
    const below = registry.randomTickState(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 })));
    const below_two_pos = offsetBlock(pos, .{ .x = 0, .y = -2, .z = 0 });
    const below_two_state = simulation.blocks.blockAt(simulation.world, below_two_pos);
    const below_two = registry.randomTickState(below_two_state);
    var leaves: i8 = 0;
    if (height >= 1 and (blockId(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != bamboo_block_id or below.enum_value == 0)) {
        leaves = 1;
    } else if (below.enum_value != 0) {
        leaves = 2;
        if (blockId(below_two_state) == bamboo_block_id) {
            applyRandomTickChange(simulation, state, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }), bambooState(registry.randomTickState(block_state).age, 1, below.stage), outputs, changes);
            if (changes.* >= config.max_random_tick_block_changes_per_tick) return;
            applyRandomTickChange(simulation, state, below_two_pos, bambooState(below_two.age, 0, below_two.stage), outputs, changes);
            if (changes.* >= config.max_random_tick_block_changes_per_tick) return;
        }
    }
    const age: i8 = if (registry.randomTickState(block_state).age == 1 or blockId(below_two_state) == bamboo_block_id) 1 else 0;
    const stage: i8 = if ((height >= 11 and simulation.random.random.nextFloat() < 0.25) or height == 15) 1 else 0;
    applyRandomTickChange(simulation, state, above, bambooState(age, leaves, stage), outputs, changes);
}

fn randomTickIce(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) void {
    if (blockLightAt(simulation, pos) <= 11 - game_data.blockInfo(block_state).filtered_light) return;
    applyRandomTickChange(simulation, state, pos, registry.state_water_level_0, outputs, changes);
}

fn randomTickSnow(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    if (blockLightAt(simulation, pos) > 11)
        applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
}

fn randomTickSapling(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (baseLightAt(simulation, offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 })) < 9 or simulation.random.random.nextIntBoundedComptime(7) != 0) return;
    if (behavior.stage == 0 and behavior.next_stage >= 0) {
        applyRandomTickChange(simulation, state, pos, behavior.next_stage, outputs, changes);
        return;
    }
    if (blockId(block_state) != registry.block_oak_sapling_id) return;
    growOakTree(simulation, state, pos, outputs, changes);
}

fn growOakTree(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    const height: i16 = 4 + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(3)));
    var y: i16 = 0;
    while (y < height + 2) : (y += 1) {
        const radius: i32 = if (y < height - 2) 0 else 2;
        var z: i32 = -radius;
        while (z <= radius) : (z += 1) {
            var x: i32 = -radius;
            while (x <= radius) : (x += 1) {
                const target = geometry.BlockPos{ .x = pos.x + x, .y = pos.y + y, .z = pos.z + z };
                const current = simulation.blocks.blockAt(simulation.world, target);
                if (current != registry.block_air_default_state and leafDistance(current) == null and !(x == 0 and z == 0 and y == 0)) return;
            }
        }
    }
    applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
    y = 0;
    while (y < height and changes.* < config.max_random_tick_block_changes_per_tick) : (y += 1)
        applyRandomTickChange(simulation, state, .{ .x = pos.x, .y = pos.y + y, .z = pos.z }, registry.block_oak_log_default_state, outputs, changes);
    y = height - 2;
    while (y <= height and changes.* < config.max_random_tick_block_changes_per_tick) : (y += 1) {
        const radius: i32 = if (y == height) 1 else 2;
        var z: i32 = -radius;
        while (z <= radius and changes.* < config.max_random_tick_block_changes_per_tick) : (z += 1) {
            var x: i32 = -radius;
            while (x <= radius and changes.* < config.max_random_tick_block_changes_per_tick) : (x += 1) {
                if (@abs(x) == radius and @abs(z) == radius and simulation.random.random.nextIntBoundedComptime(2) == 0) continue;
                const target = geometry.BlockPos{ .x = pos.x + x, .y = pos.y + y, .z = pos.z + z };
                if (simulation.blocks.blockAt(simulation.world, target) == registry.block_air_default_state)
                    applyRandomTickChange(simulation, state, target, registry.block_oak_leaves_default_state, outputs, changes);
            }
        }
    }
}

fn randomTickTurtleEgg(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    const day_time = simulation.time.day_time % 24_000;
    if (!((day_time >= 21_600 and day_time <= 22_550) or simulation.random.random.nextIntBounded(500) == 0)) return;
    if (blockId(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != sand_block_id) return;
    if (behavior.hatch < 2) {
        applyRandomTickChange(simulation, state, pos, block_state + 1, outputs, changes);
    } else {
        applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        var egg: i8 = 0;
        while (egg < behavior.eggs) : (egg += 1) {
            const turtle = simulation.spawnLiving(.turtle, .{
                .x = @as(f64, @floatFromInt(pos.x)) + 0.3 + @as(f64, @floatFromInt(egg)) * 0.2,
                .y = @floatFromInt(pos.y),
                .z = @as(f64, @floatFromInt(pos.z)) + 0.3,
            }, true, false) catch return;
            outputs.living_spawned(turtle.index);
        }
    }
}

fn randomTickNetherPortal(simulation: *Dependencies, pos: geometry.BlockPos, outputs: *Packets) void {
    if (!simulation.rules.do_mob_spawning or simulation.living.entities.free_count == 0) return;
    const difficulty: u32 = switch (simulation.rules.difficulty) {
        .peaceful => 0,
        .easy => 1,
        .normal => 2,
        .hard => 3,
    };
    if (simulation.random.random.nextIntBounded(2000) >= difficulty) return;
    var ground = pos;
    for (0..@as(usize, @intCast(block_store.world_top_y - config.world_min_y + 1))) |_| {
        if (blockId(simulation.blocks.blockAt(simulation.world, ground)) != blockId(registry.state_nether_portal_axis_x)) break;
        if (ground.y == config.world_min_y) return;
        ground.y -= 1;
    } else diagnostics.panic("nether portal scan exceeded world height", &.{});
    if (game_data.blockInfo(simulation.blocks.blockAt(simulation.world, ground)).filtered_light != 15) return;
    const piglin = simulation.spawnLiving(.zombified_piglin, .{
        .x = @as(f64, @floatFromInt(ground.x)) + 0.5,
        .y = @as(f64, @floatFromInt(ground.y)) + 1,
        .z = @as(f64, @floatFromInt(ground.z)) + 0.5,
    }, false, false) catch return;
    outputs.living_spawned(piglin.index);
}

const amethyst_directions = [_]geometry.BlockPos{
    .{ .x = 0, .y = 0, .z = -1 },
    .{ .x = 1, .y = 0, .z = 0 },
    .{ .x = 0, .y = 0, .z = 1 },
    .{ .x = -1, .y = 0, .z = 0 },
    .{ .x = 0, .y = 1, .z = 0 },
    .{ .x = 0, .y = -1, .z = 0 },
};

fn randomTickBuddingAmethyst(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    if (simulation.random.random.nextIntBoundedComptime(5) != 0) return;
    const direction = simulation.random.random.nextIntBoundedComptime(6);
    const target = offsetBlock(pos, amethyst_directions[direction]);
    const current = simulation.blocks.blockAt(simulation.world, target);
    const current_info = game_data.blockInfo(current);
    var next_min: i32 = -1;
    if (current == registry.block_air_default_state or blockId(current) == water_block_id) {
        next_min = small_amethyst_min_state;
    } else if (current_info.min_state == small_amethyst_min_state and @divTrunc(current - current_info.min_state, 2) == direction) {
        next_min = medium_amethyst_min_state;
    } else if (current_info.min_state == medium_amethyst_min_state and @divTrunc(current - current_info.min_state, 2) == direction) {
        next_min = large_amethyst_min_state;
    } else if (current_info.min_state == large_amethyst_min_state and @divTrunc(current - current_info.min_state, 2) == direction) {
        next_min = amethyst_cluster_min_state;
    }
    if (next_min < 0) return;
    const waterlogged: i32 = if (blockId(current) == water_block_id) 0 else 1;
    applyRandomTickChange(simulation, state, target, next_min + @as(i32, @intCast(direction * 2)) + waterlogged, outputs, changes);
}

fn randomTickCopper(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    if (behavior.next_oxidation < 0 or simulation.random.random.nextFloat() >= 0.05688889) return;
    var equal: u32 = 0;
    var later: u32 = 0;
    var y: i16 = pos.y - 4;
    while (y <= pos.y + 4) : (y += 1) {
        var z = pos.z - 4;
        while (z <= pos.z + 4) : (z += 1) {
            var x = pos.x - 4;
            while (x <= pos.x + 4) : (x += 1) {
                const distance = @abs(x - pos.x) + @abs(@as(i32, y - pos.y)) + @abs(z - pos.z);
                if (distance == 0 or distance > 4) continue;
                const neighbor_stage = copperOxidationStage(simulation.blocks.blockAt(simulation.world, .{ .x = x, .y = y, .z = z })) orelse continue;
                if (neighbor_stage < behavior.oxidation_stage) return;
                if (neighbor_stage == behavior.oxidation_stage) equal += 1 else later += 1;
            }
        }
    }
    const ratio = @as(f32, @floatFromInt(later + 1)) / @as(f32, @floatFromInt(later + equal + 1));
    const chance = ratio * ratio * if (behavior.oxidation_stage == 0) @as(f32, 0.75) else 1;
    if (simulation.random.random.nextFloat() < chance)
        applyRandomTickChange(simulation, state, pos, behavior.next_oxidation, outputs, changes);
}

fn surroundedByAir(simulation: *Dependencies, pos: geometry.BlockPos, ignored: ?usize) bool {
    const horizontal = [_]geometry.BlockPos{
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 },
    };
    for (horizontal, 0..) |direction, index| {
        if (ignored == index) continue;
        if (simulation.blocks.blockAt(simulation.world, offsetBlock(pos, direction)) != registry.block_air_default_state) return false;
    }
    return true;
}

fn randomTickChorusFlower(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (!player_store.validBuildY(above.y) or simulation.blocks.blockAt(simulation.world, above) != registry.block_air_default_state or behavior.age >= 5) return;
    const below = simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    var vertical_growth = blockId(below) == end_stone_block_id or below == registry.block_air_default_state;
    var rooted = blockId(below) == end_stone_block_id;
    if (blockId(below) == chorus_plant_block_id) {
        var depth: u8 = 1;
        while (depth < 5 and blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y - @as(i16, depth + 1), .z = pos.z })) == chorus_plant_block_id) : (depth += 1) {}
        rooted = blockId(simulation.blocks.blockAt(simulation.world, .{ .x = pos.x, .y = pos.y - @as(i16, depth + 1), .z = pos.z })) == end_stone_block_id;
        vertical_growth = depth < 2 or depth <= simulation.random.random.nextIntBounded(if (rooted) 5 else 4);
    }
    if (vertical_growth and surroundedByAir(simulation, above, null) and simulation.blocks.blockAt(simulation.world, offsetBlock(above, .{ .x = 0, .y = 1, .z = 0 })) == registry.block_air_default_state) {
        applyRandomTickChange(simulation, state, pos, chorus_plant_default_state, outputs, changes);
        if (changes.* < config.max_random_tick_block_changes_per_tick)
            applyRandomTickChange(simulation, state, above, registry.state_chorus_flower_age_0 + behavior.age, outputs, changes);
        return;
    }
    if (behavior.age < 4) {
        var attempts = simulation.random.random.nextIntBoundedComptime(4);
        if (rooted) attempts += 1;
        var grew = false;
        const directions = [_]geometry.BlockPos{
            .{ .x = 0, .y = 0, .z = -1 },
            .{ .x = 1, .y = 0, .z = 0 },
            .{ .x = 0, .y = 0, .z = 1 },
            .{ .x = -1, .y = 0, .z = 0 },
        };
        for (0..attempts) |_| {
            const direction = simulation.random.random.nextIntBoundedComptime(4);
            const target = offsetBlock(pos, directions[direction]);
            if (simulation.blocks.blockAt(simulation.world, target) != registry.block_air_default_state or simulation.blocks.blockAt(simulation.world, offsetBlock(target, .{ .x = 0, .y = -1, .z = 0 })) != registry.block_air_default_state or !surroundedByAir(simulation, target, (direction + 2) & 3)) continue;
            applyRandomTickChange(simulation, state, target, registry.state_chorus_flower_age_0 + behavior.age + 1, outputs, changes);
            grew = true;
            if (changes.* >= config.max_random_tick_block_changes_per_tick) return;
        }
        if (grew) {
            applyRandomTickChange(simulation, state, pos, chorus_plant_default_state, outputs, changes);
            return;
        }
    }
    applyRandomTickChange(simulation, state, pos, chorus_flower_dead_state, outputs, changes);
}

fn blockCanBurn(block_state: i32) bool {
    return registry.blockBehaviorFlags(block_state).flammable;
}

fn hasBurnableNeighbor(simulation: *Dependencies, pos: geometry.BlockPos) bool {
    for (amethyst_directions) |direction| if (blockCanBurn(simulation.blocks.blockAt(simulation.world, offsetBlock(pos, direction)))) return true;
    return false;
}

fn tickFire(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    if (blockId(simulation.blocks.blockAt(simulation.world, pos)) != fire_block_id) return;
    const below = simulation.blocks.blockAt(simulation.world, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    const permanent = blockId(below) == netherrack_block_id;
    const supported = game_data.blockInfo(below).filtered_light == 15;
    const has_fuel = hasBurnableNeighbor(simulation, pos);
    if (!permanent and !supported and !has_fuel) {
        applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        return;
    }
    for (amethyst_directions) |direction| {
        const target = offsetBlock(pos, direction);
        if (!blockCanBurn(simulation.blocks.blockAt(simulation.world, target))) continue;
        const roll = simulation.random.random.nextIntBoundedComptime(100);
        if (roll < 35) {
            applyRandomTickChange(simulation, state, target, fire_default_state, outputs, changes);
        } else if (roll < 55) {
            applyRandomTickChange(simulation, state, target, registry.block_air_default_state, outputs, changes);
        }
        if (changes.* == config.max_random_tick_block_changes_per_tick) return;
    }
    scheduleFire(simulation, pos);
}

fn randomTickLava(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    const attempts = simulation.random.random.nextIntBoundedComptime(3);
    if (attempts > 0) {
        var candidate = pos;
        for (0..attempts) |_| {
            candidate = .{
                .x = candidate.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
                .y = candidate.y + 1,
                .z = candidate.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            };
            const current = simulation.blocks.blockAt(simulation.world, candidate);
            if (current == registry.block_air_default_state) {
                if (hasBurnableNeighbor(simulation, candidate)) applyRandomTickChange(simulation, state, candidate, fire_default_state, outputs, changes);
                return;
            }
            if (game_data.blockInfo(current).filtered_light == 15) return;
        }
        return;
    }
    for (0..3) |_| {
        const candidate: geometry.BlockPos = .{
            .x = pos.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            .y = pos.y,
            .z = pos.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
        };
        const above = offsetBlock(candidate, .{ .x = 0, .y = 1, .z = 0 });
        if (simulation.blocks.blockAt(simulation.world, above) == registry.block_air_default_state and hasBurnableNeighbor(simulation, candidate)) {
            applyRandomTickChange(simulation, state, above, fire_default_state, outputs, changes);
            return;
        }
    }
}

fn dripstoneState(thickness: i8, vertical_direction: i8, waterlogged: bool) i32 {
    return pointed_dripstone_min_state + @as(i32, thickness) * 4 + @as(i32, vertical_direction) * 2 + @intFromBool(!waterlogged);
}

fn randomTickPointedDripstone(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) void {
    const drip_roll = simulation.random.random.nextFloat();
    if (behavior.vertical_direction == 1) {
        var source_pos = pos;
        var found_source = false;
        var source_state = registry.block_air_default_state;
        for (0..11) |_| {
            source_pos.y += 1;
            const source = simulation.blocks.blockAt(simulation.world, source_pos);
            if (blockId(source) == blockId(pointed_dripstone_min_state)) continue;
            if (blockId(source) == mud_block_id) {
                found_source = true;
                source_state = source;
            } else {
                source_pos.y += 1;
                source_state = simulation.blocks.blockAt(simulation.world, source_pos);
                found_source = blockId(source_state) == water_block_id;
            }
            break;
        }
        if (found_source and drip_roll < 0.17578125 and blockId(source_state) == mud_block_id) {
            applyRandomTickChange(simulation, state, source_pos, clay_default_state, outputs, changes);
            if (changes.* >= config.max_random_tick_block_changes_per_tick) return;
        } else if (found_source and drip_roll < 0.17578125 and blockId(source_state) == water_block_id and behavior.enum_value == 1) {
            var cauldron_pos = pos;
            for (0..11) |_| {
                cauldron_pos.y -= 1;
                const below = simulation.blocks.blockAt(simulation.world, cauldron_pos);
                if (below == registry.block_air_default_state) continue;
                if (blockId(below) == cauldron_block_id)
                    scheduleBlockTick(scheduledTicks(simulation), simulation.clock.tick + 50, cauldron_pos, .water_cauldron);
                break;
            }
        }
    }
    if (simulation.random.random.nextFloat() >= 0.011377778) return;
    if (behavior.vertical_direction == 1 and behavior.enum_value == 1) {
        const below = offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 });
        if (simulation.blocks.blockAt(simulation.world, below) == registry.block_air_default_state)
            applyRandomTickChange(simulation, state, below, dripstoneState(1, 1, false), outputs, changes);
    } else if (behavior.vertical_direction == 0 and behavior.enum_value == 1) {
        const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
        if (simulation.blocks.blockAt(simulation.world, above) == registry.block_air_default_state)
            applyRandomTickChange(simulation, state, above, dripstoneState(1, 0, false), outputs, changes);
    }
}

fn copperOxidationStage(block_state: i32) ?i8 {
    const stage = registry.randomTickState(block_state).oxidation_stage;
    return if (stage < 0) null else stage;
}

fn blockId(block_state: i32) u16 {
    return if (block_state >= 0 and block_state < registry.block_state_to_block.len)
        registry.block_state_to_block[@intCast(block_state)]
    else
        std.math.maxInt(u16);
}

fn decayLeaves(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) void {
    const blocks = block_writer.Writer.init(simulation.blocks, outputs);
    const current = simulation.blocks.blockAt(simulation.world, pos);
    if (!isDecayingOakLeaves(current)) {
        refreshRandomTickActionBlock(simulation, state, pos);
        return;
    }
    // A distance property can be temporarily stale after fixture restoration,
    // chunk activation, or a neighboring block update. Vanilla's scheduled
    // leaf tick repairs it before random decay. Validate the same bounded
    // six-edge leaf graph here so stale distance=7 can never destroy a leaf
    // that is actually connected to a log.
    if (connectedLeafDistance(simulation.blocks, simulation.world, pos)) |distance| {
        const connected = withLeafDistance(current, distance);
        if (connected != current and (blocks.set(simulation.world, pos, connected) catch false)) {
            changes.* += 1;
            reconcileLatestRandomTickMutation(simulation, state);
        }
        return;
    }
    if (blocks.set(simulation.world, pos, registry.block_air_default_state) catch false) {
        changes.* += 1;
        reconcileLatestRandomTickMutation(simulation, state);
        const drop_result = spawnOakLeafDrops(simulation.random, simulation.blocks, simulation.items, simulation.world, pos, outputs);
        plugin_profiler.countTrace(RandomTickTrace.leaf_decays, 1);
        plugin_profiler.countTrace(RandomTickTrace.leaf_sapling_rolls, @intFromBool(drop_result.rolled.sapling));
        plugin_profiler.countTrace(RandomTickTrace.leaf_sapling_spawns, @intFromBool(drop_result.sapling_spawned));
        plugin_profiler.countTrace(RandomTickTrace.leaf_drop_spawn_failures, drop_result.spawn_failures);
        plugin_profiler.countTrace(RandomTickTrace.leaf_drop_capacity_failures, drop_result.capacity_failures);
    }
}

fn randomTickBlock(simulation: *Dependencies, state: *RandomTicks, origin_chunk_index: ?usize, origin: *const block_store.GeneratedHeightChunk, pos: geometry.BlockPos, can_spread: bool, outputs: *Packets, changes: *usize) void {
    const blocks = block_writer.Writer.init(simulation.blocks, outputs);
    const spread_state = game_data.blockInfo(simulation.blocks.blockAt(simulation.world, pos)).default_state;
    const above_blocked = if (origin_chunk_index) |index|
        if (!state.chunks[index].exact_grass_neighborhood)
            projectedGrassAboveIsBlocked(&state.grass[index], pos)
        else
            simulation.blocks.grassAboveIsBlocked(origin, pos)
    else
        simulation.blocks.grassAboveIsBlocked(origin, pos);
    if (above_blocked) {
        if (blocks.set(simulation.world, pos, registry.block_dirt_default_state) catch false) {
            changes.* += 1;
            reconcileLatestRandomTickMutation(simulation, state);
        }
        return;
    }
    if (!can_spread) return;
    if (origin_chunk_index) |index| {
        if (!state.chunks[index].exact_grass_neighborhood) {
            return;
        }
    }
    for (0..4) |_| {
        const candidate = geometry.BlockPos{
            .x = pos.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            .y = pos.y + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(5))) - 3,
            .z = pos.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
        };
        if (!player_store.validBuildY(candidate.y) or !grassCanSpreadTo(simulation, state, origin_chunk_index, candidate)) continue;
        if (blocks.set(simulation.world, candidate, spread_state) catch false) {
            changes.* += 1;
            reconcileLatestRandomTickMutation(simulation, state);
            if (changes.* == config.max_random_tick_block_changes_per_tick) return;
        }
    }
}

fn projectedGrassAboveIsBlocked(projection: *const RandomTickGrassProjection, grass: geometry.BlockPos) bool {
    const column: usize = @as(usize, @intCast(grass.x & 15)) | (@as(usize, @intCast(grass.z & 15)) << 4);
    return projection.grass_above_blocked[column / 64] & (@as(u64, 1) << @intCast(column & 63)) != 0;
}

fn residentForRandomTickTicket(simulation: *const Dependencies, ticket: *const RandomTickChunk) ?*const block_store.GeneratedHeightChunk {
    const hint: usize = ticket.generated_cache_hint;
    if (hint < simulation.blocks.resident_chunks.len) {
        const resident = &simulation.blocks.resident_chunks[hint];
        if (resident.valid and geometry.sameChunk(resident.chunk, ticket.chunk)) return resident;
    }
    return simulation.blocks.residentChunk(simulation.world, ticket.chunk);
}

fn randomTickResidentFor(simulation: *const Dependencies, state: *const RandomTicks, origin_chunk_index: ?usize, candidate: geometry.BlockPos) ?*const block_store.GeneratedHeightChunk {
    const chunk = geometry.chunkForBlock(candidate);
    if (origin_chunk_index) |index| {
        const origin = &state.chunks[index];
        if (origin.chunk.x == chunk.x and origin.chunk.z == chunk.z) {
            return residentForRandomTickTicket(simulation, origin);
        }
    }
    if (findRandomTickChunk(state, chunk)) |index| {
        const active = &state.chunks[index];
        return residentForRandomTickTicket(simulation, active);
    }
    return simulation.blocks.residentChunk(simulation.world, chunk);
}

fn grassCanSpreadTo(simulation: *Dependencies, state: *RandomTicks, origin_chunk_index: ?usize, candidate: geometry.BlockPos) bool {
    // Selection caches locate authoritative chunks but do not define block
    // semantics; spread decisions use the logical section contents.
    if (!player_store.validBuildY(candidate.y)) return false;
    const resident = randomTickResidentFor(simulation, state, origin_chunk_index, candidate) orelse return false;
    return simulation.blocks.grassCanSpreadAt(resident, candidate);
}

fn allocateBuffers(state: *RandomTicks, allocator: std.mem.Allocator, maximum_chunks: usize) !void {
    state.centers = try preallocated.alloc(RandomTickCenter, allocator, config.max_players);
    state.free_chunk_indices = try preallocated.alloc(u16, allocator, maximum_chunks);
    state.active_chunk_indices = try preallocated.alloc(u16, allocator, maximum_chunks);
    state.previous_exact_neighborhoods = try preallocated.alloc(bool, allocator, maximum_chunks);
    state.chunk_was_active = try preallocated.alloc(bool, allocator, maximum_chunks);
    state.chunk_topology_generations = try preallocated.alloc(u32, allocator, maximum_chunks);
    @memset(state.chunk_topology_generations, 0);
    state.chunk_ticket_generations = try preallocated.alloc(u32, allocator, maximum_chunks);
    @memset(state.chunk_ticket_generations, 0);
    state.chunk_allocated = try preallocated.alloc(bool, allocator, maximum_chunks);
    @memset(state.chunk_allocated, false);
    state.ticket_grid_initialized = try preallocated.alloc(bool, allocator, config.max_players);
    @memset(state.ticket_grid_initialized, false);
    state.ticket_grid_center_x = try preallocated.alloc(i32, allocator, config.max_players);
    @memset(state.ticket_grid_center_x, 0);
    state.ticket_grid_center_z = try preallocated.alloc(i32, allocator, config.max_players);
    @memset(state.ticket_grid_center_z, 0);
    state.ticket_grid_seen_generation = try preallocated.alloc(u32, allocator, config.max_players);
    @memset(state.ticket_grid_seen_generation, 0);
    state.ticket_grid_missing = try preallocated.alloc(u16, allocator, config.max_players);
    @memset(state.ticket_grid_missing, 0);
    state.ticket_grid_prefetch_cursor = try preallocated.alloc(u16, allocator, config.max_players);
    @memset(state.ticket_grid_prefetch_cursor, 0);
    state.ticket_grid_handles = try preallocated.alloc([random_tick_ticket_cells]u16, allocator, config.max_players);
    state.ticket_grid_scratch = try preallocated.alloc(u16, allocator, random_tick_ticket_cells);
    state.chunks = try preallocated.alignedAlloc(RandomTickChunk, allocator, .@"64", maximum_chunks);
    state.grass = try preallocated.alignedAlloc(RandomTickGrassProjection, allocator, .@"64", maximum_chunks);
    state.general = try preallocated.alignedAlloc(RandomTickGeneralProjection, allocator, .@"64", maximum_chunks);
    state.lookup = try preallocated.alloc(u16, allocator, maximum_chunks * 2);
    @memset(state.lookup, 0);
    state.free_action_masks = try preallocated.alloc(u16, allocator, maximum_chunks * 2);
    state.action_masks = try preallocated.alloc([block_store.blocks_per_section / 64]u64, allocator, maximum_chunks * 2);
    state.action_chunk_positions = try preallocated.alignedAlloc(u64, allocator, .@"64", (maximum_chunks + 63) / 64);
    @memset(state.action_chunk_positions, 0);
}

test "grass action cache reconciles one local obstruction mutation" {
    const simulation = try std.heap.page_allocator.create(test_state.State);
    defer std.heap.page_allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 0x6772_6173_735f_6661);
    defer simulation.deinit();
    var dependencies = Dependencies.fromTestState(simulation);
    const state = try std.heap.page_allocator.create(RandomTicks);
    defer std.heap.page_allocator.destroy(state);
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());

    var selected_chunk: ?geometry.ChunkPos = null;
    var selected_column: usize = 0;
    var chunk_z: i32 = -4;
    while (chunk_z <= 4 and selected_chunk == null) : (chunk_z += 1) {
        var chunk_x: i32 = -4;
        while (chunk_x <= 4) : (chunk_x += 1) {
            const chunk = geometry.ChunkPos{ .x = chunk_x, .z = chunk_z };
            const resident = simulation.blocks.generatedHeightChunk(simulation.world, chunk, 0);
            for (resident.grass_above_blocked, 0..) |word, word_index| {
                if (word == 0) continue;
                selected_chunk = chunk;
                selected_column = word_index * 64 + @ctz(word);
                break;
            }
            if (selected_chunk != null) break;
        }
    }
    const chunk = selected_chunk orelse return error.TestExpectedTree;
    try std.testing.expect(insertRandomTickChunk(&dependencies, state, chunk, .entity_ticking));
    const active = &state.chunks[0];
    const resident = &simulation.blocks.resident_chunks[active.generated_cache_hint];
    const grass = geometry.BlockPos{
        .x = chunk.x * 16 + @as(i32, @intCast(selected_column & 15)),
        .y = resident.heights[selected_column],
        .z = chunk.z * 16 + @as(i32, @intCast(selected_column >> 4)),
    };
    try std.testing.expectEqual(registry.block_grass_block_default_state, simulation.blocks.blockAt(simulation.world, grass));
    const above = geometry.BlockPos{ .x = grass.x, .y = grass.y + 1, .z = grass.z };
    try std.testing.expect(try simulation.blocks.setBlock(above, registry.block_air_default_state));
    try std.testing.expect(reconcilePendingRandomTickMutations(&dependencies, state));
    try std.testing.expectEqual(simulation.blocks.block_mutation_sequence, state.observed_mutation_sequence);
    try std.testing.expect(state.chunks[0].exact_grass_neighborhood);

    const section = block_store.sectionIndexForY(grass.y).?;
    const local_index = block_store.localBlockIndexForPosition(grass);
    const action_handle = state.general[0].action_mask_handles[section];
    try std.testing.expect(action_handle != 0 and action_handle != random_tick_action_mask_unindexed);
    const cached = state.action_masks[action_handle - 1][local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) != 0;
    const modified_index = simulation.blocks.modifiedSectionIndex(resident, section);
    const current = simulation.blocks.sectionBlockState(resident, section, local_index, modified_index);
    try std.testing.expectEqual(
        randomTickBlockIsActionable(&dependencies, state, 0, resident, section, local_index, current),
        cached,
    );
}
