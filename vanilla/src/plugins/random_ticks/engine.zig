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
const preallocated = lightning_rod.preallocated;
const plugin_profiler = lightning_rod.plugin_profiler;
const world_limits = lightning_rod.world_limits;
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
const collision = lightning_rod.collision;
const terrain = lightning_rod.terrain;
const block_writer = lightning_rod.block_writer;
const leaf_behavior = @import("../../vanilla/leaf_behavior.zig");
const diagnostics = lightning_rod.diagnostics;
const world_store = lightning_rod.worlds;
const world_identity = lightning_rod.world_identity;

const leaf_directions = leaf_behavior.directions;
const offsetBlock = leaf_behavior.offset;
const leafDistance = leaf_behavior.distance;
const isOakLeaves = leaf_behavior.isOak;
const isDecayingOakLeaves = leaf_behavior.isDecayingOak;
const rollOakLeafDrops = leaf_behavior.rollOakDrops;
const oakLeafDropStacks = leaf_behavior.oakDropStacks;

const chunk_tickets = @import("../../vanilla/chunk_tickets.zig");
const simulation_admission = @import("../../vanilla/simulation_admission.zig");
const vanilla_persistence = @import("../vanilla_persistence.zig");
const vanilla_collision_projection = @import("../vanilla_collision_projection.zig");
const Packets = lightning_rod.Packets;
pub const FatalError = lightning_rod.plugin_lifecycle.FatalError;

pub const ScheduledBlockTicks = struct {
    pub const id = "minecraft:scheduled_block_ticks";
    pub const Configuration = struct {};

    count: u16 = 0,
    sequence: u32 = 0,
    entries: []ScheduledBlockTick = &.{},
    lookup: []ScheduledBlockTickKey = &.{},

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*ScheduledBlockTicks {
        const self = try allocator.create(ScheduledBlockTicks);
        self.* = .{};
        self.entries = try preallocated.alloc(ScheduledBlockTick, allocator, 4096);
        self.lookup = try preallocated.alloc(ScheduledBlockTickKey, allocator, 8192);
        @memset(self.lookup, .{});
        return self;
    }

    fn apply(self: *ScheduledBlockTicks, simulation: *Dependencies, random_ticks: *RandomTicks, outputs: *Packets) FatalError!void {
        try runScheduledBlockTicks(simulation, self, random_ticks, outputs);
    }
};

pub const Behavior = struct {
    context: *anyopaque,
    apply: *const fn (*anyopaque, *Invocation) FatalError!void,

    pub fn run(self: Behavior, tick: *Invocation) FatalError!void {
        try self.apply(self.context, tick);
    }
};

const Behaviors = struct {
    scheduled: *ScheduledBlockTicks,
    crops: Behavior,
    growth: Behavior,
    spread: Behavior,
    farmland: Behavior,
    leaves: Behavior,
    fire_and_lava: Behavior,
    ice_and_snow: Behavior,
    copper: Behavior,
    block_events: Behavior,
};

pub const Simulation = struct {
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
    active: ?*chunk_tickets.ChunkTickets = null,
    scheduled: *ScheduledBlockTicks,
    projection: ?*RandomTicks = null,
    materialization: *vanilla_persistence.Materializer,
    io: std.Io,

    fn blockAt(self: *const Simulation, pos: geometry.BlockPos) FatalError!i32 {
        const section = block_store.sectionIndexForY(pos.y) orelse return registry.block_air_default_state;
        if (self.projection) |projection| {
            if (findRandomTickOverride(projection, self.world, pos)) |index|
                return projection.mutation_overrides[index].block_state;
            const chunk = geometry.chunkForBlock(pos);
            if (findRandomTickChunk(projection, self.world, chunk)) |chunk_index| {
                if (projection.chunks[chunk_index].projection_initialized) {
                    if (randomTickProjectedState(projection, chunk_index, section, block_store.localBlockIndexForPosition(pos))) |state|
                        return state;
                }
            }
        }
        if (self.blocks.blockAtIfMaterialized(self.world, pos)) |state| return state;
        return (try self.materialization.readStoredBlock(self.world, pos)) orelse error.StorageReadFailed;
    }

    fn blockFlammable(self: *const Simulation, pos: geometry.BlockPos) FatalError!bool {
        if (self.projection) |projection| if (findRandomTickOverride(projection, self.world, pos)) |index|
            return registry.blockBehaviorFlags(projection.mutation_overrides[index].block_state).flammable;
        return registry.blockBehaviorFlags(try self.blockAt(pos)).flammable;
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

const Dependencies = Simulation;

const random_tick_action_mask_unindexed = std.math.maxInt(u16);
const random_tick_action_state_uniform = std.math.maxInt(u16) - 1;
const random_tick_action_state_unindexed = std.math.maxInt(u16);
const random_tick_action_states_per_page = 256;
const random_tick_inactive_position = std.math.maxInt(u16);

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

const RandomTickCenter = struct {
    slot: u16,
    world: world_identity.Handle,
    chunk_x: i32,
    chunk_z: i32,
};

const RandomTickChunk = struct {
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    random_key: u32,
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
    _padding: [14]u8,
};

const RandomTickGrassProjection = struct {
    heights: [16 * 16]i16,
    grass_above_blocked: [4]u64,
    _padding: [32]u8,
};

const RandomTickGeneralProjection = struct {
    mask_slots: [world_limits.section_count]u16,
    uniform_states: [world_limits.section_count]i32,
    action_mask_slots: [world_limits.section_count]u16,
    action_state_slots: [world_limits.section_count]u16,
};

const RandomTickActionStatePage = struct {
    next: u16,
    count: u16,
    states: [random_tick_action_states_per_page]i32,
};

const RandomTickOverride = struct {
    world: world_identity.Handle = world_identity.invalid,
    pos: geometry.BlockPos = .{ .x = 0, .y = 0, .z = 0 },
    block_state: i32 = registry.block_air_default_state,
};

comptime {
    if (@sizeOf(RandomTickChunk) != 64) @compileError("random tick chunk header must occupy one cache line");
    if (@sizeOf(RandomTickGrassProjection) != 576) @compileError("random tick grass projection layout changed");
}

pub const RandomTicks = struct {
    pub const Trace = RandomTickTrace;
    pub const Dependencies = struct {
        scheduled: *ScheduledBlockTicks,
        crops: Behavior,
        growth: Behavior,
        spread: Behavior,
        farmland: Behavior,
        leaves: Behavior,
        fire_and_lava: Behavior,
        ice_and_snow: Behavior,
        copper: Behavior,
        block_events: Behavior,
        worlds: *world_store.Worlds,
        clock: *world_clock.Clock,
        time: *vanilla_time.Time,
        rules: *game_rules.GameRules,
        random: *world_random.Random,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        active: *chunk_tickets.ChunkTickets,
        admission: *simulation_admission.SimulationAdmission,
        materialization: *vanilla_persistence.Materializer,
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        living: *entity_store.LivingEntities,
        items: *entity_store.ItemEntities,
        outputs: *Packets,
        runtime_metrics: ?*lightning_rod.metrics.Runtime = null,
    };

    pub const Configuration = struct {
        maximum_block_changes: usize = 1_024,
        maximum_mutation_history: usize = 16 * 1024,
        maximum_projected_chunks: usize = 2_048,
        maximum_projection_masks: usize = 2_048,
        maximum_action_state_pages: usize = 2_048,
        maximum_mutation_overrides: usize = 4_096,

        pub fn validate(self: Configuration, blocks: *const block_store.Blocks) !void {
            if (blocks.materialized_chunks.len == 0 or self.maximum_projected_chunks == 0 or
                self.maximum_projected_chunks >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_projected_chunks) or
                self.maximum_projection_masks == 0 or self.maximum_projection_masks >= random_tick_action_mask_unindexed or
                self.maximum_action_state_pages == 0 or self.maximum_action_state_pages >= random_tick_action_state_uniform or
                self.maximum_mutation_overrides == 0 or self.maximum_mutation_overrides >= std.math.maxInt(u16) or
                !std.math.isPowerOfTwo(self.maximum_mutation_overrides) or
                self.maximum_block_changes == 0 or self.maximum_mutation_history < self.maximum_block_changes)
                return error.InvalidRandomTickChunkCapacity;
        }
    };

    topology_initialized: bool = false,
    overflow: bool = false,
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
    chunk_prefetch_generations: []u32 = &.{},
    chunk_allocated: []bool = &.{},
    observed_mutation_sequence: u64 = 0,
    observed_materialization_sequence: u64 = 0,
    observed_ticket_revision: u64 = 0,
    chunks: []align(64) RandomTickChunk = &.{},
    grass: []align(64) RandomTickGrassProjection = &.{},
    general: []align(64) RandomTickGeneralProjection = &.{},
    lookup: []u16 = &.{},
    action_mask_count: usize = 0,
    free_action_mask_count: usize = 0,
    free_action_masks: []u16 = &.{},
    action_masks: []align(64) [block_store.blocks_per_section / 64]u64 = &.{},
    free_action_state_page_count: usize = 0,
    free_action_state_pages: []u16 = &.{},
    action_state_pages: []align(64) RandomTickActionStatePage = &.{},
    mutation_override_count: usize = 0,
    mutation_overrides: []RandomTickOverride = &.{},
    mutation_override_lookup: []u16 = &.{},
    free_base_mask_count: usize = 0,
    free_base_masks: []u16 = &.{},
    base_masks: []align(64) [block_store.blocks_per_section / 64]u64 = &.{},
    action_chunk_positions: []align(64) u64 = &.{},
    maximum_block_changes: usize = 0,
    maximum_mutation_history: usize = 0,
    deps: RandomTicks.Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: RandomTicks.Dependencies, settings: Configuration) !*RandomTicks {
        try settings.validate(deps.blocks);
        const self = try allocator.create(RandomTicks);
        self.* = .{ .deps = deps, .maximum_block_changes = settings.maximum_block_changes, .maximum_mutation_history = settings.maximum_mutation_history };
        try allocateBuffers(self, allocator, settings.maximum_projected_chunks, settings.maximum_projection_masks, settings.maximum_action_state_pages, settings.maximum_mutation_overrides, deps.players.records.len);
        return self;
    }

    pub fn tick(self: *RandomTicks, io: std.Io, _: std.mem.Allocator) FatalError!void {
        const scheduled = self.deps.scheduled;
        const crops = self.deps.crops;
        const growth = self.deps.growth;
        const spread = self.deps.spread;
        const farmland = self.deps.farmland;
        const leaves = self.deps.leaves;
        const fire_and_lava = self.deps.fire_and_lava;
        const ice_and_snow = self.deps.ice_and_snow;
        const copper = self.deps.copper;
        const block_events = self.deps.block_events;
        const worlds = self.deps.worlds;
        const clock = self.deps.clock;
        const time = self.deps.time;
        const rules = self.deps.rules;
        const random = self.deps.random;
        const blocks = self.deps.blocks;
        const players = self.deps.players;
        const living = self.deps.living;
        const items = self.deps.items;
        const outputs = self.deps.outputs;
        const behaviors = Behaviors{ .scheduled = scheduled, .crops = crops, .growth = growth, .spread = spread, .farmland = farmland, .leaves = leaves, .fire_and_lava = fire_and_lava, .ice_and_snow = ice_and_snow, .copper = copper, .block_events = block_events };
        var simulation = Simulation{ .clock = clock, .time = time, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .active = self.deps.active, .scheduled = scheduled, .projection = self, .materialization = self.deps.materialization, .io = io };
        try consumeMaterializations(&simulation, self, worlds);
        try scheduled.apply(&simulation, self, outputs);
        for (worlds.active()) |world| {
            simulation.world = world;
            simulation.seed = worlds.get(world).?.seed;
            try runRandomTicks(&simulation, self, &behaviors, outputs);
        }
        if (self.deps.runtime_metrics) |runtime| runtime.setWorldProjections(
            if (self.chunk_pool_initialized) self.chunks.len - self.free_chunk_count else 0,
            self.chunks.len,
            self.action_mask_count + self.base_masks.len - self.free_base_mask_count,
            self.action_masks.len + self.base_masks.len,
            self.action_state_pages.len - self.free_action_state_page_count,
            self.action_state_pages.len,
            self.overflow,
        );
    }
};

fn consumeMaterializations(simulation: *Dependencies, state: *RandomTicks, worlds: *world_store.Worlds) FatalError!void {
    var cursor = simulation.blocks.materializationCursorFrom(state.observed_materialization_sequence);
    while (cursor.next(simulation.blocks) catch {
        for (0..state.chunks.len) |index| {
            if (!state.chunk_allocated[index] or !state.chunks[index].projection_initialized) continue;
            state.chunks[index].projection_initialized = false;
            releaseRandomTickProjectionMasks(state, index);
        }
        state.mutation_override_count = 0;
        @memset(state.mutation_override_lookup, 0);
        state.topology_initialized = false;
        state.observed_materialization_sequence = simulation.blocks.materializationCursor().sequence;
        return;
    }) |change| {
        const chunk_index = findRandomTickChunk(state, change.world, change.chunk);
        if (chunk_index) |index| state.chunk_prefetch_generations[index] = 0;
        const resident = simulation.blocks.materialized(change) orelse continue;
        const description = worlds.get(change.world) orelse continue;
        simulation.world = change.world;
        simulation.seed = description.seed;
        scheduleMaterializedBlockTicks(simulation, resident);
        const index = chunk_index orelse continue;
        if (state.chunks[index].projection_initialized and
            state.chunks[index].observed_content_revision == change.content_revision) continue;
        const resident_index = simulation.blocks.materializedChunkSlot(change.world, change.chunk) orelse continue;
        const derived = simulation.blocks.ensureMaterializedRandomTickDerived(resident_index);
        clearRandomTickOverrides(state, change.world, change.chunk);
        if (state.chunks[index].projection_initialized) {
            state.chunks[index].projection_initialized = false;
            releaseRandomTickProjectionMasks(state, index);
        }
        try initializeRandomTickProjection(simulation, state, index, derived);
        state.chunks[index].projection_initialized = true;
        state.chunks[index].observed_content_revision = change.content_revision;
        state.topology_initialized = false;
    }
    state.observed_materialization_sequence = cursor.sequence;
}

const ScheduledBlockTickKind = enum(u8) { fire, water_cauldron };

const ScheduledBlockTick = struct {
    due: u64,
    sequence: u32,
    world: world_identity.Handle,
    pos: geometry.BlockPos,
    kind: ScheduledBlockTickKind,
};

const ScheduledBlockTickKey = struct {
    world: world_identity.Handle = world_identity.invalid,
    pos: geometry.BlockPos = .{ .x = 0, .y = std.math.minInt(i16), .z = 0 },
    kind: ScheduledBlockTickKind = .fire,
};

fn scheduledKeyEmpty(key: ScheduledBlockTickKey) bool {
    return key.pos.y == std.math.minInt(i16);
}

fn scheduledKeyEqual(key: ScheduledBlockTickKey, world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) bool {
    return key.kind == kind and key.world.eql(world) and key.pos.x == pos.x and key.pos.y == pos.y and key.pos.z == pos.z;
}

fn scheduledKeyHash(world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) usize {
    var value: u64 = @as(u32, @bitCast(world));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(pos.x));
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

const ScheduledBlockTickReservation = union(enum) {
    existing,
    slot: usize,
};

fn reserveScheduledBlockTick(state: *const ScheduledBlockTicks, world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) ?ScheduledBlockTickReservation {
    const mask = state.lookup.len - 1;
    var probe = scheduledKeyHash(world, pos, kind);
    for (0..state.lookup.len) |_| {
        const index = probe & mask;
        const key = state.lookup[index];
        if (scheduledKeyEmpty(key)) return if (state.count == state.entries.len) null else .{ .slot = index };
        if (scheduledKeyEqual(key, world, pos, kind)) return .existing;
        probe += 1;
    }
    return null;
}

fn removeScheduledKey(state: *ScheduledBlockTicks, world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) void {
    const mask = state.lookup.len - 1;
    var probe = scheduledKeyHash(world, pos, kind);
    var found: ?usize = null;
    for (0..state.lookup.len) |_| {
        const index = probe & mask;
        const key = state.lookup[index];
        if (scheduledKeyEmpty(key)) return;
        if (scheduledKeyEqual(key, world, pos, kind)) {
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
        const ideal = scheduledKeyHash(key.world, key.pos, key.kind) & mask;
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

fn commitScheduledBlockTick(state: *ScheduledBlockTicks, reservation: ScheduledBlockTickReservation, due: u64, world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) void {
    const slot = switch (reservation) {
        .existing => return,
        .slot => |value| value,
    };
    std.debug.assert(state.count < state.entries.len);
    std.debug.assert(scheduledKeyEmpty(state.lookup[slot]));
    state.lookup[slot] = .{ .world = world, .pos = pos, .kind = kind };
    var index: usize = state.count;
    state.count += 1;
    state.sequence +%= 1;
    state.entries[index] = .{ .due = due, .sequence = state.sequence, .world = world, .pos = pos, .kind = kind };
    for (0..std.math.log2_int_ceil(usize, state.entries.len + 1)) |_| {
        if (index == 0) break;
        const parent = (index - 1) / 2;
        if (!scheduledTickBefore(state.entries[index], state.entries[parent])) break;
        std.mem.swap(ScheduledBlockTick, &state.entries[index], &state.entries[parent]);
        index = parent;
    }
}

fn scheduleBlockTick(state: *ScheduledBlockTicks, due: u64, world: world_identity.Handle, pos: geometry.BlockPos, kind: ScheduledBlockTickKind) bool {
    const reservation = reserveScheduledBlockTick(state, world, pos, kind) orelse return false;
    commitScheduledBlockTick(state, reservation, due, world, pos, kind);
    return true;
}

fn popScheduledBlockTick(state: *ScheduledBlockTicks) ScheduledBlockTick {
    const result = state.entries[0];
    removeScheduledKey(state, result.world, result.pos, result.kind);
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
    return simulation.scheduled;
}

fn scheduleFire(simulation: *Dependencies, pos: geometry.BlockPos) bool {
    return scheduleBlockTick(scheduledTicks(simulation), simulation.clock.tick + 30 + simulation.random.random.nextIntBoundedComptime(10), simulation.world, pos, .fire);
}

fn scheduleMaterializedBlockTicks(simulation: *Dependencies, resident: *const block_store.MaterializedChunk) void {
    var sections = resident.modified_section_mask;
    while (sections != 0) {
        const section_index: usize = @intCast(@ctz(sections));
        sections &= sections - 1;
        const section = simulation.blocks.modifiedSection(resident, section_index) orelse continue;
        for (section.modified_bits, 0..) |word, word_index| {
            var remaining = word;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                remaining &= remaining - 1;
                const local_index: u16 = @intCast(word_index * 64 + bit);
                if (blockId(simulation.blocks.modifiedSectionState(section, local_index)) != fire_block_id) continue;
                _ = scheduleFire(simulation, .{
                    .x = section.chunk.x * 16 + @as(i32, local_index & 15),
                    .y = block_store.sectionWorldY(section.section, (local_index >> 8) & 15),
                    .z = section.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
                });
            }
        }
    }
}

fn runScheduledBlockTicks(simulation: *Dependencies, state: *ScheduledBlockTicks, random_ticks: *RandomTicks, outputs: *Packets) FatalError!void {
    var changes: usize = 0;
    for (0..state.entries.len) |_| {
        if (state.count == 0 or state.entries[0].due > simulation.clock.tick) break;
        const scheduled = popScheduledBlockTick(state);
        const description = random_ticks.deps.worlds.get(scheduled.world) orelse continue;
        simulation.world = scheduled.world;
        simulation.seed = description.seed;
        switch (scheduled.kind) {
            .fire => try tickFire(simulation, random_ticks, scheduled.pos, outputs, &changes),
            .water_cauldron => {
                if (blockId(try simulation.blockAt(scheduled.pos)) == cauldron_block_id)
                    _ = try applyRandomTickChange(simulation, random_ticks, scheduled.pos, water_cauldron_level_one, outputs, &changes);
            },
        }
        if (changes == random_ticks.maximum_block_changes) return;
    }
}

const RandomTickTrace = enum {
    topology_check,
    topology_rebuild,
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

fn randomTickEventSeed(seed: u64, tick: u64, chunk_key: u32, section: usize, sample: u16) u64 {
    var value = seed ^ (tick *% 0x9e37_79b9_7f4a_7c15) ^ (@as(u64, chunk_key) << 17) ^
        (@as(u64, section) << 8) ^ sample;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

fn randomTickTopologyMatches(simulation: *const Dependencies, state: *const RandomTicks) bool {
    if (!state.topology_initialized) return false;
    if (state.observed_ticket_revision != state.deps.admission.revision()) return false;
    var center_index: usize = 0;
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator) continue;
        if (center_index == state.center_count) return false;
        const center = state.centers[center_index];
        if (center.slot != slot or !center.world.eql(player.world) or
            center.chunk_x != @divFloor(geometry.blockCoord(player.position.x), 16) or
            center.chunk_z != @divFloor(geometry.blockCoord(player.position.z), 16)) return false;
        center_index += 1;
    }
    return center_index == state.center_count;
}

fn randomTickChunkHash(world: world_identity.Handle, chunk: geometry.ChunkPos) usize {
    var value: u64 = 0xd6e8_feb8_6659_fd93;
    value ^= @as(u32, @bitCast(world));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.x));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(chunk.z));
    value *%= 0xe703_7ed1_a0b4_28db;
    value ^= value >> 32;
    return @intCast(value);
}

fn randomTickOverrideHash(world: world_identity.Handle, pos: geometry.BlockPos) usize {
    var value: u64 = @as(u32, @bitCast(world));
    value *%= 0xa076_1d64_78bd_642f;
    value ^= @as(u32, @bitCast(pos.x));
    value *%= 0xe703_7ed1_a0b4_28db;
    value ^= @as(u16, @bitCast(pos.y));
    value *%= 0x8ebc_6af0_9c88_c6e3;
    value ^= @as(u32, @bitCast(pos.z));
    return @intCast(value ^ (value >> 32));
}

fn findRandomTickOverride(state: *RandomTicks, world: world_identity.Handle, pos: geometry.BlockPos) ?usize {
    var repaired = false;
    search: while (true) {
        const mask = state.mutation_override_lookup.len - 1;
        var lookup_index = randomTickOverrideHash(world, pos) & mask;
        for (0..state.mutation_override_lookup.len) |_| {
            const encoded = state.mutation_override_lookup[lookup_index];
            if (encoded == 0) return null;
            const index: usize = encoded - 1;
            if (index >= state.mutation_override_count or index >= state.mutation_overrides.len) {
                if (repaired) @panic("random tick override lookup is corrupt");
                rebuildRandomTickOverrideLookup(state);
                repaired = true;
                continue :search;
            }
            const entry = state.mutation_overrides[index];
            if (entry.world.eql(world) and entry.pos.x == pos.x and entry.pos.y == pos.y and entry.pos.z == pos.z)
                return index;
            lookup_index = (lookup_index + 1) & mask;
        }
        return null;
    }
}

fn rebuildRandomTickOverrideLookup(state: *RandomTicks) void {
    @memset(state.mutation_override_lookup, 0);
    for (state.mutation_overrides[0..state.mutation_override_count], 0..) |entry, index| {
        const mask = state.mutation_override_lookup.len - 1;
        var lookup_index = randomTickOverrideHash(entry.world, entry.pos) & mask;
        while (state.mutation_override_lookup[lookup_index] != 0)
            lookup_index = (lookup_index + 1) & mask;
        state.mutation_override_lookup[lookup_index] = @intCast(index + 1);
    }
}

fn putRandomTickOverride(state: *RandomTicks, world: world_identity.Handle, pos: geometry.BlockPos, block_state: i32) bool {
    if (findRandomTickOverride(state, world, pos)) |index| {
        state.mutation_overrides[index].block_state = block_state;
        return true;
    }
    if (state.mutation_override_count == state.mutation_overrides.len) return false;
    const index = state.mutation_override_count;
    state.mutation_overrides[index] = .{ .world = world, .pos = pos, .block_state = block_state };
    state.mutation_override_count += 1;
    const mask = state.mutation_override_lookup.len - 1;
    var lookup_index = randomTickOverrideHash(world, pos) & mask;
    while (state.mutation_override_lookup[lookup_index] != 0)
        lookup_index = (lookup_index + 1) & mask;
    state.mutation_override_lookup[lookup_index] = @intCast(index + 1);
    return true;
}

fn clearRandomTickOverrides(state: *RandomTicks, world: world_identity.Handle, chunk: geometry.ChunkPos) void {
    var write: usize = 0;
    for (state.mutation_overrides[0..state.mutation_override_count]) |entry| {
        if (entry.world.eql(world) and geometry.sameChunk(geometry.chunkForBlock(entry.pos), chunk)) continue;
        state.mutation_overrides[write] = entry;
        write += 1;
    }
    if (write == state.mutation_override_count) return;
    state.mutation_override_count = write;
    rebuildRandomTickOverrideLookup(state);
}

fn ensureRandomTickChunkPool(state: *RandomTicks) void {
    if (state.chunk_pool_initialized) return;
    for (0..state.free_chunk_indices.len) |index|
        state.free_chunk_indices[index] = @intCast(state.free_chunk_indices.len - 1 - index);
    state.free_chunk_count = state.free_chunk_indices.len;
    state.chunk_pool_initialized = true;
}

fn allocateRandomTickActionStatePage(state: *RandomTicks) ?u16 {
    if (state.free_action_state_page_count == 0) return null;
    state.free_action_state_page_count -= 1;
    const index = state.free_action_state_pages[state.free_action_state_page_count];
    // Pages are recycled after arbitrary linked-list use.  Clear the header
    // before handing one back out; the state payload is populated by the
    // caller before it can be read.
    state.action_state_pages[index] = .{ .next = 0, .count = 0, .states = undefined };
    return index + 1;
}

fn releaseRandomTickActionStates(state: *RandomTicks, handle: *u16) void {
    var current = handle.*;
    handle.* = 0;
    if (current == 0 or current == random_tick_action_state_uniform or current == random_tick_action_state_unindexed) return;
    while (current != 0) {
        std.debug.assert(current <= state.action_state_pages.len);
        const next = actionStatePage(state, current).next;
        std.debug.assert(state.free_action_state_page_count < state.free_action_state_pages.len);
        state.free_action_state_pages[state.free_action_state_page_count] = current - 1;
        state.free_action_state_page_count += 1;
        current = next;
    }
}

fn allocateRandomTickBaseMask(state: *RandomTicks) ?u16 {
    if (state.free_base_mask_count == 0) return null;
    state.free_base_mask_count -= 1;
    const index = state.free_base_masks[state.free_base_mask_count];
    return index + 1;
}

fn releaseRandomTickBaseMask(state: *RandomTicks, handle: *u16) void {
    if (handle.* == 0 or handle.* == block_store.random_tick_mask_columns or handle.* == block_store.random_tick_mask_unindexed) {
        handle.* = 0;
        return;
    }
    std.debug.assert(handle.* <= state.base_masks.len);
    std.debug.assert(state.free_base_mask_count < state.free_base_masks.len);
    state.free_base_masks[state.free_base_mask_count] = handle.* - 1;
    state.free_base_mask_count += 1;
    handle.* = 0;
}

fn releaseRandomTickBaseMasks(state: *RandomTicks, chunk_index: usize) void {
    for (&state.general[chunk_index].mask_slots) |*handle| releaseRandomTickBaseMask(state, handle);
}

fn allocateRandomTickActionMask(state: *RandomTicks) ?u16 {
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
    for (&state.general[chunk_index].action_mask_slots, &state.general[chunk_index].action_state_slots) |*mask, *states| {
        releaseRandomTickActionMask(state, mask);
        releaseRandomTickActionStates(state, states);
    }
    state.chunks[chunk_index].action_section_mask = 0;
}

fn releaseRandomTickProjectionMasks(state: *RandomTicks, chunk_index: usize) void {
    releaseRandomTickActionMasks(state, chunk_index);
    releaseRandomTickBaseMasks(state, chunk_index);
}

fn actionMask(state: *const RandomTicks, handle: u16) *const [block_store.blocks_per_section / 64]u64 {
    std.debug.assert(handle != 0 and handle <= state.action_masks.len);
    return &state.action_masks[handle - 1];
}

fn actionMaskForWrite(state: *RandomTicks, handle: u16) *[block_store.blocks_per_section / 64]u64 {
    std.debug.assert(handle != 0 and handle <= state.action_masks.len);
    return &state.action_masks[handle - 1];
}

fn baseMask(state: *const RandomTicks, handle: u16) *const [block_store.blocks_per_section / 64]u64 {
    std.debug.assert(handle != 0 and handle <= state.base_masks.len);
    return &state.base_masks[handle - 1];
}

fn baseMaskForWrite(state: *RandomTicks, handle: u16) *[block_store.blocks_per_section / 64]u64 {
    std.debug.assert(handle != 0 and handle <= state.base_masks.len);
    return &state.base_masks[handle - 1];
}

fn actionStatePage(state: *const RandomTicks, handle: u16) *const RandomTickActionStatePage {
    std.debug.assert(handle != 0 and handle <= state.action_state_pages.len);
    return &state.action_state_pages[handle - 1];
}

fn actionStatePageForWrite(state: *RandomTicks, handle: u16) *RandomTickActionStatePage {
    std.debug.assert(handle != 0 and handle <= state.action_state_pages.len);
    return &state.action_state_pages[handle - 1];
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

fn refreshRandomTickSections(active: *RandomTickChunk, generated: *const block_store.MaterializedChunk) void {
    active.section_mask = generated.random_tick_sections;
    active.observed_modified_section_mask = generated.modified_section_mask;
}

fn baseSectionSupportsProjectedGrass(simulation: *const Dependencies, state: *const RandomTicks, chunk_index: usize, generated: *const block_store.MaterializedChunk, section: usize) bool {
    const handle = state.general[chunk_index].mask_slots[section];
    if (handle == 0) return false;
    if (handle == block_store.random_tick_mask_columns)
        return generated.random_tick_uniform_states[section] == registry.block_grass_block_default_state;

    if (handle != block_store.random_tick_mask_unindexed) {
        for (baseMask(state, handle), 0..) |word, word_index| {
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

fn initializeRandomTickProjection(simulation: *const Dependencies, state: *RandomTicks, active_index: usize, generated: *const block_store.MaterializedChunk) FatalError!void {
    const active = &state.chunks[active_index];
    const grass = &state.grass[active_index];
    const general = &state.general[active_index];
    active.base_section_mask = generated.random_tick_sections;
    active.grass_section_mask = 0;
    active.action_section_mask = 0;
    grass.heights = generated.heights;
    grass.grass_above_blocked = generated.grass_above_blocked;
    general.mask_slots = [_]u16{0} ** world_limits.section_count;
    general.uniform_states = generated.random_tick_uniform_states;
    general.action_mask_slots = [_]u16{0} ** world_limits.section_count;
    general.action_state_slots = [_]u16{0} ** world_limits.section_count;
    var sections = active.base_section_mask;
    while (sections != 0) {
        const section: usize = @intCast(@ctz(sections));
        sections &= sections - 1;
        const source_handle = generated.random_tick_mask_handles[section];
        general.mask_slots[section] = switch (source_handle) {
            0, block_store.random_tick_mask_columns, block_store.random_tick_mask_unindexed => source_handle,
            else => if (allocateRandomTickBaseMask(state)) |handle| copy: {
                @memcpy(baseMaskForWrite(state, handle), &simulation.blocks.random_tick_masks[source_handle - 1]);
                break :copy handle;
            } else block_store.random_tick_mask_unindexed,
        };
        if (baseSectionSupportsProjectedGrass(simulation, state, active_index, generated, section)) {
            active.grass_section_mask |= @as(u32, 1) << @intCast(section);
        }
    }
    try refreshRandomTickModifiedProjection(simulation, state, active_index, generated);
}

fn refreshRandomTickModifiedProjection(simulation: *const Dependencies, state: *RandomTicks, chunk_index: usize, generated: *const block_store.MaterializedChunk) FatalError!void {
    const active = &state.chunks[chunk_index];
    refreshRandomTickSections(active, generated);
    for (0..world_limits.section_count) |section| {
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
    try refreshRandomTickActionProjection(simulation, state, chunk_index, generated);
}

fn findRandomTickChunkInLookup(state: *const RandomTicks, lookup: []const u16, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
    const mask = lookup.len - 1;
    var slot = randomTickChunkHash(world, chunk) & mask;
    for (0..lookup.len) |_| {
        const encoded = lookup[slot];
        if (encoded == 0) return null;
        const index = encoded - 1;
        const existing = state.chunks[index].chunk;
        if (state.chunks[index].world.eql(world) and existing.x == chunk.x and existing.z == chunk.z) return index;
        slot = (slot + 1) & mask;
    }
    return null;
}

fn findRandomTickChunk(state: *const RandomTicks, world: world_identity.Handle, chunk: geometry.ChunkPos) ?usize {
    return findRandomTickChunkInLookup(state, state.lookup, world, chunk);
}

fn insertRandomTickChunkLookup(state: *const RandomTicks, lookup: []u16, chunk_index: usize) void {
    const mask = lookup.len - 1;
    var slot = randomTickChunkHash(state.chunks[chunk_index].world, state.chunks[chunk_index].chunk) & mask;
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
    var slot = randomTickChunkHash(state.chunks[chunk_index].world, chunk) & mask;
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
        releaseRandomTickProjectionMasks(state, chunk_index);
    removeRandomTickChunkLookup(state, state.lookup, chunk_index);
    state.chunk_topology_generations[chunk_index] = 0;
    state.chunk_prefetch_generations[chunk_index] = 0;
    state.chunk_allocated[chunk_index] = false;
    state.chunks[chunk_index] = undefined;
    state.grass[chunk_index] = undefined;
    state.general[chunk_index] = undefined;
    std.debug.assert(state.free_chunk_count < state.free_chunk_indices.len);
    state.free_chunk_indices[state.free_chunk_count] = @intCast(chunk_index);
    state.free_chunk_count += 1;
}

const RandomTickActivation = enum {
    active,
    not_materialized,
    capacity,
};

fn requestRandomTickNeighborhood(simulation: *Dependencies, state: *RandomTicks, chunk: geometry.ChunkPos) void {
    var chunk_z = chunk.z - 1;
    while (chunk_z <= chunk.z + 1) : (chunk_z += 1) {
        var chunk_x = chunk.x - 1;
        while (chunk_x <= chunk.x + 1) : (chunk_x += 1) {
            const neighbor = geometry.ChunkPos{ .x = chunk_x, .z = chunk_z };
            const neighbor_index = resolveRandomTickChunk(simulation, state, neighbor) orelse {
                _ = state.deps.materialization.requestProjection(simulation.world, neighbor);
                continue;
            };
            requestRandomTickProjection(simulation, state, neighbor_index);
        }
    }
}

fn requestRandomTickProjection(simulation: *const Dependencies, state: *RandomTicks, chunk_index: usize) void {
    if (state.chunk_prefetch_generations[chunk_index] != 0) return;
    const active = state.chunks[chunk_index];
    if (simulation.blocks.materializedChunk(active.world, active.chunk) != null) return;
    _ = rememberRandomTickProjection(
        &state.chunk_prefetch_generations[chunk_index],
        state.deps.materialization.requestProjection(active.world, active.chunk),
    );
}

fn rememberRandomTickProjection(prefetch: *u32, result: vanilla_persistence.RequestResult) bool {
    switch (result) {
        .pending, .submitted => {
            prefetch.* = 1;
            return true;
        },
        .resident, .backpressured => return false,
    }
}

test "random tick projection claims deduplicate overlap and retry backpressure" {
    var prefetch = [_]u32{0} ** 9;
    var submitted: usize = 0;
    for (0..2) |_| {
        for (&prefetch) |*claimed| {
            if (claimed.* != 0) continue;
            if (rememberRandomTickProjection(claimed, .submitted)) submitted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 9), submitted);

    prefetch[4] = 0; // Its materialization was evicted after the prior request completed.
    try std.testing.expect(!rememberRandomTickProjection(&prefetch[4], .backpressured));
    try std.testing.expectEqual(@as(u32, 0), prefetch[4]);
    try std.testing.expect(rememberRandomTickProjection(&prefetch[4], .submitted));
    try std.testing.expectEqual(@as(u32, 1), prefetch[4]);
}

test "random tick direct pools reuse bounded slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RandomTicks = .{ .deps = undefined };
    try allocateBuffers(&state, arena.allocator(), 2, 1, 2, 1, 0);

    var base = allocateRandomTickBaseMask(&state).?;
    const base_slot = base;
    baseMaskForWrite(&state, base)[0] = 0x7f;
    releaseRandomTickBaseMask(&state, &base);
    const reused_base = allocateRandomTickBaseMask(&state).?;
    try std.testing.expectEqual(base_slot, reused_base);

    var action = allocateRandomTickActionMask(&state).?;
    const action_slot = action;
    actionMaskForWrite(&state, action)[0] = 0x7f;
    releaseRandomTickActionMask(&state, &action);
    const reused_action = allocateRandomTickActionMask(&state).?;
    try std.testing.expectEqual(action_slot, reused_action);
    try std.testing.expectEqual(@as(usize, 1), state.action_mask_count);

    var first = allocateRandomTickActionStatePage(&state).?;
    const second = allocateRandomTickActionStatePage(&state).?;
    actionStatePageForWrite(&state, first).next = second;
    actionStatePageForWrite(&state, first).count = 1;
    releaseRandomTickActionStates(&state, &first);
    try std.testing.expectEqual(state.action_state_pages.len, state.free_action_state_page_count);
    const reused_state = allocateRandomTickActionStatePage(&state).?;
    try std.testing.expectEqual(@as(u16, 0), actionStatePage(&state, reused_state).next);
    try std.testing.expectEqual(@as(u16, 0), actionStatePage(&state, reused_state).count);
}

fn activateRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, chunk_index: usize, level_type: VanillaChunkLevelType) FatalError!RandomTickActivation {
    const existing = &state.chunks[chunk_index];
    const chunk = existing.chunk;
    existing.level_type = level_type;
    const was_active = state.chunk_topology_generations[chunk_index] != 0;

    const resident = simulation.blocks.materializedChunkRef(simulation.world, chunk, simulation.clock.tick);
    if (resident == null and !existing.projection_initialized) {
        requestRandomTickNeighborhood(simulation, state, chunk);
        return .not_materialized;
    }
    if (state.chunk_count == state.active_chunk_indices.len) return .capacity;
    state.chunk_was_active[chunk_index] = was_active;
    state.chunk_topology_generations[chunk_index] = state.topology_generation;
    state.active_chunk_indices[state.chunk_count] = @intCast(chunk_index);
    state.chunk_count += 1;

    if (!existing.projection_initialized) {
        const materialized = resident.?;
        existing.observed_content_revision = materialized.entry.content_revision;
        try initializeRandomTickProjection(
            simulation,
            state,
            chunk_index,
            simulation.blocks.ensureMaterializedRandomTickDerived(materialized.index),
        );
        existing.projection_initialized = true;
        state.chunk_prefetch_generations[chunk_index] = 0;
        return .active;
    }

    if (resident) |materialized| if (existing.observed_content_revision != materialized.entry.content_revision) {
        existing.projection_initialized = false;
        releaseRandomTickProjectionMasks(state, chunk_index);
        existing.observed_content_revision = materialized.entry.content_revision;
        try initializeRandomTickProjection(
            simulation,
            state,
            chunk_index,
            simulation.blocks.ensureMaterializedRandomTickDerived(materialized.index),
        );
        existing.projection_initialized = true;
    };
    return .active;
}

fn resolveRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, chunk: geometry.ChunkPos) ?usize {
    ensureRandomTickChunkPool(state);
    if (findRandomTickChunk(state, simulation.world, chunk)) |chunk_index| return chunk_index;
    if (state.free_chunk_count == 0) return null;
    state.free_chunk_count -= 1;
    const chunk_index: usize = state.free_chunk_indices[state.free_chunk_count];
    const resident = simulation.blocks.materializedChunkRef(simulation.world, chunk, simulation.clock.tick);
    state.chunks[chunk_index] = .{
        .world = simulation.world,
        .chunk = chunk,
        .random_key = randomTickChunkKey(simulation.seed, chunk),
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
    return (try activateRandomTickChunk(simulation, state, chunk_index, level_type)) != .capacity;
}

fn markModifiedNeighborhood(state: *RandomTicks, world: world_identity.Handle, chunk: geometry.ChunkPos) void {
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const neighbor = geometry.ChunkPos{ .x = chunk.x + dx, .z = chunk.z + dz };
            if (findRandomTickChunk(state, world, neighbor)) |index| state.chunks[index].exact_grass_neighborhood = true;
        }
    }
}

fn chunkHasGrassSpreadCandidate(simulation: *const Dependencies, active: *const RandomTickChunk) bool {
    const resident = simulation.blocks.materializedChunk(active.world, active.chunk) orelse return false;
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
                if (pos.y > world_limits.min_y) {
                    const below = geometry.BlockPos{ .x = pos.x, .y = pos.y - 1, .z = pos.z };
                    if (simulation.blocks.grassCanSpreadAt(resident, below)) return true;
                }
            }
        }
    }
    return false;
}

fn refreshRandomTickSectionPresence(simulation: *const Dependencies, active: *RandomTickChunk, resident: *const block_store.MaterializedChunk, section: usize, modified_index: ?usize) void {
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

fn initializeRandomTickNeighborhoods(simulation: *Dependencies, state: *RandomTicks) FatalError!void {
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = &state.chunks[chunk_index];
        simulation.world = active.world;
        simulation.seed = state.deps.worlds.get(active.world).?.seed;
        state.previous_exact_neighborhoods[chunk_index] = active.exact_grass_neighborhood;
        if (!state.chunk_was_active[chunk_index])
            active.base_grass_candidate_source = chunkHasGrassSpreadCandidate(simulation, active);
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        if (!state.chunk_was_active[chunk_index] and active.base_grass_candidate_source)
            markModifiedNeighborhood(state, active.world, active.chunk);
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        simulation.world = active.world;
        simulation.seed = state.deps.worlds.get(active.world).?.seed;
        if (state.chunk_was_active[chunk_index] or active.exact_grass_neighborhood) continue;
        var dz: i32 = -1;
        while (dz <= 1 and !state.chunks[chunk_index].exact_grass_neighborhood) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const neighbor = geometry.ChunkPos{ .x = active.chunk.x + dx, .z = active.chunk.z + dz };
                const neighbor_index = findRandomTickChunk(state, simulation.world, neighbor) orelse continue;
                if (!state.chunks[neighbor_index].base_grass_candidate_source) continue;
                state.chunks[chunk_index].exact_grass_neighborhood = true;
                break;
            }
        }
    }
    for (state.active_chunk_indices[0..state.chunk_count]) |chunk_index| {
        const active = state.chunks[chunk_index];
        if (active.exact_grass_neighborhood == state.previous_exact_neighborhoods[chunk_index]) continue;
        simulation.world = active.world;
        simulation.seed = state.deps.worlds.get(active.world).?.seed;
        if (simulation.blocks.materializedChunk(active.world, active.chunk)) |resident|
            try refreshRandomTickActionProjection(simulation, state, chunk_index, resident);
    }
    state.observed_mutation_sequence = simulation.blocks.blockMutationSequence();
}

fn blockCanBeGrassCandidate(block_state: i32) bool {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return false;
    return game_data.blockInfo(block_state).default_state == registry.block_dirt_default_state;
}

fn blockObstructsGrass(block_state: i32) bool {
    return block_state >= 0 and block_state < registry.block_state_to_block.len and game_data.preventsGrassSurvival(block_state);
}

fn reconcileRandomTickMutation(simulation: *const Dependencies, state: *RandomTicks, mutation: geometry.BlockMutation) FatalError!void {
    if (!mutation.world.eql(simulation.world)) return;
    const chunk = geometry.chunkForBlock(mutation.pos);
    const active_index = findRandomTickChunk(state, simulation.world, chunk) orelse return;
    if (state.chunk_topology_generations[active_index] != state.topology_generation) return;
    if (!putRandomTickOverride(state, mutation.world, mutation.pos, mutation.block_state)) {
        state.topology_initialized = false;
        requestRandomTickProjection(simulation, state, active_index);
        return;
    }
    const candidate_changed = blockCanBeGrassCandidate(mutation.previous_state) != blockCanBeGrassCandidate(mutation.block_state);
    const spreadable_changed = registry.randomTickState(mutation.previous_state).kind == .spreadable or
        registry.randomTickState(mutation.block_state).kind == .spreadable;
    var obstruction_candidate: ?geometry.BlockPos = null;
    if (mutation.pos.y > world_limits.min_y and blockObstructsGrass(mutation.previous_state) != blockObstructsGrass(mutation.block_state)) {
        const below = geometry.BlockPos{ .x = mutation.pos.x, .y = mutation.pos.y - 1, .z = mutation.pos.z };
        const below_state = try simulation.blockAt(below);
        if (blockCanBeGrassCandidate(below_state) or registry.randomTickState(below_state).kind == .spreadable)
            obstruction_candidate = below;
    }
    if (candidate_changed or spreadable_changed or obstruction_candidate != null) markModifiedNeighborhood(state, simulation.world, chunk);
    if (obstruction_candidate) |candidate| {
        const candidate_chunk = geometry.chunkForBlock(candidate);
        if (findRandomTickChunk(state, simulation.world, candidate_chunk)) |index| {
            const column: usize = @as(usize, @intCast(candidate.x & 15)) | (@as(usize, @intCast(candidate.z & 15)) << 4);
            const bit = @as(u64, 1) << @intCast(column & 63);
            if (blockObstructsGrass(mutation.block_state))
                state.grass[index].grass_above_blocked[column / 64] |= bit
            else
                state.grass[index].grass_above_blocked[column / 64] &= ~bit;
        }
    }
}

fn reconcilePendingRandomTickMutations(simulation: *Dependencies, state: *RandomTicks) FatalError!bool {
    const latest = simulation.blocks.blockMutationSequence();
    const pending = latest -% state.observed_mutation_sequence;
    if (pending > state.maximum_mutation_history) return false;
    const original_world = simulation.world;
    const original_seed = simulation.seed;
    defer {
        simulation.world = original_world;
        simulation.seed = original_seed;
    }
    var cursor = simulation.blocks.mutationCursorFrom(state.observed_mutation_sequence);
    while (cursor.next(simulation.blocks) catch return false) |mutation| {
        const description = state.deps.worlds.get(mutation.world) orelse continue;
        simulation.world = mutation.world;
        simulation.seed = description.seed;
        try reconcileRandomTickMutation(simulation, state, mutation);
    }
    state.observed_mutation_sequence = cursor.sequence;
    return true;
}

fn reconcileLatestRandomTickMutation(simulation: *Dependencies, state: *RandomTicks) FatalError!void {
    const latest = simulation.blocks.blockMutationSequence();
    if (latest == state.observed_mutation_sequence) return;
    if (!(try reconcilePendingRandomTickMutations(simulation, state))) {
        state.topology_initialized = false;
    }
}

fn finishRandomTickTopologyRebuild(state: *RandomTicks) void {
    for (0..state.chunks.len) |chunk_index| {
        if (!state.chunk_allocated[chunk_index]) continue;
        if (state.chunk_topology_generations[chunk_index] == state.topology_generation or
            state.chunk_prefetch_generations[chunk_index] != 0) continue;
        releaseRandomTickChunk(state, chunk_index);
    }
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

fn rebuildRandomTickChunks(simulation: *Dependencies, state: *RandomTicks, radius: i32) FatalError!void {
    beginTopologyRebuild(state);
    collectRandomTickCenters(simulation, state);
    _ = radius;
    try activateRandomTickTopology(simulation, state);
    {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_retirement);
        defer trace.end();
        finishRandomTickTopologyRebuild(state);
    }
    {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_neighborhoods);
        defer trace.end();
        try initializeRandomTickNeighborhoods(simulation, state);
    }
    rebuildRandomTickActionChunkPositions(state);
    state.observed_ticket_revision = state.deps.admission.revision();
}

fn activateRandomTickTopology(simulation: *Dependencies, state: *RandomTicks) FatalError!void {
    var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_activation);
    defer trace.end();
    var iterator = state.deps.admission.iterator();
    while (iterator.next()) |active| {
        simulation.world = active.world;
        simulation.seed = state.deps.worlds.get(active.world).?.seed;
        const level: VanillaChunkLevelType = switch (active.level) {
            .full => .full,
            .block_ticking => .block_ticking,
            .entity_ticking => .entity_ticking,
        };
        const chunk_index = resolveRandomTickChunk(simulation, state, active.chunk) orelse {
            state.overflow = true;
            continue;
        };
        const activation = try activateRandomTickChunk(simulation, state, chunk_index, level);
        if (activation == .capacity) {
            state.overflow = true;
            continue;
        }
    }
    state.ticking_chunk_count = 0;
    for (0..state.chunk_count) |position| {
        const chunk_index = state.active_chunk_indices[position];
        if (state.chunks[chunk_index].level_type != .entity_ticking) continue;
        const previous = state.active_chunk_indices[state.ticking_chunk_count];
        state.active_chunk_indices[state.ticking_chunk_count] = chunk_index;
        state.active_chunk_indices[position] = previous;
        state.ticking_chunk_count += 1;
    }
}

fn beginTopologyRebuild(state: *RandomTicks) void {
    state.topology_generation +%= 1;
    if (state.topology_generation == 0) {
        @memset(state.chunk_topology_generations, 0);
        @memset(state.chunk_prefetch_generations, 0);
        state.topology_generation = 1;
    }
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

fn collectRandomTickCenters(simulation: *Dependencies, state: *RandomTicks) void {
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or player.gamemode == .spectator) continue;
        const center_x = @divFloor(geometry.blockCoord(player.position.x), 16);
        const center_z = @divFloor(geometry.blockCoord(player.position.z), 16);
        state.centers[state.center_count] = .{ .slot = slot, .world = player.world, .chunk_x = center_x, .chunk_z = center_z };
        state.center_count += 1;
    }
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
) FatalError!bool {
    const active = &state.chunks[active_index];
    const action_handle = state.general[active_index].action_mask_slots[section];
    const action_states = state.general[active_index].action_state_slots[section];
    const resident = if (action_handle == random_tick_action_mask_unindexed or
        action_states == random_tick_action_state_unindexed)
        materializedForRandomTickTicket(simulation, active) orelse {
            requestRandomTickProjection(simulation, state, active_index);
            return false;
        }
    else
        null;
    var modified_index: ?usize = undefined;
    var modified_index_initialized = false;
    var observed_mutation_sequence = simulation.blocks.blockMutationSequence();
    workload.action_sections += 1;
    workload.coordinate_probes += simulation.rules.random_tick_speed;
    if (action_handle == random_tick_action_mask_unindexed)
        workload.unindexed_sections += 1;
    var first_sample: u16 = 0;
    while (first_sample < simulation.rules.random_tick_speed) : (first_sample += 4) {
        const samples = randomTickSamplesForTickKey(active.random_key, sample_tick_key, section, first_sample);
        const lane_count: u16 = @min(4, simulation.rules.random_tick_speed - first_sample);
        for (samples[0..lane_count], 0..) |sample_bits, lane| {
            const local_index = sample_bits & (block_store.blocks_per_section - 1);
            const pos = geometry.BlockPos{
                .x = active.chunk.x * 16 + @as(i32, @intCast(local_index & 15)),
                .y = block_store.sectionWorldY(section, (local_index >> 8) & 15),
                .z = active.chunk.z * 16 + @as(i32, @intCast((local_index >> 4) & 15)),
            };
            const override = findRandomTickOverride(state, active.world, pos);
            if (override == null and action_handle == 0) continue;
            if (override == null and action_handle != 0 and action_handle != random_tick_action_mask_unindexed) {
                const word = actionMask(state, action_handle)[local_index / 64];
                if (word & (@as(u64, 1) << @intCast(local_index & 63)) == 0) continue;
            }
            if (resident != null and !modified_index_initialized) {
                const encoded = resident.?.modified_section_indices[section];
                modified_index = if (encoded == block_store.no_modified_section_index) null else encoded;
                modified_index_initialized = true;
            }
            const selected_state = if (override) |index|
                state.mutation_overrides[index].block_state
            else if (randomTickProjectedState(state, active_index, section, local_index)) |projected|
                projected
            else if (resident) |materialized|
                simulation.blocks.sectionBlockState(materialized, section, local_index, modified_index)
            else {
                requestRandomTickProjection(simulation, state, active_index);
                return false;
            };
            if (selected_state < 0 or selected_state >= registry.block_state_to_block.len)
                diagnostics.panic("invalid selected random-tick state (state, chunk x, chunk z, section, local index)", &.{ diagnostics.integer(selected_state), diagnostics.integer(active.chunk.x), diagnostics.integer(active.chunk.z), diagnostics.integer(section), diagnostics.integer(local_index) });
            if (override != null and !randomTickStateIsActionable(selected_state)) continue;
            if (override == null and action_handle == random_tick_action_mask_unindexed and
                !try randomTickBlockIsActionable(simulation, state, active_index, resident.?, section, local_index, selected_state)) continue;
            workload.action_hits += 1;
            const saved_random = simulation.random.random;
            simulation.random.random = world_random.DeterministicRng.init(randomTickEventSeed(
                simulation.seed,
                simulation.clock.tick,
                active.random_key,
                section,
                first_sample + @as(u16, @intCast(lane)),
            ));
            const stopped = try randomTickSelectedBlock(simulation, state, behaviors, active_index, resident, active.chunk, section, local_index, selected_state, true, outputs, changes);
            simulation.random.random = saved_random;
            if (stopped) return true;
            if (simulation.blocks.blockMutationSequence() != observed_mutation_sequence) {
                observed_mutation_sequence = simulation.blocks.blockMutationSequence();
                if (resident == null) continue;
                const encoded = resident.?.modified_section_indices[section];
                modified_index = if (encoded == block_store.no_modified_section_index) null else encoded;
            }
        }
    }
    return false;
}

fn randomTickStateIsActionable(block_state: i32) bool {
    if (block_state < 0 or block_state >= registry.block_state_to_block.len) return false;
    return switch (registry.randomTickState(block_state).kind) {
        .none, .mud => false,
        .leaves => isDecayingOakLeaves(block_state),
        else => true,
    };
}

fn runRandomTickChunk(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, active_index: usize, outputs: *Packets, changes: *usize, workload: *RandomTickWorkload, sample_tick_key: u32) FatalError!bool {
    workload.action_chunks += 1;
    var processed_sections: u32 = 0;
    var remaining_sections = state.chunks[active_index].action_section_mask;
    while (remaining_sections != 0) {
        const section: usize = @intCast(@ctz(remaining_sections));
        const section_bit = @as(u32, 1) << @intCast(section);
        processed_sections |= section_bit;
        if (try runRandomTickSection(simulation, state, behaviors, active_index, section, outputs, changes, workload, sample_tick_key)) return true;
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
        if (word_index >= state.action_chunk_positions.len or
            word_index * 64 >= state.ticking_chunk_count) return null;
        word = state.action_chunk_positions[word_index];
    }
    return null;
}

fn runRandomTicks(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, outputs: *Packets) FatalError!void {
    const active = simulation.active orelse return;
    const world = simulation.world;
    const seed = simulation.seed;
    const radius = entityTickingRadius(active.simulationDistance());
    if (!simulation.rules.do_random_ticks) return;
    const topology_matches = topology_matches: {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_check);
        defer trace.end();
        break :topology_matches randomTickTopologyMatches(simulation, state);
    };
    if (!topology_matches) {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.topology_rebuild);
        defer trace.end();
        try rebuildRandomTickChunks(simulation, state, radius);
        simulation.world = world;
        simulation.seed = seed;
    }
    if (state.observed_mutation_sequence != simulation.blocks.blockMutationSequence()) {
        var trace = plugin_profiler.beginTrace(RandomTickTrace.mutation_reconcile);
        defer trace.end();
        if (!(try reconcilePendingRandomTickMutations(simulation, state))) try rebuildRandomTickChunks(simulation, state, radius);
        simulation.world = world;
        simulation.seed = seed;
    }
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
    var first_position: usize = 0;
    for (0..state.active_chunk_indices.len) |_| {
        const position = nextRandomTickActionChunkPosition(state, first_position) orelse break;
        first_position = position + 1;
        const active_index = state.active_chunk_indices[position];
        if (!state.chunks[active_index].world.eql(simulation.world)) continue;
        if (try runRandomTickChunk(simulation, state, behaviors, active_index, outputs, &changes, &workload, sample_tick_key)) return;
    }
}

fn grassHasSpreadCandidateNear(simulation: *const Dependencies, origin: geometry.BlockPos) FatalError!bool {
    var y_offset: i16 = -3;
    while (y_offset <= 1) : (y_offset += 1) {
        var z_offset: i32 = -1;
        while (z_offset <= 1) : (z_offset += 1) {
            var x_offset: i32 = -1;
            while (x_offset <= 1) : (x_offset += 1) {
                const candidate = geometry.BlockPos{ .x = origin.x + x_offset, .y = origin.y + y_offset, .z = origin.z + z_offset };
                if (!player_store.validBuildY(candidate.y)) continue;
                if (game_data.blockInfo(try simulation.blockAt(candidate)).default_state == registry.block_dirt_default_state and
                    !game_data.preventsGrassSurvival(try simulation.blockAt(.{ .x = candidate.x, .y = candidate.y + 1, .z = candidate.z }))) return true;
            }
        }
    }
    return false;
}

fn randomTickBlockIsActionable(
    simulation: *const Dependencies,
    state: *const RandomTicks,
    active_index: ?usize,
    resident: *const block_store.MaterializedChunk,
    section: usize,
    local_index: u16,
    block_state: i32,
) FatalError!bool {
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
            break :blk try grassHasSpreadCandidateNear(simulation, pos);
        },
        else => true,
    };
}

fn countRandomTickActions(simulation: *const Dependencies, state: *const RandomTicks, active_index: ?usize, resident: *const block_store.MaterializedChunk, section: usize, modified_index: ?usize, output: ?*[block_store.blocks_per_section / 64]u64) FatalError!u16 {
    if (output) |mask| @memset(mask, 0);
    const section_bit = @as(u32, 1) << @intCast(section);
    if (active_index != null and modified_index == null and state.chunks[active_index.?].grass_section_mask & section_bit != 0) {
        const index = active_index.?;
        var count: u16 = 0;
        for (resident.heights, 0..) |height, column| {
            const local_y: u16 = @intCast((@as(i32, height) - @as(i32, world_limits.min_y)) & 15);
            if (height != block_store.sectionWorldY(section, local_y)) continue;
            const blocked = state.grass[index].grass_above_blocked[column / 64] & (@as(u64, 1) << @intCast(column & 63)) != 0;
            const local_index: u16 = @intCast(column | (@as(usize, local_y) << 8));
            const pos = geometry.BlockPos{
                .x = resident.chunk.x * 16 + @as(i32, local_index & 15),
                .y = block_store.sectionWorldY(section, local_y),
                .z = resident.chunk.z * 16 + @as(i32, (local_index >> 4) & 15),
            };
            if (blocked or (state.chunks[index].exact_grass_neighborhood and try grassHasSpreadCandidateNear(simulation, pos))) {
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
        if (try randomTickBlockIsActionable(simulation, state, active_index, resident, section, local_index, block_state)) {
            if (output) |mask| mask[local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
            count += 1;
        }
    }
    return count;
}

fn buildRandomTickActionStates(
    simulation: *const Dependencies,
    state: *RandomTicks,
    chunk_index: usize,
    resident: *const block_store.MaterializedChunk,
    section: usize,
    modified_index: ?usize,
    mask: *const [block_store.blocks_per_section / 64]u64,
) u16 {
    var head: u16 = 0;
    var tail: u16 = 0;
    var first_state: i32 = 0;
    var state_count: usize = 0;
    var uniform = true;
    for (mask, 0..) |word, word_index| {
        var remaining = word;
        while (remaining != 0) {
            const bit: u6 = @intCast(@ctz(remaining));
            remaining &= remaining - 1;
            const local_index: u16 = @intCast(word_index * 64 + bit);
            const block_state = simulation.blocks.sectionBlockState(resident, section, local_index, modified_index);
            if (state_count == 0)
                first_state = block_state
            else if (block_state != first_state)
                uniform = false;
            if (tail == 0 or actionStatePage(state, tail).count == random_tick_action_states_per_page) {
                const next = allocateRandomTickActionStatePage(state) orelse {
                    releaseRandomTickActionStates(state, &head);
                    return random_tick_action_state_unindexed;
                };
                if (tail == 0)
                    head = next
                else
                    actionStatePageForWrite(state, tail).next = next;
                tail = next;
            }
            const page = actionStatePageForWrite(state, tail);
            page.states[page.count] = block_state;
            page.count += 1;
            state_count += 1;
        }
    }
    if (uniform) {
        releaseRandomTickActionStates(state, &head);
        state.general[chunk_index].uniform_states[section] = first_state;
        return random_tick_action_state_uniform;
    }
    return head;
}

fn randomTickProjectedState(state: *RandomTicks, chunk_index: usize, section: usize, local_index: u16) ?i32 {
    if (chunk_index >= state.general.len or section >= world_limits.section_count or local_index >= block_store.blocks_per_section) {
        state.topology_initialized = false;
        state.overflow = true;
        return null;
    }
    const mask_handle = state.general[chunk_index].action_mask_slots[section];
    if (mask_handle == 0) return null;
    if (mask_handle != random_tick_action_mask_unindexed and mask_handle > state.action_masks.len) {
        state.topology_initialized = false;
        state.overflow = true;
        return null;
    }
    if (mask_handle != random_tick_action_mask_unindexed and
        actionMask(state, mask_handle)[local_index / 64] & (@as(u64, 1) << @intCast(local_index & 63)) == 0) return null;
    const state_handle = state.general[chunk_index].action_state_slots[section];
    if (state_handle == random_tick_action_state_uniform)
        return state.general[chunk_index].uniform_states[section];
    if (state_handle == 0 or state_handle == random_tick_action_state_unindexed or mask_handle == random_tick_action_mask_unindexed)
        return null;
    var rank: usize = 0;
    const mask = actionMask(state, mask_handle);
    for (mask[0 .. local_index / 64]) |word| rank += @popCount(word);
    const last_word = mask[local_index / 64];
    const before = if ((local_index & 63) == 0) @as(u64, 0) else (@as(u64, 1) << @intCast(local_index & 63)) - 1;
    rank += @popCount(last_word & before);
    var handle = state_handle;
    for (0..state.action_state_pages.len) |_| {
        if (handle == 0) return null;
        if (handle > state.action_state_pages.len) {
            state.topology_initialized = false;
            state.overflow = true;
            return null;
        }
        const page = actionStatePage(state, handle);
        if (rank < page.count) return page.states[rank];
        rank -= page.count;
        handle = page.next;
    }
    state.topology_initialized = false;
    state.overflow = true;
    return null;
}

fn refreshRandomTickActionProjection(simulation: *const Dependencies, state: *RandomTicks, active_index: usize, resident: *const block_store.MaterializedChunk) FatalError!void {
    const active = &state.chunks[active_index];
    active.action_section_mask = 0;
    var scratch: [block_store.blocks_per_section / 64]u64 = undefined;
    for (0..world_limits.section_count) |section| {
        const section_bit = @as(u32, 1) << @intCast(section);
        const handle = &state.general[active_index].action_mask_slots[section];
        const states = &state.general[active_index].action_state_slots[section];
        if (active.section_mask & section_bit == 0) {
            releaseRandomTickActionMask(state, handle);
            releaseRandomTickActionStates(state, states);
            continue;
        }
        const encoded = resident.modified_section_indices[section];
        const modified_index: ?usize = if (encoded == block_store.no_modified_section_index) null else encoded;
        const count = try countRandomTickActions(simulation, state, active_index, resident, section, modified_index, &scratch);
        if (count == 0) {
            releaseRandomTickActionMask(state, handle);
            releaseRandomTickActionStates(state, states);
            continue;
        }
        active.action_section_mask |= section_bit;
        if (handle.* == 0 or handle.* == random_tick_action_mask_unindexed) {
            releaseRandomTickActionMask(state, handle);
            handle.* = allocateRandomTickActionMask(state) orelse random_tick_action_mask_unindexed;
        }
        releaseRandomTickActionStates(state, states);
        if (handle.* != random_tick_action_mask_unindexed) {
            @memcpy(actionMaskForWrite(state, handle.*), &scratch);
            states.* = buildRandomTickActionStates(simulation, state, active_index, resident, section, modified_index, &scratch);
        } else {
            states.* = random_tick_action_state_unindexed;
        }
    }
    updateRandomTickActionChunkPosition(state, active_index);
}

pub const Invocation = struct {
    simulation: *Dependencies,
    scheduler: *RandomTicks,
    origin_chunk_index: ?usize,
    origin: ?*const block_store.MaterializedChunk,
    pos: geometry.BlockPos,
    block_state: i32,
    behavior: *const registry.RandomTickState,
    can_spread: bool,
    outputs: *Packets,
    changes: *usize,
};

pub fn applyCropGrowth(tick: *Invocation) FatalError!void {
    switch (tick.behavior.kind) {
        .crop => try randomTickCrop(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
        .stem => try randomTickStem(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
        .cocoa => try randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 5, tick.outputs, tick.changes),
        .nether_wart => try randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 10, tick.outputs, tick.changes),
        .sweet_berry_bush => if (try baseLightAt(tick.simulation, offsetBlock(tick.pos, .{ .x = 0, .y = 1, .z = 0 })) >= 9)
            try randomTickAgeChance(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, 5, tick.outputs, tick.changes),
        else => unreachable,
    }
}

pub fn applyPlantGrowth(tick: *Invocation) FatalError!void {
    switch (tick.behavior.kind) {
        .cactus => try randomTickColumnPlant(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.age, cactus_block_id, cactus_default_state, tick.outputs, tick.changes),
        .sugar_cane => try randomTickColumnPlant(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.age, sugar_cane_block_id, sugar_cane_default_state, tick.outputs, tick.changes),
        .kelp => try randomTickKelp(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
        .bamboo => try randomTickBamboo(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes),
        .bamboo_sapling => try randomTickBambooSapling(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes),
        .chorus_flower => try randomTickChorusFlower(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
        .mangrove_propagule => if (tick.behavior.next_age >= 0) {
            _ = try applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, tick.behavior.next_age, tick.outputs, tick.changes);
        },
        .sapling => try randomTickSapling(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
        else => unreachable,
    }
}

pub fn applyPlantSpread(tick: *Invocation) FatalError!void {
    switch (tick.behavior.kind) {
        .spreadable => try randomTickBlock(tick.simulation, tick.scheduler, tick.origin_chunk_index, tick.origin, tick.pos, tick.can_spread, tick.outputs, tick.changes),
        .mushroom => try randomTickMushroom(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes),
        .vine => try randomTickVine(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
        .nylium => if (game_data.blockInfo(try tick.simulation.blockAt(offsetBlock(tick.pos, .{ .x = 0, .y = 1, .z = 0 }))).filtered_light >= 15) {
            _ = try applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, registry.block_netherrack_default_state, tick.outputs, tick.changes);
        },
        else => unreachable,
    }
}

pub fn applyFarmlandHydration(tick: *Invocation) FatalError!void {
    switch (tick.behavior.kind) {
        .farmland => try randomTickFarmland(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior.moisture, tick.outputs, tick.changes),
        .mud => {},
        .pointed_dripstone => try randomTickPointedDripstone(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes),
        else => unreachable,
    }
}

pub fn applyLeafDecay(tick: *Invocation) FatalError!void {
    if (isDecayingOakLeaves(tick.block_state)) try decayLeaves(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
}

pub fn applyFireAndLava(tick: *Invocation) FatalError!void {
    try randomTickLava(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
}

pub fn applyIceAndSnow(tick: *Invocation) FatalError!void {
    if (tick.behavior.kind == .ice)
        try randomTickIce(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.outputs, tick.changes)
    else
        try randomTickSnow(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes);
}

pub fn applyCopperWeathering(tick: *Invocation) FatalError!void {
    try randomTickCopper(tick.simulation, tick.scheduler, tick.pos, tick.behavior, tick.outputs, tick.changes);
}

pub fn applyRandomBlockEvents(tick: *Invocation) FatalError!void {
    switch (tick.behavior.kind) {
        .redstone_ore => _ = try applyRandomTickChange(tick.simulation, tick.scheduler, tick.pos, tick.block_state + 1, tick.outputs, tick.changes),
        .nether_portal => try randomTickNetherPortal(tick.simulation, tick.pos, tick.outputs),
        .turtle_egg => try randomTickTurtleEgg(tick.simulation, tick.scheduler, tick.pos, tick.block_state, tick.behavior, tick.outputs, tick.changes),
        .budding_amethyst => try randomTickBuddingAmethyst(tick.simulation, tick.scheduler, tick.pos, tick.outputs, tick.changes),
        else => unreachable,
    }
}

fn randomTickSelectedBlock(simulation: *Dependencies, state: *RandomTicks, behaviors: *const Behaviors, active_index: ?usize, generated: ?*const block_store.MaterializedChunk, chunk: geometry.ChunkPos, section: usize, local_index: u16, selected: ?i32, can_spread: bool, outputs: *Packets, changes: *usize) FatalError!bool {
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
    var tick = Invocation{ .simulation = simulation, .scheduler = state, .origin_chunk_index = active_index, .origin = generated, .pos = pos, .block_state = block_state, .behavior = behavior, .can_spread = can_spread, .outputs = outputs, .changes = changes };
    switch (behavior.kind) {
        .none => {},
        .crop, .stem, .cocoa, .nether_wart, .sweet_berry_bush => try behaviors.crops.run(&tick),
        .cactus, .sugar_cane, .kelp, .bamboo, .bamboo_sapling, .chorus_flower, .mangrove_propagule, .sapling => try behaviors.growth.run(&tick),
        .spreadable, .mushroom, .vine, .nylium => try behaviors.spread.run(&tick),
        .farmland, .mud, .pointed_dripstone => try behaviors.farmland.run(&tick),
        .leaves => try behaviors.leaves.run(&tick),
        .lava => try behaviors.fire_and_lava.run(&tick),
        .ice, .snow => try behaviors.ice_and_snow.run(&tick),
        .copper => try behaviors.copper.run(&tick),
        .redstone_ore, .nether_portal, .turtle_egg, .budding_amethyst => try behaviors.block_events.run(&tick),
    }
    return changes.* == state.maximum_block_changes;
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

fn applyRandomTickChange(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) FatalError!bool {
    const scheduled = if (blockId(block_state) == fire_block_id)
        reserveScheduledBlockTick(scheduledTicks(simulation), simulation.world, pos, .fire) orelse return false
    else
        null;
    const changed = if (simulation.blocks.blockAtIfMaterialized(simulation.world, pos) != null) resident: {
        const blocks = block_writer.Writer.init(simulation.blocks, outputs);
        break :resident blocks.set(simulation.world, pos, block_state) catch |err| switch (err) {
            error.MutationCapacity,
            error.WorldSectionCapacity,
            => return error.WorkingMemoryExceeded,
            error.ChunkNotMaterialized => return error.StorageReadFailed,
            error.MutationReserved, error.MutationCommitted => return error.StorageCorrupt,
        };
    } else cold: {
        const writes = [_]lightning_rod.chunk_storage.BlockWrite{.{ .position = pos, .state = block_state }};
        var mutations: [1]geometry.BlockMutation = undefined;
        const count = simulation.materialization.writeStoredBlocks(simulation.io, simulation.world, geometry.chunkForBlock(pos), &writes, &mutations) catch |err| switch (err) {
            error.ChunkMissing => return error.StorageReadFailed,
            error.InvalidMutation, error.MutationCapacity => return error.StorageCorrupt,
            else => |remaining| return remaining,
        };
        if (count != 0) {
            var packets: [1]lightning_rod.packet_args.BlockChanged = undefined;
            for (mutations[0..count], 0..) |mutation, index|
                packets[index] = .{ .world = mutation.world, .pos = mutation.pos, .block_state = mutation.block_state };
            outputs.blocksChanged(packets[0..count]);
        }
        break :cold count != 0;
    };
    if (!changed) return false;
    if (scheduled) |reservation|
        commitScheduledBlockTick(scheduledTicks(simulation), reservation, simulation.clock.tick + 30 + simulation.random.random.nextIntBoundedComptime(10), simulation.world, pos, .fire);
    changes.* += 1;
    try reconcileLatestRandomTickMutation(simulation, state);
    return true;
}

fn randomTickAgeChance(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, next_state: i32, bound: u32, outputs: *Packets, changes: *usize) FatalError!void {
    if (next_state >= 0 and simulation.random.random.nextIntBounded(bound) == 0)
        _ = try applyRandomTickChange(simulation, state, pos, next_state, outputs, changes);
}

fn cropAvailableMoisture(simulation: *Dependencies, pos: geometry.BlockPos, crop_block_id: u16) FatalError!f32 {
    var moisture: f32 = 1;
    var z_offset: i32 = -1;
    while (z_offset <= 1) : (z_offset += 1) {
        var x_offset: i32 = -1;
        while (x_offset <= 1) : (x_offset += 1) {
            const farmland_pos = geometry.BlockPos{ .x = pos.x + x_offset, .y = pos.y - 1, .z = pos.z + z_offset };
            const farmland_state = try simulation.blockAt(farmland_pos);
            var contribution: f32 = 0;
            if (blockId(farmland_state) == farmland_block_id) {
                contribution = if (registry.randomTickState(farmland_state).moisture > 0) 3 else 1;
                if (x_offset != 0 or z_offset != 0) contribution /= 4;
            }
            moisture += contribution;
        }
    }
    const west_or_east = blockId(try simulation.blockAt(.{ .x = pos.x - 1, .y = pos.y, .z = pos.z })) == crop_block_id or
        blockId(try simulation.blockAt(.{ .x = pos.x + 1, .y = pos.y, .z = pos.z })) == crop_block_id;
    const north_or_south = blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
        blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y, .z = pos.z + 1 })) == crop_block_id;
    if (west_or_east and north_or_south) {
        moisture /= 2;
    } else {
        const diagonal = blockId(try simulation.blockAt(.{ .x = pos.x - 1, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
            blockId(try simulation.blockAt(.{ .x = pos.x + 1, .y = pos.y, .z = pos.z - 1 })) == crop_block_id or
            blockId(try simulation.blockAt(.{ .x = pos.x + 1, .y = pos.y, .z = pos.z + 1 })) == crop_block_id or
            blockId(try simulation.blockAt(.{ .x = pos.x - 1, .y = pos.y, .z = pos.z + 1 })) == crop_block_id;
        if (diagonal) moisture /= 2;
    }
    return moisture;
}

fn randomTickCrop(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    if (blockId(try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != farmland_block_id) {
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        return;
    }
    if (behavior.next_age < 0 or try baseLightAt(simulation, pos) < 9) return;
    const current = try simulation.blockAt(pos);
    const moisture = try cropAvailableMoisture(simulation, pos, blockId(current));
    const bound: u32 = @intFromFloat(@floor(25.0 / moisture) + 1.0);
    if (simulation.random.random.nextIntBounded(bound) == 0)
        _ = try applyRandomTickChange(simulation, state, pos, behavior.next_age, outputs, changes);
}

fn randomTickFarmland(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, moisture: i8, outputs: *Packets, changes: *usize) FatalError!void {
    if (try farmlandHasWater(simulation, pos)) {
        if (moisture < 7) _ = try applyRandomTickChange(simulation, state, pos, block_state + 7 - moisture, outputs, changes);
        return;
    }
    if (moisture > 0) {
        _ = try applyRandomTickChange(simulation, state, pos, block_state - 1, outputs, changes);
        return;
    }
    if (!blockMaintainsFarmland(try simulation.blockAt(.{ .x = pos.x, .y = pos.y + 1, .z = pos.z })))
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_dirt_default_state, outputs, changes);
}

fn farmlandHasWater(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!bool {
    var y_offset: i16 = 0;
    while (y_offset <= 1) : (y_offset += 1) {
        var z_offset: i32 = -4;
        while (z_offset <= 4) : (z_offset += 1) {
            var x_offset: i32 = -4;
            while (x_offset <= 4) : (x_offset += 1) {
                if (blockId(try simulation.blockAt(.{ .x = pos.x + x_offset, .y = pos.y + y_offset, .z = pos.z + z_offset })) == water_block_id)
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

fn randomTickColumnPlant(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, age: i8, plant_block_id: u16, default_state: i32, outputs: *Packets, changes: *usize) FatalError!void {
    const above = geometry.BlockPos{ .x = pos.x, .y = pos.y + 1, .z = pos.z };
    if (try simulation.blockAt(above) != registry.block_air_default_state) return;
    var height: u8 = 1;
    while (height < 3 and blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y - @as(i16, height), .z = pos.z })) == plant_block_id) : (height += 1) {}
    if (height >= 3) return;
    if (age == 15) {
        _ = try applyRandomTickChange(simulation, state, above, default_state, outputs, changes);
        if (changes.* < state.maximum_block_changes)
            _ = try applyRandomTickChange(simulation, state, pos, block_state - 15, outputs, changes);
    } else {
        _ = try applyRandomTickChange(simulation, state, pos, block_state + 1, outputs, changes);
    }
}

fn blockLightAt(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!u8 {
    var light = game_data.blockInfo(try simulation.blockAt(pos)).emitted_light;
    for (leaf_directions) |direction| {
        const emitted = game_data.blockInfo(try simulation.blockAt(offsetBlock(pos, direction))).emitted_light;
        light = @max(light, emitted -| 1);
    }
    return light;
}

fn baseLightAt(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!u8 {
    const above = try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 }));
    return @max(try blockLightAt(simulation, pos), if (game_data.blockInfo(above).filtered_light < 15) @as(u8, 15) else 0);
}

fn randomTickStem(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    if (try baseLightAt(simulation, pos) < 9) return;
    const moisture = try cropAvailableMoisture(simulation, pos, blockId(block_state));
    const bound: u32 = @intFromFloat(@floor(25.0 / moisture) + 1.0);
    if (simulation.random.random.nextIntBounded(bound) != 0) return;
    if (behavior.next_age >= 0) {
        _ = try applyRandomTickChange(simulation, state, pos, behavior.next_age, outputs, changes);
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
    if (try simulation.blockAt(fruit_pos) != registry.block_air_default_state) return;
    const below = try simulation.blockAt(offsetBlock(fruit_pos, .{ .x = 0, .y = -1, .z = 0 }));
    const below_id = blockId(below);
    if (below_id != farmland_block_id and below_id != registry.block_dirt_id and below_id != registry.block_grass_block_id) return;
    const pumpkin = blockId(block_state) == pumpkin_stem_block_id;
    if (!pumpkin and blockId(block_state) != melon_stem_block_id) return;
    _ = try applyRandomTickChange(simulation, state, fruit_pos, if (pumpkin) pumpkin_default_state else melon_default_state, outputs, changes);
    if (changes.* < state.maximum_block_changes)
        _ = try applyRandomTickChange(simulation, state, pos, (if (pumpkin) attached_pumpkin_stem_min_state else attached_melon_stem_min_state) + @as(i32, @intCast(direction_index)), outputs, changes);
}

fn randomTickMushroom(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) FatalError!void {
    if (!try mushroomCanRemainAt(simulation, pos)) {
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
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
                if (blockId(try simulation.blockAt(.{ .x = x, .y = y, .z = z })) != blockId(block_state)) continue;
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
        if (try mushroomCanPlaceAt(simulation, candidate)) origin = candidate;
        candidate = .{
            .x = origin.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            .y = origin.y + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))) - @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(2))),
            .z = origin.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
        };
    }
    if (try mushroomCanPlaceAt(simulation, candidate))
        _ = try applyRandomTickChange(simulation, state, candidate, block_state, outputs, changes);
}

fn mushroomCanRemainAt(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!bool {
    const below = try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    if (registry.blockBehaviorFlags(below).mushroom_substrate) return true;
    return game_data.blockInfo(below).filtered_light == 15 and try baseLightAt(simulation, pos) < 13;
}

fn mushroomCanPlaceAt(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!bool {
    if (!player_store.validBuildY(pos.y) or try simulation.blockAt(pos) != registry.block_air_default_state) return false;
    const below = try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    if (registry.blockBehaviorFlags(below).mushroom_substrate) return true;
    return game_data.blockInfo(below).filtered_light == 15 and try baseLightAt(simulation, pos) < 13;
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

fn randomTickVine(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    if (simulation.random.random.nextIntBoundedComptime(4) != 0) return;
    const direction = simulation.random.random.nextIntBoundedComptime(6);
    if (direction == 0) {
        const below = offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 });
        const below_state = try simulation.blockAt(below);
        if (below_state != registry.block_air_default_state and blockId(below_state) != blockId(vine_min_state)) return;
        var faces: u5 = if (below_state == registry.block_air_default_state) behavior.vine_faces else registry.randomTickState(below_state).vine_faces;
        for (0..4) |face| {
            if (simulation.random.random.nextIntBoundedComptime(2) == 0) faces &= ~(@as(u5, 1) << @intCast(face));
        }
        if (faces != 0) _ = try applyRandomTickChange(simulation, state, below, vineState(faces), outputs, changes);
        return;
    }
    if (direction == 1) {
        const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
        if (try simulation.blockAt(above) != registry.block_air_default_state) return;
        var faces = behavior.vine_faces & 0b10111;
        for (0..4) |face| {
            if (simulation.random.random.nextIntBoundedComptime(2) == 0) faces &= ~(@as(u5, 1) << @intCast(face));
        }
        if (faces != 0) _ = try applyRandomTickChange(simulation, state, above, vineState(faces), outputs, changes);
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
    if (game_data.blockInfo(try simulation.blockAt(target)).filtered_light == 15) {
        _ = try applyRandomTickChange(simulation, state, pos, vineState(behavior.vine_faces | face_bits[index]), outputs, changes);
        return;
    }
    if (try simulation.blockAt(target) != registry.block_air_default_state) return;
    const clockwise = (index + 1) & 3;
    const counterclockwise = (index + 3) & 3;
    if (behavior.vine_faces & face_bits[clockwise] != 0 and game_data.blockInfo(try simulation.blockAt(offsetBlock(target, horizontal[clockwise]))).filtered_light == 15) {
        _ = try applyRandomTickChange(simulation, state, target, vineState(face_bits[clockwise]), outputs, changes);
    } else if (behavior.vine_faces & face_bits[counterclockwise] != 0 and game_data.blockInfo(try simulation.blockAt(offsetBlock(target, horizontal[counterclockwise]))).filtered_light == 15) {
        _ = try applyRandomTickChange(simulation, state, target, vineState(face_bits[counterclockwise]), outputs, changes);
    }
}

fn randomTickKelp(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    if (behavior.next_age < 0 or simulation.random.random.nextDouble() >= 0.14) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (blockId(try simulation.blockAt(above)) != water_block_id) return;
    _ = try applyRandomTickChange(simulation, state, pos, kelp_plant_default_state, outputs, changes);
    if (changes.* < state.maximum_block_changes)
        _ = try applyRandomTickChange(simulation, state, above, behavior.next_age, outputs, changes);
}

fn bambooState(age: i8, leaves: i8, stage: i8) i32 {
    return bamboo_default_state + @as(i32, age) * 6 + @as(i32, leaves) * 2 + stage;
}

fn randomTickBambooSapling(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    if (simulation.random.random.nextIntBoundedComptime(3) != 0) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (try simulation.blockAt(above) == registry.block_air_default_state and try baseLightAt(simulation, above) >= 9)
        _ = try applyRandomTickChange(simulation, state, above, bamboo_small_state, outputs, changes);
}

fn randomTickBamboo(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) FatalError!void {
    if (simulation.random.random.nextIntBoundedComptime(3) != 0) return;
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (try simulation.blockAt(above) != registry.block_air_default_state or try baseLightAt(simulation, above) < 9) return;
    var height: i16 = 1;
    while (height < 16 and blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y - height, .z = pos.z })) == bamboo_block_id) : (height += 1) {}
    if (height >= 16) return;
    const below = registry.randomTickState(try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 })));
    const below_two_pos = offsetBlock(pos, .{ .x = 0, .y = -2, .z = 0 });
    const below_two_state = try simulation.blockAt(below_two_pos);
    const below_two = registry.randomTickState(below_two_state);
    var leaves: i8 = 0;
    if (height >= 1 and (blockId(try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != bamboo_block_id or below.enum_value == 0)) {
        leaves = 1;
    } else if (below.enum_value != 0) {
        leaves = 2;
        if (blockId(below_two_state) == bamboo_block_id) {
            _ = try applyRandomTickChange(simulation, state, offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }), bambooState(registry.randomTickState(block_state).age, 1, below.stage), outputs, changes);
            if (changes.* >= state.maximum_block_changes) return;
            _ = try applyRandomTickChange(simulation, state, below_two_pos, bambooState(below_two.age, 0, below_two.stage), outputs, changes);
            if (changes.* >= state.maximum_block_changes) return;
        }
    }
    const age: i8 = if (registry.randomTickState(block_state).age == 1 or blockId(below_two_state) == bamboo_block_id) 1 else 0;
    const stage: i8 = if ((height >= 11 and simulation.random.random.nextFloat() < 0.25) or height == 15) 1 else 0;
    _ = try applyRandomTickChange(simulation, state, above, bambooState(age, leaves, stage), outputs, changes);
}

fn randomTickIce(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, outputs: *Packets, changes: *usize) FatalError!void {
    if (try blockLightAt(simulation, pos) <= 11 - game_data.blockInfo(block_state).filtered_light) return;
    _ = try applyRandomTickChange(simulation, state, pos, registry.state_water_level_0, outputs, changes);
}

fn randomTickSnow(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    if (try blockLightAt(simulation, pos) > 11)
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
}

fn randomTickSapling(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    if (try baseLightAt(simulation, offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 })) < 9 or simulation.random.random.nextIntBoundedComptime(7) != 0) return;
    if (behavior.stage == 0 and behavior.next_stage >= 0) {
        _ = try applyRandomTickChange(simulation, state, pos, behavior.next_stage, outputs, changes);
        return;
    }
    if (blockId(block_state) != registry.block_oak_sapling_id) return;
    try growOakTree(simulation, state, pos, outputs, changes);
}

fn growOakTree(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    const height: i16 = 4 + @as(i16, @intCast(simulation.random.random.nextIntBoundedComptime(3)));
    var y: i16 = 0;
    while (y < height + 2) : (y += 1) {
        const radius: i32 = if (y < height - 2) 0 else 2;
        var z: i32 = -radius;
        while (z <= radius) : (z += 1) {
            var x: i32 = -radius;
            while (x <= radius) : (x += 1) {
                const target = geometry.BlockPos{ .x = pos.x + x, .y = pos.y + y, .z = pos.z + z };
                const current = try simulation.blockAt(target);
                if (current != registry.block_air_default_state and leafDistance(current) == null and !(x == 0 and z == 0 and y == 0)) return;
            }
        }
    }
    _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
    y = 0;
    while (y < height and changes.* < state.maximum_block_changes) : (y += 1)
        _ = try applyRandomTickChange(simulation, state, .{ .x = pos.x, .y = pos.y + y, .z = pos.z }, registry.block_oak_log_default_state, outputs, changes);
    y = height - 2;
    while (y <= height and changes.* < state.maximum_block_changes) : (y += 1) {
        const radius: i32 = if (y == height) 1 else 2;
        var z: i32 = -radius;
        while (z <= radius and changes.* < state.maximum_block_changes) : (z += 1) {
            var x: i32 = -radius;
            while (x <= radius and changes.* < state.maximum_block_changes) : (x += 1) {
                if (@abs(x) == radius and @abs(z) == radius and simulation.random.random.nextIntBoundedComptime(2) == 0) continue;
                const target = geometry.BlockPos{ .x = pos.x + x, .y = pos.y + y, .z = pos.z + z };
                if (try simulation.blockAt(target) == registry.block_air_default_state)
                    _ = try applyRandomTickChange(simulation, state, target, registry.block_oak_leaves_default_state, outputs, changes);
            }
        }
    }
}

fn randomTickTurtleEgg(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, block_state: i32, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    const day_time = simulation.time.day_time % 24_000;
    if (!((day_time >= 21_600 and day_time <= 22_550) or simulation.random.random.nextIntBounded(500) == 0)) return;
    if (blockId(try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }))) != sand_block_id) return;
    if (behavior.hatch < 2) {
        _ = try applyRandomTickChange(simulation, state, pos, block_state + 1, outputs, changes);
    } else {
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
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

fn randomTickNetherPortal(simulation: *Dependencies, pos: geometry.BlockPos, outputs: *Packets) FatalError!void {
    if (!simulation.rules.do_mob_spawning or simulation.living.entities.free_count == 0) return;
    const difficulty: u32 = switch (simulation.rules.difficulty) {
        .peaceful => 0,
        .easy => 1,
        .normal => 2,
        .hard => 3,
    };
    if (simulation.random.random.nextIntBounded(2000) >= difficulty) return;
    var ground = pos;
    for (0..@as(usize, @intCast(block_store.world_top_y - world_limits.min_y + 1))) |_| {
        if (blockId(try simulation.blockAt(ground)) != blockId(registry.state_nether_portal_axis_x)) break;
        if (ground.y == world_limits.min_y) return;
        ground.y -= 1;
    } else diagnostics.panic("nether portal scan exceeded world height", &.{});
    if (game_data.blockInfo(try simulation.blockAt(ground)).filtered_light != 15) return;
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

fn randomTickBuddingAmethyst(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    if (simulation.random.random.nextIntBoundedComptime(5) != 0) return;
    const direction = simulation.random.random.nextIntBoundedComptime(6);
    const target = offsetBlock(pos, amethyst_directions[direction]);
    const current = try simulation.blockAt(target);
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
    _ = try applyRandomTickChange(simulation, state, target, next_min + @as(i32, @intCast(direction * 2)) + waterlogged, outputs, changes);
}

fn randomTickCopper(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
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
                const neighbor_stage = copperOxidationStage(try simulation.blockAt(.{ .x = x, .y = y, .z = z })) orelse continue;
                if (neighbor_stage < behavior.oxidation_stage) return;
                if (neighbor_stage == behavior.oxidation_stage) equal += 1 else later += 1;
            }
        }
    }
    const ratio = @as(f32, @floatFromInt(later + 1)) / @as(f32, @floatFromInt(later + equal + 1));
    const chance = ratio * ratio * if (behavior.oxidation_stage == 0) @as(f32, 0.75) else 1;
    if (simulation.random.random.nextFloat() < chance)
        _ = try applyRandomTickChange(simulation, state, pos, behavior.next_oxidation, outputs, changes);
}

fn surroundedByAir(simulation: *Dependencies, pos: geometry.BlockPos, ignored: ?usize) FatalError!bool {
    const horizontal = [_]geometry.BlockPos{
        .{ .x = 0, .y = 0, .z = -1 },
        .{ .x = 1, .y = 0, .z = 0 },
        .{ .x = 0, .y = 0, .z = 1 },
        .{ .x = -1, .y = 0, .z = 0 },
    };
    for (horizontal, 0..) |direction, index| {
        if (ignored == index) continue;
        if (try simulation.blockAt(offsetBlock(pos, direction)) != registry.block_air_default_state) return false;
    }
    return true;
}

fn randomTickChorusFlower(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
    if (!player_store.validBuildY(above.y) or try simulation.blockAt(above) != registry.block_air_default_state or behavior.age >= 5) return;
    const below = try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    var vertical_growth = blockId(below) == end_stone_block_id or below == registry.block_air_default_state;
    var rooted = blockId(below) == end_stone_block_id;
    if (blockId(below) == chorus_plant_block_id) {
        var depth: u8 = 1;
        while (depth < 5 and blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y - @as(i16, depth + 1), .z = pos.z })) == chorus_plant_block_id) : (depth += 1) {}
        rooted = blockId(try simulation.blockAt(.{ .x = pos.x, .y = pos.y - @as(i16, depth + 1), .z = pos.z })) == end_stone_block_id;
        vertical_growth = depth < 2 or depth <= simulation.random.random.nextIntBounded(if (rooted) 5 else 4);
    }
    if (vertical_growth and try surroundedByAir(simulation, above, null) and try simulation.blockAt(offsetBlock(above, .{ .x = 0, .y = 1, .z = 0 })) == registry.block_air_default_state) {
        _ = try applyRandomTickChange(simulation, state, pos, chorus_plant_default_state, outputs, changes);
        if (changes.* < state.maximum_block_changes)
            _ = try applyRandomTickChange(simulation, state, above, registry.state_chorus_flower_age_0 + behavior.age, outputs, changes);
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
            if (try simulation.blockAt(target) != registry.block_air_default_state or try simulation.blockAt(offsetBlock(target, .{ .x = 0, .y = -1, .z = 0 })) != registry.block_air_default_state or !try surroundedByAir(simulation, target, (direction + 2) & 3)) continue;
            _ = try applyRandomTickChange(simulation, state, target, registry.state_chorus_flower_age_0 + behavior.age + 1, outputs, changes);
            grew = true;
            if (changes.* >= state.maximum_block_changes) return;
        }
        if (grew) {
            _ = try applyRandomTickChange(simulation, state, pos, chorus_plant_default_state, outputs, changes);
            return;
        }
    }
    _ = try applyRandomTickChange(simulation, state, pos, chorus_flower_dead_state, outputs, changes);
}

fn hasBurnableNeighbor(simulation: *Dependencies, pos: geometry.BlockPos) FatalError!bool {
    for (amethyst_directions) |direction| if (try simulation.blockFlammable(offsetBlock(pos, direction))) return true;
    return false;
}

fn tickFire(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    if (blockId(try simulation.blockAt(pos)) != fire_block_id) return;
    const below = try simulation.blockAt(offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 }));
    const permanent = blockId(below) == netherrack_block_id;
    const supported = game_data.blockInfo(below).filtered_light == 15;
    const has_fuel = try hasBurnableNeighbor(simulation, pos);
    if (!permanent and !supported and !has_fuel) {
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes);
        return;
    }
    for (amethyst_directions) |direction| {
        const target = offsetBlock(pos, direction);
        if (!try simulation.blockFlammable(target)) continue;
        const roll = simulation.random.random.nextIntBoundedComptime(100);
        if (roll < 35) {
            _ = try applyRandomTickChange(simulation, state, target, fire_default_state, outputs, changes);
        } else if (roll < 55) {
            _ = try applyRandomTickChange(simulation, state, target, registry.block_air_default_state, outputs, changes);
        }
        if (changes.* == state.maximum_block_changes) return;
    }
    _ = scheduleFire(simulation, pos);
}

fn randomTickLava(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    const attempts = simulation.random.random.nextIntBoundedComptime(3);
    if (attempts > 0) {
        var candidate = pos;
        for (0..attempts) |_| {
            candidate = .{
                .x = candidate.x + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
                .y = candidate.y + 1,
                .z = candidate.z + @as(i32, @intCast(simulation.random.random.nextIntBoundedComptime(3))) - 1,
            };
            const current = try simulation.blockAt(candidate);
            if (current == registry.block_air_default_state) {
                if (try hasBurnableNeighbor(simulation, candidate)) _ = try applyRandomTickChange(simulation, state, candidate, fire_default_state, outputs, changes);
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
        if (try simulation.blockAt(above) == registry.block_air_default_state and try hasBurnableNeighbor(simulation, candidate)) {
            _ = try applyRandomTickChange(simulation, state, above, fire_default_state, outputs, changes);
            return;
        }
    }
}

fn dripstoneState(thickness: i8, vertical_direction: i8, waterlogged: bool) i32 {
    return pointed_dripstone_min_state + @as(i32, thickness) * 4 + @as(i32, vertical_direction) * 2 + @intFromBool(!waterlogged);
}

fn randomTickPointedDripstone(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, behavior: *const registry.RandomTickState, outputs: *Packets, changes: *usize) FatalError!void {
    const drip_roll = simulation.random.random.nextFloat();
    if (behavior.vertical_direction == 1) {
        var source_pos = pos;
        var found_source = false;
        var source_state = registry.block_air_default_state;
        for (0..11) |_| {
            source_pos.y += 1;
            const source = try simulation.blockAt(source_pos);
            if (blockId(source) == blockId(pointed_dripstone_min_state)) continue;
            if (blockId(source) == mud_block_id) {
                found_source = true;
                source_state = source;
            } else {
                source_pos.y += 1;
                source_state = try simulation.blockAt(source_pos);
                found_source = blockId(source_state) == water_block_id;
            }
            break;
        }
        if (found_source and drip_roll < 0.17578125 and blockId(source_state) == mud_block_id) {
            _ = try applyRandomTickChange(simulation, state, source_pos, clay_default_state, outputs, changes);
            if (changes.* >= state.maximum_block_changes) return;
        } else if (found_source and drip_roll < 0.17578125 and blockId(source_state) == water_block_id and behavior.enum_value == 1) {
            var cauldron_pos = pos;
            for (0..11) |_| {
                cauldron_pos.y -= 1;
                const below = try simulation.blockAt(cauldron_pos);
                if (below == registry.block_air_default_state) continue;
                if (blockId(below) == cauldron_block_id)
                    _ = scheduleBlockTick(scheduledTicks(simulation), simulation.clock.tick + 50, simulation.world, cauldron_pos, .water_cauldron);
                break;
            }
        }
    }
    if (simulation.random.random.nextFloat() >= 0.011377778) return;
    if (behavior.vertical_direction == 1 and behavior.enum_value == 1) {
        const below = offsetBlock(pos, .{ .x = 0, .y = -1, .z = 0 });
        if (try simulation.blockAt(below) == registry.block_air_default_state)
            _ = try applyRandomTickChange(simulation, state, below, dripstoneState(1, 1, false), outputs, changes);
    } else if (behavior.vertical_direction == 0 and behavior.enum_value == 1) {
        const above = offsetBlock(pos, .{ .x = 0, .y = 1, .z = 0 });
        if (try simulation.blockAt(above) == registry.block_air_default_state)
            _ = try applyRandomTickChange(simulation, state, above, dripstoneState(1, 0, false), outputs, changes);
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

fn decayLeaves(simulation: *Dependencies, state: *RandomTicks, pos: geometry.BlockPos, outputs: *Packets, changes: *usize) FatalError!void {
    const current = try simulation.blockAt(pos);
    if (!isDecayingOakLeaves(current)) return;
    const saved_random = simulation.random.random;
    const drops = rollOakLeafDrops(&simulation.random.random);
    const stacks = oakLeafDropStacks(drops);
    var specifications: [3]entity_store.ItemEntities.Spawn = undefined;
    var count: usize = 0;
    for (stacks) |stack| {
        if (stack.isEmpty()) continue;
        specifications[count] = .{
            .world = simulation.world,
            .position = entity_store.blockDropPosition(pos),
            .velocity = .{ .y = 0.1 },
            .stack = stack,
            .pickup_delay_ticks = entity_store.block_drop_pickup_delay_ticks,
        };
        count += 1;
    }
    var reservation = simulation.items.reserve(count) catch return error.WorkingMemoryExceeded;
    var committed = false;
    defer if (!committed) simulation.items.cancelReservation(&reservation);
    if (!(try applyRandomTickChange(simulation, state, pos, registry.block_air_default_state, outputs, changes))) {
        simulation.random.random = saved_random;
        return;
    }
    var indices: [3]usize = undefined;
    simulation.items.commitReserved(&reservation, simulation.random, specifications[0..count], indices[0..count]);
    committed = true;
    for (indices[0..count]) |index| outputs.item_spawned(@intCast(index));
    plugin_profiler.countTrace(RandomTickTrace.leaf_decays, 1);
    plugin_profiler.countTrace(RandomTickTrace.leaf_sapling_rolls, @intFromBool(drops.sapling));
    plugin_profiler.countTrace(RandomTickTrace.leaf_sapling_spawns, @intFromBool(drops.sapling));
    plugin_profiler.countTrace(RandomTickTrace.leaf_drop_spawn_failures, 0);
    plugin_profiler.countTrace(RandomTickTrace.leaf_drop_capacity_failures, 0);
}

fn randomTickBlock(simulation: *Dependencies, state: *RandomTicks, origin_chunk_index: ?usize, origin: ?*const block_store.MaterializedChunk, pos: geometry.BlockPos, can_spread: bool, outputs: *Packets, changes: *usize) FatalError!void {
    const spread_state = game_data.blockInfo(try simulation.blockAt(pos)).default_state;
    const above_blocked = if (origin_chunk_index) |index|
        projectedGrassAboveIsBlocked(&state.grass[index], pos)
    else if (origin) |materialized|
        simulation.blocks.grassAboveIsBlocked(materialized, pos)
    else
        return;
    if (above_blocked) {
        _ = try applyRandomTickChange(simulation, state, pos, registry.block_dirt_default_state, outputs, changes);
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
        if (!player_store.validBuildY(candidate.y) or !try grassCanSpreadTo(simulation, state, origin_chunk_index, candidate)) continue;
        if (try applyRandomTickChange(simulation, state, candidate, spread_state, outputs, changes)) {
            if (changes.* == state.maximum_block_changes) return;
        }
    }
}

fn projectedGrassAboveIsBlocked(projection: *const RandomTickGrassProjection, grass: geometry.BlockPos) bool {
    const column: usize = @as(usize, @intCast(grass.x & 15)) | (@as(usize, @intCast(grass.z & 15)) << 4);
    return projection.grass_above_blocked[column / 64] & (@as(u64, 1) << @intCast(column & 63)) != 0;
}

fn materializedForRandomTickTicket(simulation: *const Dependencies, ticket: *const RandomTickChunk) ?*const block_store.MaterializedChunk {
    return simulation.blocks.materializedChunk(ticket.world, ticket.chunk);
}

fn grassCanSpreadTo(simulation: *Dependencies, state: *RandomTicks, origin_chunk_index: ?usize, candidate: geometry.BlockPos) FatalError!bool {
    _ = state;
    _ = origin_chunk_index;
    if (!player_store.validBuildY(candidate.y)) return false;
    if (game_data.blockInfo(try simulation.blockAt(candidate)).default_state != registry.block_dirt_default_state) return false;
    return !game_data.preventsGrassSurvival(try simulation.blockAt(.{ .x = candidate.x, .y = candidate.y + 1, .z = candidate.z }));
}

fn allocateBuffers(state: *RandomTicks, allocator: std.mem.Allocator, maximum_chunks: usize, maximum_masks: usize, maximum_action_state_pages: usize, maximum_mutation_overrides: usize, player_capacity: usize) !void {
    state.centers = try preallocated.alloc(RandomTickCenter, allocator, player_capacity);
    state.free_chunk_indices = try preallocated.alloc(u16, allocator, maximum_chunks);
    state.active_chunk_indices = try preallocated.alloc(u16, allocator, maximum_chunks);
    state.previous_exact_neighborhoods = try preallocated.alloc(bool, allocator, maximum_chunks);
    state.chunk_was_active = try preallocated.alloc(bool, allocator, maximum_chunks);
    state.chunk_topology_generations = try preallocated.alloc(u32, allocator, maximum_chunks);
    @memset(state.chunk_topology_generations, 0);
    state.chunk_prefetch_generations = try preallocated.alloc(u32, allocator, maximum_chunks);
    @memset(state.chunk_prefetch_generations, 0);
    state.chunk_allocated = try preallocated.alloc(bool, allocator, maximum_chunks);
    @memset(state.chunk_allocated, false);
    state.chunks = try preallocated.alignedAlloc(RandomTickChunk, allocator, .@"64", maximum_chunks);
    state.grass = try preallocated.alignedAlloc(RandomTickGrassProjection, allocator, .@"64", maximum_chunks);
    state.general = try preallocated.alignedAlloc(RandomTickGeneralProjection, allocator, .@"64", maximum_chunks);
    state.lookup = try preallocated.alloc(u16, allocator, maximum_chunks * 2);
    @memset(state.lookup, 0);
    state.free_action_masks = try preallocated.alloc(u16, allocator, maximum_masks);
    state.action_masks = try preallocated.alignedAlloc([block_store.blocks_per_section / 64]u64, allocator, .@"64", maximum_masks);
    for (state.free_action_masks, 0..) |*entry, index|
        entry.* = @intCast(maximum_masks - index - 1);
    state.free_action_mask_count = maximum_masks;
    state.free_action_state_pages = try preallocated.alloc(u16, allocator, maximum_action_state_pages);
    state.action_state_pages = try preallocated.alignedAlloc(RandomTickActionStatePage, allocator, .@"64", maximum_action_state_pages);
    for (state.free_action_state_pages, 0..) |*entry, index|
        entry.* = @intCast(maximum_action_state_pages - index - 1);
    state.free_action_state_page_count = maximum_action_state_pages;
    state.mutation_overrides = try preallocated.alloc(RandomTickOverride, allocator, maximum_mutation_overrides);
    state.mutation_override_lookup = try preallocated.alloc(u16, allocator, maximum_mutation_overrides * 2);
    @memset(state.mutation_override_lookup, 0);
    state.free_base_masks = try preallocated.alloc(u16, allocator, maximum_masks);
    state.base_masks = try preallocated.alignedAlloc([block_store.blocks_per_section / 64]u64, allocator, .@"64", maximum_masks);
    for (state.free_base_masks, 0..) |*entry, index|
        entry.* = @intCast(maximum_masks - index - 1);
    state.free_base_mask_count = maximum_masks;
    state.action_chunk_positions = try preallocated.alignedAlloc(u64, allocator, .@"64", (maximum_chunks + 63) / 64);
    @memset(state.action_chunk_positions, 0);
}
