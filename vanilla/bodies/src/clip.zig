//! Level.clip: the first block shape or fluid a segment meets, as BlockGetter.clip walks the cells
//! it crosses with ClipContext's shapes, VoxelShape.clip in each, and AABB.clip's arithmetic for
//! where it enters, so the point is vanilla's to the bit.

const std = @import("std");
const game_data = @import("game_data");
const mth = @import("mth.zig");
const body = @import("body.zig");

/// ClipContext.Fluid: the fluids a clip meets besides the shapes.
pub const Fluids = enum { none, source_only, any };

/// Direction, in vanilla's order.
pub const Face = enum(u3) {
    down,
    up,
    north,
    south,
    west,
    east,

    pub fn opposite(self: Face) Face {
        return switch (self) {
            .down => .up,
            .up => .down,
            .north => .south,
            .south => .north,
            .west => .east,
            .east => .west,
        };
    }
};

/// BlockHitResult of a hit: where the segment met the shape, the block, the face it entered
/// through, and whether it started inside the shape.
pub const Hit = struct { location: [3]f64, cell: [3]i32, face: Face, inside: bool };

/// BlockGetter.clip from `from` to `to` through outline shapes, ClipContext.Block.OUTLINE as
/// looking and using items trace, or null for ClipContext's miss.
pub fn clip(level: *const body.Level, from: [3]f64, to: [3]f64, fluids: Fluids) !?Hit {
    if (std.mem.eql(u64, @ptrCast(&from), @ptrCast(&to))) return null;
    // BlockGetter.traverseBlocks: from a start pulled 1e-7 back toward the end, to an end pulled
    // 1e-7 back toward the start.
    const start: [3]f64 = .{ lerp(-1.0e-7, from[0], to[0]), lerp(-1.0e-7, from[1], to[1]), lerp(-1.0e-7, from[2], to[2]) };
    const end: [3]f64 = .{ lerp(-1.0e-7, to[0], from[0]), lerp(-1.0e-7, to[1], from[1]), lerp(-1.0e-7, to[2], from[2]) };
    var cell: [3]i32 = .{ mth.floor(start[0]), mth.floor(start[1]), mth.floor(start[2]) };
    if (try visit(level, from, to, cell, fluids)) |hit| return hit;
    var step: [3]i32 = undefined;
    var next: [3]f64 = undefined;
    var increment: [3]f64 = undefined;
    for (0..3) |axis| {
        const span = end[axis] - start[axis];
        step[axis] = if (span > 0) 1 else if (span < 0) -1 else 0;
        increment[axis] = if (step[axis] == 0) std.math.floatMax(f64) else @as(f64, @floatFromInt(step[axis])) / span;
        const fraction = start[axis] - @floor(start[axis]);
        next[axis] = increment[axis] * (if (step[axis] > 0) 1.0 - fraction else fraction);
    }
    while (next[0] <= 1.0 or next[1] <= 1.0 or next[2] <= 1.0) {
        if (next[0] < next[1]) {
            if (next[0] < next[2]) {
                cell[0] += step[0];
                next[0] += increment[0];
            } else {
                cell[2] += step[2];
                next[2] += increment[2];
            }
        } else if (next[1] < next[2]) {
            cell[1] += step[1];
            next[1] += increment[1];
        } else {
            cell[2] += step[2];
            next[2] += increment[2];
        }
        if (try visit(level, from, to, cell, fluids)) |hit| return hit;
    }
    return null;
}

/// BlockGetter.clip's visitor for a cell: the nearer of the block's shape and its fluid's.
fn visit(level: *const body.Level, from: [3]f64, to: [3]f64, cell: [3]i32, fluids: Fluids) !?Hit {
    const state = try level.state(cell[0], cell[1], cell[2]);
    var boxes: [16]body.Box = undefined;
    const block = shapeClip(from, to, cell, outlineOf(state, cell, &boxes));
    const physics = game_data.physics.get(state);
    const picks = switch (fluids) {
        .none => false,
        .source_only => physics.fluid != .none and physics.amount == 8 and !physics.falling,
        .any => physics.fluid != .none,
    };
    const fluid = if (picks) fluid: {
        // FlowingFluid.getShape keeps one shape a state, as tall as the first it was asked for
        // stood: a fluid open to the air, its own height, which every clip then traces.
        const box: body.Box = .{ .min = .{ 0, 0, 0 }, .max = .{ 1, physics.height(), 1 } };
        break :fluid shapeClip(from, to, cell, &.{box});
    } else null;
    const block_distance = if (block) |hit| distanceSquared(from, hit.location) else std.math.floatMax(f64);
    const fluid_distance = if (fluid) |hit| distanceSquared(from, hit.location) else std.math.floatMax(f64);
    return if (block_distance <= fluid_distance) block else fluid;
}

/// A state's outline shape as boxes within its cell.
fn outlineOf(state: u16, cell: [3]i32, output: *[16]body.Box) []const body.Box {
    const outline = game_data.physics.outline(state, cell[0], cell[2]);
    const count = @min(outline.count, output.len);
    for (output[0..count], 0..) |*box, index| {
        const value = outline.get(index);
        box.* = .{ .min = .{ value[0], value[1], value[2] }, .max = .{ value[3], value[4], value[5] } };
    }
    return output[0..count];
}

/// VoxelShape.clip of a shape whose boxes lie within the cell: a hit just past the start when
/// that is inside the shape, or where AABB.clip enters it first.
fn shapeClip(from: [3]f64, to: [3]f64, cell: [3]i32, boxes: []const body.Box) ?Hit {
    if (boxes.len == 0) return null;
    const delta: [3]f64 = .{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    if (delta[0] * delta[0] + delta[1] * delta[1] + delta[2] * delta[2] < 1.0e-7) return null;
    const origin: [3]f64 = .{ @floatFromInt(cell[0]), @floatFromInt(cell[1]), @floatFromInt(cell[2]) };
    const probe: [3]f64 = .{ from[0] + delta[0] * 0.001, from[1] + delta[1] * 0.001, from[2] + delta[2] * 0.001 };
    for (boxes) |box| {
        const inside = for (0..3) |axis| {
            const at = probe[axis] - origin[axis];
            if (!(at >= box.min[axis] and at < box.max[axis])) break false;
        } else true;
        if (inside) return .{ .location = probe, .cell = cell, .face = nearestFace(delta).opposite(), .inside = true };
    }
    // AABB.clip: the least time over every box's faces facing the segment.
    var time: f64 = 1.0;
    var face: ?Face = null;
    for (boxes) |relative| {
        const box: body.Box = .{ .min = .{ origin[0] + relative.min[0], origin[1] + relative.min[1], origin[2] + relative.min[2] }, .max = .{ origin[0] + relative.max[0], origin[1] + relative.max[1], origin[2] + relative.max[2] } };
        face = facing(box, from, delta, &time, face);
    }
    const entered = face orelse return null;
    return .{ .location = .{ from[0] + time * delta[0], from[1] + time * delta[1], from[2] + time * delta[2] }, .cell = cell, .face = entered, .inside = false };
}

/// AABB.getDirection: each face the segment moves toward, tried as AABB.clipPoint tries it.
fn facing(box: body.Box, from: [3]f64, delta: [3]f64, time: *f64, found: ?Face) ?Face {
    var face = found;
    if (delta[0] > 1.0e-7) {
        face = clipPoint(time, face, delta, 0, box.min[0], box, .west, from);
    } else if (delta[0] < -1.0e-7) face = clipPoint(time, face, delta, 0, box.max[0], box, .east, from);
    if (delta[1] > 1.0e-7) {
        face = clipPoint(time, face, delta, 1, box.min[1], box, .down, from);
    } else if (delta[1] < -1.0e-7) face = clipPoint(time, face, delta, 1, box.max[1], box, .up, from);
    if (delta[2] > 1.0e-7) {
        face = clipPoint(time, face, delta, 2, box.min[2], box, .north, from);
    } else if (delta[2] < -1.0e-7) face = clipPoint(time, face, delta, 2, box.max[2], box, .south, from);
    return face;
}

/// AABB.clipPoint: where the segment crosses the plane of a face, if sooner than any yet and on
/// the face, within 1e-7.
fn clipPoint(time: *f64, found: ?Face, delta: [3]f64, axis: usize, plane: f64, box: body.Box, face: Face, from: [3]f64) ?Face {
    const a = (axis + 1) % 3;
    const b = (axis + 2) % 3;
    const at = (plane - from[axis]) / delta[axis];
    const along_a = from[a] + at * delta[a];
    const along_b = from[b] + at * delta[b];
    if (0.0 < at and at < time.* and box.min[a] - 1.0e-7 < along_a and along_a < box.max[a] + 1.0e-7 and box.min[b] - 1.0e-7 < along_b and along_b < box.max[b] + 1.0e-7) {
        time.* = at;
        return face;
    }
    return found;
}

/// Direction.getApproximateNearest: the direction whose normal is nearest, the first of equals.
fn nearestFace(vector: [3]f64) Face {
    const faces = [_]struct { face: Face, normal: [3]f64 }{
        .{ .face = .down, .normal = .{ 0, -1, 0 } },
        .{ .face = .up, .normal = .{ 0, 1, 0 } },
        .{ .face = .north, .normal = .{ 0, 0, -1 } },
        .{ .face = .south, .normal = .{ 0, 0, 1 } },
        .{ .face = .west, .normal = .{ -1, 0, 0 } },
        .{ .face = .east, .normal = .{ 1, 0, 0 } },
    };
    var best: Face = .north;
    var best_dot = -std.math.floatMax(f32);
    for (faces) |each| {
        const dot: f32 = @floatCast(vector[0] * each.normal[0] + vector[1] * each.normal[1] + vector[2] * each.normal[2]);
        if (dot > best_dot) {
            best_dot = dot;
            best = each.face;
        }
    }
    return best;
}

fn distanceSquared(a: [3]f64, b: [3]f64) f64 {
    return (b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]) + (b[2] - a[2]) * (b[2] - a[2]);
}

/// Mth.lerp: from start toward end by delta.
fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}
