const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const world_clock = lightning_rod.clock;
const world_store = lightning_rod.worlds;
const std = @import("std");
const Packets = lightning_rod.Packets;
const config = lightning_rod.config.value;
const registry = lightning_rod.registry_data;
const collision = lightning_rod.collision;
const diagnostics = lightning_rod.diagnostics;
const test_state = lightning_rod.test_support.state;

fn sameVec3(a: geometry.Vec3, b: geometry.Vec3) bool {
    return a.x == b.x and a.y == b.y and a.z == b.z;
}

fn applyPendingMovement(players: *player_store.Players, inputs: *input_store.Inputs, slot: u16) ?input_store.PreviousMovement {
    std.debug.assert(slot < players.records.len);
    const pending = &inputs.movements[slot];
    if (!pending.dirty) return null;
    const player = &players.records[slot];
    if (player.state != .play or player.health <= 0) {
        pending.* = .{};
        return null;
    }
    const previous = input_store.PreviousMovement{ .position = player.position, .rotation = player.rotation, .on_ground = player.on_ground };
    const changed = (pending.has_position and !sameVec3(pending.position, player.position)) or
        (pending.has_rotation and (pending.rotation.yaw != player.rotation.yaw or pending.rotation.pitch != player.rotation.pitch)) or
        pending.on_ground != player.on_ground;
    if (pending.has_position) player.position = pending.position;
    if (pending.has_rotation) player.rotation = pending.rotation;
    player.on_ground = pending.on_ground;
    pending.* = .{};
    if (pending.dirty)
        diagnostics.panic("player input invariant failed: pending movement remained dirty after consumption (player slot)", &.{diagnostics.integer(slot)});
    return if (changed) previous else null;
}

pub const MovementValidation = struct {
    pub const id = "lightning_rod:survival_movement_validation";

    airborne_origin_y: []f64 = &.{},
    airborne_ticks: []u16 = &.{},
    floating_ticks: []u16 = &.{},
    initialized: []bool = &.{},
    player_session_generation: []u64 = &.{},
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    inputs: *input_store.Inputs,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) !*MovementValidation {
        const self = try allocator.create(MovementValidation);
        self.* = .{ .blocks = blocks, .players = players, .inputs = inputs, .outputs = outputs };
        self.airborne_origin_y = try allocator.alloc(f64, config.connectionCapacity());
        self.airborne_ticks = try allocator.alloc(u16, config.connectionCapacity());
        self.floating_ticks = try allocator.alloc(u16, config.connectionCapacity());
        self.initialized = try allocator.alloc(bool, config.connectionCapacity());
        self.player_session_generation = try allocator.alloc(u64, config.connectionCapacity());
        @memset(self.airborne_origin_y, 0);
        @memset(self.airborne_ticks, 0);
        @memset(self.floating_ticks, 0);
        @memset(self.initialized, false);
        @memset(self.player_session_generation, 0);
        return self;
    }

    pub fn tick(self: *MovementValidation, _: std.mem.Allocator) void {
        const blocks = self.blocks;
        const players = self.players;
        const inputs = self.inputs;
        const outputs = self.outputs;
        for (players.activeSlots()) |slot| {
            beginPlayerSession(self, players, slot);
            const pending = &inputs.movements[slot];
            const player = &players.records[slot];
            if (!pending.dirty or !pending.has_position or player.gamemode == .creative or player.gamemode == .spectator) continue;
            if (movementIsValid(blocks, players, inputs, self, slot)) continue;
            pending.* = .{};
            self.airborne_ticks[slot] = 0;
            self.floating_ticks[slot] = 0;
            self.initialized[slot] = false;
            outputs.player_movement_rejected(slot);
        }
    }
};

const maximum_survival_jump_rise = 2.0;
const vanilla_floating_grace_ticks: u16 = 80;
const collision_epsilon = 1.0e-7;

fn playerCollisionBox(position: geometry.Vec3) collision.Box {
    var box = collision.entityBox(position.x, position.y, position.z, 0.6, 1.8);
    box.min_x += collision_epsilon;
    box.min_y += collision_epsilon;
    box.min_z += collision_epsilon;
    box.max_x -= collision_epsilon;
    box.max_y -= collision_epsilon;
    box.max_z -= collision_epsilon;
    return box;
}

fn beginPlayerSession(state: *MovementValidation, players: *player_store.Players, slot: usize) void {
    const generation = players.session_generations[slot];
    if (state.player_session_generation[slot] == generation) return;
    state.player_session_generation[slot] = generation;
    state.initialized[slot] = false;
    state.airborne_ticks[slot] = 0;
    state.floating_ticks[slot] = 0;
}

fn movementIsValid(blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, state: *MovementValidation, slot: usize) bool {
    const pending = &inputs.movements[slot];
    const player = &players.records[slot];
    const candidate = pending.position;
    const dx = candidate.x - player.position.x;
    const dy = candidate.y - player.position.y;
    const dz = candidate.z - player.position.z;
    if (!std.math.isFinite(candidate.x) or !std.math.isFinite(candidate.y) or
        !std.math.isFinite(candidate.z) or dx * dx + dy * dy + dz * dz > 100 * 100) return false;
    const candidate_chunk = geometry.chunkForBlock(.{
        .x = geometry.blockCoord(candidate.x),
        .y = @intCast(std.math.clamp(geometry.blockCoord(candidate.y), @as(i32, config.world_min_y), @as(i32, block_store.world_top_y))),
        .z = geometry.blockCoord(candidate.z),
    });
    if (blocks.residentChunk(player.world, candidate_chunk) == null or
        block_queries.livingBoxCollides(blocks, player.world, playerCollisionBox(candidate))) return false;
    const previous_supported = block_queries.playerGroundSupported(blocks, player.world, player.position);
    const candidate_supported = block_queries.playerGroundSupported(blocks, player.world, candidate);
    if (!state.initialized[slot] or previous_supported) {
        state.initialized[slot] = true;
        state.airborne_ticks[slot] = 0;
        state.floating_ticks[slot] = 0;
        state.airborne_origin_y[slot] = player.position.y;
    }
    if (candidate_supported) {
        state.airborne_ticks[slot] = 0;
        state.floating_ticks[slot] = 0;
        state.airborne_origin_y[slot] = candidate.y;
        return true;
    }
    if (previous_supported) {
        state.airborne_origin_y[slot] = player.position.y;
        state.airborne_ticks[slot] = 1;
        state.floating_ticks[slot] = 0;
        return candidate.y - player.position.y <= maximum_survival_jump_rise;
    }
    state.airborne_ticks[slot] +|= 1;
    if (@abs(dy) >= 0.03125) {
        state.floating_ticks[slot] = 0;
        return candidate.y - state.airborne_origin_y[slot] <= maximum_survival_jump_rise;
    }
    state.floating_ticks[slot] +|= 1;
    return candidate.y - state.airborne_origin_y[slot] <= maximum_survival_jump_rise and
        state.floating_ticks[slot] <= vanilla_floating_grace_ticks;
}

fn applyPlayerFlags(players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.player_inputs[slot];
        const sprint_action = &inputs.sprint_actions[slot];
        if (!pending.dirty and !sprint_action.dirty) {
            @branchHint(.likely);
            continue;
        }
        const player = &players.records[slot];
        var shift = player.sneaking;
        if (pending.dirty) shift = pending.shift;
        var sprinting = player.sprinting;
        if (sprint_action.dirty) sprinting = sprint_action.sprinting;
        pending.* = .{};
        sprint_action.* = .{};
        if (player.state != .play or player.health <= 0 or
            (player.sneaking == shift and player.sprinting == sprinting)) continue;
        player.sneaking = shift;
        player.sprinting = sprinting;
        outputs.player_flags_changed(@as(u16, @intCast(slot)));
    }
}

fn applyMovements(players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.movements[slot];
        if (pending.dirty and players.records[slot].state == .play) {
            if (applyPendingMovement(players, inputs, @intCast(slot))) |previous| {
                outputs.player_moved(.{ .slot = @as(u16, @intCast(slot)), .previous = previous });
            }
        }
    }
}

fn applyArmSwings(players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.arm_swings[slot];
        if (!pending.active) {
            @branchHint(.likely);
            continue;
        }
        const hand = pending.hand;
        pending.* = .{};
        if (players.records[slot].state == .play and players.records[slot].health > 0)
            outputs.arm_swing(.{ .slot = @as(u16, @intCast(slot)), .hand = hand });
    }
}

fn resetPlayerAfterRespawn(clock: *world_clock.Clock, worlds: *world_store.Worlds, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, slot: usize) void {
    const player = &players.records[slot];
    const world = worlds.get(player.world) orelse
        diagnostics.panic("player respawn requested in an unknown world (player slot)", &.{diagnostics.integer(slot)});
    blocks.ensureChunkAt(player.world, world.spawn_x, world.spawn_z, clock.tick);
    players.teleport(@intCast(slot), player.world, .{
        .x = @as(f64, @floatFromInt(world.spawn_x)) + 0.5,
        .y = @floatFromInt(world.spawn_y),
        .z = @as(f64, @floatFromInt(world.spawn_z)) + 0.5,
    }, .{});
    player.sneaking = false;
    player.sprinting = false;
    player.health = 20;
    player.food = 20;
    player.saturation = 5;
    player.exhaustion = 0;
    player.last_damage_taken = 0;
    player.time_until_regen = 0;
    player.food_tick_timer = 0;
    player.last_attacked_ticks = 0;
    player.last_attack_item_id = 0;
    inputs.movements[slot] = .{};
    inputs.player_inputs[slot] = .{};
    inputs.sprint_actions[slot] = .{};
    inputs.dig_actions[slot] = .none;
    inputs.item_drops[slot] = .{};
    inputs.living_attacks[slot] = .{};
    inputs.player_attacks[slot] = .{};
    inputs.living_interactions[slot] = .{};
    inputs.arm_swings[slot] = .{};
}

fn applyRespawns(clock: *world_clock.Clock, worlds: *world_store.Worlds, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.respawns[slot];
        if (!pending.*) {
            @branchHint(.likely);
            continue;
        }
        pending.* = false;
        const player = &players.records[slot];
        if (player.state != .play or player.health > 0) continue;
        resetPlayerAfterRespawn(clock, worlds, blocks, players, inputs, slot);
        outputs.player_respawned(@as(u16, @intCast(slot)));
    }
}

pub const PlayerInput = struct {
    pub const id = "minecraft:player_input";

    clock: *world_clock.Clock,
    worlds: *world_store.Worlds,
    blocks: *block_store.Blocks,
    players: *player_store.Players,
    inputs: *input_store.Inputs,
    outputs: *Packets,

    pub fn create(allocator: std.mem.Allocator, clock: *world_clock.Clock, worlds: *world_store.Worlds, blocks: *block_store.Blocks, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) !*PlayerInput {
        const self = try allocator.create(PlayerInput);
        self.* = .{ .clock = clock, .worlds = worlds, .blocks = blocks, .players = players, .inputs = inputs, .outputs = outputs };
        return self;
    }

    pub fn tick(self: *PlayerInput, _: std.mem.Allocator) void {
        applyPlayerFlags(self.players, self.inputs, self.outputs);
        applyMovements(self.players, self.inputs, self.outputs);
        applyArmSwings(self.players, self.inputs, self.outputs);
        applyRespawns(self.clock, self.worlds, self.blocks, self.players, self.inputs, self.outputs);
    }
};

test "respawn uses the current world's configured spawn" {
    const simulation = try std.testing.allocator.create(test_state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 51);
    defer simulation.deinit();

    const destination = simulation.worlds.find(.{ .value = 2 }).?;
    const world = simulation.worlds.get(destination).?;
    world.spawn_x = 24;
    world.spawn_y = 91;
    world.spawn_z = -12;
    const player = &simulation.players.records[0];
    player.world = destination;
    player.health = 0;

    resetPlayerAfterRespawn(
        &simulation.clock,
        &simulation.worlds,
        &simulation.blocks,
        &simulation.players,
        &simulation.inputs,
        0,
    );
    try std.testing.expect(player.world.eql(destination));
    try std.testing.expectEqual(@as(f64, 24.5), player.position.x);
    try std.testing.expectEqual(@as(f64, 91), player.position.y);
    try std.testing.expectEqual(@as(f64, -11.5), player.position.z);
    try std.testing.expectEqual(@as(f32, 20), player.health);
}
