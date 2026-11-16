//! LegacyRandomSource, the random each vanilla entity draws from: Java's 48 bit linear
//! congruential generator with vanilla's bounded ints, floats, doubles and Marsaglia polar
//! gaussians. Mobs draw in vanilla's order, so a mob seeded as vanilla seeds one behaves alike.

const std = @import("std");

pub const JavaRandom = struct {
    seed: u64,
    next_gaussian: f64 = 0,
    have_next_gaussian: bool = false,

    const multiplier: u64 = 25214903917;
    const mask: u64 = (1 << 48) - 1;

    pub fn init(seed: i64) JavaRandom {
        return .{ .seed = (@as(u64, @bitCast(seed)) ^ multiplier) & mask };
    }

    /// The state to store, the seed as Java holds it after scrambling.
    pub fn state(self: JavaRandom) u64 {
        return self.seed;
    }

    pub fn restore(seed: u64) JavaRandom {
        return .{ .seed = seed & mask };
    }

    pub fn next(self: *JavaRandom, bits: u6) i32 {
        std.debug.assert(bits >= 1 and bits <= 32);
        self.seed = (self.seed *% multiplier +% 11) & mask;
        return @truncate(@as(i64, @intCast(self.seed >> @intCast(48 - @as(u7, bits)))));
    }

    pub fn nextInt(self: *JavaRandom) i32 {
        return self.next(32);
    }

    pub fn nextIntBounded(self: *JavaRandom, bound: i32) i32 {
        std.debug.assert(bound > 0);
        if (bound & (bound - 1) == 0) return @intCast((@as(i64, bound) * self.next(31)) >> 31);
        while (true) {
            const bits = self.next(31);
            const value = @rem(bits, bound);
            // Java tests bits - value + (bound - 1) < 0 in 32 bit arithmetic, which overflows.
            if (bits -% value +% (bound - 1) >= 0) return value;
        }
    }

    pub fn nextLong(self: *JavaRandom) i64 {
        const high: i64 = self.next(32);
        const low: i64 = self.next(32);
        return (high << 32) +% low;
    }

    pub fn nextBoolean(self: *JavaRandom) bool {
        return self.next(1) != 0;
    }

    pub fn nextFloat(self: *JavaRandom) f32 {
        return @as(f32, @floatFromInt(self.next(24))) * 5.9604645e-8;
    }

    pub fn nextDouble(self: *JavaRandom) f64 {
        const high: i64 = self.next(26);
        const low: i64 = self.next(27);
        return @as(f64, @floatFromInt((high << 27) + low)) * 1.1102230246251565e-16;
    }

    pub fn nextGaussian(self: *JavaRandom) f64 {
        if (self.have_next_gaussian) {
            self.have_next_gaussian = false;
            return self.next_gaussian;
        }
        while (true) {
            const x = 2.0 * self.nextDouble() - 1.0;
            const y = 2.0 * self.nextDouble() - 1.0;
            const squared = x * x + y * y;
            if (squared >= 1.0 or squared == 0.0) continue;
            const scale = @sqrt(-2.0 * @log(squared) / squared);
            self.next_gaussian = y * scale;
            self.have_next_gaussian = true;
            return x * scale;
        }
    }

    pub fn triangle(self: *JavaRandom, mode: f64, deviation: f64) f64 {
        return mode + deviation * (self.nextDouble() - self.nextDouble());
    }

    pub fn triangleFloat(self: *JavaRandom, mode: f32, deviation: f32) f32 {
        return mode + deviation * (self.nextFloat() - self.nextFloat());
    }

    pub fn nextIntBetweenInclusive(self: *JavaRandom, minimum: i32, maximum: i32) i32 {
        return self.nextIntBounded(maximum - minimum + 1) + minimum;
    }
};

test "draws match java.util.Random" {
    // Values from new java.util.Random(42), which LegacyRandomSource draws alike.
    var random = JavaRandom.init(42);
    try std.testing.expectEqual(@as(i32, -1170105035), random.nextInt());
    try std.testing.expectEqual(@as(i32, 234785527), random.nextInt());
    random = JavaRandom.init(42);
    try std.testing.expectEqual(@as(i32, 0), random.nextIntBounded(10));
    try std.testing.expectEqual(@as(i32, 3), random.nextIntBounded(10));
    random = JavaRandom.init(42);
    try std.testing.expectEqual(@as(f32, 0.7275637), random.nextFloat());
    random = JavaRandom.init(42);
    try std.testing.expectEqual(@as(f64, 0.7275636800328681), random.nextDouble());
    random = JavaRandom.init(42);
    // java.util.Random takes StrictMath logarithms, vanilla Math ones, which may differ in the last place.
    try std.testing.expectApproxEqAbs(@as(f64, 1.1419053154730547), random.nextGaussian(), 1e-15);
}
