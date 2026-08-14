const std = @import("std");

const golden_gamma: u64 = 0x9e37_79b9_7f4a_7c15;
const silver_seed: u64 = 0x6a09_e667_f3bc_c909;

pub const Xoroshiro = struct {
    lo: u64,
    hi: u64,

    pub fn init(seed: u64) Xoroshiro {
        const lo = seed ^ silver_seed;
        return initState(staffordMix13(lo), staffordMix13(lo +% golden_gamma));
    }

    pub fn initUnmixed(seed: u64) Xoroshiro {
        const lo = seed ^ silver_seed;
        return initState(lo, lo +% golden_gamma);
    }

    pub fn initState(lo: u64, hi: u64) Xoroshiro {
        if (lo | hi == 0) return .{ .lo = golden_gamma, .hi = silver_seed };
        return .{ .lo = lo, .hi = hi };
    }

    pub inline fn nextU64(self: *Xoroshiro) u64 {
        const lo = self.lo;
        var hi = self.hi;
        const result = std.math.rotl(u64, lo +% hi, 17) +% lo;
        hi ^= lo;
        self.lo = std.math.rotl(u64, lo, 49) ^ hi ^ (hi << 21);
        self.hi = std.math.rotl(u64, hi, 28);
        return result;
    }

    pub inline fn nextI32(self: *Xoroshiro) i32 {
        return @bitCast(@as(u32, @truncate(self.nextU64())));
    }

    pub fn nextBoundedI32(self: *Xoroshiro, bound: i32) i32 {
        std.debug.assert(bound > 0);
        const unsigned_bound: u64 = @intCast(bound);
        var value: u64 = @as(u32, @bitCast(self.nextI32()));
        var product = value *% unsigned_bound;
        var low: u64 = @as(u32, @truncate(product));
        if (low < unsigned_bound) {
            const threshold = (0 -% unsigned_bound) % unsigned_bound;
            while (low < threshold) {
                value = @as(u32, @bitCast(self.nextI32()));
                product = value *% unsigned_bound;
                low = @as(u32, @truncate(product));
            }
        }
        return @intCast(product >> 32);
    }

    pub inline fn nextBool(self: *Xoroshiro) bool {
        return self.nextU64() & 1 != 0;
    }

    pub inline fn nextF32(self: *Xoroshiro) f32 {
        return @as(f32, @floatFromInt(self.nextU64() >> 40)) * 0x1.0p-24;
    }

    pub inline fn nextF64(self: *Xoroshiro) f64 {
        return @as(f64, @floatFromInt(self.nextU64() >> 11)) * 0x1.0p-53;
    }

    pub fn split(self: *Xoroshiro) Xoroshiro {
        return initState(self.nextU64(), self.nextU64());
    }

    pub fn splitter(self: *Xoroshiro) Splitter {
        return .{ .lo = self.nextU64(), .hi = self.nextU64() };
    }

    pub fn populationSeed(world_seed: u64, block_x: i32, block_z: i32) u64 {
        var random = init(world_seed);
        const x_seed: i64 = @bitCast(random.nextU64() | 1);
        const z_seed: i64 = @bitCast(random.nextU64() | 1);
        const mixed = @as(i64, block_x) *% x_seed +% @as(i64, block_z) *% z_seed;
        return @as(u64, @bitCast(mixed)) ^ world_seed;
    }
};

pub const ChunkRandom = struct {
    base: Xoroshiro,
    gaussian: f64 = 0,
    has_gaussian: bool = false,

    pub fn init(seed: u64) ChunkRandom {
        return .{ .base = Xoroshiro.init(seed) };
    }

    pub fn reseed(self: *ChunkRandom, seed: u64) void {
        self.base = Xoroshiro.init(seed);
    }

    pub inline fn next(self: *ChunkRandom, comptime bits: u6) i32 {
        const shift: u6 = @intCast(64 - @as(u7, bits));
        const value: u32 = @truncate(self.base.nextU64() >> shift);
        return if (bits == 32) @bitCast(value) else @intCast(value);
    }

    pub fn nextBoundedI32(self: *ChunkRandom, bound: i32) i32 {
        std.debug.assert(bound > 0);
        if (bound & (bound - 1) == 0)
            return @intCast((@as(i64, bound) * self.next(31)) >> 31);
        for (0..128) |_| {
            const value = self.next(31);
            const result = @mod(value, bound);
            if (value -% result +% (bound - 1) >= 0) return result;
        }
        unreachable;
    }

    pub fn nextI64(self: *ChunkRandom) i64 {
        const upper = @as(i64, self.next(32)) << 32;
        return upper +% @as(i64, self.next(32));
    }

    pub inline fn nextF32(self: *ChunkRandom) f32 {
        return @as(f32, @floatFromInt(self.next(24))) * 0x1.0p-24;
    }

    pub inline fn nextBool(self: *ChunkRandom) bool {
        return self.next(1) != 0;
    }

    pub inline fn nextF64(self: *ChunkRandom) f64 {
        const upper = @as(i64, self.next(26)) << 27;
        return @as(f64, @floatFromInt(upper + self.next(27))) * 0x1.0p-53;
    }

    pub fn nextGaussian(self: *ChunkRandom) f64 {
        if (self.has_gaussian) {
            self.has_gaussian = false;
            return self.gaussian;
        }
        for (0..128) |_| {
            const x = 2 * self.nextF64() - 1;
            const y = 2 * self.nextF64() - 1;
            const radius = x * x + y * y;
            if (radius >= 1 or radius == 0) continue;
            const scale = @sqrt(-2 * @log(radius) / radius);
            self.gaussian = y * scale;
            self.has_gaussian = true;
            return x * scale;
        }
        unreachable;
    }

    pub fn populationSeed(world_seed: u64, block_x: i32, block_z: i32) u64 {
        var source = init(world_seed);
        const x_seed = source.nextI64() | 1;
        const z_seed = source.nextI64() | 1;
        const mixed = @as(i64, block_x) *% x_seed +% @as(i64, block_z) *% z_seed;
        return @as(u64, @bitCast(mixed)) ^ world_seed;
    }
};

pub const Splitter = struct {
    lo: u64,
    hi: u64,

    pub fn splitSeed(self: Splitter, seed: u64) Xoroshiro {
        return Xoroshiro.initState(seed ^ self.lo, seed ^ self.hi);
    }

    pub fn splitPosition(self: Splitter, x: i32, y: i32, z: i32) Xoroshiro {
        const seed: u64 = @bitCast(hashBlockPosition(x, y, z));
        return Xoroshiro.initState(seed ^ self.lo, self.hi);
    }

    pub fn splitString(self: Splitter, value: []const u8) Xoroshiro {
        return self.splitDigest(std.crypto.hash.Md5.hashResult(value));
    }

    pub fn splitDigest(self: Splitter, digest: [16]u8) Xoroshiro {
        const lo = std.mem.readInt(u64, digest[0..8], .big);
        const hi = std.mem.readInt(u64, digest[8..16], .big);
        return Xoroshiro.initState(lo ^ self.lo, hi ^ self.hi);
    }
};

pub inline fn decoratorSeed(population_seed: u64, index: usize, step: usize) u64 {
    return population_seed +% index +% (10_000 *% step);
}

pub inline fn regionSeed(world_seed: u64, region_x: i32, region_z: i32, salt: i32) u64 {
    return @as(u64, @bitCast(@as(i64, region_x))) *% 341_873_128_712 +%
        @as(u64, @bitCast(@as(i64, region_z))) *% 132_897_987_541 +%
        world_seed +% @as(u64, @bitCast(@as(i64, salt)));
}

pub fn hashBlockPosition(x: i32, y: i32, z: i32) i64 {
    var value = @as(i64, x *% 3_129_871) ^ (@as(i64, z) *% 116_129_781) ^ @as(i64, y);
    value = value *% value *% 42_317_861 +% value *% 11;
    return value >> 16;
}

pub fn staffordMix13(value: u64) u64 {
    var mixed = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    mixed = (mixed ^ (mixed >> 27)) *% 0x94d0_49bb_1331_11eb;
    return mixed ^ (mixed >> 31);
}

test "xoroshiro stream matches Vanilla reference" {
    var random = Xoroshiro.init(0);
    const expected = [_]i32{
        -160_476_802,
        781_697_906,
        653_572_596,
        1_337_520_923,
        -505_875_771,
        -47_281_585,
        342_195_906,
        1_417_498_593,
        -1_478_887_443,
        1_560_080_270,
    };
    for (expected) |value| try std.testing.expectEqual(value, random.nextI32());
}

test "xoroshiro bounded stream matches Vanilla reference" {
    var random = Xoroshiro.init(0);
    const expected = [_]i32{ 9, 1, 1, 3, 8, 9, 0, 3, 6, 3 };
    for (expected) |value| try std.testing.expectEqual(value, random.nextBoundedI32(10));
}

test "chunk random preserves Vanilla BaseRandom sampling semantics" {
    const population = ChunkRandom.populationSeed(0, 7 * 16, 4 * 16);
    try std.testing.expectEqual(@as(u64, 9_737_109_434_949_740_624), population);
    var source = ChunkRandom.init(decoratorSeed(population, 0, 6));
    const expected = [_]i64{
        -6_716_999_907_044_039_100,
        1_367_613_912_288_112_453,
        -9_210_823_514_986_555_481,
        -1_954_082_862_629_492_158,
    };
    for (expected) |value| try std.testing.expectEqual(value, source.nextI64());
}

test "chunk random decorator reseeding preserves the Gaussian cache" {
    var source = ChunkRandom.init(123);
    _ = source.nextGaussian();
    const cached = source.gaussian;
    try std.testing.expect(source.has_gaussian);
    source.reseed(456);
    try std.testing.expect(source.has_gaussian);
    try std.testing.expectEqual(cached, source.nextGaussian());
}

test "block position hashing matches Vanilla reference" {
    try std.testing.expectEqual(@as(i64, 0), hashBlockPosition(0, 0, 0));
    try std.testing.expectEqual(@as(i64, 60_311_958_971_344), hashBlockPosition(1, 1, 1));
    try std.testing.expectEqual(@as(i64, 8_437_923_733_503), hashBlockPosition(-387_008_604, -387_008_604, -387_008_604));
}
