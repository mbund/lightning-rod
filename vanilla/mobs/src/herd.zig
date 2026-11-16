//! Mobs in entity id order, the order vanilla ticks them in, with the hot state of idle mobs
//! kept apart as arrays by place in that order, so runs of idle mobs advance together over
//! compact memory.
//!
//! An idle mob rests (Mob.resting), runs no goal, looks at nothing, follows no path and is
//! grown, calm and whole (see `idle`). Its whole vanilla tick is then a few counters and random
//! draws, which `advance` computes. A draw that would start something, a sound or a goal, or a
//! player holding food nearby, sends the mob back to its scalar tick from the start, as if it
//! had never been idle. While a mob idles, the fields in Hot live here and are stale in its
//! Mob, and leaving writes them back.

const std = @import("std");
const mob_state = @import("mob.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;

const Mob = mob_state.Mob;
const assert = std.debug.assert;

pub const no_place = std.math.maxInt(u32);

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
};

/// What an idle tick reads and never changes, by place.
const Still = struct {
    /// Mob.getId's low bits, which pick the goal selector's tick parity.
    parity_id: []i32,
    position: [][3]f64,
    world: []u32,
    persistence_required: []bool,
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
        assert(!self.idling[place] and idle(mob));
        self.idling[place] = true;
        self.hot.seed[place] = mob.random.state();
        self.hot.tick_count[place] = mob.tick_count;
        self.hot.ambient_sound_time[place] = mob.ambient_sound_time;
        self.hot.no_action_time[place] = mob.no_action_time;
        self.hot.navigation_tick[place] = mob.navigation.tick;
        self.hot.head_stable_time[place] = mob.head_stable_time;
        self.hot.tempt_calm_down[place] = mob.goals.tempt_calm_down;
        self.hot.age[place] = mob.age;
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
    }

    /// The mob stops idling: its hot fields go back to it.
    pub fn leave(self: *Herd, place: usize, mob: *Mob) void {
        self.writeBack(place, mob);
        self.idling[place] = false;
    }
};

/// Whether a resting mob's tick is only counters and draws: nothing runs, turns or hurts.
pub fn idle(mob: *const Mob) bool {
    return mob.resting and mob.alive() and !mob.no_ai and !mob.first_tick and mob.species == .cow and
        mob.goals.running == 0 and mob.goals.move_owner == null and mob.goals.look_owner == null and mob.goals.jump_owner == null and
        mob.goals.disabled == 0 and mob.goals.tempt_player == null and mob.goals.look_at_player == null and
        !mob.navigation.path.active and !mob.navigation.has_delayed_recomputation and
        mob.look_cooldown == 0 and mob.pitch == 0 and mob.old_pitch == 0 and mob.yaw == mob.old_yaw and
        mob.head_yaw == mob.body_yaw and mob.old_head_yaw == mob.head_yaw and mob.old_body_yaw == mob.body_yaw and
        @abs(mob.head_yaw - mob.last_stable_head_yaw) <= 15 and
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

pub const Outcome = enum { idled, started };

/// One idle tick for the mob at a place: Mob.checkDespawn, then Mob.tick as mob_tick.zig runs
/// it for an idle mob. Commits only when nothing started; `started` leaves the place as it was.
pub fn advance(herd: *Herd, place: usize, audience: Audience, tempt_range: f64) Outcome {
    var random = JavaRandom.restore(herd.hot.seed[place]);
    var tick_count = herd.hot.tick_count[place];
    var ambient = herd.hot.ambient_sound_time[place];
    var no_action = herd.hot.no_action_time[place];
    var calm_down = herd.hot.tempt_calm_down[place];
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
    // Mob.baseTick: the ambient sound.
    const roll = random.nextIntBounded(1000);
    const time = ambient;
    ambient += 1;
    if (roll < time) return .started;
    // Mob.serverAiStep.
    no_action += 1;
    const parity = @rem(tick_count +% herd.still.parity_id[place], 2);
    if (!(parity != 0 and tick_count > 1)) {
        // GoalSelector.tick with nothing running: each goal in turn may start.
        if (calm_down > 0) {
            calm_down -= 1;
        } else if (audience.temptsNear(world, position, tempt_range)) {
            return .started;
        }
        if (no_action < 100 and random.nextIntBounded(60) == 0) return .started;
        if (!(random.nextFloat() >= 0.02)) return .started;
        if (random.nextFloat() < 0.02) return .started;
    }
    herd.hot.seed[place] = random.state();
    herd.hot.tick_count[place] = tick_count;
    herd.hot.ambient_sound_time[place] = ambient;
    herd.hot.no_action_time[place] = no_action;
    herd.hot.tempt_calm_down[place] = calm_down;
    herd.hot.navigation_tick[place] += 1;
    // AgeableMob.aiStep: a grown mob's breeding cooldown runs down, and it stays grown.
    if (herd.hot.age[place] > 0) herd.hot.age[place] -= 1;
    // BodyRotationControl: still and facing its head, the head counts as stable.
    herd.hot.head_stable_time[place] += 1;
    return .idled;
}
