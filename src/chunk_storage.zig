const std = @import("std");
const blocks = @import("world/blocks.zig");
const limits = @import("world/limits.zig");
const geometry = @import("world/geometry.zig");
const terrain = @import("terrain.zig");
const world_identity = @import("world/identity.zig");
const registry = @import("registry_data");

const magic = "LRCHUNK2";
const header_len = magic.len + @sizeOf(i32) * 2 + @sizeOf(u16) + @sizeOf(u64) + @sizeOf(u32);
const shape_fixed_size = 16 * 16 * @sizeOf(i16) +
    @sizeOf(u8) + @sizeOf(u32) +
    limits.section_count * (@sizeOf(u32) * 2 + @sizeOf(u16) + @sizeOf(u8)) +
    limits.section_count * terrain.biome_cells_per_section;

pub const minimum_encoded_size = header_len + @sizeOf(u64);
pub const encoded_size = header_len + @sizeOf(u64) + shape_fixed_size +
    terrain.chunk_storage_capacity +
    limits.section_count *
        (@sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32));

const no_modified_record = std.math.maxInt(u32);

/// A change to apply to a canonical encoded chunk record.
pub const BlockWrite = struct {
    position: geometry.BlockPos,
    state: i32,
};

/// Immutable canonical chunk data borrowed directly from an encoded record.
/// It intentionally does not materialize a Blocks resident or expand a section.
pub const View = struct {
    shape: terrain.ShapeView,
    record: []const u8,
    content_revision: u64,
    /// The first byte following the fixed shape representation.  Anything after
    /// the modified-section records is derived data and is deliberately not
    /// retained by rewrite.
    shape_prefix_end: usize,
    modified_record_offsets: [limits.section_count]u32 = [_]u32{no_modified_record} ** limits.section_count,

    pub fn init(expected: geometry.ChunkPos, bytes: []const u8) !View {
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
        const content_revision = try reader.int(u64);
        if (content_revision == 0 or content_revision > blocks.Blocks.maximum_persisted_content_revision)
            return error.InvalidChunkRevision;

        var result = View{
            .shape = try readShapeView(&reader, expected),
            .record = bytes,
            .content_revision = content_revision,
            .shape_prefix_end = reader.index,
        };
        const record_size = @sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32);
        const records_end = reader.index + @as(usize, section_count) * record_size;
        if (records_end > bytes.len) return error.InvalidChunkLength;
        var previous: ?u16 = null;
        for (0..section_count) |_| {
            const section = try reader.int(u16);
            if (section >= limits.section_count or (previous != null and section <= previous.?))
                return error.InvalidWorldSection;
            previous = section;
            result.modified_record_offsets[section] = @intCast(reader.index);
            for (0..blocks.blocks_per_section) |_| {
                if (!terrain.validBlockState(try reader.int(i32))) return error.InvalidChunkBlockState;
            }
        }
        if (reader.index != records_end) return error.ExtraWorldData;
        return result;
    }

    /// Re-encodes this view's canonical data with the requested block writes.
    /// This is intentionally a record-to-record operation: it neither creates a
    /// resident Blocks instance nor expands an existing section.
    pub fn rewrite(self: *const View, destination: []u8, writes: []const BlockWrite, content_revision: u64) ![]u8 {
        if (content_revision == 0 or
            content_revision > blocks.Blocks.maximum_persisted_content_revision or
            content_revision == self.content_revision)
            return error.InvalidChunkRevision;
        var touched = [_]bool{false} ** limits.section_count;
        var added_sections: usize = 0;
        for (writes) |write| {
            if (!geometry.sameChunk(geometry.chunkForBlock(write.position), .{
                .x = self.shape.chunk_x,
                .z = self.shape.chunk_z,
            })) return error.UnexpectedChunkPosition;
            const section = blocks.sectionIndexForY(write.position.y) orelse return error.InvalidWorldSection;
            if (!terrain.validBlockState(write.state)) return error.InvalidChunkBlockState;
            if (!touched[section]) {
                touched[section] = true;
                if (self.modified_record_offsets[section] == no_modified_record) added_sections += 1;
            }
        }

        const record_size = @sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32);
        var existing_sections: usize = 0;
        for (self.modified_record_offsets) |offset| {
            if (offset != no_modified_record) existing_sections += 1;
        }
        const output_len = self.shape_prefix_end + (existing_sections + added_sections) * record_size;
        if (destination.len < output_len) return error.EndOfStream;
        if (slicesOverlap(self.record, destination)) return error.AliasedChunkRewrite;

        // The header and packed shape are byte-for-byte stable.
        @memcpy(destination[0..self.shape_prefix_end], self.record[0..self.shape_prefix_end]);
        std.mem.writeInt(u64, destination[header_len..][0..@sizeOf(u64)], content_revision, .little);
        var writer = Writer{ .buffer = destination[0..output_len], .index = self.shape_prefix_end };
        var output_sections: usize = 0;
        var state_offsets: [limits.section_count]usize = undefined;
        for (0..limits.section_count) |section| {
            const source_offset = self.modified_record_offsets[section];
            if (source_offset != no_modified_record) {
                const record_start = @as(usize, source_offset) - @sizeOf(u16);
                try writer.bytes(self.record[record_start..][0..record_size]);
            } else if (touched[section]) {
                try writer.int(u16, @intCast(section));
                for (0..blocks.blocks_per_section) |local_index| {
                    const palette_index = try self.shape.sectionPaletteIndex(section, @intCast(local_index));
                    try writer.int(i32, self.shape.sectionPaletteState(section, palette_index));
                }
            } else continue;

            state_offsets[section] = writer.index - blocks.blocks_per_section * @sizeOf(i32);
            output_sections += 1;
        }
        std.debug.assert(writer.index == output_len);
        for (writes) |write| {
            const section = blocks.sectionIndexForY(write.position.y).?;
            const local = blocks.localBlockIndexForPosition(write.position);
            const offset = state_offsets[section] + @as(usize, local) * @sizeOf(i32);
            std.mem.writeInt(i32, destination[offset..][0..@sizeOf(i32)], write.state, .little);
        }

        const section_count_offset = magic.len + @sizeOf(i32) * 2;
        const payload_len_offset = section_count_offset + @sizeOf(u16);
        const checksum_offset = payload_len_offset + @sizeOf(u64);
        std.mem.writeInt(u16, destination[section_count_offset..][0..@sizeOf(u16)], @intCast(output_sections), .little);
        std.mem.writeInt(u64, destination[payload_len_offset..][0..@sizeOf(u64)], @intCast(output_len - header_len), .little);
        std.mem.writeInt(u32, destination[checksum_offset..][0..@sizeOf(u32)], std.hash.crc.Crc32.hash(destination[header_len..output_len]), .little);
        return destination[0..output_len];
    }

    pub fn blockAt(self: *const View, position: geometry.BlockPos) !i32 {
        const section = blocks.sectionIndexForY(position.y) orelse
            return self.shape.blockAt(position.x, position.y, position.z);
        const offset = self.modified_record_offsets[section];
        if (offset == no_modified_record)
            return self.shape.blockAt(position.x, position.y, position.z);
        const local = blocks.localBlockIndexForPosition(position);
        const state_offset = @as(usize, offset) + @as(usize, local) * @sizeOf(i32);
        return std.mem.readInt(i32, self.record[state_offset..][0..@sizeOf(i32)], .little);
    }
};

fn slicesOverlap(a: []const u8, b: []u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return a_start < b_start + b.len and b_start < a_start + a.len;
}

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
    const resident = source.materializedChunk(world, chunk) orelse return error.ChunkNotMaterialized;
    if (resident.content_revision == 0 or resident.content_revision > blocks.Blocks.maximum_persisted_content_revision)
        return error.InvalidChunkRevision;
    try writer.int(u64, resident.content_revision);
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
    const content_revision = try reader.int(u64);
    if (content_revision == 0 or content_revision > blocks.Blocks.maximum_persisted_content_revision)
        return error.InvalidChunkRevision;

    var section: [blocks.blocks_per_section]i32 = undefined;
    var generated: [blocks.blocks_per_section]i32 = undefined;
    var shape_storage: [terrain.chunk_storage_capacity]u8 = undefined;
    const shape = try readShape(&reader, expected, &shape_storage);
    const record_size = @sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32);
    const records_end = reader.index + @as(usize, section_count) * record_size;
    if (bytes.len < records_end)
        return error.InvalidChunkLength;

    const sections_start = reader.index;
    var available_sections = destination.modifiedSectionCapacity() - destination.modifiedSectionCount();
    var available_dense_sections = destination.availableDenseSections();
    var present_sections: u32 = 0;
    var previous: ?u16 = null;
    for (0..section_count) |_| {
        const section_index = try reader.int(u16);
        if (section_index >= limits.section_count or
            (previous != null and section_index <= previous.?))
            return error.InvalidWorldSection;
        previous = section_index;
        present_sections |= @as(u32, 1) << @intCast(section_index);
        for (&section) |*block_state| {
            block_state.* = try reader.int(i32);
            if (!terrain.validBlockState(block_state.*)) return error.InvalidChunkBlockState;
        }
        const differs = blocks.Blocks.sectionDiffersFromShape(section_index, &section, &shape);
        const existing = destination.findModifiedSection(world, expected, section_index);
        const existing_dense = if (existing) |index| destination.modifiedSectionIsDense(index) else false;
        // `loadSectionFromShape` releases an existing entry before it assigns
        // this record.  Mirror that exact order so a record which becomes
        // sparse can fund a following new modified section.
        if (existing != null and !differs) available_sections += 1 else if (existing == null and differs) {
            if (available_sections == 0) return error.WorldSectionCapacity;
            available_sections -= 1;
        }
        if (existing_dense) available_dense_sections += 1;
        if (differs and blocks.Blocks.sectionRequiresDenseStorage(section_index, &section, &shape)) {
            if (available_dense_sections == 0) return error.WorldSectionCapacity;
            available_dense_sections -= 1;
        }
    }
    if (reader.index != records_end) return error.ExtraWorldData;

    _ = try destination.installPersistedMaterialization(world, shape, 0, content_revision);
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
    destination.finishPersistedMaterialization(world, expected, content_revision);
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

fn readShapeView(reader: *Reader, expected: geometry.ChunkPos) !terrain.ShapeView {
    for (0..16 * 16) |_| _ = try reader.int(i16);
    _ = try reader.boolean();
    const storage_len = try reader.int(u32);
    if (storage_len > terrain.chunk_storage_capacity) return error.InvalidChunkShapeStorage;
    var sections: [limits.section_count]terrain.SectionShape = undefined;
    try readSectionDescriptors(reader, &sections, storage_len);
    const storage = try reader.bytes(storage_len);
    const shape = terrain.ShapeView{
        .chunk_x = expected.x,
        .chunk_z = expected.z,
        .sections = sections,
        .storage = storage,
    };
    try validateViewPalettes(&shape);
    const biomes = try reader.bytes(terrain.biome_cells_per_chunk);
    for (biomes) |biome| if (biome >= terrain.biome_registry_count)
        return error.InvalidChunkShapeBiome;
    return shape;
}

fn readSections(reader: *Reader, shape: *terrain.ChunkShape) !void {
    try readSectionDescriptors(reader, &shape.sections, shape.storage_len);
}

fn readSectionDescriptors(
    reader: *Reader,
    sections: *[limits.section_count]terrain.SectionShape,
    storage_len: u32,
) !void {
    var expected_offset: usize = 0;
    for (sections) |*section| {
        const palette_offset = try reader.int(u32);
        const data_offset = try reader.int(u32);
        const palette_count = try reader.int(u16);
        const bits_per_block = try reader.int(u8);
        if (bits_per_block > 8 or palette_count == 0 or palette_count > 256)
            return error.InvalidChunkShapeSection;
        const expected_bits: u8 = if (palette_count == 1) 0 else @intCast(std.math.log2_int_ceil(usize, palette_count));
        if (bits_per_block != expected_bits or palette_offset != expected_offset)
            return error.InvalidChunkShapeSection;
        const palette_end = expected_offset + @as(usize, palette_count) * @sizeOf(i32);
        if (data_offset != palette_end) return error.InvalidChunkShapeSection;
        section.* = .{
            .palette_offset = palette_offset,
            .data_offset = data_offset,
            .palette_count = palette_count,
            .bits_per_block = @intCast(bits_per_block),
        };
        expected_offset = palette_end +
            (@as(usize, bits_per_block) * terrain.blocks_per_section + 7) / 8;
        if (expected_offset > storage_len) return error.InvalidChunkShapeSection;
    }
    if (expected_offset != storage_len) return error.InvalidChunkShapeSection;
}

fn validatePalettes(shape: *const terrain.ChunkShape) !void {
    for (shape.sections) |section| for (0..section.palette_count) |palette_index| {
        const offset = @as(usize, section.palette_offset) + palette_index * @sizeOf(i32);
        const block_state = std.mem.readInt(i32, shape.storage[offset..][0..4], .little);
        if (!terrain.validBlockState(block_state)) return error.InvalidChunkShapeBlockState;
    };
}

fn validateViewPalettes(shape: *const terrain.ShapeView) !void {
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
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    const destination = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 71);
    generator.bind(source);
    const position = geometry.ChunkPos{ .x = 2, .z = -3 };
    _ = source.materializeGeneratedChunk(test_world, position, 1);
    var record: [encoded_size]u8 = undefined;
    const encoded = try encode(&record, source, test_world, position);
    const source_revision = source.materializedChunk(test_world, position).?.content_revision;
    const source_binding = source.materializedChunk(test_world, position).?.binding_revision;
    const tail = "derived-light";
    const extended = try append(&record, encoded, tail);
    const decoded_tail = try decodeWithTail(destination, test_world, position, extended);
    try std.testing.expectEqualSlices(u8, tail, decoded_tail);
    try std.testing.expectEqual(source_revision, destination.materializedChunk(test_world, position).?.content_revision);

    source.markChunkClean(test_world, position);
    try std.testing.expect(source.evictChunk(test_world, position));
    _ = try decodeWithTail(source, test_world, position, extended);
    try std.testing.expectEqual(source_revision, source.materializedChunk(test_world, position).?.content_revision);
    try std.testing.expect(source_binding != source.materializedChunk(test_world, position).?.binding_revision);
}

test "chunk decode reserves every modified section before installing anything" {
    const test_generator = @import("test_support/world_generator.zig");
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const chunk = geometry.ChunkPos{ .x = 0, .z = 0 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    const destination = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 1,
    });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 0);
    generator.bind(source);
    _ = source.materializeGeneratedChunk(world, chunk, 0);
    try std.testing.expect(try source.setBlock(world, .{ .x = 0, .y = 200, .z = 0 }, registry.block_stone_default_state));
    try std.testing.expect(try source.setBlock(world, .{ .x = 0, .y = 216, .z = 0 }, registry.block_stone_default_state));
    var bytes: [encoded_size]u8 = undefined;
    const encoded = try encode(&bytes, source, world, chunk);
    const cursor = destination.chunk_change_sequence;
    var invalid_revision: [encoded_size]u8 = undefined;
    @memcpy(invalid_revision[0..encoded.len], encoded);
    std.mem.writeInt(u64, invalid_revision[header_len..][0..@sizeOf(u64)], 0, .little);
    rewriteChecksum(invalid_revision[0..encoded.len]);
    try std.testing.expectError(error.InvalidChunkRevision, decode(destination, world, chunk, invalid_revision[0..encoded.len]));
    try std.testing.expectEqual(@as(usize, 0), destination.materializedChunkCount());
    try std.testing.expectEqual(cursor, destination.chunk_change_sequence);
    std.mem.writeInt(u64, invalid_revision[header_len..][0..@sizeOf(u64)], blocks.Blocks.maximum_persisted_content_revision + 1, .little);
    rewriteChecksum(invalid_revision[0..encoded.len]);
    try std.testing.expectError(error.InvalidChunkRevision, decode(destination, world, chunk, invalid_revision[0..encoded.len]));
    try std.testing.expectEqual(@as(usize, 0), destination.materializedChunkCount());
    try std.testing.expectEqual(cursor, destination.chunk_change_sequence);
    try std.testing.expectError(error.WorldSectionCapacity, decode(destination, world, chunk, encoded));
    try std.testing.expectEqual(@as(usize, 0), destination.materializedChunkCount());
    try std.testing.expectEqual(@as(usize, 0), destination.modifiedSectionCount());
    try std.testing.expectEqual(cursor, destination.chunk_change_sequence);
    try std.testing.expectError(error.ContentRevisionExhausted, destination.nextContentRevision(blocks.Blocks.maximum_persisted_content_revision));
}

test "encoded chunk view reads canonical modifications without materializing" {
    const test_generator = @import("test_support/world_generator.zig");
    const test_world = world_identity.Handle{ .index = 0, .generation = 1 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 71);
    generator.bind(source);
    const chunk = geometry.ChunkPos{ .x = 2, .z = -3 };
    _ = source.materializeGeneratedChunk(test_world, chunk, 1);

    const modified = geometry.BlockPos{ .x = chunk.x * 16 + 1, .y = 200, .z = chunk.z * 16 + 2 };
    try std.testing.expect(try source.setBlock(test_world, modified, registry.block_stone_default_state));
    const base = geometry.BlockPos{ .x = chunk.x * 16 + 3, .y = 64, .z = chunk.z * 16 + 4 };
    var record: [encoded_size]u8 = undefined;
    const encoded = try encode(&record, source, test_world, chunk);
    const view = try View.init(chunk, encoded);
    try std.testing.expectEqual(source.blockAt(test_world, modified), try view.blockAt(modified));
    try std.testing.expectEqual(source.blockAt(test_world, base), try view.blockAt(base));

    var corrupt: [encoded_size]u8 = undefined;
    @memcpy(corrupt[0..encoded.len], encoded);
    corrupt[encoded.len - 1] ^= 1;
    try std.testing.expectError(error.WorldChecksumMismatch, View.init(chunk, corrupt[0..encoded.len]));

    @memcpy(corrupt[0..encoded.len], encoded);
    const descriptors_start = header_len + @sizeOf(u64) + 16 * 16 * @sizeOf(i16) + @sizeOf(u8) + @sizeOf(u32);
    corrupt[descriptors_start + @sizeOf(u32) * 2 + @sizeOf(u16)] = 16;
    rewriteChecksum(corrupt[0..encoded.len]);
    try std.testing.expectError(error.InvalidChunkShapeSection, View.init(chunk, corrupt[0..encoded.len]));

    const malformed_chunk = geometry.ChunkPos{ .x = 3, .z = -3 };
    var template_storage: [terrain.chunk_storage_capacity]u8 = undefined;
    const template = try terrain.buildFlatChunkShape(
        &template_storage,
        malformed_chunk.x,
        malformed_chunk.z,
        64,
        registry.block_grass_block_default_state,
        registry.block_stone_default_state,
    );
    var shape_storage: [terrain.chunk_storage_capacity]u8 = undefined;
    var malformed_shape = terrain.ChunkShape{
        .chunk_x = malformed_chunk.x,
        .chunk_z = malformed_chunk.z,
        .heights = @splat(limits.top_y),
        .grass_spread_possible = template.grass_spread_possible,
        .storage = &shape_storage,
        .biomes = template.biomes,
    };
    var section_blocks: [terrain.blocks_per_section]i32 = [_]i32{registry.block_stone_default_state} ** terrain.blocks_per_section;
    section_blocks[0] = registry.block_air_default_state;
    section_blocks[1] = registry.block_grass_block_default_state;
    try malformed_shape.encodeSection(0, &section_blocks);
    for (1..limits.section_count) |section| {
        if (section == limits.section_count - 1)
            @memset(&section_blocks, registry.block_stone_default_state)
        else
            terrain.fillSectionFromShape(&template, section, &section_blocks);
        try malformed_shape.encodeSection(section, &section_blocks);
    }
    _ = try source.installMaterialization(test_world, malformed_shape, 1, .persisted);
    var malformed_record: [encoded_size]u8 = undefined;
    const malformed_encoded = try encode(&malformed_record, source, test_world, malformed_chunk);
    const valid_view = try View.init(malformed_chunk, malformed_encoded);
    try std.testing.expectEqual(registry.block_stone_default_state, try valid_view.blockAt(.{
        .x = malformed_chunk.x * 16,
        .y = limits.top_y,
        .z = malformed_chunk.z * 16,
    }));
    @memcpy(corrupt[0..malformed_encoded.len], malformed_encoded);
    const section_descriptor_bytes = @sizeOf(u32) * 2 + @sizeOf(u16) + @sizeOf(u8);
    const storage_start = descriptors_start + limits.section_count * section_descriptor_bytes;
    const data_offset = std.mem.readInt(u32, corrupt[descriptors_start + @sizeOf(u32) ..][0..@sizeOf(u32)], .little);
    corrupt[storage_start + @as(usize, data_offset)] = 0xff; // palette index 3 is invalid for the explicit three-state palette.
    rewriteChecksum(corrupt[0..malformed_encoded.len]);
    const malformed_view = try View.init(malformed_chunk, corrupt[0..malformed_encoded.len]);
    const malformed_position = geometry.BlockPos{
        .x = malformed_chunk.x * 16,
        .y = limits.min_y,
        .z = malformed_chunk.z * 16,
    };
    try std.testing.expectError(error.InvalidChunkShapePaletteIndex, malformed_view.blockAt(malformed_position));
}

test "encoded chunk view rewrites canonical sections without materializing" {
    const test_generator = @import("test_support/world_generator.zig");
    const world = world_identity.Handle{ .index = 0, .generation = 1 };
    const chunk = geometry.ChunkPos{ .x = 2, .z = -3 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try blocks.Blocks.init(arena.allocator(), .{
        .maximum_transient_chunks = 4,
        .maximum_modified_sections = 2,
    });
    var generator: test_generator.Generator = .{};
    try generator.init(arena.allocator(), 71);
    generator.bind(source);
    _ = source.materializeGeneratedChunk(world, chunk, 1);

    const old_modified = geometry.BlockPos{ .x = 33, .y = 200, .z = -46 };
    const untouched = geometry.BlockPos{ .x = 35, .y = 64, .z = -44 };
    const newly_modified = geometry.BlockPos{ .x = 36, .y = 32, .z = -45 };
    try std.testing.expect(try source.setBlock(world, old_modified, registry.block_stone_default_state));
    var source_record: [encoded_size]u8 = undefined;
    const canonical = try encode(&source_record, source, world, chunk);
    const extended = try append(&source_record, canonical, "derived-light");
    var source_copy: [encoded_size]u8 = undefined;
    @memcpy(source_copy[0..extended.len], extended);
    const view = try View.init(chunk, extended);
    const materialized_before = source.materializedChunkCount();

    const writes = [_]BlockWrite{
        .{ .position = old_modified, .state = registry.block_air_default_state },
        .{ .position = newly_modified, .state = registry.block_stone_default_state },
        .{ .position = old_modified, .state = registry.block_grass_block_default_state },
    };
    var rewritten_storage: [encoded_size]u8 = undefined;
    const rewritten = try view.rewrite(&rewritten_storage, &writes, view.content_revision + 1);
    const rewritten_view = try View.init(chunk, rewritten);
    try std.testing.expectEqual(registry.block_grass_block_default_state, try rewritten_view.blockAt(old_modified));
    try std.testing.expectEqual(registry.block_stone_default_state, try rewritten_view.blockAt(newly_modified));
    try std.testing.expectEqual(try view.blockAt(untouched), try rewritten_view.blockAt(untouched));
    try std.testing.expectEqual(materialized_before, source.materializedChunkCount());
    try std.testing.expectEqualSlices(u8, source_copy[0..extended.len], extended);
    try std.testing.expectEqual(view.shape_prefix_end + 2 * (@sizeOf(u16) + blocks.blocks_per_section * @sizeOf(i32)), rewritten.len);

    var too_small: [1]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, view.rewrite(&too_small, &writes, view.content_revision + 1));
    try std.testing.expectEqualSlices(u8, source_copy[0..extended.len], extended);
    try std.testing.expectError(error.AliasedChunkRewrite, view.rewrite(source_record[0..], &writes, view.content_revision + 1));
    try std.testing.expectError(error.InvalidChunkRevision, view.rewrite(&rewritten_storage, &writes, blocks.Blocks.maximum_persisted_content_revision + 1));
    source.markChunkClean(world, chunk);
    try std.testing.expect(source.evictChunk(world, chunk));
    try decode(source, world, chunk, rewritten);
    try std.testing.expectEqual(registry.block_grass_block_default_state, source.blockAt(world, old_modified));
    try std.testing.expectEqual(registry.block_stone_default_state, source.blockAt(world, newly_modified));
}

fn rewriteChecksum(bytes: []u8) void {
    const payload_len_offset = magic.len + @sizeOf(i32) * 2 + @sizeOf(u16);
    const checksum_offset = payload_len_offset + @sizeOf(u64);
    std.mem.writeInt(u32, bytes[checksum_offset..][0..@sizeOf(u32)], std.hash.crc.Crc32.hash(bytes[header_len..]), .little);
}
