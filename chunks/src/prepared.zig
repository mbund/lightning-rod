const std = @import("std");
const deflate = @import("deflate");
const assert = std.debug.assert;

/// Bits, height mode, then u16 palette length, block count, fluid count, entity count and
/// compressed word length, then the u32 word checksum. Decoded word length follows from bits.
pub const header_bytes = 16;
pub const maximum_fragment = 16384;
pub const maximum_bytes = header_bytes + Heights.encoded_maximum + 2 * 256 + 4 * 4096 + maximum_fragment;

pub const Heightmap = struct {
    pub const maximum_sections = 32;
    const maximum_bits = std.math.log2_int_ceil(u16, maximum_sections * 16 + 1);
    const minimum_per_word = 64 / @as(usize, maximum_bits);
    pub const maximum_bytes = (256 + minimum_per_word - 1) / minimum_per_word * 8;
    /// The heightmap types a chunk packet carries. Both carry the same words.
    pub const kinds = [2]u8{ 1, 4 };
    /// Both heightmaps as a chunk packet carries them after their count.
    pub const packet_bytes = kinds.len * (2 + Heightmap.maximum_bytes);
    pub const maximum_fragment = deflate.fragments.bound(packet_bytes);

    /// Each type, its word count and the words. One fragment of this codes the second copy as a
    /// match of the first, where two fragments could not refer to each other.
    pub fn packetPair(sections: usize, words: []const u8, output: *[packet_bytes]u8) []const u8 {
        const count = wordCount(sections);
        assert(words.len == count * 8 and count < 128);
        var length: usize = 0;
        for (kinds) |kind| {
            output[length..][0..2].* = .{ kind, @intCast(count) };
            @memcpy(output[length + 2 ..][0..words.len], words);
            length += 2 + words.len;
        }
        return output[0..length];
    }

    pub fn bits(sections: usize) u4 {
        assert(sections > 0 and sections <= maximum_sections);
        return @intCast(std.math.log2_int_ceil(u16, @intCast(sections * 16 + 1)));
    }

    pub fn wordCount(sections: usize) usize {
        const per_word = 64 / @as(usize, bits(sections));
        return (256 + per_word - 1) / per_word;
    }

    pub fn dependencies(sections: usize, heights: *const [256]u16) u32 {
        assert(sections > 0 and sections <= maximum_sections);
        var selected: u32 = 0;
        for (heights) |height| {
            assert(height <= sections * 16);
            if (height != 0) selected |= @as(u32, 1) << @intCast((height - 1) / 16);
        }
        return selected;
    }

    pub fn pack(sections: usize, heights: *const [256]u16, output: *[Heightmap.maximum_bytes]u8) []const u8 {
        assert(@reduce(.Max, @as(@Vector(256, u16), heights.*)) <= sections * 16);
        const width = bits(sections);
        const length = wordCount(sections) * 8;
        switch (width) {
            inline 5...10 => |count| {
                const per_word = 64 / @as(usize, count);
                for (0..length / 8) |index| {
                    var word: u64 = 0;
                    inline for (0..per_word) |lane| {
                        const cell = index * per_word + lane;
                        if (cell < 256) word |= @as(u64, heights[cell]) << (lane * count);
                    }
                    std.mem.writeInt(u64, output[index * 8 ..][0..8], word, .big);
                }
            },
            else => unreachable,
        }
        return output[0..length];
    }
};

/// The highest occupied cell plus one for each column of a section, or zero when empty.
/// Mode 1 to 17 is one constant height. Mode 18 stores height minus one as nibbles.
/// Mode 19 adds a bitmap of nonzero columns before the nibbles.
pub const Heights = struct {
    const constant_last = 17;
    const nibbles: u8 = 18;
    const sparse: u8 = 19;
    const nibble_bytes = 128;
    const mask_bytes = 32;
    pub const encoded_maximum = mask_bytes + nibble_bytes;
    mode: u8,
    bytes: []const u8,

    fn size(mode: u8) !usize {
        return switch (mode) {
            1...constant_last => 0,
            nibbles => nibble_bytes,
            sparse => mask_bytes + nibble_bytes,
            else => error.Corrupt,
        };
    }

    /// Writes the smallest encoding and returns its mode and length.
    fn encode(heights: *const [256]u8, output: *[encoded_maximum]u8) struct { mode: u8, length: usize } {
        assert(@reduce(.Max, @as(@Vector(256, u8), heights.*)) <= 16);
        if (std.mem.allEqual(u8, heights, heights[0])) return .{ .mode = heights[0] + 1, .length = 0 };
        var zeros = false;
        var mask: [mask_bytes]u8 = @splat(0);
        for (heights, 0..) |height, cell| {
            zeros = zeros or height == 0;
            mask[cell / 8] |= @as(u8, @intFromBool(height != 0)) << @intCast(cell % 8);
        }
        const prefix: usize = if (zeros) mask_bytes else 0;
        if (zeros) output[0..mask_bytes].* = mask;
        for (output[prefix..][0..nibble_bytes], 0..) |*byte, pair| {
            const low = heights[pair * 2] -| 1;
            const high = heights[pair * 2 + 1] -| 1;
            byte.* = low | high << 4;
        }
        return .{ .mode = if (zeros) sparse else nibbles, .length = prefix + nibble_bytes };
    }

    pub fn decode(self: Heights, output: *[256]u8) void {
        if (self.mode <= constant_last) {
            @memset(output, self.mode - 1);
            return;
        }
        const prefix: usize = if (self.mode == sparse) mask_bytes else 0;
        const packed_bytes: @Vector(nibble_bytes, u8) = self.bytes[prefix..][0..nibble_bytes].*;
        const low = (packed_bytes & @as(@Vector(nibble_bytes, u8), @splat(15))) + @as(@Vector(nibble_bytes, u8), @splat(1));
        const high = (packed_bytes >> @splat(4)) + @as(@Vector(nibble_bytes, u8), @splat(1));
        const even = comptime blk: {
            var lanes: [256]i32 = undefined;
            for (&lanes, 0..) |*lane, cell| lane.* = if (cell % 2 == 0) @intCast(cell / 2) else ~@as(i32, @intCast(cell / 2));
            break :blk lanes;
        };
        var heights: @Vector(256, u8) = @shuffle(u8, low, high, even);
        if (self.mode == sparse) {
            // Each cell reads its byte of the mask and tests its bit there. Bitcasting the mask to
            // a bool vector decoded differently under the LLVM and self-hosted backends.
            const cell_bytes = comptime blk: {
                var lanes: [256]i32 = undefined;
                for (&lanes, 0..) |*lane, cell| lane.* = @intCast(cell / 8);
                break :blk lanes;
            };
            const cell_bits: @Vector(256, u8) = comptime blk: {
                var bits: [256]u8 = undefined;
                for (&bits, 0..) |*bit, cell| bit.* = @as(u8, 1) << @intCast(cell % 8);
                break :blk bits;
            };
            const mask: @Vector(mask_bytes, u8) = self.bytes[0..mask_bytes].*;
            const spread = @shuffle(u8, mask, undefined, cell_bytes);
            const present = spread & cell_bits != @as(@Vector(256, u8), @splat(0));
            heights = @select(u8, present, heights, @as(@Vector(256, u8), @splat(0)));
        }
        output.* = heights;
    }
};

test "heightmaps preserve every column for every supported dimension height" {
    var random = std.Random.DefaultPrng.init(0x275e312);
    var heights: [256]u16 = undefined;
    var bytes: [Heightmap.maximum_bytes]u8 = undefined;
    for (1..Heightmap.maximum_sections + 1) |sections| for (0..32) |_| {
        for (&heights) |*height| height.* = random.random().intRangeAtMost(u16, 0, @intCast(sections * 16));
        const encoded = Heightmap.pack(sections, &heights, &bytes);
        var width: usize = 0;
        while (@as(usize, 1) << @intCast(width) <= sections * 16) : (width += 1) {}
        const per_word = 64 / width;
        const mask = (@as(u64, 1) << @intCast(width)) - 1;
        var dependencies: u32 = 0;
        for (heights, 0..) |height, index| {
            const word = std.mem.readInt(u64, encoded[index / per_word * 8 ..][0..8], .big);
            try std.testing.expectEqual(@as(u64, height), (word >> @intCast(index % per_word * width)) & mask);
            if (height != 0) dependencies |= @as(u32, 1) << @intCast((height - 1) / 16);
        }
        try std.testing.expectEqual(dependencies, Heightmap.dependencies(sections, &heights));
        for (0..encoded.len / 8) |index| {
            const used = @min(per_word, 256 - index * per_word) * width;
            if (used != 64) try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, encoded[index * 8 ..][0..8], .big) >> @intCast(used));
        }
    };
}

pub const Section = struct {
    bits: u8,
    count: u16,
    fluids: u16,
    heights: Heights,
    palette: []const u8,
    entities: []const u8,
    words: deflate.fragments.Fragment,

    pub fn state(self: Section, rank: usize) u16 {
        assert(rank < self.palette.len / 2);
        return std.mem.readInt(u16, self.palette[rank * 2 ..][0..2], .little);
    }

    pub fn materialize(self: Section, decoder: *deflate.fragments.Decoder, words: *[8192]u8, states: *[4096]u16) !void {
        const bytes = try decoder.decode(self.words, words);
        if (self.bits == 16) {
            for (states, 0..) |*value, cell| value.* = std.mem.readInt(u16, bytes[cell * 2 ..][0..2], .big);
        } else {
            const per_word: usize = 64 / @as(usize, self.bits);
            const mask = (@as(u64, 1) << @intCast(self.bits)) - 1;
            for (states, 0..) |*value, cell| {
                const word = std.mem.readInt(u64, bytes[cell / per_word * 8 ..][0..8], .big);
                const rank = (word >> @intCast(cell % per_word * self.bits)) & mask;
                if (rank >= self.palette.len / 2) return error.Corrupt;
                value.* = self.state(@intCast(rank));
            }
        }
    }

    /// Validated bytes remain borrowed and immutable until the consumer finishes.
    pub const Encoded = struct {
        bytes: []const u8,

        pub inline fn view(self: Encoded) Section {
            const data = self.bytes;
            assert(data.len >= header_bytes);
            const palette = std.mem.readInt(u16, data[2..4], .little);
            const entities = std.mem.readInt(u16, data[8..10], .little);
            const height_bytes = Heights.size(data[1]) catch unreachable;
            const palette_end = header_bytes + height_bytes + @as(usize, palette) * 2;
            const entities_end = palette_end + @as(usize, entities) * 4;
            const heights: Heights = .{ .mode = data[1], .bytes = data[header_bytes..][0..height_bytes] };
            return .{ .bits = data[0], .count = std.mem.readInt(u16, data[4..6], .little), .fluids = std.mem.readInt(u16, data[6..8], .little), .heights = heights, .palette = data[header_bytes + height_bytes .. palette_end], .entities = data[palette_end..entities_end], .words = .{ .bytes = data[entities_end..], .decoded = wordBytes(data[0]), .checksum = std.mem.readInt(u32, data[12..16], .little) } };
        }
    };

    pub fn read(bytes: []const u8) !Section {
        return (try validate(bytes)).view();
    }

    pub fn validate(bytes: []const u8) !Encoded {
        if (bytes.len < header_bytes) return error.Corrupt;
        const bits = bytes[0];
        const palette = std.mem.readInt(u16, bytes[2..4], .little);
        const count = std.mem.readInt(u16, bytes[4..6], .little);
        const fluids = std.mem.readInt(u16, bytes[6..8], .little);
        const entities = std.mem.readInt(u16, bytes[8..10], .little);
        const compressed = std.mem.readInt(u16, bytes[10..12], .little);
        if (count > 4096 or fluids > 4096 or entities > count or compressed == 0 or compressed > maximum_fragment) return error.Corrupt;
        if (bits == 16) {
            if (palette != 0) return error.Corrupt;
        } else {
            if (bits < 4 or bits > 8 or palette < 2 or palette > 256 or bits != @max(4, std.math.log2_int_ceil(usize, palette))) return error.Corrupt;
        }
        const height_bytes = try Heights.size(bytes[1]);
        const palette_end = header_bytes + height_bytes + @as(usize, palette) * 2;
        const entities_end = palette_end + @as(usize, entities) * 4;
        if (entities_end > bytes.len or bytes.len - entities_end != compressed) return error.Corrupt;
        var previous: ?u16 = null;
        for (0..entities) |index| {
            const position = std.mem.readInt(u16, bytes[palette_end + index * 4 ..][0..2], .little);
            if (position >= 4096 or (previous != null and previous.? >= position)) return error.Corrupt;
            previous = position;
        }
        return .{ .bytes = bytes };
    }
};

test "prepared terrain preserves every palette width metadata and direct states without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const baker = try Baker.init(bounded.allocator());
    defer baker.deinit();
    var decoder = try deflate.fragments.Decoder.init(bounded.allocator(), maximum_fragment);
    defer decoder.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var properties: [4096]u8 = @splat(0);
    properties[0] = 1;
    properties[1] = 2;
    properties[2] = 4;
    var output: [maximum_bytes]u8 = undefined;
    var words: [8192]u8 = undefined;
    var states: [4096]u16 = undefined;
    var random = std.Random.DefaultPrng.init(0x3c721);
    for ([_]bool{ false, true }) |layered| for ([_]u16{ 1, 2, 3, 16, 17, 32, 33, 64, 65, 128, 129, 256, 257, 4096 }) |palette| {
        for (&baker.states, 0..) |*state, cell| state.* = if (cell < palette) @intCast(cell) else random.random().uintLessThan(u16, palette);
        // Layered terrain fills most rows with one state, which the baker handles per row.
        if (layered) for (0..256) |row| {
            if (row * 16 < palette or row % 5 == 0) continue;
            @memset(baker.states[row * 16 ..][0..16], random.random().uintLessThan(u16, palette));
        };
        const result = try baker.encode(&properties, &output);
        if (palette == 1) {
            try std.testing.expectEqual(@as(u16, 0), result.uniform);
            continue;
        }
        const section = try Section.read(result.section);
        try section.materialize(&decoder, &words, &states);
        try std.testing.expectEqualSlices(u16, &baker.states, &states);
        var count: u16 = 0;
        var fluids: u16 = 0;
        var heights: [256]u8 = @splat(0);
        var entities: usize = 0;
        for (states, 0..) |state, cell| {
            if (state != 0) {
                count += 1;
                heights[cell % 256] = @intCast(cell / 256 + 1);
            }
            fluids += @intFromBool(state == 1);
            if (state == 2) {
                try std.testing.expectEqual(@as(u16, @intCast(cell)), std.mem.readInt(u16, section.entities[entities * 4 ..][0..2], .little));
                try std.testing.expectEqual(state, std.mem.readInt(u16, section.entities[entities * 4 + 2 ..][0..2], .little));
                entities += 1;
            }
        }
        try std.testing.expectEqual(count, section.count);
        try std.testing.expectEqual(fluids, section.fluids);
        try std.testing.expectEqual(entities * 4, section.entities.len);
        var decoded_heights: [256]u8 = undefined;
        section.heights.decode(&decoded_heights);
        try std.testing.expectEqualSlices(u8, &heights, &decoded_heights);
        for ([_]usize{ 0, header_bytes - 1, result.section.len / 2, result.section.len - 1 }) |length| try std.testing.expectError(error.Corrupt, Section.read(result.section[0..length]));
    };
    try std.testing.expect(!bounded.has_induced_failure);
}

pub const Baker = struct {
    pub const Result = union(enum) { uniform: u16, section: []const u8 };
    allocator: std.mem.Allocator,
    compressor: deflate.fragments.Baker,
    states: [4096]u16 = undefined,
    indices: [4096]u16 = undefined,
    palette: [4096]u16 = undefined,
    frequencies: [4096]u16 = undefined,
    order: [4096]u16 = undefined,
    ranks: []u16,
    word_bytes: [8192]u8 = undefined,
    heights: [256]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) !*Baker {
        const self = try allocator.create(Baker);
        errdefer allocator.destroy(self);
        var compressor = try deflate.fragments.Baker.init(allocator);
        errdefer compressor.deinit();
        const ranks = try allocator.alloc(u16, 65536);
        @memset(ranks, std.math.maxInt(u16));
        self.* = .{ .allocator = allocator, .compressor = compressor, .ranks = ranks };
        return self;
    }

    pub fn deinit(self: *Baker) void {
        const allocator = self.allocator;
        self.compressor.deinit();
        allocator.free(self.ranks);
        allocator.destroy(self);
    }

    /// Properties select air, fluid, and block entities with bits 0, 1, and 2.
    pub fn encode(self: *Baker, properties: []const u8, output: []u8) !Result {
        assert(output.len >= maximum_bytes);
        var palette_count: usize = 0;
        defer for (self.palette[0..palette_count]) |state| {
            self.ranks[state] = std.math.maxInt(u16);
        };
        var count: u16 = 0;
        var fluids: u16 = 0;
        var entities: usize = 0;
        @memset(output[0..header_bytes], 0);
        const heights = &self.heights;
        @memset(heights, 0);
        // Terrain rows are mostly one state, so a uniform row costs one palette lookup.
        var uniform_rows: [4]u64 = @splat(0);
        for (0..256) |row| {
            const cells: @Vector(16, u16) = self.states[row * 16 ..][0..16].*;
            const first = self.states[row * 16];
            if (@reduce(.And, cells == @as(@Vector(16, u16), @splat(first)))) {
                const rank = try self.intern(first, properties, &palette_count);
                const flags = properties[first];
                self.indices[row * 16 ..][0..16].* = @splat(rank);
                self.frequencies[rank] += 16;
                uniform_rows[row / 64] |= @as(u64, 1) << @intCast(row % 64);
                if (flags & 1 == 0) {
                    count += 16;
                    heights[row % 16 * 16 ..][0..16].* = @splat(@intCast(row / 16 + 1));
                }
                fluids += @as(u16, 16) * @intFromBool(flags & 2 != 0);
                entities += @as(usize, 16) * @intFromBool(flags & 4 != 0);
                continue;
            }
            var previous: ?u16 = null;
            var rank: u16 = undefined;
            for (self.states[row * 16 ..][0..16], self.indices[row * 16 ..][0..16], 0..) |state, *index, lane| {
                if (previous != state) {
                    rank = try self.intern(state, properties, &palette_count);
                    previous = state;
                }
                const flags = properties[state];
                index.* = rank;
                self.frequencies[rank] += 1;
                if (flags & 1 == 0) {
                    count += 1;
                    heights[row % 16 * 16 + lane] = @intCast(row / 16 + 1);
                }
                fluids += @intFromBool(flags & 2 != 0);
                entities += @intFromBool(flags & 4 != 0);
            }
        }
        assert(palette_count > 0 and entities <= count);
        if (palette_count == 1) return .{ .uniform = self.palette[0] };
        const direct = palette_count > 256;
        const bits: u8 = if (direct) 16 else @intCast(@max(4, std.math.log2_int_ceil(usize, palette_count)));
        const stored_palette = if (direct) 0 else palette_count;
        const height = Heights.encode(heights, output[header_bytes..][0..Heights.encoded_maximum]);
        const height_bytes = height.length;
        const palette_end = header_bytes + height_bytes + stored_palette * 2;
        if (!direct) {
            for (self.order[0..palette_count], 0..) |*rank, index| rank.* = @intCast(index);
            const Order = struct {
                states: []const u16,
                counts: []const u16,
                fn less(self_: @This(), a: u16, b: u16) bool {
                    return self_.counts[a] > self_.counts[b] or (self_.counts[a] == self_.counts[b] and self_.states[a] < self_.states[b]);
                }
            };
            std.sort.pdq(u16, self.order[0..palette_count], Order{ .states = self.palette[0..palette_count], .counts = self.frequencies[0..palette_count] }, Order.less);
            // The most common state takes the lowest rank. Cells map through this small
            // table instead of the state table.
            var sorted: [256]u16 = undefined;
            for (self.order[0..palette_count], 0..) |old, rank| {
                std.mem.writeInt(u16, output[header_bytes + height_bytes + rank * 2 ..][0..2], self.palette[old], .little);
                sorted[old] = @intCast(rank);
            }
            for (0..256) |row| {
                const indices = self.indices[row * 16 ..][0..16];
                if (uniform_rows[row / 64] & (@as(u64, 1) << @intCast(row % 64)) != 0) {
                    indices.* = @splat(sorted[indices[0]]);
                } else for (indices) |*index| {
                    index.* = sorted[index.*];
                }
            }
        }
        if (entities != 0) {
            var next_entity: usize = 0;
            for (self.states, 0..) |state, cell| {
                if (properties[state] & 4 == 0) continue;
                const at = palette_end + next_entity * 4;
                std.mem.writeInt(u16, output[at..][0..2], @intCast(cell), .little);
                std.mem.writeInt(u16, output[at + 2 ..][0..2], state, .little);
                next_entity += 1;
            }
            assert(next_entity == entities);
        }
        const word_bytes = self.word_bytes[0..wordBytes(bits)];
        switch (bits) {
            16 => for (self.states, 0..) |state, cell| std.mem.writeInt(u16, word_bytes[cell * 2 ..][0..2], state, .big),
            // A constant width lets each word pack without variable shifts.
            inline 4...8 => |width| {
                const per_word: usize = 64 / @as(usize, width);
                for (0..(4096 + per_word - 1) / per_word) |word| {
                    var value: u64 = 0;
                    inline for (0..per_word) |lane| {
                        const cell = word * per_word + lane;
                        if (cell < 4096) value |= @as(u64, self.indices[cell]) << @as(u6, @intCast(lane * @as(usize, width)));
                    }
                    std.mem.writeInt(u64, word_bytes[word * 8 ..][0..8], value, .big);
                }
            },
            else => unreachable,
        }
        const entities_end = palette_end + entities * 4;
        const fragment = try self.compressor.encode(word_bytes, output[entities_end..]);
        output[0] = bits;
        output[1] = height.mode;
        std.mem.writeInt(u16, output[2..4], @intCast(stored_palette), .little);
        std.mem.writeInt(u16, output[4..6], count, .little);
        std.mem.writeInt(u16, output[6..8], fluids, .little);
        std.mem.writeInt(u16, output[8..10], @intCast(entities), .little);
        assert(fragment.decoded == wordBytes(bits));
        std.mem.writeInt(u16, output[10..12], @intCast(fragment.bytes.len), .little);
        std.mem.writeInt(u32, output[12..16], fragment.checksum, .little);
        const result = output[0 .. entities_end + fragment.bytes.len];
        _ = try Section.read(result);
        return .{ .section = result };
    }

    /// The palette rank of a state, added on first sight.
    inline fn intern(self: *Baker, state: u16, properties: []const u8, palette_count: *usize) !u16 {
        if (state >= properties.len) return error.InvalidBlockState;
        if (self.ranks[state] == std.math.maxInt(u16)) {
            self.ranks[state] = @intCast(palette_count.*);
            self.palette[palette_count.*] = state;
            self.frequencies[palette_count.*] = 0;
            palette_count.* += 1;
        }
        return self.ranks[state];
    }
};

pub fn wordBytes(bits: u8) u32 {
    if (bits == 16) return 8192;
    assert(bits >= 4 and bits <= 8);
    const per_word: u32 = 64 / @as(u32, bits);
    return (4096 + per_word - 1) / per_word * 8;
}

test "sparse column heights decode every cell as encoded" {
    var random = std.Random.DefaultPrng.init(7);
    var heights: [256]u8 = undefined;
    var output: [Heights.encoded_maximum]u8 = undefined;
    var decoded: [256]u8 = undefined;
    for (0..64) |_| {
        for (&heights) |*height| height.* = if (random.random().boolean()) 0 else random.random().intRangeAtMost(u8, 1, 16);
        const encoded = Heights.encode(&heights, &output);
        (Heights{ .mode = encoded.mode, .bytes = output[0..encoded.length] }).decode(&decoded);
        try std.testing.expectEqualSlices(u8, &heights, &decoded);
    }
}
