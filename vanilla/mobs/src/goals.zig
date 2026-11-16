//! GoalSelector with the cow's goals, in AbstractCow.registerGoals' order: float, panic, breed,
//! tempt, follow parent, stroll, look at a player, look around. A goal holds the move, look and
//! jump flags it uses, and starts when every one is free or held by a goal of a lower priority.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const living = @import("living.zig");
const ai = @import("ai.zig");
const navigation = @import("navigation.zig");
const pathfinding = @import("pathfinding.zig");
const senses = @import("senses.zig");
const random_positions = @import("random_positions.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

pub const Goal = enum(u3) {
    float,
    panic,
    breed,
    tempt,
    follow_parent,
    stroll,
    look_at_player,
    look_around,

    const Flags = packed struct { move: bool = false, look: bool = false, jump: bool = false };

    fn flags(self: Goal) Flags {
        return switch (self) {
            .float => .{ .jump = true },
            .panic, .stroll => .{ .move = true },
            .breed, .tempt, .look_around => .{ .move = true, .look = true },
            .follow_parent => .{},
            .look_at_player => .{ .look = true },
        };
    }

    fn requiresUpdateEveryTick(self: Goal) bool {
        return self == .float or self == .look_around;
    }

    fn priority(self: Goal) u3 {
        return @backingInt(self);
    }
};

const all = [_]Goal{ .float, .panic, .breed, .tempt, .follow_parent, .stroll, .look_at_player, .look_around };

fn running(mob: *const Mob, goal: Goal) bool {
    return mob.goals.running & bit(goal) != 0;
}

fn bit(goal: Goal) u8 {
    return @as(u8, 1) << @backingInt(goal);
}

pub fn isPanicking(mob: *const Mob) bool {
    return running(mob, .panic);
}

/// WrappedGoal.stop.
fn stopGoal(mobs: *Mobs, mob: *Mob, goal: Goal) void {
    if (!running(mob, goal)) return;
    mob.goals.running &= ~bit(goal);
    stop(mobs, mob, goal);
}

/// WrappedGoal.start.
fn startGoal(mobs: *Mobs, mob: *Mob, goal: Goal) !void {
    if (running(mob, goal)) return;
    mob.goals.running |= bit(goal);
    try start(mobs, mob, goal);
}

/// GoalSelector.goalCanBeReplacedForAllFlags: every flag is free, or held by a goal this one
/// outranks. Every goal here may be interrupted.
fn replaceable(mob: *const Mob, goal: Goal) bool {
    const flags = goal.flags();
    const owners = [_]struct { wanted: bool, owner: ?u3 }{
        .{ .wanted = flags.move, .owner = mob.goals.move_owner },
        .{ .wanted = flags.look, .owner = mob.goals.look_owner },
        .{ .wanted = flags.jump, .owner = mob.goals.jump_owner },
    };
    for (owners) |entry| {
        if (!entry.wanted) continue;
        const owner = entry.owner orelse continue;
        if (!(goal.priority() < owner)) return false;
    }
    return true;
}

/// GoalSelector.tick.
pub fn tick(mobs: *Mobs, mob: *Mob) !void {
    // Mobs here carry no passengers and ride nothing, so no flag is disabled.
    for (all) |goal| {
        if (running(mob, goal) and !try canContinueToUse(mobs, mob, goal)) stopGoal(mobs, mob, goal);
    }
    // lockedFlags.removeIf(goal is not running).
    if (mob.goals.move_owner) |owner| if (!running(mob, @fromBackingInt(@intCast(owner)))) {
        mob.goals.move_owner = null;
    };
    if (mob.goals.look_owner) |owner| if (!running(mob, @fromBackingInt(@intCast(owner)))) {
        mob.goals.look_owner = null;
    };
    if (mob.goals.jump_owner) |owner| if (!running(mob, @fromBackingInt(@intCast(owner)))) {
        mob.goals.jump_owner = null;
    };
    for (all) |goal| {
        if (running(mob, goal) or !replaceable(mob, goal)) continue;
        if (!try canUse(mobs, mob, goal)) continue;
        const flags = goal.flags();
        if (flags.move) {
            if (mob.goals.move_owner) |owner| stopGoal(mobs, mob, @fromBackingInt(@intCast(owner)));
            mob.goals.move_owner = @backingInt(goal);
        }
        if (flags.look) {
            if (mob.goals.look_owner) |owner| stopGoal(mobs, mob, @fromBackingInt(@intCast(owner)));
            mob.goals.look_owner = @backingInt(goal);
        }
        if (flags.jump) {
            if (mob.goals.jump_owner) |owner| stopGoal(mobs, mob, @fromBackingInt(@intCast(owner)));
            mob.goals.jump_owner = @backingInt(goal);
        }
        try startGoal(mobs, mob, goal);
    }
    try tickRunning(mobs, mob, true);
}

/// GoalSelector.tickRunningGoals.
pub fn tickRunning(mobs: *Mobs, mob: *Mob, every: bool) !void {
    for (all) |goal| {
        if (running(mob, goal) and (every or goal.requiresUpdateEveryTick())) try tickGoal(mobs, mob, goal);
    }
}

/// Goal.reducedTickDelay: halved, rounded up, for goals updated every other tick.
fn reducedTickDelay(ticks: i32) i32 {
    return @divFloor(ticks + 1, 2);
}

fn adjustedTickDelay(goal: Goal, ticks: i32) i32 {
    return if (goal.requiresUpdateEveryTick()) ticks else reducedTickDelay(ticks);
}

fn canUse(mobs: *Mobs, mob: *Mob, goal: Goal) !bool {
    return switch (goal) {
        .float => floatCanUse(mobs, mob),
        .panic => try panicCanUse(mobs, mob),
        .breed => try breedCanUse(mobs, mob),
        .tempt => try temptCanUse(mobs, mob),
        .follow_parent => followParentCanUse(mobs, mob),
        .stroll => try strollCanUse(mobs, mob),
        .look_at_player => try lookAtPlayerCanUse(mobs, mob),
        .look_around => mob.random.nextFloat() < 0.02,
    };
}

fn canContinueToUse(mobs: *Mobs, mob: *Mob, goal: Goal) !bool {
    return switch (goal) {
        .float => floatCanUse(mobs, mob),
        .panic => !navigation.done(mob),
        .breed => breedCanContinue(mobs, mob),
        .tempt => try temptCanUse(mobs, mob),
        .follow_parent => followParentCanContinue(mobs, mob),
        .stroll => !navigation.done(mob),
        .look_at_player => lookAtPlayerCanContinue(mobs, mob),
        .look_around => mob.goals.look_around_time >= 0,
    };
}

fn start(mobs: *Mobs, mob: *Mob, goal: Goal) !void {
    switch (goal) {
        .float => {},
        .panic => {
            const target = mob.goals.panic_target;
            _ = try navigation.moveToPosition(mobs, mob, target[0], target[1], target[2], 2.0);
        },
        .breed => {},
        .tempt => {
            const player = &mobs.deps.players.records[mob.goals.tempt_player.?];
            mob.goals.tempt_player_position = .{ player.position.x, player.position.y, player.position.z };
        },
        .follow_parent => mob.goals.parent_recalculate = 0,
        .stroll => {
            const target = mob.goals.stroll_target;
            _ = try navigation.moveToPosition(mobs, mob, target[0], target[1], target[2], 1.0);
        },
        .look_at_player => mob.goals.look_time = adjustedTickDelay(.look_at_player, 40 + mob.random.nextIntBounded(40)),
        .look_around => {
            const angle = (std.math.pi * 2.0) * mob.random.nextDouble();
            mob.goals.look_around = .{ @cos(angle), @sin(angle) };
            mob.goals.look_around_time = 20 + mob.random.nextIntBounded(20);
        },
    }
}

fn stop(mobs: *Mobs, mob: *Mob, goal: Goal) void {
    _ = mobs;
    switch (goal) {
        .float, .panic, .follow_parent => {
            if (goal == .follow_parent) mob.goals.parent = null;
        },
        .breed => {
            mob.goals.breed_partner = null;
            mob.goals.breed_love_time = 0;
        },
        .tempt => {
            mob.goals.tempt_player = null;
            navigation.stop(mob);
            mob.goals.tempt_calm_down = reducedTickDelay(100);
        },
        .stroll => navigation.stop(mob),
        .look_at_player => mob.goals.look_at_player = null,
        .look_around => {},
    }
}

fn tickGoal(mobs: *Mobs, mob: *Mob, goal: Goal) !void {
    switch (goal) {
        .float => {
            if (mob.random.nextFloat() < 0.8) mob.jump = true;
        },
        .breed => try breedTick(mobs, mob),
        .tempt => try temptTick(mobs, mob),
        .follow_parent => try followParentTick(mobs, mob),
        .look_at_player => {
            const slot = mob.goals.look_at_player orelse return;
            if (!playerAlive(mobs, slot)) return;
            const eye = senses.playerEye(mobs, slot);
            ai.setLookAt(mob, eye[0], eye[1], eye[2], ai.head_rotation_speed, ai.max_head_pitch);
            mob.goals.look_time -= 1;
        },
        .look_around => {
            mob.goals.look_around_time -= 1;
            ai.setLookAt(mob, mob.position[0] + mob.goals.look_around[0], living.eyeY(mobs, mob), mob.position[2] + mob.goals.look_around[1], ai.head_rotation_speed, ai.max_head_pitch);
        },
        .panic, .stroll => {},
    }
}

fn playerAlive(mobs: *Mobs, slot: u32) bool {
    const player = &mobs.deps.players.records[slot];
    if (player.handle == null or player.stage != .ready) return false;
    return mobs.deps.player_states.of(player).health > 0;
}

// FloatGoal.

fn floatCanUse(mobs: *Mobs, mob: *const Mob) bool {
    return (mob.touching_water and mob.water_height > living.fluidJumpThreshold(mobs, mob)) or living.inLava(mob);
}

// PanicGoal.

fn panicCanUse(mobs: *Mobs, mob: *Mob) !bool {
    if (!mobs.shouldPanic(mob)) return false;
    if (mob.fire_ticks > 0) {
        if (try lookForWater(mobs, mob)) |water| {
            mob.goals.panic_target = .{ @floatFromInt(water[0]), @floatFromInt(water[1]), @floatFromInt(water[2]) };
            return true;
        }
    }
    const target = try random_positions.defaultPosition(mobs, mob, 5, 4) orelse return false;
    mob.goals.panic_target = target;
    return true;
}

/// PanicGoal.lookForWater: from a block with no collision shape, the nearest water within 5
/// blocks across and 1 up or down, in BlockPos.withinManhattan's order.
fn lookForWater(mobs: *Mobs, mob: *const Mob) !?[3]i32 {
    const level = mobs.level(mob.world);
    const at = mob.blockPosition();
    if (body.collisionBoxes(&level, try level.state(at[0], at[1], at[2]), at[0], at[1], at[2], .{ .empty = true }).count != 0) return null;
    const horizontal: i32 = 5;
    const vertical: i32 = 1;
    const deepest = horizontal + vertical + horizontal;
    var depth: i32 = 0;
    while (depth <= deepest) : (depth += 1) {
        const max_x = @min(horizontal, depth);
        var x = -max_x;
        while (x <= max_x) : (x += 1) {
            const max_y = @min(vertical, depth - @as(i32, @intCast(@abs(x))));
            var y = -max_y;
            while (y <= max_y) : (y += 1) {
                const z = depth - @as(i32, @intCast(@abs(x))) - @as(i32, @intCast(@abs(y)));
                if (z > horizontal) continue;
                for ([2]i32{ z, -z }, 0..) |offset, mirror| {
                    if (mirror == 1 and z == 0) break;
                    const position: [3]i32 = .{ at[0] + x, at[1] + y, at[2] + offset };
                    if ((try level.fluid(position[0], position[1], position[2])).fluid == .water) return position;
                }
            }
        }
    }
    return null;
}

// BreedGoal.

fn breedCanUse(mobs: *Mobs, mob: *Mob) !bool {
    if (mob.in_love <= 0) return false;
    mob.goals.breed_partner = freePartner(mobs, mob);
    return mob.goals.breed_partner != null;
}

/// BreedGoal.getFreePartner: the nearest mob of the kind within 8 blocks that can mate and
/// does not panic.
fn freePartner(mobs: *Mobs, mob: *Mob) ?u32 {
    var best: ?u32 = null;
    var best_distance = std.math.floatMax(f64);
    var kin = senses.Kin.init(mobs, mob, living.box(mobs, mob).inflate(8, 8, 8));
    while (kin.next()) |index| {
        const other = &mobs.mobs[index];
        if (!other.alive()) continue;
        const distance = senses.distanceSquared(mob, other);
        // PARTNER_TARGETING's range, which mobs see at full visibility.
        if (distance > 64) continue;
        if (!canMate(mob, other) or isPanicking(other)) continue;
        if (distance < best_distance) {
            best = index;
            best_distance = distance;
        }
    }
    return best;
}

/// Animal.canMate: another of the same kind, both in love.
pub fn canMate(mob: *const Mob, other: *const Mob) bool {
    return mob != other and other.species == mob.species and mob.in_love > 0 and other.in_love > 0;
}

fn breedCanContinue(mobs: *Mobs, mob: *Mob) bool {
    const partner = &mobs.mobs[mob.goals.breed_partner orelse return false];
    return partner.alive() and partner.in_love > 0 and mob.goals.breed_love_time < 60 and !isPanicking(partner);
}

fn breedTick(mobs: *Mobs, mob: *Mob) !void {
    const partner_index = mob.goals.breed_partner orelse return;
    const partner = &mobs.mobs[partner_index];
    ai.setLookAt(mob, partner.position[0], living.eyeY(mobs, partner), partner.position[2], 10.0, ai.max_head_pitch);
    _ = try navigation.moveToEntity(mobs, mob, partner.position, 1.0);
    mob.goals.breed_love_time += 1;
    if (mob.goals.breed_love_time >= adjustedTickDelay(.breed, 60) and senses.distanceSquared(mob, partner) < 9.0) try mobs.breed(mob, partner);
}

// TemptGoal.

fn temptCanUse(mobs: *Mobs, mob: *Mob) !bool {
    if (mob.goals.tempt_calm_down > 0) {
        mob.goals.tempt_calm_down -= 1;
        return false;
    }
    const range = mobs.traits(mob.species).attribute(.tempt_range);
    mob.goals.tempt_player = try senses.nearestPlayer(mobs, mob, .{ .range = range, .line_of_sight = false, .holding_food = true }, mob.position);
    return mob.goals.tempt_player != null;
}

fn temptTick(mobs: *Mobs, mob: *Mob) !void {
    const slot = mob.goals.tempt_player orelse return;
    const player = &mobs.deps.players.records[slot];
    const eye = senses.playerEye(mobs, slot);
    ai.setLookAt(mob, eye[0], eye[1], eye[2], @as(f32, ai.max_head_yaw + 20), ai.max_head_pitch);
    const dx = mob.position[0] - player.position.x;
    const dy = mob.position[1] - player.position.y;
    const dz = mob.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz < 2.5 * 2.5) {
        navigation.stop(mob);
    } else {
        _ = try navigation.moveToEntity(mobs, mob, .{ player.position.x, player.position.y, player.position.z }, 1.25);
    }
}

// FollowParentGoal.

fn followParentCanUse(mobs: *Mobs, mob: *Mob) bool {
    if (mob.age >= 0) return false;
    var best: ?u32 = null;
    var best_distance = std.math.floatMax(f64);
    var kin = senses.Kin.init(mobs, mob, living.box(mobs, mob).inflate(8, 4, 8));
    while (kin.next()) |index| {
        const other = &mobs.mobs[index];
        if (other.age < 0) continue;
        const distance = senses.distanceSquared(mob, other);
        if (!(distance > best_distance)) {
            best_distance = distance;
            best = index;
        }
    }
    const parent = best orelse return false;
    if (best_distance < 9.0) return false;
    mob.goals.parent = parent;
    return true;
}

fn followParentCanContinue(mobs: *Mobs, mob: *Mob) bool {
    if (mob.age >= 0) return false;
    const parent = &mobs.mobs[mob.goals.parent orelse return false];
    if (!parent.alive()) return false;
    const distance = senses.distanceSquared(mob, parent);
    return !(distance < 9.0) and !(distance > 256.0);
}

fn followParentTick(mobs: *Mobs, mob: *Mob) !void {
    mob.goals.parent_recalculate -= 1;
    if (mob.goals.parent_recalculate > 0) return;
    mob.goals.parent_recalculate = adjustedTickDelay(.follow_parent, 10);
    const parent = &mobs.mobs[mob.goals.parent orelse return];
    _ = try navigation.moveToEntity(mobs, mob, parent.position, 1.25);
}

// WaterAvoidingRandomStrollGoal.

fn strollCanUse(mobs: *Mobs, mob: *Mob) !bool {
    // RandomStrollGoal checks no action time: mobs no player came near lately stand still.
    if (mob.no_action_time >= 100) return false;
    if (mob.random.nextIntBounded(reducedTickDelay(120)) != 0) return false;
    const target = (try strollPosition(mobs, mob)) orelse return false;
    mob.goals.stroll_target = target;
    return true;
}

/// WaterAvoidingRandomStrollGoal.getPosition.
fn strollPosition(mobs: *Mobs, mob: *Mob) !?[3]f64 {
    if (mob.touching_water) {
        return try random_positions.landPosition(mobs, mob, 15, 7) orelse try random_positions.defaultPosition(mobs, mob, 10, 7);
    }
    if (mob.random.nextFloat() >= 0.001) return random_positions.landPosition(mobs, mob, 10, 7);
    return random_positions.defaultPosition(mobs, mob, 10, 7);
}

// LookAtPlayerGoal.

fn lookAtPlayerCanUse(mobs: *Mobs, mob: *Mob) !bool {
    if (mob.random.nextFloat() >= 0.02) return false;
    const eye: [3]f64 = .{ mob.position[0], living.eyeY(mobs, mob), mob.position[2] };
    mob.goals.look_at_player = try senses.nearestPlayer(mobs, mob, .{ .range = 6.0, .line_of_sight = true }, eye);
    return mob.goals.look_at_player != null;
}

fn lookAtPlayerCanContinue(mobs: *Mobs, mob: *Mob) bool {
    const slot = mob.goals.look_at_player orelse return false;
    if (!playerAlive(mobs, slot)) return false;
    const player = &mobs.deps.players.records[slot];
    const dx = mob.position[0] - player.position.x;
    const dy = mob.position[1] - player.position.y;
    const dz = mob.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz > 6.0 * 6.0) return false;
    return mob.goals.look_time > 0;
}
