const std = @import("std");
const builtin = @import("builtin");
const records = @import("records");
const storage = @import("storage");
pub const bitplanes = @import("bitplanes.zig");

pub const blocks = 16 * 16 * 16;
pub const dense_block_bytes = 1 + blocks * @sizeOf(u16);
pub const biome_cells = 4 * 4 * 4;
pub const biome_header_bytes = 1 + biome_cells * @sizeOf(u16);
pub const maximum_decoded_bytes = biome_header_bytes + dense_block_bytes;
pub const codec: records.Codec = .{ .encode = encode, .decode = decode };

const palette_capacity = 2048;
const table_capacity = 4096;
const empty = std.math.maxInt(u16);

// Tags 0 and 1 match the decoded uniform and dense representations.
// Tag 2 stores a frequency-ordered palette followed by LSB-first bitplanes.
// Tag 3 prefixes a block representation with 64 little-endian biome IDs.
pub fn encode(input: []const u8, output: []u8) storage.Error![]const u8 {
    if (input.len >= biome_header_bytes + 3 and input[0] == 3) {
        if (input[biome_header_bytes] == 3) return error.Corrupt;
        if (output.len < biome_header_bytes + 3) return error.BufferTooSmall;
        const encoded = try encode(input[biome_header_bytes..], output[biome_header_bytes..]);
        if (encoded.ptr == input[biome_header_bytes..].ptr) return input;
        @memcpy(output[0..biome_header_bytes], input[0..biome_header_bytes]);
        return output[0 .. biome_header_bytes + encoded.len];
    }
    if (input.len == 3 and input[0] == 0) return input;
    if (input.len != dense_block_bytes or input[0] != 1) return error.Corrupt;
    var table: [table_capacity]u16 = @splat(empty);
    var palette: [palette_capacity]u16 = undefined;
    var indices: [blocks]u16 = undefined;
    var counts: [palette_capacity]u16 = undefined;
    var order: [palette_capacity]u16 = undefined;
    var count: u16 = 0;
    for (&indices, 0..) |*index, i| {
        const state = std.mem.readInt(u16, input[1 + i * 2 ..][0..2], .little);
        var slot: usize = (@as(u32, state) *% 0x9e3779b9) >> 20;
        while (table[slot] != empty and palette[table[slot]] != state) slot = (slot + 1) % table_capacity;
        if (table[slot] == empty) {
            if (encodedBytes(count + 1) >= dense_block_bytes) return input;
            std.debug.assert(count < palette.len);
            palette[count] = state;
            counts[count] = 0;
            table[slot] = count;
            count += 1;
        }
        index.* = table[slot];
        counts[index.*] += 1;
    }
    const length = encodedBytes(count);
    if (output.len < length) return error.BufferTooSmall;
    if (count == 1) {
        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], palette[0], .little);
        return output[0..3];
    }
    output[0] = 2;
    std.mem.writeInt(u16, output[1..3], count, .little);
    for (order[0..count], 0..) |*entry, index| entry.* = @intCast(index);
    const Sort = struct {
        palette: []const u16,
        counts: []const u16,
        fn less(self: @This(), a: u16, b: u16) bool {
            return self.counts[a] > self.counts[b] or (self.counts[a] == self.counts[b] and self.palette[a] < self.palette[b]);
        }
    };
    std.mem.sort(u16, order[0..count], Sort{ .palette = palette[0..count], .counts = counts[0..count] }, Sort.less);
    for (order[0..count], 0..) |old, rank| {
        std.mem.writeInt(u16, output[3 + rank * 2 ..][0..2], palette[old], .little);
        counts[old] = @intCast(rank);
    }
    for (&indices) |*index| index.* = counts[index.*];
    var writer: std.Io.Writer = .fixed(output[3 + @as(usize, count) * 2 .. length]);
    bitplanes.encode(blocks, &indices, count, &writer) catch return error.BufferTooSmall;
    std.debug.assert(writer.end == writer.buffer.len);
    return output[0..length];
}

pub fn decode(buffer: []u8, length: usize) storage.Error!usize {
    if (length == 0 or length > buffer.len) return error.Corrupt;
    if (buffer[0] == 3) {
        if (length < biome_header_bytes + 3) return error.Corrupt;
        if (buffer[biome_header_bytes] == 3) return error.Corrupt;
        return biome_header_bytes + try decode(buffer[biome_header_bytes..], length - biome_header_bytes);
    }
    switch (buffer[0]) {
        0 => return if (length == 3) 3 else error.Corrupt,
        1 => return if (length == dense_block_bytes) dense_block_bytes else error.Corrupt,
        2 => {},
        else => return error.Corrupt,
    }
    if (length < 3) return error.Corrupt;
    const count = std.mem.readInt(u16, buffer[1..3], .little);
    if (count < 2 or count >= palette_capacity or encodedBytes(count) >= dense_block_bytes or encodedBytes(count) != length) return error.Corrupt;
    if (buffer.len < dense_block_bytes) return error.BufferTooSmall;
    // Expansion overlaps both the palette and indices in the destination.
    var encoded: [dense_block_bytes]u8 = undefined;
    @memcpy(encoded[0..length], buffer[0..length]);
    return decodeTo(encoded[0..length], buffer);
}

pub fn decodeTo(input: []const u8, output: []u8) storage.Error!usize {
    if (input.len == 0) return error.Corrupt;
    if (input[0] == 3) {
        if (input.len < biome_header_bytes + 3) return error.Corrupt;
        if (input[biome_header_bytes] == 3) return error.Corrupt;
        if (output.len < biome_header_bytes + 3) return error.BufferTooSmall;
        const length = try decodeTo(input[biome_header_bytes..], output[biome_header_bytes..]);
        @memcpy(output[0..biome_header_bytes], input[0..biome_header_bytes]);
        return biome_header_bytes + length;
    }
    switch (input[0]) {
        0 => {
            if (input.len != 3) return error.Corrupt;
            if (output.len < 3) return error.BufferTooSmall;
            @memcpy(output[0..3], input);
            return 3;
        },
        1 => {
            if (input.len != dense_block_bytes) return error.Corrupt;
            if (output.len < dense_block_bytes) return error.BufferTooSmall;
            @memcpy(output[0..dense_block_bytes], input);
            return dense_block_bytes;
        },
        2 => {},
        else => return error.Corrupt,
    }
    if (input.len < 3) return error.Corrupt;
    const count = std.mem.readInt(u16, input[1..3], .little);
    if (count < 2 or count >= palette_capacity or encodedBytes(count) >= dense_block_bytes or encodedBytes(count) != input.len) return error.Corrupt;
    if (output.len < dense_block_bytes) return error.BufferTooSmall;
    if (count == 2) {
        const first: @Vector(8, u16) = @splat(std.mem.readInt(u16, input[3..5], .little));
        const second: @Vector(8, u16) = @splat(std.mem.readInt(u16, input[5..7], .little));
        const masks: @Vector(8, u8) = .{ 1, 2, 4, 8, 16, 32, 64, 128 };
        std.debug.assert(input.len == 7 + blocks / 8);
        for (input[7..][0 .. blocks / 8], 0..) |byte, index| {
            const bytes: @Vector(8, u8) = @splat(byte);
            const states = @select(u16, (bytes & masks) != @as(@Vector(8, u8), @splat(0)), second, first);
            const encoded = if (builtin.cpu.arch.endian() == .little) states else @byteSwap(states);
            output[1 + index * 16 ..][0..16].* = @bitCast(encoded);
        }
        output[0] = 1;
        return dense_block_bytes;
    }
    var indices: [blocks]u16 = undefined;
    var reader: std.Io.Reader = .fixed(input[3 + @as(usize, count) * 2 ..]);
    bitplanes.decode(blocks, &reader, &indices, count) catch return error.Corrupt;
    for (indices, 0..) |index, i| {
        if (index >= count) return error.Corrupt;
        const state = std.mem.readInt(u16, input[3 + @as(usize, index) * 2 ..][0..2], .little);
        std.mem.writeInt(u16, output[1 + i * 2 ..][0..2], state, .little);
    }
    output[0] = 1;
    return dense_block_bytes;
}

fn validateIndices(bytes: []const u8, count: u16) storage.Error!void {
    if (std.math.isPowerOfTwo(count)) return;
    const bits = std.math.log2_int_ceil(usize, count);
    const planes = bytes[3 + @as(usize, count) * 2 ..];
    for (0..64) |word| {
        var equal: u64 = std.math.maxInt(u64);
        var greater: u64 = 0;
        var bit: usize = bits;
        while (bit != 0) {
            bit -= 1;
            const plane = std.mem.readInt(u64, planes[bit * 512 + word * 8 ..][0..8], .little);
            if (count & (@as(u16, 1) << @intCast(bit)) == 0) {
                greater |= equal & plane;
                equal &= ~plane;
            } else equal &= plane;
        }
        if (greater | equal != 0) return error.Corrupt;
    }
}

pub const Classification = union(enum) {
    unavailable,
    known: struct { common: u8, property: u8, selected: [64]u64 },
};
pub const ClassificationMode = enum { homogeneous, complete };

pub const Packed = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) storage.Error!Packed {
        if (!valid(bytes)) return error.Corrupt;
        const blocks_bytes = bytes[blockOffset(bytes)..];
        if (blocks_bytes[0] == 2) try validateIndices(blocks_bytes, std.mem.readInt(u16, blocks_bytes[1..3], .little));
        return .{ .bytes = blocks_bytes };
    }

    pub fn paletteCount(self: Packed) usize {
        return switch (self.bytes[0]) {
            0 => 1,
            2 => std.mem.readInt(u16, self.bytes[1..3], .little),
            else => 0,
        };
    }

    pub fn state(self: Packed, rank: usize) u16 {
        std.debug.assert(rank < self.paletteCount());
        const offset = if (self.bytes[0] == 0) @as(usize, 1) else 3 + rank * 2;
        return std.mem.readInt(u16, self.bytes[offset..][0..2], .little);
    }

    pub fn ranks(self: Packed, group: u7) [32]u16 {
        std.debug.assert(self.bytes[0] == 2);
        const count = self.paletteCount();
        const bits = std.math.log2_int_ceil(usize, count);
        const planes = self.bytes[3 + count * 2 ..];
        var values: @Vector(32, u16) = @splat(0);
        for (0..bits) |bit| {
            const word = std.mem.readInt(u32, planes[bit * 512 + @as(usize, group) * 4 ..][0..4], .little);
            const present: @Vector(32, bool) = @bitCast(word);
            values |= @select(u16, present, @as(@Vector(32, u16), @splat(@as(u16, 1) << @intCast(bit))), @as(@Vector(32, u16), @splat(0)));
        }
        return values;
    }

    pub fn nibbles(self: Packed, group: u6) [4]u64 {
        const count = self.paletteCount();
        std.debug.assert(self.bytes[0] == 2 and count >= 2 and count <= 16);
        const bits = std.math.log2_int_ceil(usize, count);
        const planes = self.bytes[3 + count * 2 ..];
        const Wide = @Vector(4, u64);
        var words: Wide = @splat(0);
        for (0..bits) |bit| {
            const plane = std.mem.readInt(u64, planes[bit * 512 + @as(usize, group) * 8 ..][0..8], .little);
            var spread: Wide = .{ plane & 65535, (plane >> 16) & 65535, (plane >> 32) & 65535, plane >> 48 };
            // Dilate each bit into its nibble lane without expanding palette indices.
            spread = (spread | (spread << @splat(24))) & @as(Wide, @splat(0x000000ff000000ff));
            spread = (spread | (spread << @splat(12))) & @as(Wide, @splat(0x000f000f000f000f));
            spread = (spread | (spread << @splat(6))) & @as(Wide, @splat(0x0303030303030303));
            spread = (spread | (spread << @splat(3))) & @as(Wide, @splat(0x1111111111111111));
            words |= spread << @splat(@as(u6, @intCast(bit)));
        }
        return words;
    }

    pub fn get(self: Packed, index: u12) u16 {
        if (self.bytes[0] == 0) return self.state(0);
        if (self.bytes[0] == 1) return std.mem.readInt(u16, self.bytes[1 + @as(usize, index) * 2 ..][0..2], .little);
        const count = self.paletteCount();
        const bits = std.math.log2_int_ceil(usize, count);
        const planes = self.bytes[3 + count * 2 ..];
        var rank: usize = 0;
        for (0..bits) |bit| rank |= @as(usize, (planes[bit * 512 + index / 8] >> @as(u3, @intCast(index % 8))) & 1) << @intCast(bit);
        return self.state(rank);
    }

    pub fn row(self: Packed, index: u8) [16]u16 {
        if (self.bytes[0] == 0) return @splat(self.state(0));
        if (self.bytes[0] == 1) {
            const values: @Vector(16, u16) = @bitCast(self.bytes[1 + @as(usize, index) * 32 ..][0..32].*);
            return if (builtin.cpu.arch.endian() == .little) values else @byteSwap(values);
        }
        const values = self.ranks(@intCast(index / 2));
        var states: [16]u16 = undefined;
        for (&states, 0..) |*value, lane| value.* = self.state(values[@as(usize, index % 2) * 16 + lane]);
        return states;
    }
};

/// Project a registry property directly from storage bitplanes without expanding block states.
pub fn classify(input: []const u8, properties: []const u8, selected: u8, mode: ClassificationMode) storage.Error!Classification {
    std.debug.assert(std.math.isPowerOfTwo(selected));
    if (!valid(input)) return error.Corrupt;
    const bytes = input[blockOffset(input)..];
    var result: Classification = .{ .known = .{ .common = 255, .property = selected, .selected = @splat(0) } };
    const output = &result.known;
    if (bytes[0] == 0) {
        const state = std.mem.readInt(u16, bytes[1..3], .little);
        if (state >= properties.len) return error.Corrupt;
        output.common = properties[state];
        if (properties[state] & selected != 0) output.selected = @splat(std.math.maxInt(u64));
        return result;
    }
    if (bytes[0] == 1) {
        var first: ?bool = null;
        for (0..blocks) |index| {
            const state = std.mem.readInt(u16, bytes[1 + index * 2 ..][0..2], .little);
            if (state >= properties.len) return error.Corrupt;
            output.common &= properties[state];
            const matches = properties[state] & selected != 0;
            if (mode == .homogeneous) {
                if (first) |before| {
                    if (before != matches) return .unavailable;
                } else first = matches;
            }
            if (properties[state] & selected != 0) output.selected[index / 64] |= @as(u64, 1) << @intCast(index % 64);
        }
        return result;
    }
    const count = std.mem.readInt(u16, bytes[1..3], .little);
    var flags: [palette_capacity]u8 = undefined;
    var occupied: usize = 0;
    for (flags[0..count], 0..) |*flag, index| {
        const state = std.mem.readInt(u16, bytes[3 + index * 2 ..][0..2], .little);
        if (state >= properties.len) return error.Corrupt;
        flag.* = properties[state];
        output.common &= flag.*;
        occupied += @intFromBool(flag.* & selected != 0);
        if (mode == .homogeneous and occupied != 0 and occupied != index + 1) return .unavailable;
    }
    try validateIndices(bytes, count);
    if (occupied == 0 or occupied == count) {
        if (occupied != 0) output.selected = @splat(std.math.maxInt(u64));
        return result;
    }
    const inverted = occupied > count / 2;
    if (inverted) output.selected = @splat(std.math.maxInt(u64));
    const bits = std.math.log2_int_ceil(usize, count);
    const planes = bytes[3 + @as(usize, count) * 2 ..];
    const Wide = @Vector(4, u64);
    for (flags[0..count], 0..) |flag, rank| {
        if ((flag & selected != 0) == inverted) continue;
        var word: usize = 0;
        while (word < 64) : (word += 4) {
            var equal: Wide = @splat(std.math.maxInt(u64));
            for (0..bits) |bit| {
                const raw: Wide = @bitCast(planes[bit * 512 + word * 8 ..][0..32].*);
                const values = if (builtin.cpu.arch.endian() == .little) raw else @byteSwap(raw);
                equal &= if (rank & (@as(usize, 1) << @intCast(bit)) != 0) values else ~values;
            }
            const previous: Wide = output.selected[word..][0..4].*;
            output.selected[word..][0..4].* = if (inverted) previous & ~equal else previous | equal;
        }
    }
    return result;
}

fn encodedBytes(count: u16) usize {
    if (count <= 1) return 3;
    const bits = std.math.log2_int_ceil(u16, count);
    return 3 + @as(usize, count) * 2 + blocks * @as(usize, bits) / 8;
}

pub fn blockOffset(bytes: []const u8) usize {
    std.debug.assert(bytes.len >= 3);
    return if (bytes[0] == 3) biome_header_bytes else 0;
}

pub fn valid(bytes: []const u8) bool {
    if (bytes.len < 3) return false;
    const offset: usize = if (bytes[0] == 3) biome_header_bytes else 0;
    if (bytes.len < offset + 3) return false;
    const block = bytes[offset..];
    return switch (block[0]) {
        0 => block.len == 3,
        1 => block.len == dense_block_bytes,
        2 => blk: {
            const count = std.mem.readInt(u16, block[1..3], .little);
            break :blk count >= 2 and count < palette_capacity and encodedBytes(count) < dense_block_bytes and encodedBytes(count) == block.len;
        },
        else => false,
    };
}
