const std = @import("std");

const gradients = [16][3]f64{
    .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 },
    .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 },
    .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 },
    .{ 1, 1, 0 }, .{ 0, -1, 1 }, .{ -1, 1, 0 }, .{ 0, -1, -1 },
};

pub const Random = struct {
    state: u64,

    pub fn init(seed: i64) Random {
        var result: Random = undefined;
        result.setSeed(seed);
        return result;
    }

    pub fn setSeed(self: *Random, seed: i64) void {
        self.state = (@as(u64, @bitCast(seed)) ^ 0x5deece66d) & ((1 << 48) - 1);
    }

    pub fn next(self: *Random, comptime bits: u6) u32 {
        self.state = (self.state *% 0x5deece66d +% 11) & ((1 << 48) - 1);
        return @truncate(self.state >> (48 - bits));
    }

    pub fn nextBounded(self: *Random, bound: u32) u32 {
        std.debug.assert(bound != 0 and bound <= std.math.maxInt(i32));
        if (bound & (bound - 1) == 0)
            return @intCast((@as(u64, bound) * self.next(31)) >> 31);
        for (0..128) |_| {
            const value = self.next(31);
            const result = value % bound;
            if (@as(u32, @bitCast(value -% result +% (bound - 1))) <= std.math.maxInt(i32))
                return result;
        }
        unreachable;
    }

    pub fn nextBoundedI32(self: *Random, bound: i32) i32 {
        std.debug.assert(bound > 0);
        return @intCast(self.nextBounded(@intCast(bound)));
    }

    pub fn nextF64(self: *Random) f64 {
        const value = (@as(u64, self.next(26)) << 27) + self.next(27);
        return @as(f64, @floatFromInt(value)) * 0x1.0p-53;
    }

    pub fn nextF32(self: *Random) f32 {
        return @as(f32, @floatFromInt(self.next(24))) * 0x1.0p-24;
    }

    pub fn nextBool(self: *Random) bool {
        return self.next(1) != 0;
    }

    pub fn nextI64(self: *Random) i64 {
        const high: i64 = @as(i32, @bitCast(self.next(32)));
        const low: i64 = @as(i32, @bitCast(self.next(32)));
        return (high << 32) +% low;
    }

    pub fn discard(self: *Random, count: usize) void {
        for (0..count) |_| _ = self.next(32);
    }

    pub fn setCarverSeed(self: *Random, world_seed: i64, chunk_x: i32, chunk_z: i32) void {
        self.setSeed(world_seed);
        const x_seed = self.nextI64();
        const z_seed = self.nextI64();
        const mixed = @as(i64, chunk_x) *% x_seed ^
            @as(i64, chunk_z) *% z_seed ^
            world_seed;
        self.setSeed(mixed);
    }
};

pub const Simplex = struct {
    permutation: [256]u8,
    origin_x: f64,
    origin_y: f64,
    origin_z: f64,

    pub fn init(source: *Random) Simplex {
        var result: Simplex = .{
            .permutation = undefined,
            .origin_x = source.nextF64() * 256,
            .origin_y = source.nextF64() * 256,
            .origin_z = source.nextF64() * 256,
        };
        for (&result.permutation, 0..) |*entry, index| entry.* = @intCast(index);
        for (0..256) |index| {
            const offset = source.nextBounded(@intCast(256 - index));
            std.mem.swap(
                u8,
                &result.permutation[index],
                &result.permutation[index + offset],
            );
        }
        return result;
    }

    pub fn sample2(self: *const Simplex, x: f64, y: f64) f64 {
        const sqrt_three: f64 = std.math.sqrt(3.0);
        const skew_factor: f64 = 0.5 * (sqrt_three - 1.0);
        const unskew_factor: f64 = (3.0 - sqrt_three) / 6.0;
        const skew = (x + y) * skew_factor;
        const cell_x: i32 = @intFromFloat(@floor(x + skew));
        const cell_y: i32 = @intFromFloat(@floor(y + skew));
        const unskew = @as(f64, @floatFromInt(cell_x + cell_y)) * unskew_factor;
        const local_x = x - (@as(f64, @floatFromInt(cell_x)) - unskew);
        const local_y = y - (@as(f64, @floatFromInt(cell_y)) - unskew);
        const middle_x: i32 = if (local_x > local_y) 1 else 0;
        const middle_y: i32 = if (local_x > local_y) 0 else 1;
        const x1 = local_x - @as(f64, @floatFromInt(middle_x)) + unskew_factor;
        const y1 = local_y - @as(f64, @floatFromInt(middle_y)) + unskew_factor;
        const x2 = local_x - 1 + 2 * unskew_factor;
        const y2 = local_y - 1 + 2 * unskew_factor;
        const gradient0 = @mod(self.map(cell_x + self.map(cell_y)), 12);
        const gradient1 = @mod(self.map(cell_x + middle_x + self.map(cell_y + middle_y)), 12);
        const gradient2 = @mod(self.map(cell_x + 1 + self.map(cell_y + 1)), 12);
        return 70 * (gradient(gradient0, local_x, local_y, 0, 0.5) +
            gradient(gradient1, x1, y1, 0, 0.5) +
            gradient(gradient2, x2, y2, 0, 0.5));
    }

    fn map(self: *const Simplex, value: i32) i32 {
        const index: u8 = @truncate(@as(u32, @bitCast(value)));
        return self.permutation[index];
    }
};

pub const OctaveSimplex = struct {
    samplers: [3]Simplex = undefined,
    count: u2,
    persistence: f64,

    pub fn init(seed: i64, count: u2) OctaveSimplex {
        std.debug.assert(count == 1 or count == 3);
        var source = Random.init(seed);
        var result: OctaveSimplex = .{
            .count = count,
            .persistence = 1 / (std.math.pow(f64, 2, @floatFromInt(count)) - 1),
        };
        for (result.samplers[0..count]) |*sampler| sampler.* = Simplex.init(&source);
        return result;
    }

    pub fn sample(self: *const OctaveSimplex, x: f64, y: f64) f64 {
        var result: f64 = 0;
        var lacunarity: f64 = 1;
        var persistence = self.persistence;
        for (self.samplers[0..self.count]) |*sampler| {
            result += sampler.sample2(x * lacunarity, y * lacunarity) * persistence;
            lacunarity /= 2;
            persistence *= 2;
        }
        return result;
    }
};

fn gradient(index: i32, x: f64, y: f64, z: f64, radius: f64) f64 {
    var falloff = radius - x * x - y * y - z * z;
    if (falloff < 0) return 0;
    falloff *= falloff;
    const vector = gradients[@intCast(index)];
    return falloff * falloff * (vector[0] * x + vector[1] * y + vector[2] * z);
}

test "legacy random matches java.util.Random" {
    var source = Random.init(0);
    try std.testing.expectEqual(@as(f64, 0.730967787376657), source.nextF64());
    try std.testing.expectEqual(@as(f64, 0.24053641567148587), source.nextF64());
    try std.testing.expectEqual(@as(f64, 0.6374174253501083), source.nextF64());
}

test "legacy random carver seed matches Vanilla" {
    var source = Random.init(0);
    source.setCarverSeed(0, 7, 4);
    try std.testing.expectEqual(@as(f32, 0.757_332_44), source.nextF32());
}
