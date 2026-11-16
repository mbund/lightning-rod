//! PathNavigation with GroundPathNavigation: finds paths for goals, follows them node by node
//! through the move control, gives up when stuck, and finds them again when blocks change.
//! A mob's path lives in the path store at the mob's index.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const living = @import("living.zig");
const ai = @import("ai.zig");
const pathfinding = @import("pathfinding.zig");
const mob_blocks = @import("mob_blocks.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const PathType = mob_blocks.PathType;
const assert = std.debug.assert;

pub fn inProgress(mob: *const Mob) bool {
    return !done(mob);
}

/// PathNavigation.isDone.
pub fn done(mob: *const Mob) bool {
    const path = mob.navigation.path;
    return !path.active or path.next >= path.count;
}

pub fn stop(mob: *Mob) void {
    mob.navigation.path.active = false;
}

fn nodes(mobs: *Mobs, mob: *const Mob) []pathfinding.PathNode {
    return mobs.pathNodes(mob)[0..mob.navigation.path.count];
}

/// GroundPathNavigation.canUpdatePath: on the ground or in a liquid.
fn canUpdatePath(mob: *const Mob) bool {
    return mob.on_ground or mob.touching_water or living.inLava(mob);
}

/// GroundPathNavigation.getTempMobPos, with getSurfaceY.
fn tempMobPosition(mobs: *Mobs, mob: *const Mob) ![3]f64 {
    return .{ mob.position[0], @floatFromInt(try surfaceY(mobs, mob)), mob.position[2] };
}

fn surfaceY(mobs: *Mobs, mob: *const Mob) !i32 {
    if (mob.touching_water and canFloat(mob)) {
        const level = mobs.level(mob.world);
        var y = mth.floor(mob.position[1]);
        const x = mth.floor(mob.position[0]);
        const z = mth.floor(mob.position[2]);
        var state = try level.state(x, y, z);
        var count: i32 = 0;
        while (level.blocks.get(state).kind == .water) {
            y += 1;
            state = try level.state(x, y, z);
            count += 1;
            if (count > 16) return mth.floor(mob.position[1]);
        }
        return y;
    }
    return mth.floor(mob.position[1] + 0.5);
}

/// FloatGoal sets the navigation floating for mobs that have it, which every cow does.
fn canFloat(_: *const Mob) bool {
    return true;
}

/// PathNavigation.getMaxPathLength: the follow range, at least the required 16.
pub fn maxPathLength(mobs: *const Mobs, mob: *const Mob) f32 {
    return @max(@as(f32, @floatCast(followRange(mobs, mob))), 16.0);
}

/// The follow range attribute with the random spawn bonus, a multiplier of its base.
pub fn followRange(mobs: *const Mobs, mob: *const Mob) f64 {
    const base = mobs.traits(mob.species).attribute(.follow_range);
    return std.math.clamp(base + base * mob.follow_range_bonus, 0, 2048);
}

/// PathNavigation.updatePathfinderMaxVisitedNodes, which Mob.onAttributeUpdated calls once
/// the follow range has its bonus.
pub fn maxVisitedNodes(mobs: *const Mobs, mob: *const Mob) i32 {
    return mth.floorFloat(maxPathLength(mobs, mob) * 16.0);
}

/// The evaluator's view of the mob.
pub fn pathfindingMob(mobs: *const Mobs, mob: *const Mob) pathfinding.Mob {
    var result: pathfinding.Mob = .{
        .width = living.width(mobs, mob),
        .height = living.height(mobs, mob),
        .max_up_step = @floatCast(mobs.traits(mob.species).attribute(.step_height)),
        .position = mob.position,
        .on_ground = mob.on_ground,
        .in_water = mob.touching_water,
        .can_float = canFloat(mob),
    };
    // Animal: fire nearby is worse, and fire itself is out.
    result.malus[@backingInt(PathType.danger_fire)] = 16.0;
    result.malus[@backingInt(PathType.damage_fire)] = -1.0;
    return result;
}

pub const Created = enum { none, current, fresh };

/// GroundPathNavigation.createPath(BlockPos, int): the target moves down to the ground, or up
/// out of solid blocks, then PathNavigation.createPath finds the way.
pub fn createPath(mobs: *Mobs, mob: *Mob, target_in: [3]i32, accuracy: i32) !Created {
    const level = mobs.level(mob.world);
    // The target's chunk must be loaded, which here means the mob may read it.
    if (!mobs.loaded(mob.world, target_in)) return .none;
    var target = target_in;
    if (level.blocks.get(try level.state(target[0], target[1], target[2])).flags.air) {
        var probe = target;
        probe[1] -= 1;
        while (probe[1] >= level.minimum_y and level.blocks.get(try level.state(probe[0], probe[1], probe[2])).flags.air) probe[1] -= 1;
        if (probe[1] >= level.minimum_y) return find(mobs, mob, .{ probe[0], probe[1] + 1, probe[2] }, accuracy);
        probe[1] = target[1] + 1;
        while (probe[1] <= level.minimum_y + level.height - 1 and level.blocks.get(try level.state(probe[0], probe[1], probe[2])).flags.air) probe[1] += 1;
        target = probe;
    }
    if (!level.blocks.get(try level.state(target[0], target[1], target[2])).flags.solid) return find(mobs, mob, target, accuracy);
    var probe = target;
    probe[1] += 1;
    while (probe[1] <= level.minimum_y + level.height - 1 and level.blocks.get(try level.state(probe[0], probe[1], probe[2])).flags.solid) probe[1] += 1;
    return find(mobs, mob, probe, accuracy);
}

/// PathNavigation.createPath(Set, int, boolean, int, float) for one target.
fn find(mobs: *Mobs, mob: *Mob, target: [3]i32, accuracy: i32) !Created {
    const level = mobs.level(mob.world);
    if (mob.position[1] < @as(f64, @floatFromInt(level.minimum_y))) return .none;
    if (!canUpdatePath(mob)) return .none;
    const navigation = &mob.navigation;
    if (!done(mob)) if (navigation.target) |current| if (std.meta.eql(current, target)) return .current;
    mobs.path_searches += 1;
    const evaluator_mob = pathfindingMob(mobs, mob);
    const found = (try mobs.search.findPath(&level, &evaluator_mob, .{
        .target = target,
        .max_range = maxPathLength(mobs, mob),
        .accuracy = accuracy,
        .max_visited_nodes = maxVisitedNodes(mobs, mob),
    }, mobs.scratch_path)) orelse return .none;
    mobs.scratch = .{ .count = @intCast(found.count), .target = found.target, .reached = found.reached };
    navigation.target = found.target;
    navigation.reach_range = accuracy;
    resetStuckTimeout(mob);
    return .fresh;
}

/// PathNavigation.moveTo(Path, double) with the path createPath gave.
pub fn moveTo(mobs: *Mobs, mob: *Mob, created: Created, speed: f64) !bool {
    const navigation = &mob.navigation;
    switch (created) {
        .none => {
            navigation.path.active = false;
            return false;
        },
        .current => {},
        .fresh => {
            const fresh = mobs.scratch_path[0..mobs.scratch.count];
            if (!sameAs(fresh, nodes(mobs, mob), navigation.path.active)) {
                @memcpy(mobs.pathNodes(mob)[0..fresh.len], fresh);
                navigation.path = .{ .active = true, .count = mobs.scratch.count, .next = 0, .target = mobs.scratch.target, .reached = mobs.scratch.reached };
            }
        },
    }
    if (done(mob)) return false;
    try trimPath(mobs, mob);
    if (navigation.path.count == 0) return false;
    navigation.speed = speed;
    navigation.last_stuck_check = navigation.tick;
    navigation.last_stuck_check_position = try tempMobPosition(mobs, mob);
    return true;
}

fn sameAs(fresh: []const pathfinding.PathNode, current: []const pathfinding.PathNode, active: bool) bool {
    if (!active or fresh.len != current.len) return false;
    for (fresh, current) |a, b| if (a.x != b.x or a.y != b.y or a.z != b.z) return false;
    return true;
}

/// PathNavigation.moveTo(double, double, double, double).
pub fn moveToPosition(mobs: *Mobs, mob: *Mob, x: f64, y: f64, z: f64, speed: f64) !bool {
    const created = try createPath(mobs, mob, .{ mth.floor(x), mth.floor(y), mth.floor(z) }, 1);
    return moveTo(mobs, mob, created, speed);
}

/// PathNavigation.moveTo(Entity, double), which GroundPathNavigation aims at the block the
/// entity stands in.
pub fn moveToEntity(mobs: *Mobs, mob: *Mob, position: [3]f64, speed: f64) !bool {
    const created = try createPath(mobs, mob, .{ mth.floor(position[0]), mth.floor(position[1]), mth.floor(position[2]) }, 1);
    if (created == .none) return false;
    return moveTo(mobs, mob, created, speed);
}

/// PathNavigation.trimPath: a path through a cauldron goes over it.
fn trimPath(mobs: *Mobs, mob: *Mob) !void {
    const level = mobs.level(mob.world);
    const path = nodes(mobs, mob);
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        const node = path[index];
        if (!level.blocks.get(try level.state(node.x, node.y, node.z)).flags.cauldron) continue;
        path[index].y = node.y + 1;
        if (index + 1 < path.len and node.y >= path[index + 1].y) path[index + 1] = .{ .x = path[index + 1].x, .y = node.y + 1, .z = path[index + 1].z, .type = node.type };
    }
}

/// Path.getEntityPosAtNode.
fn entityPositionAt(mobs: *Mobs, mob: *const Mob, index: usize) [3]f64 {
    const node = mobs.pathNodes(mob)[index];
    const offset = @as(f64, @floatFromInt(mth.javaInt(living.width(mobs, mob) + 1.0))) * 0.5;
    return .{ @as(f64, @floatFromInt(node.x)) + offset, @floatFromInt(node.y), @as(f64, @floatFromInt(node.z)) + offset };
}

/// PathNavigation.tick.
pub fn tick(mobs: *Mobs, mob: *Mob) !void {
    const navigation = &mob.navigation;
    navigation.tick += 1;
    if (navigation.has_delayed_recomputation) try recomputePath(mobs, mob, mobs.gameTime());
    if (done(mob)) return;
    if (canUpdatePath(mob)) {
        try followThePath(mobs, mob);
    } else if (navigation.path.active and !done(mob)) {
        const at = try tempMobPosition(mobs, mob);
        const next = entityPositionAt(mobs, mob, navigation.path.next);
        if (at[1] > next[1] and !mob.on_ground and mth.floor(at[0]) == mth.floor(next[0]) and mth.floor(at[2]) == mth.floor(next[2])) navigation.path.next += 1;
    }
    if (done(mob)) return;
    const next = entityPositionAt(mobs, mob, navigation.path.next);
    ai.setWanted(mob, next[0], try groundY(mobs, mob, next), next[2], navigation.speed);
}

/// PathNavigation.getGroundY: over air the node's own height, else the floor in its block.
fn groundY(mobs: *Mobs, mob: *const Mob, position: [3]f64) !f64 {
    const level = mobs.level(mob.world);
    const at: [3]i32 = .{ mth.floor(position[0]), mth.floor(position[1]), mth.floor(position[2]) };
    if (level.blocks.get(try level.state(at[0], at[1] - 1, at[2])).flags.air) return position[1];
    return pathfinding.staticFloorLevel(&level, at[0], at[1], at[2]);
}

/// PathNavigation.followThePath.
fn followThePath(mobs: *Mobs, mob: *Mob) !void {
    const navigation = &mob.navigation;
    const at = try tempMobPosition(mobs, mob);
    const width = living.width(mobs, mob);
    navigation.max_distance_to_waypoint = if (width > 0.75) width / 2.0 else 0.75 - width / 2.0;
    const next = mobs.pathNodes(mob)[navigation.path.next];
    const dx = @abs(mob.position[0] - (@as(f64, @floatFromInt(next.x)) + 0.5));
    const dy = @abs(mob.position[1] - @as(f64, @floatFromInt(next.y)));
    const dz = @abs(mob.position[2] - (@as(f64, @floatFromInt(next.z)) + 0.5));
    const close = dx < navigation.max_distance_to_waypoint and dz < navigation.max_distance_to_waypoint and dy < 1.0;
    if (close or (canCutCorner(next.type) and shouldTargetNextNodeInDirection(mobs, mob, at))) navigation.path.next += 1;
    try doStuckDetection(mobs, mob, at);
}

/// PathNavigation.canCutCorner.
fn canCutCorner(path_type: PathType) bool {
    return path_type != .danger_fire and path_type != .danger_other and path_type != .walkable_door;
}

fn bottomCenter(node: pathfinding.PathNode) [3]f64 {
    return .{ @as(f64, @floatFromInt(node.x)) + 0.5, @floatFromInt(node.y), @as(f64, @floatFromInt(node.z)) + 0.5 };
}

/// PathNavigation.shouldTargetNextNodeInDirection: the mob may skip a node when the one after
/// it is closer, or the node is barely ahead, and the two lie on opposite sides of it.
fn shouldTargetNextNodeInDirection(mobs: *Mobs, mob: *const Mob, at: [3]f64) bool {
    const path = mob.navigation.path;
    if (path.next + 1 >= path.count) return false;
    const next = bottomCenter(mobs.pathNodes(mob)[path.next]);
    const to_next: [3]f64 = .{ next[0] - at[0], next[1] - at[1], next[2] - at[2] };
    if (!(to_next[0] * to_next[0] + to_next[1] * to_next[1] + to_next[2] * to_next[2] < 4.0)) return false;
    // GroundPathNavigation cannot move directly.
    const after = bottomCenter(mobs.pathNodes(mob)[path.next + 1]);
    const to_after: [3]f64 = .{ after[0] - at[0], after[1] - at[1], after[2] - at[2] };
    const next_squared = to_next[0] * to_next[0] + to_next[1] * to_next[1] + to_next[2] * to_next[2];
    const after_squared = to_after[0] * to_after[0] + to_after[1] * to_after[1] + to_after[2] * to_after[2];
    if (!(after_squared < next_squared) and !(next_squared < 0.5)) return false;
    const a = living.normalize(to_next);
    const b = living.normalize(to_after);
    return b[0] * a[0] + b[1] * a[1] + b[2] * a[2] < 0.0;
}

/// PathNavigation.doStuckDetection: a mob that covered less than a quarter of its speed over
/// 100 ticks, or that takes three times too long to reach a node, stops.
fn doStuckDetection(mobs: *Mobs, mob: *Mob, at: [3]f64) !void {
    const navigation = &mob.navigation;
    if (navigation.tick - navigation.last_stuck_check > 100) {
        const speed = if (mob.speed >= 1.0) mob.speed else mob.speed * mob.speed;
        const limit = speed * 100.0 * 0.25;
        const moved = distanceSquared(at, navigation.last_stuck_check_position);
        if (moved < @as(f64, limit * limit)) {
            navigation.stuck = true;
            stop(mob);
        } else {
            navigation.stuck = false;
        }
        navigation.last_stuck_check = navigation.tick;
        navigation.last_stuck_check_position = at;
    }
    if (!navigation.path.active or done(mob)) return;
    const node = mobs.pathNodes(mob)[navigation.path.next];
    const position: [3]i32 = .{ node.x, node.y, node.z };
    const now = mobs.gameTime();
    if (std.meta.eql(position, navigation.timeout_node)) {
        navigation.timeout_timer += now - navigation.last_timeout_check;
    } else {
        navigation.timeout_node = position;
        const reach = @sqrt(distanceSquared(at, bottomCenter(node)));
        navigation.timeout_limit = if (mob.speed > 0) reach / mob.speed * 20.0 else 0.0;
    }
    if (navigation.timeout_limit > 0 and @as(f64, @floatFromInt(navigation.timeout_timer)) > navigation.timeout_limit * 3.0) {
        resetStuckTimeout(mob);
        stop(mob);
    }
    navigation.last_timeout_check = now;
}

fn distanceSquared(a: [3]f64, b: [3]f64) f64 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

fn resetStuckTimeout(mob: *Mob) void {
    mob.navigation.timeout_node = .{ 0, 0, 0 };
    mob.navigation.timeout_timer = 0;
    mob.navigation.timeout_limit = 0;
    mob.navigation.stuck = false;
}

/// PathNavigation.recomputePath: at most once a second, the way to the same target again. `now`
/// is the game time it happens at, which for an edit is when the edit was made.
pub fn recomputePath(mobs: *Mobs, mob: *Mob, now: i64) !void {
    const navigation = &mob.navigation;
    if (now - navigation.time_last_recompute > 20) {
        if (navigation.target) |target| {
            navigation.path.active = false;
            const created = try createPath(mobs, mob, target, navigation.reach_range);
            switch (created) {
                .none, .current => navigation.path.active = false,
                .fresh => {
                    const fresh = mobs.scratch_path[0..mobs.scratch.count];
                    @memcpy(mobs.pathNodes(mob)[0..fresh.len], fresh);
                    navigation.path = .{ .active = true, .count = mobs.scratch.count, .next = 0, .target = mobs.scratch.target, .reached = mobs.scratch.reached };
                },
            }
            navigation.time_last_recompute = now;
            navigation.has_delayed_recomputation = false;
        }
    } else {
        navigation.has_delayed_recomputation = true;
    }
}

/// PathNavigation.shouldRecomputePath: a block changed near enough the rest of the path.
pub fn shouldRecomputePath(mobs: *Mobs, mob: *const Mob, position: [3]i32) bool {
    const navigation = mob.navigation;
    if (navigation.has_delayed_recomputation) return false;
    if (!navigation.path.active or done(mob) or navigation.path.count == 0) return false;
    const end = mobs.pathNodes(mob)[navigation.path.count - 1];
    const middle: [3]f64 = .{ (@as(f64, @floatFromInt(end.x)) + mob.position[0]) / 2.0, (@as(f64, @floatFromInt(end.y)) + mob.position[1]) / 2.0, (@as(f64, @floatFromInt(end.z)) + mob.position[2]) / 2.0 };
    const center: [3]f64 = .{ @as(f64, @floatFromInt(position[0])) + 0.5, @as(f64, @floatFromInt(position[1])) + 0.5, @as(f64, @floatFromInt(position[2])) + 0.5 };
    const remaining: f64 = @floatFromInt(navigation.path.count - navigation.path.next);
    return distanceSquared(center, middle) < remaining * remaining;
}

/// PathNavigation.isStableDestination: something solid to stand on.
pub fn isStableDestination(mobs: *Mobs, mob: *const Mob, position: [3]i32) !bool {
    const level = mobs.level(mob.world);
    return level.blocks.get(try level.state(position[0], position[1] - 1, position[2])).flags.solid_render;
}
