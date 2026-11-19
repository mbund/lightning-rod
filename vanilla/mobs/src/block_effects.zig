//! Block effects on mobs: the shared port in vanilla_bodies, with Mobs as its host.

const std = @import("std");
const bodies = @import("vanilla_bodies");
const living_body = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;
const MobSound = @import("mobs.zig").Sound;
const JavaRandom = bodies.java_random.JavaRandom;

const generic = bodies.block_effects;
const Mob = mob_state.Mob;

pub const Scratch = generic.Scratch;
pub const insideActs = generic.insideActs;

/// Entity.applyEffectsFromBlocks over the movements the mob recorded this tick.
pub fn applyEffectsFromBlocks(mobs: *Mobs, mob: *Mob) !bool {
    defer mob.movement_count = 0;
    return generic.apply(Host{ .mobs = mobs }, mob, mobs.movements[0..mob.movement_count]);
}

/// Entity.isOnFire on the server.
pub fn onFire(mobs: *Mobs, mob: *const Mob) bool {
    return generic.onFire(Host{ .mobs = mobs }, mob) catch unreachable;
}

const Host = struct {
    pub const living = true;
    mobs: *Mobs,

    pub fn level(self: Host, world: u32) bodies.body.Level {
        return self.mobs.level(world);
    }
    pub fn scratch(self: Host) *generic.Scratch {
        return &self.mobs.effects_scratch;
    }
    pub fn width(self: Host, mob: *const Mob) f32 {
        return living_body.width(self.mobs, mob);
    }
    pub fn height(self: Host, mob: *const Mob) f32 {
        return living_body.height(self.mobs, mob);
    }
    pub fn alive(_: Host, mob: *const Mob) bool {
        return mob.alive();
    }
    pub fn fireImmune(self: Host, mob: *const Mob) error{}!bool {
        return self.mobs.traits(mob.species).fire_immune;
    }
    pub fn onPosition(self: Host, mob: *const Mob, depth: f32) ![3]i32 {
        return living_body.onPosition(self.mobs, mob, depth);
    }
    pub fn hurt(self: Host, mob: *Mob, damage: generic.Damage, amount: f32) !bool {
        const kind: mob_state.DamageType = switch (damage) {
            inline else => |tag| @field(mob_state.DamageType, @tagName(tag)),
        };
        return self.mobs.hurt(mob, .{ .type = kind }, amount);
    }
    pub fn playSound(self: Host, mob: *const Mob, sound: generic.Sound, volume: f32, pitch: f32) void {
        const kind: MobSound = switch (sound) {
            inline else => |tag| @field(MobSound, @tagName(tag)),
        };
        self.mobs.playSound(mob, kind, volume, pitch);
    }
    pub fn random(_: Host, mob: *Mob) *JavaRandom {
        return &mob.random;
    }
    pub fn levelRandom(self: Host) *JavaRandom {
        return self.mobs.levelRandom();
    }
    pub fn mobGriefing(self: Host) bool {
        return self.mobs.mobGriefing();
    }
    pub fn destroyBlock(self: Host, world: u32, position: [3]i32) !void {
        return self.mobs.destroyBlock(world, position);
    }
    pub fn lowerCauldron(self: Host, world: u32, position: [3]i32) !void {
        return self.mobs.lowerCauldron(world, position);
    }
    pub fn crackTurtleEgg(self: Host, world: u32, position: [3]i32, state: u16) !void {
        return self.mobs.crackTurtleEgg(world, position, state);
    }
    pub fn entityEvent(self: Host, mob: *Mob, event: u8) void {
        self.mobs.entityEvent(mob, event);
    }
};
