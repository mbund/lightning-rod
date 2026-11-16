//! A mob's body as vanilla's Entity and LivingEntity move it: Entity.move with collisions and
//! stepping, falling, the blocks a body stands on, fluid heights and currents, and
//! LivingEntity.travel on land, in water and in lava. Functions take the Mobs plugin for the
//! world and for what moving causes (sounds, damage, block changes), so they run in vanilla's
//! order and draw from the mob's random as vanilla does.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");
const Mob = @import("mob.zig").Mob;
const Movement = @import("mob.zig").Movement;
const DamageType = @import("mob.zig").DamageType;
const Mobs = @import("mobs.zig").Mobs;
const Sound = @import("mobs.zig").Sound;

const Box = body.Box;
const assert = std.debug.assert;

pub fn width(mobs: *const Mobs, mob: *const Mob) f32 {
    const traits = mobs.traits(mob.species);
    return if (mob.baby()) traits.baby_width else traits.width;
}

pub fn height(mobs: *const Mobs, mob: *const Mob) f32 {
    const traits = mobs.traits(mob.species);
    return if (mob.baby()) traits.baby_height else traits.height;
}

pub fn eyeHeight(mobs: *const Mobs, mob: *const Mob) f32 {
    const traits = mobs.traits(mob.species);
    return if (mob.baby()) traits.baby_eye_height else traits.eye_height;
}

pub fn eyeY(mobs: *const Mobs, mob: *const Mob) f64 {
    return mob.position[1] + eyeHeight(mobs, mob);
}

pub fn box(mobs: *const Mobs, mob: *const Mob) Box {
    return body.makeBox(mob.position, width(mobs, mob), height(mobs, mob));
}

pub fn context(mob: *const Mob) body.Context {
    return .{ .bottom = mob.position[1], .fall_distance = mob.fall_distance };
}

fn lengthSquared(vector: [3]f64) f64 {
    return vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
}

/// Entity.addMovementThisTick: block effects trace these at the end of the tick. Vanilla
/// keeps up to 100 and merges the oldest two past that, the same rule over fewer.
fn addMovement(mobs: *Mobs, mob: *Mob, movement: Movement) void {
    const movements = &mobs.movements;
    if (mob.movement_count == movements.len) {
        movements[1] = .{ .from = movements[0].from, .to = movements[1].to, .axis_independent = false };
        std.mem.copyForwards(Movement, movements[0 .. movements.len - 1], movements[1..]);
        mob.movement_count -= 1;
    }
    movements[mob.movement_count] = movement;
    mob.movement_count += 1;
}

/// Entity.move for a mob moving itself.
pub fn move(mobs: *Mobs, mob: *Mob, requested_in: [3]f64) !void {
    var requested = requested_in;
    if (lengthSquared(mob.stuck) > 1.0e-7) {
        requested = .{ requested[0] * mob.stuck[0], requested[1] * mob.stuck[1], requested[2] * mob.stuck[2] };
        mob.stuck = .{ 0, 0, 0 };
        mob.velocity = .{ 0, 0, 0 };
    }
    const level = mobs.level(mob.world);
    const traits = mobs.traits(mob.species);
    const moved = try body.collide(&level, box(mobs, mob), requested, context(mob), mob.on_ground, @floatCast(traits.attribute(.step_height)));
    const moved_squared = lengthSquared(moved);
    if (moved_squared > 1.0e-7 or lengthSquared(requested) - moved_squared < 1.0e-7) {
        if (mob.fall_distance != 0 and moved_squared >= 1.0) {
            const destination: [3]f64 = .{ mob.position[0] + moved[0], mob.position[1] + moved[1], mob.position[2] + moved[2] };
            if (try clipsFallReset(&level, mob.position, destination)) mob.fall_distance = 0;
        }
        const from = mob.position;
        const to: [3]f64 = .{ from[0] + moved[0], from[1] + moved[1], from[2] + moved[2] };
        addMovement(mobs, mob, .{ .from = from, .to = to, .axis_independent = true });
        mob.position = to;
    }
    const blocked_x = !mth.equal(requested[0], moved[0]);
    const blocked_z = !mth.equal(requested[2], moved[2]);
    mob.horizontal_collision = blocked_x or blocked_z;
    // Mobs on the server are their own authority, so the vertical flags always update.
    mob.vertical_collision = requested[1] != moved[1];
    mob.vertical_collision_below = mob.vertical_collision and requested[1] < 0;
    mob.on_ground = mob.vertical_collision_below;
    try checkSupportingBlock(mobs, mob, moved);
    const on_position = try onPosition(mobs, mob, 0.2);
    const on_state = try level.state(on_position[0], on_position[1], on_position[2]);
    try checkFallDamage(mobs, mob, moved[1], mob.on_ground, on_state, on_position);
    if (mob.removed) return;
    if (mob.horizontal_collision) {
        if (blocked_x) mob.velocity[0] = 0;
        if (blocked_z) mob.velocity[2] = 0;
    }
    if (requested[1] != moved[1]) afterFallOn(mobs, mob, on_state);
    try movementEmission(mobs, mob, moved, on_position, on_state);
    const factor = try blockSpeedFactor(mobs, mob);
    mob.velocity[0] *= factor;
    mob.velocity[2] *= factor;
}

/// Entity.checkSupportingBlock, after a move that may have landed.
fn checkSupportingBlock(mobs: *Mobs, mob: *Mob, moved: [3]f64) !void {
    if (!mob.on_ground) {
        mob.on_ground_no_blocks = false;
        mob.supporting = null;
        return;
    }
    const level = mobs.level(mob.world);
    const current = box(mobs, mob);
    const below: Box = .{ .min = .{ current.min[0], current.min[1] - 1.0e-6, current.min[2] }, .max = .{ current.max[0], current.min[1], current.max[2] } };
    var found = try body.findSupportingBlock(&level, below, context(mob), mob.position);
    if (found != null or mob.on_ground_no_blocks) {
        mob.supporting = found;
    } else {
        found = try body.findSupportingBlock(&level, below.move(.{ -moved[0], 0, -moved[2] }), context(mob), mob.position);
        mob.supporting = found;
    }
    mob.on_ground_no_blocks = found == null;
}

/// Entity.getOnPos: the block the mob stands on, looked for this far below its feet.
pub fn onPosition(mobs: *Mobs, mob: *const Mob, depth: f32) ![3]i32 {
    if (mob.supporting) |supporting| {
        if (!(depth > 1.0e-5)) return supporting;
        const level = mobs.level(mob.world);
        const entry = level.blocks.get(try level.state(supporting[0], supporting[1], supporting[2]));
        const keeps = (depth <= 0.5 and entry.flags.fence) or entry.flags.wall or entry.flags.fence_gate;
        if (keeps) return supporting;
        return .{ supporting[0], mth.floor(mob.position[1] - depth), supporting[2] };
    }
    return .{ mth.floor(mob.position[0]), mth.floor(mob.position[1] - depth), mth.floor(mob.position[2]) };
}

/// LivingEntity.checkFallDamage then Entity.checkFallDamage.
fn checkFallDamage(mobs: *Mobs, mob: *Mob, moved_y: f64, on_ground: bool, state: u16, position: [3]i32) !void {
    if (!mob.touching_water) try updateWaterState(mobs, mob);
    if (on_ground and mob.fall_distance > 0) {
        const traits = mobs.traits(mob.species);
        const power = @max(0, mth.floor(mob.fall_distance + 1.0e-6 - traits.attribute(.safe_fall_distance)));
        if (power > 0 and !game_data.physics.get(state).air) {
            var x = mob.position[0];
            var z = mob.position[2];
            const at = mob.blockPosition();
            if (position[0] != at[0] or position[2] != at[2]) {
                const dx = x - @as(f64, @floatFromInt(position[0])) - 0.5;
                const dz = z - @as(f64, @floatFromInt(position[2])) - 0.5;
                const farthest = @max(@abs(dx), @abs(dz));
                x = @as(f64, @floatFromInt(position[0])) + 0.5 + dx / farthest * 0.5;
                z = @as(f64, @floatFromInt(position[2])) + 0.5 + dz / farthest * 0.5;
            }
            const scale = @min(@as(f64, @as(f32, 0.2)) + @as(f64, @floatFromInt(power)) / 15.0, 2.5);
            mobs.blockParticles(mob.world, .{ x, mob.position[1], z }, state, @intFromFloat(150.0 * scale), @as(f32, 0.15));
        }
    }
    if (!mob.touching_water and moved_y < 0) mob.fall_distance -= @as(f64, @as(f32, @floatCast(moved_y)));
    if (on_ground) {
        if (mob.fall_distance > 0) try fallOn(mobs, mob, state, position, mob.fall_distance);
        mob.fall_distance = 0;
        mob.last_climbable = null;
    }
}

/// Block.fallOn and the blocks that change it.
fn fallOn(mobs: *Mobs, mob: *Mob, state: u16, position: [3]i32, distance: f64) !void {
    const level = mobs.level(mob.world);
    const entry = level.blocks.get(state);
    // BedBlock.fallOn halves the distance.
    if (entry.flags.bed) return try causeFallDamage(mobs, mob, distance * 0.5, 1, .fall);
    switch (entry.kind) {
        .hay_block, .honey_block => {
            if (entry.kind == .honey_block) mobs.blockSound(mob.world, mob.position, .honey_block_slide, 1, 1);
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
                if (w * w * h > 0.512) try mobs.trampleFarmland(mob.world, position, state);
            }
            return try causeFallDamage(mobs, mob, distance, 1, .fall);
        },
        .turtle_egg => {
            // TurtleEggBlock.fallOn: one fall in three cracks an egg, drawn only where mobs may grief.
            if (mobs.mobGriefing() and mobs.levelRandom().nextIntBounded(3) == 0) try mobs.crackTurtleEgg(mob.world, position, state);
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
fn causeFallDamage(mobs: *Mobs, mob: *Mob, distance: f64, multiplier: f32, damage_type: DamageType) !void {
    const traits = mobs.traits(mob.species);
    const power = distance + 1.0e-6 - traits.attribute(.safe_fall_distance);
    const damage = mth.floor(power * multiplier * traits.attribute(.fall_damage_multiplier));
    if (damage <= 0) return;
    mobs.playSound(mob, if (damage > 4) .generic_big_fall else .generic_small_fall, 1, 1);
    try playBlockFallSound(mobs, mob);
    _ = try mobs.hurt(mob, .{ .type = damage_type }, @floatFromInt(damage));
}

/// LivingEntity.playBlockFallSound.
fn playBlockFallSound(mobs: *Mobs, mob: *Mob) !void {
    const level = mobs.level(mob.world);
    const state = try level.state(mth.floor(mob.position[0]), mth.floor(mob.position[1] - @as(f64, @as(f32, 0.2))), mth.floor(mob.position[2]));
    if (game_data.physics.get(state).air) return;
    mobs.blockFallSound(mob, state);
}

/// Block.updateEntityMovementAfterFallOn, after a move that stopped vertically.
fn afterFallOn(mobs: *Mobs, mob: *Mob, state: u16) void {
    const entry = mobs.blocks.get(state);
    if (entry.kind == .slime_block or entry.flags.bed) {
        // SlimeBlock and BedBlock bounce what falls on them, beds less.
        if (mob.velocity[1] < 0) mob.velocity[1] = -mob.velocity[1] * (if (entry.kind == .slime_block) @as(f64, 1.0) else @as(f64, @as(f32, 0.66)));
        return;
    }
    mob.velocity[1] = 0;
}

/// Entity.applyMovementEmissionAndPlaySound: step sounds every block walked.
fn movementEmission(mobs: *Mobs, mob: *Mob, moved: [3]f64, on_legacy: [3]i32, on_legacy_state: u16) !void {
    const level = mobs.level(mob.world);
    const horizontal: f32 = @floatCast(@sqrt(moved[0] * moved[0] + moved[2] * moved[2]) * @as(f64, @as(f32, 0.6)));
    const length: f32 = @floatCast(@sqrt(lengthSquared(moved)) * @as(f64, @as(f32, 0.6)));
    const on = try onPosition(mobs, mob, 1.0e-5);
    const on_state = try level.state(on[0], on[1], on[2]);
    const on_entry = level.blocks.get(on_state);
    const climbable = on_entry.flags.climbable or on_entry.kind == .powder_snow;
    mob.move_dist += if (climbable) length else horizontal;
    if (mob.move_dist > mob.next_step and !on_entry.flags.air) {
        const same = std.meta.eql(on, on_legacy);
        var stepped = stepEffects(mobs, mob, on_legacy_state, true);
        if (!same) stepped = stepEffects(mobs, mob, on_state, false) or stepped;
        if (stepped) {
            mob.next_step = @floor(mob.move_dist) + 1;
        } else if (mob.touching_water) {
            mob.next_step = @floor(mob.move_dist) + 1;
            playSwimSound(mobs, mob);
        }
    }
}

/// Entity.vibrationAndSoundEffectsFromBlock, which the step sound of the mob plays from.
fn stepEffects(mobs: *Mobs, mob: *Mob, state: u16, sound: bool) bool {
    const entry = mobs.blocks.get(state);
    if (entry.flags.air) return false;
    const climbable = entry.flags.climbable or entry.kind == .powder_snow;
    if (!mob.on_ground and !climbable) return false;
    if (sound) mobs.stepSound(mob, state);
    return true;
}

/// Entity.playSwimSound, quieter for slower swimmers.
fn playSwimSound(mobs: *Mobs, mob: *Mob) void {
    const velocity = mob.velocity;
    const strength: f32 = @min(1.0, @as(f32, @floatCast(@sqrt(velocity[0] * velocity[0] * @as(f64, @as(f32, 0.2)) + velocity[1] * velocity[1] + velocity[2] * velocity[2] * @as(f64, @as(f32, 0.2))))) * 0.35);
    const pitch = 1.0 + (mob.random.nextFloat() - mob.random.nextFloat()) * 0.4;
    mobs.playSound(mob, .generic_swim, strength, pitch);
}

/// LivingEntity.getBlockSpeedFactor, with no movement efficiency, then Entity's.
fn blockSpeedFactor(mobs: *Mobs, mob: *const Mob) !f32 {
    const level = mobs.level(mob.world);
    const at = mob.blockPosition();
    const state = try level.state(at[0], at[1], at[2]);
    const factor = game_data.physics.get(state).speed;
    const kind = level.blocks.get(state).kind;
    const own = if (kind == .water or kind == .bubble_column) factor else if (factor == 1.0) below: {
        const under = try onPosition(mobs, mob, 0.500001);
        break :below game_data.physics.get(try level.state(under[0], under[1], under[2])).speed;
    } else factor;
    const efficiency: f32 = @floatCast(mobs.traits(mob.species).attribute(.movement_efficiency));
    return mth.lerp(efficiency, own, 1.0);
}

/// Entity.getBlockJumpFactor.
pub fn blockJumpFactor(mobs: *Mobs, mob: *const Mob) !f32 {
    const level = mobs.level(mob.world);
    const at = mob.blockPosition();
    const factor = game_data.physics.mobState(try level.state(at[0], at[1], at[2])).jump_factor;
    if (factor != 1.0) return factor;
    const under = try onPosition(mobs, mob, 0.500001);
    return game_data.physics.mobState(try level.state(under[0], under[1], under[2])).jump_factor;
}

/// Whether a ray from one point to another passes a block that resets falling or water, as the
/// clip in Entity.move tests with Block.FALLDAMAGE_RESETTING and ClipContext.Fluid.WATER.
fn clipsFallReset(level: *const body.Level, from: [3]f64, to: [3]f64) !bool {
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    // BlockGetter.traverseBlocks walks the cells the segment crosses, from a start pulled back
    // by 1e-7 toward the end.
    const start: [3]f64 = .{ lerp(-1.0e-7, to[0], from[0]), lerp(-1.0e-7, to[1], from[1]), lerp(-1.0e-7, to[2], from[2]) };
    const end: [3]f64 = .{ lerp(-1.0e-7, from[0], to[0]), lerp(-1.0e-7, from[1], to[1]), lerp(-1.0e-7, from[2], to[2]) };
    var cell: [3]i32 = .{ mth.floor(start[0]), mth.floor(start[1]), mth.floor(start[2]) };
    var step: [3]i32 = undefined;
    var next: [3]f64 = undefined;
    var increment: [3]f64 = undefined;
    for (0..3) |axis| {
        const span = end[axis] - start[axis];
        step[axis] = if (span > 0) 1 else if (span < 0) -1 else 0;
        increment[axis] = if (step[axis] == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(step[axis])) / span;
        const fraction = start[axis] - @floor(start[axis]);
        next[axis] = increment[axis] * (if (step[axis] > 0) 1.0 - fraction else fraction);
    }
    while (true) {
        if (try hitsResetCell(level, cell, from, delta)) return true;
        if (next[0] > 1 and next[1] > 1 and next[2] > 1) return false;
        const axis: usize = if (next[0] < next[1]) (if (next[0] < next[2]) 0 else 2) else (if (next[1] < next[2]) 1 else 2);
        cell[axis] += step[axis];
        next[axis] += increment[axis];
    }
}

fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}

fn hitsResetCell(level: *const body.Level, cell: [3]i32, from: [3]f64, delta: [3]f64) !bool {
    const state = try level.state(cell[0], cell[1], cell[2]);
    const origin: [3]f64 = .{ @floatFromInt(cell[0]), @floatFromInt(cell[1]), @floatFromInt(cell[2]) };
    if (level.blocks.get(state).flags.fall_damage_resetting) {
        if (segmentHits(.{ .min = origin, .max = .{ origin[0] + 1, origin[1] + 1, origin[2] + 1 } }, from, delta)) return true;
    }
    const physics = game_data.physics.get(state);
    if (physics.fluid == .water) {
        const above = game_data.physics.get(try level.state(cell[0], cell[1] + 1, cell[2]));
        const top: f64 = if (above.fluid == .water) 1.0 else physics.height();
        if (segmentHits(.{ .min = origin, .max = .{ origin[0] + 1, origin[1] + top, origin[2] + 1 } }, from, delta)) return true;
    }
    return false;
}

/// VoxelShape.clip for one box: hit when the point just past the start is inside, or when the
/// segment enters the box.
fn segmentHits(target: Box, from: [3]f64, delta: [3]f64) bool {
    if (lengthSquared(delta) < 1.0e-7) return false;
    const probe: [3]f64 = .{ from[0] + delta[0] * 0.001, from[1] + delta[1] * 0.001, from[2] + delta[2] * 0.001 };
    if (probe[0] >= target.min[0] and probe[0] < target.max[0] and probe[1] >= target.min[1] and probe[1] < target.max[1] and probe[2] >= target.min[2] and probe[2] < target.max[2]) return true;
    var enter: f64 = 0;
    var leave: f64 = 1;
    for (0..3) |axis| {
        if (delta[axis] == 0) {
            if (from[axis] < target.min[axis] or from[axis] > target.max[axis]) return false;
            continue;
        }
        var near = (target.min[axis] - from[axis]) / delta[axis];
        var far = (target.max[axis] - from[axis]) / delta[axis];
        if (near > far) std.mem.swap(f64, &near, &far);
        enter = @max(enter, near);
        leave = @min(leave, far);
        if (enter > leave) return false;
    }
    return true;
}

// Fluids.

/// Entity.updateInWaterStateAndDoFluidPushing.
pub fn updateFluids(mobs: *Mobs, mob: *Mob) !void {
    try updateWaterState(mobs, mob);
    const ultrawarm = mobs.ultrawarm(mob.world);
    mob.lava_height = (try fluidHeightAndPush(mobs, mob, .lava, if (ultrawarm) 0.007 else 0.0023333333333333335)).height;
}

/// Entity.updateInWaterStateAndDoWaterCurrentPushing.
pub fn updateWaterState(mobs: *Mobs, mob: *Mob) !void {
    const result = try fluidHeightAndPush(mobs, mob, .water, 0.014);
    mob.water_height = result.height;
    if (result.touching) {
        if (!mob.touching_water and !mob.first_tick) waterSplash(mobs, mob);
        mob.fall_distance = 0;
        mob.touching_water = true;
    } else {
        mob.touching_water = false;
    }
}

const FluidResult = struct { touching: bool, height: f64 };

/// Entity.updateFluidHeightAndDoFluidPushing.
fn fluidHeightAndPush(mobs: *Mobs, mob: *Mob, fluid: game_data.physics_data.Fluid, strength: f64) !FluidResult {
    const level = mobs.level(mob.world);
    const current = box(mobs, mob).inflate(-0.001, -0.001, -0.001);
    const first: [3]i32 = .{ mth.floor(current.min[0]), mth.floor(current.min[1]), mth.floor(current.min[2]) };
    const last: [3]i32 = .{ mth.ceil(current.max[0]), mth.ceil(current.max[1]), mth.ceil(current.max[2]) };
    var deepest: f64 = 0;
    var touching = false;
    var push: [3]f64 = .{ 0, 0, 0 };
    var pushes: u32 = 0;
    var x = first[0];
    while (x < last[0]) : (x += 1) {
        var y = first[1];
        while (y < last[1]) : (y += 1) {
            var z = first[2];
            while (z < last[2]) : (z += 1) {
                const physics = try level.fluid(x, y, z);
                if (physics.fluid != fluid) continue;
                const top = @as(f64, @floatFromInt(y)) + try fluidHeight(&level, x, y, z, physics);
                if (top < current.min[1]) continue;
                touching = true;
                deepest = @max(top - current.min[1], deepest);
                // Every mob is pushed by fluids.
                var flow = try fluidFlow(&level, x, y, z, physics);
                if (deepest < 0.4) flow = .{ flow[0] * deepest, flow[1] * deepest, flow[2] * deepest };
                push = .{ push[0] + flow[0], push[1] + flow[1], push[2] + flow[2] };
                pushes += 1;
            }
        }
    }
    if (@sqrt(lengthSquared(push)) > 0) {
        if (pushes > 0) {
            const scale = 1.0 / @as(f64, @floatFromInt(pushes));
            push = .{ push[0] * scale, push[1] * scale, push[2] * scale };
        }
        push = normalize(push);
        push = .{ push[0] * strength, push[1] * strength, push[2] * strength };
        if (@abs(mob.velocity[0]) < 0.003 and @abs(mob.velocity[2]) < 0.003 and @sqrt(lengthSquared(push)) < 0.0045000000000000005) {
            push = normalize(push);
            push = .{ push[0] * 0.0045000000000000005, push[1] * 0.0045000000000000005, push[2] * 0.0045000000000000005 };
        }
        mob.velocity = .{ mob.velocity[0] + push[0], mob.velocity[1] + push[1], mob.velocity[2] + push[2] };
    }
    return .{ .touching = touching, .height = deepest };
}

pub fn normalize(vector: [3]f64) [3]f64 {
    const length = @sqrt(lengthSquared(vector));
    if (length < 1.0e-5) return .{ 0, 0, 0 };
    return .{ vector[0] / length, vector[1] / length, vector[2] / length };
}

/// FluidState.getHeight: a full block under the same fluid, its own height otherwise.
fn fluidHeight(level: *const body.Level, x: i32, y: i32, z: i32, physics: game_data.physics_data.State) !f64 {
    const above = try level.fluid(x, y + 1, z);
    return if (above.fluid == physics.fluid) 1.0 else physics.height();
}

/// FlowingFluid.getFlow.
fn fluidFlow(level: *const body.Level, x: i32, y: i32, z: i32, physics: game_data.physics_data.State) ![3]f64 {
    // Direction.Plane.HORIZONTAL: north, east, south, west, with their sturdy face bits.
    const directions = [_]struct { dx: i32, dz: i32, face: u3 }{
        .{ .dx = 0, .dz = -1, .face = 2 },
        .{ .dx = 1, .dz = 0, .face = 1 },
        .{ .dx = 0, .dz = 1, .face = 3 },
        .{ .dx = -1, .dz = 0, .face = 0 },
    };
    var flow_x: f64 = 0;
    var flow_z: f64 = 0;
    for (directions) |direction| {
        const other = try level.fluid(x + direction.dx, y, z + direction.dz);
        if (other.fluid != physics.fluid and other.fluid != .none) continue;
        var own = other.height();
        var difference: f32 = 0;
        if (own == 0) {
            if (!other.blocks_motion) {
                const below = try level.fluid(x + direction.dx, y - 1, z + direction.dz);
                if (below.fluid == physics.fluid or below.fluid == .none) {
                    own = below.height();
                    if (own > 0) difference = physics.height() - (own - 0.8888889);
                }
            }
        } else if (own > 0) {
            difference = physics.height() - own;
        }
        if (difference != 0) {
            flow_x += @as(f64, @floatFromInt(direction.dx)) * difference;
            flow_z += @as(f64, @floatFromInt(direction.dz)) * difference;
        }
    }
    var flow: [3]f64 = .{ flow_x, 0, flow_z };
    if (physics.falling) {
        for (directions) |direction| {
            const mask = @as(u8, 1) << direction.face;
            const side = try level.fluid(x + direction.dx, y, z + direction.dz);
            const above = try level.fluid(x + direction.dx, y + 1, z + direction.dz);
            const solid = (side.fluid != physics.fluid and !side.ice and side.sturdy & mask != 0) or (above.fluid != physics.fluid and !above.ice and above.sturdy & mask != 0);
            if (solid) {
                flow = normalize(flow);
                flow[1] -= 6.0;
                break;
            }
        }
    }
    return normalize(flow);
}

/// Entity.doWaterSplashEffect: the sound, and the random particles cost, which vanilla draws
/// even though the server shows none.
fn waterSplash(mobs: *Mobs, mob: *Mob) void {
    const velocity = mob.velocity;
    const strength: f32 = @min(1.0, @as(f32, @floatCast(@sqrt(velocity[0] * velocity[0] * @as(f64, @as(f32, 0.2)) + velocity[1] * velocity[1] + velocity[2] * velocity[2] * @as(f64, @as(f32, 0.2))))) * 0.2);
    const pitch = 1.0 + (mob.random.nextFloat() - mob.random.nextFloat()) * 0.4;
    mobs.playSound(mob, if (strength < 0.25) .generic_splash else .generic_splash, strength, pitch);
    const count = 1.0 + width(mobs, mob) * 20.0;
    var index: f32 = 0;
    while (index < count) : (index += 1) {
        _ = mob.random.nextDouble();
        _ = mob.random.nextDouble();
        _ = mob.random.nextDouble();
    }
    index = 0;
    while (index < count) : (index += 1) {
        _ = mob.random.nextDouble();
        _ = mob.random.nextDouble();
    }
}

/// Entity.updateFluidOnEyes, for water only, which is what mobs read.
pub fn updateEyes(mobs: *Mobs, mob: *Mob) !void {
    const level = mobs.level(mob.world);
    const eye = eyeY(mobs, mob);
    const at: [3]i32 = .{ mth.floor(mob.position[0]), mth.floor(eye), mth.floor(mob.position[2]) };
    const physics = try level.fluid(at[0], at[1], at[2]);
    if (physics.fluid == .none) {
        mob.eye_in_water = false;
        return;
    }
    const top = @as(f64, @floatFromInt(at[1])) + try fluidHeight(&level, at[0], at[1], at[2], physics);
    mob.eye_in_water = top > eye and physics.fluid == .water;
}

pub fn inLava(mob: *const Mob) bool {
    return !mob.first_tick and mob.lava_height > 0;
}

// Travel.

/// LivingEntity.travel for a mob moving itself.
pub fn travel(mobs: *Mobs, mob: *Mob, input: [3]f32) !void {
    if (mob.touching_water or inLava(mob)) {
        try travelInFluid(mobs, mob, input);
    } else {
        try travelInAir(mobs, mob, input);
    }
}

fn gravity(mobs: *Mobs, mob: *const Mob) f64 {
    return mobs.traits(mob.species).attribute(.gravity);
}

/// LivingEntity.travelInAir.
fn travelInAir(mobs: *Mobs, mob: *Mob, input: [3]f32) !void {
    const level = mobs.level(mob.world);
    const below = try onPosition(mobs, mob, 0.500001);
    const friction: f32 = if (mob.on_ground) game_data.physics.get(try level.state(below[0], below[1], below[2])).friction else 1.0;
    const drag = friction * 0.91;
    const velocity = try relativeFriction(mobs, mob, input, friction);
    var vertical = velocity[1];
    // The chunk under a ticking mob is always loaded on the server.
    vertical -= gravity(mobs, mob);
    mob.velocity = .{ velocity[0] * drag, vertical * @as(f64, @as(f32, 0.98)), velocity[2] * drag };
}

/// LivingEntity.travelInFluid.
fn travelInFluid(mobs: *Mobs, mob: *Mob, input: [3]f32) !void {
    const falling = mob.velocity[1] <= 0;
    const start_y = mob.position[1];
    const g = gravity(mobs, mob);
    const traits = mobs.traits(mob.species);
    if (mob.touching_water) {
        // LivingEntity.getWaterSlowDown, as mobs do not sprint.
        var slowdown: f32 = 0.8;
        var speed: f32 = 0.02;
        var efficiency: f32 = @floatCast(traits.attribute(.water_movement_efficiency));
        if (!mob.on_ground) efficiency *= 0.5;
        if (efficiency > 0) {
            slowdown += (0.54600006 - slowdown) * efficiency;
            speed += (mob.speed - speed) * efficiency;
        }
        moveRelative(mob, speed, input);
        try move(mobs, mob, mob.velocity);
        var velocity = mob.velocity;
        if (mob.horizontal_collision and try onClimbable(mobs, mob)) velocity[1] = 0.2;
        velocity = .{ velocity[0] * slowdown, velocity[1] * @as(f64, @as(f32, 0.8)), velocity[2] * slowdown };
        mob.velocity = fluidFallingAdjusted(g, falling, velocity);
    } else {
        moveRelative(mob, 0.02, input);
        try move(mobs, mob, mob.velocity);
        if (mob.lava_height <= fluidJumpThreshold(mobs, mob)) {
            mob.velocity = .{ mob.velocity[0] * 0.5, mob.velocity[1] * @as(f64, @as(f32, 0.8)), mob.velocity[2] * 0.5 };
            mob.velocity = fluidFallingAdjusted(g, falling, mob.velocity);
        } else {
            mob.velocity = .{ mob.velocity[0] * 0.5, mob.velocity[1] * 0.5, mob.velocity[2] * 0.5 };
        }
        if (g != 0) mob.velocity[1] += -g / 4.0;
    }
    const velocity = mob.velocity;
    if (mob.horizontal_collision and try isFree(mobs, mob, .{ velocity[0], velocity[1] + @as(f64, @as(f32, 0.6)) - mob.position[1] + start_y, velocity[2] })) {
        mob.velocity = .{ velocity[0], @as(f64, @as(f32, 0.3)), velocity[2] };
    }
}

/// LivingEntity.getFluidFallingAdjustedMovement.
fn fluidFallingAdjusted(g: f64, falling: bool, velocity: [3]f64) [3]f64 {
    if (g == 0) return velocity;
    const vertical = if (falling and @abs(velocity[1] - 0.005) >= 0.003 and @abs(velocity[1] - g / 16.0) < 0.003) -0.003 else velocity[1] - g / 16.0;
    return .{ velocity[0], vertical, velocity[2] };
}

/// Entity.getFluidJumpThreshold.
pub fn fluidJumpThreshold(mobs: *const Mobs, mob: *const Mob) f64 {
    return if (eyeHeight(mobs, mob) < 0.4) 0.0 else 0.4;
}

/// LivingEntity.handleRelativeFrictionAndCalculateMovement.
fn relativeFriction(mobs: *Mobs, mob: *Mob, input: [3]f32, friction: f32) ![3]f64 {
    const speed = if (mob.on_ground) mob.speed * (0.21600002 / (friction * friction * friction)) else 0.02;
    moveRelative(mob, speed, input);
    try handleOnClimbable(mobs, mob);
    try move(mobs, mob, mob.velocity);
    var velocity = mob.velocity;
    // Mobs never walk on powder snow, so only climbing lifts them.
    if ((mob.horizontal_collision or mob.jumping) and try onClimbable(mobs, mob)) velocity[1] = 0.2;
    return velocity;
}

/// LivingEntity.handleOnClimbable.
fn handleOnClimbable(mobs: *Mobs, mob: *Mob) !void {
    if (!try onClimbable(mobs, mob)) return;
    mob.fall_distance = 0;
    const limit: f64 = @as(f32, 0.15);
    mob.velocity = .{ mth.clampDouble(mob.velocity[0], -limit, limit), @max(mob.velocity[1], -limit), mth.clampDouble(mob.velocity[2], -limit, limit) };
}

/// LivingEntity.onClimbable: climbable blocks, and open trapdoors over a ladder facing the
/// same way.
pub fn onClimbable(mobs: *Mobs, mob: *Mob) !bool {
    const level = mobs.level(mob.world);
    const at = mob.blockPosition();
    const entry = level.blocks.get(try level.state(at[0], at[1], at[2]));
    if (entry.flags.climbable) {
        mob.last_climbable = at;
        return true;
    }
    if (entry.flags.trapdoor and entry.flags.open) {
        const below = level.blocks.get(try level.state(at[0], at[1] - 1, at[2]));
        if (below.kind == .ladder and below.facing == entry.facing) {
            mob.last_climbable = at;
            return true;
        }
    }
    return false;
}

/// Entity.moveRelative with Entity.getInputVector.
pub fn moveRelative(mob: *Mob, speed: f32, input: [3]f32) void {
    const vector: [3]f64 = .{ input[0], input[1], input[2] };
    const squared = lengthSquared(vector);
    if (squared < 1.0e-7) return;
    const unit = if (squared > 1.0) normalize(vector) else vector;
    const scaled: [3]f64 = .{ unit[0] * speed, unit[1] * speed, unit[2] * speed };
    const sine: f64 = mth.sin(mob.yaw * (std.math.pi / 180.0));
    const cosine: f64 = mth.cos(mob.yaw * (std.math.pi / 180.0));
    mob.velocity = .{ mob.velocity[0] + (scaled[0] * cosine - scaled[2] * sine), mob.velocity[1] + scaled[1], mob.velocity[2] + (scaled[2] * cosine + scaled[0] * sine) };
}

/// Entity.isFree: no collision and no liquid in the box moved by the offset.
pub fn isFree(mobs: *Mobs, mob: *const Mob, offset: [3]f64) !bool {
    const level = mobs.level(mob.world);
    const moved = box(mobs, mob).move(offset);
    if (!try body.noCollision(&level, moved, context(mob))) return false;
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
pub fn jumpFromGround(mobs: *Mobs, mob: *Mob) !void {
    const traits = mobs.traits(mob.species);
    const power: f32 = @as(f32, @floatCast(traits.attribute(.jump_strength))) * try blockJumpFactor(mobs, mob);
    if (power <= 1.0e-5) return;
    mob.velocity[1] = @max(@as(f64, power), mob.velocity[1]);
    mob.has_impulse = true;
}

/// LivingEntity.jumpInLiquid.
pub fn jumpInLiquid(mob: *Mob) void {
    mob.velocity[1] += @as(f64, @as(f32, 0.04));
}

test "a ray reaching into water clips" {
    const water: Box = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, 0.8888889, 1 } };
    try std.testing.expect(segmentHits(water, .{ 0.5, 3, 0.5 }, .{ 0, -2.5, 0 }));
    try std.testing.expect(!segmentHits(water, .{ 0.5, 3, 0.5 }, .{ 0, -1.5, 0 }));
}
