const std = @import("std");

const multiplier: u64 = 0x5deece66d;
const addend: u64 = 0xb;
const mask: u64 = (@as(u64, 1) << 48) - 1;

pub const Random = struct {
    seed: u64,
    gaussian: f64 = 0,
    has_gaussian: bool = false,

    pub fn init(seed: u64) Random {
        var result = Random{ .seed = 0 };
        result.setSeed(seed);
        return result;
    }

    pub fn setSeed(self: *Random, seed: u64) void {
        self.seed = (seed ^ multiplier) & mask;
        self.has_gaussian = false;
    }

    pub inline fn nextBits(self: *Random, comptime bits: u6) u32 {
        self.seed = (self.seed *% multiplier +% addend) & mask;
        return @truncate(self.seed >> (48 - bits));
    }

    pub fn nextInt(self: *Random) i32 {
        return @bitCast(self.nextBits(32));
    }

    pub fn nextIntBounded(self: *Random, bound: i32) i32 {
        std.debug.assert(bound > 0);
        if ((bound & (bound - 1)) == 0) {
            const product = @as(i64, bound) * @as(i64, self.nextBits(31));
            return @intCast(product >> 31);
        }
        for (0..128) |_| {
            const bits: i32 = @intCast(self.nextBits(31));
            const value = @mod(bits, bound);
            const acceptance: i32 = bits -% value +% (bound -% 1);
            if (acceptance >= 0) return value;
        }
        unreachable;
    }

    pub fn nextLong(self: *Random) i64 {
        const high: i64 = self.nextInt();
        const low: i64 = self.nextInt();
        return (high << 32) +% low;
    }

    pub fn nextBoolean(self: *Random) bool {
        return self.nextBits(1) != 0;
    }

    pub fn nextFloat(self: *Random) f32 {
        return @as(f32, @floatFromInt(self.nextBits(24))) / @as(f32, 1 << 24);
    }

    pub fn nextDouble(self: *Random) f64 {
        const value = (@as(u64, self.nextBits(26)) << 27) + self.nextBits(27);
        return @as(f64, @floatFromInt(value)) * 0x1.0p-53;
    }

    pub fn nextGaussian(self: *Random) f64 {
        if (self.has_gaussian) {
            self.has_gaussian = false;
            return self.gaussian;
        }
        for (0..128) |_| {
            const x = 2.0 * self.nextDouble() - 1.0;
            const y = 2.0 * self.nextDouble() - 1.0;
            const radius = x * x + y * y;
            if (radius >= 1.0 or radius == 0.0) continue;
            const scale = @sqrt(-2.0 * @log(radius) / radius);
            self.gaussian = y * scale;
            self.has_gaussian = true;
            return x * scale;
        }
        unreachable;
    }
};

test "CheckedRandom matches Java 21 reference values" {
    var random = Random.init(6840335469066362132);
    try std.testing.expectEqual(@as(i32, 235), random.nextIntBounded(1000));
    try std.testing.expectEqual(@as(u32, 0x3f0a876f), @as(u32, @bitCast(random.nextFloat())));
    try std.testing.expectEqual(@as(i32, 16), random.nextIntBounded(60));
    try std.testing.expectEqual(@as(u64, 0x3fd760b6f8173f38), @as(u64, @bitCast(random.nextDouble())));
}

test "bounded generation exercises Java rejection and power-of-two paths" {
    var a = Random.init(1);
    var b = Random.init(1);
    for (0..1000) |_| {
        const power = a.nextIntBounded(64);
        const uneven = b.nextIntBounded(67);
        try std.testing.expect(power >= 0 and power < 64);
        try std.testing.expect(uneven >= 0 and uneven < 67);
    }
}
