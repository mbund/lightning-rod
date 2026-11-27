//! Entity.applyEffectsFromBlocks: what the block a body stands on does to it (Block.stepOn), then
//! what every block and fluid it moved through this tick does (Entity.checkInsideBlocks), with
//! InsideBlockEffectApplier.StepBasedCollector ordering the effects as vanilla does.
//!
//! Every kind of body shares it: a kind hands its body over as a `Subject`, the entity fields
//! the blocks read and change, and answers for the rest through a `Host`.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;

const Box = body.Box;
const assert = std.debug.assert;

/// A body as the blocks see it: what they read of it as the tick's moves left it, and where
/// what they change lies, in the kind's own state.
pub const Subject = struct {
    world: u32,
    position: [3]f64,
    old_position: [3]f64,
    on_ground: bool,
    /// Entity.isRemoved: a removed body meets no block.
    removed: bool,
    width: f32,
    height: f32,
    velocity: *[3]f64,
    fall_distance: *f64,
    /// Entity.stuckSpeedMultiplier.
    stuck: *[3]f64,
    fire_ticks: *i32,
    ticks_frozen: *i32,
    in_powder_snow: *bool,
};

/// What can hold back the next move of a body that is not living: the blocks whose
/// makeStuckInBlock reaches it, Entity.stuckSpeedMultiplier as they leave it.
pub const Stuck = enum(u8) {
    none,
    cobweb,
    powder_snow,

    pub fn multiplier(self: Stuck) [3]f64 {
        return switch (self) {
            .none => .{ 0, 0, 0 },
            // WebBlock: 0.05F.
            .cobweb => .{ 0.25, @as(f32, 0.05), 0.25 },
            .powder_snow => .{ @as(f32, 0.9), 1.5, @as(f32, 0.9) },
        };
    }

    pub fn of(multiplier_value: [3]f64) Stuck {
        inline for (.{ Stuck.none, Stuck.cobweb, Stuck.powder_snow }) |each| {
            if (std.meta.eql(multiplier_value, each.multiplier())) return each;
        }
        unreachable;
    }
};

/// What a kind answers for its bodies, each function given the kind's own context.
pub fn Host(comptime Context: type) type {
    return struct {
        context: Context,
        /// The world the subject is in.
        level: *const body.Level,
        scratch: *Scratch,
        /// Entity.random, the subject's own.
        random: *JavaRandom,
        /// Level.random.
        level_random: *JavaRandom,
        /// The mobGriefing game rule.
        mob_griefing: bool,
        /// Entity.isAlive: what has died meets no more blocks this tick.
        alive: *const fn (Context) bool,
        fire_immune: *const fn (Context) anyerror!bool,
        /// Entity.getOnPos at the depth asked.
        on_position: *const fn (Context, depth: f32) anyerror![3]i32,
        /// Entity.hurtServer: whether it hurt.
        hurt: *const fn (Context, Damage, amount: f32) anyerror!bool,
        play_sound: *const fn (Context, Sound, volume: f32, pitch: f32) void,
        /// Level.destroyBlock without drops.
        destroy_block: *const fn (Context, [3]i32) anyerror!void,
        /// LayeredCauldronBlock.lowerFillLevel, under a burning body.
        lower_cauldron: *const fn (Context, [3]i32) anyerror!void,
        /// Entity.onAboveBubbleColumn, for a kind with its own: Entity's, `aboveBubbleColumn`,
        /// otherwise.
        above_bubble_column: ?*const fn (Context, drag: bool, [3]i32) anyerror!void = null,
        /// For living subjects, which some blocks act on alone.
        living: ?Living = null,
        /// For boats: WaterlilyBlock breaks under them, Level.destroyBlock with drops.
        break_lily_pad: ?*const fn (Context, [3]i32) anyerror!void = null,

        pub const Living = struct {
            crack_turtle_egg: *const fn (Context, [3]i32, state: u16) anyerror!void,
            /// Level.broadcastEntityEvent.
            entity_event: *const fn (Context, event: u8) void,
        };
    };
}

/// Entity.Movement: a stretch of a tick's travel, which block effects trace.
pub const Movement = struct { from: [3]f64, to: [3]f64, axis_independent: bool };

/// The damage blocks deal, by what vanilla names it.
pub const Damage = enum { cactus, in_fire, campfire, sweet_berry_bush, lava, hot_floor };

/// The sounds block effects make.
pub const Sound = enum { generic_burn, generic_extinguish_fire, honey_block_slide };

/// Vanilla keeps up to a hundred movements a tick, merging the oldest past that.
pub const maximum_movements = 100;

/// InsideBlockEffectType, in its order of application.
const Effect = enum(u2) { freeze, fire_ignite, lava_ignite, extinguish };

/// The deferred actions blocks queue around an effect.
const Action = union(enum) {
    effect: Effect,
    /// BaseFireBlock's damage after igniting.
    fire_hurt: f32,
    lava_hurt,
    /// PowderSnowBlock melts under a burning body before it is put out.
    melt_powder_snow: [3]i32,
    /// LayeredCauldronBlock lowers its level under a burning body before it is put out.
    lower_cauldron: [3]i32,
};

/// InsideBlockEffectApplier.StepBasedCollector, with room for what a tick of movement can
/// queue. Blocks queue at most one action before and after each effect at a time.
const Collector = struct {
    in_step: [4]bool = @splat(false),
    before: [4][8]Action = undefined,
    before_count: [4]u8 = @splat(0),
    after: [4][8]Action = undefined,
    after_count: [4]u8 = @splat(0),
    final: [128]Action = undefined,
    final_count: usize = 0,
    last_step: i32 = -1,
    /// Whether a block or fluid with an inside effect was within reach.
    acted: bool = false,

    /// Empty, without touching the arrays the counts guard.
    fn reset(self: *Collector) void {
        self.in_step = @splat(false);
        self.before_count = @splat(0);
        self.after_count = @splat(0);
        self.final_count = 0;
        self.last_step = -1;
        self.acted = false;
    }

    fn advanceStep(self: *Collector, step: i32) void {
        if (self.last_step == step) return;
        self.last_step = step;
        self.flush();
    }

    fn flush(self: *Collector) void {
        for (0..4) |index| {
            for (self.before[index][0..self.before_count[index]]) |action| self.push(action);
            self.before_count[index] = 0;
            if (self.in_step[index]) {
                self.in_step[index] = false;
                self.push(.{ .effect = @fromBackingInt(@intCast(index)) });
            }
            for (self.after[index][0..self.after_count[index]]) |action| self.push(action);
            self.after_count[index] = 0;
        }
    }

    fn push(self: *Collector, action: Action) void {
        // A tick of movement crosses a few dozen blocks at most.
        std.debug.assert(self.final_count < self.final.len);
        self.final[self.final_count] = action;
        self.final_count += 1;
    }

    fn apply(self: *Collector, effect: Effect) void {
        self.in_step[@backingInt(effect)] = true;
    }

    fn runBefore(self: *Collector, effect: Effect, action: Action) void {
        const index = @backingInt(effect);
        if (self.before_count[index] == self.before[index].len) return;
        self.before[index][self.before_count[index]] = action;
        self.before_count[index] += 1;
    }

    fn runAfter(self: *Collector, effect: Effect, action: Action) void {
        const index = @backingInt(effect);
        if (self.after_count[index] == self.after[index].len) return;
        self.after[index][self.after_count[index]] = action;
        self.after_count[index] += 1;
    }
};

/// What block effects work in, kept by the host so its arrays are not filled anew each tick.
pub const Scratch = struct {
    collector: Collector = .{},
    visited: Visited = .{},
    along: Visited = .{},
};

/// Entity.applyEffectsFromBlocks over the movements recorded this tick. Whether a block under
/// or around the subject could act on it, as resting bodies need none to.
pub fn apply(comptime Context: type, host: *const Host(Context), subject: Subject, recorded: []const Movement) !bool {
    // Release builds keep safety, which fills undefined memory: these movements are written
    // before they are read, and filling them every body's tick cost more than the rest.
    @setRuntimeSafety(false);
    var movements: [maximum_movements + 1]Movement = undefined;
    return Walk(Context).apply(host, subject, recorded, &movements);
}

/// Entity.isOnFire on the server.
pub fn onFire(comptime Context: type, host: *const Host(Context), fire_ticks: i32) !bool {
    return fire_ticks > 0 and !try host.fire_immune(host.context);
}

/// Entity.onAboveBubbleColumn as Entity has it: up or down at the column's top, and the
/// particles' draws from the level's random.
pub fn aboveBubbleColumn(level_random: *JavaRandom, velocity: *[3]f64, drag: bool) void {
    velocity[1] = if (drag) @max(-0.9, velocity[1] - 0.03) else @min(1.8, velocity[1] + 0.1);
    // Entity.sendBubbleColumnParticles draws from the level's random.
    for (0..2) |_| for (0..4) |_| {
        _ = level_random.nextDouble();
    };
}

const verify_skips = @import("builtin").mode == .debug;

/// Blocks visited this tick, which act once however many movements cross them.
const Visited = struct {
    positions: [256][3]i32 = undefined,
    count: usize = 0,

    fn add(self: *Visited, position: [3]i32) bool {
        for (self.positions[0..self.count]) |seen| if (std.meta.eql(seen, position)) return false;
        if (self.count == self.positions.len) return true;
        self.positions[self.count] = position;
        self.count += 1;
        return true;
    }
};

fn contains(visited: *const Visited, position: [3]i32) bool {
    for (visited.positions[0..visited.count]) |seen| if (std.meta.eql(seen, position)) return true;
    return false;
}

fn boxOf(subject: Subject, position: [3]f64) Box {
    return body.makeBox(position, subject.width, subject.height);
}

/// The walk over the blocks, for one kind's host.
fn Walk(comptime Context: type) type {
    return struct {
        const H = *const Host(Context);

        fn apply(host: H, subject: Subject, recorded: []const Movement, movements: *[maximum_movements + 1]Movement) !bool {
            assert(recorded.len <= maximum_movements);
            var count: usize = recorded.len;
            @memcpy(movements[0..count], recorded);
            if (count == 0) {
                movements[0] = .{ .from = subject.old_position, .to = subject.position, .axis_independent = false };
                count = 1;
            } else {
                const last = movements[count - 1].to;
                const dx = last[0] - subject.position[0];
                const dy = last[1] - subject.position[1];
                const dz = last[2] - subject.position[2];
                if (dx * dx + dy * dy + dz * dz > @as(f64, @as(f32, 9.9999994e-11))) {
                    movements[count] = .{ .from = last, .to = subject.position, .axis_independent = false };
                    count += 1;
                }
            }
            if (subject.removed) return true;
            var acted = false;
            if (subject.on_ground) acted = try stepOn(host, subject);
            const burning = try onFire(Context, host, subject.fire_ticks.*);
            const freezing = subject.ticks_frozen.* > 0;
            const fire_before = subject.fire_ticks.*;
            const collector = &host.scratch.collector;
            collector.reset();
            // With no fluid and no block that acts on a body inside it around the one ticking,
            // the walk finds nothing, which Debug still checks.
            const quiet = try quietAround(host, subject, movements[0..count]);
            if (!quiet or verify_skips) try checkInsideBlocks(host, subject, movements[0..count], collector);
            if (quiet) assert(collector.final_count == 0 and !collector.acted and collector.before_count[0] == 0);
            collector.flush();
            for (collector.final[0..collector.final_count]) |action| {
                if (!host.alive(host.context)) break;
                try run(host, subject, action);
            }
            if ((burning and !try onFire(Context, host, subject.fire_ticks.*)) or (freezing and subject.ticks_frozen.* <= 0)) {
                // Entity.playEntityOnFireExtinguishedSound.
                const pitch = 1.6 + (host.random.nextFloat() - host.random.nextFloat()) * 0.4;
                host.play_sound(host.context, .generic_extinguish_fire, 0.7, pitch);
            }
            const ignited = subject.fire_ticks.* > fire_before;
            // Entity.getFireImmuneTicks, which is none.
            if (!try onFire(Context, host, subject.fire_ticks.*) and !ignited) subject.fire_ticks.* = 0;
            return acted or collector.acted;
        }

        /// Block.stepOn for the block under the subject, and whether that block does anything.
        fn stepOn(host: H, subject: Subject) !bool {
            const level = host.level;
            const at = try host.on_position(host.context, 0.2);
            const state = try level.state(at[0], at[1], at[2]);
            const kind = level.blocks.get(state).kind;
            const living = host.living != null;
            switch (kind) {
                // MagmaBlock: living bodies that do not step carefully, which mobs never do.
                .magma_block => if (living) {
                    _ = try host.hurt(host.context, .hot_floor, 1.0);
                },
                // SlimeBlock: slow on it unless falling or rising fast.
                .slime_block => {
                    const vertical = @abs(subject.velocity[1]);
                    if (vertical < 0.1) {
                        const factor = 0.4 + vertical * 0.2;
                        subject.velocity[0] *= factor;
                        subject.velocity[2] *= factor;
                    }
                },
                // TurtleEggBlock: one step of a living body in a hundred cracks an egg, where
                // mobs may grief.
                .turtle_egg => if (host.living) |only| if (host.mob_griefing and host.level_random.nextIntBounded(100) == 0) try only.crack_turtle_egg(host.context, at, state),
                else => {},
            }
            return kind == .slime_block or (living and (kind == .magma_block or kind == .turtle_egg));
        }

        /// Whether no cell the movements could visit, one block more for the fluid above, lies
        /// in a section that may hold a fluid or a block that acts on what is inside it.
        fn quietAround(host: H, subject: Subject, movements: []const Movement) !bool {
            const half: f64 = subject.width / 2.0;
            const tall: f64 = subject.height;
            var low: [3]f64 = movements[0].from;
            var high: [3]f64 = movements[0].from;
            for (movements) |movement| for ([2][3]f64{ movement.from, movement.to }) |point| for (0..3) |axis| {
                low[axis] = @min(low[axis], point[axis]);
                high[axis] = @max(high[axis], point[axis]);
            };
            const first: [3]i32 = .{ mth.floor(low[0] - half) - 1, mth.floor(low[1]) - 1, mth.floor(low[2] - half) - 1 };
            const last: [3]i32 = .{ mth.floor(high[0] + half) + 1, mth.floor(high[1] + tall) + 1, mth.floor(high[2] + half) + 1 };
            return try host.level.without(mob_blocks.mark_fluid | mob_blocks.mark_inside, first, last);
        }

        /// Entity.checkInsideBlocks over the tick's movements, each split by axis where it moved
        /// along them one at a time.
        fn checkInsideBlocks(host: H, subject: Subject, movements: []const Movement, collector: *Collector) !void {
            const visited = &host.scratch.visited;
            visited.count = 0;
            for (movements) |movement| {
                var from = movement.from;
                const delta: [3]f64 = .{ movement.to[0] - from[0], movement.to[1] - from[1], movement.to[2] - from[2] };
                if (movement.axis_independent and delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] > 0) {
                    const order: [3]usize = if (@abs(delta[0]) < @abs(delta[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };
                    for (order) |axis| {
                        if (delta[axis] == 0) continue;
                        var to = from;
                        to[axis] += delta[axis];
                        try checkSegment(host, subject, from, to, collector, visited);
                        from = to;
                    }
                } else {
                    try checkSegment(host, subject, movement.from, movement.to, collector, visited);
                }
            }
        }

        /// BlockGetter.forEachBlockIntersectedBetween with Entity.checkInsideBlocks' visitor.
        fn checkSegment(host: H, subject: Subject, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !void {
            const box = boxOf(subject, subject.position);
            const at_to = box.move(.{ to[0] - subject.position[0], to[1] - subject.position[1], to[2] - subject.position[2] }).inflate(-1.0e-5, -1.0e-5, -1.0e-5);
            const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
            const length = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
            if (length < @as(f64, @as(f32, 0.99999)) * @as(f64, @as(f32, 0.99999))) {
                try visitBox(host, subject, at_to, 0, from, to, collector, visited, null);
                return;
            }
            // Long moves walk the box's corner along the travel first, then the rest of the box.
            const along = &host.scratch.along;
            along.count = 0;
            const step = try travel(host, subject, at_to, delta, from, to, collector, visited, along);
            try visitBox(host, subject, at_to, step + 1, from, to, collector, visited, along);
        }

        fn visitBox(host: H, subject: Subject, target: Box, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, skip: ?*Visited) !void {
            // BlockPos.betweenClosed: x fastest, then y, then z.
            var z = mth.floor(target.min[2]);
            while (z <= mth.floor(target.max[2])) : (z += 1) {
                var y = mth.floor(target.min[1]);
                while (y <= mth.floor(target.max[1])) : (y += 1) {
                    var x = mth.floor(target.min[0]);
                    while (x <= mth.floor(target.max[0])) : (x += 1) {
                        if (skip) |seen| if (contains(seen, .{ x, y, z })) continue;
                        if (!try visit(host, subject, .{ x, y, z }, step, from, to, collector, visited)) return;
                    }
                }
            }
        }

        /// BlockGetter.addCollisionsAlongTravel: the cells the box's low corner crosses on its way, and
        /// the boxes it fills there, each at its step.
        fn travel(host: H, subject: Subject, target: Box, delta: [3]f64, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, along: *Visited) !i32 {
            const end = target.min;
            const start: [3]f64 = .{ end[0] - delta[0], end[1] - delta[1], end[2] - delta[2] };
            var cell: [3]i32 = .{ mth.floor(start[0]), mth.floor(start[1]), mth.floor(start[2]) };
            var sign: [3]i32 = undefined;
            var increment: [3]f64 = undefined;
            var next: [3]f64 = undefined;
            for (0..3) |axis| {
                sign[axis] = if (delta[axis] > 0) 1 else if (delta[axis] < 0) -1 else 0;
                increment[axis] = if (sign[axis] == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(sign[axis])) / delta[axis];
                const fraction = start[axis] - @floor(start[axis]);
                next[axis] = increment[axis] * (if (sign[axis] > 0) 1.0 - fraction else fraction);
            }
            var step: i32 = 0;
            const size: [3]f64 = .{ target.max[0] - target.min[0], target.max[1] - target.min[1], target.max[2] - target.min[2] };
            while (next[0] <= 1.0 or next[1] <= 1.0 or next[2] <= 1.0) {
                if (next[0] < next[1]) {
                    if (next[0] < next[2]) {
                        cell[0] += sign[0];
                        next[0] += increment[0];
                    } else {
                        cell[2] += sign[2];
                        next[2] += increment[2];
                    }
                } else if (next[1] < next[2]) {
                    cell[1] += sign[1];
                    next[1] += increment[1];
                } else {
                    cell[2] += sign[2];
                    next[2] += increment[2];
                }
                const current = step;
                step += 1;
                if (current > 16) break;
                const hit = clipCell(cell, start, end) orelse continue;
                const corner: [3]f64 = .{
                    mth.clampDouble(hit[0], @as(f64, @floatFromInt(cell[0])) + @as(f64, @as(f32, 1.0e-5)), @as(f64, @floatFromInt(cell[0])) + 1.0 - @as(f64, @as(f32, 1.0e-5))),
                    mth.clampDouble(hit[1], @as(f64, @floatFromInt(cell[1])) + @as(f64, @as(f32, 1.0e-5)), @as(f64, @floatFromInt(cell[1])) + 1.0 - @as(f64, @as(f32, 1.0e-5))),
                    mth.clampDouble(hit[2], @as(f64, @floatFromInt(cell[2])) + @as(f64, @as(f32, 1.0e-5)), @as(f64, @floatFromInt(cell[2])) + 1.0 - @as(f64, @as(f32, 1.0e-5))),
                };
                const last: [3]i32 = .{ mth.floor(corner[0] + size[0]), mth.floor(corner[1] + size[1]), mth.floor(corner[2] + size[2]) };
                var x = cell[0];
                while (x <= last[0]) : (x += 1) {
                    var y = cell[1];
                    while (y <= last[1]) : (y += 1) {
                        var z = cell[2];
                        while (z <= last[2]) : (z += 1) {
                            if (!along.add(.{ x, y, z })) continue;
                            if (!try visit(host, subject, .{ x, y, z }, current, from, to, collector, visited)) return -1;
                        }
                    }
                }
            }
            return step;
        }

        /// Entity.checkInsideBlocks' visitor for one block: the block's own effect when the body
        /// meets its inside shape, then its fluid's.
        fn visit(host: H, subject: Subject, position: [3]i32, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !bool {
            if (!host.alive(host.context)) return false;
            const level = host.level;
            const state = try level.state(position[0], position[1], position[2]);
            const entry = level.blocks.get(state);
            if (entry.flags.air) return true;
            if (!visited.add(position)) return true;
            if (insideActs(entry.kind) or game_data.physics.get(state).fluid != .none) collector.acted = true;
            if (try meetsInside(host, subject, state, position, from, to)) {
                collector.advanceStep(step);
                try entityInside(host, subject, state, position, collector);
            }
            const physics = game_data.physics.get(state);
            if (physics.fluid != .none and try meetsFluid(host, subject, position, physics, from, to)) {
                collector.advanceStep(step);
                // LavaFluid and WaterFluid.entityInside.
                if (physics.fluid == .lava) {
                    collector.apply(.lava_ignite);
                    collector.runAfter(.lava_ignite, .lava_hurt);
                } else {
                    collector.apply(.extinguish);
                }
            }
            return true;
        }

        /// BlockState.getEntityInsideCollisionShape: the whole block for most, the filled inside
        /// of cauldrons for theirs.
        fn meetsInside(host: H, subject: Subject, state: u16, position: [3]i32, from: [3]f64, to: [3]f64) !bool {
            const level = host.level;
            const entry = level.blocks.get(state);
            const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
            // PowderSnowBlock.getEntityInsideCollisionShape: its collision shape for the body,
            // the whole block where it has none, as for a body that has not fallen far.
            if (entry.kind == .powder_snow) {
                const shape = body.collisionBoxes(level, state, position[0], position[1], position[2], .{ .bottom = subject.position[1], .fall_distance = subject.fall_distance.* });
                if (shape.count == 0) return true;
                const falling: Box = (body.Shape{ .boxes = shape, .x = position[0], .y = position[1], .z = position[2] }).get(0);
                return collidedMovingFrom(subject, from, to, &.{falling});
            }
            const filled: ?f64 = switch (entry.kind) {
                .lava_cauldron => 15.0,
                .water_cauldron, .powder_snow_cauldron => 6.0 + @as(f64, @floatFromInt(entry.flags.level)) * 3.0,
                else => null,
            };
            const height = filled orelse return true;
            // Shapes.or(AbstractCauldronBlock.SHAPE, the content column): the cauldron's outline
            // and what fills it.
            const outline = game_data.physics.outline(state, position[0], position[2]);
            var boxes: [16]Box = undefined;
            var count: usize = 0;
            for (0..outline.count) |index| {
                if (count == boxes.len) break;
                const value = outline.get(index);
                boxes[count] = .{ .min = .{ origin[0] + value[0], origin[1] + value[1], origin[2] + value[2] }, .max = .{ origin[0] + value[3], origin[1] + value[4], origin[2] + value[5] } };
                count += 1;
            }
            boxes[@min(count, boxes.len - 1)] = .{ .min = .{ origin[0] + 2.0 / 16.0, origin[1] + 4.0 / 16.0, origin[2] + 2.0 / 16.0 }, .max = .{ origin[0] + 14.0 / 16.0, origin[1] + height / 16.0, origin[2] + 14.0 / 16.0 } };
            count = @min(count + 1, boxes.len);
            return collidedMovingFrom(subject, from, to, boxes[0..count]);
        }

        /// Entity.collidedWithFluid: the fluid's box, its height in the block, met along the move.
        fn meetsFluid(host: H, subject: Subject, position: [3]i32, physics: game_data.physics_data.State, from: [3]f64, to: [3]f64) !bool {
            const above = try host.level.fluid(position[0], position[1] + 1, position[2]);
            const height: f64 = if (above.fluid == physics.fluid) 1.0 else physics.height();
            const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
            const fluid_box: Box = .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + height, origin[2] + 1 } };
            return collidedMovingFrom(subject, from, to, &.{fluid_box});
        }

        /// BlockBehaviour.entityInside, for the blocks that do something to what is inside them.
        fn entityInside(host: H, subject: Subject, state: u16, position: [3]i32, collector: *Collector) !void {
            const level = host.level;
            const entry = level.blocks.get(state);
            const living = host.living != null;
            switch (entry.kind) {
                .cactus => _ = try host.hurt(host.context, .cactus, 1.0),
                .fire, .soul_fire => {
                    collector.apply(.fire_ignite);
                    collector.runAfter(.fire_ignite, .{ .fire_hurt = if (entry.kind == .soul_fire) 2.0 else 1.0 });
                },
                // CampfireBlock burns living bodies alone.
                .campfire, .soul_campfire => if (living and entry.flags.lit_campfire) {
                    _ = try host.hurt(host.context, .campfire, if (entry.kind == .soul_campfire) 2.0 else 1.0);
                },
                // SweetBerryBushBlock catches living bodies alone.
                .sweet_berry_bush => if (living) {
                    makeStuck(subject, .{ @as(f32, 0.8), 0.75, @as(f32, 0.8) });
                    if (entry.flags.aged) {
                        // The body moved since last tick, across rather than only up or down.
                        const dx = subject.old_position[0] - subject.position[0];
                        const dz = subject.old_position[2] - subject.position[2];
                        if (dx * dx + dz * dz > 0 and (@abs(dx) >= @as(f64, @as(f32, 0.003)) or @abs(dz) >= @as(f64, @as(f32, 0.003)))) {
                            _ = try host.hurt(host.context, .sweet_berry_bush, 1.0);
                        }
                    }
                },
                .cobweb => makeStuck(subject, Stuck.cobweb.multiplier()),
                .powder_snow => {
                    // PowderSnowBlock holds what is not living, and a living body whose feet are
                    // in it.
                    const at: [3]i32 = .{ mth.floor(subject.position[0]), mth.floor(subject.position[1]), mth.floor(subject.position[2]) };
                    if (!living or level.blocks.get(try level.state(at[0], at[1], at[2])).kind == .powder_snow) makeStuck(subject, Stuck.powder_snow.multiplier());
                    collector.runBefore(.extinguish, .{ .melt_powder_snow = position });
                    collector.apply(.freeze);
                    collector.apply(.extinguish);
                },
                .honey_block => try honeySlide(host, subject, position),
                // WaterlilyBlock.entityInside: a boat breaks it, and its drops fall.
                .lily_pad => if (host.break_lily_pad) |breaks| try breaks(host.context, position),
                .bubble_column => {
                    const above = try level.state(position[0], position[1] + 1, position[2]);
                    const open = body.contextFreeBoxes(above, position[0], position[2]).count == 0 and game_data.physics.get(above).fluid == .none;
                    const drag = entry.flags.drag;
                    if (open) {
                        if (host.above_bubble_column) |own| try own(host.context, drag, position) else aboveBubbleColumn(host.level_random, subject.velocity, drag);
                    } else {
                        subject.velocity[1] = if (drag) @max(-0.3, subject.velocity[1] - 0.03) else @min(0.7, subject.velocity[1] + 0.06);
                        subject.fall_distance.* = 0;
                    }
                },
                .lava_cauldron => {
                    collector.apply(.lava_ignite);
                    collector.runAfter(.lava_ignite, .lava_hurt);
                },
                .water_cauldron, .powder_snow_cauldron => {
                    collector.runBefore(.extinguish, .{ .lower_cauldron = position });
                    collector.apply(.extinguish);
                },
                else => {},
            }
        }

        /// HoneyBlock.entityInside: a body falling down the side of a honey block slides slowly.
        fn honeySlide(host: H, subject: Subject, position: [3]i32) !void {
            if (subject.on_ground) return;
            if (subject.position[1] > @as(f64, @floatFromInt(position[1])) + 0.9375 - 1.0e-7) return;
            const velocity = subject.velocity;
            const old_y = velocity[1] / @as(f64, @as(f32, 0.98)) + 0.08;
            if (old_y >= -0.08) return;
            const dx = @abs(@as(f64, @floatFromInt(position[0])) + 0.5 - subject.position[0]);
            const dz = @abs(@as(f64, @floatFromInt(position[2])) + 0.5 - subject.position[2]);
            const reach = 0.4375 + @as(f64, subject.width / 2.0);
            if (!(dx + 1.0e-7 > reach or dz + 1.0e-7 > reach)) return;
            const new_y = (-0.05 - 0.08) * @as(f64, @as(f32, 0.98));
            if (old_y < -0.13) {
                const scale = -0.05 / old_y;
                velocity.* = .{ velocity[0] * scale, new_y, velocity[2] * scale };
            } else {
                velocity[1] = new_y;
            }
            subject.fall_distance.* = 0;
            // HoneyBlock.doesEntityDoHoneyBlockSlideEffects: living bodies, among those that tick
            // here.
            const only = host.living orelse return;
            if (host.level_random.nextIntBounded(5) == 0) host.play_sound(host.context, .honey_block_slide, 1, 1);
            if (host.level_random.nextIntBounded(5) == 0) only.entity_event(host.context, 53);
        }

        fn run(host: H, subject: Subject, action: Action) !void {
            switch (action) {
                .effect => |effect| switch (effect) {
                    .freeze => {
                        subject.in_powder_snow.* = true;
                        subject.ticks_frozen.* = @min(140, subject.ticks_frozen.* + 1);
                    },
                    // BaseFireBlock.fireIgnite.
                    .fire_ignite => if (!try host.fire_immune(host.context)) {
                        if (subject.fire_ticks.* < 0) subject.fire_ticks.* += 1;
                        if (subject.fire_ticks.* >= 0) ignite(subject, 160);
                    },
                    // Entity.lavaIgnite.
                    .lava_ignite => if (!try host.fire_immune(host.context)) ignite(subject, 300),
                    .extinguish => subject.fire_ticks.* = 0,
                },
                .fire_hurt => |amount| _ = try host.hurt(host.context, .in_fire, amount),
                // Entity.lavaHurt, with its sound when it hurts.
                .lava_hurt => if (!try host.fire_immune(host.context)) {
                    if (try host.hurt(host.context, .lava, 4.0)) host.play_sound(host.context, .generic_burn, 0.4, 2.0 + host.random.nextFloat() * 0.4);
                },
                .melt_powder_snow => |position| if (try onFire(Context, host, subject.fire_ticks.*) and host.mob_griefing) try host.destroy_block(host.context, position),
                .lower_cauldron => |position| if (try onFire(Context, host, subject.fire_ticks.*)) try host.lower_cauldron(host.context, position),
            }
        }
    };
}

/// Entity.collidedWithShapeMovingFrom with AABB.collidedAlongVector: the box at the start swept
/// along the move meets one of the boxes.
fn collidedMovingFrom(subject: Subject, from: [3]f64, to: [3]f64, boxes: []const Box) bool {
    const start = boxOf(subject, from);
    const half: [3]f64 = .{ (start.max[0] - start.min[0]) * 0.5, (start.max[1] - start.min[1]) * 0.5, (start.max[2] - start.min[2]) * 0.5 };
    const center: [3]f64 = .{ (start.min[0] + start.max[0]) * 0.5, (start.min[1] + start.max[1]) * 0.5, (start.min[2] + start.max[2]) * 0.5 };
    const end: [3]f64 = .{ center[0] + to[0] - from[0], center[1] + to[1] - from[1], center[2] + to[2] - from[2] };
    for (boxes) |box| {
        const grown = box.inflate(half[0], half[1], half[2]);
        if (inside(grown, end) or inside(grown, center)) return true;
        if (clipBox(grown, center, end)) return true;
    }
    return false;
}

/// Entity.makeStuckInBlock.
fn makeStuck(subject: Subject, multiplier: [3]f64) void {
    subject.fall_distance.* = 0;
    subject.stuck.* = multiplier;
}

/// Entity.igniteForTicks.
fn ignite(subject: Subject, ticks: i32) void {
    if (subject.fire_ticks.* < ticks) subject.fire_ticks.* = ticks;
    subject.ticks_frozen.* = 0;
}

/// AABB.clip for a unit cell: where the segment enters it, if it does.
fn clipCell(cell: [3]i32, from: [3]f64, to: [3]f64) ?[3]f64 {
    const low: [3]f64 = .{ @floatFromInt(cell[0]), @floatFromInt(cell[1]), @floatFromInt(cell[2]) };
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    var enter: f64 = 0;
    var leave: f64 = 1;
    for (0..3) |axis| {
        if (delta[axis] == 0) {
            if (from[axis] < low[axis] or from[axis] > low[axis] + 1) return null;
            continue;
        }
        var near = (low[axis] - from[axis]) / delta[axis];
        var far = (low[axis] + 1 - from[axis]) / delta[axis];
        if (near > far) std.mem.swap(f64, &near, &far);
        enter = @max(enter, near);
        leave = @min(leave, far);
        if (enter > leave) return null;
    }
    return .{ from[0] + delta[0] * enter, from[1] + delta[1] * enter, from[2] + delta[2] * enter };
}

fn inside(box: Box, point: [3]f64) bool {
    return point[0] >= box.min[0] and point[0] < box.max[0] and point[1] >= box.min[1] and point[1] < box.max[1] and point[2] >= box.min[2] and point[2] < box.max[2];
}

fn clipBox(box: Box, from: [3]f64, to: [3]f64) bool {
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    var enter: f64 = 0;
    var leave: f64 = 1;
    for (0..3) |axis| {
        if (delta[axis] == 0) {
            if (from[axis] < box.min[axis] or from[axis] > box.max[axis]) return false;
            continue;
        }
        var near = (box.min[axis] - from[axis]) / delta[axis];
        var far = (box.max[axis] - from[axis]) / delta[axis];
        if (near > far) std.mem.swap(f64, &near, &far);
        enter = @max(enter, near);
        leave = @min(leave, far);
        if (enter > leave) return false;
    }
    return true;
}

/// The kinds entityInside does something for, lit or not.
pub fn insideActs(kind: mob_blocks.Kind) bool {
    return switch (kind) {
        .cactus, .fire, .soul_fire, .campfire, .soul_campfire, .sweet_berry_bush, .cobweb, .powder_snow, .honey_block, .bubble_column, .lava_cauldron, .water_cauldron, .powder_snow_cauldron, .lily_pad => true,
        else => false,
    };
}
