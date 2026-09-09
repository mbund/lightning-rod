const lightning_rod = @import("lightning_rod");
const input_store = lightning_rod.inputs;
const player_store = lightning_rod.players;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const world_store = lightning_rod.worlds;
const std = @import("std");
const Packets = lightning_rod.Packets;
const registry = lightning_rod.registry_data;
const collision = lightning_rod.collision;
const diagnostics = lightning_rod.diagnostics;
const test_state = lightning_rod.test_support.state;
const vanilla_collision_projection = @import("vanilla_collision_projection.zig");
const vanilla_persistence = @import("vanilla_persistence.zig");

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
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        collision_projection: *vanilla_collision_projection.CollisionProjection,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    };

    airborne_origin_y: []f64 = &.{},
    airborne_ticks: []u16 = &.{},
    floating_ticks: []u16 = &.{},
    initialized: []bool = &.{},
    player_session_generation: []u64 = &.{},
    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*MovementValidation {
        const self = try allocator.create(MovementValidation);
        self.* = .{ .deps = deps };
        const connections = deps.players.records.len;
        self.airborne_origin_y = try allocator.alloc(f64, connections);
        self.airborne_ticks = try allocator.alloc(u16, connections);
        self.floating_ticks = try allocator.alloc(u16, connections);
        self.initialized = try allocator.alloc(bool, connections);
        self.player_session_generation = try allocator.alloc(u64, connections);
        @memset(self.airborne_origin_y, 0);
        @memset(self.airborne_ticks, 0);
        @memset(self.floating_ticks, 0);
        @memset(self.initialized, false);
        @memset(self.player_session_generation, 0);
        return self;
    }

    pub fn tick(self: *MovementValidation, _: std.mem.Allocator) void {
        const projection = self.deps.collision_projection;
        const players = self.deps.players;
        const inputs = self.deps.inputs;
        const outputs = self.deps.outputs;
        for (players.activeSlots()) |slot| {
            beginPlayerSession(self, players, slot);
            const pending = &inputs.movements[slot];
            const player = &players.records[slot];
            if (!pending.dirty or !pending.has_position or player.gamemode == .creative or player.gamemode == .spectator) continue;
            if (movementIsValid(projection, players, inputs, self, slot)) continue;
            pending.* = .{};
            self.airborne_ticks[slot] = 0;
            self.floating_ticks[slot] = 0;
            self.initialized[slot] = false;
            _ = outputs.emitPlayerCorrection(slot);
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

fn movementIsValid(projection: *vanilla_collision_projection.CollisionProjection, players: *player_store.Players, inputs: *input_store.Inputs, state: *MovementValidation, slot: usize) bool {
    const pending = &inputs.movements[slot];
    const player = &players.records[slot];
    const candidate = pending.position;
    const dx = candidate.x - player.position.x;
    const dy = candidate.y - player.position.y;
    const dz = candidate.z - player.position.z;
    if (!std.math.isFinite(candidate.x) or !std.math.isFinite(candidate.y) or
        !std.math.isFinite(candidate.z) or dx * dx + dy * dy + dz * dz > 100 * 100) return false;
    const source = projection.source();
    if (block_queries.livingBoxCollidesFrom(source, player.world, playerCollisionBox(candidate))) return false;
    const previous_supported = block_queries.playerGroundSupportedFrom(source, player.world, player.position);
    const candidate_supported = block_queries.playerGroundSupportedFrom(source, player.world, candidate);
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
        outputs.emitPlayerState(@as(u16, @intCast(slot)));
    }
}

fn applyMovements(players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.movements[slot];
        if (pending.dirty and players.records[slot].state == .play) {
            if (applyPendingMovement(players, inputs, @intCast(slot))) |previous| {
                outputs.emitPlayerPosition(@as(u16, @intCast(slot)), previous);
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
            outputs.emitArmSwing(@as(u16, @intCast(slot)), hand);
    }
}

fn resetPlayerAfterRespawn(worlds: *world_store.Worlds, players: *player_store.Players, inputs: *input_store.Inputs, slot: usize) void {
    const player = &players.records[slot];
    const world = worlds.get(player.world) orelse
        diagnostics.panic("player respawn requested in an unknown world (player slot)", &.{diagnostics.integer(slot)});
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
    inputs.clearDigActions(@intCast(slot));
    inputs.item_drops[slot] = .{};
    inputs.living_attacks[slot] = .{};
    inputs.player_attacks[slot] = .{};
    inputs.living_interactions[slot] = .{};
    inputs.arm_swings[slot] = .{};
}

fn applyRespawns(worlds: *world_store.Worlds, materialization: *vanilla_persistence.Materializer, players: *player_store.Players, inputs: *input_store.Inputs, outputs: *Packets) void {
    for (players.activeSlots()) |active_slot| {
        const slot: usize = active_slot;
        const pending = &inputs.respawns[slot];
        if (!pending.*) {
            @branchHint(.likely);
            continue;
        }
        const player = &players.records[slot];
        if (player.state != .play or player.health > 0) {
            pending.* = false;
            continue;
        }
        const world = worlds.get(player.world) orelse continue;
        if (materialization.requestProjection(player.world, geometry.chunkForBlock(.{ .x = world.spawn_x, .y = world.spawn_y, .z = world.spawn_z })) != .resident) continue;
        pending.* = false;
        resetPlayerAfterRespawn(worlds, players, inputs, slot);
        outputs.emitRespawn(@as(u16, @intCast(slot)));
    }
}

pub const PlayerInput = struct {
    pub const id = "minecraft:player_input";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        worlds: *world_store.Worlds,
        materialization: *vanilla_persistence.Materializer,
        players: *player_store.Players,
        inputs: *input_store.Inputs,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayerInput {
        const self = try allocator.create(PlayerInput);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayerInput, _: std.mem.Allocator) void {
        applyPlayerFlags(self.deps.players, self.deps.inputs, self.deps.outputs);
        applyMovements(self.deps.players, self.deps.inputs, self.deps.outputs);
        applyArmSwings(self.deps.players, self.deps.inputs, self.deps.outputs);
        applyRespawns(self.deps.worlds, self.deps.materialization, self.deps.players, self.deps.inputs, self.deps.outputs);
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
    simulation.blocks.ensureChunkAt(destination, world.spawn_x, world.spawn_z, simulation.clock.tick);

    resetPlayerAfterRespawn(
        simulation.worlds,
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
