//! LivingEntity.hurtServer for mobs, with Animal.actuallyHurt: invulnerability frames,
//! knockback away from where the damage came from, hurt and death sounds, damage events for
//! viewers, and death with its loot and experience.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("vanilla_bodies").mth;
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;

pub fn hurt(mobs: *Mobs, mob: *Mob, damage: mob_state.Damage, amount: f32) !bool {
    const flags = mobs.damageFlags(damage.type);
    // LivingEntity.isInvulnerableTo: removed, or fire to the fire immune.
    if (mob.removed) return false;
    if (flags.fire and mobs.traits(mob.species).fire_immune) return false;
    if (!mob.alive()) return false;
    mob.no_action_time = 0;
    var value = @max(amount, 0);
    if (std.math.isNan(value) or std.math.isInf(value)) value = std.math.floatMax(f32);
    var full = true;
    if (@as(f32, @floatFromInt(mob.invulnerable_time)) > 10.0 and !flags.bypasses_cooldown) {
        if (value <= mob.last_hurt) return false;
        actuallyHurt(mobs, mob, value - mob.last_hurt);
        mob.last_hurt = value;
        full = false;
    } else {
        mob.last_hurt = value;
        mob.invulnerable_time = 20;
        actuallyHurt(mobs, mob, value);
        mob.hurt_duration = 10;
        mob.hurt_time = 10;
    }
    if (damage.attacker) |slot| {
        // LivingEntity.setLastHurtByPlayer, which loot and experience need for 100 ticks.
        mob.last_hurt_by_player = mobs.deps.players.records[slot].uuid;
        mob.last_hurt_by_player_time = 100;
    }
    if (full) {
        mobs.damageEvent(mob, damage);
        if (!flags.no_impact) mob.hurt_marked = true;
        if (!flags.no_knockback) {
            var dx: f64 = 0;
            var dz: f64 = 0;
            if (damage.source) |source| {
                dx = source[0] - mob.position[0];
                dz = source[2] - mob.position[2];
            }
            mobs.knockback(mob, 0.4, dx, dz);
        }
    }
    if (!mob.alive()) {
        if (full) mobs.makeSound(mob, deathSound(mob));
        try die(mobs, mob, damage);
    } else if (full) {
        // Mob.playHurtSound resets the ambient sound's wait first.
        mob.ambient_sound_time = -mobs.traits(mob.species).ambient_interval;
        mobs.makeSound(mob, hurtSound(mob));
    }
    mob.last_damage = damage;
    mob.last_damage_stamp = mobs.gameTime();
    return true;
}

/// Animal.actuallyHurt ends love, then LivingEntity.actuallyHurt takes health. Mobs here wear
/// no armor and have no effects or absorption.
fn actuallyHurt(_: *Mobs, mob: *Mob, amount: f32) void {
    mob.in_love = 0;
    if (amount != 0) mob.health -= amount;
}

/// LivingEntity.die.
fn die(mobs: *Mobs, mob: *Mob, damage: mob_state.Damage) !void {
    if (mob.removed or mob.dead) return;
    mob.dead = true;
    // LivingEntity.dropAllDeathLoot: loot and experience come when a player hurt the mob in the
    // last five seconds, and never from babies.
    const by_player = mob.last_hurt_by_player_time > 0;
    if (!mob.baby()) try mobs.dropLoot(mob, damage, by_player);
    if (by_player and !mob.baby()) {
        // Animal.getBaseExperienceReward.
        const amount = 1 + mob.random.nextIntBounded(3);
        try mobs.awardExperience(mob, amount);
    }
    mobs.entityEvent(mob, 3);
}

fn hurtSound(mob: *const Mob) @import("mobs.zig").Sound {
    return switch (mob.species) {
        .cow => .cow_hurt,
    };
}

fn deathSound(mob: *const Mob) @import("mobs.zig").Sound {
    return switch (mob.species) {
        .cow => .cow_death,
    };
}
