//! Mobs in entity id order, the order vanilla ticks them in, with the hot state of idle mobs
//! kept apart as arrays by place in that order, so runs of idle mobs advance together over
//! compact memory.
//!
//! An idle mob rests (Mob.resting), runs at most the look around goal, follows no path and is
//! grown, calm and whole (see `idle`). Its whole vanilla tick is then counters, random draws and
//! its head and body turning toward a fixed point, which `advance` computes. A draw that would start something, a sound or a goal, or a
//! player holding food nearby, sends the mob back to its scalar tick from the start, as if it
//! had never been idle. While a mob idles, the fields in Hot live here and are stale in its
//! Mob, and leaving writes them back.

const std = @import("std");
const mob_state = @import("mob.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;
const ai = @import("ai.zig");
const mth = @import("mth.zig");
const mob_tick = @import("mob_tick.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const assert = std.debug.assert;

pub const no_place = std.math.maxInt(u32);

/// RandomLookAroundGoal, last of the cow's goals.
const look_around_priority = 7;
const look_around_bit: u8 = 1 << look_around_priority;

/// The fields an idle tick changes, by place.
const Hot = struct {
    seed: []u64,
    tick_count: []i32,
    ambient_sound_time: []i32,
    no_action_time: []i32,
    navigation_tick: []i32,
    head_stable_time: []i32,
    tempt_calm_down: []i32,
    age: []i32,
    head_yaw: []f32,
    body_yaw: []f32,
    old_head_yaw: []f32,
    old_body_yaw: []f32,
    last_stable_head_yaw: []f32,
    look_cooldown: []i32,
    look_around_time: []i32,
    /// RandomLookAroundGoal runs, holding the move and look flags.
    gazing: []bool,
    /// Its direction, and what the look control turns toward with what limits.
    look_vector: [][2]f64,
    look_wanted: [][3]f64,
    look_max_yaw: []f32,
    look_max_pitch: []f32,
    /// LookControl.getYRotD for the wanted point, which stays put while the mob does. NaN when
    /// there is none.
    gaze_yaw: []f32,
    /// Began idling since replication last sent the mob from its Mob, which it does once to
    /// catch anything that changed on the way in.
    fresh: []bool,
};

/// What an idle tick reads and never changes, by place.
const Still = struct {
    /// Mob.getId's low bits, which pick the goal selector's tick parity.
    parity_id: []i32,
    position: [][3]f64,
    world: []u32,
    persistence_required: []bool,
    id: []u64,
    yaw: []f32,
    /// The velocity it rests with, gravity pulling it into the floor.
    velocity: [][3]f64,
    /// For replication: the tick count, modulo the send interval, on which it sends.
    send_phase: []u8,
    /// Whether its column ticked, as of a domains revision.
    ticks: []bool,
    ticks_revision: []u64,
    /// For any mob, idle or not: the domains revision as of which its column did not tick, so
    /// it waits without its Mob being read. A mob that does not tick cannot move itself.
    dormant_revision: []u64,
    /// The chunk column the mob stands in, which decides whether it ticks.
    chunk: [][2]i32,
};

pub const Herd = struct {
    /// Mob slots by place, in entity id order.
    slots: []u32,
    count: usize = 0,
    /// Places by mob slot.
    place_of: []u32,
    /// Removed mobs leave holes, closed up before the next tick.
    holes: usize = 0,
    /// Mobs added out of id order, sorted before the next tick.
    unsorted: bool = false,
    idling: []bool,
    hot: Hot,
    still: Still,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Herd {
        const place_of = try allocator.alloc(u32, capacity);
        @memset(place_of, no_place);
        const idling = try allocator.alloc(bool, capacity);
        @memset(idling, false);
        var hot: Hot = undefined;
        inline for (@typeInfo(Hot).@"struct".field_names, @typeInfo(Hot).@"struct".field_types) |name, Field| @field(hot, name) = try allocator.alloc(@typeInfo(Field).pointer.child, capacity);
        var still: Still = undefined;
        inline for (@typeInfo(Still).@"struct".field_names, @typeInfo(Still).@"struct".field_types) |name, Field| @field(still, name) = try allocator.alloc(@typeInfo(Field).pointer.child, capacity);
        return .{ .slots = try allocator.alloc(u32, capacity), .place_of = place_of, .idling = idling, .hot = hot, .still = still };
    }

    /// New mobs take ids above every other, so they join at the end.
    pub fn add(self: *Herd, mobs: []const Mob, slot: u32) void {
        assert(self.place_of[slot] == no_place and self.count < self.slots.len);
        if (self.count > 0 and mobs[self.slots[self.count - 1]].id > mobs[slot].id) self.unsorted = true;
        self.slots[self.count] = slot;
        self.place_of[slot] = @intCast(self.count);
        self.idling[self.count] = false;
        self.still.dormant_revision[self.count] = std.math.maxInt(u64);
        self.count += 1;
    }

    /// A removed mob leaves a hole until `tidy`.
    pub fn remove(self: *Herd, slot: u32) void {
        const place = self.place_of[slot];
        assert(place != no_place and !self.idling[place]);
        self.slots[place] = no_place;
        self.place_of[slot] = no_place;
        self.holes += 1;
    }

    /// Closes holes and restores id order, keeping idle state with its mob.
    pub fn tidy(self: *Herd, mobs: []const Mob) void {
        if (self.holes == 0 and !self.unsorted) return;
        var kept: usize = 0;
        for (0..self.count) |place| {
            if (self.slots[place] == no_place) continue;
            self.move(place, kept);
            kept += 1;
        }
        self.count = kept;
        self.holes = 0;
        if (self.unsorted) {
            // Out of order only when mobs load, so an insertion sort over places is enough.
            for (1..self.count) |place| {
                var at = place;
                while (at > 0 and mobs[self.slots[at - 1]].id > mobs[self.slots[at]].id) : (at -= 1) self.swap(at - 1, at);
            }
            self.unsorted = false;
        }
        for (self.slots[0..self.count], 0..) |slot, place| self.place_of[slot] = @intCast(place);
    }

    fn move(self: *Herd, from: usize, to: usize) void {
        if (from == to) return;
        self.slots[to] = self.slots[from];
        self.idling[to] = self.idling[from];
        inline for (@typeInfo(Hot).@"struct".field_names) |name| @field(self.hot, name)[to] = @field(self.hot, name)[from];
        inline for (@typeInfo(Still).@"struct".field_names) |name| @field(self.still, name)[to] = @field(self.still, name)[from];
    }

    fn swap(self: *Herd, a: usize, b: usize) void {
        std.mem.swap(u32, &self.slots[a], &self.slots[b]);
        std.mem.swap(bool, &self.idling[a], &self.idling[b]);
        inline for (@typeInfo(Hot).@"struct".field_names, @typeInfo(Hot).@"struct".field_types) |name, Field| std.mem.swap(@typeInfo(Field).pointer.child, &@field(self.hot, name)[a], &@field(self.hot, name)[b]);
        inline for (@typeInfo(Still).@"struct".field_names, @typeInfo(Still).@"struct".field_types) |name, Field| std.mem.swap(@typeInfo(Field).pointer.child, &@field(self.still, name)[a], &@field(self.still, name)[b]);
    }

    /// The mob starts idling: its hot fields move here.
    pub fn enter(self: *Herd, place: usize, mob: *const Mob) void {
        assert(!self.idling[place]);
        self.idling[place] = true;
        self.hot.seed[place] = mob.random.state();
        self.hot.tick_count[place] = mob.tick_count;
        self.hot.ambient_sound_time[place] = mob.ambient_sound_time;
        self.hot.no_action_time[place] = mob.no_action_time;
        self.hot.navigation_tick[place] = mob.navigation.tick;
        self.hot.head_stable_time[place] = mob.head_stable_time;
        self.hot.tempt_calm_down[place] = mob.goals.tempt_calm_down;
        self.hot.age[place] = mob.age;
        self.hot.head_yaw[place] = mob.head_yaw;
        self.hot.body_yaw[place] = mob.body_yaw;
        self.hot.old_head_yaw[place] = mob.old_head_yaw;
        self.hot.old_body_yaw[place] = mob.old_body_yaw;
        self.hot.last_stable_head_yaw[place] = mob.last_stable_head_yaw;
        self.hot.look_cooldown[place] = mob.look_cooldown;
        self.hot.look_around_time[place] = mob.goals.look_around_time;
        self.hot.gazing[place] = mob.goals.running != 0;
        self.hot.gaze_yaw[place] = ai.lookYaw(mob) orelse std.math.nan(f32);
        self.hot.look_max_yaw[place] = mob.look_max_yaw;
        self.hot.look_max_pitch[place] = mob.look_max_pitch;
        self.hot.look_vector[place] = mob.goals.look_around;
        self.hot.look_wanted[place] = mob.look_wanted;
        self.still.id[place] = mob.id;
        self.still.yaw[place] = mob.yaw;
        self.still.velocity[place] = mob.velocity;
        self.still.ticks_revision[place] = std.math.maxInt(u64);
        self.hot.fresh[place] = true;
        self.still.parity_id[place] = @intCast(mob.id & 0x7fffffff);
        self.still.position[place] = mob.position;
        self.still.world[place] = mob.world;
        self.still.persistence_required[place] = mob.persistence_required;
        self.still.chunk[place] = @import("mobs.zig").chunkOf(mob.position);
    }

    /// Writes the hot fields back into a mob, as it stands at this place.
    pub fn writeBack(self: *const Herd, place: usize, mob: *Mob) void {
        assert(self.idling[place]);
        mob.random = JavaRandom.restore(self.hot.seed[place]);
        mob.tick_count = self.hot.tick_count[place];
        mob.ambient_sound_time = self.hot.ambient_sound_time[place];
        mob.no_action_time = self.hot.no_action_time[place];
        mob.navigation.tick = self.hot.navigation_tick[place];
        mob.head_stable_time = self.hot.head_stable_time[place];
        mob.goals.tempt_calm_down = self.hot.tempt_calm_down[place];
        mob.age = self.hot.age[place];
        mob.head_yaw = self.hot.head_yaw[place];
        mob.body_yaw = self.hot.body_yaw[place];
        mob.old_head_yaw = self.hot.old_head_yaw[place];
        mob.old_body_yaw = self.hot.old_body_yaw[place];
        mob.last_stable_head_yaw = self.hot.last_stable_head_yaw[place];
        mob.look_cooldown = self.hot.look_cooldown[place];
        mob.goals.look_around_time = self.hot.look_around_time[place];
        mob.goals.look_around = self.hot.look_vector[place];
        mob.look_wanted = self.hot.look_wanted[place];
        mob.look_max_yaw = self.hot.look_max_yaw[place];
        mob.look_max_pitch = self.hot.look_max_pitch[place];
        const gazing = self.hot.gazing[place];
        mob.goals.running = if (gazing) look_around_bit else 0;
        mob.goals.move_owner = if (gazing) look_around_priority else null;
        mob.goals.look_owner = if (gazing) look_around_priority else null;
    }

    /// The mob stops idling: its hot fields go back to it.
    pub fn leave(self: *Herd, place: usize, mob: *Mob) void {
        self.writeBack(place, mob);
        self.idling[place] = false;
    }
};

/// Whether a resting mob's tick is only counters, draws and turning: no goal but the look
/// around runs, nothing hurts, and the look control's pitch stays level.
pub fn idle(mobs: *const Mobs, mob: *const Mob) bool {
    const goals = mob.goals;
    const gazing = goals.running == look_around_bit and goals.move_owner == look_around_priority and goals.look_owner == look_around_priority;
    const still = goals.running == 0 and goals.move_owner == null and goals.look_owner == null;
    if (!(gazing or still)) return false;
    // While the look control counts down, the pitch it turns toward must keep the head level.
    if (mob.look_cooldown > 0) if (ai.lookPitch(mobs, mob)) |pitch| if (mth.rotateTowards(0, pitch, mob.look_max_pitch) != 0) return false;
    return mob.resting and mob.alive() and !mob.no_ai and !mob.first_tick and mob.species == .cow and
        goals.jump_owner == null and goals.disabled == 0 and goals.tempt_player == null and goals.look_at_player == null and
        !mob.navigation.path.active and !mob.navigation.has_delayed_recomputation and
        mob.pitch == 0 and mob.old_pitch == 0 and mob.yaw == mob.old_yaw and
        mob.age >= 0 and mob.in_love == 0 and mob.hurt_time == 0 and mob.invulnerable_time == 0 and
        mob.last_hurt_by_player == null and mob.last_hurt_by_player_time == 0 and mob.last_hurt_by_mob == null and mob.last_damage == null and
        mob.air_supply == 300 and mob.no_jump_delay == 0 and !mob.jumping and !mob.jump and mob.move_operation == .wait and
        mob.strafe == 0 and mob.forward == 0 and mob.vertical_input == 0 and mob.frost_speed == 0;
}

/// The players an idle tick looks for, as the tick begins.
pub const Audience = struct {
    /// Players Mobs.nearestPlayerDistanceSquared counts: ready and not spectating.
    present: []const Player,
    /// Of those, the ones holding the mobs' food, which may tempt them.
    holding_food: []const Player,

    pub const Player = struct { world: u32, position: [3]f64 };

    fn nearestSquared(self: Audience, world: u32, position: [3]f64) ?f64 {
        var best: ?f64 = null;
        for (self.present) |player| {
            if (player.world != world) continue;
            const dx = player.position[0] - position[0];
            const dy = player.position[1] - position[1];
            const dz = player.position[2] - position[2];
            const distance = dx * dx + dy * dy + dz * dz;
            if (best == null or distance < best.?) best = distance;
        }
        return best;
    }

    /// Whether a present player is within a range of a position.
    fn within(self: Audience, world: u32, position: [3]f64, range: f64) bool {
        for (self.present) |player| {
            if (player.world != world) continue;
            const dx = position[0] - player.position[0];
            const dy = position[1] - player.position[1];
            const dz = position[2] - player.position[2];
            if (dx * dx + dy * dy + dz * dz <= range * range) return true;
        }
        return false;
    }

    /// Whether a holder is close enough that TemptGoal must look properly: within its 10
    /// blocks, before sneaking narrows that.
    fn temptsNear(self: Audience, world: u32, position: [3]f64, range: f64) bool {
        for (self.holding_food) |player| {
            if (player.world != world) continue;
            const dx = position[0] - player.position[0];
            const dy = position[1] - player.position[1];
            const dz = position[2] - player.position[2];
            if (dx * dx + dy * dy + dz * dz <= range * range) return true;
        }
        return false;
    }
};

/// What an idle tick needs of the species, all cows here.
pub const Species = struct {
    tempt_range: f64,
    eye_height: f32,
    ambient_interval: i32,
};

/// An idle tick that stays idle, with the pitch of the ambient sound it plays, if it does.
pub const Outcome = union(enum) {
    idled: ?f32,
    /// Something started that only the full tick does, so the place is left as it was.
    started,
};

/// One idle tick for the mob at a place: Mob.checkDespawn, then Mob.tick as mob_tick.zig runs
/// it for an idle mob. Commits only when it stays idle.
pub fn advance(herd: *Herd, place: usize, audience: Audience, species: Species) Outcome {
    const hot = &herd.hot;
    var random = JavaRandom.restore(hot.seed[place]);
    var tick_count = hot.tick_count[place];
    var ambient = hot.ambient_sound_time[place];
    var no_action = hot.no_action_time[place];
    var calm_down = hot.tempt_calm_down[place];
    var gazing = hot.gazing[place];
    var look_around_time = hot.look_around_time[place];
    var cooldown = hot.look_cooldown[place];
    var gaze_yaw = hot.gaze_yaw[place];
    const position = herd.still.position[place];
    const world = herd.still.world[place];
    // Mob.checkDespawn: an animal never despawns, but the draw happens after 600 idle ticks.
    if (herd.still.persistence_required[place]) {
        no_action = 0;
    } else if (audience.nearestSquared(world, position)) |nearest| {
        const near = 32 * 32;
        if (no_action > 600 and random.nextIntBounded(800) == 0 and nearest > near) {
            // Animal.removeWhenFarAway is false.
        } else if (nearest < near) {
            no_action = 0;
        }
    }
    tick_count += 1;
    // Mob.baseTick: the ambient sound, its pitch Mob.getVoicePitch for a grown mob.
    var sound: ?f32 = null;
    const roll = random.nextIntBounded(1000);
    const time = ambient;
    ambient += 1;
    if (roll < time) {
        ambient = -species.ambient_interval;
        sound = (random.nextFloat() - random.nextFloat()) * 0.2 + 1.0;
    }
    // Mob.serverAiStep.
    no_action += 1;
    var started_gazing = false;
    var look_vector = hot.look_vector[place];
    const parity = @rem(tick_count +% herd.still.parity_id[place], 2);
    if (!(parity != 0 and tick_count > 1)) {
        // GoalSelector.tick: the look around stops when its time runs out, then each goal not
        // running may start.
        if (gazing and !(look_around_time >= 0)) gazing = false;
        if (calm_down > 0) {
            calm_down -= 1;
        } else if (audience.temptsNear(world, position, species.tempt_range)) {
            return .started;
        }
        if (no_action < 100 and random.nextIntBounded(60) == 0) return .started;
        // LookAtPlayerGoal: on its roll it looks for a player within 6 blocks, measured from the
        // mob, and starts only for one it sees.
        if (!(random.nextFloat() >= 0.02) and audience.within(world, position, 6.0)) return .started;
        // RandomLookAroundGoal.
        if (!gazing and random.nextFloat() < 0.02) {
            const angle = (std.math.pi * 2.0) * random.nextDouble();
            look_vector = .{ @cos(angle), @sin(angle) };
            look_around_time = 20 + random.nextIntBounded(20);
            gazing = true;
            started_gazing = true;
        }
    }
    // RandomLookAroundGoal.tick, which runs every tick, and LookControl.setLookAt.
    if (gazing) {
        look_around_time -= 1;
        cooldown = 2;
        if (started_gazing) {
            const wanted: [3]f64 = .{ position[0] + look_vector[0], position[1] + species.eye_height, position[2] + look_vector[1] };
            hot.look_wanted[place] = wanted;
            hot.look_max_yaw[place] = ai.head_rotation_speed;
            hot.look_max_pitch[place] = ai.max_head_pitch;
            gaze_yaw = ai.lookYawAt(wanted, position) orelse std.math.nan(f32);
        }
    }
    // LookControl.tick. The pitch stays level, as `idle` and a look around both ensure.
    var head = hot.head_yaw[place];
    const body = hot.body_yaw[place];
    if (cooldown > 0) {
        cooldown -= 1;
        if (!std.math.isNan(gaze_yaw)) head = mth.rotateTowards(head, gaze_yaw, hot.look_max_yaw[place]);
    } else {
        head = mth.rotateTowards(head, body, 10);
    }
    // BodyRotationControl, for a mob that stood still.
    var turn: mob_tick.Turn = .{ .body = body, .last_stable = hot.last_stable_head_yaw[place], .stable_time = hot.head_stable_time[place] };
    mob_tick.turnStill(head, &turn);
    hot.seed[place] = random.state();
    hot.tick_count[place] = tick_count;
    hot.ambient_sound_time[place] = ambient;
    hot.no_action_time[place] = no_action;
    hot.tempt_calm_down[place] = calm_down;
    hot.navigation_tick[place] += 1;
    hot.gazing[place] = gazing;
    hot.look_around_time[place] = look_around_time;
    hot.look_vector[place] = look_vector;
    hot.look_cooldown[place] = cooldown;
    hot.gaze_yaw[place] = gaze_yaw;
    // Entity.baseTick keeps last tick's angles before anything turns.
    hot.old_head_yaw[place] = hot.head_yaw[place];
    hot.old_body_yaw[place] = body;
    hot.head_yaw[place] = head;
    hot.body_yaw[place] = turn.body;
    hot.last_stable_head_yaw[place] = turn.last_stable;
    hot.head_stable_time[place] = turn.stable_time;
    // AgeableMob.aiStep: a grown mob's breeding cooldown runs down, and it stays grown.
    if (hot.age[place] > 0) hot.age[place] -= 1;
    return .{ .idled = sound };
}

// Eight lanes at once.

pub const lane_count = 8;
const U64 = @Vector(lane_count, u64);
const I32 = @Vector(lane_count, i32);
const F32 = @Vector(lane_count, f32);
const F64 = @Vector(lane_count, f64);
const Mask = @Vector(lane_count, bool);

const none: Mask = @splat(false);

/// What `advanceBlock` found for eight places, kept until each lane is committed.
pub const Block = struct {
    /// Lanes that met something rare and take `advance` instead.
    rare: [lane_count]bool,
    any_rare: bool,
    seed: [lane_count]u64,
    tick_count: [lane_count]i32,
    ambient_sound_time: [lane_count]i32,
    no_action_time: [lane_count]i32,
    tempt_calm_down: [lane_count]i32,
    gazing: [lane_count]bool,
    look_around_time: [lane_count]i32,
    look_cooldown: [lane_count]i32,
    head_yaw: [lane_count]f32,
    body_yaw: [lane_count]f32,
    last_stable_head_yaw: [lane_count]f32,
    head_stable_time: [lane_count]i32,
};

fn load(comptime T: type, items: []const T, first: usize) @Vector(lane_count, T) {
    return items[first..][0..lane_count].*;
}

fn lcg(seed: U64) U64 {
    return (seed *% @as(U64, @splat(0x5DEECE66D)) +% @as(U64, @splat(11))) & @as(U64, @splat((1 << 48) - 1));
}

/// JavaRandom.next for the lanes that draw, which alone move their seed.
fn draw(seed: *U64, drawing: Mask, comptime bits: u6) I32 {
    const advanced = lcg(seed.*);
    seed.* = @select(u64, drawing, advanced, seed.*);
    const shifted: @Vector(lane_count, u32) = @truncate(advanced >> @splat(48 - @as(u7, bits)));
    return @bitCast(shifted);
}

/// JavaRandom.nextIntBounded for a bound that is no power of two. A lane whose draw vanilla would
/// draw again is rare.
fn boundedInt(seed: *U64, drawing: Mask, comptime bound: i32, rare: *Mask) I32 {
    const bits = draw(seed, drawing, 31);
    const value = @rem(bits, @as(I32, @splat(bound)));
    const accepted = (bits -% value +% @as(I32, @splat(bound - 1))) >= @as(I32, @splat(0));
    rare.* = rare.* | (drawing & !accepted);
    return value;
}

fn nextFloat(seed: *U64, drawing: Mask) F32 {
    return @as(F32, @floatFromInt(draw(seed, drawing, 24))) * @as(F32, @splat(5.9604645e-8));
}

/// mth.wrapDegrees, with mth.remainder360 up to 720. A lane that needs more is rare.
fn wrapDegrees(value: F32, rare: *Mask) F32 {
    const size = @abs(value);
    rare.* = rare.* | (size >= @as(F32, @splat(720.0)));
    const turn: F32 = @splat(360.0);
    const reduced = @select(f32, value > @as(F32, @splat(0)), value - turn, value + turn);
    const zero: F32 = @splat(0);
    const signed_zero = @select(f32, value < zero, @as(F32, @splat(-0.0)), zero);
    const remainder = @select(f32, reduced == zero, signed_zero, reduced);
    var wrapped = @select(f32, size < turn, value, remainder);
    wrapped = @select(f32, wrapped >= @as(F32, @splat(180.0)), wrapped - @as(F32, @splat(360.0)), wrapped);
    wrapped = @select(f32, wrapped < @as(F32, @splat(-180.0)), wrapped + @as(F32, @splat(360.0)), wrapped);
    return wrapped;
}

fn clamp(value: F32, minimum: F32, maximum: F32) F32 {
    return @select(f32, value < minimum, minimum, @min(value, maximum));
}

fn rotateTowards(angle: F32, target: F32, limit: F32, rare: *Mask) F32 {
    return angle + clamp(wrapDegrees(target - angle, rare), -limit, limit);
}

fn rotateIfNecessary(angle: F32, target: F32, limit: F32, rare: *Mask) F32 {
    return target - clamp(wrapDegrees(target - angle, rare), -limit, limit);
}

/// `advance` for the eight places from `first`, all idle and ticking, without committing.
pub fn advanceBlock(herd: *const Herd, first: usize, audience: Audience, species: Species) Block {
    const hot = &herd.hot;
    const still = &herd.still;
    var rare = none;
    var seed = load(u64, hot.seed, first);
    var tick_count = load(i32, hot.tick_count, first);
    var ambient = load(i32, hot.ambient_sound_time, first);
    var no_action = load(i32, hot.no_action_time, first);
    var calm_down = load(i32, hot.tempt_calm_down, first);
    var gazing = load(bool, hot.gazing, first);
    var look_around_time = load(i32, hot.look_around_time, first);
    var cooldown = load(i32, hot.look_cooldown, first);
    const persistent = load(bool, still.persistence_required, first);
    const positions = still.position[first..][0..lane_count];
    const worlds = load(u32, still.world, first);
    var x: F64 = undefined;
    var y: F64 = undefined;
    var z: F64 = undefined;
    inline for (0..lane_count) |lane| {
        x[lane] = positions[lane][0];
        y[lane] = positions[lane][1];
        z[lane] = positions[lane][2];
    }
    const zero: I32 = @splat(0);
    // Mob.checkDespawn, with the nearest player in each lane's world.
    var nearest: F64 = @splat(std.math.inf(f64));
    var seen = none;
    for (audience.present) |player| {
        const here = worlds == @as(@Vector(lane_count, u32), @splat(player.world));
        const dx = @as(F64, @splat(player.position[0])) - x;
        const dy = @as(F64, @splat(player.position[1])) - y;
        const dz = @as(F64, @splat(player.position[2])) - z;
        const distance = dx * dx + dy * dy + dz * dz;
        nearest = @select(f64, here & (distance < nearest), distance, nearest);
        seen = seen | here;
    }
    const near: F64 = @splat(32 * 32);
    const counting = seen & !persistent;
    const despawn_draw = counting & (no_action > @as(I32, @splat(600)));
    const despawn_roll = boundedInt(&seed, despawn_draw, 800, &rare);
    const despawning = despawn_draw & (despawn_roll == zero) & (nearest > near);
    no_action = @select(i32, persistent | (counting & !despawning & (nearest < near)), zero, no_action);
    tick_count +%= @splat(1);
    // Mob.baseTick: a lane whose ambient sound plays is rare.
    const roll = boundedInt(&seed, @splat(true), 1000, &rare);
    rare = rare | (roll < ambient);
    ambient +%= @splat(1);
    // Mob.serverAiStep and GoalSelector.tick on the ticks it runs in full.
    no_action +%= @splat(1);
    const parity_odd = ((tick_count +% load(i32, still.parity_id, first)) & @as(I32, @splat(1))) != zero;
    const full = !(parity_odd & (tick_count > @as(I32, @splat(1))));
    gazing = gazing & !(full & (look_around_time < zero));
    const calming = full & (calm_down > zero);
    calm_down = @select(i32, calming, calm_down -% @as(I32, @splat(1)), calm_down);
    if (audience.holding_food.len > 0) {
        inline for (0..lane_count) |lane| {
            if (full[lane] and !calming[lane] and audience.temptsNear(worlds[lane], positions[lane], species.tempt_range)) rare[lane] = true;
        }
    }
    const strolling = full & (no_action < @as(I32, @splat(100)));
    const stroll = boundedInt(&seed, strolling, 60, &rare);
    rare = rare | (strolling & (stroll == zero));
    const look_at = nextFloat(&seed, full);
    rare = rare | (full & !(look_at >= @as(F32, @splat(0.02))));
    const looking_around = full & !gazing;
    const look_around = nextFloat(&seed, looking_around);
    rare = rare | (looking_around & (look_around < @as(F32, @splat(0.02))));
    // RandomLookAroundGoal.tick and LookControl.setLookAt.
    look_around_time = @select(i32, gazing, look_around_time -% @as(I32, @splat(1)), look_around_time);
    cooldown = @select(i32, gazing, @as(I32, @splat(2)), cooldown);
    // LookControl.tick.
    const head = load(f32, hot.head_yaw, first);
    const body = load(f32, hot.body_yaw, first);
    const gaze_yaw = load(f32, hot.gaze_yaw, first);
    const counting_down = cooldown > zero;
    cooldown = @select(i32, counting_down, cooldown -% @as(I32, @splat(1)), cooldown);
    const toward_gaze = counting_down & (gaze_yaw == gaze_yaw);
    const target = @select(f32, toward_gaze, gaze_yaw, body);
    const limit = @select(f32, toward_gaze, load(f32, hot.look_max_yaw, first), @as(F32, @splat(10)));
    const turned = rotateTowards(head, target, limit, &rare);
    const new_head = @select(f32, toward_gaze | !counting_down, turned, head);
    // BodyRotationControl for a mob that stood still.
    var last_stable = load(f32, hot.last_stable_head_yaw, first);
    var stable_time = load(i32, hot.head_stable_time, first);
    const moved_head = @abs(new_head - last_stable) > @as(F32, @splat(15));
    stable_time = @select(i32, moved_head, zero, stable_time +% @as(I32, @splat(1)));
    last_stable = @select(f32, moved_head, new_head, last_stable);
    const fraction = clamp(@as(F32, @floatFromInt(stable_time -% @as(I32, @splat(10)))) / @as(F32, @splat(10.0)), @splat(0), @splat(1));
    const settling_limit = @as(F32, @splat(75)) * (@as(F32, @splat(1)) - fraction);
    const body_limit = @select(f32, moved_head, @as(F32, @splat(75)), settling_limit);
    const follows = moved_head | (stable_time > @as(I32, @splat(10)));
    const new_body = @select(f32, follows, rotateIfNecessary(body, new_head, body_limit, &rare), body);
    return .{
        .rare = rare,
        .any_rare = @reduce(.Or, rare),
        .seed = seed,
        .tick_count = tick_count,
        .ambient_sound_time = ambient,
        .no_action_time = no_action,
        .tempt_calm_down = calm_down,
        .gazing = gazing,
        .look_around_time = look_around_time,
        .look_cooldown = cooldown,
        .head_yaw = new_head,
        .body_yaw = new_body,
        .last_stable_head_yaw = last_stable,
        .head_stable_time = stable_time,
    };
}

/// Commits one lane of a block, as `advance` would have left it.
pub fn commitLane(herd: *Herd, first: usize, block: *const Block, lane: usize) void {
    assert(!block.rare[lane]);
    const place = first + lane;
    const hot = &herd.hot;
    hot.seed[place] = block.seed[lane];
    hot.tick_count[place] = block.tick_count[lane];
    hot.ambient_sound_time[place] = block.ambient_sound_time[lane];
    hot.no_action_time[place] = block.no_action_time[lane];
    hot.tempt_calm_down[place] = block.tempt_calm_down[lane];
    hot.navigation_tick[place] += 1;
    hot.gazing[place] = block.gazing[lane];
    hot.look_around_time[place] = block.look_around_time[lane];
    hot.look_cooldown[place] = block.look_cooldown[lane];
    hot.old_head_yaw[place] = hot.head_yaw[place];
    hot.old_body_yaw[place] = hot.body_yaw[place];
    hot.head_yaw[place] = block.head_yaw[lane];
    hot.body_yaw[place] = block.body_yaw[lane];
    hot.last_stable_head_yaw[place] = block.last_stable_head_yaw[lane];
    hot.head_stable_time[place] = block.head_stable_time[lane];
    if (hot.age[place] > 0) hot.age[place] -= 1;
}

/// Commits a whole block with no rare lane.
pub fn commitBlock(herd: *Herd, first: usize, block: *const Block) void {
    assert(!block.any_rare);
    const hot = &herd.hot;
    hot.seed[first..][0..lane_count].* = block.seed;
    hot.tick_count[first..][0..lane_count].* = block.tick_count;
    hot.ambient_sound_time[first..][0..lane_count].* = block.ambient_sound_time;
    hot.no_action_time[first..][0..lane_count].* = block.no_action_time;
    hot.tempt_calm_down[first..][0..lane_count].* = block.tempt_calm_down;
    hot.navigation_tick[first..][0..lane_count].* = load(i32, hot.navigation_tick, first) +% @as(I32, @splat(1));
    hot.gazing[first..][0..lane_count].* = block.gazing;
    hot.look_around_time[first..][0..lane_count].* = block.look_around_time;
    hot.look_cooldown[first..][0..lane_count].* = block.look_cooldown;
    hot.old_head_yaw[first..][0..lane_count].* = load(f32, hot.head_yaw, first);
    hot.old_body_yaw[first..][0..lane_count].* = load(f32, hot.body_yaw, first);
    hot.head_yaw[first..][0..lane_count].* = block.head_yaw;
    hot.body_yaw[first..][0..lane_count].* = block.body_yaw;
    hot.last_stable_head_yaw[first..][0..lane_count].* = block.last_stable_head_yaw;
    hot.head_stable_time[first..][0..lane_count].* = block.head_stable_time;
    const age = load(i32, hot.age, first);
    hot.age[first..][0..lane_count].* = @select(i32, age > @as(I32, @splat(0)), age -% @as(I32, @splat(1)), age);
}
