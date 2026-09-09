const std = @import("std");

const sine_table = makeSineTable();
const arcsine_tables = makeArcsineTables();
const arcsine_table = arcsine_tables[0];
const cosine_of_arcsine_table = arcsine_tables[1];
const rounder_256ths: f64 = @bitCast(@as(u64, 4805340802404319232));

fn makeSineTable() [65536]f32 {
    @setEvalBranchQuota(200000);
    var table: [65536]f32 = undefined;
    for (&table, 0..) |*value, index| {
        const radians = @as(f64, @floatFromInt(index)) * std.math.pi * 2.0 / 65536.0;
        value.* = @floatCast(@sin(radians));
    }
    return table;
}

fn makeArcsineTables() struct { [257]f64, [257]f64 } {
    @setEvalBranchQuota(10000);
    var arcsine: [257]f64 = undefined;
    var cosine: [257]f64 = undefined;
    for (0..257) |index| {
        const value = @as(f64, @floatFromInt(index)) / 256.0;
        const angle = std.math.asin(value);
        arcsine[index] = angle;
        cosine[index] = @cos(angle);
    }
    return .{ arcsine, cosine };
}

pub inline fn sin(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * @as(f32, 10430.378));
    return sine_table[@as(u16, @truncate(@as(u32, @bitCast(scaled))))];
}

pub inline fn cos(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * @as(f32, 10430.378) + @as(f32, 16384));
    return sine_table[@as(u16, @truncate(@as(u32, @bitCast(scaled))))];
}

pub inline fn wrapDegrees(value: f32) f32 {
    var result = @rem(value, @as(f32, 360));
    if (result >= 180) result -= 360;
    if (result < -180) result += 360;
    return result;
}

pub inline fn changeAngle(current: f32, target: f32, maximum: f32) f32 {
    const delta = std.math.clamp(wrapDegrees(target - current), -maximum, maximum);
    var result = current + delta;
    if (result < 0) result += 360 else if (result > 360) result -= 360;
    return result;
}

pub inline fn movementYaw(dz: f64, dx: f64) f32 {
    @setFloatMode(.strict);
    const angle_bits: u64 = @bitCast(atan2(dz, dx));
    const angle: f64 = @bitCast(angle_bits);
    const degrees_bits: u64 = @bitCast(angle * 57.2957763671875);
    const degrees: f32 = @floatCast(@as(f64, @bitCast(degrees_bits)));
    return degrees - @as(f32, 90);
}

pub fn atan2(initial_y: f64, initial_x: f64) f64 {
    var y = initial_y;
    var x = initial_x;
    const magnitude_squared = x * x + y * y;
    if (std.math.isNan(magnitude_squared)) return std.math.nan(f64);
    const negative_y = y < 0;
    if (negative_y) y = -y;
    const negative_x = x < 0;
    if (negative_x) x = -x;
    const swapped = y > x;
    if (swapped) std.mem.swap(f64, &x, &y);

    const inverse_magnitude = fastInverseSqrt(magnitude_squared);
    x *= inverse_magnitude;
    y *= inverse_magnitude;
    const rounded = rounder_256ths + y;
    const index: u32 = @truncate(@as(u64, @bitCast(rounded)));
    const arcsine = arcsine_table[index];
    const cosine = cosine_of_arcsine_table[index];
    const rounded_y = rounded - rounder_256ths;
    const delta = y * cosine - x * rounded_y;
    const correction = (6.0 + delta * delta) * delta * (1.0 / 6.0);
    var angle = arcsine + correction;
    if (swapped) angle = std.math.pi / 2.0 - angle;
    if (negative_x) angle = std.math.pi - angle;
    if (negative_y) angle = -angle;
    return angle;
}

inline fn fastInverseSqrt(value: f64) f64 {
    const half = 0.5 * value;
    var bits: u64 = @bitCast(value);
    bits = 6910469410427058090 - (bits >> 1);
    var estimate: f64 = @bitCast(bits);
    estimate *= 1.5 - half * estimate * estimate;
    return estimate;
}

test "movement yaw and lookup trigonometry match the first Vanilla westward chase tick" {
    const angle = atan2(0, -1);
    try std.testing.expectEqual(@as(u64, 0x400921fb54442d18), @as(u64, @bitCast(angle)));
    const degrees = angle * 57.2957763671875;
    try std.testing.expectEqual(@as(u64, 0x40667fffeb460a52), @as(u64, @bitCast(degrees)));
    const yaw = changeAngle(90, movementYaw(0, -1), 90);
    try std.testing.expectEqual(@as(u32, 0x42b3fffe), @as(u32, @bitCast(yaw)));
    const radians = yaw * @as(f32, 0.017453292);
    try std.testing.expectEqual(@as(u32, 0x3f800000), @as(u32, @bitCast(sin(radians))));
    try std.testing.expectEqual(@as(u32, 0x38c90fdb), @as(u32, @bitCast(cos(radians))));
}

test "immutable lookup table matches runtime generation bit for bit" {
    for (sine_table, 0..) |value, index| {
        const radians = @as(f64, @floatFromInt(index)) * std.math.pi * 2.0 / 65536.0;
        const expected: f32 = @floatCast(@sin(radians));
        try std.testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(value)));
    }
}
