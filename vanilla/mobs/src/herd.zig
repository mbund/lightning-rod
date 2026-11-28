//! Idle mobs' ticks. An idle mob rests (Mob.resting), runs at most the look around goal, follows
//! no path and is grown, calm and whole (see `idle`). Its whole vanilla tick is then counters,
//! random draws and its head and body turning toward a fixed point, which `advance` computes over
//! its `Idle` group alone. Runs of idle mobs side by side in the mobs' table, as the tick order
//! has them, advance together over their rows with `advanceBlock`. A draw that would start
//! something, a sound or a goal, or a player holding food nearby, sends the mob back to its full
//! tick from the start, as if it had never been idle.

const std = @import("std");
const mob_state = @import("mob.zig");
const species_data = @import("species.zig");
const JavaRandom = @import("vanilla_bodies").java_random.JavaRandom;
const ai = @import("ai.zig");
const mth = @import("vanilla_bodies").mth;
const mob_tick = @import("mob_tick.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const Idle = mob_state.Idle;
const Motion = mob_state.Motion;
const assert = std.debug.assert;
const species_count = mob_state.max_species;

/// RandomLookAroundGoal, last of the animal goals, which every species that idles registers.
const look_around_priority: u4 = for (species_data.animal_goals, 0..) |goal, at| {
    if (std.meta.eql(goal, species_data.Goal{ .shared = .look_around })) break at;
} else unreachable;
const look_around_bit: u16 = @as(u16, 1) << look_around_priority;

/// Whether a resting mob's tick is only counters, draws and turning: no goal but the look
/// around runs, nothing hurts, and the look control's pitch stays level.
pub fn idle(mobs: *const Mobs, mob: Mob) bool {
    const hot = mob.idle;
    const gazing = hot.running == look_around_bit and hot.move_owner == look_around_priority and hot.look_owner == look_around_priority;
    const still = hot.running == 0 and hot.move_owner == null and hot.look_owner == null;
    if (!(gazing or still)) return false;
    // Looking around is the only goal running, if any: nothing else keeps a focus.
    assert(mob.part(.focus) == null);
    // While the look control counts down, the pitch it turns toward must keep the head level.
    if (hot.look_cooldown > 0) if (ai.lookPitch(mobs, mob)) |pitch| if (mth.rotateTowards(0, pitch, hot.look_max_pitch) != 0) return false;
    return mob.motion.resting and mob.alive() and !mob.control.no_ai and !mob.entity.first_tick and mobs.traits(mob.entity.species).definition.idles and
        mob.goals.jump_owner == null and mob.goals.disabled == 0 and
        !mob.navigation.path.active and !mob.navigation.has_delayed_recomputation and
        mob.motion.pitch == 0 and mob.motion.old_pitch == 0 and mob.motion.yaw == mob.motion.old_yaw and
        hot.age >= 0 and mob.inLove() == 0 and mob.living.hurt_time == 0 and mob.living.invulnerable_time == 0 and
        mob.living.last_hurt_by_player_time == 0 and mob.part(.hurt) == null and
        mob.living.air_supply == 300 and mob.living.no_jump_delay == 0 and !mob.living.jumping and !mob.control.jump and mob.control.move_operation == .wait and
        mob.living.strafe == 0 and mob.living.forward == 0 and mob.living.vertical_input == 0 and mob.living.frost_speed == 0;
}

/// LookControl.getYRotD for the point an idle mob's look control turns toward, which stays put
/// while the mob does: NaN when there is none. Kept beside the mob while it idles.
pub fn gazeYaw(mob: Mob) f32 {
    return ai.lookYaw(mob) orelse std.math.nan(f32);
}

/// The players an idle tick looks for, as the tick begins.
pub const Audience = struct {
    /// Players Mobs.nearestPlayerDistanceSquared counts: ready and not spectating.
    present: []const Player,
    /// Of those, by species, the ones holding its food, which may tempt it.
    holding_food: [species_count][]const Player,

    pub const Player = struct { world: u32, position: [3]f64 };

    pub fn nearestSquared(self: Audience, world: u32, position: [3]f64) ?f64 {
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
    pub fn temptsNear(self: Audience, species: mob_state.Species, world: u32, position: [3]f64, range: f64) bool {
        for (self.holding_food[@backingInt(species)]) |player| {
            if (player.world != world) continue;
            const dx = position[0] - player.position[0];
            const dy = position[1] - player.position[1];
            const dz = position[2] - player.position[2];
            if (dx * dx + dy * dy + dz * dz <= range * range) return true;
        }
        return false;
    }
};

/// What an idle tick needs of the species.
pub const Species = struct {
    which: mob_state.Species,
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

/// What an idle tick reads of a mob besides its `Idle` group, none of which it changes.
pub const Still = struct {
    world: u32,
    position: [3]f64,
    persistent: bool,
    /// Mob.getId, whose low bit picks the goal selector's tick parity.
    given: i32,
};

/// One idle tick for a mob: Mob.checkDespawn, then Mob.tick as mob_tick.zig runs it for an
/// idle mob. Commits only when it stays idle; `gaze_yaw` is the mob's kept `gazeYaw`.
pub fn advance(hot: *Idle, still: Still, gaze_yaw: *f32, audience: Audience, species: Species) Outcome {
    var random = hot.random;
    var tick_count = hot.tick_count;
    var ambient = hot.ambient_sound_time;
    var no_action = hot.no_action_time;
    var calm_down = hot.tempt_calm_down;
    var gazing = hot.running == look_around_bit;
    var look_around_time = hot.look_around.time;
    var cooldown = hot.look_cooldown;
    var gaze = gaze_yaw.*;
    const position = still.position;
    const world = still.world;
    // Mob.checkDespawn: an animal never despawns, but the draw happens after 600 idle ticks.
    if (still.persistent) {
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
    var look_vector = hot.look_around.relative;
    const parity = @rem(tick_count +% still.given, 2);
    if (!(parity != 0 and tick_count > 1)) {
        // GoalSelector.tick: the look around stops when its time runs out, then each goal not
        // running may start.
        if (gazing and !(look_around_time >= 0)) gazing = false;
        if (calm_down > 0) {
            calm_down -= 1;
        } else if (audience.temptsNear(species.which, world, position, species.tempt_range)) {
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
            hot.look_wanted = wanted;
            hot.look_max_yaw = ai.head_rotation_speed;
            hot.look_max_pitch = ai.max_head_pitch;
            gaze = ai.lookYawAt(wanted, position) orelse std.math.nan(f32);
        }
    }
    // LookControl.tick. The pitch stays level, as `idle` and a look around both ensure.
    var head = hot.head_yaw;
    const body = hot.body_yaw;
    if (cooldown > 0) {
        cooldown -= 1;
        if (!std.math.isNan(gaze)) head = mth.rotateTowards(head, gaze, hot.look_max_yaw);
    } else {
        head = mth.rotateTowards(head, body, 10);
    }
    // BodyRotationControl, for a mob that stood still.
    var turn: mob_tick.Turn = .{ .body = body, .last_stable = hot.last_stable_head_yaw, .stable_time = hot.head_stable_time };
    mob_tick.turnStill(head, &turn);
    hot.random = random;
    hot.tick_count = tick_count;
    hot.ambient_sound_time = ambient;
    hot.no_action_time = no_action;
    hot.tempt_calm_down = calm_down;
    hot.navigation_tick += 1;
    setGazing(hot, gazing);
    hot.look_around = .{ .relative = look_vector, .time = look_around_time };
    hot.look_cooldown = cooldown;
    gaze_yaw.* = gaze;
    // Entity.baseTick keeps last tick's angles before anything turns.
    hot.old_head_yaw = hot.head_yaw;
    hot.old_body_yaw = body;
    hot.head_yaw = head;
    hot.body_yaw = turn.body;
    hot.last_stable_head_yaw = turn.last_stable;
    hot.head_stable_time = turn.stable_time;
    // AgeableMob.aiStep: a grown mob's breeding cooldown runs down, and it stays grown.
    if (hot.age > 0) hot.age -= 1;
    return .{ .idled = sound };
}

/// The look around runs or not, holding the move and look flags while it does.
fn setGazing(hot: *Idle, gazing: bool) void {
    hot.running = if (gazing) look_around_bit else 0;
    hot.move_owner = if (gazing) look_around_priority else null;
    hot.look_owner = if (gazing) look_around_priority else null;
}

// Lanes at once: as many 32-bit values as the target's vectors hold, the wider ones taking two.

pub const lane_count = std.simd.suggestVectorLength(f32) orelse 1;
const U64 = @Vector(lane_count, u64);
const I32 = @Vector(lane_count, i32);
const F32 = @Vector(lane_count, f32);
const F64 = @Vector(lane_count, f64);
const Mask = @Vector(lane_count, bool);

const none: Mask = @splat(false);

/// What `advanceBlock` found for a run of mobs, one per lane, kept until each lane is committed.
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

/// A run of idle mobs side by side in the mobs' table, one per lane: each group's rows from the
/// run's first.
pub const Run = struct {
    idle: *[lane_count]Idle,
    motion: *const [lane_count]Motion,
    persistent: [lane_count]bool,
    given: [lane_count]i32,
    gaze_yaw: [lane_count]f32,
};

/// One field of every lane's row.
fn gather(comptime T: type, rows: anytype, comptime field: []const u8) @Vector(lane_count, T) {
    var values: @Vector(lane_count, T) = undefined;
    inline for (0..lane_count) |lane| values[lane] = @field(rows[lane], field);
    return values;
}

/// `advance` for a run of lanes, all idle and ticking, without committing.
pub fn advanceBlock(run: Run, audience: Audience, species: Species) Block {
    const hot = run.idle;
    var rare = none;
    var seed: U64 = undefined;
    inline for (0..lane_count) |lane| seed[lane] = hot[lane].random.state();
    var tick_count = gather(i32, hot, "tick_count");
    var ambient = gather(i32, hot, "ambient_sound_time");
    var no_action = gather(i32, hot, "no_action_time");
    var calm_down = gather(i32, hot, "tempt_calm_down");
    var gazing: Mask = gather(u16, hot, "running") == @as(@Vector(lane_count, u16), @splat(look_around_bit));
    var look_around_time: I32 = undefined;
    inline for (0..lane_count) |lane| look_around_time[lane] = hot[lane].look_around.time;
    var cooldown = gather(i32, hot, "look_cooldown");
    const persistent: Mask = run.persistent;
    var positions: [lane_count][3]f64 = undefined;
    var x: F64 = undefined;
    var y: F64 = undefined;
    var z: F64 = undefined;
    var worlds: @Vector(lane_count, u32) = undefined;
    inline for (0..lane_count) |lane| {
        positions[lane] = run.motion[lane].position;
        x[lane] = positions[lane][0];
        y[lane] = positions[lane][1];
        z[lane] = positions[lane][2];
        worlds[lane] = run.motion[lane].world;
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
    const given: I32 = run.given;
    const parity_odd = ((tick_count +% given) & @as(I32, @splat(1))) != zero;
    const full = !(parity_odd & (tick_count > @as(I32, @splat(1))));
    gazing = gazing & !(full & (look_around_time < zero));
    const calming = full & (calm_down > zero);
    calm_down = @select(i32, calming, calm_down -% @as(I32, @splat(1)), calm_down);
    if (audience.holding_food[@backingInt(species.which)].len > 0) {
        inline for (0..lane_count) |lane| {
            if (full[lane] and !calming[lane] and audience.temptsNear(species.which, worlds[lane], positions[lane], species.tempt_range)) rare[lane] = true;
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
    const head = gather(f32, hot, "head_yaw");
    const body = gather(f32, hot, "body_yaw");
    const gaze_yaw: F32 = run.gaze_yaw;
    const counting_down = cooldown > zero;
    cooldown = @select(i32, counting_down, cooldown -% @as(I32, @splat(1)), cooldown);
    const toward_gaze = counting_down & (gaze_yaw == gaze_yaw);
    const target = @select(f32, toward_gaze, gaze_yaw, body);
    const limit = @select(f32, toward_gaze, gather(f32, hot, "look_max_yaw"), @as(F32, @splat(10)));
    const turned = rotateTowards(head, target, limit, &rare);
    const new_head = @select(f32, toward_gaze | !counting_down, turned, head);
    // BodyRotationControl for a mob that stood still.
    var last_stable = gather(f32, hot, "last_stable_head_yaw");
    var stable_time = gather(i32, hot, "head_stable_time");
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

/// Commits one lane of a run, as `advance` would have left it.
pub fn commitLane(hot: *Idle, block: *const Block, lane: usize) void {
    assert(!block.rare[lane]);
    hot.random = JavaRandom.restore(block.seed[lane]);
    hot.tick_count = block.tick_count[lane];
    hot.ambient_sound_time = block.ambient_sound_time[lane];
    hot.no_action_time = block.no_action_time[lane];
    hot.tempt_calm_down = block.tempt_calm_down[lane];
    hot.navigation_tick +%= 1;
    setGazing(hot, block.gazing[lane]);
    hot.look_around.time = block.look_around_time[lane];
    hot.look_cooldown = block.look_cooldown[lane];
    hot.old_head_yaw = hot.head_yaw;
    hot.old_body_yaw = hot.body_yaw;
    hot.head_yaw = block.head_yaw[lane];
    hot.body_yaw = block.body_yaw[lane];
    hot.last_stable_head_yaw = block.last_stable_head_yaw[lane];
    hot.head_stable_time = block.head_stable_time[lane];
    if (hot.age > 0) hot.age -= 1;
}

/// Commits a whole run with no rare lane.
pub fn commitBlock(run: Run, block: *const Block) void {
    assert(!block.any_rare);
    inline for (0..lane_count) |lane| commitLane(&run.idle[lane], block, lane);
}
