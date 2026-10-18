const std = @import("std");
const records = @import("records");
const storage = @import("storage");

pub const blocks = 16 * 16 * 16;
pub const decoded_bytes = 1 + blocks * @sizeOf(u16);
pub const codec: records.Codec = .{ .encode = encode, .decode = decode };

const palette_capacity = 2048;
const table_capacity = 4096;
const empty = std.math.maxInt(u16);

// Tags 0 and 1 match the decoded uniform and dense representations.
// Tag 2 stores a u16 palette length, u16 states, then contiguous LSB-first indices.
pub fn encode(input: []const u8, output: []u8) storage.Error![]const u8 {
    if (input.len == 3 and input[0] == 0) return input;
    if (input.len != decoded_bytes or input[0] != 1) return error.Corrupt;
    var table: [table_capacity]u16 = @splat(empty);
    var palette: [palette_capacity]u16 = undefined;
    var indices: [blocks]u16 = undefined;
    var count: u16 = 0;
    for (&indices, 0..) |*index, i| {
        const state = std.mem.readInt(u16, input[1 + i * 2 ..][0..2], .little);
        var slot: usize = (@as(u32, state) *% 0x9e3779b9) >> 20;
        while (table[slot] != empty and palette[table[slot]] != state) slot = (slot + 1) % table_capacity;
        if (table[slot] == empty) {
            if (encodedBytes(count + 1) >= decoded_bytes) return input;
            std.debug.assert(count < palette.len);
            palette[count] = state;
            table[slot] = count;
            count += 1;
        }
        index.* = table[slot];
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
    for (palette[0..count], 0..) |state, i| std.mem.writeInt(u16, output[3 + i * 2 ..][0..2], state, .little);
    const bits: u5 = @intCast(std.math.log2_int_ceil(u16, count));
    var pending: u32 = 0;
    var pending_bits: u5 = 0;
    var at: usize = 3 + @as(usize, count) * 2;
    for (indices) |index| {
        pending |= @as(u32, index) << pending_bits;
        pending_bits += bits;
        while (pending_bits >= 8) {
            output[at] = @truncate(pending);
            at += 1;
            pending >>= 8;
            pending_bits -= 8;
        }
    }
    std.debug.assert(pending_bits == 0 and at == length);
    return output[0..length];
}

pub fn decode(buffer: []u8, length: usize) storage.Error!usize {
    if (length == 0 or length > buffer.len) return error.Corrupt;
    switch (buffer[0]) {
        0 => return if (length == 3) 3 else error.Corrupt,
        1 => return if (length == decoded_bytes) decoded_bytes else error.Corrupt,
        2 => {},
        else => return error.Corrupt,
    }
    if (length < 3) return error.Corrupt;
    const count = std.mem.readInt(u16, buffer[1..3], .little);
    if (count < 2 or count >= palette_capacity or encodedBytes(count) >= decoded_bytes or encodedBytes(count) != length) return error.Corrupt;
    if (buffer.len < decoded_bytes) return error.BufferTooSmall;
    // Expansion overlaps both the palette and indices in the destination.
    var encoded: [decoded_bytes]u8 = undefined;
    @memcpy(encoded[0..length], buffer[0..length]);
    const bits: u5 = @intCast(std.math.log2_int_ceil(u16, count));
    const mask = (@as(u32, 1) << bits) - 1;
    var pending: u32 = 0;
    var pending_bits: u5 = 0;
    var at: usize = 3 + @as(usize, count) * 2;
    for (0..blocks) |i| {
        while (pending_bits < bits) {
            pending |= @as(u32, encoded[at]) << pending_bits;
            at += 1;
            pending_bits += 8;
        }
        const index = pending & mask;
        if (index >= count) return error.Corrupt;
        const state = std.mem.readInt(u16, encoded[3 + index * 2 ..][0..2], .little);
        std.mem.writeInt(u16, buffer[1 + i * 2 ..][0..2], state, .little);
        pending >>= bits;
        pending_bits -= bits;
    }
    std.debug.assert(pending_bits == 0 and at == length);
    buffer[0] = 1;
    return decoded_bytes;
}

fn encodedBytes(count: u16) usize {
    if (count <= 1) return 3;
    const bits = std.math.log2_int_ceil(u16, count);
    return 3 + @as(usize, count) * 2 + blocks * @as(usize, bits) / 8;
}
