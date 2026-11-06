const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const builtin = @import("builtin");
const chunks = @import("chunks");
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const support = @import("protocol_support");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_26_1 = @import("wire_26_1");
const lightning_rod = @import("lightning_rod");
const lighting = @import("lighting.zig");
const worlds = @import("worlds");
const assert = std.debug.assert;
const container_blocks = @import("container_blocks.zig");

pub const Workspace = struct {
    const Summary = struct {
        const State = struct {
            stamp: lighting.Stamp = .{ .generation = std.math.maxInt(u64) },
            palette_len: u16 = 0,
            count: u16 = 0,
            fluid_count: u16 = 0,
            block_entities: u16 = 0,
            direct: bool = false,
        };

        state: State = .{},
        heights: [256]u8 = undefined,
        palette: [256]u16 = undefined,
        entities: [64]u64 = undefined,

        fn reset(self: *Summary) void {
            self.state = .{};
        }
    };

    const Column = struct {
        valid: bool = false,
        stamps: [lighting.maximum_sections]lighting.Stamp = undefined,
        count: usize = 0,
        minimum_section: i32 = 0,
        heights: [256]i16 = undefined,
        heightmap: [37]u64 = undefined,
    };

    represented: [lighting.maximum_sections]lighting.Section = undefined,
    biome_padding: [lighting.maximum_sections][64]u16 = undefined,
    disclosure: u32 = std.math.maxInt(u32),
    concealment: u16 = 0,
    column: Column = .{},
    summaries: [lighting.maximum_sections]Summary = @splat(.{}),
    palette_indices: [1 << game_data.registry.block_state_bits]u16 = @splat(std.math.maxInt(u16)),
    properties: []const u8,

    pub fn init(allocator: std.mem.Allocator) !*Workspace {
        const self = try allocator.create(Workspace);
        errdefer allocator.destroy(self);
        const properties = try allocator.alloc(u8, game_data.registry.block_state_to_block.len);
        for (properties, 0..) |*value, state| value.* = @as(u8, @intFromBool(isAir(@intCast(state)))) |
            (@as(u8, @intFromBool(game_data.registry.stateContainsFluid(@intCast(state)))) << 1) |
            (@as(u8, @intFromBool(container_blocks.entityName(@intCast(state)) != null)) << 2);
        self.* = .{ .properties = properties };
        return self;
    }

    fn representation(self: *Workspace, chunk: Chunk) []const lighting.Section {
        assert(chunk.sections.len <= self.represented.len);
        const changed = self.disclosure ^ chunk.disclosure;
        const all = (@as(u32, 1) << @intCast(chunk.sections.len)) - 1;
        for (chunk.sections, 0..) |section, index| {
            if (chunk.disclosure & (@as(u32, 1) << @intCast(index)) != 0) assert(section.view != .unavailable);
        }
        const biome_disclosure = chunk.disclosure & chunk.biome_disclosure;
        if (chunk.disclosure & all == all and biome_disclosure & all == all) {
            if (changed & all != 0) {
                for (self.summaries[0..chunk.sections.len]) |*summary| summary.reset();
                self.column.valid = false;
            }
            self.disclosure = chunk.disclosure;
            self.concealment = chunk.concealment;
            return chunk.sections;
        }

        var biome_sources: u32 = 0;
        for (chunk.sections, 0..) |section, index| {
            if (section.biomes != null) biome_sources |= biome_disclosure & (@as(u32, 1) << @intCast(index));
        }
        for (chunk.sections, 0..) |section, index| {
            const visible = chunk.disclosure & (@as(u32, 1) << @intCast(index)) != 0;
            if (changed & (@as(u32, 1) << @intCast(index)) != 0 or (!visible and self.concealment != chunk.concealment)) {
                self.summaries[index].reset();
                self.column.valid = false;
            }
            self.represented[index] = section;
            if (!visible) {
                self.represented[index].view = .{ .uniform = chunk.concealment };
                self.represented[index].stamp = .{ .constant = chunk.concealment };
            }
            if (biome_disclosure & (@as(u32, 1) << @intCast(index)) == 0) {
                self.represented[index].biomes = if (chunk.biome_neighbors) |neighbors|
                    if (neighbors.project(index, &self.biome_padding[index])) &self.biome_padding[index] else null
                else
                    coverBiomes(chunk.sections, biome_sources, @intCast(index));
            }
        }
        self.disclosure = chunk.disclosure;
        self.concealment = chunk.concealment;
        return self.represented[0..chunk.sections.len];
    }

    fn prepare(self: *Workspace, sections: []const lighting.Section) !void {
        assert(sections.len <= self.summaries.len);
        for (sections, 0..) |section, index| {
            const summary = &self.summaries[index];
            if (section.stamp.constant) |state| assert(section.view == .uniform and section.view.uniform == state);
            if (std.meta.eql(summary.state.stamp, section.stamp)) continue;
            summary.reset();
            const view = section.view;
            var palette_len: u16 = 0;
            defer {
                for (summary.palette[0..palette_len]) |state| self.palette_indices[state] = std.math.maxInt(u16);
            }
            if (view == .uniform) {
                const state = view.uniform;
                if (state >= self.palette_indices.len) return error.InvalidBlockState;
                summary.palette[0] = state;
                palette_len = 1;
                const empty = isAir(state);
                summary.state.count = if (empty) 0 else 4096;
                summary.state.block_entities = if (container_blocks.entityName(state) != null) 4096 else 0;
                @memset(&summary.entities, if (summary.state.block_entities == 0) 0 else std.math.maxInt(u64));
                summary.state.fluid_count = if (game_data.registry.stateContainsFluid(state)) 4096 else 0;
                @memset(&summary.heights, if (empty) 0 else 16);
            } else if (view == .encoded and view.encoded.paletteCount() > 0 and view.encoded.paletteCount() <= summary.palette.len) {
                const packed_view = view.encoded;
                palette_len = @intCast(packed_view.paletteCount());
                var present: u8 = 0;
                for (summary.palette[0..palette_len], 0..) |*state, rank| {
                    state.* = packed_view.state(rank);
                    if (state.* >= self.properties.len) return error.InvalidBlockState;
                    present |= self.properties[state.*];
                }
                const air = try chunks.encoding.classify(packed_view.bytes, self.properties, 1, .complete);
                var empty: u16 = 0;
                for (air.known.selected) |word| empty += @popCount(word);
                summary.state.count = 4096 - empty;
                @memset(&summary.heights, 0);
                var found: [4]u64 = @splat(0);
                var y: usize = 16;
                while (y != 0) {
                    y -= 1;
                    for (0..4) |group| {
                        const occupied = ~air.known.selected[y * 4 + group];
                        var added = occupied & ~found[group];
                        found[group] |= occupied;
                        while (added != 0) {
                            const cell = @ctz(added);
                            summary.heights[group * 64 + cell] = @intCast(y + 1);
                            added &= added - 1;
                        }
                    }
                }
                inline for (.{ @as(u8, 2), @as(u8, 4) }, .{ "fluid_count", "block_entities" }) |flag, field| {
                    if (present & flag != 0) {
                        const classified = try chunks.encoding.classify(packed_view.bytes, self.properties, flag, .complete);
                        var count: u16 = 0;
                        for (classified.known.selected) |word| count += @popCount(word);
                        @field(summary.state, field) = count;
                        if (flag == 4) summary.entities = classified.known.selected;
                    }
                }
            } else {
                @memset(&summary.heights, 0);
                @memset(&summary.entities, 0);
                var count: u32 = 0;
                var fluid_count: u32 = 0;
                var block_entities: u32 = 0;
                var direct = false;
                for (0..256) |row| {
                    const states = view.row(@intCast(row));
                    for (states, 0..) |state, x| {
                        if (state >= game_data.registry.block_state_to_block.len) return error.InvalidBlockState;
                        const occupied = !isAir(state);
                        count += @intFromBool(occupied);
                        if (occupied) summary.heights[row % 16 * 16 + x] = @intCast(row / 16 + 1);
                        if (self.properties[state] & 4 != 0) {
                            const cell = row * 16 + x;
                            summary.entities[cell / 64] |= @as(u64, 1) << @intCast(cell % 64);
                            block_entities += 1;
                        }
                        fluid_count += @intFromBool(game_data.registry.stateContainsFluid(state));
                        if (direct or self.palette_indices[state] != std.math.maxInt(u16)) continue;
                        if (palette_len == summary.palette.len) {
                            direct = true;
                            continue;
                        }
                        self.palette_indices[state] = palette_len;
                        summary.palette[palette_len] = state;
                        palette_len += 1;
                    }
                }
                assert(count <= 4096 and fluid_count <= 4096 and block_entities <= 4096);
                summary.state.count = @intCast(count);
                summary.state.fluid_count = @intCast(fluid_count);
                summary.state.block_entities = @intCast(block_entities);
                summary.state.direct = direct;
            }
            summary.state.palette_len = palette_len;
            summary.state.stamp = section.stamp;
        }
    }

    fn prepareColumn(self: *Workspace, chunk: Chunk) *const Column {
        const column = &self.column;
        var matches = column.valid and column.count == chunk.sections.len and column.minimum_section == chunk.minimum_section;
        for (chunk.sections, 0..) |section, i| {
            const stamp = section.stamp;
            matches = matches and std.meta.eql(column.stamps[i], stamp);
            column.stamps[i] = stamp;
        }
        if (matches) return column;
        column.count = chunk.sections.len;
        column.minimum_section = chunk.minimum_section;
        const minimum_y: i16 = @intCast(chunk.minimum_section * 16);
        @memset(&column.heights, minimum_y - 1);
        for (chunk.sections, 0..) |section, s| {
            const view = section.view;
            if (view == .uniform) {
                if (view.uniform != 0) @memset(&column.heights, @as(i16, @intCast(s * 16 + 15)) + minimum_y);
                continue;
            }
            const summary = &self.summaries[s];
            for (summary.heights, &column.heights) |height, *height_column| {
                if (height != 0) height_column.* = @as(i16, @intCast(s * 16 + height - 1)) + minimum_y;
            }
        }
        @memset(&column.heightmap, 0);
        for (column.heights, 0..) |height, i| {
            column.heightmap[i / 7] |= @as(u64, @intCast(height - minimum_y + 1)) << @intCast((i % 7) * 9);
        }
        column.valid = true;
        return column;
    }
};

fn isAir(state: u16) bool {
    return state == game_data.registry.block_air_default_state or state == game_data.registry.block_cave_air_default_state or state == game_data.registry.block_void_air_default_state;
}

fn coverBiomes(sections: []const lighting.Section, sources: u32, index: u5) ?*const [64]u16 {
    assert(index < sections.len and sections.len <= lighting.maximum_sections);
    assert(sources & (@as(u32, 1) << index) == 0);
    if (sources == 0) return null;
    const below = sources & ((@as(u32, 1) << index) - 1);
    const above = sources & ~((@as(u32, 1) << index) - 1);
    const lower: u5 = if (below != 0) @intCast(31 - @clz(below)) else 0;
    const upper: u5 = if (above != 0) @intCast(@ctz(above)) else 0;
    const selected = if (below == 0) upper else if (above == 0 or index - lower <= upper - index) lower else upper;
    assert(sources & (@as(u32, 1) << selected) != 0);
    return sections[selected].biomes.?;
}

pub const BiomeNeighborhood = struct {
    biomes: []const ?*const [64]u16,
    count: usize,
    disclosed: [9]u32,

    pub fn first(self: *const BiomeNeighborhood) ?u16 {
        assert(self.count > 0 and self.count <= lighting.maximum_sections and self.biomes.len == 9 * self.count);
        for (self.disclosed, 0..) |mask, column| {
            if (mask != 0) return self.biomes[column * self.count + @ctz(mask)].?[0];
        }
        return null;
    }

    pub fn project(self: *const BiomeNeighborhood, section: usize, output: *[64]u16) bool {
        assert(self.count > 0 and self.count <= lighting.maximum_sections and section < self.count);
        assert(self.biomes.len == 9 * self.count);
        const Candidate = struct { cells: *const [64]u16, y: usize, distance: i32 };
        var candidates: [9][4]Candidate = undefined;
        var active: u16 = 0;
        const bit = @as(u32, 1) << @intCast(section);
        for (self.disclosed, 0..) |mask, column| {
            assert(mask >> @intCast(self.count) == 0);
            if (mask == 0) continue;
            active |= @as(u16, 1) << @intCast(column);
            const below = mask & (bit - 1);
            const above = mask & ~(bit * 2 - 1);
            const lower: usize = if (below != 0) 31 - @clz(below) else 0;
            const upper: usize = if (above != 0) @ctz(above) else 0;
            for (0..4) |y| {
                const low_distance = (@as(i32, @intCast(section)) - @as(i32, @intCast(lower))) * 4 + @as(i32, @intCast(y)) - 3;
                const high_distance = (@as(i32, @intCast(upper)) - @as(i32, @intCast(section))) * 4 - @as(i32, @intCast(y));
                const selected = if (mask & bit != 0) section else if (below == 0) upper else if (above == 0 or low_distance <= high_distance) lower else upper;
                const source_y = if (selected < section) 3 else if (selected > section) 0 else y;
                const dy = (@as(i32, @intCast(selected)) - @as(i32, @intCast(section))) * 4 + @as(i32, @intCast(source_y)) - @as(i32, @intCast(y));
                assert(mask & (@as(u32, 1) << @intCast(selected)) != 0);
                candidates[column][y] = .{ .cells = self.biomes[column * self.count + selected].?, .y = source_y, .distance = dy * dy };
            }
        }
        if (active == 0) return false;
        for (output, 0..) |*biome, index| {
            const x: i32 = @intCast(index % 4);
            const y = index / 16;
            const z: i32 = @intCast(index / 4 % 4);
            var distance: i32 = std.math.maxInt(i32);
            var pending = active;
            while (pending != 0) {
                const column = @ctz(pending);
                pending &= pending - 1;
                const dx = (@as(i32, column % 3) - 1) * 4;
                const dz = (@as(i32, column / 3) - 1) * 4;
                const source_x = std.math.clamp(x - dx, 0, 3);
                const source_z = std.math.clamp(z - dz, 0, 3);
                const candidate = candidates[column][y];
                const offset_x = dx + source_x - x;
                const offset_z = dz + source_z - z;
                const squared = offset_x * offset_x + offset_z * offset_z + candidate.distance;
                if (squared >= distance) continue;
                distance = squared;
                biome.* = candidate.cells[candidate.y * 16 + @as(usize, @intCast(source_z * 4 + source_x))];
            }
        }
        return true;
    }
};

pub const Chunk = struct {
    x: i32,
    z: i32,
    sections: []const lighting.Section,
    biome: i32,
    minimum_section: i32,
    workspace: *Workspace,
    light: lighting.Data,
    disclosure: u32 = std.math.maxInt(u32),
    biome_disclosure: u32 = std.math.maxInt(u32),
    biome_neighbors: ?*const BiomeNeighborhood = null,
    concealment: u16 = 0,
};

pub const write = .{ writeLegacy, writeFluidCount };

fn writeLegacy(packet: wire_1_21_5.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, chunk, protocol, false);
}

fn writeFluidCount(packet: wire_26_1.play.toClient.packet_map_chunk.Writer, registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol) ![]u8 {
    return encode(packet._cursor, registry, chunk, protocol, true);
}

// The schema exposes chunkData as opaque bytes, so section encoding must handle the 26.1 fluid count.
fn encode(cursor: support.cursor.State(.write), registry: packets.Registry, chunk: Chunk, protocol: *const sessions.Protocol, comptime write_fluid_count: bool) ![]u8 {
    const x = chunk.x;
    const z = chunk.z;
    const sections = chunk.workspace.representation(chunk);
    assert(chunk.light.count == sections.len + 2);
    // Retention must describe the final disclosure encoded below.
    assert((chunk.light.retained[0] | chunk.light.retained[1]) == 0 or
        chunk.light.disclosure & ~chunk.disclosure & ((@as(u32, 1) << @intCast(sections.len)) - 1) == 0);
    const biome = chunk.biome;
    if (biome < 0 or biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
    const biome_name = game_data.registry.biome_names[@intCast(biome)];
    const wire_biome = try protocol.registryId("minecraft:worldgen/biome", biome_name);
    const output = cursor.buffer;
    var writer: std.Io.Writer = .fixed(output);
    writer.end = output.len - cursor.rest.len;
    try writer.writeInt(i32, x, .big);
    try writer.writeInt(i32, z, .big);
    const workspace = chunk.workspace;
    try workspace.prepare(sections);
    var represented = chunk;
    represented.sections = sections;
    const column = workspace.prepareColumn(represented);
    try varint(&writer, 2);

    for ([_]i32{ 1, 4 }) |kind| {
        try varint(&writer, kind);
        try varint(&writer, 37);

        for (column.heightmap) |word| try writer.writeInt(u64, word, .big);
    }

    const length_offset = writer.end;
    try writer.splatByteAll(0, 3);
    const palette_indices = &workspace.palette_indices;

    for (sections, 0..) |snapshot, section_index| {
        const section = snapshot.view;
        const summary = &workspace.summaries[section_index];
        const first = section.get(0);
        const count = summary.state.count;
        const fluid_count = summary.state.fluid_count;
        const palette_len: usize = summary.state.palette_len;
        const palette = &summary.palette;
        const direct = summary.state.direct;
        for (palette[0..palette_len], 0..) |state, index| palette_indices[state] = @intCast(index);
        defer {
            for (palette[0..palette_len]) |state| palette_indices[state] = std.math.maxInt(u16);
        }

        try writer.writeInt(u16, count, .big);
        if (write_fluid_count) try writer.writeInt(u16, fluid_count, .big);

        if (palette_len == 1 and !direct) {
            try writer.writeByte(0);
            try varint(&writer, try registry.blockState(first));
        } else {
            const bits: u8 = if (direct) registry.block_state_bits else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_len)));
            try writer.writeByte(bits);

            if (!direct) {
                try varint(&writer, @intCast(palette_len));

                for (palette[0..palette_len]) |state| try varint(&writer, try registry.blockState(state));
            }

            if (section == .encoded and !direct and section.encoded.paletteCount() == palette_len) {
                switch (bits) {
                    inline 4, 5, 6, 7, 8 => |width| try writePacked(&writer, section.encoded, width),
                    else => unreachable,
                }
            } else if (bits == 4 and !direct) {
                try writePaletted4(&writer, section, palette_indices, @intCast(palette_len));
            } else {
                const per_word: usize = 64 / bits;
                for (0..(4096 + per_word - 1) / per_word) |word| {
                    var value: u64 = 0;

                    for (0..per_word) |i| {
                        const index = word * per_word + i;

                        if (index < 4096) {
                            const state = section.get(@intCast(index));
                            const encoded: u32 = if (direct) @intCast(try registry.blockState(state)) else palette_indices[state];
                            assert(direct or encoded < palette_len);
                            value |= @as(u64, encoded) << @intCast(i * bits);
                        }
                    }

                    try writer.writeInt(u64, value, .big);
                }
            }
        }

        if (snapshot.biomes) |values| {
            try writeBiomes(&writer, values, protocol);
        } else {
            try writer.writeByte(0);
            try varint(&writer, wire_biome);
        }
    }

    const length: u32 = @intCast(writer.end - length_offset - 3);
    output[length_offset] = @as(u8, @truncate(length & 127)) | 128;
    output[length_offset + 1] = @as(u8, @truncate((length >> 7) & 127)) | 128;
    output[length_offset + 2] = @intCast(length >> 14);
    var entities: usize = 0;
    for (workspace.summaries[0..sections.len]) |summary| entities += summary.state.block_entities;
    try varint(&writer, @intCast(entities));
    for (sections, 0..) |section, section_index| {
        if (workspace.summaries[section_index].state.block_entities == 0) continue;
        for (workspace.summaries[section_index].entities, 0..) |word, at| {
            var remaining = word;
            while (remaining != 0) {
                const index = at * 64 + @ctz(remaining);
                remaining &= remaining - 1;
                const name = container_blocks.entityName(section.view.get(@intCast(index))).?;
                try writer.writeByte(@intCast(((index % 16) << 4) | ((index / 16) % 16)));
                try writer.writeInt(i16, @intCast((chunk.minimum_section + @as(i32, @intCast(section_index))) * 16 + @as(i32, @intCast(index / 256))), .big);
                try varint(&writer, try protocol.registryId("minecraft:block_entity_type", name));
                try writer.writeAll(&.{ 10, 0 });
            }
        }
    }
    var light = chunk.light;
    light.disclosure &= chunk.disclosure;
    try light.write(&writer);
    return output[0..writer.end];
}

fn writePaletted4(writer: *std.Io.Writer, view: lighting.Section.View, palette: *const [1 << game_data.registry.block_state_bits]u16, count: u16) !void {
    assert(count >= 2 and count <= 16);
    const output = try writer.writableSlice(256 * 8);
    for (0..256) |row| {
        const states = view.row(@intCast(row));
        var ranks: @Vector(16, u16) = undefined;
        inline for (0..16) |lane| ranks[lane] = palette[states[lane]];
        assert(@reduce(.Max, ranks) < count);
        var word: u64 = 0;
        inline for (0..16) |lane| word |= @as(u64, ranks[lane]) << (4 * lane);
        std.mem.writeInt(u64, output[row * 8 ..][0..8], word, .big);
    }
}

fn writePacked(writer: *std.Io.Writer, view: chunks.encoding.Packed, comptime bits: u8) !void {
    if (bits == 4) {
        const output = try writer.writableSlice(2048);
        for (0..64) |group| {
            const words: @Vector(4, u64) = view.nibbles(@intCast(group));
            const wire_words = if (builtin.cpu.arch.endian() == .little) @byteSwap(words) else words;
            @memcpy(output[group * 32 ..][0..32], std.mem.asBytes(&wire_words));
        }
        return;
    }
    const per_word: usize = 64 / bits;
    const count = (4096 + per_word - 1) / per_word;
    const output = try writer.writableSlice(count * 8);
    var row: usize = 128;
    var ranks: [32]u16 = undefined;
    for (0..count) |word| {
        var value: u64 = 0;
        inline for (0..per_word) |lane| {
            const index = word * per_word + lane;
            if (index < 4096) {
                if (index / ranks.len != row) {
                    row = index / ranks.len;
                    ranks = view.ranks(@intCast(row));
                }
                value |= @as(u64, ranks[index % ranks.len]) << (lane * bits);
            }
        }
        std.mem.writeInt(u64, output[word * 8 ..][0..8], value, .big);
    }
}

fn varint(writer: *std.Io.Writer, value: i32) !void {
    var number: u32 = @bitCast(value);

    while (number >= 128) : (number >>= 7) try writer.writeByte(@as(u8, @truncate(number & 127)) | 128);
    try writer.writeByte(@intCast(number));
}

test "stored bitplanes produce protocol words without changing block states" {
    var raw: [chunks.encoding.maximum_decoded_bytes]u8 = undefined;
    var storage_bytes: [chunks.encoding.maximum_decoded_bytes]u8 = undefined;
    var actual: [8192]u8 = undefined;
    raw[0] = 1;
    inline for (.{ 4, 5, 6, 7, 8 }) |bits| {
        for ([_]usize{ (@as(usize, 1) << (bits - 1)) + 1, @as(usize, 1) << bits }) |count| {
            for (0..4096) |index| std.mem.writeInt(u16, raw[1 + index * 2 ..][0..2], @intCast((index * 31 + index / 19) % count), .little);
            const bytes = try chunks.encoding.encode(raw[0..chunks.encoding.dense_block_bytes], &storage_bytes);
            const view = try chunks.encoding.Packed.init(bytes);
            var writer: std.Io.Writer = .fixed(&actual);
            try writePacked(&writer, view, bits);
            const per_word = 64 / bits;
            for (0..4096) |index| {
                const word = std.mem.readInt(u64, actual[index / per_word * 8 ..][0..8], .big);
                const rank = (word >> @intCast(index % per_word * bits)) & ((@as(u64, 1) << bits) - 1);
                try std.testing.expectEqual(view.get(@intCast(index)), view.state(@intCast(rank)));
            }
        }
    }
}

test "four bit packet words match scalar encoding for every section layout" {
    const dense = try std.testing.allocator.alloc(u16, 4096);
    defer std.testing.allocator.free(dense);
    const strided = try std.testing.allocator.alloc(u16, 16 * 48 * 48);
    defer std.testing.allocator.free(strided);
    const palette = try std.testing.allocator.create([1 << game_data.registry.block_state_bits]u16);
    defer std.testing.allocator.destroy(palette);
    @memset(palette, std.math.maxInt(u16));
    var chunk: [8193]u8 = undefined;
    chunk[0] = 1;
    var actual: [2048]u8 = undefined;
    var expected: [2048]u8 = undefined;
    for ([_]u16{ 2, 3, 8, 16 }) |count| {
        for (0..count) |rank| palette[200 + rank * 17] = count - 1 - @as(u16, @intCast(rank));
        for (dense, 0..) |*value, index| {
            value.* = @intCast(200 + ((index * 331 + index / 17) % count) * 17);
            strided[index / 256 * 48 * 48 + index / 16 % 16 * 48 + index % 16] = value.*;
            std.mem.writeInt(u16, chunk[1 + index * 2 ..][0..2], value.*, .little);
        }
        for ([_]lighting.Section.View{ .{ .dense = dense[0..4096] }, .{ .rows = strided }, .{ .chunk = .{ .dense = chunk[1..] } }, .{ .uniform = 200 } }) |view| {
            for (0..256) |word| {
                var encoded: u64 = 0;
                for (0..16) |lane| encoded |= @as(u64, palette[view.get(@intCast(word * 16 + lane))]) << @intCast(lane * 4);
                std.mem.writeInt(u64, expected[word * 8 ..][0..8], encoded, .big);
            }
            var writer: std.Io.Writer = .fixed(&actual);
            try writePaletted4(&writer, view, palette, count);
            try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
        }
    }
}

test "biome padding preserves edges corners and vertical variation against exhaustive cell distances" {
    const count = 3;
    var values: [9][count][64]u16 = undefined;
    var sections: [9 * count]?*const [64]u16 = undefined;
    for (&values, 0..) |*column, xz| for (column, 0..) |*cells, y| {
        for (cells, 0..) |*cell, index| cell.* = @intCast(xz * 1000 + y * 100 + index);
        sections[xz * count + y] = cells;
    };
    const cases = [_][9]u32{
        .{ 0, 0, 0, 7, 0, 7, 0, 0, 0 },
        .{ 7, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 5, 0, 0, 0, 0 },
        .{ 1, 0, 4, 0, 0, 0, 0, 2, 0 },
    };
    for (cases) |disclosed| {
        const neighborhood: BiomeNeighborhood = .{ .count = count, .biomes = &sections, .disclosed = disclosed };
        var actual: [64]u16 = undefined;
        try std.testing.expect(neighborhood.project(1, &actual));
        for (actual, 0..) |biome, target| {
            const x: i32 = @intCast(target % 4);
            const y: i32 = @intCast(4 + target / 16);
            const z: i32 = @intCast(target / 4 % 4);
            var expected: ?u16 = null;
            var nearest: i32 = std.math.maxInt(i32);
            for (disclosed, 0..) |mask, column| for (0..count) |section| {
                if (mask & (@as(u32, 1) << @intCast(section)) == 0) continue;
                for (0..64) |source| {
                    const dx = (@as(i32, @intCast(column % 3)) - 1) * 4 + @as(i32, @intCast(source % 4)) - x;
                    const dy = @as(i32, @intCast(section * 4 + source / 16)) - y;
                    const dz = (@as(i32, @intCast(column / 3)) - 1) * 4 + @as(i32, @intCast(source / 4 % 4)) - z;
                    const distance = dx * dx + dy * dy + dz * dz;
                    if (distance >= nearest) continue;
                    nearest = distance;
                    expected = values[column][section][source];
                }
            };
            try std.testing.expectEqual(expected.?, biome);
        }
    }
    const empty: BiomeNeighborhood = .{ .count = count, .biomes = &sections, .disclosed = @splat(0) };
    var output: [64]u16 = @splat(65535);
    try std.testing.expect(!empty.project(1, &output));
    try std.testing.expect(empty.first() == null);
    for (output) |biome| try std.testing.expectEqual(@as(u16, 65535), biome);
}

test "concealed sections borrow the nearest disclosed biome without exposing hidden biomes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator());
    var biomes: [5][64]u16 = undefined;
    var sections: [5]lighting.Section = undefined;
    for (&sections, &biomes, 0..) |*section, *values, index| {
        @memset(values, @intCast(index));
        section.* = .{ .stamp = .{ .generation = index + 1, .constant = 1 }, .view = .{ .uniform = 1 }, .biomes = values };
    }
    var chunk: Chunk = .{ .x = 0, .z = 0, .minimum_section = -4, .sections = &sections, .biome = 0, .workspace = workspace, .light = undefined, .disclosure = 17 };
    const covered = workspace.representation(chunk);
    try workspace.prepare(covered);
    for (covered, 0..) |section, index| {
        const expected: usize = if (index <= 2) 0 else 4;
        try std.testing.expect(section.biomes.? == &biomes[expected]);
        try std.testing.expectEqual(@as(u16, if (index == 0 or index == 4) 1 else 0), section.view.get(0));
        try std.testing.expectEqual(@as(u16, if (index == 0 or index == 4) 4096 else 0), workspace.summaries[index].state.count);
    }
    chunk.disclosure = 0;
    for (workspace.representation(chunk)) |section| try std.testing.expect(section.biomes == null);
    chunk.disclosure = 31;
    for (workspace.representation(chunk), &biomes) |section, *values| try std.testing.expect(section.biomes.? == values);
    chunk.biome_disclosure = 0;
    for (workspace.representation(chunk)) |section| {
        try std.testing.expect(section.biomes == null);
        try std.testing.expectEqual(@as(u16, 1), section.view.get(0));
    }
    chunk.biome_disclosure = 16;
    for (workspace.representation(chunk)) |section| try std.testing.expect(section.biomes.? == &biomes[4]);
}

test "all vanilla air variants have empty section counts and heightmaps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const workspace = try Workspace.init(arena.allocator());
    var sections: [3]lighting.Section = undefined;
    for (&sections, [_]u16{ @intCast(game_data.registry.block_air_default_state), @intCast(game_data.registry.block_cave_air_default_state), @intCast(game_data.registry.block_void_air_default_state) }, 0..) |*section, state, index| {
        section.* = .{ .stamp = .{ .generation = index + 1 }, .view = .{ .uniform = state } };
    }
    try workspace.prepare(&sections);
    for (workspace.summaries[0..sections.len]) |summary| {
        try std.testing.expectEqual(@as(u16, 0), summary.state.count);
        for (summary.heights) |height| try std.testing.expectEqual(@as(u8, 0), height);
    }
    const states = try arena.allocator().alloc(u16, 16 * 48 * 48);
    @memset(states, @intCast(game_data.registry.block_void_air_default_state));
    sections[0].view = .{ .rows = states };
    sections[0].stamp.revision += 1;
    try workspace.prepare(&sections);
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    states[15 * 48 + 15] = @intCast(game_data.registry.block_stone_default_state);
    sections[0].stamp.revision += 1;
    try workspace.prepare(&sections);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u8, 1), workspace.summaries[0].heights[255]);
}

test "section summaries invalidate on edits and slot reuse and recover after errors" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var metric_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 48 });
    defer metric_registry.deinit();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/encoding", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const transaction = store.transaction();
    defer transaction.fail();
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 1, .cache_sections = 4 }, .{ .metrics = &metric_registry, .storage = try transaction.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
    const workspace = try Workspace.init(arena.allocator());
    const position: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const snapshot = try lighting.Workspace.init(arena.allocator(), terrain, try game_data.lighting.init(arena.allocator()));
    const world_dimension: worlds.Worlds.Dimension = .{ .name = "test:encoding", .minimum_section = 0, .section_count = 1, .skylight = true };
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 1 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u8, 16), workspace.summaries[0].heights[255]);
    try std.testing.expectEqual(@as(u16, 2), workspace.summaries[0].state.palette_len);
    var states: [258]i32 = undefined;
    for (&states, 0..) |*state, i| state.* = @intCast(i);
    const registry: packets.Registry = .{
        .entities = &.{},
        .items = &.{},
        .blocks = &.{},
        .block_states = &states,
        .block_state_bits = game_data.registry.block_state_bits,
        .sounds = &.{},
        .effects = &.{},
        .attributes = &.{},
    };
    const protocol: sessions.Protocol = .{
        .number = 0,
        .registries = &.{.{ .name = "minecraft:worldgen/biome", .entries = &.{"minecraft:plains"} }},
    };
    var column: Chunk = .{
        .x = 0,
        .z = 0,
        .sections = snapshot.sections(),
        .biome = game_data.registry.biomeId("minecraft:plains").?,
        .minimum_section = 0,
        .workspace = workspace,
        .light = snapshot.data(),
    };
    var short: [640]u8 = undefined;
    try std.testing.expectError(error.WriteFailed, encode(.init(&short), registry, column, &protocol, true));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    var reused: [32 * 1024]u8 = undefined;
    var fresh: [32 * 1024]u8 = undefined;
    inline for (.{ false, true }) |fluid_count| {
        column.workspace = workspace;
        const actual = try encode(.init(&reused), registry, column, &protocol, fluid_count);
        column.workspace = try Workspace.init(arena.allocator());
        const expected = try encode(.init(&fresh), registry, column, &protocol, fluid_count);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
    const revision = workspace.summaries[0].state.stamp;
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(revision, workspace.summaries[0].state.stamp);
    var edits: [257]chunks.BlockEdit = undefined;
    for (&edits, 0..) |*edit, i| edit.* = .{ .index = @intCast(i), .state = @intCast(i + 1) };
    try terrain.setBlocks(position, &edits);
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expect(workspace.summaries[0].state.direct);
    try std.testing.expectEqual(@as(u16, 258), workspace.summaries[0].state.count);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = std.math.maxInt(u16) }});
    try std.testing.expectError(error.InvalidEdit, prepareSnapshot(snapshot, terrain, world_dimension, 0));
    for (workspace.palette_indices) |index| try std.testing.expectEqual(std.math.maxInt(u16), index);
    try terrain.setBlocks(position, &.{.{ .index = 4095, .state = 0 }});
    try prepareSnapshot(snapshot, terrain, world_dimension, 0);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 257), workspace.summaries[0].state.count);
    column.sections = snapshot.sections();
    const changed = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, 0), changed.heights[255]);
    try std.testing.expectEqual(@as(i16, 1), changed.heights[0]);
    column.minimum_section = -4;
    const dimension = workspace.prepareColumn(column);
    try std.testing.expectEqual(@as(i16, -63), dimension.heights[0]);

    try prepareSnapshot(snapshot, terrain, world_dimension, 1);
    try workspace.prepare(snapshot.sections());
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.count);
    try std.testing.expectEqual(@as(u16, 1), workspace.summaries[0].state.palette_len);
    try std.testing.expectEqual(@as(u8, 0), workspace.summaries[0].heights[255]);
    column.sections = snapshot.sections();
    try std.testing.expectEqual(@as(i16, -65), workspace.prepareColumn(column).heights[0]);

    var concealed_sections = [_]lighting.Section{.{
        .stamp = .{ .generation = 900, .revision = 1 },
        .view = .{ .uniform = @intCast(game_data.registry.block_chest_default_state) },
    }};
    column.sections = &concealed_sections;
    column.minimum_section = 0;
    column.workspace = workspace;
    column.disclosure = 0;
    column.concealment = 1;
    const concealed = try encode(.init(&reused), registry, column, &protocol, true);
    var reader = std.Io.Reader.fixed(concealed);
    _ = try reader.take(8);
    try std.testing.expectEqual(@as(u32, 2), try readVarint(&reader));
    for (0..2) |_| {
        _ = try readVarint(&reader);
        try std.testing.expectEqual(@as(u32, 37), try readVarint(&reader));
        _ = try reader.take(37 * 8);
    }
    _ = try readVarint(&reader);
    try std.testing.expectEqual(@as(u16, 4096), try reader.takeInt(u16, .big));
    try std.testing.expectEqual(@as(u16, 0), try reader.takeInt(u16, .big));
    try std.testing.expectEqual(@as(u8, 0), try reader.takeByte());
    try std.testing.expectEqual(@as(u32, 1), try readVarint(&reader));
    try std.testing.expectEqual(@as(u8, 0), try reader.takeByte());
    _ = try readVarint(&reader);
    try std.testing.expectEqual(@as(u32, 0), try readVarint(&reader));
    for (0..2) |_| {
        try std.testing.expectEqual(@as(u32, 1), try readVarint(&reader));
        try std.testing.expectEqual(@as(u64, 0), (try reader.takeInt(u64, .big)) & 2);
    }
    try std.testing.expectEqual(@as(u16, 0), workspace.summaries[0].state.block_entities);
    column.disclosure = 1;
    const revealed = workspace.representation(column);
    try workspace.prepare(revealed);
    try std.testing.expectEqual(@as(u16, 4096), workspace.summaries[0].state.block_entities);
    concealed_sections[0].view = .{ .uniform = 1 };
    concealed_sections[0].stamp.revision += 1;
    column.light.coverage = 0;
    column.light.disclosure = 0;
    _ = try encode(.init(&reused), registry, column, &protocol, true);
}

fn prepareSnapshot(snapshot: *lighting.Workspace, terrain: *chunks.Chunks, dimension: worlds.Worlds.Dimension, x: i32) !void {
    for (0..128) |_| {
        if (try snapshot.prepare(terrain, 0, x, 0, dimension, 0)) return;
        try terrain.poll();
    }
    return error.SnapshotStalled;
}

fn writeBiomes(writer: *std.Io.Writer, values: *const [64]u16, protocol: *const sessions.Protocol) !void {
    if (std.mem.allEqual(u16, values, values[0])) {
        if (values[0] >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
        const id = try protocol.registryId("minecraft:worldgen/biome", game_data.registry.biome_names[values[0]]);
        try writer.writeByte(0);
        try varint(writer, id);
        return;
    }
    var palette: [64]u16 = undefined;
    var indices: [64]u16 = undefined;
    var count: usize = 0;
    for (values, &indices) |biome, *rank| {
        const index = std.mem.indexOfScalar(u16, palette[0..count], biome) orelse count;
        if (index == count) {
            palette[count] = biome;
            count += 1;
        }
        rank.* = @intCast(index);
    }
    var wire: [64]u32 = undefined;
    for (palette[0..count], wire[0..count]) |biome, *encoded| {
        if (biome >= game_data.registry.biome_names.len) return error.UnsupportedBiome;
        encoded.* = @intCast(try protocol.registryId("minecraft:worldgen/biome", game_data.registry.biome_names[biome]));
    }
    if (count == 1) {
        try writer.writeByte(0);
        try varint(writer, @intCast(wire[0]));
        return;
    }
    const direct = count > 8;
    const registry_count: usize = for (protocol.registries) |registry| {
        if (std.mem.eql(u8, registry.name, "minecraft:worldgen/biome")) break registry.entries.len;
    } else return error.UnsupportedBiome;
    const bits: u8 = @intCast(if (direct) @max(4, std.math.log2_int_ceil(usize, registry_count)) else std.math.log2_int_ceil(usize, count));
    try writer.writeByte(bits);
    if (!direct) {
        try varint(writer, @intCast(count));
        for (wire[0..count]) |id| try varint(writer, @intCast(id));
    }
    const per_word = 64 / @as(usize, bits);
    for (0..(64 + per_word - 1) / per_word) |word| {
        var encoded: u64 = 0;
        for (0..per_word) |offset| {
            const index = word * per_word + offset;
            if (index >= 64) break;
            const value: u64 = if (direct) wire[indices[index]] else indices[index];
            encoded |= value << @intCast(offset * bits);
        }
        try writer.writeInt(u64, encoded, .big);
    }
}

fn readVarint(reader: *std.Io.Reader) !u32 {
    var value: u32 = 0;
    for (0..5) |index| {
        const byte = try reader.takeByte();
        value |= @as(u32, byte & 127) << @intCast(index * 7);
        if (byte & 128 == 0) return value;
    }
    return error.InvalidVarint;
}
