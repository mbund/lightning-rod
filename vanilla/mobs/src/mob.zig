//! A mob's state, by the components of vanilla's classes: what Entity, LivingEntity, Mob,
//! PathfinderMob, AgeableMob and Animal keep, and a few bytes each species keeps of its own.
//! Plain data, each part a component of its own.

const std = @import("std");
const extras = @import("extras.zig");
const body = @import("vanilla_bodies").body;
const mob_blocks = @import("vanilla_bodies").mob_blocks;
const JavaRandom = @import("vanilla_bodies").java_random.JavaRandom;

/// A species registered with the Mobs plugin, by the order they were registered in.
pub const Species = enum(u8) { _ };

/// How many species may register.
pub const max_species = 16;

/// One stretch of movement in a tick, which block effects trace (Entity.Movement).
pub const Movement = @import("vanilla_bodies").block_effects.Movement;

/// Damage types mobs take, by what vanilla names them. The panic_causes tag decides which make
/// a cow panic, and the registry decides the rest.
pub const DamageType = @import("vanilla_survival").damage_types.DamageType;

pub const Damage = struct {
    type: DamageType,
    /// The player that dealt it, as a slot in Players, for player attacks.
    attacker: ?u32 = null,
    /// DamageSource.getSourcePosition, which knockback pushes away from.
    source: ?[3]f64 = null,
};

pub const MoveOperation = enum(u2) { wait, move_to, strafe, jumping };

/// A path whose nodes the mobs do not hold.
pub const no_nodes = std.math.maxInt(u32);

/// PathNavigation.path. Its nodes are the mobs' while it is followed.
pub const Path = struct {
    active: bool = false,
    count: u16 = 0,
    next: u16 = 0,
    target: [3]i32 = .{ 0, 0, 0 },
    reached: bool = false,
    /// The nodes' places, hashed, which Path.sameAs compares once the nodes are gone.
    fingerprint: u128 = 0,
    /// The blob holding its nodes while the mobs hold them, which they let go once it is done.
    nodes: u32 = no_nodes,
    /// Its last node, which edits are measured against without reading the nodes.
    end: [3]i32 = .{ 0, 0, 0 },
};

pub const Navigation = struct {
    path: Path = .{},
    speed: f64 = 0,
    last_stuck_check: i32 = 0,
    last_stuck_check_position: [3]f64 = .{ 0, 0, 0 },
    timeout_node: [3]i32 = .{ 0, 0, 0 },
    timeout_timer: i64 = 0,
    last_timeout_check: i64 = 0,
    timeout_limit: f64 = 0,
    max_distance_to_waypoint: f32 = 0.5,
    has_delayed_recomputation: bool = false,
    time_last_recompute: i64 = 0,
    target: ?[3]i32 = null,
    reach_range: i32 = 0,
    stuck: bool = false,
};

pub const Goals = struct {
    /// GoalSelector.disabledFlags, set every fifth tick from passengers.
    disabled: u4 = 0,
    /// The goal holding the jump flag, by priority, or none.
    jump_owner: ?u4 = null,
};

/// Breeding, tempting and looking at a player take the look flag, as looking around does, so no
/// two run at once: what one keeps is a part of the mob while it runs, and goes as it stops, since
/// each start sets afresh all it reads. Looking around keeps its own, among what idle mobs change.
pub const Focus = union(enum) {
    breed: struct { partner: u64, love_time: i32 = 0 },
    tempt: struct { player: u32, player_position: [3]f64 },
    look_at_player: struct { player: u32, time: i32 },
};

/// What an idle mob's tick changes, side by side for every mob: the counters, the random, the
/// head and body turning and what turns them, and the look around goal, which is the only goal
/// an idle mob runs. Mobs advance runs of idle mobs together over these.
pub const Idle = struct {
    random: JavaRandom,
    tick_count: i32 = 0,
    /// Mob.ambientSoundTime and noActionTime; PathNavigation.tick.
    ambient_sound_time: i32 = 0,
    no_action_time: i32 = 0,
    navigation_tick: i32 = 0,
    /// LookControl: what it turns toward, with what limits, and its countdown.
    look_wanted: [3]f64 = .{ 0, 0, 0 },
    look_max_yaw: f32 = 0,
    look_max_pitch: f32 = 0,
    look_cooldown: i32 = 0,
    /// BodyRotationControl.
    head_stable_time: i32 = 0,
    last_stable_head_yaw: f32 = 0,
    head_yaw: f32 = 0,
    old_head_yaw: f32 = 0,
    body_yaw: f32 = 0,
    old_body_yaw: f32 = 0,
    /// TemptGoal.calmDown, which counts down whether the goal runs or not.
    tempt_calm_down: i32 = 0,
    /// AgeableMob.age: below zero a baby, above it a breeding cooldown.
    age: i32 = 0,
    /// Bits of running goals, by their priority among its species' goals.
    running: u16 = 0,
    /// Goals holding the move and look flags, by priority, or none.
    move_owner: ?u4 = null,
    look_owner: ?u4 = null,
    /// RandomLookAroundGoal's direction and time, while it runs.
    look_around: struct { relative: [2]f64 = .{ 0, 0 }, time: i32 = 0 } = .{},
};

/// Where a mob is and how it moves: what lookups, replication and moves read.
pub const Motion = struct {
    world: u32,
    position: [3]f64,
    old_position: [3]f64,
    velocity: [3]f64 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    old_yaw: f32 = 0,
    old_pitch: f32 = 0,
    on_ground: bool = false,
    horizontal_collision: bool = false,
    vertical_collision: bool = false,
    vertical_collision_below: bool = false,
    on_ground_no_blocks: bool = false,
    supporting: ?[3]i32 = null,
    fall_distance: f64 = 0,
    stuck: [3]f64 = .{ 0, 0, 0 },
    move_dist: f32 = 0,
    next_step: f32 = 1,
    /// Movements this tick, held in Mobs.movements while the mob ticks.
    movement_count: u8 = 0,
    /// Standing still on blocks that act on nothing, touching no other mob, after a tick that
    /// found so: the next tick skips what only reads blocks and neighbours, as it would find the
    /// same. Edits nearby, a mob coming into contact, a spawn and a change of size clear it, and
    /// each skip checks the mob is still where and as it rested. See mob_tick.zig.
    resting: bool = false,
    rest_position: [3]f64 = .{ 0, 0, 0 },
    rest_velocity: [3]f64 = .{ 0, 0, 0 },
};

/// Entity: what every entity has but where it is and how it moves. Its id and kind, what it
/// touches, and the counters of its life.
pub const EntityPart = struct {
    id: u64,
    uuid: u128,
    species: Species,
    /// Entity.remainingFireTicks, which rests at -getFireImmuneTicks, 0 for mobs.
    fire_ticks: i32 = 0,
    touching_water: bool = false,
    eye_in_water: bool = false,
    water_height: f64 = 0,
    lava_height: f64 = 0,
    /// Entity.ticksFrozen, which powder snow raises and warmth lowers.
    ticks_frozen: i32 = 0,
    in_powder_snow: bool = false,
    was_in_powder_snow: bool = false,
    first_tick: bool = true,
    has_impulse: bool = false,
    hurt_marked: bool = false,
    removed: bool = false,
    /// Removed as its column left memory: told to viewers as gone, its record kept.
    unloaded: bool = false,
    /// Where its place in the sections was last put, so a mob that stayed is not looked up.
    placed: bool = false,
    placed_world: u32 = 0,
    placed_position: [3]f64 = .{ 0, 0, 0 },
    /// Rises when data viewers see changes: health, age, fire, air, pose.
    revision: u32 = 0,
};

/// LivingEntity: health and its timers, breath, and what moves it.
pub const Living = struct {
    health: f32,
    hurt_time: i32 = 0,
    hurt_duration: i32 = 0,
    invulnerable_time: i32 = 0,
    death_time: i32 = 0,
    dead: bool = false,
    last_hurt: f32 = 0,
    /// LivingEntity.lastHurtByPlayerMemoryTime: loot and experience come while it runs. Who it
    /// was, and the mob that hurt it last, nothing here asks.
    last_hurt_by_player_time: i32 = 0,
    air_supply: i32 = 300,
    strafe: f32 = 0,
    vertical_input: f32 = 0,
    forward: f32 = 0,
    jumping: bool = false,
    no_jump_delay: i32 = 0,
    speed: f32 = 0,
    /// LivingEntity.tryAddFrost's slowdown, added to the movement speed while freezing.
    frost_speed: f32 = 0,
    last_climbable: ?[3]i32 = null,
    /// FOLLOW_RANGE's random spawn bonus, a multiplier of its base.
    follow_range_bonus: f64 = 0,
};

/// Mob: its controls, MoveControl and JumpControl, and the flags Mob keeps beside them.
pub const Control = struct {
    persistence_required: bool = false,
    left_handed: bool = false,
    no_ai: bool = false,
    move_operation: MoveOperation = .wait,
    wanted: [3]f64 = .{ 0, 0, 0 },
    move_speed: f64 = 0,
    jump: bool = false,
};

/// FollowParentGoal's parent while it runs, and its countdown to the next move.
pub const Follow = struct { parent: u64, recalculate: i32 = 0 };

/// Animal.inLove and loveCause, while either is set.
pub const Breeding = struct { in_love: i32 = 0, love_cause: ?u128 = null };

/// AgeableMob.forcedAge and forcedAgeTimer, once food made a baby grow.
pub const Ageing = struct { forced_age: i32 = 0, forced_age_timer: i32 = 0 };

/// LivingEntity.lastDamageSource and lastDamageStamp, until forgotten.
pub const Hurt = struct { damage: Damage, stamp: i64 };

/// A mob's rare parts: state that matters to few mobs at a time, kept apart from the groups every
/// mob has, each only while it is there.
pub const Part = enum { focus, follow, breeding, ageing, hurt };

pub fn PartType(comptime part: Part) type {
    return switch (part) {
        .focus => Focus,
        .follow => Follow,
        .breeding => Breeding,
        .ageing => Ageing,
        .hurt => Hurt,
    };
}

/// A mob's rare parts as values, as copies hold them.
pub const Rare = struct {
    focus: ?Focus = null,
    follow: ?Follow = null,
    breeding: ?Breeding = null,
    ageing: ?Ageing = null,
    hurt: ?Hurt = null,
};

/// Where a mob's rare parts are: behind its row's link in the mobs' extras, or in a copy.
pub const Extras = union(enum) {
    table: struct { link: *u32, store: *extras.Store },
    copy: *Rare,
};

/// What a species' plugin keeps of each of its mobs, as its own class keeps it: the cow's
/// variant, the sheep's wool. The plugin reads its bytes as it likes, saved as they are.
pub const Kin = struct {
    bytes: [4]u8 = @splat(0),
};

/// A mob's components as values, grouped by what reads and writes them together: what an idle
/// tick changes, where it is and moves, then by vanilla's classes, Entity, LivingEntity, Mob with
/// its GoalSelector, PathfinderMob's navigation, AgeableMob and Animal, and its species' kin. What a
/// mob is made from, saved as, and copied into for checks; the mobs' table keeps each a column.
pub const MobState = struct {
    idle: Idle,
    motion: Motion,
    entity: EntityPart,
    living: Living,
    control: Control = .{},
    goals: Goals = .{},
    navigation: Navigation = .{},
    kin: Kin = .{},
    rare: Rare = .{},
};

/// A mob as the code works on it: where each of its components lies. In the Mobs plugin's
/// tables the records hold until the tick's end; a handle over a `MobState` copy is a copy.
pub const Mob = struct {
    idle: *Idle,
    motion: *Motion,
    entity: *EntityPart,
    living: *Living,
    control: *Control,
    goals: *Goals,
    navigation: *Navigation,
    kin: *Kin,
    extras: Extras,

    /// The groups every mob has, which a handle reaches directly.
    pub const groups = .{ "idle", "motion", "entity", "living", "control", "goals", "navigation", "kin" };

    /// A handle over values held elsewhere, as a copy is.
    pub fn of(values: *MobState) Mob {
        var mob: Mob = undefined;
        inline for (groups) |name| @field(mob, name) = &@field(values, name);
        mob.extras = .{ .copy = &values.rare };
        return mob;
    }

    /// The values the handle reaches.
    pub fn state(self: Mob) MobState {
        var values: MobState = undefined;
        inline for (groups) |name| @field(values, name) = @field(self, name).*;
        values.rare = self.rareValues();
        return values;
    }

    /// The mob's rare parts as values.
    pub fn rareValues(self: Mob) Rare {
        return switch (self.extras) {
            .table => |held| held.store.read(held.link.*),
            .copy => |rare| rare.*,
        };
    }

    /// One of the mob's rare parts, if it has it: good until the tick's end.
    pub fn part(self: Mob, comptime which: Part) ?*PartType(which) {
        return switch (self.extras) {
            .table => |held| held.store.get(held.link.*, which),
            .copy => |rare| if (@field(rare, @tagName(which))) |*value| value else null,
        };
    }

    /// The mob has a rare part, with this value.
    pub fn put(self: Mob, comptime which: Part, value: PartType(which)) !*PartType(which) {
        switch (self.extras) {
            .table => |held| return held.store.put(held.link, which, value),
            .copy => |rare| {
                @field(rare, @tagName(which)) = value;
                return &@field(rare, @tagName(which)).?;
            },
        }
    }

    /// The mob's rare part goes, if it has it.
    pub fn drop(self: Mob, comptime which: Part) void {
        switch (self.extras) {
            .table => |held| held.store.drop(held.link, which),
            .copy => |rare| @field(rare, @tagName(which)) = null,
        }
    }

    /// Animal.inLove.
    pub fn inLove(self: Mob) i32 {
        return if (self.part(.breeding)) |breeding| breeding.in_love else 0;
    }

    /// Animal.resetLove, and every other place in love ends: the cause is kept.
    pub fn endLove(self: Mob) void {
        const breeding = self.part(.breeding) orelse return;
        breeding.in_love = 0;
        if (breeding.love_cause == null) self.drop(.breeding);
    }

    /// Whether two handles reach the same mob.
    pub fn same(self: Mob, other: Mob) bool {
        return self.entity == other.entity;
    }

    pub fn baby(self: Mob) bool {
        return self.idle.age < 0;
    }

    pub fn alive(self: Mob) bool {
        return !self.entity.removed and self.living.health > 0;
    }

    pub fn blockPosition(self: Mob) [3]i32 {
        const position = self.motion.position;
        return .{ floorInt(position[0]), floorInt(position[1]), floorInt(position[2]) };
    }
};

fn floorInt(value: f64) i32 {
    return @intFromFloat(@floor(value));
}

/// What befell a mob for its viewers to hear of, in the order it did: Level.broadcastEntityEvent's
/// status bytes, ServerLevel.broadcastDamageEvent, and the ClientboundAnimatePacket of critical
/// and enchanted hits.
pub const Event = struct {
    slot: u32,
    id: u64,
    what: union(enum) { status: u8, damage: Damage, animation: u8 },
};
