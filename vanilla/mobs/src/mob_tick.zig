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
const mth = @import("mth.zig");
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

pub fn tick(mobs: *Mobs, mob: *Mob) !void {
    checkDespawn(mobs, mob);
    mob.old_position = mob.position;
    mob.old_yaw = mob.yaw;
    mob.old_pitch = mob.pitch;
    mob.tick_count += 1;
    var findings: Findings = .{};
    try baseTick(mobs, mob, &findings);
    if (!mob.removed) try aiStep(mobs, mob, &findings);
    turnBody(mobs, mob);
    // Mob.tick: passengers decide the control flags, and mobs here carry none.
    if (@rem(mob.tick_count, 5) == 0) mob.goals.disabled = 0;
    settle(mob, findings);
}

/// Whether the mob is where it rested, so what it read there still holds.
fn restsInPlace(mob: *const Mob) bool {
    return mob.resting and std.meta.eql(mob.position, mob.rest_position);
}

/// Rests after a tick that left the mob standing still on the ground, moving only as gravity
/// pulls it into the floor, with nothing in or under it acting on it and no mob touching it.
fn settle(mob: *Mob, findings: Findings) void {
    mob.resting = !mob.removed and mob.alive() and !findings.in_wall and !findings.blocks_acted and findings.touched == 0 and
        mob.on_ground and !mob.horizontal_collision and std.meta.eql(mob.position, mob.old_position) and
        mob.velocity[0] == 0 and mob.velocity[2] == 0 and mob.fall_distance == 0 and
        !mob.touching_water and mob.lava_height == 0 and !mob.eye_in_water and
        !mob.in_powder_snow and !mob.was_in_powder_snow and mob.ticks_frozen == 0 and mob.fire_ticks == 0 and
        std.meta.eql(mob.stuck, [3]f64{ 0, 0, 0 }) and mob.last_climbable == null and mob.movement_count == 0;
    if (!mob.resting) return;
    mob.rest_position = mob.position;
    mob.rest_velocity = mob.velocity;
}

/// In Debug, the skipped part run on a copy must leave it as the skip leaves the mob.
fn checkSkip(mob: *const Mob, copy: *const Mob) void {
    if (!std.meta.eql(copy.*, mob.*)) {
        std.debug.print("rest skip diverged for mob {d} at {any}\n", .{ mob.id, mob.position });
        unreachable;
    }
}

/// Mob.checkDespawn. Animals never despawn, but a mob no player is near stops counting as
/// recently active, and vanilla draws from its random while it waits to despawn.
fn checkDespawn(mobs: *Mobs, mob: *Mob) void {
    if (mob.persistence_required) {
        mob.no_action_time = 0;
        return;
    }
    const nearest = mobs.nearestPlayerDistanceSquared(mob.world, mob.position) orelse return;
    // MobCategory.CREATURE's distance within which mobs never despawn.
    const near = 32 * 32;
    if (mob.no_action_time > 600 and mob.random.nextIntBounded(800) == 0 and nearest > near) {
        // Animal.removeWhenFarAway is false.
    } else if (nearest < near) {
        mob.no_action_time = 0;
    }
}

/// Entity.baseTick, LivingEntity.baseTick and Mob.baseTick.
fn baseTick(mobs: *Mobs, mob: *Mob, findings: *Findings) !void {
    // Entity.baseTick.
    mob.was_in_powder_snow = mob.in_powder_snow;
    mob.in_powder_snow = false;
    if (restsInPlace(mob)) {
        if (verify_rest) {
            var copy = mob.*;
            try living.updateFluids(mobs, &copy);
            try living.updateEyes(mobs, &copy);
            checkSkip(mob, &copy);
        }
    } else {
        try living.updateFluids(mobs, mob);
        try living.updateEyes(mobs, mob);
    }
    if (mob.fire_ticks > 0) {
        if (mobs.traits(mob.species).fire_immune) {
            mob.fire_ticks -= 4;
        } else {
            if (@rem(mob.fire_ticks, 20) == 0 and !living.inLava(mob)) _ = try mobs.hurt(mob, .{ .type = .on_fire }, 1);
            mob.fire_ticks -= 1;
        }
    }
    if (living.inLava(mob)) mob.fall_distance *= 0.5;
    const world_bottom = mobs.level(mob.world).minimum_y;
    if (mob.position[1] < @as(f64, @floatFromInt(world_bottom - 64))) {
        // Entity.onBelowWorld discards the mob.
        mob.removed = true;
        return;
    }
    mob.first_tick = false;

    // LivingEntity.baseTick.
    if (mobs.traits(mob.species).fire_immune) mob.fire_ticks = 0;
    if (mob.alive()) {
        if (restsInPlace(mob)) {
            if (verify_rest) assert(!try inWall(mobs, mob));
        } else if (try inWall(mobs, mob)) {
            findings.in_wall = true;
            _ = try mobs.hurt(mob, .{ .type = .in_wall }, 1);
        }
        // The block at the eyes is only read for a mob whose eyes are in water.
        if (mob.eye_in_water and !try bubbleAtEyes(mobs, mob)) {
            mob.air_supply = decreaseAir(mobs, mob, mob.air_supply);
            if (mob.air_supply == -20) {
                mob.air_supply = 0;
                mobs.entityEvent(mob, 67);
                _ = try mobs.hurt(mob, .{ .type = .drown }, 2);
            }
        } else if (mob.air_supply < 300) {
            mob.air_supply = @min(mob.air_supply + 4, 300);
        }
    }
    if (mob.hurt_time > 0) mob.hurt_time -= 1;
    if (mob.invulnerable_time > 0) mob.invulnerable_time -= 1;
    if (!mob.alive()) mobs.tickDeath(mob);
    if (mob.last_hurt_by_player_time > 0) {
        mob.last_hurt_by_player_time -= 1;
    } else {
        mob.last_hurt_by_player = null;
    }
    if (mob.last_hurt_by_mob != null and mob.tick_count - mob.last_hurt_by_mob_timestamp > 100) mob.last_hurt_by_mob = null;
    mob.old_head_yaw = mob.head_yaw;
    mob.old_body_yaw = mob.body_yaw;
    mob.old_yaw = mob.yaw;
    mob.old_pitch = mob.pitch;

    // Mob.baseTick.
    if (mob.alive()) {
        const roll = mob.random.nextIntBounded(1000);
        const time = mob.ambient_sound_time;
        mob.ambient_sound_time += 1;
        if (roll < time) {
            mob.ambient_sound_time = -mobs.traits(mob.species).ambient_interval;
            mobs.ambientSound(mob);
        }
    }
}

fn bubbleAtEyes(mobs: *Mobs, mob: *const Mob) !bool {
    const level = mobs.level(mob.world);
    const eye = living.eyeY(mobs, mob);
    return level.blocks.get(try level.state(mth.floor(mob.position[0]), mth.floor(eye), mth.floor(mob.position[2]))).kind == .bubble_column;
}

/// LivingEntity.decreaseAirSupply, with no oxygen bonus.
fn decreaseAir(mobs: *Mobs, mob: *Mob, air: i32) i32 {
    const bonus = mobs.traits(mob.species).attribute(.oxygen_bonus);
    if (bonus > 0 and mob.random.nextDouble() >= 1.0 / (bonus + 1.0)) return air;
    return air - 1;
}

/// Entity.isInWall: a suffocating block's collision shape across the eyes.
fn inWall(mobs: *Mobs, mob: *const Mob) !bool {
    const level = mobs.level(mob.world);
    const size: f64 = living.width(mobs, mob) * 0.8;
    const eye = living.eyeY(mobs, mob);
    const probe: @import("body.zig").Box = .{
        .min = .{ mob.position[0] - size / 2, eye - 1.0e-6 / 2.0, mob.position[2] - size / 2 },
        .max = .{ mob.position[0] + size / 2, eye + 1.0e-6 / 2.0, mob.position[2] + size / 2 },
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
                    const shape: @import("body.zig").Box = .{
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
fn aiStep(mobs: *Mobs, mob: *Mob, findings: *Findings) !void {
    if (mob.no_jump_delay > 0) mob.no_jump_delay -= 1;
    if (@abs(mob.velocity[0]) < 0.003) mob.velocity[0] = 0;
    if (@abs(mob.velocity[1]) < 0.003) mob.velocity[1] = 0;
    if (@abs(mob.velocity[2]) < 0.003) mob.velocity[2] = 0;
    // LivingEntity.applyInput.
    mob.strafe *= 0.98;
    mob.forward *= 0.98;
    if (!mob.alive()) {
        mob.jumping = false;
        mob.strafe = 0;
        mob.forward = 0;
    } else if (!mob.no_ai) {
        try ai.serverAiStep(mobs, mob);
    }
    if (mob.jumping) {
        const in_lava = living.inLava(mob);
        const fluid_height = if (in_lava) mob.lava_height else mob.water_height;
        const swimming = mob.touching_water and fluid_height > 0;
        const threshold = living.fluidJumpThreshold(mobs, mob);
        if (swimming and !(mob.on_ground and !(fluid_height > threshold))) {
            living.jumpInLiquid(mob);
        } else if (in_lava and !(mob.on_ground and !(fluid_height > threshold))) {
            living.jumpInLiquid(mob);
        } else if ((mob.on_ground or (swimming and fluid_height <= threshold)) and mob.no_jump_delay == 0) {
            try living.jumpFromGround(mobs, mob);
            mob.no_jump_delay = 10;
        }
    } else {
        mob.no_jump_delay = 0;
    }
    const input: [3]f32 = .{ mob.strafe, mob.vertical_input, mob.forward };
    if (!mob.no_ai) {
        // At rest with no input, travel pulls the mob into the floor and back as last tick.
        const still = std.meta.eql(input, [3]f32{ 0, 0, 0 }) and std.meta.eql(mob.velocity, mob.rest_velocity);
        if (restsInPlace(mob) and still) {
            mobs.travels_skipped += 1;
            if (verify_rest) {
                var copy = mob.*;
                try living.travel(mobs, &copy, input);
                checkSkip(mob, &copy);
            }
        } else {
            mobs.travels_run += 1;
            try living.travel(mobs, mob, input);
        }
    }
    // Blocks act on a mob that moved, or stands in or on one that acts.
    const unmoved = std.meta.eql(mob.position, mob.old_position) and mob.movement_count == 0 and mob.fire_ticks == 0 and mob.ticks_frozen == 0;
    if (restsInPlace(mob) and unmoved) {
        if (verify_rest) {
            var copy = mob.*;
            assert(!try effects.applyEffectsFromBlocks(mobs, &copy));
            checkSkip(mob, &copy);
        }
    } else {
        findings.blocks_acted = try effects.applyEffectsFromBlocks(mobs, mob);
    }
    // Freezing: powder snow chills, and thaws two ticks at a time outside it.
    if (!mob.in_powder_snow) mob.ticks_frozen = @max(0, mob.ticks_frozen - 2);
    // LivingEntity.removeFrost, then tryAddFrost over anything but air.
    mob.frost_speed = 0;
    if (mob.ticks_frozen > 0) {
        const under = try living.onPosition(mobs, mob, 0.2);
        const level = mobs.level(mob.world);
        if (!level.blocks.get(try level.state(under[0], under[1], under[2])).flags.air) {
            mob.frost_speed = -0.05 * (@as(f32, @floatFromInt(@min(140, mob.ticks_frozen))) / 140.0);
        }
    }
    if (@rem(mob.tick_count, 40) == 0 and mob.ticks_frozen >= 140) _ = try mobs.hurt(mob, .{ .type = .freeze }, 1);
    // A mob coming into contact wakes a resting one, so one at rest touches nothing.
    if (restsInPlace(mob)) {
        if (verify_rest) {
            var copy = mob.*;
            assert(try mobs.pushEntities(&copy) == 0);
            checkSkip(mob, &copy);
        }
    } else {
        findings.touched = try mobs.pushEntities(mob);
    }

    // AgeableMob.aiStep.
    if (mob.alive()) {
        if (mob.age < 0) {
            mobs.setAge(mob, mob.age + 1);
        } else if (mob.age > 0) {
            mobs.setAge(mob, mob.age - 1);
        }
    }
    // Animal.aiStep.
    if (mob.age != 0) mob.in_love = 0;
    if (mob.in_love > 0) {
        mob.in_love -= 1;
        if (@rem(mob.in_love, 10) == 0) {
            // A heart particle on the client, but the random draws happen on the server too.
            _ = mob.random.nextGaussian();
            _ = mob.random.nextGaussian();
            _ = mob.random.nextGaussian();
            _ = mob.random.nextDouble();
            _ = mob.random.nextDouble();
            _ = mob.random.nextDouble();
        }
    }
}

/// The end of LivingEntity.tick: the body faces where the mob walked, through
/// BodyRotationControl, which Mob.tickHeadTurn uses.
fn turnBody(mobs: *Mobs, mob: *Mob) void {
    _ = mobs;
    const dx = mob.position[0] - mob.old_position[0];
    const dz = mob.position[2] - mob.old_position[2];
    if (dx * dx + dz * dz > @as(f64, @as(f32, 2.5000003e-7))) {
        mob.body_yaw = mob.yaw;
        mob.head_yaw = mth.rotateIfNecessary(mob.head_yaw, mob.body_yaw, 75);
        mob.last_stable_head_yaw = mob.head_yaw;
        mob.head_stable_time = 0;
        return;
    }
    if (@abs(mob.head_yaw - mob.last_stable_head_yaw) > 15) {
        mob.head_stable_time = 0;
        mob.last_stable_head_yaw = mob.head_yaw;
        mob.body_yaw = mth.rotateIfNecessary(mob.body_yaw, mob.head_yaw, 75);
    } else {
        mob.head_stable_time += 1;
        if (mob.head_stable_time > 10) {
            const fraction = mth.clamp(@as(f32, @floatFromInt(mob.head_stable_time - 10)) / 10.0, 0, 1);
            mob.body_yaw = mth.rotateIfNecessary(mob.body_yaw, mob.head_yaw, 75 * (1 - fraction));
        }
    }
}
