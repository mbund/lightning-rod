const std = @import("std");
const chunks = @import("chunks");
const assert = std.debug.assert;

pub fn encode(comptime game_data: type, comptime Registry: type, comptime write_fluid_count: bool, packet: anytype, x: i32, z: i32, sections: []const chunks.Lease, biome: i32, minimum_section: i32, skylight: bool) ![]u8 {
    if (biome < 0 or biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
    const biome_name = game_data.registry.biome_names[@intCast(biome)];
    const wire_biome = Registry.biomeId(biome_name) orelse return error.UnsupportedBiome;
    const output = packet._cursor.buffer;
    var writer: std.Io.Writer = .fixed(output);
    writer.end = output.len - packet._cursor.rest.len;
    try writer.writeInt(i32, x, .big);
    try writer.writeInt(i32, z, .big);
    const minimum_y: i16 = @intCast(minimum_section * 16);
    var heights: [256]i16 = @splat(minimum_y - 1);
    var view_storage: [24]chunks.View = undefined;
    const views = view_storage[0..sections.len];

    for (sections, views) |section, *view| view.* = section.view();

    for (views, 0..) |section, s| {
        if (section == .uniform) {
            if (section.uniform != 0) @memset(&heights, @as(i16, @intCast(s * 16 + 15)) + minimum_y);
            continue;
        }

        for (0..4096) |i| if (section.get(@intCast(i)) != 0) {
            heights[i % 256] = @as(i16, @intCast(s * 16 + i / 256)) + minimum_y;
        };
    }

    try varint(&writer, 2);

    for ([_]i32{ 1, 4 }) |kind| {
        try varint(&writer, kind);
        try varint(&writer, 37);

        for (0..37) |word| {
            var value: u64 = 0;

            for (0..7) |i| {
                const column = word * 7 + i;

                if (column < heights.len) value |= @as(u64, @intCast(heights[column] - minimum_y + 1)) << @intCast(i * 9);
            }

            try writer.writeInt(u64, value, .big);
        }
    }

    const length_offset = writer.end;
    try writer.splatByteAll(0, 3);
    var palette_indices: [1 << game_data.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16));
    var palette: [256]u16 = undefined;

    for (views) |section| {
        const first = section.get(0);
        if (first >= palette_indices.len) return error.InvalidBlockState;

        var count: u16 = 0;
        var fluid_count: u16 = 0;
        var palette_len: usize = 0;
        var direct = false;

        if (section == .uniform) {
            count = if (first != 0) 4096 else 0;
            if (write_fluid_count) fluid_count = if (game_data.registry.stateContainsFluid(first)) 4096 else 0;
            palette[0] = first;
            palette_len = 1;
        } else {
            for (0..4096) |i| {
                const state = section.get(@intCast(i));
                if (state >= palette_indices.len) return error.InvalidBlockState;
                count += @intFromBool(state != 0);
                if (write_fluid_count) fluid_count += @intFromBool(game_data.registry.stateContainsFluid(state));
                if (direct or palette_indices[state] != std.math.maxInt(u16)) continue;
                if (palette_len == palette.len) {
                    direct = true;
                    continue;
                }

                palette_indices[state] = @intCast(palette_len);
                palette[palette_len] = state;
                palette_len += 1;
            }
        }

        try writer.writeInt(u16, count, .big);
        if (write_fluid_count) try writer.writeInt(u16, fluid_count, .big);

        if (palette_len == 1 and !direct) {
            try writer.writeByte(0);
            try varint(&writer, try block(Registry, first));
        } else {
            const bits: u8 = if (direct) Registry.block_state_bits else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_len)));
            try writer.writeByte(bits);

            if (!direct) {
                try varint(&writer, @intCast(palette_len));

                for (palette[0..palette_len]) |state| try varint(&writer, try block(Registry, state));
            }

            const per_word: usize = 64 / bits;

            for (0..(4096 + per_word - 1) / per_word) |word| {
                var value: u64 = 0;

                for (0..per_word) |i| {
                    const index = word * per_word + i;

                    if (index < 4096) {
                        const state = section.get(@intCast(index));
                        const encoded: u32 = if (direct) @intCast(try block(Registry, state)) else palette_indices[state];
                        assert(direct or encoded < palette_len);
                        value |= @as(u64, encoded) << @intCast(i * bits);
                    }
                }

                try writer.writeInt(u64, value, .big);
            }
        }

        for (palette[0..palette_len]) |state| palette_indices[state] = std.math.maxInt(u16);
        try writer.writeByte(0);
        try varint(&writer, wire_biome);
    }

    const length: u32 = @intCast(writer.end - length_offset - 3);
    output[length_offset] = @as(u8, @truncate(length & 127)) | 128;
    output[length_offset + 1] = @as(u8, @truncate((length >> 7) & 127)) | 128;
    output[length_offset + 2] = @intCast(length >> 14);
    try varint(&writer, 0);
    var sky_mask: u32 = 0;
    const minimum = std.mem.min(i16, &heights);
    const maximum = std.mem.max(i16, &heights);
    const light_sections = sections.len + 2;
    const light_mask = (@as(u64, 1) << @intCast(light_sections)) - 1;

    for (0..light_sections) |section| if (skylight and (@as(i32, @intCast(section)) + minimum_section - 1) * 16 + 15 > minimum) {
        sky_mask |= @as(u32, 1) << @intCast(section);
    };

    try varint(&writer, 1);
    try writer.writeInt(u64, sky_mask, .big);
    try varint(&writer, 0);
    try varint(&writer, 1);
    try writer.writeInt(u64, (~@as(u64, sky_mask)) & light_mask, .big);
    try varint(&writer, 1);
    try writer.writeInt(u64, light_mask, .big);
    try varint(&writer, @popCount(sky_mask));

    for (0..light_sections) |section| {
        if (sky_mask & (@as(u32, 1) << @intCast(section)) == 0) continue;
        try varint(&writer, 2048);
        const light = try writer.writableSlice(2048);
        if ((@as(i32, @intCast(section)) + minimum_section - 1) * 16 > maximum) {
            @memset(light, 255);
            continue;
        }

        for (light, 0..) |*byte, i| {
            const y = (@as(i32, @intCast(section)) + minimum_section - 1) * 16 + @as(i32, @intCast(i / 128));
            byte.* = @as(u8, if (y > heights[(i * 2) % 256]) 15 else 0) | @as(u8, if (y > heights[(i * 2 + 1) % 256]) 240 else 0);
        }
    }

    try varint(&writer, 0);
    return output[0..writer.end];
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var number: u32 = @bitCast(value);

    while (number >= 128) : (number >>= 7) try writer.writeByte(@as(u8, @truncate(number & 127)) | 128);
    try writer.writeByte(@intCast(number));
}

fn block(comptime Registry: type, state: u16) !i32 {
    if (state >= Registry.canonical_block_state_to_wire.len) return error.UnsupportedBlock;
    const wire = Registry.canonical_block_state_to_wire[state];
    if (wire < 0) return error.UnsupportedBlock;
    return wire;
}
