const std = @import("std");

pub const Biome = enum {
    nether_wastes,
    crimson_forest,
    soul_sand_valley,
    basalt_deltas,
    warped_forest,
    the_end,
    end_highlands,
    end_midlands,
    small_end_islands,
    end_barrens,

    pub fn canonicalName(self: Biome) []const u8 {
        return switch (self) {
            inline else => |value| "minecraft:" ++ @tagName(value),
        };
    }
};

pub fn Nether(comptime density: type) type {
    return struct {
        pub fn at(router: *density.Router, x: i32, y: i32, z: i32) Biome {
            const position = density.Position{ .x = x, .y = y, .z = z };
            const temperature = quantize(router.sampleTemperature(position));
            const vegetation = quantize(router.sampleVegetation(position));
            const points = [_]struct { biome: Biome, temperature: i64, vegetation: i64, offset: i64 }{
                .{ .biome = .nether_wastes, .temperature = 0, .vegetation = 0, .offset = 0 },
                .{ .biome = .crimson_forest, .temperature = 4_000, .vegetation = 0, .offset = 0 },
                .{ .biome = .soul_sand_valley, .temperature = 0, .vegetation = -5_000, .offset = 0 },
                .{ .biome = .basalt_deltas, .temperature = -5_000, .vegetation = 0, .offset = 1_750 },
                .{ .biome = .warped_forest, .temperature = 0, .vegetation = 5_000, .offset = 3_750 },
            };
            var nearest = points[0].biome;
            var nearest_distance: i64 = std.math.maxInt(i64);
            for (points) |point| {
                const delta_temperature = temperature - point.temperature;
                const delta_vegetation = vegetation - point.vegetation;
                const distance = delta_temperature * delta_temperature +
                    delta_vegetation * delta_vegetation + point.offset * point.offset;
                if (distance < nearest_distance) {
                    nearest = point.biome;
                    nearest_distance = distance;
                }
            }
            return nearest;
        }
    };
}

fn quantize(value: f64) i64 {
    const vanilla_precision: f32 = @floatCast(value);
    return @intFromFloat(vanilla_precision * 10_000);
}

pub fn End(comptime density: type) type {
    return struct {
        pub fn at(router: *density.Router, x: i32, y: i32, z: i32) Biome {
            const section_x = @divFloor(x, 16);
            const section_z = @divFloor(z, 16);
            const section_x_wide: i64 = section_x;
            const section_z_wide: i64 = section_z;
            if (section_x_wide * section_x_wide + section_z_wide * section_z_wide <= 4_096)
                return .the_end;
            const erosion = router.sampleErosion(.{
                .x = (section_x * 2 + 1) * 8,
                .y = y,
                .z = (section_z * 2 + 1) * 8,
            });
            if (erosion > 0.25) return .end_highlands;
            if (erosion >= -0.0625) return .end_midlands;
            if (erosion < -0.21875) return .small_end_islands;
            return .end_barrens;
        }
    };
}
