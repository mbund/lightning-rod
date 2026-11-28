//! What a mob species is: what its plugin says of it, a Definition, and what the snapshot adds of
//! its entity type, dimensions and default attributes, together its Traits. The Mobs plugin keeps
//! every species registered with it, and the code all share reads a mob's through its Traits:
//! constants as data, the goals it registers in priority order, the data its viewers are sent,
//! and, as functions of its plugin, the few moments its own class acts.

const std = @import("std");
const game_data = @import("game_data");
const loot = @import("vanilla_items").loot;
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;
const Use = @import("mob_interaction.zig").Use;

const registry = game_data.registry;
const Mob = mob_state.Mob;
const MobState = mob_state.MobState;
const Kin = mob_state.Kin;

pub const Attribute = enum {
    max_health,
    movement_speed,
    follow_range,
    tempt_range,
    step_height,
    gravity,
    jump_strength,
    safe_fall_distance,
    fall_damage_multiplier,
    water_movement_efficiency,
    movement_efficiency,
    knockback_resistance,
    armor,
    armor_toughness,
    oxygen_bonus,
    scale,
    burning_time,
};

/// The goals vanilla's animals share, which Mobs runs for every species that registers them.
pub const Shared = enum(u3) { float, panic, breed, tempt, follow_parent, stroll, look_at_player, look_around };

/// Goal.Flag: what a goal holds while it runs.
pub const Flags = packed struct { move: bool = false, look: bool = false, jump: bool = false };

/// A goal of the species' own, as its plugin implements Goal's methods.
pub const OwnGoal = struct {
    context: *anyopaque,
    flags: Flags,
    /// Goal.requiresUpdateEveryTick.
    every_tick: bool = false,
    can_use: *const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) anyerror!bool,
    can_continue: *const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) anyerror!bool,
    start: *const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) anyerror!void,
    stop: *const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) void,
    tick: *const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) anyerror!void,
};

/// A goal a species registers: a shared one, or its own.
pub const Goal = union(enum) { shared: Shared, own: *const OwnGoal };

/// The flags a goal holds while it runs.
pub fn flagsOf(goal: Goal) Flags {
    return switch (goal) {
        .shared => |shared| switch (shared) {
            .float => .{ .jump = true },
            .panic, .stroll => .{ .move = true },
            .breed, .tempt, .look_around => .{ .move = true, .look = true },
            .follow_parent => .{},
            .look_at_player => .{ .look = true },
        },
        .own => |own| own.flags,
    };
}

/// Goal.requiresUpdateEveryTick.
pub fn everyTick(goal: Goal) bool {
    return switch (goal) {
        .shared => |shared| shared == .float or shared == .look_around,
        .own => |own| own.every_tick,
    };
}

/// The goals of AbstractCow.registerGoals, which the herd's idle ticks stand for.
pub const animal_goals = [_]Goal{ .{ .shared = .float }, .{ .shared = .panic }, .{ .shared = .breed }, .{ .shared = .tempt }, .{ .shared = .follow_parent }, .{ .shared = .stroll }, .{ .shared = .look_at_player }, .{ .shared = .look_around } };

/// An entity data entry of the species' own, sent from a byte of its kin: its key, which 26.1's
/// age_locked moved one later, how it is written, and its value on a fresh entity.
pub const DataEntry = struct {
    key: u8,
    modern_key: u8,
    serializer: enum { byte, cow_variant },
    kin: u2,
    default: u8 = 0,
};

/// The sound events of the species' voice and steps.
pub const Sounds = struct { ambient: []const u8, hurt: []const u8, death: []const u8, step: []const u8 };

/// The moments the species' own class acts, each of them rare.
pub const Hooks = struct {
    context: *anyopaque = undefined,
    /// Mob.finalizeSpawn's own part, before the draws of Mob's.
    finalize: ?*const fn (context: *anyopaque, mobs: *Mobs, created: *MobState) anyerror!void = null,
    /// AgeableMob.getBreedOffspring's own part: the young one's kin, from its parents.
    offspring: ?*const fn (context: *anyopaque, mobs: *Mobs, parent: Mob, other: Mob, kin: *Kin) anyerror!void = null,
    /// Mob.ate.
    ate: ?*const fn (context: *anyopaque, mobs: *Mobs, mob: Mob) anyerror!void = null,
    /// Mob.mobInteract before Animal's: whether it took the use.
    interact: ?*const fn (context: *anyopaque, use: *const Use) anyerror!bool = null,
    /// What an item used on it does once the mob passed the use on, as an item's
    /// interactLivingEntity: whether it took the use.
    use_item: ?*const fn (context: *anyopaque, use: *const Use) anyerror!bool = null,
    /// What its loot tables' entity_properties may ask of it, good while it is in hand.
    facts: ?*const fn (mob: Mob) loot.EntityFacts = null,
};

/// What a species' plugin says of it.
pub const Definition = struct {
    entity: []const u8,
    /// Its goals in registerGoals' order, which is their priority.
    goals: []const Goal = &animal_goals,
    /// The speeds its PanicGoal, TemptGoal and FollowParentGoal move at.
    panic_speed: f64,
    tempt_speed: f64,
    follow_parent_speed: f64,
    /// Animal.isFood: the item tag of what tempts it and makes it breed.
    food_tag: []const u8,
    /// The loot table it drops when it dies.
    loot_table: []const u8,
    sounds: Sounds,
    /// Mob.getSoundVolume.
    sound_volume: f32 = 1.0,
    /// Its baby's eye height where its class sets one, as AbstractCow.BABY_DIMENSIONS does: else
    /// scaled with the rest.
    baby_eye_height: ?f32 = null,
    data: []const DataEntry = &.{},
    /// Whether an idle mob of it ticks as the herd's, which stands for the animal goals alone.
    idles: bool = false,
    hooks: Hooks = .{},
};

pub const Traits = struct {
    entity_type: u32,
    width: f32,
    height: f32,
    eye_height: f32,
    baby_width: f32,
    baby_height: f32,
    baby_eye_height: f32,
    fire_immune: bool,
    tracking_range: u8,
    update_interval: u32,
    track_deltas: bool,
    attributes: [@typeInfo(Attribute).@"enum".field_names.len]f64,
    /// Animal.getAmbientSoundInterval.
    ambient_interval: i32 = 120,
    /// What its plugin said, after what the tick reads most.
    definition: Definition,
    /// By shared goal, its priority among the species' goals, if it registers it.
    shared: [@typeInfo(Shared).@"enum".field_names.len]?u4,
    /// By priority, a bit for each goal that holds the move, look or jump flag, and for each
    /// that ticks every tick, found once so the goal selector reads its goals by bits.
    move: u16 = 0,
    look: u16 = 0,
    jump: u16 = 0,
    every_tick: u16 = 0,

    pub fn attribute(self: *const Traits, which: Attribute) f64 {
        return self.attributes[@backingInt(which)];
    }

    /// The bit of a shared goal among a mob's running goals, none where it has none.
    pub fn sharedBit(self: *const Traits, goal: Shared) u16 {
        const index = self.shared[@backingInt(goal)] orelse return 0;
        return @as(u16, 1) << index;
    }
};

/// Attribute.getDefaultValue for attributes an entity type does not list.
fn defaultValue(which: Attribute) f64 {
    return switch (which) {
        .max_health => 20,
        .movement_speed => 0.7,
        .follow_range => 32,
        .tempt_range => 10,
        .step_height => 0.6,
        .gravity => 0.08,
        .jump_strength => 0.42,
        .safe_fall_distance => 3,
        .fall_damage_multiplier => 1,
        .water_movement_efficiency => 0,
        .movement_efficiency => 0,
        .knockback_resistance => 0,
        .armor => 0,
        .armor_toughness => 0,
        .oxygen_bonus => 0,
        .scale => 1,
        .burning_time => 1,
    };
}

fn attributeId(name: []const u8) u16 {
    @setEvalBranchQuota(1_000_000);
    for (registry.named_registries) |named| {
        if (!std.mem.eql(u8, named.name, "minecraft:attribute")) continue;
        for (named.entries, 0..) |entry, index| if (std.mem.eql(u8, entry, name)) return @intCast(index);
    }
    unreachable;
}

fn sameGoals(a: []const Goal, b: []const Goal) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}

pub fn traits(definition: Definition) !Traits {
    if (definition.goals.len > 16) return error.TooManyGoals;
    const entity_type: u32 = @intCast(registry.entityId(definition.entity) orelse return error.UnknownEntityType);
    const entity = game_data.physics.entityType(entity_type);
    var result: Traits = .{
        .definition = definition,
        .entity_type = entity_type,
        .width = entity.width,
        .height = entity.height,
        .eye_height = entity.eye_height,
        .baby_width = entity.width * 0.5,
        .baby_height = entity.height * 0.5,
        .baby_eye_height = definition.baby_eye_height orelse entity.eye_height * 0.5,
        .fire_immune = entity.fire_immune,
        .tracking_range = entity.tracking_range,
        .update_interval = entity.update_interval,
        .track_deltas = entity.track_deltas,
        .attributes = undefined,
        .shared = @splat(null),
    };
    inline for (@typeInfo(Attribute).@"enum".field_names, 0..) |field, index| {
        const id = comptime attributeId("minecraft:" ++ field);
        result.attributes[index] = game_data.physics.attribute(entity_type, id) orelse defaultValue(@field(Attribute, field));
    }
    for (definition.goals, 0..) |goal, priority| {
        const bit = @as(u16, 1) << @intCast(priority);
        const held = flagsOf(goal);
        if (held.move) result.move |= bit;
        if (held.look) result.look |= bit;
        if (held.jump) result.jump |= bit;
        if (everyTick(goal)) result.every_tick |= bit;
    }
    for (definition.goals, 0..) |goal, priority| switch (goal) {
        .shared => |shared| {
            if (result.shared[@backingInt(shared)] != null) return error.GoalRegisteredTwice;
            result.shared[@backingInt(shared)] = @intCast(priority);
        },
        .own => {},
    };
    // The herd's idle tick draws as the animal goals do, and no other.
    if (definition.idles and !sameGoals(definition.goals, &animal_goals)) return error.IdleNeedsAnimalGoals;
    return result;
}
