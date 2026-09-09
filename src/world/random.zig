const std = @import("std");

pub const DeterministicRng = struct {
    const multiplier: u64 = 0x5deece66d;
    const addend: u64 = 0xb;
    const mask: u64 = (@as(u64, 1) << 48) - 1;

    seed: u64,
    entropy: u64,

    pub fn init(seed: u64) DeterministicRng {
        return .{ .seed = seed, .entropy = (seed ^ multiplier) & mask };
    }

    fn nextBits(self: *DeterministicRng, comptime bits: u6) u32 {
        self.entropy = (self.entropy *% multiplier +% addend) & mask;
        return @truncate(self.entropy >> (48 - bits));
    }

    pub fn next(self: *DeterministicRng) u64 {
        const high: i64 = @as(i32, @bitCast(self.nextBits(32)));
        const low: i64 = @as(i32, @bitCast(self.nextBits(32)));
        return @bitCast((high << 32) +% low);
    }

    pub fn nextIntBounded(self: *DeterministicRng, bound: u32) u32 {
        std.debug.assert(bound != 0 and bound <= std.math.maxInt(i32));
        const signed_bound: i32 = @intCast(bound);
        if ((bound & (bound - 1)) == 0) {
            const product = @as(i64, signed_bound) * @as(i64, self.nextBits(31));
            return @intCast(product >> 31);
        }
        while (true) {
            const bits: i32 = @intCast(self.nextBits(31));
            const value = @mod(bits, signed_bound);
            if (bits -% value +% (signed_bound -% 1) >= 0) return @intCast(value);
        }
    }

    pub fn nextIntBoundedComptime(self: *DeterministicRng, comptime bound: u32) u32 {
        comptime std.debug.assert(bound != 0 and bound <= std.math.maxInt(i32));
        const signed_bound: i32 = bound;
        if (comptime std.math.isPowerOfTwo(bound)) {
            const product = @as(i64, signed_bound) * @as(i64, self.nextBits(31));
            return @intCast(product >> 31);
        }
        while (true) {
            const bits = self.nextBits(31);
            const value = constantRemainder(bits, bound);
            const acceptance: i32 = @bitCast(bits -% value +% (bound - 1));
            if (acceptance >= 0) return value;
        }
    }

    pub fn discardIntBoundedComptime(self: *DeterministicRng, comptime bound: u32) void {
        comptime std.debug.assert(bound != 0 and bound <= std.math.maxInt(i32));
        if (comptime std.math.isPowerOfTwo(bound)) {
            _ = self.nextBits(31);
            return;
        }
        const range = @as(u64, 1) << 31;
        const acceptance_limit: u32 = @intCast(range - range % bound);
        while (self.nextBits(31) >= acceptance_limit) {}
    }

    fn constantRemainder(value: u32, comptime bound: u32) u32 {
        const quotient: u32 = switch (bound) {
            3 => @intCast((@as(u64, value) * 0xaaaa_aaab) >> 33),
            5 => @intCast((@as(u64, value) * 0xcccc_cccd) >> 34),
            48 => @intCast((@as(u64, value) * 0xaaaa_aaab) >> 37),
            else => return value % bound,
        };
        return value - quotient * bound;
    }

    pub fn nextFloat(self: *DeterministicRng) f32 {
        return @as(f32, @floatFromInt(self.nextBits(24))) / @as(f32, 1 << 24);
    }

    pub fn nextDouble(self: *DeterministicRng) f64 {
        const high = @as(u64, self.nextBits(26)) << 27;
        const low = self.nextBits(27);
        return @as(f64, @floatFromInt(high | low)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    pub fn uuid_for(self: *DeterministicRng, slot: u16) u128 {
        const hi = self.next() ^ (@as(u64, slot) << 32);
        const lo = self.next() ^ self.seed;
        return (@as(u128, hi) << 64) | lo;
    }

    pub fn uuid_for_item(self: *DeterministicRng, index: u16) u128 {
        const hi = self.next() ^ 0x6974_656d_0000_0000 ^ @as(u64, index);
        const lo = self.next() ^ self.seed;
        return (@as(u128, hi) << 64) | lo;
    }

    pub fn uuid_for_living(self: *DeterministicRng, index: u16) u128 {
        const hi = self.next() ^ 0x6c69_7669_6e67_0000 ^ @as(u64, index);
        const lo = self.next() ^ self.seed;
        return (@as(u128, hi) << 64) | lo;
    }
};

pub const Random = struct {
    pub const id = "minecraft:random";
    pub const Configuration = struct { seed: u64 = 0x6d_62_75_6e_64_00_00_01 };

    random: DeterministicRng = DeterministicRng.init(0x6d_62_75_6e_64_00_00_01),

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration) !*Random {
        const self = try allocator.create(Random);
        self.* = .{ .random = DeterministicRng.init(configuration.seed) };
        return self;
    }
};

test "constant bounded random streams match the general implementation" {
    inline for (.{ 3, 5, 48 }) |bound| {
        var specialized = DeterministicRng.init(0x6d_62_75_6e_64);
        var general = specialized;
        for (0..100_000) |_|
            try std.testing.expectEqual(general.nextIntBounded(bound), specialized.nextIntBoundedComptime(bound));
    }
}

test "discarding a bounded random result preserves the stream" {
    inline for (.{ 2, 3, 5, 48 }) |bound| {
        var general = DeterministicRng.init(0x55aa_0123_9876);
        var discarded = general;
        for (0..100_000) |_| {
            _ = general.nextIntBounded(bound);
            discarded.discardIntBoundedComptime(bound);
            try std.testing.expectEqual(general.entropy, discarded.entropy);
        }
    }
}
