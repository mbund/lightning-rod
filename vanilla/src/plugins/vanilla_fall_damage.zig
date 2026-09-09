const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const world_identity = lightning_rod.world_identity;
const world_limits = lightning_rod.world_limits;
const std = @import("std");
const registry = lightning_rod.registry_data;
const active_chunks = @import("../vanilla/active_chunks.zig");
const vanilla_living_death = @import("vanilla_living_death.zig");
const Packets = lightning_rod.Packets;

const safe_fall_distance: f64 = 3;

const FallTrack = struct {
    world: world_identity.Handle = world_identity.invalid,
    last_y: f64 = 0,
    distance: f64 = 0,
    generation: u64 = 0,
    teleport_epoch: u64 = 0,
    initialized: bool = false,
    grounded: bool = false,
};

pub const FallTracking = struct {
    pub const id = "lightning_rod:fall_tracking";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *player_store.Players, living: *entity_store.LivingEntities };

    deps: Dependencies,
    players: []FallTrack = &.{},
    living: []FallTrack = &.{},

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*FallTracking {
        const self = try allocator.create(FallTracking);
        self.* = .{ .deps = deps };
        self.players = try allocator.alloc(FallTrack, deps.players.records.len);
        self.living = try allocator.alloc(FallTrack, deps.living.entities.active.len);
        @memset(self.players, .{});
        @memset(self.living, .{});
        return self;
    }

    fn applyPlayer(self: *FallTracking, blocks: *block_store.Blocks, players: *player_store.Players, outputs: *Packets) void {
        for (players.activeSlots()) |slot| {
            const player = &players.records[slot];
            const track = &self.players[slot];
            if (player.state != .play or player.health <= 0 or player.gamemode == .creative or player.gamemode == .spectator) {
                track.* = .{};
                continue;
            }
            const grounded = block_queries.playerGroundSupported(blocks, player.world, player.position);
            if (isInFluid(blocks, player.world, player.position)) {
                track.* = .{ .world = player.world, .last_y = player.position.y, .generation = players.session_generations[slot], .teleport_epoch = player.teleport_epoch, .initialized = true, .grounded = grounded };
                continue;
            }
            const distance = landedDistance(track, players.session_generations[slot], player.teleport_epoch, player.world, player.position.y, grounded) orelse continue;
            const damage = acceptedDamage(damageForDistance(distance), &player.last_damage_taken, &player.time_until_regen);
            if (damage <= 0) continue;
            player.health = @max(0, player.health - damage);
            outputs.player_fell(.{ .slot = slot, .fatal = player.health == 0 });
        }
    }

    fn applyLiving(self: *FallTracking, deaths: *vanilla_living_death.LivingDeaths, blocks: *block_store.Blocks, active: *active_chunks.ActiveChunks, living: *entity_store.LivingEntities, outputs: *Packets) void {
        const entities = &living.entities;
        for (entities.active_indices[0..entities.active_count]) |index| {
            const track = &self.living[index];
            const generation: u64 = entities.generations[index];
            if (entities.dead[index] or entities.health[index] <= 0) {
                track.* = .{};
                continue;
            }
            if (!livingFallTicks(blocks, active, entities, index)) continue;
            const position = geometry.Vec3{ .x = entities.position_x[index], .y = entities.position_y[index], .z = entities.position_z[index] };
            if (isInFluid(blocks, entities.worlds[index], position)) {
                track.* = .{ .world = entities.worlds[index], .last_y = position.y, .generation = generation, .initialized = true, .grounded = entities.on_ground[index] };
                continue;
            }
            const distance = landedDistance(track, generation, 0, entities.worlds[index], position.y, entities.on_ground[index]) orelse continue;
            const damage = acceptedDamage(damageForDistance(distance), &entities.last_damage_taken[index], &entities.time_until_regen[index]);
            if (damage <= 0) continue;
            entities.health[index] = @max(0, entities.health[index] - damage);
            outputs.living_fell(index);
            outputs.living_metadata_changed(index);
            if (entities.health[index] == 0) _ = deaths.kill(living, index, .fall, null);
        }
    }

    fn primeLiving(self: *FallTracking, living: *const entity_store.LivingEntities) void {
        const entities = &living.entities;
        for (entities.active_indices[0..entities.active_count]) |index| {
            const track = &self.living[index];
            const generation: u64 = entities.generations[index];
            if (track.initialized and track.generation == generation) continue;
            track.* = .{ .world = entities.worlds[index], .last_y = entities.position_y[index], .generation = generation, .initialized = true, .grounded = entities.on_ground[index] };
        }
    }
};

fn landedDistance(track: *FallTrack, generation: u64, teleport_epoch: u64, world: world_identity.Handle, y: f64, grounded: bool) ?f64 {
    if (!track.initialized or track.generation != generation or
        track.teleport_epoch != teleport_epoch or !track.world.eql(world))
    {
        track.* = .{
            .world = world,
            .last_y = y,
            .generation = generation,
            .teleport_epoch = teleport_epoch,
            .initialized = true,
            .grounded = grounded,
        };
        return null;
    }

    const descent = @max(0, track.last_y - y);
    var landed: ?f64 = null;
    if (grounded) {
        if (!track.grounded) {
            track.distance += descent;
            landed = track.distance;
        }
        track.distance = 0;
    } else {
        track.distance += descent;
    }
    track.last_y = y;
    track.grounded = grounded;
    return landed;
}

fn damageForDistance(distance: f64) f32 {
    const damage: i32 = @intFromFloat(@floor(distance + 0.000001 - safe_fall_distance));
    return @floatFromInt(@max(0, damage));
}

fn acceptedDamage(raw_damage: f32, last_damage: *f32, time_until_regen: *i32) f32 {
    var damage = raw_damage;
    if (time_until_regen.* > 10) {
        if (raw_damage <= last_damage.*) return 0;
        damage -= last_damage.*;
    } else {
        time_until_regen.* = 20;
    }
    last_damage.* = raw_damage;
    return damage;
}

fn isInFluid(blocks: *block_store.Blocks, world: world_identity.Handle, position: geometry.Vec3) bool {
    const y = std.math.clamp(geometry.blockCoord(position.y), @as(i32, world_limits.min_y), @as(i32, block_store.world_top_y));
    const state = blocks.blockAtIfResident(world, .{
        .x = geometry.blockCoord(position.x),
        .y = @intCast(y),
        .z = geometry.blockCoord(position.z),
    }) orelse return false;
    return (state >= registry.state_water_level_0 and state <= registry.state_water_level_15) or
        (state >= registry.state_lava_level_0 and state <= registry.state_lava_level_15);
}

fn livingFallTicks(blocks: *const block_store.Blocks, active: *const active_chunks.ActiveChunks, entities: *const living_entities.Pool, index: u16) bool {
    const chunk = geometry.ChunkPos{
        .x = @divFloor(geometry.blockCoord(entities.position_x[index]), 16),
        .z = @divFloor(geometry.blockCoord(entities.position_z[index]), 16),
    };
    return blocks.residentChunk(entities.worlds[index], chunk) != null and
        active.entityTicking(entities.worlds[index], chunk);
}

pub const PlayerFallDamage = struct {
    pub const id = "minecraft:player_fall_damage";
    pub const Configuration = struct {};
    pub const Dependencies = struct { tracking: *FallTracking, blocks: *block_store.Blocks, players: *player_store.Players, outputs: *Packets };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PlayerFallDamage {
        const self = try allocator.create(PlayerFallDamage);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PlayerFallDamage, _: std.mem.Allocator) void {
        self.deps.tracking.applyPlayer(self.deps.blocks, self.deps.players, self.deps.outputs);
    }
};

pub const PrimeLivingFalls = struct {
    pub const id = "lightning_rod:prime_living_falls";
    pub const Configuration = struct {};
    pub const Dependencies = struct { tracking: *FallTracking, living: *entity_store.LivingEntities };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*PrimeLivingFalls {
        const self = try allocator.create(PrimeLivingFalls);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *PrimeLivingFalls, _: std.mem.Allocator) void {
        self.deps.tracking.primeLiving(self.deps.living);
    }
};

pub const LivingFallDamage = struct {
    pub const id = "minecraft:living_fall_damage";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        tracking: *FallTracking,
        deaths: *vanilla_living_death.LivingDeaths,
        blocks: *block_store.Blocks,
        active: *active_chunks.ActiveChunks,
        living: *entity_store.LivingEntities,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingFallDamage {
        const self = try allocator.create(LivingFallDamage);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *LivingFallDamage, _: std.mem.Allocator) void {
        self.deps.tracking.applyLiving(self.deps.deaths, self.deps.blocks, self.deps.active, self.deps.living, self.deps.outputs);
    }
};

test "fall damage starts after three blocks" {
    try std.testing.expectEqual(@as(f32, 0), damageForDistance(3));
    try std.testing.expectEqual(@as(f32, 0), damageForDistance(3.01));
    try std.testing.expectEqual(@as(f32, 0), damageForDistance(3.99));
    try std.testing.expectEqual(@as(f32, 1), damageForDistance(4));
    try std.testing.expectEqual(@as(f32, 2), damageForDistance(5));
}

test "jumping from a two block ledge does not deal fall damage" {
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    var track = FallTrack{};
    try std.testing.expectEqual(@as(?f64, null), landedDistance(&track, 1, 0, world, 64, true));
    try std.testing.expectEqual(@as(?f64, null), landedDistance(&track, 1, 0, world, 65.25, false));
    const distance = landedDistance(&track, 1, 0, world, 62, true) orelse return error.ExpectedLanding;
    try std.testing.expectApproxEqAbs(@as(f64, 3.25), distance, 0.000001);
    try std.testing.expectEqual(@as(f32, 0), damageForDistance(distance));
}

test "changing worlds clears accumulated fall distance" {
    const source = world_identity.Handle{ .index = 0, .generation = 1 };
    const destination = world_identity.Handle{ .index = 1, .generation = 1 };
    var track = FallTrack{};
    try std.testing.expect(landedDistance(&track, 1, 0, source, 90, false) == null);
    try std.testing.expect(landedDistance(&track, 1, 0, source, 70, false) == null);
    try std.testing.expect(landedDistance(&track, 1, 0, destination, 80, false) == null);
    const distance = landedDistance(&track, 1, 0, destination, 79, true) orelse return error.ExpectedLanding;
    try std.testing.expectEqual(@as(f64, 1), distance);
}

test "teleporting within one world clears accumulated fall distance" {
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    var track = FallTrack{};
    try std.testing.expect(landedDistance(&track, 1, 1, world, 90, false) == null);
    try std.testing.expect(landedDistance(&track, 1, 1, world, 70, false) == null);
    try std.testing.expect(landedDistance(&track, 1, 2, world, 80, false) == null);
    const distance = landedDistance(&track, 1, 2, world, 79, true) orelse return error.ExpectedLanding;
    try std.testing.expectEqual(@as(f64, 1), distance);
}
