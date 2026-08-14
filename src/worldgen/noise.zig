const std = @import("std");
const random = @import("random.zig");

const maximum_octaves = 32;
pub const sample_lanes = 8;
pub const Samples = @Vector(sample_lanes, f64);

const gradients = [16][3]f64{
    .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 },
    .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 },
    .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 },
    .{ 1, 1, 0 }, .{ 0, -1, 1 }, .{ -1, 1, 0 }, .{ 0, -1, -1 },
};

pub const Perlin = struct {
    permutation: [256]u8,
    origin: [3]f64,

    pub fn init(source: anytype) Perlin {
        var result = Perlin{
            .permutation = undefined,
            .origin = .{
                source.nextF64() * 256,
                source.nextF64() * 256,
                source.nextF64() * 256,
            },
        };
        for (&result.permutation, 0..) |*entry, index| entry.* = @intCast(index);
        for (0..256) |index| {
            const offset: usize = @intCast(source.nextBoundedI32(@intCast(256 - index)));
            std.mem.swap(u8, &result.permutation[index], &result.permutation[index + offset]);
        }
        return result;
    }

    pub fn sample(self: *const Perlin, x: f64, y: f64, z: f64) f64 {
        return self.sampleScaledY(x, y, z, 0, 0);
    }

    pub fn sample4(self: *const Perlin, x: Samples, y: Samples, z: Samples) Samples {
        @setRuntimeSafety(false);
        const true_x = x + @as(Samples, @splat(self.origin[0]));
        const true_y = y + @as(Samples, @splat(self.origin[1]));
        const true_z = z + @as(Samples, @splat(self.origin[2]));
        const floor_x = @floor(true_x);
        const floor_y = @floor(true_y);
        const floor_z = @floor(true_z);
        return self.sampleCell4(
            @intFromFloat(floor_x),
            @intFromFloat(floor_y),
            @intFromFloat(floor_z),
            true_x - floor_x,
            true_y - floor_y,
            true_z - floor_z,
            true_y - floor_y,
        );
    }

    fn sampleScaledY4(
        self: *const Perlin,
        x: Samples,
        y: Samples,
        z: Samples,
        y_scale: Samples,
        y_max: Samples,
    ) Samples {
        @setRuntimeSafety(false);
        const true_x = x + @as(Samples, @splat(self.origin[0]));
        const true_y = y + @as(Samples, @splat(self.origin[1]));
        const true_z = z + @as(Samples, @splat(self.origin[2]));
        const floor_x = @floor(true_x);
        const floor_y = @floor(true_y);
        const floor_z = @floor(true_z);
        const local_x = true_x - floor_x;
        const local_y = true_y - floor_y;
        const local_z = true_z - floor_z;
        const limited_y = @min(@select(f64, y_max >= @as(Samples, @splat(0)), y_max, local_y), local_y);
        const y_noise = @floor(limited_y / y_scale + @as(Samples, @splat(1.0e-7))) * y_scale;
        return self.sampleCell4(
            @intFromFloat(floor_x),
            @intFromFloat(floor_y),
            @intFromFloat(floor_z),
            local_x,
            local_y - y_noise,
            local_z,
            local_y,
        );
    }

    pub fn sampleScaledY(self: *const Perlin, x: f64, y: f64, z: f64, y_scale: f64, y_max: f64) f64 {
        @setRuntimeSafety(false);
        const true_x = x + self.origin[0];
        const true_y = y + self.origin[1];
        const true_z = z + self.origin[2];
        const floor_x = @floor(true_x);
        const floor_y = @floor(true_y);
        const floor_z = @floor(true_z);
        const local_x = true_x - floor_x;
        const local_y = true_y - floor_y;
        const local_z = true_z - floor_z;
        const y_noise = if (y_scale == 0)
            0
        else
            @floor((@min(if (y_max >= 0) y_max else local_y, local_y) / y_scale) + 1.0e-7) * y_scale;
        return self.sampleCell(
            @intFromFloat(floor_x),
            @intFromFloat(floor_y),
            @intFromFloat(floor_z),
            local_x,
            local_y - y_noise,
            local_z,
            local_y,
        );
    }

    fn sampleCell(
        self: *const Perlin,
        x: i32,
        y: i32,
        z: i32,
        local_x: f64,
        local_y: f64,
        local_z: f64,
        fade_y: f64,
    ) f64 {
        @setRuntimeSafety(false);
        const x0 = self.map(x);
        const x1 = self.map(x + 1);
        const x0y0 = self.map(x0 + y);
        const x0y1 = self.map(x0 + y + 1);
        const x1y0 = self.map(x1 + y);
        const x1y1 = self.map(x1 + y + 1);
        const a = grad(self.map(x0y0 + z), local_x, local_y, local_z);
        const b = grad(self.map(x1y0 + z), local_x - 1, local_y, local_z);
        const c = grad(self.map(x0y1 + z), local_x, local_y - 1, local_z);
        const d = grad(self.map(x1y1 + z), local_x - 1, local_y - 1, local_z);
        const e = grad(self.map(x0y0 + z + 1), local_x, local_y, local_z - 1);
        const f = grad(self.map(x1y0 + z + 1), local_x - 1, local_y, local_z - 1);
        const g = grad(self.map(x0y1 + z + 1), local_x, local_y - 1, local_z - 1);
        const h = grad(self.map(x1y1 + z + 1), local_x - 1, local_y - 1, local_z - 1);
        return lerp3(fade(local_x), fade(fade_y), fade(local_z), a, b, c, d, e, f, g, h);
    }

    fn sampleCell4(
        self: *const Perlin,
        x: @Vector(sample_lanes, i32),
        y: @Vector(sample_lanes, i32),
        z: @Vector(sample_lanes, i32),
        local_x: Samples,
        local_y: Samples,
        local_z: Samples,
        fade_y: Samples,
    ) Samples {
        @setRuntimeSafety(false);
        var a: [sample_lanes]f64 = undefined;
        var b: [sample_lanes]f64 = undefined;
        var c: [sample_lanes]f64 = undefined;
        var d: [sample_lanes]f64 = undefined;
        var e: [sample_lanes]f64 = undefined;
        var f: [sample_lanes]f64 = undefined;
        var g: [sample_lanes]f64 = undefined;
        var h: [sample_lanes]f64 = undefined;
        inline for (0..sample_lanes) |lane| {
            const x0 = self.map(x[lane]);
            const x1 = self.map(x[lane] + 1);
            const x0y0 = self.map(x0 + y[lane]);
            const x0y1 = self.map(x0 + y[lane] + 1);
            const x1y0 = self.map(x1 + y[lane]);
            const x1y1 = self.map(x1 + y[lane] + 1);
            a[lane] = grad(self.map(x0y0 + z[lane]), local_x[lane], local_y[lane], local_z[lane]);
            b[lane] = grad(self.map(x1y0 + z[lane]), local_x[lane] - 1, local_y[lane], local_z[lane]);
            c[lane] = grad(self.map(x0y1 + z[lane]), local_x[lane], local_y[lane] - 1, local_z[lane]);
            d[lane] = grad(self.map(x1y1 + z[lane]), local_x[lane] - 1, local_y[lane] - 1, local_z[lane]);
            e[lane] = grad(self.map(x0y0 + z[lane] + 1), local_x[lane], local_y[lane], local_z[lane] - 1);
            f[lane] = grad(self.map(x1y0 + z[lane] + 1), local_x[lane] - 1, local_y[lane], local_z[lane] - 1);
            g[lane] = grad(self.map(x0y1 + z[lane] + 1), local_x[lane], local_y[lane] - 1, local_z[lane] - 1);
            h[lane] = grad(self.map(x1y1 + z[lane] + 1), local_x[lane] - 1, local_y[lane] - 1, local_z[lane] - 1);
        }
        return lerp34(fade4(local_x), fade4(fade_y), fade4(local_z), a, b, c, d, e, f, g, h);
    }

    inline fn map(self: *const Perlin, value: i32) i32 {
        return self.permutation[@as(u8, @truncate(@as(u32, @bitCast(value))))];
    }
};

const LegacyOctaves = struct {
    sampler: Perlin,
    amplitude: f64,
    persistence: f64,
    lacunarity: f64,

    fn init(source: *@import("legacy_noise.zig").Random, first_octave: i32) LegacyOctaves {
        const splitter_seed = source.nextI64();
        var name_buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "octave_{d}", .{first_octave}) catch
            unreachable;
        const name_hash = javaStringHash(name);
        var octave_source = @import("legacy_noise.zig").Random.init(
            splitter_seed ^ @as(i64, name_hash),
        );
        return .{
            .sampler = Perlin.init(&octave_source),
            .amplitude = 1,
            .persistence = 1,
            .lacunarity = std.math.pow(f64, 2, @floatFromInt(first_octave)),
        };
    }

    fn sample(self: *const LegacyOctaves, x: f64, y: f64, z: f64) f64 {
        return self.amplitude * self.persistence * self.sampler.sample(
            maintainPrecision(x * self.lacunarity),
            maintainPrecision(y * self.lacunarity),
            maintainPrecision(z * self.lacunarity),
        );
    }
};

pub const LegacyDoublePerlin = struct {
    first: LegacyOctaves,
    second: LegacyOctaves,
    amplitude: f64,

    pub fn init(world_seed: i64, first_octave: i32) LegacyDoublePerlin {
        var source = @import("legacy_noise.zig").Random.init(world_seed);
        return .{
            .first = LegacyOctaves.init(&source, first_octave),
            .second = LegacyOctaves.init(&source, first_octave),
            .amplitude = (1.0 / 6.0) / 0.2,
        };
    }

    pub fn sample(self: *const LegacyDoublePerlin, x: f64, y: f64, z: f64) f64 {
        const domain = 1.0181268882175227;
        return (self.first.sample(x, y, z) +
            self.second.sample(x * domain, y * domain, z * domain)) * self.amplitude;
    }
};

fn javaStringHash(value: []const u8) i32 {
    var hash: i32 = 0;
    for (value) |byte| hash = hash *% 31 +% byte;
    return hash;
}

const OctaveEntry = struct {
    sampler: Perlin,
    amplitude: f64,
    persistence: f64,
    lacunarity: f64,
};

const minimum_octave = -32;
const maximum_octave = 32;
const octave_digests = digests: {
    @setEvalBranchQuota(1_000_000);
    var result: [maximum_octave - minimum_octave + 1][16]u8 = undefined;
    for (&result, 0..) |*digest, index| {
        const octave = minimum_octave + @as(i32, @intCast(index));
        digest.* = std.crypto.hash.Md5.hashResult(std.fmt.comptimePrint(
            "octave_{d}",
            .{octave},
        ));
    }
    break :digests result;
};

fn octaveDigest(octave: i32) [16]u8 {
    std.debug.assert(octave >= minimum_octave and octave <= maximum_octave);
    return octave_digests[@intCast(octave - minimum_octave)];
}

pub const Octaves = struct {
    entries: [maximum_octaves]OctaveEntry = undefined,
    len: u8 = 0,
    maximum: f64 = 0,

    pub fn init(source: *random.Xoroshiro, first_octave: i32, amplitudes: []const f64) Octaves {
        std.debug.assert(amplitudes.len <= maximum_octaves);
        var result = Octaves{};
        const splitter = source.splitter();
        var persistence = std.math.pow(f64, 2, @floatFromInt(amplitudes.len - 1)) /
            (std.math.pow(f64, 2, @floatFromInt(amplitudes.len)) - 1);
        var lacunarity = std.math.pow(f64, 2, @floatFromInt(first_octave));
        for (amplitudes, 0..) |amplitude, index| {
            if (amplitude != 0) {
                const octave = first_octave + @as(i32, @intCast(index));
                var octave_random = splitter.splitDigest(octaveDigest(octave));
                result.entries[result.len] = .{
                    .sampler = Perlin.init(&octave_random),
                    .amplitude = amplitude,
                    .persistence = persistence,
                    .lacunarity = lacunarity,
                };
                result.len += 1;
                result.maximum += 2 * amplitude * persistence;
            }
            persistence *= 0.5;
            lacunarity *= 2;
        }
        return result;
    }

    pub fn sample(self: *const Octaves, x: f64, y: f64, z: f64) f64 {
        var result: f64 = 0;
        for (self.entries[0..self.len]) |*entry| {
            result += entry.amplitude * entry.persistence * entry.sampler.sample(
                maintainPrecision(x * entry.lacunarity),
                maintainPrecision(y * entry.lacunarity),
                maintainPrecision(z * entry.lacunarity),
            );
        }
        return result;
    }

    pub fn sample4(self: *const Octaves, x: Samples, y: Samples, z: Samples) Samples {
        var result: Samples = @splat(0);
        for (self.entries[0..self.len]) |*entry| {
            const lacunarity: Samples = @splat(entry.lacunarity);
            const sampled = entry.sampler.sample4(
                maintainPrecision4(x * lacunarity),
                maintainPrecision4(y * lacunarity),
                maintainPrecision4(z * lacunarity),
            );
            result += @as(Samples, @splat(entry.amplitude * entry.persistence)) * sampled;
        }
        return result;
    }
};

pub const DoublePerlin = struct {
    first: Octaves,
    second: Octaves,
    amplitude: f64,
    maximum: f64,

    pub fn init(source: *random.Xoroshiro, first_octave: i32, amplitudes: []const f64) DoublePerlin {
        const first = Octaves.init(source, first_octave, amplitudes);
        const second = Octaves.init(source, first_octave, amplitudes);
        var first_nonzero: usize = amplitudes.len;
        var last_nonzero: usize = 0;
        for (amplitudes, 0..) |amplitude, index| {
            if (amplitude == 0) continue;
            first_nonzero = @min(first_nonzero, index);
            last_nonzero = index;
        }
        std.debug.assert(first_nonzero != amplitudes.len);
        const span: f64 = @floatFromInt(last_nonzero - first_nonzero + 1);
        const amplitude = (1.0 / 6.0) / (0.1 * (1 + 1 / span));
        return .{
            .first = first,
            .second = second,
            .amplitude = amplitude,
            .maximum = (first.maximum + second.maximum) * amplitude,
        };
    }

    pub fn sample(self: *const DoublePerlin, x: f64, y: f64, z: f64) f64 {
        const domain = 1.0181268882175227;
        return (self.first.sample(x, y, z) + self.second.sample(x * domain, y * domain, z * domain)) * self.amplitude;
    }

    pub fn sample4(self: *const DoublePerlin, x: Samples, y: Samples, z: Samples) Samples {
        const domain: Samples = @splat(1.0181268882175227);
        return (self.first.sample4(x, y, z) + self.second.sample4(x * domain, y * domain, z * domain)) *
            @as(Samples, @splat(self.amplitude));
    }
};

pub const Interpolated = struct {
    lower: [16]Perlin,
    upper: [16]Perlin,
    interpolation: [8]Perlin,
    scaled_xz_scale: f64,
    scaled_y_scale: f64,
    xz_factor: f64,
    y_factor: f64,
    smear_scale_multiplier: f64,

    pub fn init(
        source: *random.Xoroshiro,
        xz_scale: f64,
        y_scale: f64,
        xz_factor: f64,
        y_factor: f64,
        smear_scale_multiplier: f64,
    ) Interpolated {
        var result: Interpolated = .{
            .lower = undefined,
            .upper = undefined,
            .interpolation = undefined,
            .scaled_xz_scale = 684.412 * xz_scale,
            .scaled_y_scale = 684.412 * y_scale,
            .xz_factor = xz_factor,
            .y_factor = y_factor,
            .smear_scale_multiplier = smear_scale_multiplier,
        };
        initLegacyOctaves(16, &result.lower, source);
        initLegacyOctaves(16, &result.upper, source);
        initLegacyOctaves(8, &result.interpolation, source);
        return result;
    }

    pub fn sample(self: *const Interpolated, block_x: i32, block_y: i32, block_z: i32) f64 {
        const x: f64 = @floatFromInt(block_x);
        const y: f64 = @floatFromInt(block_y);
        const z: f64 = @floatFromInt(block_z);
        const scaled_x = x * self.scaled_xz_scale;
        const scaled_y = y * self.scaled_y_scale;
        const scaled_z = z * self.scaled_xz_scale;
        const interpolation_x = scaled_x / self.xz_factor;
        const interpolation_y = scaled_y / self.y_factor;
        const interpolation_z = scaled_z / self.xz_factor;
        const smeared_y = self.scaled_y_scale * self.smear_scale_multiplier;
        const interpolation_smear = smeared_y / self.y_factor;

        var interpolation_sum: f64 = 0;
        var fraction: f64 = 1;
        var octave = self.interpolation.len;
        while (octave > 0) {
            octave -= 1;
            interpolation_sum += self.interpolation[octave].sampleScaledY(
                maintainPrecision(interpolation_x * fraction),
                maintainPrecision(interpolation_y * fraction),
                maintainPrecision(interpolation_z * fraction),
                interpolation_smear * fraction,
                interpolation_y * fraction,
            ) / fraction;
            fraction *= 0.5;
        }

        const blend = (interpolation_sum / 10 + 1) / 2;
        const lower = if (blend < 1)
            sampleLegacyOctaves(&self.lower, scaled_x, scaled_y, scaled_z, smeared_y)
        else
            0;
        const upper = if (blend > 0)
            sampleLegacyOctaves(&self.upper, scaled_x, scaled_y, scaled_z, smeared_y)
        else
            0;
        return clampedLerp(lower / 512, upper / 512, blend) / 128;
    }

    pub fn sample4(self: *const Interpolated, positions: [sample_lanes][3]i32) Samples {
        var x_values: [sample_lanes]f64 = undefined;
        var y_values: [sample_lanes]f64 = undefined;
        var z_values: [sample_lanes]f64 = undefined;
        inline for (0..sample_lanes) |lane| {
            x_values[lane] = @floatFromInt(positions[lane][0]);
            y_values[lane] = @floatFromInt(positions[lane][1]);
            z_values[lane] = @floatFromInt(positions[lane][2]);
        }
        const x: Samples = x_values;
        const y: Samples = y_values;
        const z: Samples = z_values;
        const scaled_x = x * @as(Samples, @splat(self.scaled_xz_scale));
        const scaled_y = y * @as(Samples, @splat(self.scaled_y_scale));
        const scaled_z = z * @as(Samples, @splat(self.scaled_xz_scale));
        const interpolation_x = scaled_x / @as(Samples, @splat(self.xz_factor));
        const interpolation_y = scaled_y / @as(Samples, @splat(self.y_factor));
        const interpolation_z = scaled_z / @as(Samples, @splat(self.xz_factor));
        const smeared_y = self.scaled_y_scale * self.smear_scale_multiplier;
        const interpolation_smear = smeared_y / self.y_factor;

        var interpolation_sum: Samples = @splat(0);
        var fraction: f64 = 1;
        var octave = self.interpolation.len;
        while (octave > 0) {
            octave -= 1;
            const fraction_vector: Samples = @splat(fraction);
            interpolation_sum += self.interpolation[octave].sampleScaledY4(
                maintainPrecision4(interpolation_x * fraction_vector),
                maintainPrecision4(interpolation_y * fraction_vector),
                maintainPrecision4(interpolation_z * fraction_vector),
                @splat(interpolation_smear * fraction),
                interpolation_y * fraction_vector,
            ) / fraction_vector;
            fraction *= 0.5;
        }

        const blend = (interpolation_sum / @as(Samples, @splat(10)) + @as(Samples, @splat(1))) /
            @as(Samples, @splat(2));
        const lower = sampleLegacyOctaves4(&self.lower, scaled_x, scaled_y, scaled_z, smeared_y);
        const upper = sampleLegacyOctaves4(&self.upper, scaled_x, scaled_y, scaled_z, smeared_y);
        return clampedLerp4(
            lower / @as(Samples, @splat(512)),
            upper / @as(Samples, @splat(512)),
            blend,
        ) / @as(Samples, @splat(128));
    }
};

fn initLegacyOctaves(
    comptime count: usize,
    destination: *[count]Perlin,
    source: *random.Xoroshiro,
) void {
    var index = count;
    while (index > 0) {
        index -= 1;
        destination[index] = Perlin.init(source);
    }
}

fn sampleLegacyOctaves(
    samplers: *const [16]Perlin,
    x: f64,
    y: f64,
    z: f64,
    y_scale: f64,
) f64 {
    var sum: f64 = 0;
    var fraction: f64 = 1;
    var octave = samplers.len;
    while (octave > 0) {
        octave -= 1;
        sum += samplers[octave].sampleScaledY(
            maintainPrecision(x * fraction),
            maintainPrecision(y * fraction),
            maintainPrecision(z * fraction),
            y_scale * fraction,
            y * fraction,
        ) / fraction;
        fraction *= 0.5;
    }
    return sum;
}

fn sampleLegacyOctaves4(
    samplers: *const [16]Perlin,
    x: Samples,
    y: Samples,
    z: Samples,
    y_scale: f64,
) Samples {
    var sum: Samples = @splat(0);
    var fraction: f64 = 1;
    var octave = samplers.len;
    while (octave > 0) {
        octave -= 1;
        const fraction_vector: Samples = @splat(fraction);
        sum += samplers[octave].sampleScaledY4(
            maintainPrecision4(x * fraction_vector),
            maintainPrecision4(y * fraction_vector),
            maintainPrecision4(z * fraction_vector),
            @splat(y_scale * fraction),
            y * fraction_vector,
        ) / fraction_vector;
        fraction *= 0.5;
    }
    return sum;
}

pub inline fn maintainPrecision(value: f64) f64 {
    return value - @floor(value / 33_554_432 + 0.5) * 33_554_432;
}

fn maintainPrecision4(value: Samples) Samples {
    var result: [sample_lanes]f64 = undefined;
    inline for (0..sample_lanes) |lane| result[lane] = maintainPrecision(value[lane]);
    return result;
}

inline fn grad(hash: i32, x: f64, y: f64, z: f64) f64 {
    const gradient = gradients[@intCast(hash & 15)];
    return gradient[0] * x + gradient[1] * y + gradient[2] * z;
}

inline fn fade(value: f64) f64 {
    return value * value * value * (value * (value * 6 - 15) + 10);
}

inline fn lerp(delta: f64, start: f64, end: f64) f64 {
    return start + delta * (end - start);
}

inline fn clampedLerp(start: f64, end: f64, delta: f64) f64 {
    if (delta < 0) return start;
    if (delta > 1) return end;
    return lerp(delta, start, end);
}

inline fn clampedLerp4(start: Samples, end: Samples, delta: Samples) Samples {
    return @select(
        f64,
        delta < @as(Samples, @splat(0)),
        start,
        @select(
            f64,
            delta > @as(Samples, @splat(1)),
            end,
            start + delta * (end - start),
        ),
    );
}

inline fn lerp3(
    x: f64,
    y: f64,
    z: f64,
    x0y0z0: f64,
    x1y0z0: f64,
    x0y1z0: f64,
    x1y1z0: f64,
    x0y0z1: f64,
    x1y0z1: f64,
    x0y1z1: f64,
    x1y1z1: f64,
) f64 {
    return lerp(z, lerp(y, lerp(x, x0y0z0, x1y0z0), lerp(x, x0y1z0, x1y1z0)), lerp(y, lerp(x, x0y0z1, x1y0z1), lerp(x, x0y1z1, x1y1z1)));
}

inline fn fade4(value: Samples) Samples {
    return value * value * value *
        (value * (value * @as(Samples, @splat(6)) - @as(Samples, @splat(15))) + @as(Samples, @splat(10)));
}

inline fn lerp4(delta: Samples, start: Samples, end: Samples) Samples {
    return start + delta * (end - start);
}

inline fn lerp34(
    x: Samples,
    y: Samples,
    z: Samples,
    x0y0z0: Samples,
    x1y0z0: Samples,
    x0y1z0: Samples,
    x1y1z0: Samples,
    x0y0z1: Samples,
    x1y0z1: Samples,
    x0y1z1: Samples,
    x1y1z1: Samples,
) Samples {
    return lerp4(
        z,
        lerp4(y, lerp4(x, x0y0z0, x1y0z0), lerp4(x, x0y1z0, x1y1z0)),
        lerp4(y, lerp4(x, x0y0z1, x1y0z1), lerp4(x, x0y1z1, x1y1z1)),
    );
}

test "Perlin construction and samples match Vanilla reference" {
    var source = random.Xoroshiro.init(111);
    try std.testing.expectEqual(@as(i32, -1_467_508_761), source.nextI32());
    const sampler = Perlin.init(&source);
    try std.testing.expectEqual(@as(f64, 48.58072036717974), sampler.origin[0]);
    try std.testing.expectEqual(@as(f64, 110.73235882678037), sampler.origin[1]);
    try std.testing.expectEqual(@as(f64, 65.26438852860176), sampler.origin[2]);
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.38582139614602945),
        sampler.sample(-3.134738528791615e8, 5.676610095659718e7, 2.011711832498507e8),
        1.0e-15,
    );
}

test "double Perlin xoroshiro sample matches Vanilla reference" {
    var source = random.Xoroshiro.init(5);
    try std.testing.expectEqual(@as(i32, -1_678_727_252), source.nextI32());
    var sampler = DoublePerlin.init(&source, 1, &.{ 2, 4 });
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.09627881756376819),
        sampler.sample(-2.4823401687190732e8, 1.6909869132832196e8, 1.0510057123823991e8),
        1.0e-15,
    );
}

test "legacy double Perlin geode sampler matches Vanilla reference" {
    const sampler = LegacyDoublePerlin.init(0, -4);
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.23329982955277573),
        sampler.sample(-491, -9, -499),
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.6284375015501312),
        sampler.sample(0, 0, 0),
        1.0e-15,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, -0.025207154826088065),
        sampler.sample(17, -23, 41),
        1.0e-15,
    );
}
