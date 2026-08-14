const std = @import("std");
const config = @import("config.zig").value;
const block_store = @import("world/blocks.zig");
const geometry = @import("world/geometry.zig");
const world_identity = @import("world/identity.zig");
const view = @import("view.zig");
const protocol_versions = @import("protocol_versions.zig");
const protocol_support = @import("protocol_support");
const registry_data = @import("registry_data");
const light_projection = @import("light_projection.zig");
const chunk_palette = @import("chunk_palette.zig");
const terrain = @import("terrain.zig");

pub fn lightPacketCapacity(update: light_projection.Update) usize {
    const arrays =
        @popCount(update.sky_changed_mask) +
        @popCount(update.block_changed_mask);
    return @min(
        config.output_buffer_size - 64,
        256 + @as(usize, arrays) *
            (light_projection.bytes_per_section + 8),
    );
}

const chunk_section_max_len = chunk_palette.maximum_encoded_len + 2;
const chunk_data_max_len =
    config.overworld_section_count * chunk_section_max_len;
pub const chunk_data_count_reserve = 3;
const heightmap_bits = 9;
const heightmap_values_per_long = 64 / heightmap_bits;
const heightmap_long_count =
    std.math.divCeil(usize, 16 * 16, heightmap_values_per_long) catch unreachable;
const light_array_len = light_projection.bytes_per_section;
pub const estimated_chunk_packet_len =
    chunk_data_max_len +
    2 * light_projection.protocol_section_count * (1 + light_array_len) +
    1024;
comptime {
    if (chunk_data_max_len >= @as(usize, 1) << 21)
        @compileError("chunk data length no longer fits the reserved VarInt");
    if (estimated_chunk_packet_len > config.player_write_buffer_size)
        @compileError("player write buffer cannot hold one encoded chunk body");
}

fn writeI64Array(buffer: []u8, values: []const i64) ![]u8 {
    var rest = try protocol_support.write_count(buffer, i32, values.len);
    for (values) |value| rest = try protocol_support.write_i64(rest, value);
    return rest;
}

fn writeLightMask(buffer: []u8, mask: u32) ![]u8 {
    if (mask == 0) return writeI64Array(buffer, &.{});
    return writeI64Array(buffer, &.{@intCast(mask)});
}

pub fn writeChunkLight(
    buffer: []u8,
    lighting: *const light_projection.Chunk,
) ![]u8 {
    const sky_mask = lighting.sky_mask;
    const block_mask = lighting.block_mask;
    const empty_sky = lighting.empty_sky_mask;
    const empty_block = lighting.empty_block_mask;
    var rest = try writeLightMask(buffer, sky_mask);
    rest = try writeLightMask(rest, block_mask);
    rest = try writeLightMask(rest, empty_sky);
    rest = try writeLightMask(rest, empty_block);

    rest = try protocol_support.write_count(rest, i32, @popCount(sky_mask));
    var remaining = sky_mask;
    while (remaining != 0) {
        const section: usize = @intCast(@ctz(remaining));
        remaining &= remaining - 1;
        rest = try protocol_support.write_count(rest, i32, light_array_len);
        if (rest.len < light_array_len) return error.EndOfStream;
        if (lighting.sky[section].bytes()) |bytes|
            @memcpy(rest[0..light_array_len], bytes)
        else
            @memset(rest[0..light_array_len], 0xff);
        rest = rest[light_array_len..];
    }

    rest = try protocol_support.write_count(rest, i32, @popCount(block_mask));
    remaining = block_mask;
    while (remaining != 0) {
        const section: usize = @intCast(@ctz(remaining));
        remaining &= remaining - 1;
        rest = try protocol_support.write_count(rest, i32, light_array_len);
        if (rest.len < light_array_len) return error.EndOfStream;
        if (lighting.block[section].bytes()) |bytes|
            @memcpy(rest[0..light_array_len], bytes)
        else
            @memset(rest[0..light_array_len], 0);
        rest = rest[light_array_len..];
    }
    return rest;
}

fn writeSinglePalette(buffer: []u8, value: i32) ![]u8 {
    var rest = try protocol_support.write_u8(buffer, 0);
    rest = try protocol_support.write_varint(rest, value);
    return rest;
}

fn writeSectionBiomes(
    buffer: []u8,
    shape: *const terrain.ChunkShape,
    section: usize,
) ![]u8 {
    var biomes: [terrain.biome_cells_per_section]u8 = undefined;
    terrain.fillSectionBiomesFromShape(shape, section, &biomes);
    var palette: [8]u8 = undefined;
    var indices: [terrain.biome_cells_per_section]u8 = undefined;
    var palette_len: usize = 0;
    var direct = false;
    for (biomes, 0..) |biome, cell| {
        var index: usize = 0;
        while (index < palette_len and palette[index] != biome) : (index += 1) {}
        if (index == palette_len) {
            if (palette_len == palette.len) {
                direct = true;
                break;
            }
            palette[palette_len] = biome;
            palette_len += 1;
        }
        indices[cell] = @intCast(index);
    }
    if (!direct and palette_len == 1)
        return writeSinglePalette(buffer, palette[0]);
    const bits: u8 = if (direct)
        @intCast(std.math.log2_int_ceil(usize, terrain.biomeNames().len))
    else
        @max(1, std.math.log2_int_ceil(usize, palette_len));
    var rest = try protocol_support.write_u8(buffer, bits);
    if (!direct) {
        rest = try protocol_support.write_count(rest, i32, palette_len);
        for (palette[0..palette_len]) |biome|
            rest = try protocol_support.write_varint(rest, biome);
    }
    const values_per_long = 64 / @as(usize, bits);
    const long_count = std.math.divCeil(
        usize,
        terrain.biome_cells_per_section,
        values_per_long,
    ) catch unreachable;
    for (0..long_count) |long_index| {
        var word: u64 = 0;
        for (0..values_per_long) |entry_index| {
            const cell = long_index * values_per_long + entry_index;
            if (cell == biomes.len) break;
            const value: u64 = if (direct) biomes[cell] else indices[cell];
            word |= value << @intCast(entry_index * bits);
        }
        rest = try protocol_support.write_i64(rest, @bitCast(word));
    }
    return rest;
}

pub fn writeChunkSection(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    player_view: *const view.PlayerView,
    chunk: geometry.ChunkPos,
    section: usize,
    shape: *const terrain.ChunkShape,
    protocol_number: i32,
) ![]u8 {
    if (game_world.findModifiedSection(world, chunk, section) == null and
        !player_view.chunkHasOverlays(chunk))
    {
        if (terrain.uniformSectionBlockStateFromShape(
            shape,
            section,
        )) |uniform| {
            const wire_state = try protocol_versions.staticWireBlockState(
                protocol_number,
                uniform,
            );
            const rest = try chunk_palette.encodeUniform(buffer, wire_state);
            return writeSectionBiomes(rest, shape, section);
        }
    }
    var states: [block_store.blocks_per_section]i32 = undefined;
    if (game_world.findModifiedSection(world, chunk, section)) |section_index|
        game_world.copySectionBlocks(section_index, &states)
    else
        terrain.fillSectionFromShape(shape, section, &states);
    player_view.applySectionOverlays(chunk, section, &states);
    for (&states) |*state|
        state.* = try protocol_versions.staticWireBlockState(
            protocol_number,
            state.*,
        );
    const rest = try chunk_palette.encode(buffer, &states);
    return writeSectionBiomes(rest, shape, section);
}

fn buildHeightmap(
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    shape: *const terrain.ChunkShape,
    packed_values: *[heightmap_long_count]i64,
) void {
    var heights: [16 * 16]u16 = undefined;
    var rescan = [_]bool{false} ** (16 * 16);
    initializeHeightmap(shape, &heights);
    applyHeightmapChanges(game_world, world, chunk, shape, &heights, &rescan);
    rescanHeightmapColumns(game_world, world, chunk, &heights, &rescan);
    packHeightmap(&heights, packed_values);
}

fn initializeHeightmap(shape: *const terrain.ChunkShape, heights: *[16 * 16]u16) void {
    const world_top_y =
        config.world_min_y +
        @as(i16, @intCast(config.overworld_section_count * 16)) - 1;
    for (heights, 0..) |*height, column| {
        const y = @min(
            terrain.highestYFromShape(shape, column & 15, column >> 4),
            world_top_y,
        );
        height.* = if (y < config.world_min_y)
            0
        else
            @intCast(@as(i32, y) - @as(i32, config.world_min_y) + 1);
    }
}

fn applyHeightmapChanges(game_world: *const block_store.Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, shape: *const terrain.ChunkShape, heights: *[16 * 16]u16, rescan: *[16 * 16]bool) void {
    var generated: [block_store.blocks_per_section]i32 = undefined;
    for (0..config.overworld_section_count) |section| {
        const section_index =
            game_world.findModifiedSection(world, chunk, section) orelse continue;
        var blocks: [block_store.blocks_per_section]i32 = undefined;
        game_world.copySectionBlocks(section_index, &blocks);
        terrain.fillSectionFromShape(shape, section, &generated);
        for (&blocks, &generated, 0..) |state, generated_state, local| {
            if (state == generated_state) continue;
            const column = ((local >> 4) & 15) * 16 + (local & 15);
            const height: u16 =
                @intCast(section * 16 + (local >> 8) + 1);
            if (state != registry_data.block_air_default_state)
                heights[column] = @max(heights[column], height)
            else if (heights[column] == height) rescan[column] = true;
        }
    }
}

fn rescanHeightmapColumns(game_world: *const block_store.Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, heights: *[16 * 16]u16, rescan: *const [16 * 16]bool) void {
    for (heights, 0..) |*height, column| {
        if (!rescan[column]) continue;
        const x = chunk.x * 16 + @as(i32, @intCast(column & 15));
        const z = chunk.z * 16 + @as(i32, @intCast(column >> 4));
        var section = config.overworld_section_count;
        height.* = 0;
        outer: while (section != 0) {
            section -= 1;
            var local_y: usize = 16;
            while (local_y != 0) {
                local_y -= 1;
                const y = block_store.sectionWorldY(section, local_y);
                if (game_world.blockAt(world, .{ .x = x, .y = y, .z = z }) !=
                    registry_data.block_air_default_state)
                {
                    height.* = @intCast(
                        @as(i32, y) - @as(i32, config.world_min_y) + 1,
                    );
                    break :outer;
                }
            }
        }
    }
}

fn packHeightmap(heights: *const [16 * 16]u16, packed_values: *[heightmap_long_count]i64) void {
    for (0..heightmap_long_count) |long_index| {
        var word: u64 = 0;
        for (0..heightmap_values_per_long) |entry_index| {
            const index = long_index * heightmap_values_per_long + entry_index;
            if (index >= heights.len) break;
            word |= @as(u64, heights[index]) <<
                @intCast(entry_index * heightmap_bits);
        }
        packed_values[long_index] = @bitCast(word);
    }
}

pub fn writeHeightmaps(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
    shape: *const terrain.ChunkShape,
) ![]u8 {
    var packed_values: [heightmap_long_count]i64 = undefined;
    buildHeightmap(game_world, world, chunk, shape, &packed_values);
    var rest = try protocol_support.write_count(buffer, i32, 2);
    for ([_]i32{ 1, 4 }) |kind| {
        rest = try protocol_support.write_varint(rest, kind);
        rest = try protocol_support.write_count(rest, i32, packed_values.len);
        for (packed_values) |word|
            rest = try protocol_support.write_i64(rest, word);
    }
    return rest;
}

fn blockEntityType(state: i32) ?i32 {
    if (state < 0 or state >= registry_data.block_state_to_block.len)
        return null;
    return switch (registry_data.block_state_to_block[@intCast(state)]) {
        registry_data.block_furnace_id => 0,
        registry_data.block_chest_id => 1,
        else => null,
    };
}

pub fn writeChunkBlockEntities(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
) ![]u8 {
    var count: usize = 0;
    var states: [block_store.blocks_per_section]i32 = undefined;
    for (0..config.overworld_section_count) |section| {
        const index =
            game_world.findModifiedSection(world, chunk, section) orelse continue;
        game_world.copySectionBlocks(index, &states);
        for (states) |state| {
            if (blockEntityType(state) == null) continue;
            count += 1;
        }
    }
    var rest = try protocol_support.write_count(buffer, i32, count);
    for (0..config.overworld_section_count) |section| {
        const index =
            game_world.findModifiedSection(world, chunk, section) orelse continue;
        game_world.copySectionBlocks(index, &states);
        for (states, 0..) |state, local| {
            const entity_type = blockEntityType(state) orelse continue;
            if (rest.len < 1) return error.EndOfStream;
            rest[0] = @as(u8, @intCast(local & 15)) << 4 |
                @as(u8, @intCast((local >> 4) & 15));
            rest = rest[1..];
            rest = try protocol_support.write_i16(
                rest,
                block_store.sectionWorldY(section, local >> 8),
            );
            rest = try protocol_support.write_varint(rest, entity_type);
            rest = try protocol_support.write_u8(rest, 0);
        }
    }
    return rest;
}
