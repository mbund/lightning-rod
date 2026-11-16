//! What mobs notice: players by vanilla's TargetingConditions (range scaled for sneaking, and
//! line of sight where the condition asks for it), the mob's own kind nearby, and whether a ray
//! between two points passes collision shapes, as Level.clip with ClipContext.Block.COLLIDER.

const std = @import("std");
const game_data = @import("game_data");
const inventories = @import("inventories");
const mth = @import("mth.zig");
const body = @import("body.zig");
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

pub const Conditions = struct {
    range: f64,
    line_of_sight: bool,
    /// TemptGoal's selector: holding the mob's food in either hand.
    holding_food: bool = false,
};

/// Player.getEyeHeight for the pose the player is in.
fn playerEyeHeight(sneaking: bool) f64 {
    return if (sneaking) @as(f32, 1.27) else @as(f32, 1.62);
}

/// EntityGetter.getNearestPlayer(TargetingConditions, LivingEntity, x, y, z): the player who
/// passes the conditions nearest the point, the first of equals.
pub fn nearestPlayer(mobs: *Mobs, mob: *const Mob, conditions: Conditions, point: [3]f64) !?u32 {
    var best: ?u32 = null;
    var best_distance: f64 = -1;
    for (mobs.deps.players.activeSlots()) |slot| {
        const player = &mobs.deps.players.records[slot];
        if (player.world != mob.world or player.stage != .ready or player.handle == null) continue;
        if (!try test_(mobs, mob, conditions, @intCast(slot))) continue;
        const dx = player.position.x - point[0];
        const dy = player.position.y - point[1];
        const dz = player.position.z - point[2];
        const distance = dx * dx + dy * dy + dz * dz;
        if (best_distance == -1 or distance < best_distance) {
            best_distance = distance;
            best = @intCast(slot);
        }
    }
    return best;
}

/// TargetingConditions.test for a mob looking at a player, without combat.
pub fn test_(mobs: *Mobs, mob: *const Mob, conditions: Conditions, slot: u32) !bool {
    const player = &mobs.deps.players.records[slot];
    const state = mobs.deps.player_states.of(player);
    // LivingEntity.canBeSeenByAnyone.
    if (state.gamemode == .spectator or state.health <= 0) return false;
    if (conditions.holding_food and !try holdsFood(mobs, mob, slot)) return false;
    // LivingEntity.getVisibilityPercent: sneaking players are noticed closer.
    const visibility: f64 = if (player.flags.sneaking) 0.8 else 1.0;
    const reach = @max(conditions.range * visibility, 2.0);
    const dx = mob.position[0] - player.position.x;
    const dy = mob.position[1] - player.position.y;
    const dz = mob.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz > reach * reach) return false;
    if (conditions.line_of_sight and !try hasLineOfSight(mobs, mob, .{ player.position.x, player.position.y + playerEyeHeight(player.flags.sneaking), player.position.z })) return false;
    return true;
}

pub fn playerEye(mobs: *Mobs, slot: u32) [3]f64 {
    const player = &mobs.deps.players.records[slot];
    return .{ player.position.x, player.position.y + playerEyeHeight(player.flags.sneaking), player.position.z };
}

/// Whether the player holds food the mob is tempted by in either hand.
fn holdsFood(mobs: *Mobs, mob: *const Mob, slot: u32) !bool {
    const player = &mobs.deps.players.records[slot];
    const state = mobs.deps.player_states.of(player);
    const slots = [_]inventories.Slot{
        .{ .owner = player.uuid, .index = 36 + @as(u16, state.selected_slot) },
        .{ .owner = player.uuid, .index = 45 },
    };
    for (slots) |held| {
        const stack = (try mobs.deps.inventories.get(held)).stack orelse continue;
        if (try mobs.isFood(mob, stack)) return true;
    }
    return false;
}

/// LivingEntity.hasLineOfSight: no collision shape between the eyes, within 128 blocks.
pub fn hasLineOfSight(mobs: *Mobs, mob: *const Mob, target: [3]f64) !bool {
    const eye: [3]f64 = .{ mob.position[0], living.eyeY(mobs, mob), mob.position[2] };
    const dx = target[0] - eye[0];
    const dy = target[1] - eye[1];
    const dz = target[2] - eye[2];
    if (@sqrt(dx * dx + dy * dy + dz * dz) > 128.0) return false;
    const level = mobs.level(mob.world);
    return !try clipsCollider(&level, eye, target, living.context(mob));
}

/// Level.clip with COLLIDER shapes and no fluids: whether the segment enters a collision shape.
pub fn clipsCollider(level: *const body.Level, from: [3]f64, to: [3]f64, context: body.Context) !bool {
    if (from[0] == to[0] and from[1] == to[1] and from[2] == to[2]) return false;
    const start: [3]f64 = .{ lerp(-1.0e-7, to[0], from[0]), lerp(-1.0e-7, to[1], from[1]), lerp(-1.0e-7, to[2], from[2]) };
    const end: [3]f64 = .{ lerp(-1.0e-7, from[0], to[0]), lerp(-1.0e-7, from[1], to[1]), lerp(-1.0e-7, from[2], to[2]) };
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    var cell: [3]i32 = .{ mth.floor(start[0]), mth.floor(start[1]), mth.floor(start[2]) };
    if (try cellClips(level, cell, from, delta, context)) return true;
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
    while (next[0] <= 1 or next[1] <= 1 or next[2] <= 1) {
        const axis: usize = if (next[0] < next[1]) (if (next[0] < next[2]) 0 else 2) else (if (next[1] < next[2]) 1 else 2);
        cell[axis] += step[axis];
        next[axis] += increment[axis];
        if (try cellClips(level, cell, from, delta, context)) return true;
    }
    return false;
}

fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}

fn cellClips(level: *const body.Level, cell: [3]i32, from: [3]f64, delta: [3]f64, context: body.Context) !bool {
    const state = try level.state(cell[0], cell[1], cell[2]);
    const boxes = body.collisionBoxes(level, state, cell[0], cell[1], cell[2], context);
    if (boxes.count == 0) return false;
    const shape: body.Shape = .{ .boxes = boxes, .x = cell[0], .y = cell[1], .z = cell[2] };
    const length = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
    if (length < 1.0e-7) return false;
    // VoxelShape.clip: a start just inside the shape hits.
    const probe: [3]f64 = .{ from[0] + delta[0] * 0.001, from[1] + delta[1] * 0.001, from[2] + delta[2] * 0.001 };
    for (0..boxes.count) |index| {
        const target = shape.get(index);
        if (probe[0] >= target.min[0] and probe[0] < target.max[0] and probe[1] >= target.min[1] and probe[1] < target.max[1] and probe[2] >= target.min[2] and probe[2] < target.max[2]) return true;
        if (entersBox(target, from, delta)) return true;
    }
    return false;
}

/// AABB.clip: the segment enters the box through a face it starts outside of.
fn entersBox(target: body.Box, from: [3]f64, delta: [3]f64) bool {
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
    return enter <= 1.0;
}

/// Mobs of the same species whose boxes meet a box, by index, calling back for each in the
/// spatial index's order.
pub const Kin = struct {
    mobs: *Mobs,
    mob: *const Mob,
    query: body.Box,
    rectangle: @import("vanilla_item_entities").item_spatial.Index.Rectangle,

    pub fn init(mobs: *Mobs, mob: *const Mob, query: body.Box) Kin {
        const low: [2]i32 = .{ @divFloor(mth.floor(query.min[0]) - 2, 16), @divFloor(mth.floor(query.min[2]) - 2, 16) };
        const high: [2]i32 = .{ @divFloor(mth.floor(query.max[0]) + 2, 16), @divFloor(mth.floor(query.max[2]) + 2, 16) };
        return .{ .mobs = mobs, .mob = mob, .query = query, .rectangle = mobs.spatial.rectangle(mob.world, low, high) };
    }

    pub fn next(self: *Kin) ?u32 {
        while (self.rectangle.next()) |index| {
            const other = &self.mobs.mobs[index];
            if (other == self.mob or other.removed or other.species != self.mob.species) continue;
            if (!living.box(self.mobs, other).intersects(self.query)) continue;
            return index;
        }
        return null;
    }
};

pub fn distanceSquared(a: *const Mob, b: *const Mob) f64 {
    const dx = a.position[0] - b.position[0];
    const dy = a.position[1] - b.position[1];
    const dz = a.position[2] - b.position[2];
    return dx * dx + dy * dy + dz * dz;
}
