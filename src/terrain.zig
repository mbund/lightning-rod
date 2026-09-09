const std = @import("std");
const limits = @import("world/limits.zig");
const registry = @import("registry_data");
const game_data = @import("game_data.zig");

pub const blocks_per_section = 16 * 16 * 16;
pub const chunk_storage_capacity = 64 * 1024;
pub const biome_registry_count = registry.biome_names.len;
pub const biome_cells_per_section = 4 * 4 * 4;
pub const biome_cells_per_chunk = limits.section_count * biome_cells_per_section;
pub const random_tick_mask_words = blocks_per_section / 64;
pub const maximum_generated_y: i16 = limits.top_y;

pub const SectionVisibility = enum(u2) {
    transparent,
    solid,
    mixed,
};

pub const SectionShape = struct {
    palette_offset: u32 = 0,
    data_offset: u32 = 0,
    palette_count: u16 = 0,
    bits_per_block: u4 = 0,
};

pub const ChunkShape = struct {
    chunk_x: i32,
    chunk_z: i32,
    heights: [16 * 16]i16,
    grass_spread_possible: bool = false,
    sections: [limits.section_count]SectionShape =
        [_]SectionShape{.{}} ** limits.section_count,
    section_visibility: [limits.section_count]SectionVisibility =
        [_]SectionVisibility{.mixed} ** limits.section_count,
    storage_len: u32 = 0,
    storage: []u8 = &.{},
    biomes: [biome_cells_per_chunk]u8 = undefined,

    pub fn sectionPaletteCount(self: *const ChunkShape, section: usize) usize {
        return self.sections[section].palette_count;
    }

    pub fn sectionPaletteState(
        self: *const ChunkShape,
        section: usize,
        palette_index: usize,
    ) i32 {
        const descriptor = self.sections[section];
        std.debug.assert(palette_index < descriptor.palette_count);
        const offset = @as(usize, descriptor.palette_offset) + palette_index * @sizeOf(i32);
        return std.mem.readInt(i32, self.storage[offset..][0..@sizeOf(i32)], .little);
    }

    pub fn sectionPaletteIndex(
        self: *const ChunkShape,
        section: usize,
        local_index: u16,
    ) u16 {
        const descriptor = self.sections[section];
        if (descriptor.bits_per_block == 0) return 0;

        const bit_offset = @as(usize, local_index) * descriptor.bits_per_block;
        const byte_offset = @as(usize, descriptor.data_offset) + bit_offset / 8;
        const shift: u4 = @intCast(bit_offset & 7);
        var encoded: u16 = self.storage[byte_offset];
        if (shift + descriptor.bits_per_block > 8) {
            encoded |= @as(u16, self.storage[byte_offset + 1]) << 8;
        }
        const mask: u16 = (@as(u16, 1) << descriptor.bits_per_block) - 1;
        const palette_index = (encoded >> shift) & mask;
        std.debug.assert(palette_index < descriptor.palette_count);
        return palette_index;
    }

    pub fn sectionBlockState(
        self: *const ChunkShape,
        section: usize,
        local_index: u16,
    ) i32 {
        return self.sectionPaletteState(
            section,
            self.sectionPaletteIndex(section, local_index),
        );
    }

    pub fn rebuildSectionVisibility(self: *ChunkShape) void {
        for (0..limits.section_count) |section| {
            self.section_visibility[section] = sectionVisibility(self, section);
        }
    }

    pub fn encodeUniformSection(
        self: *ChunkShape,
        section: usize,
        block_state: i32,
    ) !void {
        const required = @as(usize, self.storage_len) + @sizeOf(i32);
        if (required > self.storage.len) return error.GeneratedChunkStorageCapacity;

        self.sections[section] = .{
            .palette_offset = self.storage_len,
            .data_offset = self.storage_len + @sizeOf(i32),
            .palette_count = 1,
        };
        std.mem.writeInt(
            i32,
            self.storage[self.storage_len..][0..@sizeOf(i32)],
            block_state,
            .little,
        );
        self.storage_len = @intCast(required);
        self.section_visibility[section] = blockVisibility(block_state);
    }

    pub fn encodeSection(
        self: *ChunkShape,
        section: usize,
        blocks: *const [blocks_per_section]i32,
    ) !void {
        var palette: [256]i32 = undefined;
        var indices: [blocks_per_section]u8 = undefined;
        const palette_count = try collectPalette(blocks, &palette, &indices);
        try self.writeSection(
            section,
            palette[0..palette_count],
            &indices,
            blocksVisibility(blocks),
        );
    }

    pub fn writeSection(
        self: *ChunkShape,
        section: usize,
        palette: []const i32,
        indices: *const [blocks_per_section]u8,
        visibility: SectionVisibility,
    ) !void {
        const bits: u4 = if (palette.len <= 1)
            0
        else
            @intCast(std.math.log2_int_ceil(usize, palette.len));
        const palette_bytes = palette.len * @sizeOf(i32);
        const data_bytes = (@as(usize, bits) * blocks_per_section + 7) / 8;
        const required = @as(usize, self.storage_len) + palette_bytes + data_bytes;
        if (required > self.storage.len) return error.GeneratedChunkStorageCapacity;

        self.sections[section] = .{
            .palette_offset = self.storage_len,
            .data_offset = self.storage_len + @as(u32, @intCast(palette_bytes)),
            .palette_count = @intCast(palette.len),
            .bits_per_block = bits,
        };
        var cursor: usize = self.storage_len;
        for (palette) |block_state| {
            std.mem.writeInt(i32, self.storage[cursor..][0..@sizeOf(i32)], block_state, .little);
            cursor += @sizeOf(i32);
        }
        writePackedIndices(self.storage[cursor..][0..data_bytes], indices, bits);
        self.storage_len = @intCast(required);
        self.section_visibility[section] = visibility;
    }
};

fn collectPalette(
    blocks: *const [blocks_per_section]i32,
    palette: *[256]i32,
    indices: *[blocks_per_section]u8,
) !usize {
    var palette_count: usize = 0;
    for (blocks, 0..) |block_state, block_index| {
        var palette_index: usize = 0;
        while (palette_index < palette_count and palette[palette_index] != block_state) {
            palette_index += 1;
        }
        if (palette_index == palette_count) {
            if (palette_count == palette.len) return error.GeneratedSectionPaletteCapacity;
            palette[palette_count] = block_state;
            palette_count += 1;
        }
        indices[block_index] = @intCast(palette_index);
    }
    return palette_count;
}

fn writePackedIndices(destination: []u8, indices: *const [blocks_per_section]u8, bits: u4) void {
    @memset(destination, 0);
    if (bits == 0) return;

    for (indices, 0..) |palette_index, block_index| {
        const bit_offset = block_index * @as(usize, bits);
        const byte_offset = bit_offset / 8;
        const shift: u4 = @intCast(bit_offset & 7);
        const encoded: u16 = @as(u16, palette_index) << shift;
        destination[byte_offset] |= @truncate(encoded);
        if (shift + bits > 8) destination[byte_offset + 1] |= @truncate(encoded >> 8);
    }
}

fn blockVisibility(block_state: i32) SectionVisibility {
    const info = game_data.blockInfo(block_state);
    if (info.visually_transparent) return .transparent;
    return if (info.filtered_light >= 15) .solid else .mixed;
}

fn blocksVisibility(blocks: *const [blocks_per_section]i32) SectionVisibility {
    var all_transparent = true;
    var all_opaque = true;
    for (blocks) |block_state| {
        const info = game_data.blockInfo(block_state);
        all_transparent = all_transparent and info.visually_transparent;
        all_opaque = all_opaque and !info.visually_transparent and info.filtered_light >= 15;
    }
    if (all_transparent) return .transparent;
    return if (all_opaque) .solid else .mixed;
}

fn sectionVisibility(shape: *const ChunkShape, section: usize) SectionVisibility {
    var all_transparent = true;
    var all_opaque = true;
    for (0..blocks_per_section) |block_index| {
        const info = game_data.blockInfo(shape.sectionBlockState(section, @intCast(block_index)));
        all_transparent = all_transparent and info.visually_transparent;
        all_opaque = all_opaque and !info.visually_transparent and info.filtered_light >= 15;
    }
    if (all_transparent) return .transparent;
    return if (all_opaque) .solid else .mixed;
}

pub fn validBlockState(block_state: i32) bool {
    return block_state >= 0 and block_state <= registry.maximum_block_state;
}

pub fn plainsBiomeId() u8 {
    return registry.biomeId("minecraft:plains").?;
}

pub fn buildFlatChunkShape(
    storage: []u8,
    chunk_x: i32,
    chunk_z: i32,
    surface_y: i16,
    surface_state: i32,
    underground_state: i32,
) !ChunkShape {
    if (!validBlockState(surface_state) or !validBlockState(underground_state)) {
        return error.InvalidBlockState;
    }
    if (surface_y < limits.min_y or surface_y > maximum_generated_y) {
        return error.InvalidSurfaceHeight;
    }

    var shape: ChunkShape = .{
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
        .heights = [_]i16{surface_y} ** 256,
        .storage = storage,
    };
    var blocks: [blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
        try encodeFlatSection(&shape, section, surface_y, surface_state, underground_state, &blocks);
    }
    @memset(&shape.biomes, plainsBiomeId());
    return shape;
}

fn encodeFlatSection(
    shape: *ChunkShape,
    section: usize,
    surface_y: i16,
    surface_state: i32,
    underground_state: i32,
    blocks: *[blocks_per_section]i32,
) !void {
    const bottom = limits.min_y + @as(i16, @intCast(section * 16));
    if (bottom + 15 < surface_y) {
        return shape.encodeUniformSection(section, underground_state);
    }
    if (bottom > surface_y) {
        return shape.encodeUniformSection(section, registry.block_air_default_state);
    }
    for (blocks, 0..) |*block_state, local_index| {
        const y = bottom + @as(i16, @intCast(local_index >> 8));
        block_state.* = if (y < surface_y)
            underground_state
        else if (y == surface_y)
            surface_state
        else
            registry.block_air_default_state;
    }
    return shape.encodeSection(section, blocks);
}

pub fn buildVoidChunkShape(storage: []u8, chunk_x: i32, chunk_z: i32) !ChunkShape {
    var shape: ChunkShape = .{
        .chunk_x = chunk_x,
        .chunk_z = chunk_z,
        .heights = [_]i16{limits.min_y - 1} ** 256,
        .storage = storage,
    };
    for (0..limits.section_count) |section| {
        try shape.encodeUniformSection(section, registry.block_air_default_state);
    }
    @memset(&shape.biomes, plainsBiomeId());
    return shape;
}

pub fn blockAtFromShape(shape: *const ChunkShape, x: i32, y: i16, z: i32) i32 {
    const min_x = shape.chunk_x * 16;
    const min_z = shape.chunk_z * 16;
    std.debug.assert(x >= min_x and x < min_x + 16);
    std.debug.assert(z >= min_z and z < min_z + 16);
    if (y < limits.min_y or y >= limits.top_y) return registry.block_air_default_state;

    const local_x: usize = @intCast(x - min_x);
    const local_z: usize = @intCast(z - min_z);
    const relative_y: usize = @intCast(y - limits.min_y);
    const local_index: u16 = @intCast(
        local_x | (local_z << 4) | ((relative_y & 15) << 8),
    );
    return shape.sectionBlockState(relative_y / 16, local_index);
}

pub fn fillSectionFromShape(
    shape: *const ChunkShape,
    section: usize,
    output: *[blocks_per_section]i32,
) void {
    std.debug.assert(section < limits.section_count);
    for (output, 0..) |*block_state, local_index| {
        block_state.* = shape.sectionBlockState(section, @intCast(local_index));
    }
}

pub fn fillSectionBiomesFromShape(
    shape: *const ChunkShape,
    section: usize,
    output: *[biome_cells_per_section]u8,
) void {
    std.debug.assert(section < limits.section_count);
    @memcpy(
        output,
        shape.biomes[section * biome_cells_per_section ..][0..biome_cells_per_section],
    );
}

pub fn highestYFromShape(shape: *const ChunkShape, local_x: usize, local_z: usize) i16 {
    std.debug.assert(local_x < 16 and local_z < 16);
    return shape.heights[local_z * 16 + local_x];
}

pub fn uniformSectionState(shape: *const ChunkShape, section: usize) ?i32 {
    if (section >= limits.section_count) return null;
    if (shape.sections[section].palette_count != 1) return null;
    return shape.sectionPaletteState(section, 0);
}

pub fn uniformSectionBlockStateFromShape(shape: *const ChunkShape, section: usize) ?i32 {
    return uniformSectionState(shape, section);
}

pub fn sectionMayContainBlocks(section: usize) bool {
    return section < limits.section_count;
}

pub fn fillChunkRandomTickMasksFromShape(
    shape: *const ChunkShape,
    heights: *[256]i16,
    grass_above_blocked: *[4]u64,
    masks: *[limits.section_count][random_tick_mask_words]u64,
    counts: *[limits.section_count]u16,
) u32 {
    @memset(masks, [_]u64{0} ** random_tick_mask_words);
    @memset(counts, 0);
    grass_above_blocked.* = [_]u64{0} ** 4;
    heights.* = shape.heights;
    markGrassBlockers(shape, grass_above_blocked);
    return markRandomTickBlocks(shape, masks, counts);
}

fn markGrassBlockers(shape: *const ChunkShape, grass_above_blocked: *[4]u64) void {
    for (shape.heights, 0..) |height, column| {
        if (height < limits.min_y or height >= maximum_generated_y) continue;
        const relative_y: usize = @intCast(height + 1 - limits.min_y);
        const local_index: u16 = @intCast(
            (column & 15) | ((column >> 4) << 4) | ((relative_y & 15) << 8),
        );
        const above = shape.sectionBlockState(relative_y / 16, local_index);
        if (game_data.preventsGrassSurvival(above)) {
            grass_above_blocked[column / 64] |= @as(u64, 1) << @intCast(column & 63);
        }
    }
}

fn markRandomTickBlocks(
    shape: *const ChunkShape,
    masks: *[limits.section_count][random_tick_mask_words]u64,
    counts: *[limits.section_count]u16,
) u32 {
    var blocks: [blocks_per_section]i32 = undefined;
    var section_mask: u32 = 0;
    for (0..limits.section_count) |section| {
        fillSectionFromShape(shape, section, &blocks);
        for (blocks, 0..) |block_state, local_index| {
            if (registry.randomTickState(block_state).kind == .none) continue;
            masks[section][local_index / 64] |= @as(u64, 1) << @intCast(local_index & 63);
            counts[section] += 1;
        }
        if (counts[section] != 0) section_mask |= @as(u32, 1) << @intCast(section);
    }
    return section_mask;
}

test "random tick masks include every tickable block" {
    var storage: [chunk_storage_capacity]u8 = undefined;
    const shape = try buildFlatChunkShape(
        &storage,
        0,
        0,
        64,
        registry.block_grass_block_default_state,
        registry.block_stone_default_state,
    );
    var heights: [256]i16 = undefined;
    var blocked: [4]u64 = undefined;
    var masks: [limits.section_count][random_tick_mask_words]u64 = undefined;
    var counts: [limits.section_count]u16 = undefined;
    const sections = fillChunkRandomTickMasksFromShape(
        &shape,
        &heights,
        &blocked,
        &masks,
        &counts,
    );

    for (masks, counts, 0..) |section_mask, count, section| {
        var observed: u16 = 0;
        for (section_mask) |word| {
            observed += @popCount(word);
        }
        try std.testing.expectEqual(count, observed);
        try std.testing.expectEqual(
            count != 0,
            sections & (@as(u32, 1) << @intCast(section)) != 0,
        );
    }
    try std.testing.expect(sections != 0);
    try expectTickMasksMatchStates(&shape, &masks);
}

fn expectTickMasksMatchStates(
    shape: *const ChunkShape,
    masks: *const [limits.section_count][random_tick_mask_words]u64,
) !void {
    var blocks: [blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
        fillSectionFromShape(shape, section, &blocks);
        for (blocks, 0..) |block_state, local_index| {
            const actual = masks[section][local_index / 64] &
                (@as(u64, 1) << @intCast(local_index & 63)) != 0;
            const expected = registry.randomTickState(block_state).kind != .none;
            try std.testing.expectEqual(expected, actual);
        }
    }
}
