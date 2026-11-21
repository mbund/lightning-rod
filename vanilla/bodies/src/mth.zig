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

/// Java's float % 360: the sign of the dividend, exact. Below 360 it is the value itself, and below
/// 720 one subtraction is exact (Sterbenz), keeping a zero's sign, which spares the library call.
pub fn remainder360(value: f32) f32 {
    const size = @abs(value);
    if (size < 360.0) return value;
    if (size < 720.0) {
        const reduced = if (value > 0) value - 360.0 else value + 360.0;
        return if (reduced == 0) std.math.copysign(@as(f32, 0), value) else reduced;
    }
    return @rem(value, 360.0);
}

pub fn wrapDegrees(value: f32) f32 {
    var wrapped = remainder360(value);
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


/// Mth.atan2 for several at once, each lane the same operations as `atan2` alone.
pub fn atan2Many(comptime lanes: usize, y_in: @Vector(lanes, f64), x_in: @Vector(lanes, f64)) @Vector(lanes, f64) {
    const V = @Vector(lanes, f64);
    const I = @Vector(lanes, i64);
    const zero: V = @splat(0);
    const squared = x_in * x_in + y_in * y_in;
    const negative_y = y_in < zero;
    const negative_x = x_in < zero;
    const ay = @abs(y_in);
    const ax = @abs(x_in);
    const steep = ay > ax;
    var x = @select(f64, steep, ay, ax);
    var y = @select(f64, steep, ax, ay);
    // fastInverseSqrt, lane by lane.
    const half = @as(V, @splat(0.5)) * squared;
    const bits: I = @as(I, @splat(6910469410427058090)) - (@as(I, @bitCast(squared)) >> @splat(1));
    const estimate: V = @bitCast(bits);
    const inverse = estimate * (@as(V, @splat(1.5)) - half * estimate * estimate);
    x *= inverse;
    y *= inverse;
    const bias: V = @splat(@as(f64, @bitCast(@as(u64, 4805340802404319232))));
    const biased = bias + y;
    const nan = squared != squared;
    var base: V = undefined;
    var base_cosine: V = undefined;
    const biased_bits: @Vector(lanes, u64) = @bitCast(biased);
    inline for (0..lanes) |lane| {
        // The table has 257 entries; a NaN lane reads the first and is NaN in the end anyway.
        const index: u32 = if (nan[lane]) 0 else @truncate(biased_bits[lane]);
        base[lane] = game_data.physics.arcsines[index];
        base_cosine[lane] = game_data.physics.arccosines[index];
    }
    const sampled = biased - bias;
    const delta = y * base_cosine - x * sampled;
    const correction = (@as(V, @splat(6.0)) + delta * delta) * delta * @as(V, @splat(0.16666666666666666));
    var angle = base + correction;
    angle = @select(f64, steep, @as(V, @splat(std.math.pi / 2.0)) - angle, angle);
    angle = @select(f64, negative_x, @as(V, @splat(std.math.pi)) - angle, angle);
    angle = @select(f64, negative_y, -angle, angle);
    return @select(f64, nan, @as(V, @splat(std.math.nan(f64))), angle);
}

test "atan2 for several at once matches atan2 alone bit for bit" {
    var random = std.Random.DefaultPrng.init(0x6174616e);
    for (0..20_000) |_| {
        var ys: [8]f64 = undefined;
        var xs: [8]f64 = undefined;
        for (&ys, &xs) |*y, *x| {
            const r = random.random();
            y.* = switch (r.uintLessThan(u8, 5)) {
                0 => 0,
                1 => -0.0,
                2 => (r.float(f64) - 0.5) * 1e-6,
                else => (r.float(f64) - 0.5) * 10,
            };
            x.* = switch (r.uintLessThan(u8, 5)) {
                0 => 0,
                1 => -0.0,
                2 => (r.float(f64) - 0.5) * 1e-6,
                else => (r.float(f64) - 0.5) * 10,
            };
        }
        const many: [8]f64 = atan2Many(8, ys, xs);
        for (ys, xs, 0..) |y, x, lane| try std.testing.expectEqual(@as(u64, @bitCast(atan2(y, x))), @as(u64, @bitCast(many[lane])));
    }
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

test "the fast remainder by 360 matches the library's bit for bit" {
    const edges = [_]f32{ 0.0, -0.0, 359.99997, 360.0, -360.0, 360.00003, 540.0, -540.0, 719.99994, -719.99994, 720.0, -720.0, 1000.5, -1000.5 };
    for (edges) |value| try std.testing.expectEqual(@as(u32, @bitCast(@rem(value, @as(f32, 360.0)))), @as(u32, @bitCast(remainder360(value))));
    var prng = std.Random.DefaultPrng.init(360);
    for (0..1_000_000) |_| {
        const value = (prng.random().float(f32) - 0.5) * 2000.0;
        try std.testing.expectEqual(@as(u32, @bitCast(@rem(value, @as(f32, 360.0)))), @as(u32, @bitCast(remainder360(value))));
    }
}
