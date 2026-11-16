//! Entity.applyEffectsFromBlocks: what blocks a mob stands on and moves through do to it.

const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

pub fn applyEffectsFromBlocks(_: *Mobs, mob: *Mob) !void {
    mob.movement_count = 0;
}
