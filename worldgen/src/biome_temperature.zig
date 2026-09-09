const legacy_noise = @import("legacy_noise.zig");

pub const Sampler = struct {
    temperature: legacy_noise.OctaveSimplex,
    frozen_ocean: legacy_noise.OctaveSimplex,
    foliage: legacy_noise.OctaveSimplex,

    pub fn init() Sampler {
        return .{
            .temperature = .init(1234, 1),
            .frozen_ocean = .init(3456, 3),
            .foliage = .init(2345, 1),
        };
    }

    pub fn isCold(
        self: *const Sampler,
        base_temperature: f32,
        frozen_modifier: bool,
        x: i32,
        y: i32,
        z: i32,
    ) bool {
        return self.at(base_temperature, frozen_modifier, x, y, z) < 0.15;
    }

    pub fn at(
        self: *const Sampler,
        base_temperature: f32,
        frozen_modifier: bool,
        x: i32,
        y: i32,
        z: i32,
    ) f32 {
        var result = if (frozen_modifier)
            self.frozenTemperature(base_temperature, x, z)
        else
            base_temperature;
        const sea_level_with_offset: i32 = 63 + 17;
        if (y > sea_level_with_offset) {
            const sample_x: f64 = @floatCast(@as(f32, @floatFromInt(x)) / 8);
            const sample_z: f64 = @floatCast(@as(f32, @floatFromInt(z)) / 8);
            const altitude_noise: f32 = @floatCast(self.temperature.sample(sample_x, sample_z) * 8);
            result -= (altitude_noise +
                @as(f32, @floatFromInt(y)) -
                @as(f32, @floatFromInt(sea_level_with_offset))) * 0.05 / 40;
        }
        return result;
    }

    fn frozenTemperature(self: *const Sampler, base: f32, x: i32, z: i32) f32 {
        const first = self.frozen_ocean.sample(
            @as(f64, @floatFromInt(x)) * 0.05,
            @as(f64, @floatFromInt(z)) * 0.05,
        ) * 7;
        const second = self.foliage.sample(
            @as(f64, @floatFromInt(x)) * 0.2,
            @as(f64, @floatFromInt(z)) * 0.2,
        );
        if (first + second < 0.3 and self.foliage.sample(
            @as(f64, @floatFromInt(x)) * 0.09,
            @as(f64, @floatFromInt(z)) * 0.09,
        ) < 0.8) return 0.2;
        return base;
    }
};

test "temperature altitude adjustment is inactive below y eighty" {
    const sampler = Sampler.init();
    try @import("std").testing.expectEqual(@as(f32, 0.8), sampler.at(0.8, false, 10, 80, -20));
}
