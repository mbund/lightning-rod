//! A mob's body as vanilla's Entity and LivingEntity move it: Entity.move with collisions and
//! stepping, falling, the blocks a body stands on, fluid heights and currents, and
//! LivingEntity.travel on land, in water and in lava. Functions take the Mobs plugin for the
//! world and for what moving causes (sounds, damage, block changes), so they run in vanilla's
//! order and draw from the mob's random as vanilla does.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const body = @import("vanilla_bodies").body;
const clip = @import("vanilla_bodies").clip;
const mob_blocks = @import("vanilla_bodies").mob_blocks;
const fluids = @import("vanilla_bodies").fluids;
const Mob = @import("mob.zig").Mob;
const Movement = @import("mob.zig").Movement;
const DamageType = @import("mob.zig").DamageType;
const Mobs = @import("mobs.zig").Mobs;
const Sound = @import("mobs.zig").Sound;

const Box = body.Box;
/// Debug builds still do what a skip would spare and check it found nothing.
const verify_skips = @import("builtin").mode == .debug;
const assert = std.debug.assert;

pub fn width(mobs: *const Mobs, mob: Mob) f32 {
    const traits = mobs.traits(mob.entity.species);
    return if (mob.baby()) traits.baby_width else traits.width;
}

pub fn height(mobs: *const Mobs, mob: Mob) f32 {
    const traits = mobs.traits(mob.entity.species);
    return if (mob.baby()) traits.baby_height else traits.height;
}

pub fn eyeHeight(mobs: *const Mobs, mob: Mob) f32 {
    const traits = mobs.traits(mob.entity.species);
    return if (mob.baby()) traits.baby_eye_height else traits.eye_height;
}

pub fn eyeY(mobs: *const Mobs, mob: Mob) f64 {
    return mob.motion.position[1] + eyeHeight(mobs, mob);
}

pub fn box(mobs: *const Mobs, mob: Mob) Box {
    return body.makeBox(mob.motion.position, width(mobs, mob), height(mobs, mob));
}

pub fn context(mob: Mob) body.Context {
    return .{ .bottom = mob.motion.position[1], .fall_distance = mob.motion.fall_distance };
}

/// The context of a mob moving or asking for room: its own, which other entities meet too.
pub fn moverContext(mobs: *const Mobs, mob: Mob) body.Context {
    var result = context(mob);
    result.slot = mobs.slotOf(mob.entity.id).?;
    return result;
}

fn lengthSquared(vector: [3]f64) f64 {
    return vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
}

/// Entity.addMovementThisTick: block effects trace these at the end of the tick. Vanilla
/// keeps up to 100 and merges the oldest two past that, the same rule over fewer.
fn addMovement(mobs: *Mobs, mob: Mob, movement: Movement) void {
    const movements = &mobs.movements;
    if (mob.motion.movement_count == movements.len) {
        movements[1] = .{ .from = movements[0].from, .to = movements[1].to, .axis_independent = false };
        std.mem.copyForwards(Movement, movements[0 .. movements.len - 1], movements[1..]);
        mob.motion.movement_count -= 1;
    }
    movements[mob.motion.movement_count] = movement;
    mob.motion.movement_count += 1;
}

/// Entity.move for a mob moving itself.
pub fn move(mobs: *Mobs, mob: Mob, requested_in: [3]f64) !void {
    var requested = requested_in;
    if (lengthSquared(mob.motion.stuck) > 1.0e-7) {
        requested = .{ requested[0] * mob.motion.stuck[0], requested[1] * mob.motion.stuck[1], requested[2] * mob.motion.stuck[2] };
        mob.motion.stuck = .{ 0, 0, 0 };
        mob.motion.velocity = .{ 0, 0, 0 };
    }
    const level = mobs.level(mob.motion.world);
    const traits = mobs.traits(mob.entity.species);
    const start = box(mobs, mob);
    const moved = try body.collide(&level, start, requested, moverContext(mobs, mob), mob.motion.on_ground, @floatCast(traits.attribute(.step_height)));
    const moved_squared = lengthSquared(moved);
    if (moved_squared > 1.0e-7 or lengthSquared(requested) - moved_squared < 1.0e-7) {
        if (mob.motion.fall_distance != 0 and moved_squared >= 1.0) {
            const destination: [3]f64 = .{ mob.motion.position[0] + moved[0], mob.motion.position[1] + moved[1], mob.motion.position[2] + moved[2] };
            // Entity.move: a fall through water or a block that ends one ends it.
            if (try clip.clip(&level, mob.motion.position, destination, .fall_damage_resetting, .water, context(mob)) != null) mob.motion.fall_distance = 0;
        }
        const from = mob.motion.position;
        const to: [3]f64 = .{ from[0] + moved[0], from[1] + moved[1], from[2] + moved[2] };
        addMovement(mobs, mob, .{ .from = from, .to = to, .axis_independent = true });
        mob.motion.position = to;
    }
    const blocked_x = !mth.equal(requested[0], moved[0]);
    const blocked_z = !mth.equal(requested[2], moved[2]);
    mob.motion.horizontal_collision = blocked_x or blocked_z;
    // Mobs on the server are their own authority, so the vertical flags always update.
    mob.motion.vertical_collision = requested[1] != moved[1];
    mob.motion.vertical_collision_below = mob.motion.vertical_collision and requested[1] < 0;
    mob.motion.on_ground = mob.motion.vertical_collision_below;
    try checkSupportingBlock(mobs, mob, moved);
    const on_position = try onPosition(mobs, mob, 0.2);
    const on_state = try level.state(on_position[0], on_position[1], on_position[2]);
    try checkFallDamage(mobs, mob, moved[1], mob.motion.on_ground, on_state, on_position);
    if (mob.entity.removed) return;
    if (mob.motion.horizontal_collision) {
        if (blocked_x) mob.motion.velocity[0] = 0;
        if (blocked_z) mob.motion.velocity[2] = 0;
    }
    if (requested[1] != moved[1]) afterFallOn(mobs, mob, on_state);
    try movementEmission(mobs, mob, moved, on_position, on_state);
    const factor = try blockSpeedFactor(mobs, mob);
    mob.motion.velocity[0] *= factor;
    mob.motion.velocity[2] *= factor;
}

/// Entity.checkSupportingBlock, after a move that may have landed.
fn checkSupportingBlock(mobs: *Mobs, mob: Mob, moved: [3]f64) !void {
    if (!mob.motion.on_ground) {
        mob.motion.on_ground_no_blocks = false;
        mob.motion.supporting = null;
        return;
    }
    const level = mobs.level(mob.motion.world);
    const found = try body.supportingAfterMove(&level, box(mobs, mob), context(mob), mob.motion.position, moved, mob.motion.on_ground_no_blocks);
    mob.motion.supporting = found;
    mob.motion.on_ground_no_blocks = found == null;
}

/// Entity.getOnPos: the block the mob stands on, looked for this far below its feet.
pub fn onPosition(mobs: *Mobs, mob: Mob, depth: f32) ![3]i32 {
    const level = mobs.level(mob.motion.world);
    return body.onPos(&level, mob.motion.supporting, mob.motion.position, depth);
}

/// LivingEntity.checkFallDamage then Entity.checkFallDamage.
fn checkFallDamage(mobs: *Mobs, mob: Mob, moved_y: f64, on_ground: bool, state: u16, position: [3]i32) !void {
    if (!mob.entity.touching_water) try updateWaterState(mobs, mob);
    if (on_ground and mob.motion.fall_distance > 0) {
        const traits = mobs.traits(mob.entity.species);
        const power = @max(0, mth.floor(mob.motion.fall_distance + 1.0e-6 - traits.attribute(.safe_fall_distance)));
        if (power > 0 and !game_data.physics.get(state).air) {
            var x = mob.motion.position[0];
            var z = mob.motion.position[2];
            const at = mob.blockPosition();
            if (position[0] != at[0] or position[2] != at[2]) {
                const dx = x - @as(f64, @floatFromInt(position[0])) - 0.5;
                const dz = z - @as(f64, @floatFromInt(position[2])) - 0.5;
                const farthest = @max(@abs(dx), @abs(dz));
                x = @as(f64, @floatFromInt(position[0])) + 0.5 + dx / farthest * 0.5;
                z = @as(f64, @floatFromInt(position[2])) + 0.5 + dz / farthest * 0.5;
            }
            const scale = @min(@as(f64, @as(f32, 0.2)) + @as(f64, @floatFromInt(power)) / 15.0, 2.5);
            mobs.blockParticles(mob.motion.world, .{ x, mob.motion.position[1], z }, state, @intFromFloat(150.0 * scale), @as(f32, 0.15));
        }
    }
    if (!mob.entity.touching_water and moved_y < 0) mob.motion.fall_distance -= @as(f64, @as(f32, @floatCast(moved_y)));
    if (on_ground) {
        if (mob.motion.fall_distance > 0) try fallOn(mobs, mob, state, position, mob.motion.fall_distance);
        mob.motion.fall_distance = 0;
        mob.living.last_climbable = null;
    }
}

/// Block.fallOn and the blocks that change it.
fn fallOn(mobs: *Mobs, mob: Mob, state: u16, position: [3]i32, distance: f64) !void {
    const level = mobs.level(mob.motion.world);
    const entry = level.blocks.get(state);
    // BedBlock.fallOn halves the distance.
    if (entry.flags.bed) return try causeFallDamage(mobs, mob, distance * 0.5, 1, .fall);
    switch (entry.kind) {
        .hay_block, .honey_block => {
            if (entry.kind == .honey_block) mobs.blockSound(mob.motion.world, mob.motion.position, .honey_block_slide, 1, 1);
            return try causeFallDamage(mobs, mob, distance, 0.2, .fall);
        },
        // SlimeBlock.fallOn: no damage unless the entity suppresses bouncing, which mobs never do.
        .slime_block => return try causeFallDamage(mobs, mob, distance, 0, .fall),
        // PowderSnowBlock.fallOn: only a sound, and no fall damage.
        .powder_snow => {
            if (distance >= 4) mobs.playSound(mob, if (distance < 7) .generic_small_fall else .generic_big_fall, 1, 1);
            return;
        },
        .farmland => {
            // FarmBlock.fallOn, which draws from the level's random.
            if (@as(f64, mobs.levelRandom().nextFloat()) < distance - 0.5 and mobs.mobGriefing()) {
                const w = width(mobs, mob);
                const h = height(mobs, mob);
                if (w * w * h > 0.512) try mobs.trampleFarmland(mob.motion.world, position, state);
            }
            return try causeFallDamage(mobs, mob, distance, 1, .fall);
        },
        .turtle_egg => {
            // TurtleEggBlock.fallOn: one fall in three cracks an egg, drawn only where mobs may grief.
            if (mobs.mobGriefing() and mobs.levelRandom().nextIntBounded(3) == 0) try mobs.crackTurtleEgg(mob.motion.world, position, state);
            return try causeFallDamage(mobs, mob, distance, 1, .fall);
        },
        .pointed_dripstone => {
            if (pointsUp(state)) return try causeFallDamage(mobs, mob, distance + 2.5, 2, .stalagmite);
            return try causeFallDamage(mobs, mob, distance, 1, .fall);
        },
        else => return try causeFallDamage(mobs, mob, distance, 1, .fall),
    }
}

fn pointsUp(state: u16) bool {
    const name = game_data.registry.blockStateName(state).?;
    return std.mem.indexOf(u8, name, "thickness=tip,") != null and std.mem.indexOf(u8, name, "vertical_direction=up") != null;
}

/// LivingEntity.causeFallDamage.
fn causeFallDamage(mobs: *Mobs, mob: Mob, distance: f64, multiplier: f32, damage_type: DamageType) !void {
    const traits = mobs.traits(mob.entity.species);
    const power = distance + 1.0e-6 - traits.attribute(.safe_fall_distance);
    const damage = mth.floor(power * multiplier * traits.attribute(.fall_damage_multiplier));
    if (damage <= 0) return;
    mobs.playSound(mob, if (damage > 4) .generic_big_fall else .generic_small_fall, 1, 1);
    try playBlockFallSound(mobs, mob);
    _ = try mobs.hurt(mob, .{ .type = damage_type }, @floatFromInt(damage));
}

/// LivingEntity.playBlockFallSound.
fn playBlockFallSound(mobs: *Mobs, mob: Mob) !void {
    const level = mobs.level(mob.motion.world);
    const state = try level.state(mth.floor(mob.motion.position[0]), mth.floor(mob.motion.position[1] - @as(f64, @as(f32, 0.2))), mth.floor(mob.motion.position[2]));
    if (game_data.physics.get(state).air) return;
    mobs.blockFallSound(mob, state);
}

/// Block.updateEntityMovementAfterFallOn, after a move that stopped vertically.
fn afterFallOn(mobs: *Mobs, mob: Mob, state: u16) void {
    const entry = mobs.blocks.get(state);
    if (entry.kind == .slime_block or entry.flags.bed) {
        // SlimeBlock and BedBlock bounce what falls on them, beds less.
        if (mob.motion.velocity[1] < 0) mob.motion.velocity[1] = -mob.motion.velocity[1] * (if (entry.kind == .slime_block) @as(f64, 1.0) else @as(f64, @as(f32, 0.66)));
        return;
    }
    mob.motion.velocity[1] = 0;
}

/// Entity.applyMovementEmissionAndPlaySound: step sounds every block walked.
fn movementEmission(mobs: *Mobs, mob: Mob, moved: [3]f64, on_legacy: [3]i32, on_legacy_state: u16) !void {
    const level = mobs.level(mob.motion.world);
    const horizontal: f32 = @floatCast(@sqrt(moved[0] * moved[0] + moved[2] * moved[2]) * @as(f64, @as(f32, 0.6)));
    const length: f32 = @floatCast(@sqrt(lengthSquared(moved)) * @as(f64, @as(f32, 0.6)));
    const on = try onPosition(mobs, mob, 1.0e-5);
    const on_state = try level.state(on[0], on[1], on[2]);
    const on_entry = level.blocks.get(on_state);
    const climbable = on_entry.flags.climbable or on_entry.kind == .powder_snow;
    mob.motion.move_dist += if (climbable) length else horizontal;
    if (mob.motion.move_dist > mob.motion.next_step and !on_entry.flags.air) {
        const same = std.meta.eql(on, on_legacy);
        var stepped = stepEffects(mobs, mob, on_legacy_state, true);
        if (!same) stepped = stepEffects(mobs, mob, on_state, false) or stepped;
        if (stepped) {
            mob.motion.next_step = @floor(mob.motion.move_dist) + 1;
        } else if (mob.entity.touching_water) {
            mob.motion.next_step = @floor(mob.motion.move_dist) + 1;
            playSwimSound(mobs, mob);
        }
    }
}

/// Entity.vibrationAndSoundEffectsFromBlock, which the step sound of the mob plays from.
fn stepEffects(mobs: *Mobs, mob: Mob, state: u16, sound: bool) bool {
    const entry = mobs.blocks.get(state);
    if (entry.flags.air) return false;
    const climbable = entry.flags.climbable or entry.kind == .powder_snow;
    if (!mob.motion.on_ground and !climbable) return false;
    if (sound) mobs.stepSound(mob, state);
    return true;
}

/// Entity.playSwimSound, quieter for slower swimmers.
fn playSwimSound(mobs: *Mobs, mob: Mob) void {
    const velocity = mob.motion.velocity;
    const strength: f32 = @min(1.0, @as(f32, @floatCast(@sqrt(velocity[0] * velocity[0] * @as(f64, @as(f32, 0.2)) + velocity[1] * velocity[1] + velocity[2] * velocity[2] * @as(f64, @as(f32, 0.2))))) * 0.35);
    const pitch = 1.0 + (mob.idle.random.nextFloat() - mob.idle.random.nextFloat()) * 0.4;
    mobs.playSound(mob, .generic_swim, strength, pitch);
}

/// LivingEntity.getBlockSpeedFactor, with no movement efficiency, then Entity's.
fn blockSpeedFactor(mobs: *Mobs, mob: Mob) !f32 {
    const level = mobs.level(mob.motion.world);
    const at = mob.blockPosition();
    const state = try level.state(at[0], at[1], at[2]);
    const factor = game_data.physics.get(state).speed;
    const kind = level.blocks.get(state).kind;
    const own = if (kind == .water or kind == .bubble_column) factor else if (factor == 1.0) below: {
        const under = try onPosition(mobs, mob, 0.500001);
        break :below game_data.physics.get(try level.state(under[0], under[1], under[2])).speed;
    } else factor;
    const efficiency: f32 = @floatCast(mobs.traits(mob.entity.species).attribute(.movement_efficiency));
    return mth.lerp(efficiency, own, 1.0);
}

/// Entity.getBlockJumpFactor.
pub fn blockJumpFactor(mobs: *Mobs, mob: Mob) !f32 {
    const level = mobs.level(mob.motion.world);
    const at = mob.blockPosition();
    const factor = game_data.physics.mobState(try level.state(at[0], at[1], at[2])).jump_factor;
    if (factor != 1.0) return factor;
    const under = try onPosition(mobs, mob, 0.500001);
    return game_data.physics.mobState(try level.state(under[0], under[1], under[2])).jump_factor;
}

// Fluids.

/// Entity.updateInWaterStateAndDoFluidPushing.
pub fn updateFluids(mobs: *Mobs, mob: Mob) !void {
    try updateWaterState(mobs, mob);
    const ultrawarm = mobs.ultrawarm(mob.motion.world);
    mob.entity.lava_height = (try fluids.heightAndPush(&mobs.level(mob.motion.world), box(mobs, mob), &mob.motion.velocity, .lava, if (ultrawarm) 0.007 else 0.0023333333333333335)).height;
}

/// Entity.updateInWaterStateAndDoWaterCurrentPushing.
pub fn updateWaterState(mobs: *Mobs, mob: Mob) !void {
    const result = try fluids.heightAndPush(&mobs.level(mob.motion.world), box(mobs, mob), &mob.motion.velocity, .water, 0.014);
    mob.entity.water_height = result.height;
    if (result.touching) {
        if (!mob.entity.touching_water and !mob.entity.first_tick) waterSplash(mobs, mob);
        mob.motion.fall_distance = 0;
        mob.entity.touching_water = true;
    } else {
        mob.entity.touching_water = false;
    }
}

/// Entity.doWaterSplashEffect: the sound, and the random particles cost, which vanilla draws
/// even though the server shows none.
fn waterSplash(mobs: *Mobs, mob: Mob) void {
    const velocity = mob.motion.velocity;
    const strength: f32 = @min(1.0, @as(f32, @floatCast(@sqrt(velocity[0] * velocity[0] * @as(f64, @as(f32, 0.2)) + velocity[1] * velocity[1] + velocity[2] * velocity[2] * @as(f64, @as(f32, 0.2))))) * 0.2);
    const pitch = 1.0 + (mob.idle.random.nextFloat() - mob.idle.random.nextFloat()) * 0.4;
    mobs.playSound(mob, if (strength < 0.25) .generic_splash else .generic_splash, strength, pitch);
    const count = 1.0 + width(mobs, mob) * 20.0;
    var index: f32 = 0;
    while (index < count) : (index += 1) {
        _ = mob.idle.random.nextDouble();
        _ = mob.idle.random.nextDouble();
        _ = mob.idle.random.nextDouble();
    }
    index = 0;
    while (index < count) : (index += 1) {
        _ = mob.idle.random.nextDouble();
        _ = mob.idle.random.nextDouble();
    }
}

/// Entity.updateFluidOnEyes, for water only, which is what mobs read.
pub fn updateEyes(mobs: *Mobs, mob: Mob) !void {
    const level = mobs.level(mob.motion.world);
    const eye = eyeY(mobs, mob);
    const at: [3]i32 = .{ mth.floor(mob.motion.position[0]), mth.floor(eye), mth.floor(mob.motion.position[2]) };
    const physics = try level.fluid(at[0], at[1], at[2]);
    if (physics.fluid == .none) {
        mob.entity.eye_in_water = false;
        return;
    }
    const top = try fluids.top(&level, at[0], at[1], at[2], physics);
    mob.entity.eye_in_water = top > eye and physics.fluid == .water;
}

pub fn inLava(mob: Mob) bool {
    return !mob.entity.first_tick and mob.entity.lava_height > 0;
}

// Travel.

/// LivingEntity.travel for a mob moving itself.
pub fn travel(mobs: *Mobs, mob: Mob, input: [3]f32) !void {
    if (mob.entity.touching_water or inLava(mob)) {
        try travelInFluid(mobs, mob, input);
    } else {
        try travelInAir(mobs, mob, input);
    }
}

fn gravity(mobs: *Mobs, mob: Mob) f64 {
    return mobs.traits(mob.entity.species).attribute(.gravity);
}

/// LivingEntity.travelInAir.
fn travelInAir(mobs: *Mobs, mob: Mob, input: [3]f32) !void {
    const level = mobs.level(mob.motion.world);
    const below = try onPosition(mobs, mob, 0.500001);
    const friction: f32 = if (mob.motion.on_ground) game_data.physics.get(try level.state(below[0], below[1], below[2])).friction else 1.0;
    const drag = friction * 0.91;
    const velocity = try relativeFriction(mobs, mob, input, friction);
    var vertical = velocity[1];
    // The chunk under a ticking mob is always loaded on the server.
    vertical -= gravity(mobs, mob);
    mob.motion.velocity = .{ velocity[0] * drag, vertical * @as(f64, @as(f32, 0.98)), velocity[2] * drag };
}

/// LivingEntity.travelInFluid.
fn travelInFluid(mobs: *Mobs, mob: Mob, input: [3]f32) !void {
    const falling = mob.motion.velocity[1] <= 0;
    const start_y = mob.motion.position[1];
    const g = gravity(mobs, mob);
    const traits = mobs.traits(mob.entity.species);
    if (mob.entity.touching_water) {
        // LivingEntity.getWaterSlowDown, as mobs do not sprint.
        var slowdown: f32 = 0.8;
        var speed: f32 = 0.02;
        var efficiency: f32 = @floatCast(traits.attribute(.water_movement_efficiency));
        if (!mob.motion.on_ground) efficiency *= 0.5;
        if (efficiency > 0) {
            slowdown += (0.54600006 - slowdown) * efficiency;
            speed += (mob.living.speed - speed) * efficiency;
        }
        moveRelative(mob, speed, input);
        try move(mobs, mob, mob.motion.velocity);
        var velocity = mob.motion.velocity;
        if (mob.motion.horizontal_collision and try onClimbable(mobs, mob)) velocity[1] = 0.2;
        velocity = .{ velocity[0] * slowdown, velocity[1] * @as(f64, @as(f32, 0.8)), velocity[2] * slowdown };
        mob.motion.velocity = fluidFallingAdjusted(g, falling, velocity);
    } else {
        moveRelative(mob, 0.02, input);
        try move(mobs, mob, mob.motion.velocity);
        if (mob.entity.lava_height <= fluidJumpThreshold(mobs, mob)) {
            mob.motion.velocity = .{ mob.motion.velocity[0] * 0.5, mob.motion.velocity[1] * @as(f64, @as(f32, 0.8)), mob.motion.velocity[2] * 0.5 };
            mob.motion.velocity = fluidFallingAdjusted(g, falling, mob.motion.velocity);
        } else {
            mob.motion.velocity = .{ mob.motion.velocity[0] * 0.5, mob.motion.velocity[1] * 0.5, mob.motion.velocity[2] * 0.5 };
        }
        if (g != 0) mob.motion.velocity[1] += -g / 4.0;
    }
    const velocity = mob.motion.velocity;
    if (mob.motion.horizontal_collision and try isFree(mobs, mob, .{ velocity[0], velocity[1] + @as(f64, @as(f32, 0.6)) - mob.motion.position[1] + start_y, velocity[2] })) {
        mob.motion.velocity = .{ velocity[0], @as(f64, @as(f32, 0.3)), velocity[2] };
    }
}

/// LivingEntity.getFluidFallingAdjustedMovement.
fn fluidFallingAdjusted(g: f64, falling: bool, velocity: [3]f64) [3]f64 {
    if (g == 0) return velocity;
    const vertical = if (falling and @abs(velocity[1] - 0.005) >= 0.003 and @abs(velocity[1] - g / 16.0) < 0.003) -0.003 else velocity[1] - g / 16.0;
    return .{ velocity[0], vertical, velocity[2] };
}

/// Entity.getFluidJumpThreshold.
pub fn fluidJumpThreshold(mobs: *const Mobs, mob: Mob) f64 {
    return if (eyeHeight(mobs, mob) < 0.4) 0.0 else 0.4;
}

/// LivingEntity.handleRelativeFrictionAndCalculateMovement.
fn relativeFriction(mobs: *Mobs, mob: Mob, input: [3]f32, friction: f32) ![3]f64 {
    const speed = if (mob.motion.on_ground) mob.living.speed * (0.21600002 / (friction * friction * friction)) else 0.02;
    moveRelative(mob, speed, input);
    try handleOnClimbable(mobs, mob);
    try move(mobs, mob, mob.motion.velocity);
    var velocity = mob.motion.velocity;
    // Mobs never walk on powder snow, so only climbing lifts them.
    if ((mob.motion.horizontal_collision or mob.living.jumping) and try onClimbable(mobs, mob)) velocity[1] = 0.2;
    return velocity;
}

/// LivingEntity.handleOnClimbable.
fn handleOnClimbable(mobs: *Mobs, mob: Mob) !void {
    if (!try onClimbable(mobs, mob)) return;
    mob.motion.fall_distance = 0;
    const limit: f64 = @as(f32, 0.15);
    mob.motion.velocity = .{ mth.clampDouble(mob.motion.velocity[0], -limit, limit), @max(mob.motion.velocity[1], -limit), mth.clampDouble(mob.motion.velocity[2], -limit, limit) };
}

/// LivingEntity.onClimbable: climbable blocks, and open trapdoors over a ladder facing the
/// same way.
pub fn onClimbable(mobs: *Mobs, mob: Mob) !bool {
    const level = mobs.level(mob.motion.world);
    const at = mob.blockPosition();
    if (!try body.climbableAt(&level, at)) return false;
    mob.living.last_climbable = at;
    return true;
}

/// Entity.moveRelative with Entity.getInputVector.
pub fn moveRelative(mob: Mob, speed: f32, input: [3]f32) void {
    const vector: [3]f64 = .{ input[0], input[1], input[2] };
    const squared = lengthSquared(vector);
    if (squared < 1.0e-7) return;
    const unit = if (squared > 1.0) mth.normalize(vector) else vector;
    const scaled: [3]f64 = .{ unit[0] * speed, unit[1] * speed, unit[2] * speed };
    const sine: f64 = mth.sin(mob.motion.yaw * (std.math.pi / 180.0));
    const cosine: f64 = mth.cos(mob.motion.yaw * (std.math.pi / 180.0));
    mob.motion.velocity = .{ mob.motion.velocity[0] + (scaled[0] * cosine - scaled[2] * sine), mob.motion.velocity[1] + scaled[1], mob.motion.velocity[2] + (scaled[2] * cosine + scaled[0] * sine) };
}

/// Entity.isFree: no collision and no liquid in the box moved by the offset.
pub fn isFree(mobs: *Mobs, mob: Mob, offset: [3]f64) !bool {
    const level = mobs.level(mob.motion.world);
    const moved = box(mobs, mob).move(offset);
    if (!try body.noCollision(&level, moved, moverContext(mobs, mob))) return false;
    return !try containsLiquid(&level, moved);
}

/// Level.containsAnyLiquid.
pub fn containsLiquid(level: *const body.Level, target: Box) !bool {
    var x = mth.floor(target.min[0]);
    while (x < mth.ceil(target.max[0])) : (x += 1) {
        var y = mth.floor(target.min[1]);
        while (y < mth.ceil(target.max[1])) : (y += 1) {
            var z = mth.floor(target.min[2]);
            while (z < mth.ceil(target.max[2])) : (z += 1) {
                if ((try level.fluid(x, y, z)).fluid != .none) return true;
            }
        }
    }
    return false;
}

/// LivingEntity.jumpFromGround, for mobs that never sprint.
pub fn jumpFromGround(mobs: *Mobs, mob: Mob) !void {
    const traits = mobs.traits(mob.entity.species);
    const power: f32 = @as(f32, @floatCast(traits.attribute(.jump_strength))) * try blockJumpFactor(mobs, mob);
    if (power <= 1.0e-5) return;
    mob.motion.velocity[1] = @max(@as(f64, power), mob.motion.velocity[1]);
    mob.entity.has_impulse = true;
}

/// LivingEntity.jumpInLiquid.
pub fn jumpInLiquid(mob: Mob) void {
    mob.motion.velocity[1] += @as(f64, @as(f32, 0.04));
}
