const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const game_rules = lightning_rod.game_rules;
const world_random = lightning_rod.random;
const world_clock = lightning_rod.clock;
const std = @import("std");
const test_state = lightning_rod.test_support.state;
const plugin_profiler = lightning_rod.plugin_profiler;
const preallocated = lightning_rod.preallocated;
const config = lightning_rod.config.value;
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;
const collision = lightning_rod.collision;
const navigation = lightning_rod.navigation;
const vanilla_math = @import("../vanilla/math.zig");
const diagnostics = lightning_rod.diagnostics;
const active_chunks = @import("../vanilla/active_chunks.zig");
const Packets = lightning_rod.Packets;
const world_identity = lightning_rod.world_identity;

const Dependencies = struct {
    clock: *world_clock.Clock,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,

    fn activePlayerSlots(self: *const Dependencies) []const u16 {
        return self.players.active_slots[0..self.players.active_count];
    }

    fn itemPosition(self: *const Dependencies, index: usize) geometry.Vec3 {
        return self.items.position(index);
    }

    fn remove_item_entity(self: *Dependencies, index: usize) void {
        self.items.remove(index);
    }

    fn spawn_item_entity_with_pickup_delay(
        self: *Dependencies,
        world: world_identity.Handle,
        position: geometry.Vec3,
        velocity: geometry.Vec3,
        stack: player_store.HotbarStack,
        pickup_delay_ticks: u16,
    ) !usize {
        return self.items.spawn(self.random, self.blocks, world, position, velocity, stack, pickup_delay_ticks);
    }
};

const navigation_node_cache_capacity = 8192;

const NavigationNodeCacheEntry = struct {
    world: world_identity.Handle = world_identity.invalid,
    revision: u64 = 0,
    x: i32 = 0,
    z: i32 = 0,
    y: i16 = 0,
    baby: bool = false,
    passable: bool = false,
    node_type: navigation.NodeType = .blocked,
    penalty: f32 = 0,
};

const NavigationNodeCache = struct {
    entries: []NavigationNodeCacheEntry = &.{},
};

const LandPathContext = struct {
    world: world_identity.Handle,
    blocks: *block_store.Blocks,
    search: *navigation.Search,
    node_cache: *NavigationNodeCache,
    baby: bool,
    resident_chunks: [8]geometry.ChunkPos = undefined,
    residents: [8]?*const block_store.GeneratedHeightChunk = [_]?*const block_store.GeneratedHeightChunk{null} ** 8,
    dependency_count: u8 = 0,
    dependencies_complete: bool = true,
    dependency_chunks: [32]geometry.ChunkPos = undefined,
    dependency_revisions: [32]u64 = undefined,

    pub fn pathSuccessors(self: *LandPathContext, current: navigation.Node, out: *[8]navigation.Candidate) usize {
        // Direction.Type.HORIZONTAL iterates by Vanilla horizontal quarter turn.
        const cardinal_offsets = [_][2]i32{ .{ 0, 1 }, .{ -1, 0 }, .{ 0, -1 }, .{ 1, 0 } };
        var cardinal: [4]navigation.Candidate = undefined;
        for (cardinal_offsets, 0..) |offset, index| {
            cardinal[index] = self.successor(current, offset[0], offset[1]);
            out[index] = cardinal[index];
        }

        const diagonal_offsets = [_][2]i32{ .{ -1, 1 }, .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 } };
        const adjacent = [_][2]usize{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 } };
        for (diagonal_offsets, adjacent, 0..) |offset, sides, index| {
            var candidate = self.successor(current, offset[0], offset[1]);
            candidate.passable = candidate.passable and cardinal[sides[0]].passable and cardinal[sides[1]].passable and
                cardinal[sides[0]].node.y <= current.y and cardinal[sides[1]].node.y <= current.y;
            out[4 + index] = candidate;
        }
        return 8;
    }

    fn successor(self: *LandPathContext, current: navigation.Node, dx: i32, dz: i32) navigation.Candidate {
        const x = current.x + dx;
        const z = current.z + dz;
        var candidate = self.search.classifyCached(self, .{ .x = x, .y = current.y, .z = z });
        if (candidate.passable) return candidate;

        if (candidate.node.node_type == .blocked) {
            const above_y: i16 = current.y +| 1;
            const above = self.search.classifyCached(self, .{ .x = x, .y = above_y, .z = z });
            if (above.passable) return above;
            return candidate;
        }

        var fall_y = current.y;
        var fall_distance: u8 = 0;
        while (fall_distance < 3 and fall_y > config.world_min_y) {
            fall_y -= 1;
            fall_distance += 1;
            candidate = self.search.classifyCached(self, .{ .x = x, .y = fall_y, .z = z });
            if (candidate.passable) return candidate;
            if (candidate.node.node_type == .blocked) return candidate;
        }
        return candidate;
    }

    pub fn classifyPathNode(self: *LandPathContext, node: navigation.Node) navigation.Candidate {
        const chunk = geometry.ChunkPos{ .x = @divFloor(node.x, 16), .z = @divFloor(node.z, 16) };
        const slot = pathResidentHash(chunk) & (self.residents.len - 1);
        const resident = blk: {
            if (self.residents[slot]) |cached|
                if (cached.valid and geometry.sameChunk(cached.chunk, chunk)) break :blk cached;
            break :blk self.resolveResident(slot, chunk) orelse return blockedPathCandidate(node);
        };
        const cache_slot = navigationNodeCacheHash(self.world, node, self.baby) & (navigation_node_cache_capacity - 1);
        const cached = &self.node_cache.entries[cache_slot];
        if (cached.world.eql(self.world) and cached.revision == resident.content_revision and cached.x == node.x and cached.y == node.y and cached.z == node.z and cached.baby == self.baby) {
            return .{
                .node = .{ .x = node.x, .y = node.y, .z = node.z, .node_type = cached.node_type, .penalty = cached.penalty },
                .passable = cached.passable,
            };
        }
        const result = block_queries.pathNodeInResident(self.blocks, resident, node.x, node.y, node.z, self.baby);
        cached.* = .{
            .world = self.world,
            .revision = resident.content_revision,
            .x = node.x,
            .y = node.y,
            .z = node.z,
            .baby = self.baby,
            .passable = result.passable,
            .node_type = result.node.node_type,
            .penalty = result.node.penalty,
        };
        return result;
    }

    fn resolveResident(self: *LandPathContext, slot: usize, chunk: geometry.ChunkPos) ?*const block_store.GeneratedHeightChunk {
        const resident = self.blocks.residentChunk(self.world, chunk) orelse return null;
        var dependency_index: usize = 0;
        while (dependency_index < self.dependency_count and !geometry.sameChunk(self.dependency_chunks[dependency_index], chunk)) : (dependency_index += 1) {}
        if (dependency_index == self.dependency_count and self.dependency_count < self.dependency_chunks.len) {
            self.dependency_chunks[dependency_index] = chunk;
            self.dependency_revisions[dependency_index] = resident.content_revision;
            self.dependency_count += 1;
        } else if (dependency_index == self.dependency_count) {
            self.dependencies_complete = false;
        }
        self.resident_chunks[slot] = chunk;
        self.residents[slot] = resident;
        return resident;
    }
};

fn blockedPathCandidate(node: navigation.Node) navigation.Candidate {
    return .{
        .node = .{
            .x = node.x,
            .y = node.y,
            .z = node.z,
            .node_type = .blocked,
            .penalty = -1,
        },
        .passable = false,
    };
}

fn navigationNodeCacheHash(world: world_identity.Handle, node: navigation.Node, baby: bool) usize {
    var value: u64 = @as(u32, @bitCast(node.x));
    value *%= 0x9e37_79b1_85eb_ca87;
    value ^= @as(u32, @bitCast(node.z));
    value *%= 0xc2b2_ae3d_27d4_eb4f;
    value ^= @as(u16, @bitCast(node.y));
    value ^= @as(u64, @intFromBool(baby)) << 63;
    value ^= @as(u32, @bitCast(world)) *% 0xd6e8_feb8;
    return @intCast(value ^ (value >> 32));
}

fn pathResidentHash(chunk: geometry.ChunkPos) usize {
    return @as(usize, @as(u32, @bitCast(chunk.x))) *% 0x9e37_79b1 ^ @as(usize, @as(u32, @bitCast(chunk.z))) *% 0x85eb_ca77;
}

fn livingEntityTicking(simulation: *const Dependencies, index: usize) bool {
    const chunk = geometry.ChunkPos{
        .x = @divFloor(geometry.blockCoord(simulation.living.entities.position_x[index]), 16),
        .z = @divFloor(geometry.blockCoord(simulation.living.entities.position_z[index]), 16),
    };
    return simulation.blocks.residentChunk(simulation.living.entities.worlds[index], chunk) != null and
        active_chunks.isEntityTicking(simulation.players, simulation.living.entities.worlds[index], chunk, config.simulation_distance_chunks);
}

const path_memo_capacity = 256;

const PathMemoEntry = struct {
    valid: bool = false,
    world: world_identity.Handle = world_identity.invalid,
    baby: bool = false,
    target_distance: i32 = 0,
    dependency_count: u8 = 0,
    dependency_chunks: [32]geometry.ChunkPos = undefined,
    dependency_revisions: [32]u64 = undefined,
    start: navigation.Node = .{ .x = 0, .y = 0, .z = 0 },
    target: navigation.Node = .{ .x = 0, .y = 0, .z = 0 },
    max_distance_bits: u32 = 0,
    max_iterations: usize = 0,
    length: u8 = 0,
    reaches_target: bool = false,
};

pub const ZombieAi = struct {
    pub const id = "minecraft:zombie_ai";

    paths: []PathMemoEntry = &.{},
    path_x: []align(64) i32 = &.{},
    path_y: []align(64) i16 = &.{},
    path_z: []align(64) i32 = &.{},
    path_node_type: []align(64) navigation.NodeType = &.{},
    path_penalty: []align(64) f32 = &.{},
    navigation_nodes: NavigationNodeCache = .{},
    clock: *world_clock.Clock,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, rules: *game_rules.GameRules, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, outputs: *Packets) !*ZombieAi {
        const self = try allocator.create(ZombieAi);
        self.* = .{ .clock = clock, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .outputs = outputs };
        try allocateBuffers(self, allocator);
        return self;
    }

    pub fn tick(self: *ZombieAi, _: std.mem.Allocator) void {
        var simulation = Dependencies{ .clock = self.clock, .rules = self.rules, .random = self.random, .blocks = self.blocks, .players = self.players, .living = self.living, .items = self.items };
        tickZombieBatch(&simulation, self, self.outputs);
    }
};

inline fn memoX(state: *ZombieAi, slot: usize) []i32 {
    return state.path_x[slot * navigation.path_capacity ..][0..navigation.path_capacity];
}

inline fn memoY(state: *ZombieAi, slot: usize) []i16 {
    return state.path_y[slot * navigation.path_capacity ..][0..navigation.path_capacity];
}

inline fn memoZ(state: *ZombieAi, slot: usize) []i32 {
    return state.path_z[slot * navigation.path_capacity ..][0..navigation.path_capacity];
}

inline fn memoNodeTypes(state: *ZombieAi, slot: usize) []navigation.NodeType {
    return state.path_node_type[slot * navigation.path_capacity ..][0..navigation.path_capacity];
}

inline fn memoPenalties(state: *ZombieAi, slot: usize) []f32 {
    return state.path_penalty[slot * navigation.path_capacity ..][0..navigation.path_capacity];
}

const LivingProfileSection = enum {
    bookkeeping,
    goals,
    navigation,
    collision_physics,
    packet_outputs,
    item_pickup,
    path_search,
    visibility,
};

const ZombieLootTrace = enum {
    pickups,
};

fn livingProfileNow() u64 {
    var now: std.os.linux.timespec = undefined;
    if (std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) return 0;
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn tickZombieItemPickup(simulation: *Dependencies, living_index: u16, outputs: *Packets) void {
    const index: usize = living_index;
    if (!simulation.rules.mob_griefing or !simulation.living.entities.can_pick_up_loot[index]) return;
    const position = geometry.Vec3{ .x = simulation.living.entities.position_x[index], .y = simulation.living.entities.position_y[index], .z = simulation.living.entities.position_z[index] };
    const width: f64 = if (simulation.living.entities.baby[index]) 0.3 else 0.6;
    const height: f64 = if (simulation.living.entities.baby[index]) 0.975 else 1.95;
    const cell = entity_store.itemSpatialCell(position);
    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const world = simulation.living.entities.worlds[index];
            var item_node = simulation.items.bucket_heads[entity_store.itemSpatialBucketForCell(world, cell.x + dx, cell.z + dz)];
            for (0..config.max_item_entities) |_| {
                if (item_node == entity_store.item_entity_sentinel) break;
                const item_index = item_node;
                item_node = simulation.items.next_in_bucket[item_index];
                if (!simulation.items.active[item_index] or !simulation.items.worlds[item_index].eql(world) or simulation.items.cell_x[item_index] != cell.x + dx or simulation.items.cell_z[item_index] != cell.z + dz or simulation.items.pickup_delay_ticks[item_index] != 0) continue;
                const item_position = simulation.itemPosition(item_index);
                if (item_position.x < position.x - width / 2 - 1 or item_position.x > position.x + width / 2 + 1 or
                    item_position.y < position.y or item_position.y > position.y + height or
                    item_position.z < position.z - width / 2 - 1 or item_position.z > position.z + width / 2 + 1) continue;
                const incoming = simulation.items.stacks[item_index];
                if (incoming.isEmpty() or incoming.item_id == registry.item_glow_ink_sac_id) continue;
                const equipment_slot = game_data.equipmentSlot(incoming.item_id);
                if (equipment_slot >= simulation.living.entities.equipment[index].len) continue;
                const equipped = simulation.living.entities.equipment[index][equipment_slot];
                if (equipped.count != 0 and !preferredEquipment(incoming, equipped, equipment_slot)) continue;

                if (equipped.count != 0) {
                    const drop_chance: f32 = if (simulation.living.entities.equipment_drop_guaranteed[index][equipment_slot]) 2 else 0.085;
                    if (simulation.living.entities.random[index].nextFloat() - 0.1 < drop_chance and simulation.items.free_count != 0) {
                        const dropped = player_store.stackForItem(equipped.item_id, equipped.count);
                        const dropped_index: ?usize = simulation.spawn_item_entity_with_pickup_delay(world, position, .{}, .{ .item_id = dropped.item_id, .block_state = dropped.block_state, .damage = equipped.damage, .count = equipped.count }, entity_store.block_drop_pickup_delay_ticks) catch null;
                        if (dropped_index) |spawned| outputs.item_spawned(@as(u16, @intCast(spawned)));
                    }
                }
                simulation.living.entities.equipment[index][equipment_slot] = .{ .item_id = incoming.item_id, .damage = incoming.damage, .count = 1 };
                simulation.living.entities.equipment_drop_guaranteed[index][equipment_slot] = true;
                simulation.living.entities.persistent[index] = true;
                if (equipment_slot >= 2) {
                    simulation.living.entities.armor[index] += game_data.armor(incoming.item_id) - game_data.armor(equipped.item_id);
                    simulation.living.entities.armor_toughness[index] += game_data.armorToughness(incoming.item_id) - game_data.armorToughness(equipped.item_id);
                } else if (equipment_slot == 0) {
                    simulation.living.entities.attack_damage[index] += game_data.playerAttackDamage(incoming.item_id) - game_data.playerAttackDamage(equipped.item_id);
                }
                const item_entity_id = simulation.items.entity_ids[item_index];
                simulation.items.stacks[item_index].count -= 1;
                outputs.item_collected(.{ .item_entity_id = item_entity_id, .collector_entity_id = simulation.living.entities.entity_ids[index], .count = 1 });
                if (simulation.items.stacks[item_index].count == 0) {
                    simulation.remove_item_entity(item_index);
                    outputs.entity_destroyed(item_entity_id);
                } else {
                    outputs.item_metadata_changed(item_index);
                }
                plugin_profiler.countTrace(ZombieLootTrace.pickups, 1);
                outputs.living_equipment_changed(.{ .index = living_index, .equipment_slot = equipment_slot });
                return;
            } else diagnostics.panic("item spatial bucket contains a cycle", &.{});
        }
    }
}

fn startZombieWander(
    simulation: *Dependencies,
    index: usize,
    outputs: *Packets,
    state: *ZombieAi,
) bool {
    const start = navigation.Node{
        .x = geometry.blockCoord(simulation.living.entities.position_x[index]),
        .y = @intFromFloat(@floor(simulation.living.entities.position_y[index] + 0.5)),
        .z = geometry.blockCoord(simulation.living.entities.position_z[index]),
    };
    var context = LandPathContext{
        .world = simulation.living.entities.worlds[index],
        .blocks = simulation.blocks,
        .search = &simulation.living.search,
        .node_cache = &state.navigation_nodes,
        .baby = simulation.living.entities.baby[index],
    };
    var target: ?navigation.Node = null;
    for (0..10) |_| {
        const x = start.x + @as(i32, @intCast(simulation.living.entities.random[index].nextIntBounded(21))) - 10;
        const sampled_y = @as(i32, start.y) + @as(i32, @intCast(simulation.living.entities.random[index].nextIntBounded(15))) - 7;
        const z = start.z + @as(i32, @intCast(simulation.living.entities.random[index].nextIntBounded(21))) - 10;
        if (target != null or (x == start.x and z == start.z)) continue;
        target = nearestWalkableWanderNode(&context, x, sampled_y, z);
    }
    const destination = target orelse return false;
    const found = findLivingPath(state, simulation, outputs, &context, index, start, destination, 0, 16, 256);
    if (found) simulation.living.paths.speed[index] = 1;
    return found;
}

fn nearestWalkableWanderNode(context: *LandPathContext, x: i32, sampled_y: i32, z: i32) ?navigation.Node {
    var distance: i32 = 0;
    while (distance <= 7) : (distance += 1) {
        const above_y = sampled_y + distance;
        if (above_y >= config.world_min_y and above_y < block_store.world_top_y) {
            const above = navigation.Node{ .x = x, .y = @intCast(above_y), .z = z };
            if (context.classifyPathNode(above).passable) return above;
        }
        if (distance == 0) continue;
        const below_y = sampled_y - distance;
        if (below_y >= config.world_min_y and below_y < block_store.world_top_y) {
            const below = navigation.Node{ .x = x, .y = @intCast(below_y), .z = z };
            if (context.classifyPathNode(below).passable) return below;
        }
    }
    return null;
}

fn tickZombieGoals(simulation: *Dependencies, index: usize, outputs: *Packets, state: *ZombieAi) void {
    if (simulation.living.entities.entity_types[index] != .zombie)
        diagnostics.panic("zombie AI received non-zombie entity (index, type, tick)", &.{
            diagnostics.integer(index),
            diagnostics.text(@tagName(simulation.living.entities.entity_types[index])),
            diagnostics.integer(simulation.clock.tick),
        });
    const selector_tick = zombieSelectorTick(simulation.living.entities.age[index], simulation.living.entities.entity_ids[index]);
    var visibility = TargetVisibility{};
    if (selector_tick) maintainZombieTarget(simulation, index, outputs, &visibility);
    if (selector_tick) acquireZombieTarget(simulation, index, outputs, &visibility);
    updateMeleeGoalState(simulation, index, selector_tick);
    if (selector_tick and !simulation.living.entities.melee_goal_running[index])
        startMeleeOrWander(simulation, index, outputs, state);
    if (simulation.living.entities.melee_goal_running[index])
        tickZombieMelee(simulation, index, outputs, state, visibility);
}

const TargetVisibility = struct {
    checked: bool = false,
    visible: bool = false,
};

fn maintainZombieTarget(simulation: *Dependencies, index: usize, outputs: *Packets, visibility: *TargetVisibility) void {
    if (!simulation.living.entities.target_goal_running[index]) return;
    var valid = switch (simulation.living.entities.targets[index]) {
        .player => |slot| slot < simulation.players.records.len and
            simulation.players.records[slot].state == .play and
            simulation.players.records[slot].world.eql(simulation.living.entities.worlds[index]) and
            simulation.players.records[slot].health > 0 and
            simulation.players.records[slot].gamemode != .creative and
            simulation.players.records[slot].gamemode != .spectator and
            livingDistanceSquaredToPlayer(&simulation.living.entities, index, &simulation.players.records[slot]) <=
                simulation.living.entities.follow_range[index] * simulation.living.entities.follow_range[index],
        else => false,
    };
    if (valid) {
        const slot = switch (simulation.living.entities.targets[index]) {
            .player => |value| value,
            else => unreachable,
        };
        visibility.* = .{
            .checked = true,
            .visible = profiledZombieCanSeePlayer(simulation, index, &simulation.players.records[slot], outputs),
        };
        if (visibility.visible) simulation.living.entities.target_unseen_selector_ticks[index] = 0 else {
            simulation.living.entities.target_unseen_selector_ticks[index] +|= 1;
            valid = simulation.living.entities.target_unseen_selector_ticks[index] <= 30;
        }
    }
    if (valid) return;
    simulation.living.entities.targets[index] = .none;
    simulation.living.entities.target_goal_running[index] = false;
    simulation.living.entities.target_unseen_selector_ticks[index] = 0;
}

fn acquireZombieTarget(simulation: *Dependencies, index: usize, outputs: *Packets, visibility: *TargetVisibility) void {
    if (simulation.living.entities.target_goal_running[index] or
        simulation.living.entities.random[index].nextIntBounded(5) != 0) return;
    var closest_slot: ?u16 = null;
    var closest_distance = simulation.living.entities.follow_range[index] * simulation.living.entities.follow_range[index];
    for (simulation.activePlayerSlots()) |slot| {
        const player = &simulation.players.records[slot];
        if (player.state != .play or !player.world.eql(simulation.living.entities.worlds[index]) or player.health <= 0 or
            player.gamemode == .creative or player.gamemode == .spectator) continue;
        const distance = livingDistanceSquaredToPlayer(&simulation.living.entities, index, player);
        if (distance > closest_distance or
            !profiledZombieCanSeePlayer(simulation, index, player, outputs)) continue;
        closest_distance = distance;
        closest_slot = @intCast(slot);
    }
    const slot = closest_slot orelse return;
    simulation.living.entities.targets[index] = .{ .player = slot };
    simulation.living.entities.target_goal_running[index] = true;
    simulation.living.entities.target_unseen_selector_ticks[index] = 0;
    visibility.* = .{ .checked = true, .visible = true };
}

fn updateMeleeGoalState(simulation: *Dependencies, index: usize, selector_tick: bool) void {
    const has_target = simulation.living.entities.targets[index] != .none;
    const stopped = simulation.living.entities.melee_goal_running[index] and
        (!has_target or (selector_tick and simulation.living.paths.isIdle(index)));
    if (!stopped) return;
    simulation.living.entities.melee_goal_running[index] = false;
    simulation.living.entities.attacking[index] = false;
    simulation.living.entities.melee_goal_ticks[index] = 0;
    simulation.living.paths.clear(index);
}

fn startMeleeOrWander(simulation: *Dependencies, index: usize, outputs: *Packets, state: *ZombieAi) void {
    _ = simulation.living.entities.random[index].nextFloat();
    _ = simulation.living.entities.random[index].nextFloat();
    const has_target = simulation.living.entities.targets[index] != .none;
    const tick = simulation.clock.tick;
    if (has_target and tick -% simulation.living.entities.melee_last_update_time[index] >= 20) {
        simulation.living.entities.melee_last_update_time[index] = tick;
        startMeleeGoal(simulation, index, outputs, state);
    }
    if (!simulation.living.entities.melee_goal_running[index] and
        simulation.living.paths.isIdle(index) and
        simulation.living.entities.despawn_counter[index] < 100 and
        simulation.living.entities.random[index].nextIntBounded(60) == 0)
        _ = startZombieWander(simulation, index, outputs, state);
}

fn startMeleeGoal(simulation: *Dependencies, index: usize, outputs: *Packets, state: *ZombieAi) void {
    const target_slot = switch (simulation.living.entities.targets[index]) {
        .player => |slot| slot,
        else => return,
    };
    const player = &simulation.players.records[target_slot];
    var context = landPathContext(simulation, state, index);
    const start = zombieNode(simulation, index);
    const target = navigation.Node{
        .x = geometry.blockCoord(player.position.x),
        .y = @intCast(geometry.blockCoord(player.position.y)),
        .z = geometry.blockCoord(player.position.z),
    };
    const max_iterations: usize = @intFromFloat(@floor(
        @max(@as(f64, 16), simulation.living.entities.follow_range[index]) * 16,
    ));
    const found = findLivingPath(
        state,
        simulation,
        outputs,
        &context,
        index,
        start,
        target,
        0,
        @floatCast(simulation.living.entities.follow_range[index]),
        max_iterations,
    );
    const player_box = collision.entityBox(player.position.x, player.position.y, player.position.z, 0.6, 1.8);
    if (!found and !zombieAttackBox(simulation, index).intersects(player_box)) return;
    simulation.living.paths.speed[index] = 1;
    simulation.living.entities.melee_goal_running[index] = true;
    simulation.living.entities.melee_goal_ticks[index] = 0;
    simulation.living.entities.melee_target_x[index] = 0;
    simulation.living.entities.melee_target_y[index] = 0;
    simulation.living.entities.melee_target_z[index] = 0;
    simulation.living.entities.melee_update_countdown[index] = 0;
    simulation.living.entities.attack_cooldown[index] = 0;
}

fn tickZombieMelee(simulation: *Dependencies, index: usize, outputs: *Packets, state: *ZombieAi, visibility: TargetVisibility) void {
    const target_slot = switch (simulation.living.entities.targets[index]) {
        .player => |slot| slot,
        else => unreachable,
    };
    const player = &simulation.players.records[target_slot];
    const can_see = if (visibility.checked) visibility.visible else profiledZombieCanSeePlayer(simulation, index, player, outputs);
    simulation.living.entities.melee_update_countdown[index] =
        @max(0, simulation.living.entities.melee_update_countdown[index] - 1);
    if (can_see and simulation.living.entities.melee_update_countdown[index] <= 0)
        updateMeleePath(simulation, index, outputs, state, player);
    simulation.living.entities.melee_goal_ticks[index] +%= 1;
    simulation.living.entities.attack_cooldown[index] = @max(0, simulation.living.entities.attack_cooldown[index] - 1);
    const player_box = collision.entityBox(player.position.x, player.position.y, player.position.z, 0.6, 1.8);
    if (simulation.living.entities.attack_cooldown[index] <= 0 and
        zombieAttackBox(simulation, index).intersects(player_box) and can_see)
        attackPlayer(simulation, index, outputs, target_slot);
    simulation.living.entities.attacking[index] =
        simulation.living.entities.melee_goal_ticks[index] >= 5 and
        simulation.living.entities.attack_cooldown[index] < 10;
}

fn updateMeleePath(simulation: *Dependencies, index: usize, outputs: *Packets, state: *ZombieAi, player: *player_store.CorePlayer) void {
    const never_cached = simulation.living.entities.melee_target_x[index] == 0 and
        simulation.living.entities.melee_target_y[index] == 0 and
        simulation.living.entities.melee_target_z[index] == 0;
    const dx = player.position.x - simulation.living.entities.melee_target_x[index];
    const dy = player.position.y - simulation.living.entities.melee_target_y[index];
    const dz = player.position.z - simulation.living.entities.melee_target_z[index];
    if (!never_cached and dx * dx + dy * dy + dz * dz < 1 and
        simulation.living.entities.random[index].nextFloat() >= 0.05) return;
    simulation.living.entities.melee_target_x[index] = player.position.x;
    simulation.living.entities.melee_target_y[index] = player.position.y;
    simulation.living.entities.melee_target_z[index] = player.position.z;
    simulation.living.entities.melee_update_countdown[index] =
        4 + simulation.living.entities.random[index].nextIntBounded(7);
    const distance = livingDistanceSquaredToPlayer(&simulation.living.entities, index, player);
    if (distance > 1024) simulation.living.entities.melee_update_countdown[index] += 10 else if (distance > 256)
        simulation.living.entities.melee_update_countdown[index] += 5;
    var context = landPathContext(simulation, state, index);
    const target = navigation.Node{
        .x = geometry.blockCoord(player.position.x),
        .y = @intCast(geometry.blockCoord(player.position.y)),
        .z = geometry.blockCoord(player.position.z),
    };
    const max_iterations: usize = @intFromFloat(@floor(
        @max(@as(f64, 16), simulation.living.entities.follow_range[index]) * 16,
    ));
    const found = findLivingPath(
        state,
        simulation,
        outputs,
        &context,
        index,
        zombieNode(simulation, index),
        target,
        1,
        @floatCast(simulation.living.entities.follow_range[index]),
        max_iterations,
    );
    if (found) simulation.living.paths.speed[index] = 1 else simulation.living.entities.melee_update_countdown[index] += 15;
}

fn landPathContext(simulation: *Dependencies, state: *ZombieAi, index: usize) LandPathContext {
    return .{
        .world = simulation.living.entities.worlds[index],
        .blocks = simulation.blocks,
        .search = &simulation.living.search,
        .node_cache = &state.navigation_nodes,
        .baby = simulation.living.entities.baby[index],
    };
}

fn zombieNode(simulation: *Dependencies, index: usize) navigation.Node {
    return .{
        .x = geometry.blockCoord(simulation.living.entities.position_x[index]),
        .y = @intFromFloat(@floor(simulation.living.entities.position_y[index] + 0.5)),
        .z = geometry.blockCoord(simulation.living.entities.position_z[index]),
    };
}

fn zombieAttackBox(simulation: *Dependencies, index: usize) collision.Box {
    const width: f32 = if (simulation.living.entities.baby[index]) 0.3 else 0.6;
    const height: f32 = if (simulation.living.entities.baby[index]) 0.975 else 1.95;
    const base = collision.entityBox(
        simulation.living.entities.position_x[index],
        simulation.living.entities.position_y[index],
        simulation.living.entities.position_z[index],
        width,
        height,
    );
    const range = @sqrt(@as(f64, @floatCast(@as(f32, 2.04)))) - @as(f64, @floatCast(@as(f32, 0.6)));
    return .{
        .min_x = base.min_x - range,
        .min_y = base.min_y,
        .min_z = base.min_z - range,
        .max_x = base.max_x + range,
        .max_y = base.max_y,
        .max_z = base.max_z + range,
    };
}

fn attackPlayer(simulation: *Dependencies, index: usize, outputs: *Packets, target_slot: u16) void {
    simulation.living.entities.attack_cooldown[index] = 20;
    simulation.living.entities.hand_swinging[index] = true;
    simulation.living.entities.hand_swing_ticks[index] = -1;
    outputs.living_arm_swing(@intCast(index));
    const player = &simulation.players.records[target_slot];
    if (player.health <= 0 or player.gamemode == .creative or player.gamemode == .spectator) return;
    const amount: f32 = @floatCast(simulation.living.entities.attack_damage[index]);
    var applied = amount;
    if (player.time_until_regen > 10) {
        if (amount <= player.last_damage_taken) applied = 0 else applied -= player.last_damage_taken;
    } else player.time_until_regen = 20;
    if (applied <= 0) return;
    player.last_damage_taken = amount;
    player.health = @max(0, player.health - applied);
    outputs.player_damaged(.{
        .slot = target_slot,
        .source = .{ .mob = simulation.living.entities.entity_ids[index] },
        .fatal = player.health == 0,
    });
}

fn zombieSelectorTick(age: u32, entity_id: i32) bool {
    // MobEntity.tickNewAi runs both selectors fully when (age + id) % 2 is
    // zero (and during the first entity tick). On the other half of ticks it
    // only advances goals whose shouldRunEveryTick() returns true.
    return age <= 1 or (age +% @as(u32, @bitCast(entity_id))) % 2 == 0;
}

test "zombie goal selectors use vanilla's staggered every-other-tick cadence" {
    var full_ticks: usize = 0;
    for (2..22) |age| full_ticks += @intFromBool(zombieSelectorTick(@intCast(age), 17));
    try std.testing.expectEqual(@as(usize, 10), full_ticks);
    try std.testing.expect(zombieSelectorTick(1, 17));
    try std.testing.expect(zombieSelectorTick(2, 18));
    try std.testing.expect(!zombieSelectorTick(2, 17));
}

test "an idle zombie can start a wander path" {
    const Outputs = struct {};
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 91);
    defer simulation.deinit();
    simulation.blocks.ensureChunkAt(simulation.world, 8, 8, 0);
    const y: i32 = 65;
    for (7..11) |x| for (7..11) |z| {
        _ = try simulation.blocks.setBlock(
            simulation.world,
            .{ .x = @intCast(x), .y = y - 1, .z = @intCast(z) },
            registry.block_stone_default_state,
        );
        _ = try simulation.blocks.setBlock(
            simulation.world,
            .{ .x = @intCast(x), .y = y, .z = @intCast(z) },
            registry.block_air_default_state,
        );
        _ = try simulation.blocks.setBlock(
            simulation.world,
            .{ .x = @intCast(x), .y = y + 1, .z = @intCast(z) },
            registry.block_air_default_state,
        );
    };
    const handle = try simulation.spawnLiving(.zombie, .{
        .x = 8.5,
        .y = @floatFromInt(y),
        .z = 8.5,
    }, false, true);
    simulation.living.entities.on_ground[handle.index] = true;
    var candidate_seed: u64 = 0;
    for (0..1_000_000) |_| {
        var candidate = simulation.living.entities.random[handle.index];
        candidate.setSeed(candidate_seed);
        if (candidate.nextIntBounded(21) == 11 and
            candidate.nextIntBounded(15) == 7 and
            candidate.nextIntBounded(21) == 10)
        {
            simulation.living.entities.random[handle.index].setSeed(candidate_seed);
            break;
        }
        candidate_seed += 1;
    }
    var outputs = Outputs{};
    var state = ZombieAi{};
    var state_storage = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state_storage.deinit();
    try state.init(state_storage.allocator());
    var dependencies = Dependencies{
        .clock = simulation.clock,
        .rules = simulation.rules,
        .random = simulation.random,
        .blocks = simulation.blocks,
        .players = simulation.players,
        .living = simulation.living,
        .items = simulation.items,
    };

    try std.testing.expect(startZombieWander(*Outputs, &dependencies, handle.index, &outputs, &state));
    try std.testing.expect(!simulation.living.paths.isIdle(handle.index));
    _ = tickLivingNavigation(&dependencies, handle.index);
    try std.testing.expect(simulation.living.entities.velocity_x[handle.index] != 0 or
        simulation.living.entities.velocity_z[handle.index] != 0);
}

fn tickLivingNavigation(simulation: *Dependencies, index: usize) bool {
    if (simulation.living.paths.isIdle(index)) return false;
    const node = simulation.living.paths.currentNode(index) orelse return false;
    const target_x = @as(f64, @floatFromInt(node.x)) + 0.5;
    const target_z = @as(f64, @floatFromInt(node.z)) + 0.5;
    const dx = target_x - simulation.living.entities.position_x[index];
    const dz = target_z - simulation.living.entities.position_z[index];
    const width: f32 = if (simulation.living.entities.baby[index]) 0.3 else 0.6;
    const reach: f64 = if (width > 0.75) @as(f64, width) / 2.0 else 0.75 - @as(f64, width) / 2.0;
    if (@abs(dx) < reach and @abs(dz) < reach and @abs(simulation.living.entities.position_y[index] - @as(f64, @floatFromInt(node.y))) < 1) {
        simulation.living.paths.current[index] += 1;
        if (simulation.living.paths.isIdle(index)) return false;
    }

    const move_node = simulation.living.paths.currentNode(index) orelse return false;
    const move_x = @as(f64, @floatFromInt(move_node.x)) + 0.5;
    const move_z = @as(f64, @floatFromInt(move_node.z)) + 0.5;
    const move_dx = move_x - simulation.living.entities.position_x[index];
    const move_dz = move_z - simulation.living.entities.position_z[index];
    const horizontal_distance_squared = move_dx * move_dx + move_dz * move_dz;
    if (horizontal_distance_squared < 2.500000277905201e-7) return false;

    const desired_yaw = vanilla_math.movementYaw(move_dz, move_dx);
    simulation.living.entities.yaw[index] = vanilla_math.changeAngle(simulation.living.entities.yaw[index], desired_yaw, 90);
    const movement_speed: f32 = @floatCast(simulation.living.paths.speed[index] * simulation.living.entities.movement_speed[index]);
    const slipperiness: f32 = 0.6;
    const acceleration: f32 = if (simulation.living.entities.on_ground[index])
        movement_speed * (@as(f32, 0.21600002) / (slipperiness * slipperiness * slipperiness))
    else
        0.02;
    const forward: f64 = @floatCast(movement_speed);
    const scale: f64 = @floatCast(acceleration);
    const radians = simulation.living.entities.yaw[index] * @as(f32, 0.017453292);
    const sin_yaw: f64 = @floatCast(vanilla_math.sin(radians));
    const cos_yaw: f64 = @floatCast(vanilla_math.cos(radians));
    simulation.living.entities.velocity_x[index] -= forward * scale * sin_yaw;
    simulation.living.entities.velocity_z[index] += forward * scale * cos_yaw;
    if (!std.math.isFinite(simulation.living.entities.velocity_x[index]) or
        !std.math.isFinite(simulation.living.entities.velocity_z[index]))
    {
        diagnostics.panic("zombie navigation produced non-finite velocity (index, position x, position z, node x, node z, dx, dz, yaw, sin, cos)", &.{
            diagnostics.integer(index),
            diagnostics.float(simulation.living.entities.position_x[index]),
            diagnostics.float(simulation.living.entities.position_z[index]),
            diagnostics.integer(move_node.x),
            diagnostics.integer(move_node.z),
            diagnostics.float(move_dx),
            diagnostics.float(move_dz),
            diagnostics.float(simulation.living.entities.yaw[index]),
            diagnostics.float(sin_yaw),
            diagnostics.float(cos_yaw),
        });
    }
    const step_height: f64 = 0.6;
    const vertical_delta = @as(f64, @floatFromInt(move_node.y)) - simulation.living.entities.position_y[index];
    return vertical_delta > step_height and horizontal_distance_squared < @max(@as(f64, 1), @as(f64, width));
}

fn preferredEquipment(incoming: player_store.HotbarStack, equipped: living_entities.EquipmentStack, equipment_slot: u8) bool {
    if (equipment_slot >= 2) {
        const incoming_armor = game_data.armor(incoming.item_id);
        const equipped_armor = game_data.armor(equipped.item_id);
        if (incoming_armor != equipped_armor) return incoming_armor > equipped_armor;
        const incoming_toughness = game_data.armorToughness(incoming.item_id);
        const equipped_toughness = game_data.armorToughness(equipped.item_id);
        if (incoming_toughness != equipped_toughness) return incoming_toughness > equipped_toughness;
    } else {
        const incoming_damage = game_data.playerAttackDamage(incoming.item_id);
        const equipped_damage = game_data.playerAttackDamage(equipped.item_id);
        if (incoming_damage != equipped_damage) return incoming_damage > equipped_damage;
    }
    const incoming_max = game_data.maxDurability(incoming.item_id);
    const equipped_max = game_data.maxDurability(equipped.item_id);
    if (incoming_max == 0 or equipped_max == 0) return false;
    return incoming_max -| incoming.damage > equipped_max -| equipped.damage;
}

fn livingDistanceSquaredToPlayer(pool: *const living_entities.Pool, index: usize, player: *const player_store.CorePlayer) f64 {
    const dx = pool.position_x[index] - player.position.x;
    const dy = pool.position_y[index] - player.position.y;
    const dz = pool.position_z[index] - player.position.z;
    return dx * dx + dy * dy + dz * dz;
}

fn zombieCanSeePlayer(simulation: *Dependencies, index: usize, player: *const player_store.CorePlayer) bool {
    return block_queries.hasLineOfSight(
        simulation.blocks,
        simulation.living.entities.worlds[index],
        .{
            .x = simulation.living.entities.position_x[index],
            .y = simulation.living.entities.position_y[index] + (if (simulation.living.entities.baby[index]) @as(f64, 0.93) else @as(f64, 1.74)),
            .z = simulation.living.entities.position_z[index],
        },
        .{ .x = player.position.x, .y = player.position.y + 1.62, .z = player.position.z },
    );
}

fn findLivingPath(
    state: *ZombieAi,
    simulation: *Dependencies,
    outputs: *Packets,
    context: *LandPathContext,
    entity: usize,
    start: navigation.Node,
    target: navigation.Node,
    target_distance: i32,
    max_distance: f32,
    max_iterations: usize,
) bool {
    const slot = pathMemoHash(start, target, target_distance, context.baby, max_distance, max_iterations) & (path_memo_capacity - 1);
    const entry = &state.paths[slot];
    if (entry.valid and entry.world.eql(context.world) and pathMemoDependenciesValid(simulation.blocks, entry) and entry.baby == context.baby and entry.target_distance == target_distance and
        samePathNode(entry.start, start) and samePathNode(entry.target, target) and entry.max_distance_bits == @as(u32, @bitCast(max_distance)) and entry.max_iterations == max_iterations)
    {
        simulation.living.paths.clear(entity);
        simulation.living.paths.target_x[entity] = target.x;
        simulation.living.paths.target_y[entity] = target.y;
        simulation.living.paths.target_z[entity] = target.z;
        simulation.living.paths.length[entity] = entry.length;
        simulation.living.paths.reaches_target[entity] = entry.reaches_target;
        const length: usize = entry.length;
        @memcpy(simulation.living.paths.xFor(entity)[0..length], memoX(state, slot)[0..length]);
        @memcpy(simulation.living.paths.yFor(entity)[0..length], memoY(state, slot)[0..length]);
        @memcpy(simulation.living.paths.zFor(entity)[0..length], memoZ(state, slot)[0..length]);
        @memcpy(simulation.living.paths.nodeTypesFor(entity)[0..length], memoNodeTypes(state, slot)[0..length]);
        @memcpy(simulation.living.paths.penaltiesFor(entity)[0..length], memoPenalties(state, slot)[0..length]);
        livingProfilePathCache(outputs, true);
        return entry.length != 0;
    }

    livingProfilePathCache(outputs, false);
    const path_started = livingProfileOperationStart(outputs);
    const found = simulation.living.search.findPath(context, &simulation.living.paths, entity, start, target, target_distance, max_distance, max_iterations);
    livingProfileOperationEnd(outputs, LivingProfileSection.path_search, path_started);
    livingProfilePathSearch(outputs, &simulation.living.search);
    entry.valid = context.dependencies_complete;
    entry.world = context.world;
    entry.dependency_count = context.dependency_count;
    @memcpy(entry.dependency_chunks[0..context.dependency_count], context.dependency_chunks[0..context.dependency_count]);
    @memcpy(entry.dependency_revisions[0..context.dependency_count], context.dependency_revisions[0..context.dependency_count]);
    entry.baby = context.baby;
    entry.target_distance = target_distance;
    entry.start = start;
    entry.target = target;
    entry.max_distance_bits = @bitCast(max_distance);
    entry.max_iterations = max_iterations;
    entry.length = simulation.living.paths.length[entity];
    entry.reaches_target = simulation.living.paths.reaches_target[entity];
    const length: usize = entry.length;
    @memcpy(memoX(state, slot)[0..length], simulation.living.paths.xFor(entity)[0..length]);
    @memcpy(memoY(state, slot)[0..length], simulation.living.paths.yFor(entity)[0..length]);
    @memcpy(memoZ(state, slot)[0..length], simulation.living.paths.zFor(entity)[0..length]);
    @memcpy(memoNodeTypes(state, slot)[0..length], simulation.living.paths.nodeTypesFor(entity)[0..length]);
    @memcpy(memoPenalties(state, slot)[0..length], simulation.living.paths.penaltiesFor(entity)[0..length]);
    return found;
}

fn pathMemoDependenciesValid(blocks: *const block_store.Blocks, entry: *const PathMemoEntry) bool {
    for (entry.dependency_chunks[0..entry.dependency_count], entry.dependency_revisions[0..entry.dependency_count]) |chunk, revision| {
        const resident = blocks.residentChunk(entry.world, chunk) orelse return false;
        if (resident.content_revision != revision) return false;
    }
    return true;
}

fn samePathNode(a: navigation.Node, b: navigation.Node) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

fn pathMemoHash(start: navigation.Node, target: navigation.Node, target_distance: i32, baby: bool, max_distance: f32, max_iterations: usize) usize {
    var value: u64 = @as(u32, @bitCast(start.x));
    value *%= 0x9e37_79b9_7f4a_7c15;
    value ^= @as(u32, @bitCast(start.z));
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= @as(u16, @bitCast(start.y));
    value ^= @as(u32, @bitCast(target.x)) << 17;
    value ^= @as(u32, @bitCast(target.z)) << 3;
    value ^= @as(u16, @bitCast(target.y));
    value ^= @as(u32, @bitCast(target_distance));
    value ^= @as(u32, @bitCast(max_distance));
    value ^= @as(u64, @intCast(max_iterations));
    value ^= @intFromBool(baby);
    return @intCast(value ^ (value >> 31));
}

fn profiledZombieCanSeePlayer(
    simulation: *Dependencies,
    index: usize,
    player: *const player_store.CorePlayer,
    outputs: *Packets,
) bool {
    const started = livingProfileOperationStart(outputs);
    const visible = zombieCanSeePlayer(simulation, index, player);
    livingProfileOperationEnd(outputs, LivingProfileSection.visibility, started);
    return visible;
}

fn livingProfileOperationStart(outputs: *Packets) u64 {
    _ = outputs;
    return if (Packets.profiles_living) livingProfileNow() else 0;
}

fn livingProfileOperationEnd(outputs: *Packets, comptime section: LivingProfileSection, started: u64) void {
    if (Packets.profiles_living)
        outputs.living_profile(section, livingProfileNow() -| started);
}

fn livingProfilePathSearch(outputs: *Packets, search: *const navigation.Search) void {
    if (Packets.profiles_living)
        outputs.living_path_search(search.last_iterations, search.count);
}

fn livingProfilePathCache(outputs: *Packets, hit: bool) void {
    if (Packets.profiles_living)
        outputs.living_path_cache(hit);
}

fn tickAmbient(living: *living_entities.Pool, index: usize) void {
    const ambient_roll = living.random[index].nextIntBounded(1000);
    const ambient_before = living.ambient_sound_chance[index];
    living.ambient_sound_chance[index] +%= 1;
    if (ambient_roll < ambient_before)
        living.ambient_sound_chance[index] = -living.random[index].nextIntBounded(20) + 80;
}

fn tickZombieBatch(simulation: *Dependencies, state: *ZombieAi, outputs: *Packets) void {
    for (simulation.living.entities.active_indices[0..simulation.living.entities.active_count]) |living_index| {
        const index: usize = living_index;
        if (simulation.living.entities.entity_types[index] != .zombie or
            simulation.living.entities.dead[index]) continue;
        if (!livingEntityTicking(simulation, index)) {
            simulation.living.paths.clear(index);
            simulation.living.entities.jump_requested[index] = false;
            continue;
        }
        tickAmbient(&simulation.living.entities, index);
        const previous_yaw = simulation.living.entities.yaw[index];
        const previous_pitch = simulation.living.entities.pitch[index];
        const previous_attacking = simulation.living.entities.attacking[index];
        tickZombieGoals(simulation, index, outputs, state);
        simulation.living.entities.jump_requested[index] = tickLivingNavigation(simulation, index);
        simulation.living.entities.pose_dirty[index] = simulation.living.entities.pose_dirty[index] or
            simulation.living.entities.yaw[index] != previous_yaw or
            simulation.living.entities.pitch[index] != previous_pitch;
        simulation.living.entities.metadata_dirty[index] = simulation.living.entities.metadata_dirty[index] or
            simulation.living.entities.attacking[index] != previous_attacking;
    }
}

fn allocateBuffers(state: *ZombieAi, allocator: std.mem.Allocator) !void {
    state.paths = try preallocated.alloc(PathMemoEntry, allocator, path_memo_capacity);
    const node_capacity = path_memo_capacity * navigation.path_capacity;
    state.path_x = try preallocated.alignedAlloc(i32, allocator, .@"64", node_capacity);
    state.path_y = try preallocated.alignedAlloc(i16, allocator, .@"64", node_capacity);
    state.path_z = try preallocated.alignedAlloc(i32, allocator, .@"64", node_capacity);
    state.path_node_type = try preallocated.alignedAlloc(navigation.NodeType, allocator, .@"64", node_capacity);
    state.path_penalty = try preallocated.alignedAlloc(f32, allocator, .@"64", node_capacity);
    state.navigation_nodes.entries = try preallocated.alloc(NavigationNodeCacheEntry, allocator, navigation_node_cache_capacity);
    @memset(state.paths, .{});
    @memset(state.navigation_nodes.entries, .{});
    vanilla_math.initialize();
}

pub const ZombieDaylight = struct {
    pub const id = "minecraft:zombie_daylight";

    time: *vanilla_time.Time,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,

    pub fn create(allocator: std.mem.Allocator, time: *vanilla_time.Time, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities) !*ZombieDaylight {
        const self = try allocator.create(ZombieDaylight);
        self.* = .{ .time = time, .blocks = blocks, .players = players, .living = living };
        return self;
    }

    pub fn tick(self: *ZombieDaylight, _: std.mem.Allocator) void {
        tickZombieDaylight(self.time, self.blocks, self.players, &self.living.entities);
    }
};

fn tickZombieDaylight(time: *vanilla_time.Time, blocks: *block_store.Blocks, players: *const player_store.Players, entities: *living_entities.Pool) void {
    const day_time = time.day_time % 24_000;
    if (day_time >= 12_000) return;
    for (entities.active_indices[0..entities.active_count]) |index| {
        if (entities.entity_types[index] != .zombie or entities.dead[index] or entities.equipment[index][5].count != 0) continue;
        const chunk = geometry.ChunkPos{
            .x = @divFloor(geometry.blockCoord(entities.position_x[index]), 16),
            .z = @divFloor(geometry.blockCoord(entities.position_z[index]), 16),
        };
        if (blocks.residentChunk(entities.worlds[index], chunk) == null or !active_chunks.isEntityTicking(players, entities.worlds[index], chunk, config.simulation_distance_chunks)) continue;
        const x = geometry.blockCoord(entities.position_x[index]);
        const z = geometry.blockCoord(entities.position_z[index]);
        const head_y = geometry.blockCoord(entities.position_y[index] + living_entities.height(.zombie, entities.baby[index]));
        if (head_y <= blocks.highestGeneratedY(entities.worlds[index], x, z)) continue;
        if (entities.fire_ticks[index] <= 0) {
            entities.fire_ticks[index] = 160;
            entities.metadata_dirty[index] = true;
        }
    }
}

pub const ZombieLoot = struct {
    pub const id = "minecraft:zombie_loot_pickup";
    pub const Trace = ZombieLootTrace;

    clock: *world_clock.Clock,
    rules: *game_rules.GameRules,
    random: *world_random.Random,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    living: *entity_store.LivingEntities,
    items: *entity_store.ItemEntities,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, rules: *game_rules.GameRules, random: *world_random.Random, blocks: *block_store.Blocks, players: *player_store.Players, living: *entity_store.LivingEntities, items: *entity_store.ItemEntities, outputs: *Packets) !*ZombieLoot {
        const self = try allocator.create(ZombieLoot);
        self.* = .{ .clock = clock, .rules = rules, .random = random, .blocks = blocks, .players = players, .living = living, .items = items, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *ZombieLoot, _: std.mem.Allocator) void {
        var simulation = Dependencies{ .clock = self.clock, .rules = self.rules, .random = self.random, .blocks = self.blocks, .players = self.players, .living = self.living, .items = self.items };
        tickZombieLoot(&simulation, self.outputs);
    }
};

fn tickZombieLoot(simulation: *Dependencies, outputs: *Packets) void {
    if (!simulation.rules.mob_griefing or simulation.items.active_count == 0) return;
    for (simulation.living.entities.active_indices[0..simulation.living.entities.active_count]) |living_index| {
        const index: usize = living_index;
        if (simulation.living.entities.entity_types[index] != .zombie or
            simulation.living.entities.dead[index]) continue;
        if (!livingEntityTicking(simulation, index)) continue;
        tickZombieItemPickup(simulation, living_index, outputs);
    }
}

test "exposed unhelmeted zombies burn only during daylight" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 23);
    defer simulation.deinit();
    simulation.players.records[0].state = .play;
    simulation.players.records[0].position = .{ .x = 8.5, .y = 65, .z = 8.5 };
    simulation.players.rebuildActive();
    simulation.blocks.ensureChunkAt(simulation.world, 8, 8, 0);
    const surface = simulation.blocks.highestGeneratedY(simulation.world, 8, 8);
    const handle = try simulation.spawnLiving(.zombie, .{
        .x = 8.5,
        .y = @floatFromInt(@as(i32, surface) + 1),
        .z = 8.5,
    }, false, true);

    simulation.time.day_time = 1_000;
    tickZombieDaylight(simulation.time, simulation.blocks, simulation.players, &simulation.living.entities);
    try std.testing.expectEqual(@as(i32, 160), simulation.living.entities.fire_ticks[handle.index]);
    try std.testing.expect(simulation.living.entities.metadata_dirty[handle.index]);

    simulation.living.entities.fire_ticks[handle.index] = 0;
    simulation.living.entities.metadata_dirty[handle.index] = false;
    simulation.time.day_time = 13_000;
    tickZombieDaylight(simulation.time, simulation.blocks, simulation.players, &simulation.living.entities);
    try std.testing.expectEqual(@as(i32, 0), simulation.living.entities.fire_ticks[handle.index]);

    simulation.time.day_time = 1_000;
    simulation.living.entities.equipment[handle.index][5] = .{ .item_id = 1, .count = 1 };
    tickZombieDaylight(simulation.time, simulation.blocks, simulation.players, &simulation.living.entities);
    try std.testing.expectEqual(@as(i32, 0), simulation.living.entities.fire_ticks[handle.index]);
}
const vanilla_time = lightning_rod.time;
