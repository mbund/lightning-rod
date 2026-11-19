//! Mob.serverAiStep: goals every other tick, navigation, then the move, look and jump controls
//! that turn a wanted position into walking input.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const goals = @import("goals.zig");
const navigation = @import("navigation.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

pub fn serverAiStep(mobs: *Mobs, mob: *Mob) !void {
    mob.no_action_time += 1;
    // Mob.getId is the network id, which is the entity id here.
    const parity = @rem(mob.tick_count +% @as(i32, @intCast(mob.id & 0x7fffffff)), 2);
    if (parity != 0 and mob.tick_count > 1) {
        try goals.tickRunning(mobs, mob, false);
    } else {
        try goals.tick(mobs, mob);
    }
    try navigation.tick(mobs, mob);
    // Animal.customServerAiStep.
    if (mob.age != 0) mob.in_love = 0;
    try moveControl(mobs, mob);
    lookControl(mobs, mob);
    // JumpControl.tick.
    mob.jumping = mob.jump;
    mob.jump = false;
}

/// MoveControl.setWantedPosition.
pub fn setWanted(mob: *Mob, x: f64, y: f64, z: f64, speed: f64) void {
    mob.wanted = .{ x, y, z };
    mob.move_speed = speed;
    if (mob.move_operation != .jumping) mob.move_operation = .move_to;
}

/// MoveControl.rotlerp, which keeps the angle in [0, 360].
fn rotlerp(angle: f32, target: f32, limit: f32) f32 {
    const turn = mth.clamp(mth.wrapDegrees(target - angle), -limit, limit);
    var result = angle + turn;
    if (result < 0) {
        result += 360;
    } else if (result > 360) {
        result -= 360;
    }
    return result;
}

pub fn movementSpeed(mobs: *const Mobs, mob: *const Mob) f64 {
    return @max(0, mobs.traits(mob.species).attribute(.movement_speed) + mob.frost_speed);
}

/// MoveControl.tick.
fn moveControl(mobs: *Mobs, mob: *Mob) !void {
    switch (mob.move_operation) {
        .strafe => unreachable,
        .move_to => {
            mob.move_operation = .wait;
            const dx = mob.wanted[0] - mob.position[0];
            const dz = mob.wanted[2] - mob.position[2];
            const dy = mob.wanted[1] - mob.position[1];
            const squared = dx * dx + dy * dy + dz * dz;
            if (squared < @as(f64, @as(f32, 2.5000003e-7))) {
                mob.forward = 0;
                return;
            }
            const facing: f32 = @as(f32, @floatCast(mth.atan2(dz, dx) * @as(f64, @as(f32, 180.0)) / @as(f64, @as(f32, std.math.pi)))) - 90.0;
            mob.yaw = rotlerp(mob.yaw, facing, 90);
            const speed: f32 = @floatCast(mob.move_speed * movementSpeed(mobs, mob));
            mob.speed = speed;
            mob.forward = speed;
            const level = mobs.level(mob.world);
            const at = mob.blockPosition();
            const state = try level.state(at[0], at[1], at[2]);
            const entry = level.blocks.get(state);
            // LivingEntity.maxUpStep is a float.
            const step: f64 = @as(f32, @floatCast(mobs.traits(mob.species).attribute(.step_height)));
            // BlockState.getCollisionShape with no entity, as the move control asks.
            const boxes = @import("vanilla_bodies").body.contextFreeBoxes(state, at[0], at[2]);
            var top: f64 = 0;
            for (0..boxes.count) |index| top = @max(top, boxes.get(index)[4]);
            const climb = dy > step and dx * dx + dz * dz < @as(f64, @max(@as(f32, 1.0), living.width(mobs, mob)));
            const ledge = boxes.count > 0 and mob.position[1] < top + @as(f64, @floatFromInt(at[1])) and !entry.flags.door and !entry.flags.fence;
            if (climb or ledge) {
                mob.jump = true;
                mob.move_operation = .jumping;
            }
        },
        .jumping => {
            const speed: f32 = @floatCast(mob.move_speed * movementSpeed(mobs, mob));
            mob.speed = speed;
            mob.forward = speed;
            if (mob.on_ground or (mob.touching_water or living.inLava(mob))) mob.move_operation = .wait;
        },
        .wait => mob.forward = 0,
    }
}

/// LookControl.setLookAt with the mob's own turn limits.
pub fn setLookAt(mob: *Mob, x: f64, y: f64, z: f64, max_yaw: f32, max_pitch: f32) void {
    mob.look_wanted = .{ x, y, z };
    mob.look_max_yaw = max_yaw;
    mob.look_max_pitch = max_pitch;
    mob.look_cooldown = 2;
}

/// Mob.getHeadRotSpeed and Mob.getMaxHeadXRot.
pub const head_rotation_speed = 10;
pub const max_head_pitch = 40;
/// Mob.getMaxHeadYRot.
pub const max_head_yaw = 75;

/// LookControl.tick.
fn lookControl(mobs: *Mobs, mob: *Mob) void {
    mob.pitch = 0;
    if (mob.look_cooldown > 0) {
        mob.look_cooldown -= 1;
        if (lookYaw(mob)) |yaw| mob.head_yaw = mth.rotateTowards(mob.head_yaw, yaw, mob.look_max_yaw);
        if (lookPitch(mobs, mob)) |pitch| mob.pitch = setPitch(mth.rotateTowards(mob.pitch, pitch, mob.look_max_pitch));
    } else {
        mob.head_yaw = mth.rotateTowards(mob.head_yaw, mob.body_yaw, 10);
    }
    if (navigation.inProgress(mob)) mob.head_yaw = mth.rotateIfNecessary(mob.head_yaw, mob.body_yaw, max_head_yaw);
}

/// LookControl.getYRotD: the yaw toward what the mob looks at, unless it is straight above or below.
pub fn lookYaw(mob: *const Mob) ?f32 {
    return lookYawAt(mob.look_wanted, mob.position);
}

pub fn lookYawAt(wanted: [3]f64, position: [3]f64) ?f32 {
    const dx = wanted[0] - position[0];
    const dz = wanted[2] - position[2];
    if (!(@abs(dz) > @as(f64, @as(f32, 1.0e-5)) or @abs(dx) > @as(f64, @as(f32, 1.0e-5)))) return null;
    return @as(f32, @floatCast(mth.atan2(dz, dx) * @as(f64, @as(f32, 180.0)) / @as(f64, @as(f32, std.math.pi)))) - 90.0;
}

/// LookControl.getXRotD: the pitch toward what the mob looks at, unless it is right there.
pub fn lookPitch(mobs: *const Mobs, mob: *const Mob) ?f32 {
    const dx = mob.look_wanted[0] - mob.position[0];
    const dz = mob.look_wanted[2] - mob.position[2];
    const dy = mob.look_wanted[1] - living.eyeY(mobs, mob);
    const horizontal = @sqrt(dx * dx + dz * dz);
    if (!(@abs(dy) > @as(f64, @as(f32, 1.0e-5)) or @abs(horizontal) > @as(f64, @as(f32, 1.0e-5)))) return null;
    return @floatCast(-(mth.atan2(dy, horizontal) * @as(f64, @as(f32, 180.0)) / @as(f64, @as(f32, std.math.pi))));
}

/// Entity.setXRot: clamped to [-90, 90] after taking it modulo 360.
pub fn setPitch(value: f32) f32 {
    return mth.clamp(@rem(value, 360.0), -90, 90);
}
