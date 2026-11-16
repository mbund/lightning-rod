//! A mob's state: what vanilla's Entity, LivingEntity, Mob, AgeableMob and Animal keep, the
//! cow's variant, and the state of its controls, navigation and goals. Plain data, kept in a
//! fixed array by the Mobs plugin.

const std = @import("std");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;

/// Mob types this server simulates.
pub const Species = enum(u8) { cow };

/// One stretch of movement in a tick, which block effects trace (Entity.Movement).
pub const Movement = struct { from: [3]f64, to: [3]f64, axis_independent: bool };

/// Damage types mobs take, by what vanilla names them. The panic_causes tag decides which make
/// a cow panic, and the registry decides the rest.
pub const DamageType = enum(u8) {
    generic,
    fall,
    in_wall,
    drown,
    on_fire,
    in_fire,
    campfire,
    lava,
    hot_floor,
    cactus,
    sweet_berry_bush,
    cramming,
    freeze,
    player_attack,
    stalagmite,
    out_of_world,
    generic_kill,
    mob_attack,
};

pub const Damage = struct {
    type: DamageType,
    /// The player that dealt it, as a slot in Players, for player attacks.
    attacker: ?u32 = null,
};

pub const MoveOperation = enum(u2) { wait, move_to, strafe, jumping };

/// PathNavigation.path. Its nodes are in the path store, at the mob's index.
pub const Path = struct {
    active: bool = false,
    count: u16 = 0,
    next: u16 = 0,
    target: [3]i32 = .{ 0, 0, 0 },
    reached: bool = false,
};

pub const Navigation = struct {
    path: Path = .{},
    speed: f64 = 0,
    tick: i32 = 0,
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
    /// Bits of running goals, by priority: float, panic, breed, tempt, follow parent, stroll,
    /// look at player, look around.
    running: u8 = 0,
    /// Goals holding the move, look and jump flags, by priority, or none.
    move_owner: ?u3 = null,
    look_owner: ?u3 = null,
    jump_owner: ?u3 = null,
    /// GoalSelector.disabledFlags, set every fifth tick from passengers.
    disabled: u4 = 0,

    panic_target: [3]f64 = .{ 0, 0, 0 },
    breed_partner: ?u32 = null,
    breed_love_time: i32 = 0,
    tempt_player: ?u32 = null,
    tempt_player_position: [3]f64 = .{ 0, 0, 0 },
    tempt_calm_down: i32 = 0,
    parent: ?u32 = null,
    parent_recalculate: i32 = 0,
    stroll_target: [3]f64 = .{ 0, 0, 0 },
    look_at_player: ?u32 = null,
    look_time: i32 = 0,
    look_around: [2]f64 = .{ 0, 0 },
    look_around_time: i32 = 0,
};

pub const Mob = struct {
    // Entity.
    id: u64,
    uuid: u128,
    species: Species,
    world: u32,
    position: [3]f64,
    old_position: [3]f64,
    velocity: [3]f64 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = 0,
    old_yaw: f32 = 0,
    old_pitch: f32 = 0,
    tick_count: i32 = 0,
    random: JavaRandom,
    on_ground: bool = false,
    horizontal_collision: bool = false,
    vertical_collision: bool = false,
    vertical_collision_below: bool = false,
    supporting: ?[3]i32 = null,
    on_ground_no_blocks: bool = false,
    fall_distance: f64 = 0,
    stuck: [3]f64 = .{ 0, 0, 0 },
    fire_ticks: i32 = -1,
    touching_water: bool = false,
    eye_in_water: bool = false,
    water_height: f64 = 0,
    lava_height: f64 = 0,
    in_powder_snow: bool = false,
    was_in_powder_snow: bool = false,
    first_tick: bool = true,
    move_dist: f32 = 0,
    next_step: f32 = 1,
    has_impulse: bool = false,
    hurt_marked: bool = false,
    removed: bool = false,
    movements: [8]Movement = undefined,
    movement_count: u8 = 0,

    // LivingEntity.
    health: f32,
    hurt_time: i32 = 0,
    hurt_duration: i32 = 0,
    invulnerable_time: i32 = 0,
    death_time: i32 = 0,
    dead: bool = false,
    last_hurt: f32 = 0,
    last_damage: ?Damage = null,
    last_damage_stamp: i64 = 0,
    last_hurt_by_player: ?u128 = null,
    last_hurt_by_player_time: i32 = 0,
    last_hurt_by_mob: ?u32 = null,
    last_hurt_by_mob_timestamp: i32 = 0,
    air_supply: i32 = 300,
    body_yaw: f32 = 0,
    old_body_yaw: f32 = 0,
    head_yaw: f32 = 0,
    old_head_yaw: f32 = 0,
    strafe: f32 = 0,
    vertical_input: f32 = 0,
    forward: f32 = 0,
    jumping: bool = false,
    no_jump_delay: i32 = 0,
    speed: f32 = 0,
    ticks_frozen: i32 = 0,
    last_climbable: ?[3]i32 = null,
    /// FOLLOW_RANGE's random spawn bonus, a multiplier of its base.
    follow_range_bonus: f64 = 0,

    // Mob.
    ambient_sound_time: i32 = 0,
    no_action_time: i32 = 0,
    persistence_required: bool = false,
    left_handed: bool = false,
    no_ai: bool = false,
    move_operation: MoveOperation = .wait,
    wanted: [3]f64 = .{ 0, 0, 0 },
    move_speed: f64 = 0,
    look_wanted: [3]f64 = .{ 0, 0, 0 },
    look_max_yaw: f32 = 0,
    look_max_pitch: f32 = 0,
    look_cooldown: i32 = 0,
    jump: bool = false,
    head_stable_time: i32 = 0,
    last_stable_head_yaw: f32 = 0,
    navigation: Navigation = .{},
    goals: Goals = .{},

    // AgeableMob and Animal.
    age: i32 = 0,
    forced_age: i32 = 0,
    forced_age_timer: i32 = 0,
    in_love: i32 = 0,
    love_cause: ?u128 = null,

    // Cow.
    variant: u8 = 0,

    /// Entity events (Level.broadcastEntityEvent) since the replication last sent them.
    events: [4]u8 = undefined,
    event_count: u8 = 0,
    /// Rises when data viewers see changes: health, age, fire, air, pose.
    revision: u32 = 0,

    pub fn baby(self: *const Mob) bool {
        return self.age < 0;
    }

    pub fn alive(self: *const Mob) bool {
        return !self.removed and self.health > 0;
    }

    pub fn blockPosition(self: *const Mob) [3]i32 {
        return .{ floorInt(self.position[0]), floorInt(self.position[1]), floorInt(self.position[2]) };
    }
};

fn floorInt(value: f64) i32 {
    return @intFromFloat(@floor(value));
}
