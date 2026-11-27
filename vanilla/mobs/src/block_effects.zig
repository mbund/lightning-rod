//! Block effects on mobs: the shared port in vanilla_bodies, with Mobs as its host.

const std = @import("std");
const bodies = @import("vanilla_bodies");
const living_body = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;
const MobSound = @import("mobs.zig").Sound;

const generic = bodies.block_effects;
const Mob = mob_state.Mob;

pub const Scratch = generic.Scratch;
pub const insideActs = generic.insideActs;

/// A mob as the shared port's host sees it.
const Context = struct { mobs: *Mobs, mob: Mob };
const Host = generic.Host(*const Context);

/// Entity.applyEffectsFromBlocks over the movements the mob recorded this tick.
pub fn applyEffectsFromBlocks(mobs: *Mobs, mob: Mob) !bool {
    defer mob.motion.movement_count = 0;
    const context: Context = .{ .mobs = mobs, .mob = mob };
    const level = mobs.level(mob.motion.world);
    const host = hostOf(&context, &level);
    return generic.apply(*const Context, &host, subjectOf(mobs, mob), mobs.movements[0..mob.motion.movement_count]);
}

/// Entity.isOnFire on the server.
pub fn onFire(mobs: *Mobs, mob: Mob) bool {
    return mob.entity.fire_ticks > 0 and !mobs.traits(mob.entity.species).fire_immune;
}

fn subjectOf(mobs: *Mobs, mob: Mob) generic.Subject {
    return .{
        .world = mob.motion.world,
        .position = mob.motion.position,
        .old_position = mob.motion.old_position,
        .on_ground = mob.motion.on_ground,
        .removed = mob.entity.removed,
        .width = living_body.width(mobs, mob),
        .height = living_body.height(mobs, mob),
        .velocity = &mob.motion.velocity,
        .fall_distance = &mob.motion.fall_distance,
        .stuck = &mob.motion.stuck,
        .fire_ticks = &mob.entity.fire_ticks,
        .ticks_frozen = &mob.entity.ticks_frozen,
        .in_powder_snow = &mob.entity.in_powder_snow,
    };
}

fn hostOf(context: *const Context, level: *const bodies.body.Level) Host {
    return .{
        .context = context,
        .level = level,
        .scratch = &context.mobs.effects_scratch,
        .random = &context.mob.idle.random,
        .level_random = context.mobs.levelRandom(),
        .mob_griefing = context.mobs.mobGriefing(),
        .alive = alive,
        .fire_immune = fireImmune,
        .on_position = onPosition,
        .hurt = hurt,
        .play_sound = playSound,
        .destroy_block = destroyBlock,
        .lower_cauldron = lowerCauldron,
        .living = .{ .crack_turtle_egg = crackTurtleEgg, .entity_event = entityEvent },
    };
}

fn alive(context: *const Context) bool {
    return context.mob.alive();
}

fn fireImmune(context: *const Context) anyerror!bool {
    return context.mobs.traits(context.mob.entity.species).fire_immune;
}

fn onPosition(context: *const Context, depth: f32) anyerror![3]i32 {
    return living_body.onPosition(context.mobs, context.mob, depth);
}

fn hurt(context: *const Context, damage: generic.Damage, amount: f32) anyerror!bool {
    const kind: mob_state.DamageType = switch (damage) {
        inline else => |tag| @field(mob_state.DamageType, @tagName(tag)),
    };
    return context.mobs.hurt(context.mob, .{ .type = kind }, amount);
}

fn playSound(context: *const Context, sound: generic.Sound, volume: f32, pitch: f32) void {
    const kind: MobSound = switch (sound) {
        inline else => |tag| @field(MobSound, @tagName(tag)),
    };
    context.mobs.playSound(context.mob, kind, volume, pitch);
}

fn destroyBlock(context: *const Context, position: [3]i32) anyerror!void {
    return context.mobs.deps.block_edits.destroyBlock(context.mob.motion.world, position);
}

fn lowerCauldron(context: *const Context, position: [3]i32) anyerror!void {
    return context.mobs.deps.block_edits.lowerCauldron(context.mob.motion.world, position);
}

fn crackTurtleEgg(context: *const Context, position: [3]i32, state: u16) anyerror!void {
    return context.mobs.crackTurtleEgg(context.mob.motion.world, position, state);
}

fn entityEvent(context: *const Context, event: u8) void {
    context.mobs.entityEvent(context.mob, event);
}
