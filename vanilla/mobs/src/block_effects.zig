//! Entity.applyEffectsFromBlocks: what the block a mob stands on does to it (Block.stepOn), then
//! what every block and fluid it moved through this tick does (Entity.checkInsideBlocks), with
//! InsideBlockEffectApplier.StepBasedCollector ordering the effects as vanilla does.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");
const living = @import("living.zig");
const mob_state = @import("mob.zig");
const Mobs = @import("mobs.zig").Mobs;

const Mob = mob_state.Mob;
const Movement = mob_state.Movement;
const Box = body.Box;
const assert = std.debug.assert;

/// InsideBlockEffectType, in its order of application.
const Effect = enum(u2) { freeze, fire_ignite, lava_ignite, extinguish };

/// The deferred actions blocks queue around an effect.
const Action = union(enum) {
    effect: Effect,
    /// BaseFireBlock's damage after igniting.
    fire_hurt: f32,
    lava_hurt,
    /// PowderSnowBlock melts under a burning mob before it is put out.
    melt_powder_snow: [3]i32,
    /// LayeredCauldronBlock lowers its level under a burning mob before it is put out.
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

/// Entity.applyEffectsFromBlocks. Whether a block under or around the mob could act on it, as
/// resting mobs need none to.
pub fn applyEffectsFromBlocks(mobs: *Mobs, mob: *Mob) !bool {
    defer mob.movement_count = 0;
    var movements: [mobs.movements.len + 1]Movement = undefined;
    var count: usize = mob.movement_count;
    @memcpy(movements[0..count], mobs.movements[0..count]);
    if (count == 0) {
        movements[0] = .{ .from = mob.old_position, .to = mob.position, .axis_independent = false };
        count = 1;
    } else {
        const last = movements[count - 1].to;
        const dx = last[0] - mob.position[0];
        const dy = last[1] - mob.position[1];
        const dz = last[2] - mob.position[2];
        if (dx * dx + dy * dy + dz * dz > @as(f64, @as(f32, 9.9999994e-11))) {
            movements[count] = .{ .from = last, .to = mob.position, .axis_independent = false };
            count += 1;
        }
    }
    if (mob.removed) return true;
    var acted = false;
    if (mob.on_ground) acted = try stepOn(mobs, mob);
    const burning = onFire(mobs, mob);
    const freezing = mob.ticks_frozen > 0;
    const fire_before = mob.fire_ticks;
    const collector = &mobs.effects_scratch.collector;
    collector.reset();
    // With no fluid and no block that acts on a mob inside it around the mob ticking, the walk
    // finds nothing, which Debug still checks.
    const quiet = quietAround(mobs, mob, movements[0..count]);
    if (!quiet or verify_skips) try checkInsideBlocks(mobs, mob, movements[0..count], collector);
    if (quiet) assert(collector.final_count == 0 and !collector.acted and collector.before_count[0] == 0);
    collector.flush();
    for (collector.final[0..collector.final_count]) |action| {
        if (!mob.alive()) break;
        try run(mobs, mob, action);
    }
    if ((burning and !onFire(mobs, mob)) or (freezing and mob.ticks_frozen <= 0)) {
        // Entity.playEntityOnFireExtinguishedSound.
        const pitch = 1.6 + (mob.random.nextFloat() - mob.random.nextFloat()) * 0.4;
        mobs.playSound(mob, .generic_extinguish_fire, 0.7, pitch);
    }
    const ignited = mob.fire_ticks > fire_before;
    if (!onFire(mobs, mob) and !ignited) mob.fire_ticks = 0;
    return acted or collector.acted;
}

/// Entity.isOnFire on the server.
pub fn onFire(mobs: *Mobs, mob: *const Mob) bool {
    return !mobs.traits(mob.species).fire_immune and mob.fire_ticks > 0;
}

/// Block.stepOn for the block under the mob's feet, and whether that block does anything.
fn stepOn(mobs: *Mobs, mob: *Mob) !bool {
    const level = mobs.level(mob.world);
    const at = try living.onPosition(mobs, mob, 0.2);
    const state = try level.state(at[0], at[1], at[2]);
    const kind = level.blocks.get(state).kind;
    switch (kind) {
        // MagmaBlock: mobs never step carefully.
        .magma_block => _ = try mobs.hurt(mob, .{ .type = .hot_floor }, 1.0),
        // SlimeBlock: slow on it unless falling or rising fast.
        .slime_block => {
            const vertical = @abs(mob.velocity[1]);
            if (vertical < 0.1) {
                const factor = 0.4 + vertical * 0.2;
                mob.velocity[0] *= factor;
                mob.velocity[2] *= factor;
            }
        },
        // TurtleEggBlock: one step in a hundred cracks an egg, where mobs may grief.
        .turtle_egg => if (mobs.mobGriefing() and mobs.levelRandom().nextIntBounded(100) == 0) try mobs.crackTurtleEgg(mob.world, at, state),
        else => {},
    }
    return kind == .magma_block or kind == .slime_block or kind == .turtle_egg;
}

/// Whether the window around the mob holds every cell the movements could visit, one block more
/// for the fluid above, and none of them is a fluid or acts on what is inside it.
fn quietAround(mobs: *Mobs, mob: *const Mob, movements: []const Movement) bool {
    const level = mobs.level(mob.world);
    const half: f64 = living.width(mobs, mob) / 2.0;
    const tall: f64 = living.height(mobs, mob);
    var low: [3]f64 = movements[0].from;
    var high: [3]f64 = movements[0].from;
    for (movements) |movement| for ([2][3]f64{ movement.from, movement.to }) |point| for (0..3) |axis| {
        low[axis] = @min(low[axis], point[axis]);
        high[axis] = @max(high[axis], point[axis]);
    };
    const first: [3]i32 = .{ mth.floor(low[0] - half) - 1, mth.floor(low[1]) - 1, mth.floor(low[2] - half) - 1 };
    const last: [3]i32 = .{ mth.floor(high[0] + half) + 1, mth.floor(high[1] + tall) + 1, mth.floor(high[2] + half) + 1 };
    return level.without(@import("mob_blocks.zig").mark_fluid | @import("mob_blocks.zig").mark_inside, first, last);
}

const verify_skips = @import("builtin").mode == .debug;

/// Entity.checkInsideBlocks over the tick's movements, each split by axis where it moved
/// along them one at a time.
fn checkInsideBlocks(mobs: *Mobs, mob: *Mob, movements: []const Movement, collector: *Collector) !void {
    const visited = &mobs.effects_scratch.visited;
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
                try checkSegment(mobs, mob, from, to, collector, visited);
                from = to;
            }
        } else {
            try checkSegment(mobs, mob, movement.from, movement.to, collector, visited);
        }
    }
}

/// What block effects work in, kept by Mobs so its arrays are not filled anew each tick.
pub const Scratch = struct {
    collector: Collector = .{},
    visited: Visited = .{},
    along: Visited = .{},
};

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

/// BlockGetter.forEachBlockIntersectedBetween with Entity.checkInsideBlocks' visitor.
fn checkSegment(mobs: *Mobs, mob: *Mob, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !void {
    const box = living.box(mobs, mob);
    const at_to = box.move(.{ to[0] - mob.position[0], to[1] - mob.position[1], to[2] - mob.position[2] }).inflate(-1.0e-5, -1.0e-5, -1.0e-5);
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    const length = delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2];
    if (length < @as(f64, @as(f32, 0.99999)) * @as(f64, @as(f32, 0.99999))) {
        try visitBox(mobs, mob, at_to, 0, from, to, collector, visited, null);
        return;
    }
    // Long moves walk the box's corner along the travel first, then the rest of the box.
    const along = &mobs.effects_scratch.along;
    along.count = 0;
    const step = try travel(mobs, mob, at_to, delta, from, to, collector, visited, along);
    try visitBox(mobs, mob, at_to, step + 1, from, to, collector, visited, along);
}

fn visitBox(mobs: *Mobs, mob: *Mob, target: Box, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, skip: ?*Visited) !void {
    // BlockPos.betweenClosed: x fastest, then y, then z.
    var z = mth.floor(target.min[2]);
    while (z <= mth.floor(target.max[2])) : (z += 1) {
        var y = mth.floor(target.min[1]);
        while (y <= mth.floor(target.max[1])) : (y += 1) {
            var x = mth.floor(target.min[0]);
            while (x <= mth.floor(target.max[0])) : (x += 1) {
                if (skip) |seen| if (contains(seen, .{ x, y, z })) continue;
                if (!try visit(mobs, mob, .{ x, y, z }, step, from, to, collector, visited)) return;
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
fn travel(mobs: *Mobs, mob: *Mob, target: Box, delta: [3]f64, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited, along: *Visited) !i32 {
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
                    if (!try visit(mobs, mob, .{ x, y, z }, current, from, to, collector, visited)) return -1;
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

/// Entity.checkInsideBlocks' visitor for one block: the block's own effect when the mob meets
/// its inside shape, then its fluid's.
fn visit(mobs: *Mobs, mob: *Mob, position: [3]i32, step: i32, from: [3]f64, to: [3]f64, collector: *Collector, visited: *Visited) !bool {
    if (!mob.alive()) return false;
    const level = mobs.level(mob.world);
    const state = try level.state(position[0], position[1], position[2]);
    const entry = level.blocks.get(state);
    if (entry.flags.air) return true;
    if (!visited.add(position)) return true;
    if (insideActs(entry.kind) or game_data.physics.get(state).fluid != .none) collector.acted = true;
    if (try meetsInside(mobs, mob, state, position, from, to)) {
        collector.advanceStep(step);
        try entityInside(mobs, mob, state, position, collector);
    }
    const physics = game_data.physics.get(state);
    if (physics.fluid != .none and try meetsFluid(mobs, mob, position, physics, from, to)) {
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
fn meetsInside(mobs: *Mobs, mob: *const Mob, state: u16, position: [3]i32, from: [3]f64, to: [3]f64) !bool {
    const entry = mobs.blocks.get(state);
    const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
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
    return collidedMovingFrom(mobs, mob, from, to, boxes[0..count]);
}

/// Entity.collidedWithFluid: the fluid's box, its height in the block, met along the move.
fn meetsFluid(mobs: *Mobs, mob: *const Mob, position: [3]i32, physics: game_data.physics_data.State, from: [3]f64, to: [3]f64) !bool {
    const level = mobs.level(mob.world);
    const above = try level.fluid(position[0], position[1] + 1, position[2]);
    const height: f64 = if (above.fluid == physics.fluid) 1.0 else physics.height();
    const origin: [3]f64 = .{ @floatFromInt(position[0]), @floatFromInt(position[1]), @floatFromInt(position[2]) };
    const fluid_box: Box = .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + height, origin[2] + 1 } };
    return collidedMovingFrom(mobs, mob, from, to, &.{fluid_box});
}

/// Entity.collidedWithShapeMovingFrom with AABB.collidedAlongVector: the box at the start swept
/// along the move meets one of the boxes.
fn collidedMovingFrom(mobs: *Mobs, mob: *const Mob, from: [3]f64, to: [3]f64, boxes: []const Box) bool {
    const start = body.makeBox(from, living.width(mobs, mob), living.height(mobs, mob));
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
pub fn insideActs(kind: @import("mob_blocks.zig").Kind) bool {
    return switch (kind) {
        .cactus, .fire, .soul_fire, .campfire, .soul_campfire, .sweet_berry_bush, .cobweb, .powder_snow, .honey_block, .bubble_column, .lava_cauldron, .water_cauldron, .powder_snow_cauldron => true,
        else => false,
    };
}

/// BlockBehaviour.entityInside, for the blocks that do something to a mob.
fn entityInside(mobs: *Mobs, mob: *Mob, state: u16, position: [3]i32, collector: *Collector) !void {
    const level = mobs.level(mob.world);
    const entry = level.blocks.get(state);
    switch (entry.kind) {
        .cactus => _ = try mobs.hurt(mob, .{ .type = .cactus }, 1.0),
        .fire, .soul_fire => {
            collector.apply(.fire_ignite);
            collector.runAfter(.fire_ignite, .{ .fire_hurt = if (entry.kind == .soul_fire) 2.0 else 1.0 });
        },
        .campfire, .soul_campfire => if (entry.flags.lit_campfire) {
            _ = try mobs.hurt(mob, .{ .type = .campfire }, if (entry.kind == .soul_campfire) 2.0 else 1.0);
        },
        .sweet_berry_bush => {
            makeStuck(mob, .{ @as(f32, 0.8), 0.75, @as(f32, 0.8) });
            if (entry.flags.aged) {
                // The mob moved since last tick, across rather than only up or down.
                const dx = mob.old_position[0] - mob.position[0];
                const dz = mob.old_position[2] - mob.position[2];
                if (dx * dx + dz * dz > 0 and (@abs(dx) >= @as(f64, @as(f32, 0.003)) or @abs(dz) >= @as(f64, @as(f32, 0.003)))) {
                    _ = try mobs.hurt(mob, .{ .type = .sweet_berry_bush }, 1.0);
                }
            }
        },
        .cobweb => makeStuck(mob, .{ 0.25, @as(f32, 0.05), 0.25 }),
        .powder_snow => {
            const at = mob.blockPosition();
            if (level.blocks.get(try level.state(at[0], at[1], at[2])).kind == .powder_snow) makeStuck(mob, .{ @as(f32, 0.9), 1.5, @as(f32, 0.9) });
            collector.runBefore(.extinguish, .{ .melt_powder_snow = position });
            collector.apply(.freeze);
            collector.apply(.extinguish);
        },
        .honey_block => try honeySlide(mobs, mob, position),
        .bubble_column => {
            const above = try level.state(position[0], position[1] + 1, position[2]);
            const open = body.contextFreeBoxes(above, position[0], position[2]).count == 0 and game_data.physics.get(above).fluid == .none;
            const drag = entry.flags.drag;
            if (open) {
                mob.velocity[1] = if (drag) @max(-0.9, mob.velocity[1] - 0.03) else @min(1.8, mob.velocity[1] + 0.1);
                // Entity.sendBubbleColumnParticles draws from the level's random.
                for (0..2) |_| for (0..4) |_| {
                    _ = mobs.levelRandom().nextDouble();
                };
            } else {
                mob.velocity[1] = if (drag) @max(-0.3, mob.velocity[1] - 0.03) else @min(0.7, mob.velocity[1] + 0.06);
                mob.fall_distance = 0;
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

/// Entity.makeStuckInBlock.
fn makeStuck(mob: *Mob, multiplier: [3]f64) void {
    mob.fall_distance = 0;
    mob.stuck = multiplier;
}

/// HoneyBlock.entityInside: a mob falling down the side of a honey block slides slowly.
fn honeySlide(mobs: *Mobs, mob: *Mob, position: [3]i32) !void {
    if (mob.on_ground) return;
    if (mob.position[1] > @as(f64, @floatFromInt(position[1])) + 0.9375 - 1.0e-7) return;
    const old_y = mob.velocity[1] / @as(f64, @as(f32, 0.98)) + 0.08;
    if (old_y >= -0.08) return;
    const dx = @abs(@as(f64, @floatFromInt(position[0])) + 0.5 - mob.position[0]);
    const dz = @abs(@as(f64, @floatFromInt(position[2])) + 0.5 - mob.position[2]);
    const reach = 0.4375 + @as(f64, living.width(mobs, mob) / 2.0);
    if (!(dx + 1.0e-7 > reach or dz + 1.0e-7 > reach)) return;
    const new_y = (-0.05 - 0.08) * @as(f64, @as(f32, 0.98));
    if (old_y < -0.13) {
        const scale = -0.05 / old_y;
        mob.velocity = .{ mob.velocity[0] * scale, new_y, mob.velocity[2] * scale };
    } else {
        mob.velocity[1] = new_y;
    }
    mob.fall_distance = 0;
    if (mobs.levelRandom().nextIntBounded(5) == 0) mobs.playSound(mob, .honey_block_slide, 1, 1);
    if (mobs.levelRandom().nextIntBounded(5) == 0) mobs.entityEvent(mob, 53);
}

fn run(mobs: *Mobs, mob: *Mob, action: Action) !void {
    const fire_immune = mobs.traits(mob.species).fire_immune;
    switch (action) {
        .effect => |effect| switch (effect) {
            .freeze => {
                mob.in_powder_snow = true;
                mob.ticks_frozen = @min(140, mob.ticks_frozen + 1);
            },
            // BaseFireBlock.fireIgnite.
            .fire_ignite => if (!fire_immune) {
                if (mob.fire_ticks < 0) mob.fire_ticks += 1;
                if (mob.fire_ticks >= 0) ignite(mob, 160);
            },
            // Entity.lavaIgnite.
            .lava_ignite => if (!fire_immune) ignite(mob, 300),
            .extinguish => mob.fire_ticks = 0,
        },
        .fire_hurt => |amount| _ = try mobs.hurt(mob, .{ .type = .in_fire }, amount),
        // Entity.lavaHurt, with its sound when it hurts.
        .lava_hurt => if (!fire_immune) {
            if (try mobs.hurt(mob, .{ .type = .lava }, 4.0)) mobs.playSound(mob, .generic_burn, 0.4, 2.0 + mob.random.nextFloat() * 0.4);
        },
        .melt_powder_snow => |position| if (onFire(mobs, mob) and mobs.mobGriefing()) try mobs.destroyBlock(mob.world, position),
        .lower_cauldron => |position| if (onFire(mobs, mob)) try mobs.lowerCauldron(mob.world, position),
    }
}

/// Entity.igniteForTicks.
fn ignite(mob: *Mob, ticks: i32) void {
    if (mob.fire_ticks < ticks) mob.fire_ticks = ticks;
    mob.ticks_frozen = 0;
}
