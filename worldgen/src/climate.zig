const std = @import("std");
const noise = @import("noise.zig");
const random = @import("random.zig");
const spline = @import("spline.zig");

pub const Sample = struct {
    temperature: f64,
    humidity: f64,
    continentalness: f64,
    erosion: f64,
    ridges: f64,
    terrain_offset: f64,

    pub fn quantized(self: Sample, block_y: i32) QuantizedSample {
        return .{
            .temperature = quantize(self.temperature),
            .humidity = quantize(self.humidity),
            .continentalness = quantize(self.continentalness),
            .erosion = quantize(self.erosion),
            .depth = self.quantizedDepth(block_y),
            .ridges = quantize(self.ridges),
        };
    }

    pub fn quantizedDepth(self: Sample, block_y: i32) i64 {
        return quantize(self.depth(block_y));
    }

    pub fn depth(self: Sample, block_y: i32) f64 {
        return clampedMap(@floatFromInt(block_y), -64, 320, 1.5, -1.5) -
            0.5037500262260437 + self.terrain_offset;
    }
};

pub const QuantizedSample = struct {
    temperature: i64,
    humidity: i64,
    continentalness: i64,
    erosion: i64,
    depth: i64,
    ridges: i64,
};

pub const Sampler = struct {
    offset: noise.DoublePerlin,
    temperature: noise.DoublePerlin,
    vegetation: noise.DoublePerlin,
    continentalness: noise.DoublePerlin,
    erosion: noise.DoublePerlin,
    ridge: noise.DoublePerlin,

    pub fn init(world_seed: u64) Sampler {
        var base = random.Xoroshiro.init(world_seed);
        const splitter = base.splitter();
        return .{
            .offset = makeNoise(splitter, "minecraft:offset", -3, &.{ 1, 1, 1, 0 }),
            .temperature = makeNoise(splitter, "minecraft:temperature", -10, &.{ 1.5, 0, 1, 0, 0, 0 }),
            .vegetation = makeNoise(splitter, "minecraft:vegetation", -8, &.{ 1, 1, 0, 0, 0, 0 }),
            .continentalness = makeNoise(splitter, "minecraft:continentalness", -9, &.{ 1, 1, 2, 2, 2, 1, 1, 1, 1 }),
            .erosion = makeNoise(splitter, "minecraft:erosion", -9, &.{ 1, 1, 0, 1, 1 }),
            .ridge = makeNoise(splitter, "minecraft:ridge", -7, &.{ 1, 2, 1, 0, 0, 0 }),
        };
    }

    pub fn sample(self: *const Sampler, block_x: i32, block_z: i32) Sample {
        const x: f64 = @floatFromInt(block_x);
        const z: f64 = @floatFromInt(block_z);
        const shift_x = self.offset.sample(x * 0.25, 0, z * 0.25) * 4;
        const shift_z = self.offset.sample(z * 0.25, x * 0.25, 0) * 4;
        const shifted_x = x * 0.25 + shift_x;
        const shifted_z = z * 0.25 + shift_z;
        const continentalness = self.continentalness.sample(shifted_x, 0, shifted_z);
        const erosion = self.erosion.sample(shifted_x, 0, shifted_z);
        const ridges = self.ridge.sample(shifted_x, 0, shifted_z);
        const folded_ridges = -3 * (-1.0 / 3.0 + @abs(-2.0 / 3.0 + @abs(ridges)));
        return .{
            .temperature = self.temperature.sample(shifted_x, 0, shifted_z),
            .humidity = self.vegetation.sample(shifted_x, 0, shifted_z),
            .continentalness = continentalness,
            .erosion = erosion,
            .ridges = ridges,
            .terrain_offset = spline.overworldOffset(.{
                .continents = @floatCast(continentalness),
                .erosion = @floatCast(erosion),
                .ridges_folded = @floatCast(folded_ridges),
            }),
        };
    }
};

fn makeNoise(
    splitter: random.Splitter,
    id: []const u8,
    first_octave: i32,
    amplitudes: []const f64,
) noise.DoublePerlin {
    var source = splitter.splitString(id);
    return .init(&source, first_octave, amplitudes);
}

fn quantize(value: f64) i64 {
    const rounded_to_vanilla_precision: f32 = @floatCast(value);
    return @intFromFloat(rounded_to_vanilla_precision * 10_000);
}

test "overworld climate fields match Vanilla reference" {
    var sampler = Sampler.init(123);
    const point = sampler.sample(123 << 2, 123 << 2).quantized(123 << 2);
    try std.testing.expectEqual(@as(i64, -5727), point.temperature);
    try std.testing.expectEqual(@as(i64, 55), point.humidity);
    try std.testing.expectEqual(@as(i64, 4996), point.continentalness);
    try std.testing.expectEqual(@as(i64, 2371), point.erosion);
    try std.testing.expectEqual(@as(i64, -19774), point.depth);
    try std.testing.expectEqual(@as(i64, 4421), point.ridges);
}

fn clampedMap(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
    if (value <= from) return from_value;
    if (value >= to) return to_value;
    const delta = (value - from) / (to - from);
    return from_value + delta * (to_value - from_value);
}
