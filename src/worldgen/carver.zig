const std = @import("std");
const aquifer = @import("aquifer.zig");
const density = @import("density.zig");
const generated_state = @import("generated_state.zig");
const legacy_noise = @import("legacy_noise.zig");
const preallocated = @import("preallocated");
const surface = @import("surface.zig");
const data = @import("carver_data");

const GeneratedState = generated_state.GeneratedState;
const Random = legacy_noise.Random;

pub const width = 16;
pub const minimum_y = density.ChunkInterpolator.minimum_y;
pub const height = density.ChunkInterpolator.height;
pub const block_count = width * width * height;

pub const Scratch = struct {
    fluids: aquifer.Sampler,
    mask: []bool,

    pub fn init(
        allocator: std.mem.Allocator,
        router: *density.Router,
        world_seed: u64,
    ) !Scratch {
        var fluids = try aquifer.Sampler.init(allocator, router, world_seed, 0, 0);
        errdefer fluids.deinit();
        return .{
            .fluids = fluids,
            .mask = try preallocated.alloc(bool, allocator, block_count),
        };
    }

    pub fn deinit(self: *Scratch) void {
        const allocator = self.fluids.allocator;
        allocator.free(self.mask);
        self.fluids.deinit();
        self.* = undefined;
    }
};

pub fn apply(
    allocator: std.mem.Allocator,
    router: *density.Router,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    output: []GeneratedState,
) !void {
    var scratch = try Scratch.init(allocator, router, world_seed);
    defer scratch.deinit();
    applyWithScratch(&scratch, world_seed, chunk_x, chunk_z, output);
}

pub fn applyWithScratch(
    scratch: *Scratch,
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    output: []GeneratedState,
) void {
    std.debug.assert(output.len == block_count);
    scratch.fluids.prepare(chunk_x, chunk_z);
    @memset(scratch.mask, false);

    var source_x = chunk_x - 8;
    while (source_x <= chunk_x + 8) : (source_x += 1) {
        var source_z = chunk_z - 8;
        while (source_z <= chunk_z + 8) : (source_z += 1) {
            const configs = [_]data.Cave{ data.cave, data.cave_extra_underground };
            for (configs, 0..) |config, carver_index| {
                var source = Random.init(0);
                source.setCarverSeed(
                    @bitCast(world_seed +% carver_index),
                    source_x,
                    source_z,
                );
                if (source.nextF32() <= config.probability)
                    carveCaves(
                        config,
                        &source,
                        &scratch.fluids,
                        source_x,
                        source_z,
                        chunk_x,
                        chunk_z,
                        output,
                        scratch.mask,
                    );
            }
            var canyon_source = Random.init(0);
            canyon_source.setCarverSeed(
                @bitCast(world_seed +% 2),
                source_x,
                source_z,
            );
            if (canyon_source.nextF32() <= data.canyon.probability)
                carveCanyon(
                    &canyon_source,
                    &scratch.fluids,
                    source_x,
                    source_z,
                    chunk_x,
                    chunk_z,
                    output,
                    scratch.mask,
                );
        }
    }
}

fn carveCaves(
    config: data.Cave,
    source: *Random,
    fluids: *aquifer.Sampler,
    source_chunk_x: i32,
    source_chunk_z: i32,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
) void {
    const maximum_length = 112;
    const cave_count = source.nextBounded(
        source.nextBounded(source.nextBounded(15) + 1) + 1,
    );
    for (0..cave_count) |_| {
        const x = @as(f64, @floatFromInt(source_chunk_x * 16 +
            @as(i32, @intCast(source.nextBounded(16)))));
        const y = @as(f64, @floatFromInt(uniformHeight(
            source,
            config.minimum_y,
            config.maximum_y,
        )));
        const z = @as(f64, @floatFromInt(source_chunk_z * 16 +
            @as(i32, @intCast(source.nextBounded(16)))));
        const horizontal_multiplier: f64 = uniformF32(
            source,
            config.horizontal_radius.minimum,
            config.horizontal_radius.maximum,
        );
        const vertical_multiplier: f64 = uniformF32(
            source,
            config.vertical_radius.minimum,
            config.vertical_radius.maximum,
        );
        const floor_level: f64 = uniformF32(
            source,
            config.floor_level.minimum,
            config.floor_level.maximum,
        );

        var tunnel_count: u32 = 1;
        if (source.nextBounded(4) == 0) {
            const y_scale: f64 = uniformF32(
                source,
                config.y_scale.minimum,
                config.y_scale.maximum,
            );
            const size = @as(f32, 1) + source.nextF32() * 6;
            _ = carveRegion(
                fluids,
                target_chunk_x,
                target_chunk_z,
                output,
                mask,
                x + 1,
                y,
                z,
                @as(f64, 1.5 + sinF32(@as(f32, std.math.pi) / 2) * size),
                @as(f64, 1.5 + sinF32(@as(f32, std.math.pi) / 2) * size) * y_scale,
                floor_level,
                null,
            );
            tunnel_count += source.nextBounded(4);
        }

        for (0..tunnel_count) |_| {
            const yaw = source.nextF32() * @as(f32, 2 * std.math.pi);
            const pitch = (source.nextF32() - 0.5) / 4;
            const tunnel_width = tunnelSystemWidth(source);
            const length: i32 = maximum_length -
                @as(i32, @intCast(source.nextBounded(maximum_length / 4)));
            carveTunnel(
                source.nextI64(),
                fluids,
                target_chunk_x,
                target_chunk_z,
                output,
                mask,
                .{
                    .x = x,
                    .y = y,
                    .z = z,
                    .horizontal_multiplier = horizontal_multiplier,
                    .vertical_multiplier = vertical_multiplier,
                    .width = tunnel_width,
                    .yaw = yaw,
                    .pitch = pitch,
                    .start = 0,
                    .length = length,
                    .floor = floor_level,
                },
            );
        }
    }
}

const Tunnel = struct {
    x: f64,
    y: f64,
    z: f64,
    horizontal_multiplier: f64,
    vertical_multiplier: f64,
    width: f32,
    yaw: f32,
    pitch: f32,
    start: i32,
    length: i32,
    floor: f64,
};

const TunnelBranch = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    step: i32,
};

fn carveTunnel(
    seed: i64,
    fluids: *aquifer.Sampler,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
    tunnel: Tunnel,
) void {
    var source = Random.init(seed);
    const branch = walkTunnel(
        &source,
        fluids,
        target_chunk_x,
        target_chunk_z,
        output,
        mask,
        tunnel,
        true,
    ) orelse return;
    const child_seed = source.nextI64();
    const child_width = source.nextF32() * 0.5 + 0.5;
    var child = branchTunnel(tunnel, branch, child_width, -@as(f32, std.math.pi) / 2);
    var child_source = Random.init(child_seed);
    _ = walkTunnel(&child_source, fluids, target_chunk_x, target_chunk_z, output, mask, child, false);
    const second_child_seed = source.nextI64();
    child.width = source.nextF32() * 0.5 + 0.5;
    child.yaw = branch.yaw + @as(f32, std.math.pi) / 2;
    child_source = Random.init(second_child_seed);
    _ = walkTunnel(&child_source, fluids, target_chunk_x, target_chunk_z, output, mask, child, false);
}

fn walkTunnel(
    source: *Random,
    fluids: *aquifer.Sampler,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
    tunnel: Tunnel,
    can_branch: bool,
) ?TunnelBranch {
    const branch_step = @as(i32, @intCast(source.nextBounded(
        @intCast(@divTrunc(tunnel.length, 2)),
    ))) + @divTrunc(tunnel.length, 4);
    const gentle_pitch = source.nextBounded(6) == 0;
    var pitch_delta: f32 = 0;
    var yaw_delta: f32 = 0;
    var x = tunnel.x;
    var y = tunnel.y;
    var z = tunnel.z;
    var yaw = tunnel.yaw;
    var pitch = tunnel.pitch;
    var step = tunnel.start;
    while (step < tunnel.length) : (step += 1) {
        const radius = tunnelRadius(step, tunnel.length, tunnel.width);
        const pitch_cos = cosF32(pitch);
        x += @as(f64, cosF32(yaw) * pitch_cos);
        y += @as(f64, sinF32(pitch));
        z += @as(f64, sinF32(yaw) * pitch_cos);
        pitch *= if (gentle_pitch) 0.92 else 0.7;
        pitch += pitch_delta * 0.1;
        yaw += yaw_delta * 0.1;
        pitch_delta *= 0.9;
        yaw_delta *= 0.75;
        pitch_delta += (source.nextF32() - source.nextF32()) * source.nextF32() * 2;
        yaw_delta += (source.nextF32() - source.nextF32()) * source.nextF32() * 4;

        if (can_branch and step == branch_step and tunnel.width > 1)
            return .{ .x = x, .y = y, .z = z, .yaw = yaw, .pitch = pitch, .step = step };
        if (source.nextBounded(4) == 0) continue;
        if (!canCarveBranch(target_chunk_x, target_chunk_z, x, z, step, tunnel.length, tunnel.width)) return null;
        _ = carveRegion(
            fluids,
            target_chunk_x,
            target_chunk_z,
            output,
            mask,
            x,
            y,
            z,
            radius * tunnel.horizontal_multiplier,
            radius * tunnel.vertical_multiplier,
            tunnel.floor,
            null,
        );
    }
    return null;
}

fn branchTunnel(parent: Tunnel, branch: TunnelBranch, child_width: f32, yaw_offset: f32) Tunnel {
    return .{
        .x = branch.x,
        .y = branch.y,
        .z = branch.z,
        .horizontal_multiplier = parent.horizontal_multiplier,
        .vertical_multiplier = parent.vertical_multiplier,
        .width = child_width,
        .yaw = branch.yaw + yaw_offset,
        .pitch = branch.pitch / 3,
        .start = branch.step,
        .length = parent.length,
        .floor = parent.floor,
    };
}

fn tunnelRadius(step: i32, length: i32, width_value: f32) f64 {
    return @as(f64, 1.5 + sinF32(
        @as(f32, std.math.pi) *
            @as(f32, @floatFromInt(step)) /
            @as(f32, @floatFromInt(length)),
    ) * width_value);
}

fn carveCanyon(
    source: *Random,
    fluids: *aquifer.Sampler,
    source_chunk_x: i32,
    source_chunk_z: i32,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
) void {
    const x: f64 = @floatFromInt(source_chunk_x * 16 +
        @as(i32, @intCast(source.nextBounded(16))));
    const y: f64 = @floatFromInt(uniformHeight(
        source,
        data.canyon.minimum_y,
        data.canyon.maximum_y,
    ));
    const z: f64 = @floatFromInt(source_chunk_z * 16 +
        @as(i32, @intCast(source.nextBounded(16))));
    const yaw = source.nextF32() * @as(f32, 6.283_185_5);
    const pitch = uniformF32(
        source,
        data.canyon.vertical_rotation.minimum,
        data.canyon.vertical_rotation.maximum,
    );
    const thickness = trapezoidF32(
        source,
        data.canyon.thickness_minimum,
        data.canyon.thickness_maximum,
        data.canyon.thickness_plateau,
    );
    const length: i32 = @intFromFloat(
        @as(f32, 112) * uniformF32(
            source,
            data.canyon.distance_factor.minimum,
            data.canyon.distance_factor.maximum,
        ),
    );
    carveRavine(
        source.nextI64(),
        fluids,
        target_chunk_x,
        target_chunk_z,
        output,
        mask,
        x,
        y,
        z,
        thickness,
        yaw,
        pitch,
        length,
    );
}

fn carveRavine(
    seed: i64,
    fluids: *aquifer.Sampler,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
    initial_x: f64,
    initial_y: f64,
    initial_z: f64,
    thickness: f32,
    initial_yaw: f32,
    initial_pitch: f32,
    length: i32,
) void {
    var source = Random.init(seed);
    var horizontal_stretch: [height]f32 = undefined;
    var stretch: f32 = 1;
    for (&horizontal_stretch, 0..) |*entry, index| {
        if (index == 0 or source.nextBounded(data.canyon.width_smoothness) == 0)
            stretch = 1 + source.nextF32() * source.nextF32();
        entry.* = stretch * stretch;
    }

    var pitch_delta: f32 = 0;
    var yaw_delta: f32 = 0;
    var x = initial_x;
    var y = initial_y;
    var z = initial_z;
    var yaw = initial_yaw;
    var pitch = initial_pitch;
    var step: i32 = 0;
    while (step < length) : (step += 1) {
        var horizontal_radius = @as(f64, 1.5 + sinF32(
            @as(f32, @floatFromInt(step)) *
                @as(f32, std.math.pi) /
                @as(f32, @floatFromInt(length)),
        ) * thickness);
        var vertical_radius = horizontal_radius * data.canyon.y_scale;
        horizontal_radius *= uniformF32(
            &source,
            data.canyon.horizontal_radius_factor.minimum,
            data.canyon.horizontal_radius_factor.maximum,
        );
        const center_factor = 1 - @abs(
            0.5 - @as(f32, @floatFromInt(step)) /
                @as(f32, @floatFromInt(length)),
        ) * 2;
        const vertical_factor = data.canyon.vertical_radius_default_factor +
            data.canyon.vertical_radius_center_factor * center_factor;
        vertical_radius *= vertical_factor * uniformF32(&source, 0.75, 1);

        const pitch_cos = cosF32(pitch);
        x += @as(f64, cosF32(yaw) * pitch_cos);
        y += @as(f64, sinF32(pitch));
        z += @as(f64, sinF32(yaw) * pitch_cos);
        pitch *= 0.7;
        pitch += pitch_delta * 0.05;
        yaw += yaw_delta * 0.05;
        pitch_delta *= 0.8;
        yaw_delta *= 0.5;
        pitch_delta += (source.nextF32() - source.nextF32()) * source.nextF32() * 2;
        yaw_delta += (source.nextF32() - source.nextF32()) * source.nextF32() * 4;

        if (source.nextBounded(4) == 0) continue;
        if (!canCarveBranch(
            target_chunk_x,
            target_chunk_z,
            x,
            z,
            step,
            length,
            thickness,
        )) return;
        _ = carveRegion(
            fluids,
            target_chunk_x,
            target_chunk_z,
            output,
            mask,
            x,
            y,
            z,
            horizontal_radius,
            vertical_radius,
            0,
            &horizontal_stretch,
        );
    }
}

fn carveRegion(
    fluids: *aquifer.Sampler,
    chunk_x: i32,
    chunk_z: i32,
    output: []GeneratedState,
    mask: []bool,
    center_x: f64,
    center_y: f64,
    center_z: f64,
    horizontal_radius: f64,
    vertical_radius: f64,
    floor_level: f64,
    horizontal_stretch: ?*const [height]f32,
) bool {
    const chunk_center_x: f64 = @floatFromInt(chunk_x * 16 + 8);
    const chunk_center_z: f64 = @floatFromInt(chunk_z * 16 + 8);
    const horizontal_limit = 16 + horizontal_radius * 2;
    if (@abs(center_x - chunk_center_x) > horizontal_limit or
        @abs(center_z - chunk_center_z) > horizontal_limit) return false;

    const first_x = chunk_x * 16;
    const first_z = chunk_z * 16;
    const minimum_x = @max(@as(i32, @intFromFloat(@floor(center_x - horizontal_radius))) -
        first_x - 1, 0);
    const maximum_x = @min(@as(i32, @intFromFloat(@floor(center_x + horizontal_radius))) -
        first_x, 15);
    const minimum_carve_y = @max(
        @as(i32, @intFromFloat(@floor(center_y - vertical_radius))) - 1,
        minimum_y + 1,
    );
    const maximum_carve_y = @min(
        @as(i32, @intFromFloat(@floor(center_y + vertical_radius))) + 1,
        minimum_y + height - 1 - 7,
    );
    const minimum_z = @max(@as(i32, @intFromFloat(@floor(center_z - horizontal_radius))) -
        first_z - 1, 0);
    const maximum_z = @min(@as(i32, @intFromFloat(@floor(center_z + horizontal_radius))) -
        first_z, 15);
    var carved = false;

    var local_x = minimum_x;
    while (local_x <= maximum_x) : (local_x += 1) {
        const x = first_x + local_x;
        const relative_x = (@as(f64, @floatFromInt(x)) + 0.5 - center_x) / horizontal_radius;
        var local_z = minimum_z;
        while (local_z <= maximum_z) : (local_z += 1) {
            const z = first_z + local_z;
            const relative_z = (@as(f64, @floatFromInt(z)) + 0.5 - center_z) / horizontal_radius;
            if (relative_x * relative_x + relative_z * relative_z >= 1) continue;
            var y = maximum_carve_y;
            while (y > minimum_carve_y) : (y -= 1) {
                const relative_y = (@as(f64, @floatFromInt(y)) - 0.5 - center_y) /
                    vertical_radius;
                const excluded = if (horizontal_stretch) |stretch|
                    (relative_x * relative_x + relative_z * relative_z) *
                        @as(f64, stretch[@intCast(y - minimum_y - 1)]) +
                        relative_y * relative_y / 6 >= 1
                else
                    relative_y <= floor_level or
                        relative_x * relative_x + relative_y * relative_y +
                            relative_z * relative_z >= 1;
                if (excluded) continue;
                const index = blockIndex(local_x, y, local_z);
                if (mask[index]) continue;
                mask[index] = true;
                if (!isReplaceable(output[index])) continue;
                const replacement: aquifer.Material = if (y <= minimum_y +
                    data.cave.lava_above_bottom)
                    .lava
                else
                    fluids.material(.{ .x = x, .y = y, .z = z }, 0);
                if (replacement == .stone) continue;
                output[index] = .{ .base = replacement };
                carved = true;
            }
        }
    }
    return carved;
}

fn canCarveBranch(
    chunk_x: i32,
    chunk_z: i32,
    x: f64,
    z: f64,
    step: i32,
    length: i32,
    width_value: f32,
) bool {
    const dx = x - @as(f64, @floatFromInt(chunk_x * 16 + 8));
    const dz = z - @as(f64, @floatFromInt(chunk_z * 16 + 8));
    const remaining: f64 = @floatFromInt(length - step);
    const limit: f64 = width_value + 2 + 16;
    return dx * dx + dz * dz - remaining * remaining <= limit * limit;
}

fn tunnelSystemWidth(source: *Random) f32 {
    var width_value = source.nextF32() * 2 + source.nextF32();
    if (source.nextBounded(10) == 0)
        width_value *= source.nextF32() * source.nextF32() * 3 + 1;
    return width_value;
}

fn uniformHeight(source: *Random, minimum: i32, maximum: i32) i32 {
    return minimum + @as(i32, @intCast(source.nextBounded(
        @intCast(maximum - minimum + 1),
    )));
}

fn uniformF32(source: *Random, minimum: f32, maximum: f32) f32 {
    return minimum + source.nextF32() * (maximum - minimum);
}

fn trapezoidF32(
    source: *Random,
    minimum: f32,
    maximum: f32,
    plateau: f32,
) f32 {
    const span = maximum - minimum;
    const slope = (span - plateau) / 2;
    return minimum + source.nextF32() * (span - slope) + source.nextF32() * slope;
}

fn isReplaceable(state: GeneratedState) bool {
    return switch (state) {
        .base => |material| material == .stone or material == .water,
        .surface => |index| !std.mem.eql(u8, surface.stateName(index), "minecraft:bedrock"),
        .feature => false,
    };
}

fn sinF32(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(
        @as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536),
    ));
}

fn cosF32(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378 + 16_384);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(
        @as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536),
    ));
}

inline fn blockIndex(local_x: i32, y: i32, local_z: i32) usize {
    return @as(usize, @intCast(y - minimum_y)) * width * width +
        @as(usize, @intCast(local_z)) * width +
        @as(usize, @intCast(local_x));
}
