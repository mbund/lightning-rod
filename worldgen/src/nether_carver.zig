const std = @import("std");
const base = @import("base_dimension.zig");
const data = @import("carver_data");
const legacy = @import("legacy_noise.zig");
const surface_data = @import("nether_surface_data");

const Block = base.Block;
const Random = legacy.Random;
const width = 16;

pub const enabled = true;

pub fn apply(
    world_seed: u64,
    chunk_x: i32,
    chunk_z: i32,
    output: []Block,
    mask: []bool,
) void {
    std.debug.assert(output.len == width * width * 128);
    std.debug.assert(mask.len == output.len);
    @memset(mask, false);
    var source_x = chunk_x - 8;
    while (source_x <= chunk_x + 8) : (source_x += 1) {
        var source_z = chunk_z - 8;
        while (source_z <= chunk_z + 8) : (source_z += 1) {
            var source = Random.init(0);
            source.setCarverSeed(@bitCast(world_seed), source_x, source_z);
            if (source.nextF32() > data.nether_cave.probability) continue;
            carveCaves(&source, source_x, source_z, chunk_x, chunk_z, output, mask);
        }
    }
}

fn carveCaves(
    source: *Random,
    source_chunk_x: i32,
    source_chunk_z: i32,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []Block,
    mask: []bool,
) void {
    const first = source.nextBounded(10);
    const second = source.nextBounded(first + 1);
    const cave_count = source.nextBounded(second + 1);
    for (0..cave_count) |_| carveCave(
        source,
        source_chunk_x,
        source_chunk_z,
        target_chunk_x,
        target_chunk_z,
        output,
        mask,
    );
}

fn carveCave(
    source: *Random,
    source_chunk_x: i32,
    source_chunk_z: i32,
    target_chunk_x: i32,
    target_chunk_z: i32,
    output: []Block,
    mask: []bool,
) void {
    const x: f64 = @floatFromInt(source_chunk_x * width + @as(i32, @intCast(source.nextBounded(width))));
    const y: f64 = @floatFromInt(uniformHeight(source, data.nether_cave.minimum_y, data.nether_cave.maximum_y));
    const z: f64 = @floatFromInt(source_chunk_z * width + @as(i32, @intCast(source.nextBounded(width))));
    var tunnels: u32 = 1;
    if (source.nextBounded(4) == 0) {
        const size = @as(f32, 1) + source.nextF32() * 6;
        const radius = @as(f64, 1.5 + sinF32(@as(f32, std.math.pi) / 2) * size);
        carveRegion(target_chunk_x, target_chunk_z, output, mask, x + 1, y, z, radius, radius * 0.5, -0.7);
        tunnels += source.nextBounded(4);
    }
    for (0..tunnels) |_| {
        const tunnel = initialTunnel(source, x, y, z);
        const seed = source.nextI64();
        carveTunnel(seed, target_chunk_x, target_chunk_z, output, mask, tunnel);
    }
}

const Tunnel = struct {
    x: f64,
    y: f64,
    z: f64,
    width_value: f32,
    yaw: f32,
    pitch: f32,
    start: i32,
    length: i32,
    y_scale: f64,
};

const Branch = struct {
    x: f64,
    y: f64,
    z: f64,
    yaw: f32,
    pitch: f32,
    step: i32,
};

fn initialTunnel(source: *Random, x: f64, y: f64, z: f64) Tunnel {
    const maximum_length: u32 = 112;
    const yaw = source.nextF32() * @as(f32, 2 * std.math.pi);
    const pitch = (source.nextF32() - 0.5) / 4;
    const width_value = (source.nextF32() * 2 + source.nextF32()) * 2;
    return .{
        .x = x,
        .y = y,
        .z = z,
        .width_value = width_value,
        .yaw = yaw,
        .pitch = pitch,
        .start = 0,
        .length = @as(i32, maximum_length) - @as(i32, @intCast(source.nextBounded(maximum_length / 4))),
        .y_scale = 5,
    };
}

fn carveTunnel(
    seed: i64,
    chunk_x: i32,
    chunk_z: i32,
    output: []Block,
    mask: []bool,
    tunnel: Tunnel,
) void {
    var source = Random.init(seed);
    const branch = walkTunnel(&source, chunk_x, chunk_z, output, mask, tunnel, true) orelse return;
    const first_seed = source.nextI64();
    const first_width = source.nextF32() * 0.5 + 0.5;
    var child = branchTunnel(tunnel, branch, first_width, -@as(f32, std.math.pi) / 2);
    var child_source = Random.init(first_seed);
    _ = walkTunnel(&child_source, chunk_x, chunk_z, output, mask, child, false);
    const second_seed = source.nextI64();
    child.width_value = source.nextF32() * 0.5 + 0.5;
    child.yaw = branch.yaw + @as(f32, std.math.pi) / 2;
    child_source = Random.init(second_seed);
    _ = walkTunnel(&child_source, chunk_x, chunk_z, output, mask, child, false);
}

fn walkTunnel(
    source: *Random,
    chunk_x: i32,
    chunk_z: i32,
    output: []Block,
    mask: []bool,
    tunnel: Tunnel,
    may_branch: bool,
) ?Branch {
    const branch_step = @as(i32, @intCast(source.nextBounded(@intCast(@divTrunc(tunnel.length, 2))))) + @divTrunc(tunnel.length, 4);
    const gentle_pitch = source.nextBounded(6) == 0;
    var position = [3]f64{ tunnel.x, tunnel.y, tunnel.z };
    var rotation = [2]f32{ tunnel.yaw, tunnel.pitch };
    var delta = [2]f32{ 0, 0 };
    var step = tunnel.start;
    while (step < tunnel.length) : (step += 1) {
        advanceTunnel(source, gentle_pitch, &position, &rotation, &delta);
        if (may_branch and step == branch_step and tunnel.width_value > 1)
            return .{ .x = position[0], .y = position[1], .z = position[2], .yaw = rotation[0], .pitch = rotation[1], .step = step };
        if (source.nextBounded(4) == 0) continue;
        if (!canReach(chunk_x, chunk_z, position[0], position[2], step, tunnel.length, tunnel.width_value)) return null;
        const radius = tunnelRadius(step, tunnel.length, tunnel.width_value);
        carveRegion(chunk_x, chunk_z, output, mask, position[0], position[1], position[2], radius, radius * tunnel.y_scale, -0.7);
    }
    return null;
}

fn advanceTunnel(
    source: *Random,
    gentle_pitch: bool,
    position: *[3]f64,
    rotation: *[2]f32,
    delta: *[2]f32,
) void {
    const pitch_cos = cosF32(rotation[1]);
    position[0] += @as(f64, cosF32(rotation[0]) * pitch_cos);
    position[1] += @as(f64, sinF32(rotation[1]));
    position[2] += @as(f64, sinF32(rotation[0]) * pitch_cos);
    rotation[1] *= if (gentle_pitch) 0.92 else 0.7;
    rotation[1] += delta[0] * 0.1;
    rotation[0] += delta[1] * 0.1;
    delta[0] = delta[0] * 0.9 + (source.nextF32() - source.nextF32()) * source.nextF32() * 2;
    delta[1] = delta[1] * 0.75 + (source.nextF32() - source.nextF32()) * source.nextF32() * 4;
}

fn branchTunnel(parent: Tunnel, branch: Branch, width_value: f32, yaw_offset: f32) Tunnel {
    return .{
        .x = branch.x,
        .y = branch.y,
        .z = branch.z,
        .width_value = width_value,
        .yaw = branch.yaw + yaw_offset,
        .pitch = branch.pitch / 3,
        .start = branch.step,
        .length = parent.length,
        .y_scale = 1,
    };
}

fn carveRegion(
    chunk_x: i32,
    chunk_z: i32,
    output: []Block,
    mask: []bool,
    center_x: f64,
    center_y: f64,
    center_z: f64,
    horizontal_radius: f64,
    vertical_radius: f64,
    floor_level: f64,
) void {
    const bounds = carveBounds(chunk_x, chunk_z, center_x, center_y, center_z, horizontal_radius, vertical_radius) orelse return;
    var local_x = bounds.minimum_x;
    while (local_x <= bounds.maximum_x) : (local_x += 1) {
        const relative_x = (@as(f64, @floatFromInt(chunk_x * width + local_x)) + 0.5 - center_x) / horizontal_radius;
        var local_z = bounds.minimum_z;
        while (local_z <= bounds.maximum_z) : (local_z += 1) {
            const relative_z = (@as(f64, @floatFromInt(chunk_z * width + local_z)) + 0.5 - center_z) / horizontal_radius;
            if (relative_x * relative_x + relative_z * relative_z >= 1) continue;
            carveColumn(output, mask, local_x, local_z, bounds.minimum_y, bounds.maximum_y, center_y, vertical_radius, relative_x, relative_z, floor_level);
        }
    }
}

const Bounds = struct {
    minimum_x: i32,
    maximum_x: i32,
    minimum_y: i32,
    maximum_y: i32,
    minimum_z: i32,
    maximum_z: i32,
};

fn carveBounds(
    chunk_x: i32,
    chunk_z: i32,
    center_x: f64,
    center_y: f64,
    center_z: f64,
    horizontal_radius: f64,
    vertical_radius: f64,
) ?Bounds {
    const middle_x: f64 = @floatFromInt(chunk_x * width + 8);
    const middle_z: f64 = @floatFromInt(chunk_z * width + 8);
    const limit = width + horizontal_radius * 2;
    if (@abs(center_x - middle_x) > limit or @abs(center_z - middle_z) > limit) return null;
    return .{
        .minimum_x = @max(@as(i32, @intFromFloat(@floor(center_x - horizontal_radius))) - chunk_x * width - 1, 0),
        .maximum_x = @min(@as(i32, @intFromFloat(@floor(center_x + horizontal_radius))) - chunk_x * width, 15),
        .minimum_y = @max(@as(i32, @intFromFloat(@floor(center_y - vertical_radius))) - 1, 1),
        .maximum_y = @min(@as(i32, @intFromFloat(@floor(center_y + vertical_radius))) + 1, 120),
        .minimum_z = @max(@as(i32, @intFromFloat(@floor(center_z - horizontal_radius))) - chunk_z * width - 1, 0),
        .maximum_z = @min(@as(i32, @intFromFloat(@floor(center_z + horizontal_radius))) - chunk_z * width, 15),
    };
}

fn carveColumn(
    output: []Block,
    mask: []bool,
    local_x: i32,
    local_z: i32,
    minimum_y: i32,
    maximum_y: i32,
    center_y: f64,
    vertical_radius: f64,
    relative_x: f64,
    relative_z: f64,
    floor_level: f64,
) void {
    var y = maximum_y;
    while (y > minimum_y) : (y -= 1) {
        const relative_y = (@as(f64, @floatFromInt(y)) - 0.5 - center_y) / vertical_radius;
        if (relative_y <= floor_level or relative_x * relative_x + relative_y * relative_y + relative_z * relative_z >= 1) continue;
        const index = blockIndex(local_x, y, local_z);
        if (mask[index]) continue;
        mask[index] = true;
        if (!replaceable(output[index])) continue;
        output[index] = if (y <= 31) .fluid else .cave_air;
    }
}

fn replaceable(block: Block) bool {
    return switch (block) {
        .solid => true,
        .air, .cave_air, .fluid => false,
        .surface => |state| replaceableName(surface_data.block_states[state]),
        .feature => |state| replaceableName(state.canonicalName()),
    };
}

fn replaceableName(name: []const u8) bool {
    const canonical_name = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
    const names = [_][]const u8{
        "minecraft:stone",         "minecraft:granite",           "minecraft:diorite",           "minecraft:andesite",
        "minecraft:tuff",          "minecraft:deepslate",         "minecraft:netherrack",        "minecraft:basalt",
        "minecraft:blackstone",    "minecraft:dirt",              "minecraft:coarse_dirt",       "minecraft:podzol",
        "minecraft:rooted_dirt",   "minecraft:grass_block",       "minecraft:mycelium",          "minecraft:crimson_nylium",
        "minecraft:warped_nylium", "minecraft:nether_wart_block", "minecraft:warped_wart_block", "minecraft:soul_sand",
        "minecraft:soul_soil",
    };
    for (names) |candidate| if (std.mem.eql(u8, canonical_name, candidate)) return true;
    return false;
}

fn canReach(chunk_x: i32, chunk_z: i32, x: f64, z: f64, step: i32, length: i32, width_value: f32) bool {
    const dx = x - @as(f64, @floatFromInt(chunk_x * width + 8));
    const dz = z - @as(f64, @floatFromInt(chunk_z * width + 8));
    const remaining: f64 = @floatFromInt(length - step);
    const limit: f64 = width_value + 2 + width;
    return dx * dx + dz * dz - remaining * remaining <= limit * limit;
}

fn tunnelRadius(step: i32, length: i32, width_value: f32) f64 {
    return @as(f64, 1.5 + sinF32(@as(f32, std.math.pi) * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(length))) * width_value);
}

fn uniformHeight(source: *Random, minimum: i32, maximum: i32) i32 {
    return minimum + @as(i32, @intCast(source.nextBounded(@intCast(maximum - minimum + 1))));
}

fn sinF32(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(@as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536)));
}

fn cosF32(value: f32) f32 {
    const scaled: i32 = @intFromFloat(value * 10_430.378 + 16_384);
    const index: u16 = @truncate(@as(u32, @bitCast(scaled)));
    return @floatCast(@sin(@as(f64, @floatFromInt(index)) * (@as(f64, 2 * std.math.pi) / 65_536)));
}

fn blockIndex(local_x: i32, y: i32, local_z: i32) usize {
    return @as(usize, @intCast(y)) * width * width + @as(usize, @intCast(local_z)) * width + @as(usize, @intCast(local_x));
}
