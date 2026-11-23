//! One mob's tick in vanilla's order: ServerLevel.tickNonPassenger with Mob.checkDespawn before
//! it, then Mob.tick, which runs LivingEntity.tick (base tick, AI step, travel, block effects,
//! pushing) and turns the body.
//!
//! A resting mob (Mob.resting) skips the parts that only read blocks and neighbours: fluids and
//! eyes, the wall check, travel, block effects and pushing. Each would find what it found last
//! tick, so skipping changes nothing, and in Debug every skip runs the full part on a copy and
//! asserts the copy comes out the same. Random draws, goals, timers and turning always run.

const std = @import("std");
const builtin = @import("builtin");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const ai = @import("ai.zig");
const effects = @import("block_effects.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const assert = std.debug.assert;

/// Debug builds check every skip against the work it skips.
const verify_rest = builtin.mode == .debug;

/// What this tick found that keeps a mob from resting.
const Findings = struct {
    in_wall: bool = false,
    blocks_acted: bool = false,
    touched: u32 = 0,
};

pub fn tick(mobs: *Mobs, mob: Mob) !void {
    checkDespawn(mobs, mob);
    mob.motion.old_position = mob.motion.position;
    mob.motion.old_yaw = mob.motion.yaw;
    mob.motion.old_pitch = mob.motion.pitch;
    mob.idle.tick_count += 1;
    var findings: Findings = .{};
    try baseTick(mobs, mob, &findings);
    if (!mob.entity.removed) try aiStep(mobs, mob, &findings);
    turnBody(mobs, mob);
    // Mob.tick: passengers decide the control flags, and mobs here carry none.
    if (@rem(mob.idle.tick_count, 5) == 0) mob.goals.disabled = 0;
    settle(mob, findings);
}

/// Whether the mob is where it rested, so what it read there still holds.
fn restsInPlace(mob: Mob) bool {
    return mob.motion.resting and std.meta.eql(mob.motion.position, mob.motion.rest_position);
}

/// Rests after a tick that left the mob standing still on the ground, moving only as gravity
/// pulls it into the floor, with nothing in or under it acting on it and no mob touching it.
fn settle(mob: Mob, findings: Findings) void {
    mob.motion.resting = !mob.entity.removed and mob.alive() and !findings.in_wall and !findings.blocks_acted and findings.touched == 0 and
        mob.motion.on_ground and !mob.motion.horizontal_collision and std.meta.eql(mob.motion.position, mob.motion.old_position) and
        mob.motion.velocity[0] == 0 and mob.motion.velocity[2] == 0 and mob.motion.fall_distance == 0 and
        !mob.entity.touching_water and mob.entity.lava_height == 0 and !mob.entity.eye_in_water and
        !mob.entity.in_powder_snow and !mob.entity.was_in_powder_snow and mob.entity.ticks_frozen == 0 and mob.entity.fire_ticks == 0 and
        std.meta.eql(mob.motion.stuck, [3]f64{ 0, 0, 0 }) and mob.living.last_climbable == null and mob.motion.movement_count == 0;
    if (!mob.motion.resting) return;
    mob.motion.rest_position = mob.motion.position;
    mob.motion.rest_velocity = mob.motion.velocity;
}

/// In Debug, the skipped part run on a copy must leave it as the skip leaves the mob.
fn checkSkip(mob: Mob, copy: Mob) void {
    if (!std.meta.eql(copy.state(), mob.state())) {
        std.debug.print("rest skip diverged for mob {d} at {any}\n", .{ mob.entity.id, mob.motion.position });
        unreachable;
    }
}

/// Mob.checkDespawn. Animals never despawn, but a mob no player is near stops counting as
/// recently active, and vanilla draws from its random while it waits to despawn.
fn checkDespawn(mobs: *Mobs, mob: Mob) void {
    if (mob.control.persistence_required) {
        mob.idle.no_action_time = 0;
        return;
    }
    const nearest = mobs.nearestPlayerDistanceSquared(mob.motion.world, mob.motion.position) orelse return;
    // MobCategory.CREATURE's distance within which mobs never despawn.
    const near = 32 * 32;
    if (mob.idle.no_action_time > 600 and mob.idle.random.nextIntBounded(800) == 0 and nearest > near) {
        // Animal.removeWhenFarAway is false.
    } else if (nearest < near) {
        mob.idle.no_action_time = 0;
    }
}

/// Entity.baseTick, LivingEntity.baseTick and Mob.baseTick.
fn baseTick(mobs: *Mobs, mob: Mob, findings: *Findings) !void {
    // Entity.baseTick.
    mob.entity.was_in_powder_snow = mob.entity.in_powder_snow;
    mob.entity.in_powder_snow = false;
    if (restsInPlace(mob)) {
        if (verify_rest) {
            var copy_state = mob.state();
            const copy = Mob.of(&copy_state);
            try living.updateFluids(mobs, copy);
            try living.updateEyes(mobs, copy);
            checkSkip(mob, copy);
        }
    } else {
        try living.updateFluids(mobs, mob);
        try living.updateEyes(mobs, mob);
    }
    if (mob.entity.fire_ticks > 0) {
        if (mobs.traits(mob.entity.species).fire_immune) {
            mob.entity.fire_ticks -= 4;
        } else {
            if (@rem(mob.entity.fire_ticks, 20) == 0 and !living.inLava(mob)) _ = try mobs.hurt(mob, .{ .type = .on_fire }, 1);
            mob.entity.fire_ticks -= 1;
        }
    }
    if (living.inLava(mob)) mob.motion.fall_distance *= 0.5;
    const world_bottom = mobs.level(mob.motion.world).minimum_y;
    if (mob.motion.position[1] < @as(f64, @floatFromInt(world_bottom - 64))) {
        // Entity.onBelowWorld discards the mob.
        mob.entity.removed = true;
        return;
    }
    mob.entity.first_tick = false;

    // LivingEntity.baseTick.
    if (mobs.traits(mob.entity.species).fire_immune) mob.entity.fire_ticks = 0;
    if (mob.alive()) {
        if (restsInPlace(mob)) {
            if (verify_rest) assert(!try inWall(mobs, mob));
        } else if (try inWall(mobs, mob)) {
            findings.in_wall = true;
            _ = try mobs.hurt(mob, .{ .type = .in_wall }, 1);
        }
        // The block at the eyes is only read for a mob whose eyes are in water.
        if (mob.entity.eye_in_water and !try bubbleAtEyes(mobs, mob)) {
            mob.living.air_supply = decreaseAir(mobs, mob, mob.living.air_supply);
            if (mob.living.air_supply == -20) {
                mob.living.air_supply = 0;
                mobs.entityEvent(mob, 67);
                _ = try mobs.hurt(mob, .{ .type = .drown }, 2);
            }
        } else if (mob.living.air_supply < 300) {
            mob.living.air_supply = @min(mob.living.air_supply + 4, 300);
        }
    }
    if (mob.living.hurt_time > 0) mob.living.hurt_time -= 1;
    if (mob.living.invulnerable_time > 0) mob.living.invulnerable_time -= 1;
    if (!mob.alive()) mobs.tickDeath(mob);
    if (mob.living.last_hurt_by_player_time > 0) mob.living.last_hurt_by_player_time -= 1;
    mob.idle.old_head_yaw = mob.idle.head_yaw;
    mob.idle.old_body_yaw = mob.idle.body_yaw;
    mob.motion.old_yaw = mob.motion.yaw;
    mob.motion.old_pitch = mob.motion.pitch;

    // Mob.baseTick.
    if (mob.alive()) {
        const roll = mob.idle.random.nextIntBounded(1000);
        const time = mob.idle.ambient_sound_time;
        mob.idle.ambient_sound_time += 1;
        if (roll < time) {
            mob.idle.ambient_sound_time = -mobs.traits(mob.entity.species).ambient_interval;
            mobs.ambientSound(mob);
        }
    }
}

fn bubbleAtEyes(mobs: *Mobs, mob: Mob) !bool {
    const level = mobs.level(mob.motion.world);
    const eye = living.eyeY(mobs, mob);
    return level.blocks.get(try level.state(mth.floor(mob.motion.position[0]), mth.floor(eye), mth.floor(mob.motion.position[2]))).kind == .bubble_column;
}

/// LivingEntity.decreaseAirSupply, with no oxygen bonus.
fn decreaseAir(mobs: *Mobs, mob: Mob, air: i32) i32 {
    const bonus = mobs.traits(mob.entity.species).attribute(.oxygen_bonus);
    if (bonus > 0 and mob.idle.random.nextDouble() >= 1.0 / (bonus + 1.0)) return air;
    return air - 1;
}

/// Entity.isInWall: a suffocating block's collision shape across the eyes.
fn inWall(mobs: *Mobs, mob: Mob) !bool {
    const level = mobs.level(mob.motion.world);
    const size: f64 = living.width(mobs, mob) * 0.8;
    const eye = living.eyeY(mobs, mob);
    const probe: @import("vanilla_bodies").body.Box = .{
        .min = .{ mob.motion.position[0] - size / 2, eye - 1.0e-6 / 2.0, mob.motion.position[2] - size / 2 },
        .max = .{ mob.motion.position[0] + size / 2, eye + 1.0e-6 / 2.0, mob.motion.position[2] + size / 2 },
    };
    var x = mth.floor(probe.min[0]);
    while (x <= mth.floor(probe.max[0])) : (x += 1) {
        var y = mth.floor(probe.min[1]);
        while (y <= mth.floor(probe.max[1])) : (y += 1) {
            var z = mth.floor(probe.min[2]);
            while (z <= mth.floor(probe.max[2])) : (z += 1) {
                const state = try level.state(x, y, z);
                const entry = level.blocks.get(state);
                if (entry.flags.air or !entry.flags.suffocating) continue;
                const boxes = game_data.physics.spawnCollision(state, x, 0, z);
                for (0..boxes.count) |index| {
                    const value = boxes.get(index);
                    const shape: @import("vanilla_bodies").body.Box = .{
                        .min = .{ @as(f64, @floatFromInt(x)) + value[0], @as(f64, @floatFromInt(y)) + value[1], @as(f64, @floatFromInt(z)) + value[2] },
                        .max = .{ @as(f64, @floatFromInt(x)) + value[3], @as(f64, @floatFromInt(y)) + value[4], @as(f64, @floatFromInt(z)) + value[5] },
                    };
                    if (shape.intersects(probe)) return true;
                }
            }
        }
    }
    return false;
}

/// LivingEntity.aiStep with Mob, AgeableMob and Animal's additions.
fn aiStep(mobs: *Mobs, mob: Mob, findings: *Findings) !void {
    if (mob.living.no_jump_delay > 0) mob.living.no_jump_delay -= 1;
    if (@abs(mob.motion.velocity[0]) < 0.003) mob.motion.velocity[0] = 0;
    if (@abs(mob.motion.velocity[1]) < 0.003) mob.motion.velocity[1] = 0;
    if (@abs(mob.motion.velocity[2]) < 0.003) mob.motion.velocity[2] = 0;
    // LivingEntity.applyInput.
    mob.living.strafe *= 0.98;
    mob.living.forward *= 0.98;
    if (!mob.alive()) {
        mob.living.jumping = false;
        mob.living.strafe = 0;
        mob.living.forward = 0;
    } else if (!mob.control.no_ai) {
        try ai.serverAiStep(mobs, mob);
    }
    if (mob.living.jumping) {
        const in_lava = living.inLava(mob);
        const fluid_height = if (in_lava) mob.entity.lava_height else mob.entity.water_height;
        const swimming = mob.entity.touching_water and fluid_height > 0;
        const threshold = living.fluidJumpThreshold(mobs, mob);
        if (swimming and !(mob.motion.on_ground and !(fluid_height > threshold))) {
            living.jumpInLiquid(mob);
        } else if (in_lava and !(mob.motion.on_ground and !(fluid_height > threshold))) {
            living.jumpInLiquid(mob);
        } else if ((mob.motion.on_ground or (swimming and fluid_height <= threshold)) and mob.living.no_jump_delay == 0) {
            try living.jumpFromGround(mobs, mob);
            mob.living.no_jump_delay = 10;
        }
    } else {
        mob.living.no_jump_delay = 0;
    }
    const input: [3]f32 = .{ mob.living.strafe, mob.living.vertical_input, mob.living.forward };
    if (!mob.control.no_ai) {
        // At rest with no input, travel pulls the mob into the floor and back as last tick.
        const still = std.meta.eql(input, [3]f32{ 0, 0, 0 }) and std.meta.eql(mob.motion.velocity, mob.motion.rest_velocity);
        if (restsInPlace(mob) and still) {
            mobs.travels_skipped += 1;
            if (verify_rest) {
                var copy_state = mob.state();
                const copy = Mob.of(&copy_state);
                try living.travel(mobs, copy, input);
                checkSkip(mob, copy);
            }
        } else {
            mobs.travels_run += 1;
            try living.travel(mobs, mob, input);
        }
    }
    // Blocks act on a mob that moved, or stands in or on one that acts.
    const unmoved = std.meta.eql(mob.motion.position, mob.motion.old_position) and mob.motion.movement_count == 0 and mob.entity.fire_ticks == 0 and mob.entity.ticks_frozen == 0;
    if (restsInPlace(mob) and unmoved) {
        if (verify_rest) {
            var copy_state = mob.state();
            const copy = Mob.of(&copy_state);
            assert(!try effects.applyEffectsFromBlocks(mobs, copy));
            checkSkip(mob, copy);
        }
    } else {
        findings.blocks_acted = try effects.applyEffectsFromBlocks(mobs, mob);
    }
    // Freezing: powder snow chills, and thaws two ticks at a time outside it.
    if (!mob.entity.in_powder_snow) mob.entity.ticks_frozen = @max(0, mob.entity.ticks_frozen - 2);
    // LivingEntity.removeFrost, then tryAddFrost over anything but air.
    mob.living.frost_speed = 0;
    if (mob.entity.ticks_frozen > 0) {
        const under = try living.onPosition(mobs, mob, 0.2);
        const level = mobs.level(mob.motion.world);
        if (!level.blocks.get(try level.state(under[0], under[1], under[2])).flags.air) {
            mob.living.frost_speed = -0.05 * (@as(f32, @floatFromInt(@min(140, mob.entity.ticks_frozen))) / 140.0);
        }
    }
    if (@rem(mob.idle.tick_count, 40) == 0 and mob.entity.ticks_frozen >= 140) _ = try mobs.hurt(mob, .{ .type = .freeze }, 1);
    // A mob coming into contact wakes a resting one, so one at rest touches nothing.
    if (restsInPlace(mob)) {
        if (verify_rest) {
            var copy_state = mob.state();
            const copy = Mob.of(&copy_state);
            assert(try mobs.pushEntities(copy) == 0);
            checkSkip(mob, copy);
        }
    } else {
        findings.touched = try mobs.pushEntities(mob);
    }

    // AgeableMob.aiStep.
    if (mob.alive()) {
        if (mob.idle.age < 0) {
            mobs.setAge(mob, mob.idle.age + 1);
        } else if (mob.idle.age > 0) {
            mobs.setAge(mob, mob.idle.age - 1);
        }
    }
    // Animal.aiStep.
    if (mob.idle.age != 0) mob.endLove();
    if (mob.part(.breeding)) |breeding| if (breeding.in_love > 0) {
        breeding.in_love -= 1;
        if (breeding.in_love == 0 and breeding.love_cause == null) mob.drop(.breeding);
        if (@rem(mob.inLove(), 10) == 0) {
            // A heart particle on the client, but the random draws happen on the server too.
            _ = mob.idle.random.nextGaussian();
            _ = mob.idle.random.nextGaussian();
            _ = mob.idle.random.nextGaussian();
            _ = mob.idle.random.nextDouble();
            _ = mob.idle.random.nextDouble();
            _ = mob.idle.random.nextDouble();
        }
    };
}

/// The end of LivingEntity.tick: the body faces where the mob walked, through
/// BodyRotationControl, which Mob.tickHeadTurn uses.
fn turnBody(mobs: *Mobs, mob: Mob) void {
    _ = mobs;
    const dx = mob.motion.position[0] - mob.motion.old_position[0];
    const dz = mob.motion.position[2] - mob.motion.old_position[2];
    if (dx * dx + dz * dz > @as(f64, @as(f32, 2.5000003e-7))) {
        mob.idle.body_yaw = mob.motion.yaw;
        mob.idle.head_yaw = mth.rotateIfNecessary(mob.idle.head_yaw, mob.idle.body_yaw, 75);
        mob.idle.last_stable_head_yaw = mob.idle.head_yaw;
        mob.idle.head_stable_time = 0;
        return;
    }
    var turn: Turn = .{ .body = mob.idle.body_yaw, .last_stable = mob.idle.last_stable_head_yaw, .stable_time = mob.idle.head_stable_time };
    turnStill(mob.idle.head_yaw, &turn);
    mob.idle.body_yaw = turn.body;
    mob.idle.last_stable_head_yaw = turn.last_stable;
    mob.idle.head_stable_time = turn.stable_time;
}

/// The body of a mob that did not move, as BodyRotationControl turns it toward the head.
pub const Turn = struct { body: f32, last_stable: f32, stable_time: i32 };

pub fn turnStill(head: f32, turn: *Turn) void {
    if (@abs(head - turn.last_stable) > 15) {
        turn.stable_time = 0;
        turn.last_stable = head;
        turn.body = mth.rotateIfNecessary(turn.body, head, 75);
    } else {
        turn.stable_time += 1;
        if (turn.stable_time > 10) {
            const fraction = mth.clamp(@as(f32, @floatFromInt(turn.stable_time - 10)) / 10.0, 0, 1);
            turn.body = mth.rotateIfNecessary(turn.body, head, 75 * (1 - fraction));
        }
    }
}
