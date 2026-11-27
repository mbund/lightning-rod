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

/// Entity.applyEffectsFromBlocks over the movements the mob recorded this tick. The shared port
/// works on the mob's Entity component; the host reaches the rest of the mob.
pub fn applyEffectsFromBlocks(mobs: *Mobs, mob: Mob) !bool {
    defer mob.motion.movement_count = 0;
    return generic.apply(Host{ .mobs = mobs, .mob = mob }, Entity.of(mob), mobs.movements[0..mob.motion.movement_count]);
}

/// Entity.isOnFire on the server.
pub fn onFire(mobs: *Mobs, mob: Mob) bool {
    // Asking changes nothing, so the host's hold on the mob is only read.
    return generic.onFire(Host{ .mobs = mobs, .mob = mob }, Entity.of(mob)) catch unreachable;
}

/// What the shared port reads and changes of a mob, where it lies among the mob's groups.
const Entity = struct {
    world: *u32,
    position: *[3]f64,
    old_position: *[3]f64,
    velocity: *[3]f64,
    on_ground: *bool,
    fall_distance: *f64,
    stuck: *[3]f64,
    removed: *bool,
    fire_ticks: *i32,
    ticks_frozen: *i32,
    in_powder_snow: *bool,

    fn of(mob: Mob) Entity {
        return .{
            .world = &mob.motion.world,
            .position = &mob.motion.position,
            .old_position = &mob.motion.old_position,
            .velocity = &mob.motion.velocity,
            .on_ground = &mob.motion.on_ground,
            .fall_distance = &mob.motion.fall_distance,
            .stuck = &mob.motion.stuck,
            .removed = &mob.entity.removed,
            .fire_ticks = &mob.entity.fire_ticks,
            .ticks_frozen = &mob.entity.ticks_frozen,
            .in_powder_snow = &mob.entity.in_powder_snow,
        };
    }
};

const Host = struct {
    pub const living = true;
    pub const boat = false;
    mobs: *Mobs,
    mob: Mob,

    pub fn level(self: Host, world: u32) bodies.body.Level {
        return self.mobs.level(world);
    }
    pub fn scratch(self: Host) *generic.Scratch {
        return &self.mobs.effects_scratch;
    }
    pub fn width(self: Host, _: Entity) f32 {
        return living_body.width(self.mobs, self.mob);
    }
    pub fn height(self: Host, _: Entity) f32 {
        return living_body.height(self.mobs, self.mob);
    }
    pub fn alive(self: Host, _: Entity) bool {
        return self.mob.alive();
    }
    pub fn fireImmune(self: Host, _: Entity) error{}!bool {
        return self.mobs.traits(self.mob.entity.species).fire_immune;
    }
    pub fn onPosition(self: Host, _: Entity, depth: f32) ![3]i32 {
        return living_body.onPosition(self.mobs, self.mob, depth);
    }
    pub fn hurt(self: Host, _: Entity, damage: generic.Damage, amount: f32) !bool {
        const kind: mob_state.DamageType = switch (damage) {
            inline else => |tag| @field(mob_state.DamageType, @tagName(tag)),
        };
        return self.mobs.hurt(self.mob, .{ .type = kind }, amount);
    }
    pub fn playSound(self: Host, _: Entity, sound: generic.Sound, volume: f32, pitch: f32) void {
        const kind: MobSound = switch (sound) {
            inline else => |tag| @field(MobSound, @tagName(tag)),
        };
        self.mobs.playSound(self.mob, kind, volume, pitch);
    }
    pub fn random(self: Host, _: Entity) *JavaRandom {
        return &self.mob.idle.random;
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
    pub fn entityEvent(self: Host, _: Entity, event: u8) void {
        self.mobs.entityEvent(self.mob, event);
    }
    pub fn onAboveBubbleColumn(self: Host, subject: Entity, drag: bool, _: [3]i32) !void {
        generic.aboveBubbleColumn(self, subject, drag);
    }
};
