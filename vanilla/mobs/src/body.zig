//! A mob's body as vanilla's Entity and LivingEntity move it: collisions with stepping up
//! (Entity.collide), Entity.move, LivingEntity.travel on land and in fluids, fluid heights and
//! currents, climbing, falling and the blocks a body stands on. The world is read through a
//! Level, and what happens to the mob as a result (damage, sounds) is reported through Events
//! for the caller to apply, so the body itself stays plain data and arithmetic.

const std = @import("std");
const game_data = @import("game_data");
const chunks = @import("chunks");
const mth = @import("mth.zig");
const mob_blocks = @import("mob_blocks.zig");
const JavaRandom = @import("java_random.zig").JavaRandom;

const MobBlocks = mob_blocks.MobBlocks;
const assert = std.debug.assert;

pub const Box = struct {
    min: [3]f64,
    max: [3]f64,

    /// The AABB constructor, which takes two corners in either order.
    pub fn corners(a: [3]f64, b: [3]f64) Box {
        return .{ .min = .{ @min(a[0], b[0]), @min(a[1], b[1]), @min(a[2], b[2]) }, .max = .{ @max(a[0], b[0]), @max(a[1], b[1]), @max(a[2], b[2]) } };
    }

    pub fn move(self: Box, by: [3]f64) Box {
        return .{ .min = .{ self.min[0] + by[0], self.min[1] + by[1], self.min[2] + by[2] }, .max = .{ self.max[0] + by[0], self.max[1] + by[1], self.max[2] + by[2] } };
    }

    /// AABB.expandTowards.
    pub fn expandTowards(self: Box, by: [3]f64) Box {
        var result = self;
        for (0..3) |axis| {
            if (by[axis] < 0) result.min[axis] += by[axis] else if (by[axis] > 0) result.max[axis] += by[axis];
        }
        return result;
    }

    pub fn inflate(self: Box, x: f64, y: f64, z: f64) Box {
        return .{ .min = .{ self.min[0] - x, self.min[1] - y, self.min[2] - z }, .max = .{ self.max[0] + x, self.max[1] + y, self.max[2] + z } };
    }

    /// AABB.intersects, strict on every axis.
    pub fn intersects(self: Box, other: Box) bool {
        return self.min[0] < other.max[0] and self.max[0] > other.min[0] and
            self.min[1] < other.max[1] and self.max[1] > other.min[1] and
            self.min[2] < other.max[2] and self.max[2] > other.min[2];
    }
};

/// EntityDimensions.makeBoundingBox, which halves the width as a float.
pub fn makeBox(position: [3]f64, width: f32, height: f32) Box {
    const half: f64 = width / 2.0;
    return .{ .min = .{ position[0] - half, position[1], position[2] - half }, .max = .{ position[0] + half, position[1] + height, position[2] + half } };
}

/// The world as a body reads it.
/// Blocks held in memory, for tests that build a world of their own.
pub const Volume = struct {
    size: [3]i32,
    /// By (y * size z + z) * size x + x.
    states: []const u16,

    pub fn get(self: *const Volume, x: i32, y: i32, z: i32, air: u16) u16 {
        if (x < 0 or y < 0 or z < 0 or x >= self.size[0] or y >= self.size[1] or z >= self.size[2]) return air;
        return self.states[@intCast((y * self.size[2] + z) * self.size[0] + x)];
    }
};

pub const Level = struct {
    copies: ?*chunks.Copies,
    volume: ?*const Volume = null,
    blocks: *const MobBlocks,
    world: u32,
    minimum_y: i32,
    height: i32,
    air: u16,

    /// Outside the world's height a level reads void air, which collides with nothing.
    pub fn state(self: *const Level, x: i32, y: i32, z: i32) !u16 {
        if (y < self.minimum_y or y >= self.minimum_y + self.height) return self.air;
        if (self.volume) |volume| return volume.get(x, y, z, self.air);
        return self.copies.?.get(self.world, .{ .x = x, .y = y, .z = z });
    }

    pub fn fluid(self: *const Level, x: i32, y: i32, z: i32) !game_data.physics_data.State {
        return game_data.physics.get(try self.state(x, y, z));
    }
};

/// What a collision query knows about the entity, for the few blocks whose collision shape
/// depends on it (EntityCollisionContext).
pub const Context = struct {
    bottom: f64 = 0,
    fall_distance: f64 = 0,
    /// CollisionContext.empty, for queries with no entity.
    empty: bool = false,
};

/// The collision boxes of a block state at a position, for an entity.
pub fn collisionBoxes(level: *const Level, state: u16, x: i32, y: i32, z: i32, context: Context) game_data.physics.Boxes {
    if (context.empty) return contextFreeBoxes(state, x, z);
    const kind = level.blocks.get(state).kind;
    const at_y: f64 = @floatFromInt(y);
    const epsilon: f64 = @as(f32, 1.0e-5);
    switch (kind) {
        // ScaffoldingBlock.getCollisionShape. The snapshot holds the stable shape for a block
        // below the entity and the unstable bottom (or none) for a block at its feet.
        .scaffolding => {
            if (context.bottom > at_y + 1.0 - epsilon) return game_data.physics.spawnCollision(state, x, -1, z);
            if (context.bottom > at_y - epsilon) return game_data.physics.spawnCollision(state, x, 0, z);
            return .{ .offset = 0, .count = 0, .translation = @splat(0) };
        },
        // PowderSnowBlock.getCollisionShape. Mobs that cannot walk on powder snow sink in
        // unless they fall into it from high enough.
        .powder_snow => return if (context.fall_distance > 2.5) powder_snow_falling else .{ .offset = 0, .count = 0, .translation = @splat(0) },
        else => return game_data.physics.spawnCollision(state, x, 0, z),
    }
}

// PowderSnowBlock.FALLING_COLLISION_SHAPE, a box 0.9 high, is no shape the snapshot names, so
// the caller treats this marker specially.
const powder_snow_falling: game_data.physics.Boxes = .{ .offset = std.math.maxInt(u32), .count = 1, .translation = @splat(0) };

fn box(boxes: game_data.physics.Boxes, index: usize, x: i32, y: i32, z: i32) Box {
    const origin: [3]f64 = .{ @floatFromInt(x), @floatFromInt(y), @floatFromInt(z) };
    if (boxes.offset == std.math.maxInt(u32)) {
        return .{ .min = origin, .max = .{ origin[0] + 1, origin[1] + @as(f64, @as(f32, 0.9)), origin[2] + 1 } };
    }
    const value = boxes.get(index);
    return .{ .min = .{ origin[0] + value[0], origin[1] + value[1], origin[2] + value[2] }, .max = .{ origin[0] + value[3], origin[1] + value[4], origin[2] + value[5] } };
}

/// A block shape BlockCollisions yields: all its boxes, at the block's position.
pub const Shape = struct {
    boxes: game_data.physics.Boxes,
    x: i32,
    y: i32,
    z: i32,

    pub fn get(self: Shape, index: usize) Box {
        return box(self.boxes, index, self.x, self.y, self.z);
    }
};

/// BlockCollisions: the shapes of blocks a query box touches, plus blocks one layer out whose
/// shapes reach in. A shape is yielded when one of its boxes overlaps the query.
pub const Shapes = struct {
    level: *const Level,
    query: Box,
    context: Context,
    first: [3]i32,
    last: [3]i32,
    at: [3]i32,

    pub fn init(level: *const Level, query: Box, context: Context) Shapes {
        const first: [3]i32 = .{ mth.floor(query.min[0] - 1.0e-7) - 1, mth.floor(query.min[1] - 1.0e-7) - 1, mth.floor(query.min[2] - 1.0e-7) - 1 };
        const last: [3]i32 = .{ mth.floor(query.max[0] + 1.0e-7) + 1, mth.floor(query.max[1] + 1.0e-7) + 1, mth.floor(query.max[2] + 1.0e-7) + 1 };
        return .{ .level = level, .query = query, .context = context, .first = first, .last = last, .at = first };
    }

    pub fn next(self: *Shapes) !?Shape {
        while (self.at[1] <= self.last[1]) {
            const x = self.at[0];
            const y = self.at[1];
            const z = self.at[2];
            self.at[0] += 1;
            if (self.at[0] > self.last[0]) {
                self.at[0] = self.first[0];
                self.at[2] += 1;
                if (self.at[2] > self.last[2]) {
                    self.at[2] = self.first[2];
                    self.at[1] += 1;
                }
            }
            // Cursor3D's type: how many coordinates lie on the outer layer.
            var edges: u2 = 0;
            if (x == self.first[0] or x == self.last[0]) edges += 1;
            if (y == self.first[1] or y == self.last[1]) edges += 1;
            if (z == self.first[2] or z == self.last[2]) edges += 1;
            if (edges == 3) continue;
            const state = try self.level.state(x, y, z);
            const entry = self.level.blocks.get(state);
            if (edges == 1 and !entry.flags.large_shape) continue;
            if (edges == 2 and entry.kind != .moving_piston) continue;
            const boxes = collisionBoxes(self.level, state, x, y, z, self.context);
            if (boxes.count == 0) continue;
            const shape: Shape = .{ .boxes = boxes, .x = x, .y = y, .z = z };
            for (0..boxes.count) |index| {
                if (shape.get(index).intersects(self.query)) return shape;
            }
        }
        return null;
    }
};

/// Shapes.collide along one axis, against every shape the query yields.
fn collideAxis(level: *const Level, query: Box, context: Context, moving: Box, axis: usize, distance: f64) !f64 {
    var result = distance;
    var shapes: Shapes = .init(level, query, context);
    while (try shapes.next()) |shape| {
        if (@abs(result) < 1.0e-7) return 0;
        for (0..shape.boxes.count) |index| result = collideBox(shape.get(index), moving, axis, result);
    }
    return result;
}

/// VoxelShape.collideX for one box: how far the moving box goes along the axis before the
/// obstacle stops it, within vanilla's 1e-7 tolerance.
fn collideBox(obstacle: Box, moving: Box, axis: usize, distance: f64) f64 {
    const a = (axis + 1) % 3;
    const b = (axis + 2) % 3;
    if (obstacle.max[a] <= moving.min[a] + 1.0e-7 or obstacle.min[a] >= moving.max[a] - 1.0e-7) return distance;
    if (obstacle.max[b] <= moving.min[b] + 1.0e-7 or obstacle.min[b] >= moving.max[b] - 1.0e-7) return distance;
    if (distance > 0 and obstacle.min[axis] > moving.max[axis] - 1.0e-7) {
        const gap = obstacle.min[axis] - moving.max[axis];
        if (gap >= -1.0e-7) return @min(distance, gap);
    } else if (distance < 0 and obstacle.max[axis] < moving.min[axis] + 1.0e-7) {
        const gap = obstacle.max[axis] - moving.min[axis];
        if (gap <= 1.0e-7) return @max(distance, gap);
    }
    return distance;
}

fn anyShape(level: *const Level, query: Box, context: Context) !bool {
    var shapes: Shapes = .init(level, query, context);
    return try shapes.next() != null;
}

/// Entity.collideWithShapes: Y first, then the larger of X and Z last.
fn collideWithShapes(level: *const Level, query: Box, context: Context, movement: [3]f64, start: Box) ![3]f64 {
    if (!try anyShape(level, query, context)) return movement;
    var result: [3]f64 = .{ 0, 0, 0 };
    const order: [3]usize = if (@abs(movement[0]) < @abs(movement[2])) .{ 1, 2, 0 } else .{ 1, 0, 2 };
    for (order) |axis| {
        if (movement[axis] == 0) continue;
        result[axis] = try collideAxis(level, query, context, start.move(result), axis, movement[axis]);
    }
    return result;
}

/// Entity.collide, with stepping up onto blocks no higher than max_up_step.
pub fn collide(level: *const Level, start: Box, movement: [3]f64, context: Context, on_ground: bool, max_up_step: f32) ![3]f64 {
    const length_squared = movement[0] * movement[0] + movement[1] * movement[1] + movement[2] * movement[2];
    const collided = if (length_squared == 0) movement else try collideWithShapes(level, start.expandTowards(movement), context, movement, start);
    const blocked_x = movement[0] != collided[0];
    const blocked_y = movement[1] != collided[1];
    const blocked_z = movement[2] != collided[2];
    const landed = blocked_y and movement[1] < 0;
    if (max_up_step > 0 and (landed or on_ground) and (blocked_x or blocked_z)) {
        const base = if (landed) start.move(.{ 0, collided[1], 0 }) else start;
        var query = base.expandTowards(.{ movement[0], max_up_step, movement[2] });
        if (!landed) query = query.expandTowards(.{ 0, -@as(f64, @as(f32, 1.0e-5)), 0 });
        var heights: [64]f32 = undefined;
        const count = try stepHeights(level, query, context, base, max_up_step, @floatCast(collided[1]), &heights);
        for (heights[0..count]) |height| {
            const stepped = try collideWithShapes(level, query, context, .{ movement[0], height, movement[2] }, base);
            if (stepped[0] * stepped[0] + stepped[2] * stepped[2] > collided[0] * collided[0] + collided[2] * collided[2]) {
                const lowered = start.min[1] - base.min[1];
                return .{ stepped[0], stepped[1] - lowered, stepped[2] };
            }
        }
    }
    return collided;
}

/// Entity.collectCandidateStepUpHeights: the heights above the box's bottom of shape edges no
/// higher than the step, sorted. Shape edges are box bottoms and tops here.
fn stepHeights(level: *const Level, query: Box, context: Context, base: Box, max_up_step: f32, skip: f32, output: *[64]f32) !usize {
    var count: usize = 0;
    var shapes: Shapes = .init(level, query, context);
    while (try shapes.next()) |shape| {
        for (0..shape.boxes.count) |index| {
            const value = shape.get(index);
            for ([2]f64{ value.min[1], value.max[1] }) |coordinate| {
                const height: f32 = @floatCast(coordinate - base.min[1]);
                if (height < 0 or height == skip or height > max_up_step) continue;
                if (std.mem.indexOfScalar(f32, output[0..count], height) != null) continue;
                // Distinct edges below one step cannot run out in any block vanilla has.
                assert(count < output.len);
                output[count] = height;
                count += 1;
            }
        }
    }
    std.mem.sort(f32, output[0..count], {}, std.sort.asc(f32));
    return count;
}

/// Level.findSupportingBlock: of the blocks under the box, the one whose center is nearest the
/// position, ties broken toward the larger position in vanilla's order (y, then z, then x).
pub fn findSupportingBlock(level: *const Level, query: Box, context: Context, position: [3]f64) !?[3]i32 {
    var best: ?[3]i32 = null;
    var best_distance = std.math.floatMax(f64);
    var shapes: Shapes = .init(level, query, context);
    while (try shapes.next()) |shape| {
        const dx = @as(f64, @floatFromInt(shape.x)) + 0.5 - position[0];
        const dy = @as(f64, @floatFromInt(shape.y)) + 0.5 - position[1];
        const dz = @as(f64, @floatFromInt(shape.z)) + 0.5 - position[2];
        const distance = dx * dx + dy * dy + dz * dz;
        const candidate: [3]i32 = .{ shape.x, shape.y, shape.z };
        if (distance < best_distance or (distance == best_distance and (best == null or lessBlock(best.?, candidate)))) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// Vec3i.compareTo(a, b) < 0.
fn lessBlock(a: [3]i32, b: [3]i32) bool {
    if (a[1] != b[1]) return a[1] < b[1];
    if (a[2] != b[2]) return a[2] < b[2];
    return a[0] < b[0];
}

/// CollisionGetter.noCollision for a box, which vanilla also asks with no entity's context
/// in places, ignoring entities since mobs collide with none here.
pub fn noCollision(level: *const Level, query: Box, context: Context) !bool {
    return !try anyShape(level, query, context);
}

test "a box stops at a block and steps up a slab" {
    // Pure arithmetic of one obstacle, which the world tests cover end to end.
    const obstacle: Box = .{ .min = .{ 1, 0, 0 }, .max = .{ 2, 0.5, 1 } };
    const moving: Box = .{ .min = .{ 0.1, 0, 0.1 }, .max = .{ 0.9, 1.4, 0.9 } };
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), collideBox(obstacle, moving, 0, 0.3), 1e-12);
    try std.testing.expectEqual(@as(f64, -0.3), collideBox(obstacle, moving, 0, -0.3));
    try std.testing.expectEqual(@as(f64, 0.3), collideBox(obstacle, moving.move(.{ 0, 0.5, 0 }), 0, 0.3));
}

/// BlockState.getCollisionShape with no entity (CollisionContext.empty): scaffolding is stable,
/// since the empty context counts as above every block, and powder snow has no shape.
pub fn contextFreeBoxes(state: u16, x: i32, z: i32) game_data.physics.Boxes {
    const name = game_data.registry.blockStateName(state).?;
    if (std.mem.startsWith(u8, name, "minecraft:scaffolding[")) return game_data.physics.spawnCollision(state, x, -1, z);
    return game_data.physics.spawnCollision(state, x, 0, z);
}

/// Shapes.collide along Y against the shapes a query yields, as EntityType.getYOffset asks.
pub fn collideVertical(level: *const Level, query: Box, context: Context, moving: Box, distance: f64) !f64 {
    return collideAxis(level, query, context, moving, 1, distance);
}
