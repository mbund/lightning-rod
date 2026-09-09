const lightning_rod = @import("lightning_rod");
const entity_store = lightning_rod.entities;
const living_entities = lightning_rod.living_entities;
const player_store = lightning_rod.players;
const block_store = lightning_rod.blocks;
const block_queries = lightning_rod.block_queries;
const geometry = lightning_rod.geometry;
const world_clock = lightning_rod.clock;
const std = @import("std");
const registry = lightning_rod.registry_data;
const collision = lightning_rod.collision;
const vanilla_zombie_ai = @import("vanilla_zombie_ai.zig");
const diagnostics = lightning_rod.diagnostics;
const active_chunks = @import("../vanilla/active_chunks.zig");
const vanilla_living_death = @import("vanilla_living_death.zig");
const Packets = lightning_rod.Packets;

pub const LivingEntityTick = struct {
    pub const id = "minecraft:living_entity_tick";
    pub const Configuration = struct {};
    pub const Dependencies = struct {
        deaths: *vanilla_living_death.LivingDeaths,
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        active: *active_chunks.ActiveChunks,
        living: *entity_store.LivingEntities,
        outputs: *Packets,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, _: Configuration) !*LivingEntityTick {
        const self = try allocator.create(LivingEntityTick);
        self.* = .{ .deps = deps };
        return self;
    }

    fn livingDistanceSquaredToPlayer(pool: *const living_entities.Pool, index: usize, player: *const player_store.CorePlayer) f64 {
        const dx = pool.position_x[index] - player.position.x;
        const dy = pool.position_y[index] - player.position.y;
        const dz = pool.position_z[index] - player.position.z;
        return dx * dx + dy * dy + dz * dz;
    }

    fn runLivingEntities(
        self: *LivingEntityTick,
        clock: *world_clock.Clock,
        blocks: *block_store.Blocks,
        players: *player_store.Players,
        entities: *entity_store.LivingEntities,
        deaths: *vanilla_living_death.LivingDeaths,
        outputs: *Packets,
    ) void {
        const living = &entities.entities;
        const paths = &entities.paths;
        var active_position: usize = 0;
        for (0..living.active_indices.len) |_| {
            if (active_position >= living.active_count) break;
            const living_index = living.active_indices[active_position];
            const index: usize = living_index;
            if (!isEntityTicking(blocks, self.deps.active, entities, index)) {
                paths.clear(index);
                living.jump_requested[index] = false;
                active_position += 1;
                continue;
            }
            tickBurning(entities, deaths, outputs, living_index);
            if (reapDead(clock, entities, outputs, living_index) or despawn(clock, players, entities, outputs, living_index)) {
                continue;
            }
            const previous = moveLiving(blocks, living, index);
            emitLiving(entities, outputs, living_index, previous);
            active_position += 1;
        }
        if (active_position != living.active_count)
            diagnostics.panic("living entity tick exceeded the entity capacity", &.{});
    }

    fn isEntityTicking(blocks: *const block_store.Blocks, active: *const active_chunks.ActiveChunks, entities: *const entity_store.LivingEntities, index: usize) bool {
        const living = &entities.entities;
        const chunk = geometry.ChunkPos{
            .x = @divFloor(geometry.blockCoord(living.position_x[index]), 16),
            .z = @divFloor(geometry.blockCoord(living.position_z[index]), 16),
        };
        return blocks.residentChunk(living.worlds[index], chunk) != null and
            active.entityTicking(living.worlds[index], chunk);
    }

    fn tickBurning(entities: *entity_store.LivingEntities, deaths: *vanilla_living_death.LivingDeaths, outputs: *Packets, living_index: u16) void {
        const living = &entities.entities;
        const index: usize = living_index;
        if (living.time_until_regen[index] > 0) living.time_until_regen[index] -= 1;
        if (living.fire_ticks[index] == 0 or living.dead[index]) return;
        living.fire_ticks[index] -= 1;
        if (@mod(living.fire_ticks[index], 20) == 0) {
            living.health[index] = @max(0, living.health[index] - 1);
            living.last_damage_taken[index] = 1;
            living.time_until_regen[index] = 10;
            outputs.living_burned(living_index);
            living.metadata_dirty[index] = true;
            if (living.health[index] <= 0) _ = deaths.kill(entities, living_index, .fire, null);
        }
        if (living.fire_ticks[index] == 0) living.metadata_dirty[index] = true;
    }

    fn reapDead(clock: *const world_clock.Clock, entities: *entity_store.LivingEntities, outputs: *Packets, living_index: u16) bool {
        const living = &entities.entities;
        const index: usize = living_index;
        if (!living.dead[index]) return false;
        living.death_time[index] +|= 1;
        if (living.death_time[index] < 20) return false;
        removeLiving(clock, entities, outputs, living_index, "living entity tick failed to remove dead entity (index, generation, tick)");
        return true;
    }

    fn despawn(clock: *const world_clock.Clock, players: *const player_store.Players, entities: *entity_store.LivingEntities, outputs: *Packets, living_index: u16) bool {
        const living = &entities.entities;
        const index: usize = living_index;
        if (living.persistent[index] or !living_entities.canDespawn(living.entity_types[index])) {
            living.despawn_counter[index] = 0;
            return false;
        }
        var closest = std.math.inf(f64);
        for (players.activeSlots()) |slot| {
            const player = &players.records[slot];
            if (player.gamemode != .spectator)
                closest = @min(closest, livingDistanceSquaredToPlayer(living, index, player));
        }
        if (closest == std.math.inf(f64)) return false;
        const random_despawn = living.despawn_counter[index] > 600 and
            closest > 32 * 32 and living.random[index].nextIntBounded(800) == 0;
        if (closest < 32 * 32) living.despawn_counter[index] = 0;
        if (closest <= 128 * 128 and !random_despawn) return false;
        removeLiving(clock, entities, outputs, living_index, "living entity tick failed to despawn entity (index, generation, tick)");
        return true;
    }

    fn removeLiving(clock: *const world_clock.Clock, entities: *entity_store.LivingEntities, outputs: *Packets, living_index: u16, message: []const u8) void {
        const living = &entities.entities;
        const index: usize = living_index;
        const entity_id = living.entity_ids[index];
        const handle = living_entities.Handle{ .index = living_index, .generation = living.generations[index] };
        entities.paths.clear(index);
        if (!living.remove(handle)) diagnostics.panic(message, &.{
            diagnostics.integer(living_index),
            diagnostics.integer(handle.generation),
            diagnostics.integer(clock.tick),
        });
        outputs.living_destroyed(.{ .index = living_index, .entity_id = entity_id });
    }

    const PreviousPosition = struct { x: f64, y: f64, z: f64 };

    fn moveLiving(block_world: *block_store.Blocks, living: *living_entities.Pool, index: usize) PreviousPosition {
        const previous = PreviousPosition{ .x = living.position_x[index], .y = living.position_y[index], .z = living.position_z[index] };
        tickHandSwing(living, index);
        clampVelocity(living, index);
        const in_water = block_store.isWaterBlockState(block_world.blockAtIfResident(living.worlds[index], .{
            .x = geometry.blockCoord(living.position_x[index]),
            .y = @intFromFloat(@floor(living.position_y[index] + 0.2)),
            .z = geometry.blockCoord(living.position_z[index]),
        }) orelse registry.block_air_default_state);
        applyVerticalAcceleration(living, index, in_water);
        const box = collision.entityBox(
            living.position_x[index],
            living.position_y[index],
            living.position_z[index],
            living_entities.width(living.entity_types[index], living.baby[index]),
            living_entities.height(living.entity_types[index], living.baby[index]),
        );
        const requested = collision.Movement{ .x = living.velocity_x[index], .y = living.velocity_y[index], .z = living.velocity_z[index] };
        applyMovement(living, index, requested, block_queries.adjustLivingMovement(block_world, living.worlds[index], box, requested), in_water);
        return previous;
    }

    fn tickHandSwing(living: *living_entities.Pool, index: usize) void {
        if (!living.hand_swinging[index]) return;
        living.hand_swing_ticks[index] += 1;
        if (living.hand_swing_ticks[index] < 6) return;
        living.hand_swinging[index] = false;
        living.hand_swing_ticks[index] = 0;
    }

    fn clampVelocity(living: *living_entities.Pool, index: usize) void {
        if (@abs(living.velocity_x[index]) < 0.003) living.velocity_x[index] = 0;
        if (@abs(living.velocity_y[index]) < 0.003) living.velocity_y[index] = 0;
        if (@abs(living.velocity_z[index]) < 0.003) living.velocity_z[index] = 0;
    }

    fn applyVerticalAcceleration(living: *living_entities.Pool, index: usize, in_water: bool) void {
        const jump = living.jump_requested[index];
        living.jump_requested[index] = false;
        if (living.on_ground[index] and living.velocity_y[index] < 0) living.velocity_y[index] = 0;
        if (jump and in_water) living.velocity_y[index] += 0.04 else if (jump and living.on_ground[index])
            living.velocity_y[index] = @max(living.velocity_y[index], @as(f64, @floatCast(@as(f32, 0.42))))
        else if (in_water) living.velocity_y[index] -= 0.005 else living.velocity_y[index] -= 0.08;
    }

    fn applyMovement(living: *living_entities.Pool, index: usize, requested: collision.Movement, adjusted: collision.Movement, in_water: bool) void {
        living.position_x[index] += adjusted.x;
        living.position_y[index] += adjusted.y;
        living.position_z[index] += adjusted.z;
        living.on_ground[index] = requested.y != adjusted.y and requested.y < 0;
        if (requested.x != adjusted.x) living.velocity_x[index] = 0;
        if (requested.z != adjusted.z) living.velocity_z[index] = 0;
        const horizontal_drag: f64 = if (in_water) 0.8 else if (living.on_ground[index])
            @floatCast(@as(f32, 0.6) * @as(f32, 0.91))
        else
            @floatCast(@as(f32, 0.91));
        living.velocity_x[index] *= horizontal_drag;
        living.velocity_y[index] *= if (in_water) 0.8 else @floatCast(@as(f32, 0.98));
        living.velocity_z[index] *= horizontal_drag;
    }

    fn emitLiving(entities: *entity_store.LivingEntities, outputs: *Packets, living_index: u16, previous: PreviousPosition) void {
        const living = &entities.entities;
        const index: usize = living_index;
        living.despawn_counter[index] +%= 1;
        living.age[index] +%= 1;
        if (living.position_x[index] != previous.x or living.position_y[index] != previous.y or
            living.position_z[index] != previous.z or living.pose_dirty[index])
            outputs.living_moved(living_index);
        if (living.metadata_dirty[index]) outputs.living_metadata_changed(living_index);
        living.pose_dirty[index] = false;
        living.metadata_dirty[index] = false;
    }

    pub fn tick(self: *LivingEntityTick, _: std.mem.Allocator) void {
        self.runLivingEntities(self.deps.clock, self.deps.blocks, self.deps.players, self.deps.living, self.deps.deaths, self.deps.outputs);
    }
};
