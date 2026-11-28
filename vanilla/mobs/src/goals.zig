//! GoalSelector over the goals each species registers, in its registerGoals' order, which is
//! their priority: the animal goals every species may share, float, panic, breed, tempt, follow
//! parent, stroll, look at a player and look around, run here, and a species' own goals run by
//! its plugin. A goal holds the move, look and jump flags it uses, and starts when every one is
//! free or held by a goal of a lower priority.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const body = @import("vanilla_bodies").body;
const entities = @import("entities");
const living = @import("living.zig");
const ai = @import("ai.zig");
const navigation = @import("navigation.zig");
const pathfinding = @import("pathfinding.zig");
const senses = @import("senses.zig");
const random_positions = @import("random_positions.zig");
const mob_state = @import("mob.zig");
const species_data = @import("species.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const Goal = species_data.Goal;
const Shared = species_data.Shared;

fn requiresUpdateEveryTick(goal: Goal) bool {
    return species_data.everyTick(goal);
}

fn goalsOf(mobs: *const Mobs, mob: Mob) []const Goal {
    return mobs.traits(mob.entity.species).definition.goals;
}

fn running(mob: Mob, priority: u4) bool {
    return mob.idle.running & (@as(u16, 1) << priority) != 0;
}

/// Whether the mob runs its PanicGoal.
pub fn isPanicking(mobs: *const Mobs, mob: Mob) bool {
    return mob.idle.running & mobs.traits(mob.entity.species).sharedBit(.panic) != 0;
}

/// WrappedGoal.stop.
fn stopGoal(mobs: *Mobs, mob: Mob, priority: u4) void {
    if (!running(mob, priority)) return;
    mob.idle.running &= ~(@as(u16, 1) << priority);
    stop(mobs, mob, goalsOf(mobs, mob)[priority]);
}

/// WrappedGoal.start.
fn startGoal(mobs: *Mobs, mob: Mob, priority: u4) !void {
    if (running(mob, priority)) return;
    mob.idle.running |= @as(u16, 1) << priority;
    try start(mobs, mob, goalsOf(mobs, mob)[priority]);
}

/// GoalSelector.goalCanBeReplacedForAllFlags: every flag is free, or held by a goal this one
/// outranks. Every goal here may be interrupted.
fn replaceable(traits: *const species_data.Traits, mob: Mob, priority: u4) bool {
    const bit = @as(u16, 1) << priority;
    const owners = [_]struct { wanted: bool, owner: ?u4 }{
        .{ .wanted = traits.move & bit != 0, .owner = mob.idle.move_owner },
        .{ .wanted = traits.look & bit != 0, .owner = mob.idle.look_owner },
        .{ .wanted = traits.jump & bit != 0, .owner = mob.goals.jump_owner },
    };
    for (owners) |entry| {
        if (!entry.wanted) continue;
        const owner = entry.owner orelse continue;
        if (!(priority < owner)) return false;
    }
    return true;
}

/// GoalSelector.tick.
pub fn tick(mobs: *Mobs, mob: Mob) !void {
    // Mobs here carry no passengers and ride nothing, so no flag is disabled.
    const traits = mobs.traits(mob.entity.species);
    const goals = traits.definition.goals;
    // The running goals, by their bits in priority order, as the selector meets them.
    var each = mob.idle.running;
    while (each != 0) : (each &= each - 1) {
        const priority: u4 = @intCast(@ctz(each));
        if (!try canContinueToUse(mobs, mob, goals[priority])) stopGoal(mobs, mob, priority);
    }
    // lockedFlags.removeIf(goal is not running).
    if (mob.idle.move_owner) |owner| if (!running(mob, owner)) {
        mob.idle.move_owner = null;
    };
    if (mob.idle.look_owner) |owner| if (!running(mob, owner)) {
        mob.idle.look_owner = null;
    };
    if (mob.goals.jump_owner) |owner| if (!running(mob, owner)) {
        mob.goals.jump_owner = null;
    };
    // The animal goals alone, as most species register, are known while compiling, and each is
    // met by its own code; a species with goals of its own is met through them in turn.
    if (goals.ptr == @as([*]const Goal, &species_data.animal_goals)) {
        inline for (species_data.animal_goals, 0..) |goal, at| try consider(mobs, mob, traits, goal, at);
    } else for (goals, 0..) |goal, at| try consider(mobs, mob, traits, goal, @intCast(at));
    try tickRunning(mobs, mob, true);
}

/// GoalSelector.tick for one goal not running: it starts if its flags are free and it can be
/// used, taking them from the goals holding them.
inline fn consider(mobs: *Mobs, mob: Mob, traits: *const species_data.Traits, goal: Goal, priority: u4) !void {
    if (running(mob, priority) or !replaceable(traits, mob, priority)) return;
    if (!try canUse(mobs, mob, goal)) return;
    const bit = @as(u16, 1) << priority;
    if (traits.move & bit != 0) {
        if (mob.idle.move_owner) |owner| stopGoal(mobs, mob, owner);
        mob.idle.move_owner = priority;
    }
    if (traits.look & bit != 0) {
        if (mob.idle.look_owner) |owner| stopGoal(mobs, mob, owner);
        mob.idle.look_owner = priority;
    }
    if (traits.jump & bit != 0) {
        if (mob.goals.jump_owner) |owner| stopGoal(mobs, mob, owner);
        mob.goals.jump_owner = priority;
    }
    try startGoal(mobs, mob, priority);
}

/// GoalSelector.tickRunningGoals.
pub fn tickRunning(mobs: *Mobs, mob: Mob, every: bool) !void {
    const traits = mobs.traits(mob.entity.species);
    var each = mob.idle.running & (if (every) ~@as(u16, 0) else traits.every_tick);
    while (each != 0) : (each &= each - 1) try tickGoal(mobs, mob, traits.definition.goals[@ctz(each)]);
}

/// Goal.reducedTickDelay: halved, rounded up, for goals updated every other tick.
pub fn reducedTickDelay(ticks: i32) i32 {
    return @divFloor(ticks + 1, 2);
}

fn adjustedTickDelay(goal: Shared, ticks: i32) i32 {
    return if (requiresUpdateEveryTick(.{ .shared = goal })) ticks else reducedTickDelay(ticks);
}

inline fn canUse(mobs: *Mobs, mob: Mob, goal: Goal) !bool {
    const shared = switch (goal) {
        .shared => |shared| shared,
        .own => |own| return own.can_use(own.context, mobs, mob),
    };
    return switch (shared) {
        .float => floatCanUse(mobs, mob),
        .panic => try panicCanUse(mobs, mob),
        .breed => try breedCanUse(mobs, mob),
        .tempt => try temptCanUse(mobs, mob),
        .follow_parent => try followParentCanUse(mobs, mob),
        .stroll => try strollCanUse(mobs, mob),
        .look_at_player => try lookAtPlayerCanUse(mobs, mob),
        .look_around => mob.idle.random.nextFloat() < 0.02,
    };
}

fn canContinueToUse(mobs: *Mobs, mob: Mob, goal: Goal) !bool {
    const shared = switch (goal) {
        .shared => |shared| shared,
        .own => |own| return own.can_continue(own.context, mobs, mob),
    };
    return switch (shared) {
        .float => floatCanUse(mobs, mob),
        .panic => !navigation.done(mob),
        .breed => try breedCanContinue(mobs, mob),
        .tempt => try temptCanUse(mobs, mob),
        .follow_parent => try followParentCanContinue(mobs, mob),
        .stroll => !navigation.done(mob),
        .look_at_player => lookAtPlayerCanContinue(mobs, mob),
        .look_around => mob.idle.look_around.time >= 0,
    };
}

fn start(mobs: *Mobs, mob: Mob, goal: Goal) !void {
    const shared = switch (goal) {
        .shared => |shared| shared,
        .own => |own| return own.start(own.context, mobs, mob),
    };
    switch (shared) {
        .float => {},
        .panic, .stroll => {
            const target = mobs.chosen.target;
            _ = try navigation.moveToPosition(mobs, mob, target[0], target[1], target[2], if (shared == .panic) mobs.traits(mob.entity.species).definition.panic_speed else 1.0);
        },
        .breed => _ = try mob.put(.focus, .{ .breed = .{ .partner = mobs.chosen.partner.? } }),
        .tempt => {
            const slot = mobs.chosen.player.?;
            const player = &mobs.deps.players.records[slot];
            _ = try mob.put(.focus, .{ .tempt = .{ .player = slot, .player_position = .{ player.position.x, player.position.y, player.position.z } } });
        },
        .follow_parent => {
            _ = try mob.put(.follow, .{ .parent = mobs.chosen.partner.? });
        },
        .look_at_player => _ = try mob.put(.focus, .{ .look_at_player = .{ .player = mobs.chosen.player.?, .time = adjustedTickDelay(.look_at_player, 40 + mob.idle.random.nextIntBounded(40)) } }),
        .look_around => {
            const angle = (std.math.pi * 2.0) * mob.idle.random.nextDouble();
            const relative: [2]f64 = .{ @cos(angle), @sin(angle) };
            mob.idle.look_around = .{ .relative = relative, .time = 20 + mob.idle.random.nextIntBounded(20) };
        },
    }
}

fn stop(mobs: *Mobs, mob: Mob, goal: Goal) void {
    const shared = switch (goal) {
        .shared => |shared| shared,
        .own => |own| return own.stop(own.context, mobs, mob),
    };
    switch (shared) {
        .float, .panic => {},
        .follow_parent => mob.drop(.follow),
        .breed, .look_at_player => mob.drop(.focus),
        .look_around => {},
        .tempt => {
            mob.drop(.focus);
            navigation.stop(mob);
            mob.idle.tempt_calm_down = reducedTickDelay(100);
        },
        .stroll => navigation.stop(mob),
    }
}

fn tickGoal(mobs: *Mobs, mob: Mob, goal: Goal) !void {
    const shared = switch (goal) {
        .shared => |shared| shared,
        .own => |own| return own.tick(own.context, mobs, mob),
    };
    switch (shared) {
        .float => {
            if (mob.idle.random.nextFloat() < 0.8) mob.control.jump = true;
        },
        .breed => try breedTick(mobs, mob),
        .tempt => try temptTick(mobs, mob),
        .follow_parent => try followParentTick(mobs, mob),
        .look_at_player => {
            const looking = &mob.part(.focus).?.look_at_player;
            if (!playerAlive(mobs, looking.player)) return;
            const eye = senses.playerEye(mobs, looking.player);
            ai.setLookAt(mob, eye[0], eye[1], eye[2], ai.head_rotation_speed, ai.max_head_pitch);
            looking.time -= 1;
        },
        .look_around => {
            const around = &mob.idle.look_around;
            around.time -= 1;
            ai.setLookAt(mob, mob.motion.position[0] + around.relative[0], living.eyeY(mobs, mob), mob.motion.position[2] + around.relative[1], ai.head_rotation_speed, ai.max_head_pitch);
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

fn floatCanUse(mobs: *Mobs, mob: Mob) bool {
    return (mob.entity.touching_water and mob.entity.water_height > living.fluidJumpThreshold(mobs, mob)) or living.inLava(mob);
}

// PanicGoal.

fn panicCanUse(mobs: *Mobs, mob: Mob) !bool {
    if (!mobs.shouldPanic(mob)) return false;
    if (mob.entity.fire_ticks > 0) {
        if (try lookForWater(mobs, mob)) |water| {
            mobs.chosen.target = .{ @floatFromInt(water[0]), @floatFromInt(water[1]), @floatFromInt(water[2]) };
            return true;
        }
    }
    const target = try random_positions.defaultPosition(mobs, mob, 5, 4) orelse return false;
    mobs.chosen.target = target;
    return true;
}

/// PanicGoal.lookForWater: from a block with no collision shape, the nearest water within 5
/// blocks across and 1 up or down, in BlockPos.withinManhattan's order.
fn lookForWater(mobs: *Mobs, mob: Mob) !?[3]i32 {
    const level = mobs.level(mob.motion.world);
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

fn breedCanUse(mobs: *Mobs, mob: Mob) !bool {
    if (mob.inLove() <= 0) return false;
    mobs.chosen.partner = try freePartner(mobs, mob);
    return mobs.chosen.partner != null;
}

/// BreedGoal.getFreePartner: the nearest mob of the kind within 8 blocks that can mate and
/// does not panic.
fn freePartner(mobs: *Mobs, mob: Mob) !?u64 {
    const Search = struct {
        mobs: *Mobs,
        mob: Mob,
        best: ?u64 = null,
        best_distance: f64 = std.math.floatMax(f64),

        fn visit(raw: *anyopaque, entry: entities.space.Entry, _: body.Box) anyerror!bool {
            const context: *@This() = @ptrCast(@alignCast(raw));
            const other = try context.mobs.inSlot(entry.slot);
            if (!other.alive()) return false;
            const distance = senses.distanceSquared(context.mob, other);
            // PARTNER_TARGETING's range, which mobs see at full visibility.
            if (distance > 64) return false;
            if (!canMate(context.mob, other) or isPanicking(context.mobs, other)) return false;
            if (distance < context.best_distance) {
                context.best = other.entity.id;
                context.best_distance = distance;
            }
            return false;
        }
    };
    var search: Search = .{ .mobs = mobs, .mob = mob };
    try mobs.eachOfSpecies(mob, living.box(mobs, mob).inflate(8, 8, 8), .{ .context = &search, .visit = Search.visit });
    return search.best;
}

/// Animal.canMate: another of the same kind, both in love.
pub fn canMate(mob: Mob, other: Mob) bool {
    return !mob.same(other) and other.entity.species == mob.entity.species and mob.inLove() > 0 and other.inLove() > 0;
}

fn breedCanContinue(mobs: *Mobs, mob: Mob) !bool {
    // A partner gone from the world is no longer alive, as vanilla's removed entity.
    const breeding = mob.part(.focus).?.breed;
    const partner = (try mobs.byId(breeding.partner)) orelse return false;
    return partner.alive() and partner.inLove() > 0 and breeding.love_time < 60 and !isPanicking(mobs, partner);
}

fn breedTick(mobs: *Mobs, mob: Mob) !void {
    const breeding = &mob.part(.focus).?.breed;
    const partner = (try mobs.byId(breeding.partner)) orelse return;
    ai.setLookAt(mob, partner.motion.position[0], living.eyeY(mobs, partner), partner.motion.position[2], 10.0, ai.max_head_pitch);
    _ = try navigation.moveToEntity(mobs, mob, partner.motion.position, 1.0);
    breeding.love_time += 1;
    if (breeding.love_time >= adjustedTickDelay(.breed, 60) and senses.distanceSquared(mob, partner) < 9.0) try mobs.breed(mob, partner);
}

// TemptGoal.

fn temptCanUse(mobs: *Mobs, mob: Mob) !bool {
    if (mob.idle.tempt_calm_down > 0) {
        mob.idle.tempt_calm_down -= 1;
        return false;
    }
    const range = mobs.traits(mob.entity.species).attribute(.tempt_range);
    // A player it may follow holds its food as the tick began and is within reach, which sneaking
    // only narrows: with none such near, every player fails the conditions.
    const near = mobs.context.audience.temptsNear(mob.entity.species, mob.motion.world, mob.motion.position, @max(range, 2.0));
    const found = if (near) try senses.nearestPlayer(mobs, mob, .{ .range = range, .line_of_sight = false, .holding_food = true }, mob.motion.position) else null;
    // Asked again while it runs, the player it follows is the one found; it stops on none.
    const focus = mob.part(.focus);
    if (focus != null and focus.?.* == .tempt) {
        if (found) |slot| focus.?.tempt.player = slot;
    } else mobs.chosen.player = found;
    return found != null;
}

fn temptTick(mobs: *Mobs, mob: Mob) !void {
    const slot = mob.part(.focus).?.tempt.player;
    const player = &mobs.deps.players.records[slot];
    const eye = senses.playerEye(mobs, slot);
    ai.setLookAt(mob, eye[0], eye[1], eye[2], @as(f32, ai.max_head_yaw + 20), ai.max_head_pitch);
    const dx = mob.motion.position[0] - player.position.x;
    const dy = mob.motion.position[1] - player.position.y;
    const dz = mob.motion.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz < 2.5 * 2.5) {
        navigation.stop(mob);
    } else {
        _ = try navigation.moveToEntity(mobs, mob, .{ player.position.x, player.position.y, player.position.z }, mobs.traits(mob.entity.species).definition.tempt_speed);
    }
}

// FollowParentGoal.

fn followParentCanUse(mobs: *Mobs, mob: Mob) !bool {
    if (mob.idle.age >= 0) return false;
    const Search = struct {
        mobs: *Mobs,
        mob: Mob,
        best: ?u64 = null,
        best_distance: f64 = std.math.floatMax(f64),

        fn visit(raw: *anyopaque, entry: entities.space.Entry, _: body.Box) anyerror!bool {
            const context: *@This() = @ptrCast(@alignCast(raw));
            const other = try context.mobs.inSlot(entry.slot);
            if (other.idle.age < 0) return false;
            const distance = senses.distanceSquared(context.mob, other);
            if (!(distance > context.best_distance)) {
                context.best_distance = distance;
                context.best = other.entity.id;
            }
            return false;
        }
    };
    var search: Search = .{ .mobs = mobs, .mob = mob };
    try mobs.eachOfSpecies(mob, living.box(mobs, mob).inflate(8, 4, 8), .{ .context = &search, .visit = Search.visit });
    const parent = search.best orelse return false;
    const best_distance = search.best_distance;
    if (best_distance < 9.0) return false;
    mobs.chosen.partner = parent;
    return true;
}

fn followParentCanContinue(mobs: *Mobs, mob: Mob) !bool {
    if (mob.idle.age >= 0) return false;
    const parent = (try mobs.byId((mob.part(.follow) orelse return false).parent)) orelse return false;
    if (!parent.alive()) return false;
    const distance = senses.distanceSquared(mob, parent);
    return !(distance < 9.0) and !(distance > 256.0);
}

fn followParentTick(mobs: *Mobs, mob: Mob) !void {
    const follow = mob.part(.follow) orelse return;
    follow.recalculate -= 1;
    if (follow.recalculate > 0) return;
    follow.recalculate = adjustedTickDelay(.follow_parent, 10);
    const parent = (try mobs.byId(follow.parent)) orelse return;
    _ = try navigation.moveToEntity(mobs, mob, parent.motion.position, mobs.traits(mob.entity.species).definition.follow_parent_speed);
}

// WaterAvoidingRandomStrollGoal.

fn strollCanUse(mobs: *Mobs, mob: Mob) !bool {
    // RandomStrollGoal checks no action time: mobs no player came near lately stand still.
    if (mob.idle.no_action_time >= 100) return false;
    if (mob.idle.random.nextIntBounded(reducedTickDelay(120)) != 0) return false;
    const target = (try strollPosition(mobs, mob)) orelse return false;
    mobs.chosen.target = target;
    return true;
}

/// WaterAvoidingRandomStrollGoal.getPosition.
fn strollPosition(mobs: *Mobs, mob: Mob) !?[3]f64 {
    if (mob.entity.touching_water) {
        return try random_positions.landPosition(mobs, mob, 15, 7) orelse try random_positions.defaultPosition(mobs, mob, 10, 7);
    }
    if (mob.idle.random.nextFloat() >= 0.001) return random_positions.landPosition(mobs, mob, 10, 7);
    return random_positions.defaultPosition(mobs, mob, 10, 7);
}

// LookAtPlayerGoal.

fn lookAtPlayerCanUse(mobs: *Mobs, mob: Mob) !bool {
    if (mob.idle.random.nextFloat() >= 0.02) return false;
    const eye: [3]f64 = .{ mob.motion.position[0], living.eyeY(mobs, mob), mob.motion.position[2] };
    mobs.chosen.player = try senses.nearestPlayer(mobs, mob, .{ .range = 6.0, .line_of_sight = true }, eye);
    return mobs.chosen.player != null;
}

fn lookAtPlayerCanContinue(mobs: *Mobs, mob: Mob) bool {
    const slot = mob.part(.focus).?.look_at_player.player;
    if (!playerAlive(mobs, slot)) return false;
    const player = &mobs.deps.players.records[slot];
    const dx = mob.motion.position[0] - player.position.x;
    const dy = mob.motion.position[1] - player.position.y;
    const dz = mob.motion.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz > 6.0 * 6.0) return false;
    return mob.part(.focus).?.look_at_player.time > 0;
}
