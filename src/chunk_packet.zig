const std = @import("std");
const limits = @import("world/limits.zig");
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

const chunk_section_max_len = chunk_palette.maximum_encoded_len + 2;
const chunk_data_max_len =
    limits.section_count * chunk_section_max_len;
pub const chunk_data_count_reserve = 3;
const heightmap_bits = 9;
const heightmap_values_per_long = 64 / heightmap_bits;
const heightmap_long_count =
    std.math.divCeil(usize, 16 * 16, heightmap_values_per_long) catch unreachable;
const light_array_len = light_projection.bytes_per_section;
pub const maximum_payload_bytes =
    chunk_data_max_len +
    2 * light_projection.protocol_section_count * (1 + light_array_len) +
    1024;
comptime {
    if (chunk_data_max_len >= @as(usize, 1) << 21)
        @compileError("chunk data length no longer fits the reserved VarInt");
    if (maximum_payload_bytes + 32 > @import("minecraft_session.zig").Codec.max_packet_bytes)
        @compileError("chunk payload exceeds the Sessions projection capacity");
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

fn writeChunkLight(
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
        @intCast(std.math.log2_int_ceil(usize, terrain.biome_registry_count))
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

fn writeChunkSection(
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
        const rest = try writeGeneratedSection(buffer, shape, section, protocol_number);
        return writeSectionBiomes(rest, shape, section);
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

fn writeGeneratedSection(buffer: []u8, shape: *const terrain.ChunkShape, section: usize, protocol_number: i32) ![]u8 {
    const descriptor = shape.sections[section];
    var palette: [chunk_palette.maximum_indirect_palette_entries]i32 = undefined;
    var air_index: ?u16 = null;
    for (palette[0..descriptor.palette_count], 0..) |*wire, index| {
        const state = shape.sectionPaletteState(section, index);
        if (state == registry_data.block_air_default_state) air_index = @intCast(index);
        wire.* = try protocol_versions.staticWireBlockState(protocol_number, state);
    }
    const data_bytes = (@as(usize, descriptor.bits_per_block) * block_store.blocks_per_section + 7) / 8;
    const data = shape.storage[descriptor.data_offset..][0..data_bytes];
    return chunk_palette.encodePacked(
        buffer,
        palette[0..descriptor.palette_count],
        data,
        descriptor.bits_per_block,
        air_index,
    );
}

pub fn writeChunkPayload(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    player_view: *const view.PlayerView,
    chunk: geometry.ChunkPos,
    shape: *const terrain.ChunkShape,
    lighting: *const light_projection.Chunk,
    protocol_number: i32,
) ![]u8 {
    const prefix = try protocol_versions.staticCall(
        "encodeChunkPrefix",
        protocol_number,
        .{ buffer, chunk.x, chunk.z },
    );
    var rest = buffer[prefix.len..];
    rest = try writeHeightmaps(rest, game_world, world, chunk, shape);
    rest = try writeChunkData(rest, game_world, world, player_view, chunk, shape, protocol_number);
    rest = try writeChunkBlockEntities(rest, game_world, world, chunk);
    rest = try writeChunkLight(rest, lighting);
    return buffer[0 .. buffer.len - rest.len];
}

test "generated terrain projects as one complete map-chunk packet" {
    const test_generator = @import("test_support/world_generator.zig");
    const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: test_generator.Generator = .{};
    const blocks = try block_store.Blocks.init(arena.allocator(), .{
        .maximum_resident_chunks = 4,
        .maximum_modified_sections = 4,
    });
    try generator.init(arena.allocator(), 0x5eed_0001);
    generator.bind(blocks);
    const position = geometry.ChunkPos{ .x = 3, .z = -2 };
    const resident = blocks.generatedHeightChunkRef(test_world, position, 1).entry;
    var sky: [light_projection.bytes_per_section]u8 = @splat(0xff);
    var block: [light_projection.bytes_per_section]u8 = @splat(0);
    var light = light_projection.Chunk{
        .chunk_x = position.x,
        .chunk_z = position.z,
        .revision = 1,
        .sky_mask = 1,
        .block_mask = 1,
        .empty_sky_mask = 0,
        .empty_block_mask = 0,
        .sky = @splat(.{}),
        .block = @splat(.{}),
    };
    light.sky[0] = .{ .ptr = &sky };
    light.block[0] = .{ .ptr = &block };
    var player_view = view.PlayerView{};
    var bytes: [maximum_payload_bytes]u8 = undefined;
    const payload = try writeChunkPayload(&bytes, blocks, test_world, &player_view, position, &resident.shape, &light, 772);
    const resident_count = blocks.residentChunkCount();
    var retry_bytes: [maximum_payload_bytes]u8 = undefined;
    const retry = try writeChunkPayload(&retry_bytes, blocks, test_world, &player_view, position, &resident.shape, &light, 772);
    try std.testing.expectEqual(resident_count, blocks.residentChunkCount());
    try std.testing.expectEqualSlices(u8, payload, retry);
    const Protocol = protocol_versions.Protocol(.version_1);
    const packet = try Protocol.play.toClient.read(payload).name();
    switch (packet) {
        .map_chunk => |value| try value.finish(),
        else => return error.UnexpectedPacket,
    }
}

fn writeChunkData(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    player_view: *const view.PlayerView,
    chunk: geometry.ChunkPos,
    shape: *const terrain.ChunkShape,
    protocol_number: i32,
) ![]u8 {
    const reserve = 5;
    if (buffer.len < reserve) return error.EndOfStream;
    var rest = buffer[reserve..];
    for (0..limits.section_count) |section|
        rest = try writeChunkSection(rest, game_world, world, player_view, chunk, section, shape, protocol_number);
    const data_len = buffer.len - reserve - rest.len;
    var encoded: [reserve]u8 = undefined;
    const prefix_rest = try protocol_support.write_varint(&encoded, @intCast(data_len));
    const prefix_len = reserve - prefix_rest.len;
    @memmove(buffer[prefix_len..][0..data_len], buffer[reserve..][0..data_len]);
    @memcpy(buffer[0..prefix_len], encoded[0..prefix_len]);
    return buffer[prefix_len + data_len ..];
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
    const world_top_y = limits.top_y;
    for (heights, 0..) |*height, column| {
        const y = @min(
            terrain.highestYFromShape(shape, column & 15, column >> 4),
            world_top_y,
        );
        height.* = if (y < limits.min_y)
            0
        else
            @intCast(@as(i32, y) - @as(i32, limits.min_y) + 1);
    }
}

fn applyHeightmapChanges(game_world: *const block_store.Blocks, world: world_identity.Handle, chunk: geometry.ChunkPos, shape: *const terrain.ChunkShape, heights: *[16 * 16]u16, rescan: *[16 * 16]bool) void {
    var generated: [block_store.blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
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
        var section = limits.section_count;
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
                        @as(i32, y) - @as(i32, limits.min_y) + 1,
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

fn writeHeightmaps(
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

fn writeChunkBlockEntities(
    buffer: []u8,
    game_world: *const block_store.Blocks,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
) ![]u8 {
    var count: usize = 0;
    var states: [block_store.blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
        const index =
            game_world.findModifiedSection(world, chunk, section) orelse continue;
        game_world.copySectionBlocks(index, &states);
        for (states) |state| {
            if (blockEntityType(state) == null) continue;
            count += 1;
        }
    }
    var rest = try protocol_support.write_count(buffer, i32, count);
    for (0..limits.section_count) |section| {
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
