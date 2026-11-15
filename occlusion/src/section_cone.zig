//! Direction bounds for the section flood.
//!
//! The octant flood only knows that a ray moves monotonically in one octant, so an
//! opening into open air would disclose a whole quadrant of sky. Every straight ray from
//! the eye region passes through each section face on its path, so its direction lies in
//! the direction set of every such face. Intersecting those sets along the flood removes
//! directions that no straight ray can take and never removes one that it can.
//!
//! Work happens in an octant frame, mirrored so that every direction component is
//! non-negative. A direction set is bounded by three projected slopes, one per coordinate
//! plane, each rise over run: y over x, z over y and x over z.
const std = @import("std");
const assert = std.debug.assert;

/// Largest coordinate difference; whole blocks below it are exact in f32.
pub const maximum_span = 1 << 16;

const Lanes = @Vector(4, f32);
const infinity = std.math.inf(f32);
// Lane 3 is unused and stays zero in every non-empty cone.
const zero: Lanes = @splat(0);

// Bounds round outward. Coordinates are exact, so a quotient errs by at most 2^-24
// relative and one further rounding stays far inside this widening.
const widen_low: Lanes = @splat(1.0 - 1.0 / @as(f32, 1 << 20));
const widen_high: Lanes = @splat(1.0 + 1.0 / @as(f32, 1 << 20));

pub const Cone = struct {
    low: Lanes,
    high: Lanes,

    // Empty cones are canonical so a hull with one leaves the other unchanged.
    pub const empty: Cone = .{ .low = @splat(infinity), .high = zero };
    pub const full: Cone = .{ .low = zero, .high = .{ infinity, infinity, infinity, 0 } };

    pub fn isEmpty(self: *const Cone) bool {
        return @reduce(.Or, self.low > self.high);
    }

    pub fn intersect(self: *const Cone, other: *const Cone) Cone {
        const result: Cone = .{ .low = @max(self.low, other.low), .high = @min(self.high, other.high) };
        return if (result.isEmpty()) empty else result;
    }

    /// The smallest cone covering both; it may admit directions neither admits.
    pub fn hull(self: *const Cone, other: *const Cone) Cone {
        return .{ .low = @min(self.low, other.low), .high = @max(self.high, other.high) };
    }

    /// Whether the direction with these per-plane slopes lies inside.
    pub fn admits(self: *const Cone, slopes: [3]f32) bool {
        const value: Lanes = .{ slopes[0], slopes[1], slopes[2], 0 };
        return !self.isEmpty() and !@reduce(.Or, value < self.low) and !@reduce(.Or, value > self.high);
    }
};

/// Integer box with exclusive maxima in an octant frame.
pub const Box = struct {
    low: [3]i32,
    high: [3]i32,

    /// Mirrors `self` so the octant's direction components become non-negative.
    /// Octant bit 0 selects +x, bit 1 selects +y and bit 2 selects +z.
    pub fn mirror(self: Box, octant: u3) Box {
        var result: Box = undefined;
        inline for (0..3) |axis| {
            const positive = (octant >> axis) & 1 != 0;
            result.low[axis] = if (positive) self.low[axis] else -self.high[axis];
            result.high[axis] = if (positive) self.high[axis] else -self.low[axis];
        }
        return result;
    }
};

/// Directions from any point of `eye` that reach the face of `target` crossing `exit`,
/// where both boxes are already in the same octant frame.
pub fn exitCone(eye: *const Box, target: *const Box, comptime exit: usize) Cone {
    var face_low = target.low;
    // The exit face is the far side of the target along the exit axis.
    face_low[exit] = target.high[exit];
    const reach = @as(@Vector(3, i32), target.high) - @as(@Vector(3, i32), eye.low);
    if (@reduce(.Or, reach < @as(@Vector(3, i32), @splat(0)))) return Cone.empty;
    const gap = @max(@as(@Vector(3, i32), face_low) - @as(@Vector(3, i32), eye.high), @as(@Vector(3, i32), @splat(0)));
    assert(@reduce(.And, reach <= @as(@Vector(3, i32), @splat(maximum_span))));
    const far: Lanes = .{ @floatFromInt(reach[0]), @floatFromInt(reach[1]), @floatFromInt(reach[2]), 1 };
    const near: Lanes = .{ @floatFromInt(gap[0]), @floatFromInt(gap[1]), @floatFromInt(gap[2]), 1 };
    // Planes pair run axes 0, 1, 2 with rise axes 1, 2, 0; lane 3 divides 0 by 1.
    const run_far = far;
    const run_near = near;
    const rise_far = @shuffle(f32, far, undefined, @Vector(4, i32){ 1, 2, 0, 3 }) * Lanes{ 1, 1, 1, 0 };
    const rise_near = @shuffle(f32, near, undefined, @Vector(4, i32){ 1, 2, 0, 3 }) * Lanes{ 1, 1, 1, 0 };
    // A ray that cannot advance along the run axis only fits a rise of zero or infinity.
    const stalled = @select(bool, run_far == zero, rise_near == zero, @as(@Vector(4, bool), @splat(false)));
    const low = @select(f32, stalled, zero, rise_near / run_far * widen_low);
    const high = @select(f32, run_near == zero, Lanes{ infinity, infinity, infinity, 0 }, rise_far / run_near * widen_high);
    return .{ .low = low, .high = high };
}

fn slope(rise: f64, run: f64) f32 {
    return if (run == 0) infinity else @floatCast(rise / run);
}

test "intersection and hull bound every direction of their inputs" {
    var random = std.Random.DefaultPrng.init(0xc0e5);
    for (0..4096) |_| {
        var cones: [2]Cone = undefined;
        for (&cones) |*cone| {
            cone.* = .{ .low = zero, .high = zero };
            inline for (0..3) |plane| {
                const a = slope(@floatFromInt(random.random().uintAtMost(u32, 64)), @floatFromInt(random.random().uintAtMost(u32, 64)));
                const b = slope(@floatFromInt(random.random().uintAtMost(u32, 64)), @floatFromInt(random.random().uintAtMost(u32, 64)));
                cone.low[plane] = @min(a, b);
                cone.high[plane] = @max(a, b);
            }
        }
        const both = cones[0].intersect(&cones[1]);
        const either = cones[0].hull(&cones[1]);
        try std.testing.expectEqual(cones[0], cones[0].hull(&Cone.empty));
        for (0..64) |_| {
            var slopes: [3]f32 = undefined;
            for (&slopes) |*value| value.* = slope(@floatFromInt(random.random().uintAtMost(u32, 64)), @floatFromInt(random.random().uintAtMost(u32, 64)));
            const first = cones[0].admits(slopes);
            const second = cones[1].admits(slopes);
            try std.testing.expectEqual(first and second, both.admits(slopes));
            if (first or second) try std.testing.expect(either.admits(slopes));
        }
    }
}

test "exit cones contain every segment from the eye box to the exit face" {
    var random = std.Random.DefaultPrng.init(0xface);
    for (0..4096) |trial| {
        var eye: Box = undefined;
        var target: Box = undefined;
        // Distant trials exercise slopes near the limits of f32 precision.
        const scale: i32 = if (trial % 2 == 0) 1 else 1000;
        for (0..3) |axis| {
            eye.low[axis] = random.random().intRangeAtMost(i32, -8, 8);
            eye.high[axis] = eye.low[axis] + random.random().intRangeAtMost(i32, 0, 6);
            target.low[axis] = random.random().intRangeAtMost(i32, -4, 40 * scale);
            target.high[axis] = target.low[axis] + 16;
        }
        inline for (0..3) |exit| {
            const cone = exitCone(&eye, &target, exit);
            for (0..32) |_| {
                var from: [3]f64 = undefined;
                var to: [3]f64 = undefined;
                var forward = true;
                for (0..3) |axis| {
                    const eye_low: f64 = @floatFromInt(eye.low[axis]);
                    const eye_high: f64 = @floatFromInt(eye.high[axis]);
                    const target_low: f64 = @floatFromInt(target.low[axis]);
                    const target_high: f64 = @floatFromInt(target.high[axis]);
                    // Corners are the extreme directions, so half the samples snap to them.
                    const corner = random.random().boolean();
                    from[axis] = if (corner) (if (random.random().boolean()) eye_low else eye_high) else eye_low + (eye_high - eye_low) * random.random().float(f64);
                    to[axis] = if (axis == exit) target_high else if (corner) (if (random.random().boolean()) target_low else target_high) else target_low + 16 * random.random().float(f64);
                    forward = forward and to[axis] >= from[axis];
                }
                if (!forward) continue;
                const run = [3]f64{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
                var slopes: [3]f32 = undefined;
                var degenerate = false;
                for (0..3) |plane| {
                    const rise = run[(plane + 1) % 3];
                    // A segment without extent in this plane fits any slope, so skip it.
                    degenerate = degenerate or (run[plane] == 0 and rise == 0);
                    slopes[plane] = slope(rise, run[plane]);
                }
                if (degenerate) continue;
                try std.testing.expect(cone.admits(slopes));
            }
        }
    }
}
