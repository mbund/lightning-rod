//! What blocks do to experience orbs: the block effects every body shares, with an orb as their
//! subject. Orbs are not living and not immune to fire, and an orb is hurt as
//! ExperienceOrb.hurtServer hurts one, by every damage alike.

const std = @import("std");
const entities = @import("entities");
const bodies = @import("vanilla_bodies");
const Players = @import("players").players.Players;
const world_effects = @import("vanilla_world").world_effects;
const ItemPhysics = @import("vanilla_item_entities").item_physics.ItemPhysics;
const BlockEdits = bodies.block_edits.BlockEdits;

const effects = bodies.block_effects;
const JavaRandom = bodies.java_random.JavaRandom;
const Level = bodies.body.Level;

pub const OrbHazards = struct {
    scratch: effects.Scratch = .{},
    block_edits: *BlockEdits,
    sounds: world_effects.Effects,
    /// Entity.random for the sounds orbs make, which vanilla seeds anew for each entity.
    random: JavaRandom,
    level_random: JavaRandom,
    sound_seeds: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, players: *Players, block_edits: *BlockEdits) !OrbHazards {
        return .{
            .block_edits = block_edits,
            .sounds = try .init(allocator, players),
            // Vanilla seeds these anew for each entity and level; any seed draws alike.
            .random = .init(0x6f7262),
            .level_random = .init(0x6c6576656c),
            .sound_seeds = .init(0x736f756e64),
        };
    }
};

/// An orb through its move: what block effects read and change of it, kept apart from its body,
/// which the move carries.
pub const Subject = struct {
    world: u32,
    old_position: [3]f64,
    health: i16,
    fire_ticks: i32,
    ticks_frozen: i32,
    stuck: [3]f64 = .{ 0, 0, 0 },
    /// Orbs keep no fall distance between ticks: only the blocks that reset it touch this.
    fall_distance: f64 = 0,
    in_powder_snow: bool = false,
};

/// What ItemPhysics.advanceOrb calls once the orb moved: the effects of the blocks it crossed,
/// Entity.applyEffectsFromBlocks.
pub const Hook = struct {
    hazards: *OrbHazards,
    level: *const Level,
    subject: *Subject,

    /// As ItemPhysics takes it.
    pub fn physics(self: *Hook) ItemPhysics.Hook {
        return .{ .context = self, .apply = applyHook };
    }

    fn applyHook(context: *anyopaque, body: *entities.State, on_ground: bool, from: [3]f64) anyerror!void {
        const self: *Hook = @ptrCast(@alignCast(context));
        const subject = self.subject;
        // The move took what held it back.
        subject.stuck = .{ 0, 0, 0 };
        const answers: Context = .{ .hazards = self.hazards, .subject = subject, .position = body.position };
        const host: Host = .{
            .context = &answers,
            .level = self.level,
            .scratch = &self.hazards.scratch,
            .random = &self.hazards.random,
            .level_random = &self.hazards.level_random,
            // The mobGriefing game rule, which this server keeps at vanilla's default.
            .mob_griefing = true,
            .alive = alive,
            .fire_immune = fireImmune,
            .on_position = onPosition,
            .hurt = hurt,
            .play_sound = playSound,
            .destroy_block = destroyBlock,
            .lower_cauldron = lowerCauldron,
        };
        const movement: effects.Movement = .{ .from = from, .to = body.position, .axis_independent = true };
        _ = try effects.apply(*const Context, &host, .{
            .world = subject.world,
            .position = body.position,
            .old_position = subject.old_position,
            .on_ground = on_ground,
            .removed = subject.health <= 0,
            .width = 0.5,
            .height = 0.5,
            .velocity = &body.velocity,
            .fall_distance = &subject.fall_distance,
            .stuck = &subject.stuck,
            .fire_ticks = &subject.fire_ticks,
            .ticks_frozen = &subject.ticks_frozen,
            .in_powder_snow = &subject.in_powder_snow,
        }, &.{movement});
    }
};

const Context = struct { hazards: *OrbHazards, subject: *Subject, position: [3]f64 };
const Host = effects.Host(*const Context);

fn alive(context: *const Context) bool {
    return context.subject.health > 0;
}

fn fireImmune(_: *const Context) anyerror!bool {
    return false;
}

/// Entity.getOnPos below an orb.
fn onPosition(context: *const Context, depth: f32) anyerror![3]i32 {
    const position = context.position;
    return .{ bodies.mth.floor(position[0]), bodies.mth.floor(position[1] - depth), bodies.mth.floor(position[2]) };
}

/// ExperienceOrb.hurtServer: health lost, the orb gone at none once its tick ends.
fn hurt(context: *const Context, _: effects.Damage, amount: f32) anyerror!bool {
    const subject = context.subject;
    if (subject.health <= 0) return false;
    subject.health = @intFromFloat(@max(@as(f32, std.math.minInt(i16)), @as(f32, @floatFromInt(subject.health)) - amount));
    return true;
}

fn playSound(context: *const Context, sound: effects.Sound, volume: f32, pitch: f32) void {
    const hazards = context.hazards;
    const name = switch (sound) {
        .generic_burn => "minecraft:entity.generic.burn",
        .generic_extinguish_fire => "minecraft:entity.generic.extinguish_fire",
        .honey_block_slide => "minecraft:block.honey_block.slide",
    };
    const at = context.position;
    // ExperienceOrb.getSoundSource.
    hazards.sounds.sound(context.subject.world, .{ .x = at[0], .y = at[1], .z = at[2] }, name, .ambient, volume, pitch, @bitCast(hazards.sound_seeds.next()), null);
}

fn destroyBlock(context: *const Context, position: [3]i32) anyerror!void {
    return context.hazards.block_edits.destroyBlock(context.subject.world, position);
}

fn lowerCauldron(context: *const Context, position: [3]i32) anyerror!void {
    return context.hazards.block_edits.lowerCauldron(context.subject.world, position);
}
