//! What mobs notice: players by vanilla's TargetingConditions (range scaled for sneaking, and
//! line of sight where the condition asks for it), the mob's own kind nearby, and whether a ray
//! between two points passes collision shapes, as Level.clip with ClipContext.Block.COLLIDER.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const body = @import("vanilla_bodies").body;
const clip = @import("vanilla_bodies").clip;
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
pub fn playerEyeHeight(sneaking: bool) f64 {
    return if (sneaking) @as(f32, 1.27) else @as(f32, 1.62);
}

/// EntityGetter.getNearestPlayer(TargetingConditions, LivingEntity, x, y, z): the player who
/// passes the conditions nearest the point, the first of equals.
pub fn nearestPlayer(mobs: *Mobs, mob: Mob, conditions: Conditions, point: [3]f64) !?u32 {
    var best: ?u32 = null;
    var best_distance: f64 = -1;
    for (mobs.deps.players.activeSlots()) |slot| {
        const player = &mobs.deps.players.records[slot];
        if (player.world != mob.motion.world or player.stage != .ready or player.handle == null) continue;
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
pub fn test_(mobs: *Mobs, mob: Mob, conditions: Conditions, slot: u32) !bool {
    const player = &mobs.deps.players.records[slot];
    const state = mobs.deps.player_states.of(player);
    // LivingEntity.canBeSeenByAnyone.
    if (state.gamemode == .spectator or state.health <= 0) return false;
    // LivingEntity.getVisibilityPercent: sneaking players are noticed closer.
    const visibility: f64 = if (player.flags.sneaking) 0.8 else 1.0;
    const reach = @max(conditions.range * visibility, 2.0);
    const dx = mob.motion.position[0] - player.position.x;
    const dy = mob.motion.position[1] - player.position.y;
    const dz = mob.motion.position[2] - player.position.z;
    if (dx * dx + dy * dy + dz * dz > reach * reach) return false;
    // Vanilla tests the selector before the range, and both only read, so the cheaper goes first.
    if (conditions.holding_food and !mobs.holdsFood(slot)) return false;
    if (conditions.line_of_sight and !try hasLineOfSight(mobs, mob, .{ player.position.x, player.position.y + playerEyeHeight(player.flags.sneaking), player.position.z })) return false;
    return true;
}

pub fn playerEye(mobs: *Mobs, slot: u32) [3]f64 {
    const player = &mobs.deps.players.records[slot];
    return .{ player.position.x, player.position.y + playerEyeHeight(player.flags.sneaking), player.position.z };
}

/// LivingEntity.hasLineOfSight: no collision shape between the eyes, within 128 blocks.
pub fn hasLineOfSight(mobs: *Mobs, mob: Mob, target: [3]f64) !bool {
    const eye: [3]f64 = .{ mob.motion.position[0], living.eyeY(mobs, mob), mob.motion.position[2] };
    const dx = target[0] - eye[0];
    const dy = target[1] - eye[1];
    const dz = target[2] - eye[2];
    if (@sqrt(dx * dx + dy * dy + dz * dz) > 128.0) return false;
    const level = mobs.level(mob.motion.world);
    return try clip.clip(&level, eye, target, .collider, .none, living.context(mob)) == null;
}

pub fn distanceSquared(a: Mob, b: Mob) f64 {
    const dx = a.motion.position[0] - b.motion.position[0];
    const dy = a.motion.position[1] - b.motion.position[1];
    const dz = a.motion.position[2] - b.motion.position[2];
    return dx * dx + dy * dy + dz * dz;
}
