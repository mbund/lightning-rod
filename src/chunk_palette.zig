const std = @import("std");
const protocol_support = @import("protocol_support");
const registry = @import("registry_data");

pub const block_count = 16 * 16 * 16;
pub const maximum_indirect_palette_entries = 256;
pub const maximum_encoded_len = 2 + 1 + 2 + maximum_indirect_palette_entries * 5 + 8192;

const lookup_size = maximum_indirect_palette_entries * 2;
const empty_index = std.math.maxInt(u16);

const LookupEntry = struct {
    state: i32 = 0,
    palette_index: u16 = empty_index,
};

pub fn encode(buffer: []u8, states: *const [block_count]i32) ![]u8 {
    var palette: [maximum_indirect_palette_entries]i32 = undefined;
    var lookup = [_]LookupEntry{.{}} ** lookup_size;
    var palette_indices: [block_count]u16 = undefined;
    var palette_len: usize = 0;
    var use_global = false;
    var non_air_count: i16 = 0;

    for (states, 0..) |state, block_index| {
        if (state < 0 or state > registry.maximum_block_state) return error.InvalidBlockState;
        if (state != registry.block_air_default_state) non_air_count += 1;
        if (use_global) continue;
        if (findState(&lookup, state)) |palette_index| {
            palette_indices[block_index] = palette_index;
            continue;
        }
        if (palette_len == palette.len) {
            use_global = true;
            continue;
        }
        palette[palette_len] = state;
        insertState(&lookup, state, @intCast(palette_len));
        palette_indices[block_index] = @intCast(palette_len);
        palette_len += 1;
    }

    var rest = try protocol_support.write_i16(buffer, non_air_count);
    if (palette_len == 1 and !use_global) {
        rest = try protocol_support.write_u8(rest, 0);
        rest = try protocol_support.write_varint(rest, palette[0]);
        return rest;
    }

    const bits: u8 = if (use_global) registry.block_state_bits else @max(4, std.math.log2_int_ceil(usize, palette_len));
    rest = try protocol_support.write_u8(rest, bits);
    if (!use_global) {
        rest = try protocol_support.write_count(rest, i32, palette_len);
        for (palette[0..palette_len]) |state| rest = try protocol_support.write_varint(rest, state);
    }

    const values_per_long = 64 / @as(usize, bits);
    const long_count = std.math.divCeil(usize, block_count, values_per_long) catch unreachable;
    for (0..long_count) |long_index| {
        var word: u64 = 0;
        for (0..values_per_long) |entry_index| {
            const block_index = long_index * values_per_long + entry_index;
            if (block_index == states.len) break;
            const value: u64 = if (use_global)
                @intCast(states[block_index])
            else
                palette_indices[block_index];
            word |= value << @intCast(entry_index * bits);
        }
        rest = try protocol_support.write_i64(rest, @bitCast(word));
    }
    return rest;
}

pub fn encodeUniform(buffer: []u8, state: i32) ![]u8 {
    if (state < 0 or state > registry.maximum_block_state)
        return error.InvalidBlockState;
    const non_air_count: i16 = if (state == registry.block_air_default_state)
        0
    else
        @intCast(block_count);
    var rest = try protocol_support.write_i16(buffer, non_air_count);
    rest = try protocol_support.write_u8(rest, 0);
    return protocol_support.write_varint(rest, state);
}

pub fn encodePacked(
    buffer: []u8,
    palette: []const i32,
    source: []const u8,
    source_bits: u8,
    air_index: ?u16,
) ![]u8 {
    if (palette.len == 0 or palette.len > maximum_indirect_palette_entries)
        return error.InvalidPalette;
    if (source_bits > 8 or (palette.len == 1) != (source_bits == 0))
        return error.InvalidPalette;
    if (palette.len == 1) return encodeUniform(buffer, palette[0]);
    const bits: u8 = @max(4, std.math.log2_int_ceil(usize, palette.len));
    var rest = try protocol_support.write_i16(buffer, countNonAir(source, source_bits, air_index));
    rest = try protocol_support.write_u8(rest, bits);
    rest = try protocol_support.write_count(rest, i32, palette.len);
    for (palette) |state| {
        if (state < 0 or state > registry.maximum_block_state)
            return error.InvalidBlockState;
        rest = try protocol_support.write_varint(rest, state);
    }
    return writePackedIndices(rest, source, source_bits, bits);
}

fn countNonAir(source: []const u8, bits: u8, air_index: ?u16) i16 {
    const air = air_index orelse return block_count;
    var count: i16 = 0;
    for (0..block_count) |index|
        if (packedIndex(source, bits, index) != air) {
            count += 1;
        };
    return count;
}

fn writePackedIndices(buffer: []u8, source: []const u8, source_bits: u8, output_bits: u8) ![]u8 {
    var rest = buffer;
    const values_per_long = 64 / @as(usize, output_bits);
    const long_count = std.math.divCeil(usize, block_count, values_per_long) catch unreachable;
    for (0..long_count) |long_index| {
        var word: u64 = 0;
        for (0..values_per_long) |entry_index| {
            const index = long_index * values_per_long + entry_index;
            if (index == block_count) break;
            word |= @as(u64, packedIndex(source, source_bits, index)) << @intCast(entry_index * output_bits);
        }
        rest = try protocol_support.write_i64(rest, @bitCast(word));
    }
    return rest;
}

fn packedIndex(source: []const u8, bits: u8, index: usize) u16 {
    const bit_offset = index * bits;
    const byte_offset = bit_offset / 8;
    const shift: u4 = @intCast(bit_offset & 7);
    var encoded: u16 = source[byte_offset];
    if (shift + bits > 8) encoded |= @as(u16, source[byte_offset + 1]) << 8;
    return (encoded >> shift) & ((@as(u16, 1) << @intCast(bits)) - 1);
}

fn findState(lookup: *const [lookup_size]LookupEntry, state: i32) ?u16 {
    var probe = stateHash(state);
    for (0..lookup.len) |_| {
        const entry = lookup[probe & (lookup.len - 1)];
        if (entry.palette_index == empty_index) return null;
        if (entry.state == state) return entry.palette_index;
        probe += 1;
    }
    return null;
}

fn insertState(lookup: *[lookup_size]LookupEntry, state: i32, palette_index: u16) void {
    var probe = stateHash(state);
    for (0..lookup.len) |_| {
        const entry = &lookup[probe & (lookup.len - 1)];
        if (entry.palette_index != empty_index) {
            probe += 1;
            continue;
        }
        entry.* = .{ .state = state, .palette_index = palette_index };
        return;
    }
    unreachable;
}

fn stateHash(state: i32) usize {
    var value: u64 = @as(u32, @bitCast(state));
    value *%= 0x9e37_79b9_7f4a_7c15;
    value ^= value >> 32;
    return @intCast(value);
}

test "single state section uses the compact representation" {
    var states = [_]i32{registry.block_air_default_state} ** block_count;
    var buffer: [maximum_encoded_len]u8 = undefined;
    const rest = try encode(&buffer, &states);
    try std.testing.expectEqual(@as(usize, 4), buffer.len - rest.len);
}

test "indirect palette represents arbitrary registry states" {
    var states = [_]i32{registry.block_air_default_state} ** block_count;
    for (&states, 0..) |*state, index| state.* = @intCast(index % 200);
    var buffer: [maximum_encoded_len]u8 = undefined;
    const rest = try encode(&buffer, &states);
    try std.testing.expect(buffer.len - rest.len > 0);
    try std.testing.expectEqual(@as(u8, 8), buffer[2]);
}

test "global palette handles more than 256 distinct states" {
    var states = [_]i32{0} ** block_count;
    for (&states, 0..) |*state, index| state.* = @intCast(index % @min(@as(usize, registry.maximum_block_state + 1), 512));
    var buffer: [maximum_encoded_len]u8 = undefined;
    const rest = try encode(&buffer, &states);
    try std.testing.expect(buffer.len - rest.len > 0);
    try std.testing.expectEqual(registry.block_state_bits, buffer[2]);
}

test "resident packed palettes encode identically without expanding states" {
    const palette = [_]i32{
        registry.block_air_default_state,
        registry.block_stone_default_state,
        registry.block_dirt_default_state,
        registry.block_grass_block_default_state,
        registry.block_sand_default_state,
    };
    const source_bits = 3;
    var states: [block_count]i32 = undefined;
    var packed_indices: [(block_count * source_bits + 7) / 8]u8 = @splat(0);
    for (&states, 0..) |*state, index| {
        const palette_index: u8 = @intCast(index % palette.len);
        state.* = palette[palette_index];
        const bit_offset = index * source_bits;
        const byte_offset = bit_offset / 8;
        const shift: u3 = @intCast(bit_offset & 7);
        packed_indices[byte_offset] |= palette_index << shift;
        if (@as(u4, shift) + source_bits > 8)
            packed_indices[byte_offset + 1] |= palette_index >> @intCast(8 - @as(u4, shift));
    }
    var expanded: [maximum_encoded_len]u8 = undefined;
    var direct: [maximum_encoded_len]u8 = undefined;
    const expanded_rest = try encode(&expanded, &states);
    const direct_rest = try encodePacked(&direct, &palette, &packed_indices, source_bits, 0);
    try std.testing.expectEqualSlices(
        u8,
        expanded[0 .. expanded.len - expanded_rest.len],
        direct[0 .. direct.len - direct_rest.len],
    );
}
