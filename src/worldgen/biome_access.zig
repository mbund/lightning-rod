const std = @import("std");
const density = @import("density.zig");

pub fn mixerSeed(world_seed: u64) i64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, world_seed, .little);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &digest, .{});
    return std.mem.readInt(i64, digest[0..8], .little);
}

pub fn quartPosition(seed: i64, block: density.Position) density.Position {
    const offset_x = block.x - 2;
    const offset_y = block.y - 2;
    const offset_z = block.z - 2;
    const quart_x = @divFloor(offset_x, 4);
    const quart_y = @divFloor(offset_y, 4);
    const quart_z = @divFloor(offset_z, 4);
    const x_fraction = @as(f64, @floatFromInt(@mod(offset_x, 4))) * 0.25;
    const y_fraction = @as(f64, @floatFromInt(@mod(offset_y, 4))) * 0.25;
    const z_fraction = @as(f64, @floatFromInt(@mod(offset_z, 4))) * 0.25;

    var best_permutation: u3 = 0;
    var best_score = std.math.inf(f64);
    for (0..8) |raw_permutation| {
        const permutation: u3 = @intCast(raw_permutation);
        const maintain_x = permutation & 4 == 0;
        const maintain_y = permutation & 2 == 0;
        const maintain_z = permutation & 1 == 0;
        const score = permutationScore(
            seed,
            quart_x + @intFromBool(!maintain_x),
            quart_y + @intFromBool(!maintain_y),
            quart_z + @intFromBool(!maintain_z),
            x_fraction - @as(f64, @floatFromInt(@intFromBool(!maintain_x))),
            y_fraction - @as(f64, @floatFromInt(@intFromBool(!maintain_y))),
            z_fraction - @as(f64, @floatFromInt(@intFromBool(!maintain_z))),
        );
        if (best_score > score) {
            best_score = score;
            best_permutation = permutation;
        }
    }
    return .{
        .x = quart_x + @intFromBool(best_permutation & 4 != 0),
        .y = std.math.clamp(
            quart_y + @intFromBool(best_permutation & 2 != 0),
            @divFloor(density.ChunkInterpolator.minimum_y, 4),
            @divFloor(
                density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height,
                4,
            ) - 1,
        ),
        .z = quart_z + @intFromBool(best_permutation & 1 != 0),
    };
}

pub const ChunkCache = struct {
    const horizontal_side = 6;
    const first_quart_y = @divFloor(density.ChunkInterpolator.minimum_y - 2, 4);
    const vertical_side = @divFloor(
        density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height - 1 - 2,
        4,
    ) - first_quart_y + 2;

    first_quart_x: i32 = 0,
    first_quart_z: i32 = 0,
    offsets: [horizontal_side * vertical_side * horizontal_side][3]f64 = undefined,

    pub fn prepare(self: *ChunkCache, seed: i64, chunk_x: i32, chunk_z: i32) void {
        self.first_quart_x = chunk_x * 4 - 1;
        self.first_quart_z = chunk_z * 4 - 1;
        for (0..horizontal_side) |local_x| {
            for (0..vertical_side) |local_y| {
                for (0..horizontal_side) |local_z| {
                    self.offsets[self.index(local_x, local_y, local_z)] = jitter(
                        seed,
                        self.first_quart_x + @as(i32, @intCast(local_x)),
                        first_quart_y + @as(i32, @intCast(local_y)),
                        self.first_quart_z + @as(i32, @intCast(local_z)),
                    );
                }
            }
        }
    }

    pub fn quartPosition(self: *const ChunkCache, block: density.Position) density.Position {
        const offset_x = block.x - 2;
        const offset_y = block.y - 2;
        const offset_z = block.z - 2;
        const quart_x = @divFloor(offset_x, 4);
        const quart_y = @divFloor(offset_y, 4);
        const quart_z = @divFloor(offset_z, 4);
        const x_fraction = @as(f64, @floatFromInt(@mod(offset_x, 4))) * 0.25;
        const y_fraction = @as(f64, @floatFromInt(@mod(offset_y, 4))) * 0.25;
        const z_fraction = @as(f64, @floatFromInt(@mod(offset_z, 4))) * 0.25;
        const local_x: usize = @intCast(quart_x - self.first_quart_x);
        const local_y: usize = @intCast(quart_y - first_quart_y);
        const local_z: usize = @intCast(quart_z - self.first_quart_z);
        std.debug.assert(local_x + 1 < horizontal_side);
        std.debug.assert(local_y + 1 < vertical_side);
        std.debug.assert(local_z + 1 < horizontal_side);

        const F64x8 = @Vector(8, f64);
        const corner_x: F64x8 = .{ 0, 0, 0, 0, 1, 1, 1, 1 };
        const corner_y: F64x8 = .{ 0, 0, 1, 1, 0, 0, 1, 1 };
        const corner_z: F64x8 = .{ 0, 1, 0, 1, 0, 1, 0, 1 };
        var jitter_x: [8]f64 = undefined;
        var jitter_y: [8]f64 = undefined;
        var jitter_z: [8]f64 = undefined;
        inline for (0..8) |permutation| {
            const offset = self.offsets[
                self.index(
                    local_x + @intFromBool(permutation & 4 != 0),
                    local_y + @intFromBool(permutation & 2 != 0),
                    local_z + @intFromBool(permutation & 1 != 0),
                )
            ];
            jitter_x[permutation] = offset[0];
            jitter_y[permutation] = offset[1];
            jitter_z[permutation] = offset[2];
        }
        const dx = @as(F64x8, @splat(x_fraction)) - corner_x +
            @as(F64x8, jitter_x);
        const dy = @as(F64x8, @splat(y_fraction)) - corner_y +
            @as(F64x8, jitter_y);
        const dz = @as(F64x8, @splat(z_fraction)) - corner_z +
            @as(F64x8, jitter_z);
        const score_values: [8]f64 = dx * dx + dy * dy + dz * dz;
        var best_permutation: u3 = 0;
        var best_score = std.math.inf(f64);
        inline for (score_values, 0..) |score, permutation| {
            if (best_score > score) {
                best_score = score;
                best_permutation = @intCast(permutation);
            }
        }
        return .{
            .x = quart_x + @intFromBool(best_permutation & 4 != 0),
            .y = std.math.clamp(
                quart_y + @intFromBool(best_permutation & 2 != 0),
                @divFloor(density.ChunkInterpolator.minimum_y, 4),
                @divFloor(
                    density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height,
                    4,
                ) - 1,
            ),
            .z = quart_z + @intFromBool(best_permutation & 1 != 0),
        };
    }

    inline fn index(
        self: *const ChunkCache,
        local_x: usize,
        local_y: usize,
        local_z: usize,
    ) usize {
        _ = self;
        return (local_y * horizontal_side + local_z) * horizontal_side + local_x;
    }
};

fn jitter(seed: i64, x: i32, y: i32, z: i32) [3]f64 {
    var mixed = saltMix(seed, x);
    mixed = saltMix(mixed, y);
    mixed = saltMix(mixed, z);
    mixed = saltMix(mixed, x);
    mixed = saltMix(mixed, y);
    mixed = saltMix(mixed, z);
    const offset_x = scaleMix(mixed);
    mixed = saltMix(mixed, seed);
    const offset_y = scaleMix(mixed);
    mixed = saltMix(mixed, seed);
    return .{ offset_x, offset_y, scaleMix(mixed) };
}

fn permutationScore(
    seed: i64,
    x: i32,
    y: i32,
    z: i32,
    x_fraction: f64,
    y_fraction: f64,
    z_fraction: f64,
) f64 {
    var mixed = saltMix(seed, x);
    mixed = saltMix(mixed, y);
    mixed = saltMix(mixed, z);
    mixed = saltMix(mixed, x);
    mixed = saltMix(mixed, y);
    mixed = saltMix(mixed, z);
    const offset_x = scaleMix(mixed);
    mixed = saltMix(mixed, seed);
    const offset_y = scaleMix(mixed);
    mixed = saltMix(mixed, seed);
    const offset_z = scaleMix(mixed);
    return square(z_fraction + offset_z) +
        square(y_fraction + offset_y) +
        square(x_fraction + offset_x);
}

fn scaleMix(value: i64) f64 {
    const shifted = value >> 24;
    const remainder = @mod(shifted, 1024);
    return (@as(f64, @floatFromInt(remainder)) / 1024 - 0.5) * 0.9;
}

fn saltMix(seed: i64, salt: i64) i64 {
    return seed *% (seed *% 6_364_136_223_846_793_005 +% 1_442_695_040_888_963_407) +% salt;
}

inline fn square(value: f64) f64 {
    return value * value;
}

test "biome access salt and boundary blend match Vanilla references" {
    try std.testing.expectEqual(@as(i64, 2_937_271_135_939_595_220), saltMix(12_345_678, 12_345_678));
    try std.testing.expectEqual(@as(f64, -0.45), scaleMix(12_345_678));
    try std.testing.expectEqual(
        density.Position{ .x = 31, .y = 30, .z = 30 },
        quartPosition(1_234_567_890, .{ .x = 123, .y = 123, .z = 123 }),
    );
}

test "chunk cache exactly matches direct biome quart selection" {
    const seed = mixerSeed(12_345_678);
    var cache: ChunkCache = undefined;
    cache.prepare(seed, -3, 5);
    for (0..16) |local_x| {
        for (0..density.ChunkInterpolator.height) |local_y| {
            for (0..16) |local_z| {
                const block = density.Position{
                    .x = -3 * 16 + @as(i32, @intCast(local_x)),
                    .y = density.ChunkInterpolator.minimum_y +
                        @as(i32, @intCast(local_y)),
                    .z = 5 * 16 + @as(i32, @intCast(local_z)),
                };
                try std.testing.expectEqual(
                    quartPosition(seed, block),
                    cache.quartPosition(block),
                );
            }
        }
    }
}
