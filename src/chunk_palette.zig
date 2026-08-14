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
