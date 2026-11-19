//! DefaultRandomPos and LandRandomPos: ten random tries near a mob, scored by the mob's walk
//! target value, keeping the best. Wandering and panicking pick where to go this way.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const navigation = @import("navigation.zig");
const pathfinding = @import("pathfinding.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

/// RandomPos.generateRandomDirection.
fn randomDirection(mob: *Mob, horizontal: i32, vertical: i32) [3]i32 {
    const x = mob.random.nextIntBounded(2 * horizontal + 1) - horizontal;
    const y = mob.random.nextIntBounded(2 * vertical + 1) - vertical;
    const z = mob.random.nextIntBounded(2 * horizontal + 1) - horizontal;
    return .{ x, y, z };
}

/// RandomPos.generateRandomPosTowardDirection, for mobs with no home to keep to.
fn towardDirection(mob: *const Mob, direction: [3]i32) [3]i32 {
    return .{
        mth.floor(@as(f64, @floatFromInt(direction[0])) + mob.position[0]),
        mth.floor(@as(f64, @floatFromInt(direction[1])) + mob.position[1]),
        mth.floor(@as(f64, @floatFromInt(direction[2])) + mob.position[2]),
    };
}

/// GoalUtils.isOutsideLimits: outside the world's build height.
fn outsideLimits(mobs: *Mobs, mob: *const Mob, position: [3]i32) bool {
    const level = mobs.level(mob.world);
    return position[1] < level.minimum_y or position[1] >= level.minimum_y + level.height;
}

/// GoalUtils.hasMalus: the block costs the mob anything to path through.
fn hasMalus(mobs: *Mobs, mob: *const Mob, position: [3]i32) !bool {
    const level = mobs.level(mob.world);
    const evaluator_mob = navigation.pathfindingMob(mobs, mob);
    const path_type = try pathfinding.staticPathType(&level, position[0], position[1], position[2]);
    return evaluator_mob.pathfindingMalus(path_type) != 0;
}

/// RandomPos.generateRandomPos: the best of ten tries by walk target value.
fn bestOfTen(mobs: *Mobs, mob: *Mob, comptime land: bool, horizontal: i32, vertical: i32) !?[3]f64 {
    var best_value = -std.math.inf(f64);
    var best: ?[3]i32 = null;
    for (0..10) |_| {
        const candidate = (try tryOnce(mobs, mob, land, horizontal, vertical)) orelse continue;
        const value: f64 = try mobs.walkTargetValue(mob, candidate);
        if (value > best_value) {
            best_value = value;
            best = candidate;
        }
    }
    const found = best orelse return null;
    return .{ @as(f64, @floatFromInt(found[0])) + 0.5, @floatFromInt(found[1]), @as(f64, @floatFromInt(found[2])) + 0.5 };
}

fn tryOnce(mobs: *Mobs, mob: *Mob, comptime land: bool, horizontal: i32, vertical: i32) !?[3]i32 {
    const direction = randomDirection(mob, horizontal, vertical);
    const position = towardDirection(mob, direction);
    if (outsideLimits(mobs, mob, position)) return null;
    if (!try navigation.isStableDestination(mobs, mob, position)) return null;
    if (!land) {
        // DefaultRandomPos refuses blocks with a malus at once.
        if (try hasMalus(mobs, mob, position)) return null;
        return position;
    }
    // LandRandomPos.movePosUpOutOfSolid, then no water and no malus.
    const level = mobs.level(mob.world);
    var moved = position;
    if (level.blocks.get(try level.state(moved[0], moved[1], moved[2])).flags.solid) {
        moved[1] += 1;
        const top = level.minimum_y + level.height - 1;
        while (moved[1] <= top and level.blocks.get(try level.state(moved[0], moved[1], moved[2])).flags.solid) moved[1] += 1;
    }
    if ((try level.fluid(moved[0], moved[1], moved[2])).fluid == .water) return null;
    if (try hasMalus(mobs, mob, moved)) return null;
    return moved;
}

pub fn defaultPosition(mobs: *Mobs, mob: *Mob, horizontal: i32, vertical: i32) !?[3]f64 {
    return bestOfTen(mobs, mob, false, horizontal, vertical);
}

pub fn landPosition(mobs: *Mobs, mob: *Mob, horizontal: i32, vertical: i32) !?[3]f64 {
    return bestOfTen(mobs, mob, true, horizontal, vertical);
}
