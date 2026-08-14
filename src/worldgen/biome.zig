const std = @import("std");
const climate = @import("climate.zig");
const data = @import("worldgen_data");

pub const Lookup = struct {
    previous_leaf: ?u16 = null,

    pub fn biome(self: *Lookup, sample: climate.QuantizedSample) []const u8 {
        return data.biome_names[self.biomeIndex(sample)];
    }

    pub fn biomeIndex(self: *Lookup, sample: climate.QuantizedSample) u8 {
        const point = [7]i64{
            sample.temperature,
            sample.humidity,
            sample.continentalness,
            sample.erosion,
            sample.depth,
            sample.ridges,
            0,
        };
        const leaf = resultingNode(data.overworld_biome_root, &point, self.previous_leaf);
        self.previous_leaf = leaf;
        return data.biome_nodes[leaf].biome;
    }
};

pub const quart_cells_per_section = 4 * 4 * 4;
pub const overworld_section_count = 24;
pub const overworld_cell_count = quart_cells_per_section * overworld_section_count;

pub const Cache = struct {
    const way_count = 4;
    const set_count = 32;

    const Entry = struct {
        valid: bool = false,
        chunk_x: i32 = 0,
        chunk_z: i32 = 0,
        cells: [overworld_cell_count]u8 = undefined,
    };

    entries: [set_count * way_count]Entry = [_]Entry{.{}} ** (set_count * way_count),
    replacement: [set_count]u2 = [_]u2{0} ** set_count,

    pub fn chunk(
        self: *Cache,
        sampler: *const climate.Sampler,
        chunk_x: i32,
        chunk_z: i32,
    ) *const [overworld_cell_count]u8 {
        const set = cacheSet(chunk_x, chunk_z);
        const first = set * way_count;
        var target = first + self.replacement[set];
        for (self.entries[first..][0..way_count], first..) |*entry, index| {
            if (entry.valid and entry.chunk_x == chunk_x and entry.chunk_z == chunk_z)
                return &entry.cells;
            if (!entry.valid) target = index;
        }
        const entry = &self.entries[target];
        var lookup: Lookup = .{};
        fillOverworldChunk(sampler, &lookup, chunk_x, chunk_z, &entry.cells);
        entry.valid = true;
        entry.chunk_x = chunk_x;
        entry.chunk_z = chunk_z;
        self.replacement[set] +%= 1;
        return &entry.cells;
    }

    pub fn atQuart(
        self: *Cache,
        sampler: *const climate.Sampler,
        quart_x: i32,
        quart_y: i32,
        quart_z: i32,
    ) u8 {
        const first_quart_y = -16;
        const last_quart_y = first_quart_y +
            @as(i32, overworld_section_count * 4);
        if (quart_y < first_quart_y or quart_y >= last_quart_y) {
            var lookup: Lookup = .{};
            return lookup.biomeIndex(
                sampler.sample(quart_x << 2, quart_z << 2)
                    .quantized(quart_y << 2),
            );
        }
        const chunk_x = @divFloor(quart_x, 4);
        const chunk_z = @divFloor(quart_z, 4);
        const local_x: usize = @intCast(@mod(quart_x, 4));
        const local_z: usize = @intCast(@mod(quart_z, 4));
        const vertical: usize = @intCast(quart_y - first_quart_y);
        const section = vertical / 4;
        const local_y = vertical & 3;
        return self.chunk(sampler, chunk_x, chunk_z)[
            section * quart_cells_per_section +
                local_x +
                local_z * 4 +
                local_y * 16
        ];
    }

    fn cacheSet(chunk_x: i32, chunk_z: i32) usize {
        const x: u32 = @bitCast(chunk_x);
        const z: u32 = @bitCast(chunk_z);
        const mixed = x *% 0x9e3779b1 ^ z *% 0x85ebca77;
        return @intCast(mixed & (set_count - 1));
    }
};

pub fn fillOverworldChunk(
    sampler: *const climate.Sampler,
    lookup: *Lookup,
    chunk_x: i32,
    chunk_z: i32,
    output: *[overworld_cell_count]u8,
) void {
    const first_quart_x = chunk_x << 2;
    const first_quart_z = chunk_z << 2;
    var horizontal: [4 * 4]climate.Sample = undefined;
    for (0..4) |local_x| {
        for (0..4) |local_z| {
            const quart_x = first_quart_x + @as(i32, @intCast(local_x));
            const quart_z = first_quart_z + @as(i32, @intCast(local_z));
            horizontal[local_x * 4 + local_z] = sampler.sample(quart_x << 2, quart_z << 2);
        }
    }

    for (0..overworld_section_count) |section| {
        const first_quart_y = -16 + @as(i32, @intCast(section * 4));
        for (0..4) |local_x| {
            for (0..4) |local_y| {
                const block_y = (first_quart_y + @as(i32, @intCast(local_y))) << 2;
                for (0..4) |local_z| {
                    const sample = horizontal[local_x * 4 + local_z].quantized(block_y);
                    const index = section * quart_cells_per_section + local_x + local_z * 4 + local_y * 16;
                    output[index] = lookup.biomeIndex(sample);
                }
            }
        }
    }
}

pub fn name(index: u8) []const u8 {
    return data.biome_names[index];
}

pub fn names() []const []const u8 {
    return &data.biome_names;
}

pub const Climate = struct {
    temperature: f32,
    downfall: f32,
    frozen: bool,
};

pub fn climateFor(index: u8) Climate {
    const value = data.biome_climates[index];
    return .{
        .temperature = value.temperature,
        .downfall = value.downfall,
        .frozen = value.frozen,
    };
}

fn resultingNode(node_index: u16, point: *const [7]i64, previous_leaf: ?u16) u16 {
    const node = data.biome_nodes[node_index];
    if (node.child_len == 0) return node_index;

    var best = previous_leaf;
    var best_distance = if (previous_leaf) |previous|
        distanceSquared(data.biome_nodes[previous].parameters, point)
    else
        std.math.maxInt(i64);
    if (best_distance == 0) return previous_leaf.?;
    const children = data.biome_children[node.child_start..][0..node.child_len];
    for (children) |child| {
        const child_distance = distanceSquared(data.biome_nodes[child].parameters, point);
        if (best_distance <= child_distance) continue;
        const candidate = resultingNode(child, point, best);
        const candidate_distance = if (candidate == child)
            child_distance
        else
            distanceSquared(data.biome_nodes[candidate].parameters, point);
        if (best_distance > candidate_distance) {
            best_distance = candidate_distance;
            best = candidate;
            if (best_distance == 0) return candidate;
        }
    }
    return best orelse unreachable;
}

inline fn distanceSquared(parameters: [7][2]i16, point: *const [7]i64) i64 {
    var result: i64 = 0;
    for (parameters, point) |range, value| {
        const minimum: i64 = range[0];
        const maximum: i64 = range[1];
        const distance = if (value > maximum)
            value - maximum
        else if (value < minimum)
            minimum - value
        else
            0;
        result += distance * distance;
    }
    return result;
}

test "overworld multi-noise lookup matches Vanilla desert reference" {
    var sampler = climate.Sampler.init(13_579);
    var lookup = Lookup{};
    const sample = sampler.sample(-24 << 2, 8 << 2).quantized(1 << 2);
    try std.testing.expectEqualStrings("minecraft:desert", lookup.biome(sample));
}

test "chunk biome population uses Vanilla section and palette order" {
    var sampler = climate.Sampler.init(13_579);
    var lookup = Lookup{};
    var volume: [overworld_cell_count]u8 = undefined;
    fillOverworldChunk(&sampler, &lookup, -6, 2, &volume);
    const section: usize = @intCast(@divFloor(1 - (-16), 4));
    const local_y: usize = @intCast(@mod(1 - (-16), 4));
    const local_x: usize = @intCast(@mod(-24, 4));
    const local_z: usize = @intCast(@mod(8, 4));
    const index = section * quart_cells_per_section + local_x + local_z * 4 + local_y * 16;
    try std.testing.expectEqualStrings("minecraft:desert", name(volume[index]));
}

test "seed zero chunk seven four matches Vanilla biome volume" {
    var sampler = climate.Sampler.init(0);
    var lookup = Lookup{};
    var volume: [overworld_cell_count]u8 = undefined;
    fillOverworldChunk(&sampler, &lookup, 7, 4, &volume);
    for (volume) |biome_index|
        try std.testing.expectEqualStrings("minecraft:beach", name(biome_index));
}

test "seed zero chunk seven three matches Vanilla biome volume" {
    var sampler = climate.Sampler.init(0);
    var lookup = Lookup{};
    var volume: [overworld_cell_count]u8 = undefined;
    fillOverworldChunk(&sampler, &lookup, 7, 3, &volume);
    var forest: usize = 0;
    var beach: usize = 0;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (0..overworld_section_count * 4) |local_y| {
        const section = local_y / 4;
        const section_y = local_y % 4;
        for (0..4) |local_z| {
            for (0..4) |local_x| {
                const index = section * quart_cells_per_section +
                    local_x + local_z * 4 + section_y * 16;
                const biome_name = name(volume[index]);
                if (std.mem.eql(u8, biome_name, "minecraft:forest")) {
                    forest += 1;
                } else if (std.mem.eql(u8, biome_name, "minecraft:beach")) {
                    beach += 1;
                }
                var length: [4]u8 = undefined;
                std.mem.writeInt(u32, &length, @intCast(biome_name.len), .big);
                hash.update(&length);
                hash.update(biome_name);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 864), forest);
    try std.testing.expectEqual(@as(usize, 672), beach);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    try std.testing.expectEqual(
        [32]u8{
            0x33, 0x2d, 0xdd, 0xa4, 0x49, 0x84, 0xd9, 0x33,
            0xea, 0x6a, 0x5f, 0xa8, 0x57, 0x29, 0x04, 0x18,
            0xfa, 0xc4, 0x51, 0xb9, 0x5b, 0x3a, 0xea, 0x61,
            0xd5, 0xc8, 0x2c, 0x8d, 0x46, 0x28, 0xcd, 0xaf,
        },
        digest,
    );
}
