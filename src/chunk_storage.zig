const std = @import("std");
const blocks = @import("world/blocks.zig");
const limits = @import("world/limits.zig");
const geometry = @import("world/geometry.zig");
const terrain = @import("terrain.zig");
const world_identity = @import("world/identity.zig");

const magic = "LRCHUNK";
const header_len = magic.len + @sizeOf(i32) * 2 + @sizeOf(u16) + @sizeOf(u64) + @sizeOf(u32);
const shape_fixed_size = 16 * 16 * @sizeOf(i16) +
    @sizeOf(u8) + @sizeOf(u32) +
    limits.section_count * (@sizeOf(u32) * 2 + @sizeOf(u16) + @sizeOf(u8)) +
    limits.section_count * terrain.biome_cells_per_section;

pub const minimum_encoded_size = header_len;
pub const encoded_size = header_len + shape_fixed_size +
    terrain.chunk_storage_capacity +
    limits.section_count *
        (@sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32));

pub fn encode(
    buffer: []u8,
    source: *const blocks.Blocks,
    world: world_identity.Handle,
    chunk: geometry.ChunkPos,
) ![]u8 {
    if (buffer.len < encoded_size) return error.EndOfStream;
    var writer = Writer{ .buffer = buffer[0..encoded_size] };
    try writer.bytes(magic);
    try writer.int(i32, chunk.x);
    try writer.int(i32, chunk.z);
    var section_count: u16 = 0;
    for (0..limits.section_count) |section| {
        if (source.findModifiedSection(world, chunk, section) != null) section_count += 1;
    }
    try writer.int(u16, section_count);
    const payload_len_offset = writer.index;
    try writer.int(u64, 0);
    const checksum_offset = writer.index;
    try writer.int(u32, 0);
    const payload_start = writer.index;
    const resident = source.residentChunk(world, chunk) orelse return error.ChunkNotResident;
    try writeShape(&writer, &resident.shape);
    var section_blocks: [blocks.blocks_per_section]i32 = undefined;
    for (0..limits.section_count) |section| {
        const index = source.findModifiedSection(world, chunk, section) orelse continue;
        try writer.int(u16, @intCast(section));
        source.copySectionBlocks(index, &section_blocks);
        for (section_blocks) |block_state| try writer.int(i32, block_state);
    }
    const payload = buffer[payload_start..writer.index];
    std.mem.writeInt(u64, buffer[payload_len_offset..][0..8], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buffer[checksum_offset..][0..4], std.hash.crc.Crc32.hash(payload), .little);
    return buffer[0..writer.index];
}

pub fn append(buffer: []u8, encoded: []u8, tail: []const u8) ![]u8 {
    if (encoded.ptr != buffer.ptr or encoded.len < header_len or encoded.len + tail.len > buffer.len)
        return error.EndOfStream;
    const destination = buffer[encoded.len..][0..tail.len];
    if (destination.ptr != tail.ptr) @memcpy(destination, tail);
    const length = encoded.len + tail.len;
    const payload = buffer[header_len..length];
    const payload_len_offset = magic.len + @sizeOf(i32) * 2 + @sizeOf(u16);
    const checksum_offset = payload_len_offset + @sizeOf(u64);
    std.mem.writeInt(u64, buffer[payload_len_offset..][0..8], @intCast(payload.len), .little);
    std.mem.writeInt(u32, buffer[checksum_offset..][0..4], std.hash.crc.Crc32.hash(payload), .little);
    return buffer[0..length];
}

pub fn decode(
    destination: *blocks.Blocks,
    world: world_identity.Handle,
    expected: geometry.ChunkPos,
    bytes: []const u8,
) !void {
    const tail = try decodeWithTail(destination, world, expected, bytes);
    if (tail.len != 0) return error.ExtraWorldData;
}

pub fn decodeWithTail(
    destination: *blocks.Blocks,
    world: world_identity.Handle,
    expected: geometry.ChunkPos,
    bytes: []const u8,
) ![]const u8 {
    if (bytes.len < header_len or bytes.len > encoded_size) return error.InvalidChunkLength;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidChunkMagic;
    var reader = Reader{ .buffer = bytes, .index = magic.len };
    const actual = geometry.ChunkPos{ .x = try reader.int(i32), .z = try reader.int(i32) };
    if (!geometry.sameChunk(actual, expected)) return error.UnexpectedChunkPosition;
    const section_count = try reader.int(u16);
    if (section_count > limits.section_count) return error.InvalidWorldSection;
    const payload_len = try reader.int(u64);
    const checksum = try reader.int(u32);
    if (payload_len != bytes.len - header_len) return error.InvalidChunkLength;
    if (std.hash.crc.Crc32.hash(bytes[header_len..]) != checksum) return error.WorldChecksumMismatch;

    var section: [blocks.blocks_per_section]i32 = undefined;
    var generated: [blocks.blocks_per_section]i32 = undefined;
    var shape_storage: [terrain.chunk_storage_capacity]u8 = undefined;
    const shape = try readShape(&reader, expected, &shape_storage);
    const record_size = @sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32);
    const records_end = reader.index + @as(usize, section_count) * record_size;
    if (bytes.len < records_end)
        return error.InvalidChunkLength;

    const sections_start = reader.index;
    var required_pages: usize = 0;
    var present_sections: u32 = 0;
    var previous: ?u16 = null;
    for (0..section_count) |_| {
        const section_index = try reader.int(u16);
        if (section_index >= limits.section_count or
            (previous != null and section_index <= previous.?))
            return error.InvalidWorldSection;
        previous = section_index;
        present_sections |= @as(u32, 1) << @intCast(section_index);
        for (&section) |*block_state| block_state.* = try reader.int(i32);
        if (destination.findModifiedSection(world, expected, section_index) != null) continue;
        if (blocks.Blocks.sectionStorageNeedsPage(section_index, &section, &shape)) required_pages += 1;
    }
    if (reader.index != records_end) return error.ExtraWorldData;
    if (required_pages > destination.availableSectionPages()) return error.WorldSectionCapacity;

    _ = try destination.installResidentChunk(world, shape, 0, .persisted);
    reader.index = sections_start;
    for (0..section_count) |_| {
        const section_index = try reader.int(u16);
        for (&section) |*block_state| block_state.* = try reader.int(i32);
        try destination.loadSectionFromShape(world, expected, section_index, &section, &shape);
    }
    for (0..limits.section_count) |section_index| {
        if (present_sections & (@as(u32, 1) << @intCast(section_index)) != 0) continue;
        if (destination.findModifiedSection(world, expected, section_index) == null) continue;
        terrain.fillSectionFromShape(&shape, section_index, &generated);
        try destination.loadSectionFromShape(world, expected, section_index, &generated, &shape);
    }
    std.debug.assert(reader.index == records_end);
    return bytes[records_end..];
}

fn writeShape(writer: *Writer, shape: *const terrain.ChunkShape) !void {
    for (shape.heights) |height| try writer.int(i16, height);
    try writer.int(u8, @intFromBool(shape.grass_spread_possible));
    try writer.int(u32, shape.storage_len);
    for (shape.sections) |section| {
        try writer.int(u32, section.palette_offset);
        try writer.int(u32, section.data_offset);
        try writer.int(u16, section.palette_count);
        try writer.int(u8, section.bits_per_block);
    }
    try writer.bytes(shape.storage[0..shape.storage_len]);
    try writer.bytes(&shape.biomes);
}

fn readShape(
    reader: *Reader,
    expected: geometry.ChunkPos,
    storage: []u8,
) !terrain.ChunkShape {
    var shape = terrain.ChunkShape{
        .chunk_x = expected.x,
        .chunk_z = expected.z,
        .heights = undefined,
        .storage = storage,
    };
    for (&shape.heights) |*height| height.* = try reader.int(i16);
    shape.grass_spread_possible = try reader.boolean();
    shape.storage_len = try reader.int(u32);
    if (shape.storage_len > shape.storage.len) return error.InvalidChunkShapeStorage;
    try readSections(reader, &shape);
    @memcpy(shape.storage[0..shape.storage_len], try reader.bytes(shape.storage_len));
    try validatePalettes(&shape);
    @memcpy(&shape.biomes, try reader.bytes(shape.biomes.len));
    for (shape.biomes) |biome| if (biome >= terrain.biome_registry_count)
        return error.InvalidChunkShapeBiome;
    shape.rebuildSectionVisibility();
    return shape;
}

fn readSections(reader: *Reader, shape: *terrain.ChunkShape) !void {
    var expected_offset: usize = 0;
    for (&shape.sections) |*section| {
        const palette_offset = try reader.int(u32);
        const data_offset = try reader.int(u32);
        const palette_count = try reader.int(u16);
        const bits_per_block = try reader.int(u8);
        section.* = .{
            .palette_offset = palette_offset,
            .data_offset = data_offset,
            .palette_count = palette_count,
            .bits_per_block = @intCast(bits_per_block),
        };
        if (bits_per_block > 8 or palette_count == 0 or palette_count > 256)
            return error.InvalidChunkShapeSection;
        const expected_bits: u8 = if (palette_count == 1) 0 else @intCast(std.math.log2_int_ceil(usize, palette_count));
        if (bits_per_block != expected_bits or palette_offset != expected_offset)
            return error.InvalidChunkShapeSection;
        const palette_end = expected_offset + @as(usize, palette_count) * @sizeOf(i32);
        if (data_offset != palette_end) return error.InvalidChunkShapeSection;
        expected_offset = palette_end +
            (@as(usize, bits_per_block) * terrain.blocks_per_section + 7) / 8;
        if (expected_offset > shape.storage_len) return error.InvalidChunkShapeSection;
    }
    if (expected_offset != shape.storage_len) return error.InvalidChunkShapeSection;
}

fn validatePalettes(shape: *const terrain.ChunkShape) !void {
    for (shape.sections) |section| for (0..section.palette_count) |palette_index| {
        const offset = @as(usize, section.palette_offset) + palette_index * @sizeOf(i32);
        const block_state = std.mem.readInt(i32, shape.storage[offset..][0..4], .little);
        if (!terrain.validBlockState(block_state)) return error.InvalidChunkShapeBlockState;
    };
}

const Writer = struct {
    buffer: []u8,
    index: usize = 0,

    fn int(self: *Writer, comptime T: type, value: T) !void {
        const size = @sizeOf(T);
        if (self.index + size > self.buffer.len) return error.EndOfStream;
        std.mem.writeInt(T, self.buffer[self.index..][0..size], value, .little);
        self.index += size;
    }

    fn bytes(self: *Writer, value: []const u8) !void {
        if (self.index + value.len > self.buffer.len) return error.EndOfStream;
        @memcpy(self.buffer[self.index..][0..value.len], value);
        self.index += value.len;
    }
};

const Reader = struct {
    buffer: []const u8,
    index: usize = 0,

    fn int(self: *Reader, comptime T: type) !T {
        const size = @sizeOf(T);
        if (self.index + size > self.buffer.len) return error.TruncatedWorldFile;
        const value = std.mem.readInt(T, self.buffer[self.index..][0..size], .little);
        self.index += size;
        return value;
    }

    fn bytes(self: *Reader, len: usize) ![]const u8 {
        if (self.index + len > self.buffer.len) return error.TruncatedWorldFile;
        const value = self.buffer[self.index..][0..len];
        self.index += len;
        return value;
    }

    fn boolean(self: *Reader) !bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }
};

test "chunk records retain a checksummed derived tail" {
    const test_generator = @import("test_support/world_generator.zig");
    const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_resident_chunks = 2,
        .maximum_modified_sections = 2,
    });
    const destination = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_resident_chunks = 2,
        .maximum_modified_sections = 2,
    });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 71);
    generator.bind(source);
    const position = geometry.ChunkPos{ .x = 2, .z = -3 };
    _ = source.generatedHeightChunkRef(test_world, position, 1);
    var record: [encoded_size]u8 = undefined;
    const encoded = try encode(&record, source, test_world, position);
    const tail = "derived-light";
    const extended = try append(&record, encoded, tail);
    const decoded_tail = try decodeWithTail(destination, test_world, position, extended);
    try std.testing.expectEqualSlices(u8, tail, decoded_tail);
}
