//! Vanilla's Mth, which mobs turn and move by: sine and cosine from a table of 65536 steps, its
//! own atan2 from small tables, and angle wrapping. The tables come from the snapshot, as the JVM
//! rounds them, so results match vanilla bit for bit. The tests check values vanilla printed.

const std = @import("std");
const game_data = @import("game_data");

const assert = std.debug.assert;

fn tableIndex(value: f32) u16 {
    // Java's float to int conversion saturates and turns NaN into 0, then the index keeps 16 bits.
    return @truncate(@as(u32, @bitCast(javaInt(value))));
}

pub fn sin(value: f32) f32 {
    return game_data.physics.sine(tableIndex(value * 10430.378));
}

pub fn cos(value: f32) f32 {
    return game_data.physics.sine(tableIndex(value * 10430.378 + 16384.0));
}

/// Java's (int) cast of a float.
pub fn javaInt(value: f32) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483647.0) return std.math.maxInt(i32);
    if (value <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

/// Java's (int) cast of a double.
pub fn javaIntDouble(value: f64) i32 {
    if (std.math.isNan(value)) return 0;
    if (value >= 2147483647.0) return std.math.maxInt(i32);
    if (value <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(value);
}

pub fn floor(value: f64) i32 {
    const truncated = javaIntDouble(value);
    return if (value < @as(f64, @floatFromInt(truncated))) truncated - 1 else truncated;
}

pub fn floorFloat(value: f32) i32 {
    const truncated = javaInt(value);
    return if (value < @as(f32, @floatFromInt(truncated))) truncated - 1 else truncated;
}

pub fn ceil(value: f64) i32 {
    const truncated = javaIntDouble(value);
    return if (value > @as(f64, @floatFromInt(truncated))) truncated + 1 else truncated;
}

pub fn sqrt(value: f32) f32 {
    return @floatCast(@sqrt(@as(f64, value)));
}

pub fn wrapDegrees(value: f32) f32 {
    // Java % keeps the sign of the dividend, as @rem does.
    var wrapped = @rem(value, 360.0);
    if (wrapped >= 180.0) wrapped -= 360.0;
    if (wrapped < -180.0) wrapped += 360.0;
    return wrapped;
}

pub fn wrapDegreesDouble(value: f64) f64 {
    // Java % keeps the sign of the dividend, as @rem does.
    var wrapped = @rem(value, 360.0);
    if (wrapped >= 180.0) wrapped -= 360.0;
    if (wrapped < -180.0) wrapped += 360.0;
    return wrapped;
}

pub fn degreesDifference(from: f32, to: f32) f32 {
    return wrapDegrees(to - from);
}

pub fn clamp(value: f32, minimum: f32, maximum: f32) f32 {
    return if (value < minimum) minimum else @min(value, maximum);
}

pub fn clampDouble(value: f64, minimum: f64, maximum: f64) f64 {
    return if (value < minimum) minimum else @min(value, maximum);
}

pub fn rotateIfNecessary(angle: f32, target: f32, limit: f32) f32 {
    const difference = degreesDifference(angle, target);
    return target - clamp(difference, -limit, limit);
}

/// Control.rotateTowards, which every control turns by.
pub fn rotateTowards(angle: f32, target: f32, limit: f32) f32 {
    return angle + clamp(degreesDifference(angle, target), -limit, limit);
}

pub fn sign(value: f32) f32 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

/// Mth.packDegrees, the byte angles of entity packets.
pub fn packDegrees(value: f32) i8 {
    return @truncate(floorFloat(value * 256.0 / 360.0));
}

pub fn equal(a: f64, b: f64) bool {
    return @abs(b - a) < @as(f64, @as(f32, 1.0e-5));
}

/// Mth.lerp for floats.
pub fn lerp(delta: f32, start: f32, end: f32) f32 {
    return start + delta * (end - start);
}

fn fastInverseSqrt(value: f64) f64 {
    const half = 0.5 * value;
    var bits: i64 = @bitCast(value);
    bits = 6910469410427058090 - (bits >> 1);
    const estimate: f64 = @bitCast(bits);
    return estimate * (1.5 - half * estimate * estimate);
}

/// Mth.atan2, from vanilla's tables. It differs from the exact arctangent in the last digits,
/// and mobs face along it.
pub fn atan2(y_in: f64, x_in: f64) f64 {
    var y = y_in;
    var x = x_in;
    const squared = x * x + y * y;
    if (std.math.isNan(squared)) return std.math.nan(f64);
    const negative_y = y < 0;
    if (negative_y) y = -y;
    const negative_x = x < 0;
    if (negative_x) x = -x;
    const steep = y > x;
    if (steep) {
        const swap = x;
        x = y;
        y = swap;
    }
    const inverse = fastInverseSqrt(squared);
    x *= inverse;
    y *= inverse;
    const bias: f64 = @bitCast(@as(u64, 4805340802404319232));
    const biased = bias + y;
    const index: u9 = @intCast(@as(u32, @truncate(@as(u64, @bitCast(biased)))));
    const base, const base_cosine = game_data.physics.arcsine(index);
    const sampled = biased - bias;
    const delta = y * base_cosine - x * sampled;
    const correction = (6.0 + delta * delta) * delta * 0.16666666666666666;
    var angle = base + correction;
    if (steep) angle = std.math.pi / 2.0 - angle;
    if (negative_x) angle = std.math.pi - angle;
    if (negative_y) angle = -angle;
    return angle;
}

test "table sine and atan2 follow vanilla" {
    try std.testing.expectEqual(@as(f32, 0), sin(0));
    try std.testing.expectEqual(@as(f32, 1), cos(0));
    // Printed by vanilla 1.21.8 Mth.
    try std.testing.expectEqual(@as(f64, 0.7853981366411398), atan2(1, 1));
    try std.testing.expectEqual(@as(f64, -2.356194516948653), atan2(-1, -1));
    try std.testing.expectEqual(@as(f64, 3.0309364770691625), atan2(0.3, -2.7));
    try std.testing.expectEqual(@as(f64, 1.5253719614728096), atan2(5.5, 0.25));
    try std.testing.expectEqual(@as(f32, 0.8414514), sin(1.0));
    try std.testing.expectEqual(@as(f32, 0.54033285), cos(1.0));
    try std.testing.expectEqual(@as(f32, -0.5985448), sin(-2.5));
    try std.testing.expectEqual(@as(f32, 0.86227834), cos(100.0));
    try std.testing.expectEqual(@as(f32, -170), wrapDegrees(190));
    try std.testing.expectEqual(@as(f32, 170), wrapDegrees(-190));
    try std.testing.expectEqual(@as(i8, -128), packDegrees(180));
    try std.testing.expectEqual(@as(i32, -2), floor(-1.5));
}
