const std = @import("std");
const preallocated = @import("preallocated");
const biome_temperature = @import("biome_temperature.zig");
const density = @import("density.zig");
const noise = @import("noise.zig");
const random = @import("random.zig");
const program = @import("surface_program.zig");

const data = program.data;

pub const Context = struct {
    position: density.Position,
    biome_mask: u32,
    run_depth: i32,
    secondary_depth: f64,
    fluid_height: i32,
    stone_depth_above: i32,
    stone_depth_below: i32,
    preliminary_surface: i32,
    cold: bool,
    steep: bool,
};

pub const Result = union(enum) {
    state: u16,
    badlands,
};

pub const Iceberg = struct {
    lower: f64,
    upper: f64,
    source: random.Xoroshiro,
    snow_limit: i32,
    snow_height: i32,
};

pub fn stateName(index: u16) []const u8 {
    return data.block_states[index];
}

pub fn stateCount() usize {
    return data.block_states.len;
}

pub fn biomeMask(name: []const u8) u32 {
    comptime std.debug.assert(data.biome_names.len <= 32);
    for (data.biome_names, 0..) |candidate, index|
        if (std.mem.eql(u8, name, candidate))
            return @as(u32, 1) << @intCast(index);
    return 0;
}

pub const Sampler = struct {
    allocator: std.mem.Allocator,
    base_splitter: random.Splitter,
    noises: []noise.DoublePerlin,
    gradient_splitters: []random.Splitter,
    temperature: biome_temperature.Sampler,
    terracotta_bands: [192]u16,

    pub fn init(allocator: std.mem.Allocator, world_seed: u64) !Sampler {
        const noises = try preallocated.alloc(noise.DoublePerlin, allocator, data.noise_specs.len);
        errdefer allocator.free(noises);
        const gradient_splitters = try preallocated.alloc(random.Splitter, allocator, data.random_names.len);
        errdefer allocator.free(gradient_splitters);
        var base = random.Xoroshiro.init(world_seed);
        const base_splitter = base.splitter();
        for (data.noise_specs, noises) |spec, *sampler| {
            var source = base_splitter.splitString(spec.id);
            const start: usize = spec.amplitude_start;
            sampler.* = .init(
                &source,
                spec.first_octave,
                data.amplitudes[start..][0..spec.amplitude_len],
            );
        }
        for (data.random_names, gradient_splitters) |name, *splitter| {
            var source = base_splitter.splitString(name);
            splitter.* = source.splitter();
        }
        var clay_random = base_splitter.splitString("minecraft:clay_bands");
        return .{
            .allocator = allocator,
            .base_splitter = base_splitter,
            .noises = noises,
            .gradient_splitters = gradient_splitters,
            .temperature = .init(),
            .terracotta_bands = createTerracottaBands(&clay_random),
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.allocator.free(self.gradient_splitters);
        self.allocator.free(self.noises);
        self.* = undefined;
    }

    pub fn reseed(self: *Sampler, world_seed: u64) void {
        var base = random.Xoroshiro.init(world_seed);
        const splitter = base.splitter();
        for (data.noise_specs, self.noises) |spec, *sampler| {
            var source = splitter.splitString(spec.id);
            const start: usize = spec.amplitude_start;
            sampler.* = .init(
                &source,
                spec.first_octave,
                data.amplitudes[start..][0..spec.amplitude_len],
            );
        }
        for (data.random_names, self.gradient_splitters) |name, *gradient| {
            var source = splitter.splitString(name);
            gradient.* = source.splitter();
        }
        var clay_random = splitter.splitString("minecraft:clay_bands");
        self.base_splitter = splitter;
        self.terracotta_bands = createTerracottaBands(&clay_random);
    }

    pub fn runDepth(self: *const Sampler, x: i32, z: i32) i32 {
        var source = self.base_splitter.splitPosition(x, 0, z);
        const value = self.noises[data.surface_noise].sample(
            @floatFromInt(x),
            0,
            @floatFromInt(z),
        ) * 2.75 + 3 + source.nextF64() * 0.25;
        return @intFromFloat(value);
    }

    pub fn secondaryDepth(self: *const Sampler, x: i32, z: i32) f64 {
        return self.noises[data.surface_secondary_noise].sample(
            @floatFromInt(x),
            0,
            @floatFromInt(z),
        );
    }

    pub fn terracottaBlock(self: *const Sampler, x: i32, y: i32, z: i32) u16 {
        const offset: i32 = @intFromFloat(@floor(
            self.noises[data.clay_bands_offset_noise].sample(
                @floatFromInt(x),
                0,
                @floatFromInt(z),
            ) * 4 + 0.5,
        ));
        return self.terracotta_bands[
            @intCast(@mod(
                y + offset,
                @as(i32, @intCast(self.terracotta_bands.len)),
            ))
        ];
    }

    pub fn iceberg(
        self: *const Sampler,
        x: i32,
        z: i32,
        lower_frozen_ocean_surface: bool,
    ) ?Iceberg {
        const surface_height = @min(
            @abs(self.noises[data.iceberg_surface_noise].sample(
                @floatFromInt(x),
                0,
                @floatFromInt(z),
            ) * 8.25),
            self.noises[data.iceberg_pillar_noise].sample(
                @as(f64, @floatFromInt(x)) * 1.28,
                0,
                @as(f64, @floatFromInt(z)) * 1.28,
            ) * 15,
        );
        if (surface_height <= 1.8) return null;
        const roof = @abs(self.noises[data.iceberg_pillar_roof_noise].sample(
            @as(f64, @floatFromInt(x)) * 1.17,
            0,
            @as(f64, @floatFromInt(z)) * 1.17,
        ) * 1.5);
        var height = @min(surface_height * surface_height * 1.2, @ceil(roof * 40) + 14);
        if (lower_frozen_ocean_surface) height -= 2;
        const lower = if (height > 2) 63 - height - 7 else 0;
        const upper = if (height > 2) height + 63 else 0;
        var source = self.base_splitter.splitPosition(x, 0, z);
        const snow_limit = 2 + source.nextBoundedI32(4);
        const snow_height = 63 + 18 + source.nextBoundedI32(10);
        return .{
            .lower = lower,
            .upper = upper,
            .source = source,
            .snow_limit = snow_limit,
            .snow_height = snow_height,
        };
    }

    pub fn lowerFrozenOceanSurface(
        self: *const Sampler,
        base_temperature: f32,
        frozen_modifier: bool,
        x: i32,
        z: i32,
    ) bool {
        return self.temperature.at(base_temperature, frozen_modifier, x, 63, z) > 0.1;
    }

    pub fn badlandsPillarHeight(self: *const Sampler, x: i32, z: i32, current_top: i32) ?i32 {
        const pillar = @min(
            @abs(self.noises[data.badlands_surface_noise].sample(
                @floatFromInt(x),
                0,
                @floatFromInt(z),
            ) * 8.25),
            self.noises[data.badlands_pillar_noise].sample(
                @as(f64, @floatFromInt(x)) * 0.2,
                0,
                @as(f64, @floatFromInt(z)) * 0.2,
            ) * 15,
        );
        if (pillar <= 0) return null;
        const roof = @abs(self.noises[data.badlands_pillar_roof_noise].sample(
            @as(f64, @floatFromInt(x)) * 0.75,
            0,
            @as(f64, @floatFromInt(z)) * 0.75,
        ) * 1.5);
        const target: i32 = @intFromFloat(@floor(
            64 + @min(pillar * pillar * 2.5, @ceil(roof * 50) + 24),
        ));
        return if (current_top <= target) target else null;
    }

    pub inline fn packedIceState() u16 {
        return data.packed_ice;
    }

    pub inline fn snowBlockState() u16 {
        return data.snow_block;
    }

    pub fn apply(self: *const Sampler, context: *const Context) ?Result {
        return self.applyRule(data.root, context);
    }

    pub fn isCold(
        self: *const Sampler,
        base_temperature: f32,
        frozen_modifier: bool,
        position: density.Position,
    ) bool {
        return self.temperature.isCold(
            base_temperature,
            frozen_modifier,
            position.x,
            position.y,
            position.z,
        );
    }

    fn applyRule(self: *const Sampler, rule_index: u16, context: *const Context) ?Result {
        const rule = data.rules[rule_index];
        return switch (rule.tag) {
            .block => .{ .state = rule.a },
            .badlands => .badlands,
            .condition => if (self.condition(rule.a, context))
                self.applyRule(rule.start, context)
            else
                null,
            .sequence => blk: {
                for (data.rule_children[rule.start..][0..rule.len]) |child|
                    if (self.applyRule(child, context)) |result| break :blk result;
                break :blk null;
            },
        };
    }

    fn condition(self: *const Sampler, condition_index: u16, context: *const Context) bool {
        const value = data.conditions[condition_index];
        return switch (value.tag) {
            .biome => blk: {
                for (data.biome_indices[value.start..][0..value.len]) |biome_index|
                    if (context.biome_mask &
                        (@as(u32, 1) << @intCast(biome_index)) != 0)
                        break :blk true;
                break :blk false;
            },
            .noise_threshold => blk: {
                const sample = self.noises[value.a].sample(
                    @floatFromInt(context.position.x),
                    0,
                    @floatFromInt(context.position.z),
                );
                break :blk sample >= value.x and sample <= value.y;
            },
            .vertical_gradient => blk: {
                const lower = anchorY(value.i0, value.i1);
                const upper = anchorY(value.i2, value.i3);
                if (context.position.y <= lower) break :blk true;
                if (context.position.y >= upper) break :blk false;
                const probability = mapF32(
                    @floatFromInt(context.position.y),
                    @floatFromInt(lower),
                    @floatFromInt(upper),
                    1,
                    0,
                );
                var source = self.gradient_splitters[value.a].splitPosition(
                    context.position.x,
                    context.position.y,
                    context.position.z,
                );
                break :blk source.nextF32() < probability;
            },
            .y_above => context.position.y +
                (if (value.i3 != 0) context.stone_depth_above else 0) >=
                anchorY(value.i0, value.i1) + context.run_depth * value.i2,
            .water => context.fluid_height == std.math.minInt(i32) or
                context.position.y + (if (value.i2 != 0) context.stone_depth_above else 0) >=
                    context.fluid_height + value.i0 + context.run_depth * value.i1,
            .temperature => context.cold,
            .steep => context.steep,
            .not => !self.condition(value.a, context),
            .hole => context.run_depth <= 0,
            .above_preliminary_surface => context.position.y >= context.preliminary_surface,
            .stone_depth => blk: {
                const stone_depth = if (value.i3 == 0)
                    context.stone_depth_above
                else
                    context.stone_depth_below;
                const run_depth = if (value.i1 != 0) context.run_depth else 0;
                const secondary_depth: i32 = if (value.i2 == 0)
                    0
                else
                    @intFromFloat(mapF64(
                        context.secondary_depth,
                        -1,
                        1,
                        0,
                        @floatFromInt(value.i2),
                    ));
                break :blk stone_depth <= 1 + value.i0 + run_depth + secondary_depth;
            },
        };
    }
};

fn createTerracottaBands(source: *random.Xoroshiro) [192]u16 {
    var bands: [192]u16 = @splat(data.terracotta);

    var i: usize = 0;
    while (i < bands.len) : (i += 1) {
        i += @intCast(source.nextBoundedI32(5) + 1);
        if (i < bands.len) bands[i] = data.orange_terracotta;
    }

    addTerracottaBands(&bands, source, data.yellow_terracotta, 1);
    addTerracottaBands(&bands, source, data.brown_terracotta, 2);
    addTerracottaBands(&bands, source, data.red_terracotta, 1);

    const white_count = source.nextBoundedI32(7) + 9;
    i = 0;
    var band: i32 = 0;
    while (band < white_count and i < bands.len) : (band += 1) {
        bands[i] = data.white_terracotta;
        if (i > 1 and source.nextBool()) bands[i - 1] = data.light_gray_terracotta;
        if (i + 1 < bands.len and source.nextBool()) bands[i + 1] = data.light_gray_terracotta;
        i += @intCast(source.nextBoundedI32(16) + 4);
    }
    return bands;
}

fn addTerracottaBands(
    bands: *[192]u16,
    source: *random.Xoroshiro,
    state: u16,
    base_width: i32,
) void {
    const count = source.nextBoundedI32(10) + 6;
    var band: i32 = 0;
    while (band < count) : (band += 1) {
        const width: usize = @intCast(base_width + source.nextBoundedI32(3));
        const start: usize = @intCast(source.nextBoundedI32(@intCast(bands.len)));
        @memset(bands[start..@min(start + width, bands.len)], state);
    }
}

fn anchorY(raw_tag: i32, value: i32) i32 {
    return switch (raw_tag) {
        0 => value,
        1 => density.ChunkInterpolator.minimum_y + value,
        2 => density.ChunkInterpolator.minimum_y + density.ChunkInterpolator.height - 1 - value,
        else => unreachable,
    };
}

inline fn mapF32(value: f32, from: f32, to: f32, from_value: f32, to_value: f32) f32 {
    return from_value + (value - from) / (to - from) * (to_value - from_value);
}

inline fn mapF64(value: f64, from: f64, to: f64, from_value: f64, to_value: f64) f64 {
    return from_value + (value - from) / (to - from) * (to_value - from_value);
}

test "surface program applies deterministic bedrock floor" {
    var sampler = try Sampler.init(std.testing.allocator, 0);
    defer sampler.deinit();
    const context: Context = .{
        .position = .{ .x = 0, .y = -64, .z = 0 },
        .biome_mask = biomeMask("minecraft:plains"),
        .run_depth = sampler.runDepth(0, 0),
        .secondary_depth = sampler.secondaryDepth(0, 0),
        .fluid_height = std.math.minInt(i32),
        .stone_depth_above = 1,
        .stone_depth_below = 10,
        .preliminary_surface = 60,
        .cold = false,
        .steep = false,
    };
    const result = sampler.apply(&context).?;
    try std.testing.expectEqualStrings("minecraft:bedrock", stateName(result.state));
}
