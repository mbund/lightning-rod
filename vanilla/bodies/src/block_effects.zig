//! Entity.applyEffectsFromBlocks: what the block a body stands on does to it (Block.stepOn), then
//! what every block and fluid it moved through this tick does (Entity.checkInsideBlocks), with
//! InsideBlockEffectApplier.StepBasedCollector ordering the effects as vanilla does.
//!
//! Generic over what is inside, the subject, and the host that ticks it. A subject has an
//! entity's fields: world, position, old_position, velocity, on_ground, fall_distance, stuck,
//! fire_ticks, ticks_frozen, in_powder_snow and removed. Its host answers for it:
//!
//!   living: bool, a declaration: whether subjects are living entities, which some blocks
//!     act on alone
//!   boat: bool, a declaration: whether subjects are boats, which lily pads break under. A boat
//!     host answers breakBlock(world, [3]i32) !void, Level.destroyBlock with drops
//!   level(world) body.Level, scratch() *Scratch
//!   width(subject) f32, height(subject) f32, alive(subject) bool, fireImmune(subject) !bool
//!   onPosition(subject, depth: f32) ![3]i32, Entity.getOnPos
//!   hurt(subject, Damage, amount: f32) !bool
//!   playSound(subject, Sound, volume: f32, pitch: f32) void, random(subject) *JavaRandom
//!   levelRandom() *JavaRandom, mobGriefing() bool
//!   destroyBlock(world, [3]i32) !void, lowerCauldron(world, [3]i32) !void,
//!   crackTurtleEgg(world, [3]i32, state: u16) !void, entityEvent(subject, event: u8) void
//!   onAboveBubbleColumn(subject, drag: bool, [3]i32) !void, Entity.onAboveBubbleColumn, which most
//!     hosts answer with `aboveBubbleColumn` and boats with their own

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const mob_blocks = @import("mob_blocks.zig");

const Box = body.Box;
const assert = std.debug.assert;

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
pub fn apply(host: anytype, subject: anytype, recorded: []const Movement) !bool {
    // Release builds keep safety, which fills undefined memory: these movements are written
    // before they are read, and filling them every body's tick cost more than the rest.
    @setRuntimeSafety(false);
    var movements: [maximum_movements + 1]Movement = undefined;
    return applyWith(host, subject, recorded, &movements);
}

fn applyWith(host: anytype, subject: anytype, recorded: []const Movement, movements: *[maximum_movements + 1]Movement) !bool {
    assert(recorded.len <= maximum_movements);
    var count: usize = recorded.len;
    @memcpy(movements[0..count], recorded);
    if (count == 0) {
        movements[0] = .{ .from = fieldOf(subject, "old_position").*, .to = fieldOf(subject, "position").*, .axis_independent = false };
        count = 1;
    } else {
        const last = movements[count - 1].to;
        const dx = last[0] - fieldOf(subject, "position").*[0];
        const dy = last[1] - fieldOf(subject, "position").*[1];
        const dz = last[2] - fieldOf(subject, "position").*[2];
        if (dx * dx + dy * dy + dz * dz > @as(f64, @as(f32, 9.9999994e-11))) {
            movements[count] = .{ .from = last, .to = fieldOf(subject, "position").*, .axis_independent = false };
            count += 1;
        }
    }
    if (fieldOf(subject, "removed").*) return true;
    var acted = false;
    if (fieldOf(subject, "on_ground").*) acted = try stepOn(host, subject);
    const burning = try onFire(host, subject);
    const freezing = fieldOf(subject, "ticks_frozen").* > 0;
    const fire_before = fieldOf(subject, "fire_ticks").*;
    const collector = &host.scratch().collector;
    collector.reset();
    // With no fluid and no block that acts on a body inside it around the one ticking, the walk
    // finds nothing, which Debug still checks.
    const quiet = quietAround(host, subject, movements[0..count]);
    if (!quiet or verify_skips) try checkInsideBlocks(host, subject, movements[0..count], collector);
    if (quiet) assert(collector.final_count == 0 and !collector.acted and collector.before_count[0] == 0);
    collector.flush();
    for (collector.final[0..collector.final_count]) |action| {
        if (!host.alive(subject)) break;
        try run(host, subject, action);
    }
    if ((burning and !try onFire(host, subject)) or (freezing and fieldOf(subject, "ticks_frozen").* <= 0)) {
        // Entity.playEntityOnFireExtinguishedSound.
        const random = host.random(subject);
        const pitch = 1.6 + (random.nextFloat() - random.nextFloat()) * 0.4;
        host.playSound(subject, .generic_extinguish_fire, 0.7, pitch);
    }
    const ignited = fieldOf(subject, "fire_ticks").* > fire_before;
    if (!try onFire(host, subject) and !ignited) fieldOf(subject, "fire_ticks").* = 0;
    return acted or collector.acted;
}

/// Entity.isOnFire on the server.
pub fn onFire(host: anytype, subject: anytype) !bool {
    return fieldOf(subject, "fire_ticks").* > 0 and !try host.fireImmune(subject);
}

/// Block.stepOn for the block under the subject, and whether that block does anything.
fn stepOn(host: anytype, subject: anytype) !bool {
    const level = host.level(fieldOf(subject, "world").*);
    const at = try host.onPosition(subject, 0.2);
    const state = try level.state(at[0], at[1], at[2]);
    const kind = level.blocks.get(state).kind;
    const living = @TypeOf(host).living;
    switch (kind) {
        // MagmaBlock: living bodies that do not step carefully, which mobs never do.
        .magma_block => if (living) {
            _ = try host.hurt(subject, .hot_floor, 1.0);
        },
        // SlimeBlock: slow on it unless falling or rising fast.
        .slime_block => {
            const vertical = @abs(fieldOf(subject, "velocity").*[1]);
            if (vertical < 0.1) {
                const factor = 0.4 + vertical * 0.2;
                fieldOf(subject, "velocity").*[0] *= factor;
                fieldOf(subject, "velocity").*[2] *= factor;
            }
        },
        // TurtleEggBlock: one step of a living body in a hundred cracks an egg, where mobs may
        // grief.
        .turtle_egg => if (living and host.mobGriefing() and host.levelRandom().nextIntBounded(100) == 0) try host.crackTurtleEgg(fieldOf(subject, "world").*, at, state),
        else => {},
    }
    return kind == .slime_block or (living and (kind == .magma_block or kind == .turtle_egg));
}

/// Whether the window around the body holds every cell the movements could visit, one block
/// more for the fluid above, and none of them is a fluid or acts on what is inside it.
fn quietAround(host: anytype, subject: anytype, movements: []const Movement) bool {
    const level = host.level(fieldOf(subject, "world").*);
    const half: f64 = host.width(subject) / 2.0;
    const tall: f64 = host.height(subject);
    var low: [3]f64 = movements[0].from;
    var high: [3]f64 = movements[0].from;
    for (movements) |movement| for ([2][3]f64{ movement.from, movement.to }) |point| for (0..3) |axis| {
        low[axis] = @min(low[axis], point[axis]);
        high[axis] = @max(high[axis], point[axis]);
    };
    const first: [3]i32 = .{ mth.floor(low[0] - half) - 1, mth.floor(low[1]) - 1, mth.floor(low[2] - half) - 1 };
    const last: [3]i32 = .{ mth.floor(high[0] + half) + 1, mth.floor(high[1] + tall) + 1, mth.floor(high[2] + half) + 1 };
    return level.without(mob_blocks.mark_fluid | mob_blocks.mark_inside, first, last);
}

const verify_skips = @import("builtin").mode == .debug;

/// Entity.checkInsideBlocks over the tick's movements, each split by axis where it moved
/// along them one at a time.
fn checkInsideBlocks(host: anytype, subject: anytype, movements: []const Movement, collector: *Collector) !void {
    const visited = &host.scratch().visited;
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

fn boxOf(host: anytype, subject: anytype, position: [3]f64) Box {
    return body.makeBox(position, host.width(subject), host.height(subject));
}

/// BlockGetter.forEachBlockIntersectedBetween with Entity.checkInsideBlocks' visitor.
fn checkSegment(host: anytype, subject: anytype, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !void {
    const box = boxOf(host, subject, fieldOf(subject, "position").*);
    const at_to = box.move(.{ to[0] - fieldOf(subject, "position").*[0], to[1] - fieldOf(subject, "position").*[1], to[2] - fieldOf(subject, "position").*[2] }).inflate(-1.0e-5, -1.0e-5, -1.0e-5);
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    const length = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
    if (length < @as(f64, @as(f32, 0.99999)) * @as(f64, @as(f32, 0.99999))) {
        try visitBox(host, subject, at_to, 0, from, to, collector, visited, null);
        return;
    }
    // Long moves walk the box's corner along the travel first, then the rest of the box.
    const along = &host.scratch().along;
    along.count = 0;
    const step = try travel(host, subject, at_to, delta, from, to, collector, visited, along);
    try visitBox(host, subject, at_to, step + 1, from, to, collector, visited, along);
}

fn visitBox(host: anytype, subject: anytype, target: Box, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, skip: ?*Visited) !void {
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

fn contains(visited: *const Visited, position: [3]i32) bool {
    for (visited.positions[0..visited.count]) |seen| if (std.meta.eql(seen, position)) return true;
    return false;
}

/// BlockGetter.addCollisionsAlongTravel: the cells the box's low corner crosses on its way, and
/// the boxes it fills there, each at its step.
fn travel(host: anytype, subject: anytype, target: Box, delta: [3]f64, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, along: *Visited) !i32 {
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

/// Entity.checkInsideBlocks' visitor for one block: the block's own effect when the body meets
/// its inside shape, then its fluid's.
fn visit(host: anytype, subject: anytype, position: [3]i32, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !bool {
    if (!host.alive(subject)) return false;
    const level = host.level(fieldOf(subject, "world").*);
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

/// BlockState.getEntityInsideCollisionShape: the whole block for most, the filled inside of
/// cauldrons for theirs.
fn meetsInside(host: anytype, subject: anytype, state: u16, position: [3]i32, from: [3]f64, to: [3]f64) !bool {
    const entry = host.level(fieldOf(subject, "world").*).blocks.get(state);
    const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
    // PowderSnowBlock.getEntityInsideCollisionShape: its collision shape for the body, the whole
    // block where it has none, as for a body that has not fallen far.
    if (entry.kind == .powder_snow) {
        const level = host.level(fieldOf(subject, "world").*);
        const shape = body.collisionBoxes(&level, state, position[0], position[1], position[2], .{ .bottom = fieldOf(subject, "position").*[1], .fall_distance = fieldOf(subject, "fall_distance").* });
        if (shape.count == 0) return true;
        const falling: Box = (body.Shape{ .boxes = shape, .x = position[0], .y = position[1], .z = position[2] }).get(0);
        return collidedMovingFrom(host, subject, from, to, &.{falling});
    }
    const filled: ?f64 = switch (entry.kind) {
        .lava_cauldron => 15.0,
        .water_cauldron, .powder_snow_cauldron => 6.0 + @as(f64, @floatFromInt(entry.flags.level)) * 3.0,
        else => null,
    };
    const height = filled orelse return true;
    // Shapes.or(AbstractCauldronBlock.SHAPE, the content column): the cauldron's outline and
    // what fills it.
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
    return collidedMovingFrom(host, subject, from, to, boxes[0..count]);
}

/// Entity.collidedWithFluid: the fluid's box, its height in the block, met along the move.
fn meetsFluid(host: anytype, subject: anytype, position: [3]i32, physics: game_data.physics_data.State, from: [3]f64, to: [3]f64) !bool {
    const level = host.level(fieldOf(subject, "world").*);
    const above = try level.fluid(position[0], position[1] + 1, position[2]);
    const height: f64 = if (above.fluid == physics.fluid) 1.0 else physics.height();
    const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
    const fluid_box: Box = .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + height, origin[2] + 1 } };
    return collidedMovingFrom(host, subject, from, to, &.{fluid_box});
}

/// Entity.collidedWithShapeMovingFrom with AABB.collidedAlongVector: the box at the start swept
/// along the move meets one of the boxes.
fn collidedMovingFrom(host: anytype, subject: anytype, from: [3]f64, to: [3]f64, boxes: []const Box) bool {
    const start = boxOf(host, subject, from);
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

/// BlockBehaviour.entityInside, for the blocks that do something to what is inside them.
fn entityInside(host: anytype, subject: anytype, state: u16, position: [3]i32, collector: *Collector) !void {
    const level = host.level(fieldOf(subject, "world").*);
    const entry = level.blocks.get(state);
    const living = @TypeOf(host).living;
    switch (entry.kind) {
        .cactus => _ = try host.hurt(subject, .cactus, 1.0),
        .fire, .soul_fire => {
            collector.apply(.fire_ignite);
            collector.runAfter(.fire_ignite, .{ .fire_hurt = if (entry.kind == .soul_fire) 2.0 else 1.0 });
        },
        // CampfireBlock burns living bodies alone.
        .campfire, .soul_campfire => if (living and entry.flags.lit_campfire) {
            _ = try host.hurt(subject, .campfire, if (entry.kind == .soul_campfire) 2.0 else 1.0);
        },
        // SweetBerryBushBlock catches living bodies alone.
        .sweet_berry_bush => if (living) {
            makeStuck(subject, .{ @as(f32, 0.8), 0.75, @as(f32, 0.8) });
            if (entry.flags.aged) {
                // The body moved since last tick, across rather than only up or down.
                const dx = fieldOf(subject, "old_position").*[0] - fieldOf(subject, "position").*[0];
                const dz = fieldOf(subject, "old_position").*[2] - fieldOf(subject, "position").*[2];
                if (dx * dx + dz * dz > 0 and (@abs(dx) >= @as(f64, @as(f32, 0.003)) or @abs(dz) >= @as(f64, @as(f32, 0.003)))) {
                    _ = try host.hurt(subject, .sweet_berry_bush, 1.0);
                }
            }
        },
        .cobweb => makeStuck(subject, .{ 0.25, @as(f32, 0.05), 0.25 }),
        .powder_snow => {
            // PowderSnowBlock holds what is not living, and a living body whose feet are in it.
            const at: [3]i32 = .{ mth.floor(fieldOf(subject, "position").*[0]), mth.floor(fieldOf(subject, "position").*[1]), mth.floor(fieldOf(subject, "position").*[2]) };
            if (!living or level.blocks.get(try level.state(at[0], at[1], at[2])).kind == .powder_snow) makeStuck(subject, .{ @as(f32, 0.9), 1.5, @as(f32, 0.9) });
            collector.runBefore(.extinguish, .{ .melt_powder_snow = position });
            collector.apply(.freeze);
            collector.apply(.extinguish);
        },
        .honey_block => try honeySlide(host, subject, position),
        // WaterlilyBlock.entityInside: a boat breaks it, and its drops fall.
        .lily_pad => if (@TypeOf(host).boat) try host.breakBlock(fieldOf(subject, "world").*, position),
        .bubble_column => {
            const above = try level.state(position[0], position[1] + 1, position[2]);
            const open = body.contextFreeBoxes(above, position[0], position[2]).count == 0 and game_data.physics.get(above).fluid == .none;
            const drag = entry.flags.drag;
            if (open) {
                try host.onAboveBubbleColumn(subject, drag, position);
            } else {
                fieldOf(subject, "velocity").*[1] = if (drag) @max(-0.3, fieldOf(subject, "velocity").*[1] - 0.03) else @min(0.7, fieldOf(subject, "velocity").*[1] + 0.06);
                fieldOf(subject, "fall_distance").* = 0;
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

/// Entity.onAboveBubbleColumn as Entity has it: up or down at the column's top, and the
/// particles' draws from the level's random.
pub fn aboveBubbleColumn(host: anytype, subject: anytype, drag: bool) void {
    fieldOf(subject, "velocity").*[1] = if (drag) @max(-0.9, fieldOf(subject, "velocity").*[1] - 0.03) else @min(1.8, fieldOf(subject, "velocity").*[1] + 0.1);
    // Entity.sendBubbleColumnParticles draws from the level's random.
    for (0..2) |_| for (0..4) |_| {
        _ = host.levelRandom().nextDouble();
    };
}

/// Entity.makeStuckInBlock.
fn makeStuck(subject: anytype, multiplier: [3]f64) void {
    fieldOf(subject, "fall_distance").* = 0;
    fieldOf(subject, "stuck").* = multiplier;
}

/// HoneyBlock.entityInside: a body falling down the side of a honey block slides slowly.
fn honeySlide(host: anytype, subject: anytype, position: [3]i32) !void {
    if (fieldOf(subject, "on_ground").*) return;
    if (fieldOf(subject, "position").*[1] > @as(f64, @floatFromInt(position[1])) + 0.9375 - 1.0e-7) return;
    const old_y = fieldOf(subject, "velocity").*[1] / @as(f64, @as(f32, 0.98)) + 0.08;
    if (old_y >= -0.08) return;
    const dx = @abs(@as(f64, @floatFromInt(position[0])) + 0.5 - fieldOf(subject, "position").*[0]);
    const dz = @abs(@as(f64, @floatFromInt(position[2])) + 0.5 - fieldOf(subject, "position").*[2]);
    const reach = 0.4375 + @as(f64, host.width(subject) / 2.0);
    if (!(dx + 1.0e-7 > reach or dz + 1.0e-7 > reach)) return;
    const new_y = (-0.05 - 0.08) * @as(f64, @as(f32, 0.98));
    if (old_y < -0.13) {
        const scale = -0.05 / old_y;
        fieldOf(subject, "velocity").* = .{ fieldOf(subject, "velocity").*[0] * scale, new_y, fieldOf(subject, "velocity").*[2] * scale };
    } else {
        fieldOf(subject, "velocity").*[1] = new_y;
    }
    fieldOf(subject, "fall_distance").* = 0;
    // HoneyBlock.doesEntityDoHoneyBlockSlideEffects: living bodies, among those that tick here.
    if (!@TypeOf(host).living) return;
    if (host.levelRandom().nextIntBounded(5) == 0) host.playSound(subject, .honey_block_slide, 1, 1);
    if (host.levelRandom().nextIntBounded(5) == 0) host.entityEvent(subject, 53);
}

fn run(host: anytype, subject: anytype, action: Action) !void {
    switch (action) {
        .effect => |effect| switch (effect) {
            .freeze => {
                fieldOf(subject, "in_powder_snow").* = true;
                fieldOf(subject, "ticks_frozen").* = @min(140, fieldOf(subject, "ticks_frozen").* + 1);
            },
            // BaseFireBlock.fireIgnite.
            .fire_ignite => if (!try host.fireImmune(subject)) {
                if (fieldOf(subject, "fire_ticks").* < 0) fieldOf(subject, "fire_ticks").* += 1;
                if (fieldOf(subject, "fire_ticks").* >= 0) ignite(subject, 160);
            },
            // Entity.lavaIgnite.
            .lava_ignite => if (!try host.fireImmune(subject)) ignite(subject, 300),
            .extinguish => fieldOf(subject, "fire_ticks").* = 0,
        },
        .fire_hurt => |amount| _ = try host.hurt(subject, .in_fire, amount),
        // Entity.lavaHurt, with its sound when it hurts.
        .lava_hurt => if (!try host.fireImmune(subject)) {
            if (try host.hurt(subject, .lava, 4.0)) host.playSound(subject, .generic_burn, 0.4, 2.0 + host.random(subject).nextFloat() * 0.4);
        },
        .melt_powder_snow => |position| if (try onFire(host, subject) and host.mobGriefing()) try host.destroyBlock(fieldOf(subject, "world").*, position),
        .lower_cauldron => |position| if (try onFire(host, subject)) try host.lowerCauldron(fieldOf(subject, "world").*, position),
    }
}

/// Entity.igniteForTicks.
fn ignite(subject: anytype, ticks: i32) void {
    if (fieldOf(subject, "fire_ticks").* < ticks) fieldOf(subject, "fire_ticks").* = ticks;
    fieldOf(subject, "ticks_frozen").* = 0;
}

/// A subject's field where it lies: its own, or, for a subject whose fields point into its
/// owner's state, where that points.
fn fieldOf(subject: anytype, comptime name: []const u8) FieldPointer(@TypeOf(subject), name) {
    const Field = @TypeOf(@field(subject, name));
    if (@typeInfo(Field) == .pointer) return @field(subject, name);
    return &@field(subject, name);
}

fn FieldPointer(comptime Subject: type, comptime name: []const u8) type {
    const Owner = switch (@typeInfo(Subject)) {
        .pointer => |pointer| pointer.child,
        else => Subject,
    };
    const Field = @FieldType(Owner, name);
    if (@typeInfo(Field) == .pointer) return Field;
    const constant = switch (@typeInfo(Subject)) {
        .pointer => |pointer| pointer.attrs.@"const",
        else => true,
    };
    return if (constant) *const Field else *Field;
}
