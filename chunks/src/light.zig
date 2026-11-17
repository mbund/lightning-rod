const std = @import("std");
const records = @import("records");
const deflate = @import("deflate");
const prepared = @import("prepared.zig");
const classification = @import("classification.zig");
const assert = std.debug.assert;

pub const maximum_sections = prepared.Heightmap.maximum_sections;
pub const layer_bytes = 2048;
pub const header_bytes = 224;
pub const prefix_bytes = 44;
pub const maximum_metadata = classification.Header.maximum_size;
comptime {
    // Terrain sections carry a u16 length in frames.
    assert(prepared.maximum_bytes <= std.math.maxInt(u16));
}
pub const maximum_bytes = header_bytes + 32 + maximum_metadata + 9 * maximum_sections * 129 + maximum_sections * (2 + prepared.maximum_bytes) + 10 + prepared.Heightmap.maximum_fragment + 2 * (maximum_sections + 2) * (13 + 4096);
pub const algorithm_version: u32 = 7;
pub const dependency_batch_max = records.Table.read_batch_size / 9;
pub const frame_batch_max = records.Table.read_batch_size;
pub const cache_header_bytes = 44;
pub const maximum_read_bytes = maximum_bytes + cache_header_bytes;
pub const prefix_batch_max = records.Table.read_batch_size;

pub const Column = struct {
    world: u32,
    x: i32,
    z: i32,

    /// Patched light is the copy of light that block edits changed after its frame was
    /// baked. Only the process that wrote it can use it.
    /// Layer records hold what a layer counts in the column, stamped with its neighbourhood.
    pub const Kind = enum(u8) { revision = 0, light = 1, patched = 2, metadata = 3, layer = 4 };

    pub fn key(self: Column, kind: Kind) [13]u8 {
        var bytes: [13]u8 = undefined;
        bytes[0] = @backingInt(kind);
        std.mem.writeInt(u32, bytes[1..5], self.world, .big);
        std.mem.writeInt(i32, bytes[5..9], self.x, .big);
        std.mem.writeInt(i32, bytes[9..13], self.z, .big);
        return bytes;
    }

    pub fn neighbors(self: Column) error{Overflow}![9]Column {
        var columns: [9]Column = undefined;
        for (&columns, 0..) |*column, index| column.* = .{
            .world = self.world,
            .x = try std.math.add(i32, self.x, @as(i32, @intCast(index % 3)) - 1),
            .z = try std.math.add(i32, self.z, @as(i32, @intCast(index / 3)) - 1),
        };
        return columns;
    }

    pub fn contains(self: Column, key_bytes: []const u8, minimum: i32, count: usize) bool {
        assert(key_bytes.len == 16 and count > 0);
        if (std.mem.readInt(u32, key_bytes[0..4], .big) != self.world) return false;
        const x = std.mem.readInt(i32, key_bytes[4..8], .big);
        const z = std.mem.readInt(i32, key_bytes[8..12], .big);
        const y = std.mem.readInt(i32, key_bytes[12..16], .big);
        return @abs(@as(i64, x) - self.x) <= 1 and @abs(@as(i64, z) - self.z) <= 1 and y >= minimum and @as(i64, y) - minimum < count;
    }
};

pub const Request = struct { column: Column, minimum: i32, count: usize };
pub const Dependencies = struct { revisions: [9]u64, clean: bool };
pub const PrefixRequest = struct { column: Column, minimum: i32, count: usize, destination: []u8 };
pub const PrefixSnapshot = struct { length: ?usize, clean: bool };

/// Frames borrow bytes until the caller reuses the buffer. A complete null frame is absent.
/// Incomplete entries need another batch. The buffer must fit each frame individually.
pub const FrameBatch = struct {
    bytes: []u8,
    frames: []?[]const u8,
    complete: []bool,
    clean: []bool,
    used: usize = 0,
};

pub const Header = struct {
    rules: [32]u8,
    minimum: i32,
    count: u8,
    skylight: bool,
    coverage: u32,
    revisions: [9]u64,
    biomes: [9]u32,
    uniform: u32 = 0,
    states: [maximum_sections]u16 = @splat(0),

    pub fn revision(self: Header) u64 {
        return std.hash.Wyhash.hash(0x4c524c4947485449, std.mem.asBytes(&self.revisions));
    }
};

pub const Layer = union(enum) {
    pub const Reference = enum(u32) {
        _,

        pub fn uniform(value: u4) Reference {
            return @fromBackingInt(@intCast(value));
        }

        fn encoded(position: u32) Reference {
            assert(position >= header_bytes);
            return @fromBackingInt(@intCast(position));
        }

        pub fn level(self: Reference) ?u4 {
            return if (@backingInt(self) < 16) @intCast(@backingInt(self)) else null;
        }

        fn offset(self: Reference) u32 {
            assert(@backingInt(self) >= header_bytes);
            return @backingInt(self);
        }
    };
    uniform: u4,
    dense: *const [layer_bytes]u8,
    encoded: struct { fragment: deflate.fragments.Fragment, decoder: *deflate.fragments.Decoder },

    pub fn write(self: Layer, output: *[layer_bytes]u8) !void {
        switch (self) {
            .uniform => |level| @memset(output, @as(u8, level) * 17),
            .dense => |bytes| @memcpy(output, bytes),
            .encoded => |value| {
                _ = try value.decoder.decode(value.fragment, output);
            },
        }
    }

    pub fn nonzero(self: Layer) bool {
        return switch (self) {
            .uniform => |level| level != 0,
            .dense, .encoded => true,
        };
    }
};

pub const Biome = union(enum) {
    uniform: u16,
    dense: *const [128]u8,
    palette: Palette,

    pub const Palette = struct {
        bytes: []const u8,

        pub inline fn bits(self: Palette) u4 {
            return @intCast(self.bytes[0] - 2);
        }

        pub inline fn states(self: Palette) []const u8 {
            return self.bytes[2..][0 .. @as(usize, self.bytes[1]) * 2];
        }

        pub inline fn ranks(self: Palette) []const u8 {
            return self.bytes[2 + @as(usize, self.bytes[1]) * 2 ..];
        }

        pub inline fn row(self: Palette, index: u2) [16]u16 {
            if (self.bits() == 1) {
                const packed_row = std.mem.readInt(u16, self.ranks()[@as(usize, index) * 2 ..][0..2], .little);
                const masks: @Vector(16, u16) = comptime masks: {
                    var values: [16]u16 = undefined;
                    for (&values, 0..) |*value, bit| value.* = @as(u16, 1) << @intCast(bit);
                    break :masks values;
                };
                const selected = (@as(@Vector(16, u16), @splat(packed_row)) & masks) != @as(@Vector(16, u16), @splat(0));
                const first = std.mem.readInt(u16, self.states()[0..2], .little);
                const second = std.mem.readInt(u16, self.states()[2..4], .little);
                return @select(u16, selected, @as(@Vector(16, u16), @splat(second)), @as(@Vector(16, u16), @splat(first)));
            }
            if (self.bits() == 2) {
                const packed_row = std.mem.readInt(u32, self.ranks()[@as(usize, index) * 4 ..][0..4], .little);
                const shifts: @Vector(16, u5) = comptime shifts: {
                    var values: [16]u5 = undefined;
                    for (&values, 0..) |*value, cell| value.* = @intCast(cell * 2);
                    break :shifts values;
                };
                const ranks_: @Vector(16, u8) = @intCast((@as(@Vector(16, u32), @splat(packed_row)) >> shifts) & @as(@Vector(16, u32), @splat(3)));
                assert(@reduce(.And, ranks_ < @as(@Vector(16, u8), @splat(self.bytes[1]))));
                const first = std.mem.readInt(u16, self.states()[0..2], .little);
                var result: @Vector(16, u16) = @splat(first);
                for (1..self.bytes[1]) |rank| {
                    const state = std.mem.readInt(u16, self.states()[rank * 2 ..][0..2], .little);
                    result = @select(u16, ranks_ == @as(@Vector(16, u8), @splat(@intCast(rank))), @as(@Vector(16, u16), @splat(state)), result);
                }
                return result;
            }
            var values: [16]u16 = undefined;
            switch (self.bits()) {
                inline 1, 2, 4, 8 => |width| for (&values, 0..) |*value, cell| {
                    const bit = (@as(usize, index) * 16 + cell) * width;
                    const rank = (self.ranks()[bit / 8] >> @as(u3, @intCast(bit % 8))) & ((@as(u16, 1) << width) - 1);
                    assert(rank < self.states().len / 2);
                    value.* = std.mem.readInt(u16, self.states()[@as(usize, rank) * 2 ..][0..2], .little);
                },
                else => unreachable,
            }
            return values;
        }

        pub fn get(self: Palette, cell: u6) u16 {
            const bit = @as(usize, cell) * self.bits();
            const rank = (self.ranks()[bit / 8] >> @intCast(bit % 8)) & ((@as(u16, 1) << self.bits()) - 1);
            assert(rank < self.states().len / 2);
            return std.mem.readInt(u16, self.states()[@as(usize, rank) * 2 ..][0..2], .little);
        }
    };

    pub fn get(self: Biome, cell: u6) u16 {
        return switch (self) {
            .uniform => |value| value,
            .dense => |bytes| std.mem.readInt(u16, bytes[@as(usize, cell) * 2 ..][0..2], .little),
            .palette => |values| values.get(cell),
        };
    }
};

/// The sections heights depend on, and both heightmaps as a chunk packet carries them.
pub const Heightmap = struct { sections: u32, packet: deflate.fragments.Fragment };

pub const Prefix = struct {
    rules: [32]u8,
    minimum: i32,
    count: u8,
    metadata: ?View.Metadata,

    pub fn encodedLength(bytes: []const u8) !u16 {
        const prefix = try read(bytes);
        return @intCast(prefix_bytes + if (prefix.metadata) |metadata| 32 + metadata.bytes.len else @as(usize, 0));
    }

    pub fn revisions(bytes: []const u8) ![9]u64 {
        const offset = @as(usize, try encodedLength(bytes)) + 4;
        if (bytes.len < offset + 9 * 8) return error.Corrupt;
        var result: [9]u64 = undefined;
        for (&result, 0..) |*revision, index| revision.* = std.mem.readInt(u64, bytes[offset + index * 8 ..][0..8], .little);
        return result;
    }

    pub fn read(bytes: []const u8) !Prefix {
        if (bytes.len < 4) return error.Corrupt;
        if (!std.mem.eql(u8, bytes[0..4], "LRL8")) return error.Outdated;
        if (bytes.len < prefix_bytes or bytes[40] == 0 or bytes[40] > maximum_sections or bytes[41] > 1) return error.Corrupt;
        const length = std.mem.readInt(u16, bytes[42..44], .little);
        if (length > maximum_metadata or (length != 0 and bytes.len - prefix_bytes < 32 + @as(usize, length))) return error.Corrupt;
        return .{
            .rules = bytes[4..36].*,
            .minimum = std.mem.readInt(i32, bytes[36..40], .little),
            .count = bytes[40],
            .metadata = if (length == 0) null else .{ .identity = bytes[prefix_bytes..][0..32].*, .bytes = bytes[prefix_bytes + 32 ..][0..length] },
        };
    }
};

pub const View = struct {
    pub const Metadata = struct { identity: [32]u8, bytes: []const u8 };
    header: Header,
    layers: [2][maximum_sections + 2]Layer.Reference = undefined,
    fragment_decoder: ?*deflate.fragments.Decoder = null,
    masks: [2]u64 = .{ 0, 0 },
    bytes: []const u8 = &.{},
    biome_offsets: [9][maximum_sections]u16 = undefined,
    terrain: [maximum_sections]?prepared.Section.Encoded = @splat(null),
    heightmap: ?Heightmap = null,
    metadata: ?Metadata = null,

    pub fn layer(self: *const View, index: usize, section: usize) Layer {
        assert(index < 2 and section < @as(usize, self.header.count) + 2);
        const reference = self.layers[index][section];
        if (reference.level()) |level| return .{ .uniform = level };
        const bytes = self.bytes[reference.offset()..];
        const length = std.mem.readInt(u32, bytes[8..12], .little);
        return .{ .encoded = .{ .fragment = .{ .bytes = bytes[12..][0..length], .decoded = layer_bytes, .checksum = std.mem.readInt(u32, bytes[4..8], .little) }, .decoder = self.fragment_decoder.? } };
    }

    pub inline fn biome(self: *const View, column: usize, section: usize) ?Biome {
        assert(column < 9 and section < self.header.count);
        if (self.header.biomes[column] & (@as(u32, 1) << @intCast(section)) == 0) return null;
        const offset = self.biome_offsets[column][section];
        assert(offset < self.bytes.len);
        return switch (self.bytes[offset]) {
            0 => .{ .uniform = std.mem.readInt(u16, self.bytes[offset + 1 ..][0..2], .little) },
            1 => .{ .dense = self.bytes[offset + 1 ..][0..128] },
            3, 4, 6, 10 => |tag| palette: {
                const count = self.bytes[offset + 1];
                const bits: u4 = @intCast(tag - 2);
                break :palette .{ .palette = .{
                    .bytes = self.bytes[offset..][0 .. 2 + @as(usize, count) * 2 + @as(usize, bits) * 8],
                } };
            },
            else => unreachable,
        };
    }
};

pub const Workspace = struct {
    const Dictionary = struct { offset: u16, length: u8 };
    allocator: std.mem.Allocator,
    fragment_baker: deflate.fragments.Baker,
    fragment_decoder: deflate.fragments.Decoder,
    plane: [layer_bytes]u8 = undefined,
    terrain_written: usize = 0,
    heightmap_written: bool = false,
    header_offset: usize = prefix_bytes,
    raw: []u8,
    cursor: usize = 0,
    sections: usize = 0,
    written: usize = 0,
    biome_count: usize = 0,
    reserved: bool = false,

    dictionary: [240]Dictionary = undefined,
    buckets: [512]u16 = undefined,
    dictionary_count: usize = 0,
    reference: ?u8 = null,
    run: u8 = 0,
    run_offset: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Workspace {
        var fragment_baker = try deflate.fragments.Baker.init(allocator);
        errdefer fragment_baker.deinit();
        var fragment_decoder = try deflate.fragments.Decoder.init(allocator, prepared.maximum_fragment);
        errdefer fragment_decoder.deinit();
        const raw = try allocator.alloc(u8, maximum_read_bytes);
        errdefer allocator.free(raw);
        return .{
            .allocator = allocator,
            .fragment_baker = fragment_baker,
            .fragment_decoder = fragment_decoder,
            .raw = raw,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.fragment_baker.deinit();
        self.fragment_decoder.deinit();
        self.allocator.free(self.raw);
        self.* = undefined;
    }

    pub fn begin(self: *Workspace, header: Header) void {
        assert(header.count > 0 and header.count <= maximum_sections);
        assert(header.count == 32 or header.coverage >> @intCast(header.count) == 0);
        @memcpy(self.raw[0..4], "LRL8");
        @memcpy(self.raw[4..36], &header.rules);
        std.mem.writeInt(i32, self.raw[36..40], header.minimum, .little);
        self.raw[40] = header.count;
        self.raw[41] = @intFromBool(header.skylight);
        std.mem.writeInt(u16, self.raw[42..44], 0, .little);
        std.mem.writeInt(u32, self.raw[44..48], header.coverage, .little);
        for (header.revisions, 0..) |revision, index| std.mem.writeInt(u64, self.raw[48 + index * 8 ..][0..8], revision, .little);
        self.biome_count = 0;
        for (header.biomes, 0..) |bits, index| {
            assert(header.count == 32 or bits >> @intCast(header.count) == 0);
            std.mem.writeInt(u32, self.raw[120 + index * 4 ..][0..4], bits, .little);
            self.biome_count += @popCount(bits);
        }
        assert(header.count == 32 or header.uniform >> @intCast(header.count) == 0);
        std.mem.writeInt(u32, self.raw[156..160], header.uniform, .little);
        for (header.states, 0..) |state, index| std.mem.writeInt(u16, self.raw[160 + index * 2 ..][0..2], state, .little);
        self.header_offset = prefix_bytes;
        @memset(&self.buckets, std.math.maxInt(u16));
        self.dictionary_count = 0;
        self.reference = null;
        self.run = 0;
        self.cursor = header_bytes;
        self.sections = @as(usize, header.count) + 2;
        self.written = 0;
        self.terrain_written = 0;
        self.heightmap_written = false;
        self.reserved = false;
    }

    pub fn metadata(self: *Workspace, identity: [32]u8, bytes: []const u8) void {
        assert(self.cursor == header_bytes and bytes.len > 0 and bytes.len <= maximum_metadata);
        assert(!self.reserved and self.terrain_written == 0 and self.written == 0);
        const length = 32 + bytes.len;
        assert(self.header_offset == prefix_bytes);
        std.mem.copyBackwards(u8, self.raw[prefix_bytes + length .. header_bytes + length], self.raw[prefix_bytes..header_bytes]);
        std.mem.writeInt(u16, self.raw[42..44], @intCast(bytes.len), .little);
        @memcpy(self.raw[prefix_bytes..][0..32], &identity);
        @memcpy(self.raw[prefix_bytes + 32 ..][0..bytes.len], bytes);
        self.header_offset += length;
        self.cursor += length;
    }

    pub fn biome(self: *Workspace, values: *const [64]u16) void {
        assert(self.biome_count > 0 and self.written == 0 and !self.reserved);
        assert(self.cursor + 129 <= self.raw.len);
        var bytes: [129]u8 = undefined;
        var length: usize = 3;
        const cells: @Vector(64, u16) = values.*;
        const uniform = @reduce(.And, cells == @as(@Vector(64, u16), @splat(cells[0])));
        if (uniform) {
            bytes[0] = 0;
            std.mem.writeInt(u16, bytes[1..3], values[0], .little);
        } else {
            var palette: [64]u16 = undefined;
            var ranks: [64]u8 = undefined;
            var count: usize = 0;
            for (values, &ranks) |value, *rank| {
                const at = std.mem.indexOfScalar(u16, palette[0..count], value) orelse count;
                if (at == count) {
                    palette[count] = value;
                    count += 1;
                }
                rank.* = @intCast(at);
            }
            const minimum_bits = std.math.log2_int_ceil(usize, count);
            const bits: usize = if (minimum_bits <= 2) minimum_bits else if (minimum_bits <= 4) 4 else 8;
            length = 2 + count * 2 + bits * 8;
            if (length < bytes.len) {
                bytes[0] = @intCast(2 + bits);
                bytes[1] = @intCast(count);
                for (palette[0..count], 0..) |state, index| std.mem.writeInt(u16, bytes[2 + index * 2 ..][0..2], state, .little);
                const encoded = bytes[2 + count * 2 ..][0 .. bits * 8];
                @memset(encoded, 0);
                for (ranks, 0..) |rank, index| encoded[index * bits / 8] |= rank << @intCast(index * bits % 8);
            } else {
                bytes[0] = 1;
                for (values, 0..) |state, index| std.mem.writeInt(u16, bytes[1 + index * 2 ..][0..2], state, .little);
                length = bytes.len;
            }
        }
        var bucket: usize = @intCast(std.hash.Wyhash.hash(0, bytes[0..length]) & (self.buckets.len - 1));
        while (self.buckets[bucket] != std.math.maxInt(u16)) : (bucket = (bucket + 1) & (self.buckets.len - 1)) {
            const index = self.buckets[bucket];
            const entry = self.dictionary[index];
            if (entry.length != length or !std.mem.eql(u8, self.raw[entry.offset..][0..length], bytes[0..length])) continue;
            self.writeReference(@intCast(index));
            self.biome_count -= 1;
            return;
        }
        if (self.dictionary_count < self.dictionary.len) {
            self.buckets[bucket] = @intCast(self.dictionary_count);
            self.dictionary[self.dictionary_count] = .{ .offset = @intCast(self.cursor), .length = @intCast(length) };
            self.dictionary_count += 1;
        }
        @memcpy(self.raw[self.cursor..][0..length], bytes[0..length]);
        self.cursor += length;
        self.reference = null;
        self.run = 0;
        self.biome_count -= 1;
    }

    fn writeReference(self: *Workspace, index: u8) void {
        assert(index < self.dictionary_count and index < 240);
        if (self.reference == index and self.run != 255) {
            self.run += 1;
            if (self.run == 2) {
                self.raw[self.cursor] = 16 + index;
                self.cursor += 1;
            } else if (self.run == 3) {
                self.raw[self.run_offset] = 2;
                self.raw[self.run_offset + 1] = 3;
                self.raw[self.cursor] = index;
                self.cursor += 1;
            } else self.raw[self.run_offset + 1] = self.run;
            return;
        }
        self.reference = index;
        self.run = 1;
        self.run_offset = self.cursor;
        self.raw[self.cursor] = 16 + index;
        self.cursor += 1;
    }

    pub fn terrainSection(self: *Workspace) []u8 {
        assert(!self.reserved and self.biome_count == 0 and self.written == 0 and self.terrain_written < self.sections - 2);
        self.reserved = true;
        return self.raw[self.cursor + 2 ..][0..prepared.maximum_bytes];
    }

    pub fn commitTerrain(self: *Workspace, length: usize) void {
        assert(self.reserved and self.written == 0 and length <= prepared.maximum_bytes);
        std.mem.writeInt(u16, self.raw[self.cursor..][0..2], @intCast(length), .little);
        self.cursor += 2 + length;
        self.terrain_written += 1;
        self.reserved = false;
    }

    pub fn commitUniformTerrain(self: *Workspace, state: u16) void {
        assert(self.reserved and self.terrain_written < self.sections - 2);
        const bytes = self.raw[self.header_offset..][0 .. header_bytes - prefix_bytes];
        const mask = std.mem.readInt(u32, bytes[112..116], .little) | (@as(u32, 1) << @intCast(self.terrain_written));
        std.mem.writeInt(u32, bytes[112..116], mask, .little);
        std.mem.writeInt(u16, bytes[116 + self.terrain_written * 2 ..][0..2], state, .little);
        self.terrain_written += 1;
        self.reserved = false;
    }

    pub fn heightmap(self: *Workspace, heights: *const [256]u16) !void {
        assert(!self.reserved and self.biome_count == 0 and self.written == 0 and !self.heightmap_written);
        const count = self.sections - 2;
        assert(self.terrain_written == count);
        var words: [prepared.Heightmap.maximum_bytes]u8 = undefined;
        var pair: [prepared.Heightmap.packet_bytes]u8 = undefined;
        const bytes = prepared.Heightmap.packetPair(count, prepared.Heightmap.pack(count, heights, &words), &pair);
        const fragment = try self.fragment_baker.encode(bytes, self.raw[self.cursor + 10 ..][0..prepared.Heightmap.maximum_fragment]);
        std.mem.writeInt(u16, self.raw[self.cursor..][0..2], @intCast(fragment.bytes.len), .little);
        std.mem.writeInt(u32, self.raw[self.cursor + 2 ..][0..4], prepared.Heightmap.dependencies(count, heights), .little);
        std.mem.writeInt(u32, self.raw[self.cursor + 6 ..][0..4], fragment.checksum, .little);
        self.cursor += 10 + fragment.bytes.len;
        self.heightmap_written = true;
    }

    pub fn section(self: *Workspace) *[layer_bytes]u8 {
        assert(!self.reserved and self.biome_count == 0 and self.written < 2 * self.sections);
        if (self.terrain_written == 0) {
            const uniform = std.mem.readInt(u32, self.raw[self.header_offset + 112 ..][0..4], .little);
            for (0..self.sections - 2) |index| {
                if (uniform & (@as(u32, 1) << @intCast(index)) != 0) continue;
                @memset(self.raw[self.cursor..][0..2], 0);
                self.cursor += 2;
            }
            self.terrain_written = self.sections - 2;
        }
        assert(self.terrain_written == self.sections - 2);
        if (!self.heightmap_written) {
            @memset(self.raw[self.cursor..][0..2], 0);
            self.cursor += 2;
            self.heightmap_written = true;
        }
        self.reserved = true;
        return &self.plane;
    }

    pub fn commitSection(self: *Workspace) !void {
        assert(self.reserved);
        const first = self.plane[0];
        const uniform = first & 15 == first >> 4 and std.mem.allEqual(u8, &self.plane, first);
        self.raw[self.cursor] = if (uniform) first & 15 else 16;
        self.cursor += 1;
        if (!uniform) {
            const fragment = try self.fragment_baker.encode(&self.plane, self.raw[self.cursor + 12 ..][0..4096]);
            std.mem.writeInt(u32, self.raw[self.cursor..][0..4], fragment.decoded, .little);
            std.mem.writeInt(u32, self.raw[self.cursor + 4 ..][0..4], fragment.checksum, .little);
            std.mem.writeInt(u32, self.raw[self.cursor + 8 ..][0..4], @intCast(fragment.bytes.len), .little);
            self.cursor += 12 + fragment.bytes.len;
        }
        self.written += 1;
        self.reserved = false;
    }

    pub fn finish(self: *Workspace) ![]const u8 {
        assert(!self.reserved and self.written == 2 * self.sections and self.cursor <= maximum_bytes);
        return self.raw[0..self.cursor];
    }

    /// The returned view borrows the immutable frame until its owner reuses it.
    pub fn decode(self: *Workspace, raw: []const u8) !View {
        const prefix = try Prefix.read(raw);
        if (raw.len < header_bytes or raw.len > maximum_bytes) return error.Corrupt;
        const count = prefix.count;
        const metadata_bytes = if (prefix.metadata) |metadata_| 32 + metadata_.bytes.len else @as(usize, 0);
        if (metadata_bytes > raw.len - header_bytes) return error.Corrupt;
        const fields = raw[prefix_bytes + metadata_bytes ..][0 .. header_bytes - prefix_bytes];
        const coverage = std.mem.readInt(u32, fields[0..4], .little);
        if (count < 32 and coverage >> @intCast(count) != 0) return error.Corrupt;
        var view: View = .{ .bytes = raw, .fragment_decoder = &self.fragment_decoder, .header = .{
            .rules = prefix.rules,
            .minimum = prefix.minimum,
            .count = count,
            .skylight = raw[41] != 0,
            .coverage = coverage,
            .revisions = undefined,
            .biomes = undefined,
            .uniform = std.mem.readInt(u32, fields[112..116], .little),
            .states = undefined,
        } };
        if (count < 32 and view.header.uniform >> @intCast(count) != 0) return error.Corrupt;
        for (&view.header.states, 0..) |*state, index| state.* = std.mem.readInt(u16, fields[116 + index * 2 ..][0..2], .little);
        for (&view.header.revisions, 0..) |*revision, index| revision.* = std.mem.readInt(u64, fields[4 + index * 8 ..][0..8], .little);
        var cursor: usize = header_bytes + metadata_bytes;
        view.metadata = prefix.metadata;
        var dictionary: [240]u16 = undefined;
        var entries: usize = 0;
        var remaining: u8 = 0;
        var repeated: u16 = 0;
        for (&view.header.biomes, 0..) |*bits, column| {
            bits.* = std.mem.readInt(u32, fields[76 + column * 4 ..][0..4], .little);
            if (count < 32 and bits.* >> @intCast(count) != 0) return error.Corrupt;
            var selected = bits.*;
            while (selected != 0) {
                const section_index = @ctz(selected);
                if (remaining != 0) {
                    const contiguous: usize = @ctz(~(selected >> @as(u5, @intCast(section_index))));
                    const run = @min(remaining, contiguous);
                    @memset(view.biome_offsets[column][section_index..][0..run], repeated);
                    remaining -= @intCast(run);
                    const consumed: u32 = @truncate(((@as(u64, 1) << @intCast(run)) - 1) << @intCast(section_index));
                    selected &= ~consumed;
                    continue;
                }
                selected &= selected - 1;
                if (cursor == raw.len) return error.Corrupt;
                const offset: u16 = @intCast(cursor);
                const tag = raw[cursor];
                cursor += 1;
                if (tag >= 16 or tag == 2) {
                    const index: usize = if (tag == 2) run: {
                        if (raw.len - cursor < 2 or raw[cursor] < 3) return error.Corrupt;
                        remaining = raw[cursor] - 1;
                        const repeated_index = raw[cursor + 1];
                        cursor += 2;
                        break :run repeated_index;
                    } else tag - 16;
                    if (index >= entries) return error.Corrupt;
                    repeated = dictionary[index];
                    view.biome_offsets[column][section_index] = repeated;
                    continue;
                }
                switch (tag) {
                    0 => {
                        if (raw.len - cursor < 2) return error.Corrupt;
                        cursor += 2;
                    },
                    1 => {
                        if (raw.len - cursor < 128) return error.Corrupt;
                        cursor += 128;
                    },
                    inline 3, 4, 6, 10 => |encoding| {
                        if (cursor == raw.len) return error.Corrupt;
                        const bits_per_cell = encoding - 2;
                        const palette: usize = raw[cursor];
                        cursor += 1;
                        if (palette < 2 or palette > 64 or palette > 1 << bits_per_cell) return error.Corrupt;
                        const length = palette * 2 + bits_per_cell * 8;
                        if (length > raw.len - cursor) return error.Corrupt;
                        const ranks = raw[cursor + palette * 2 ..][0 .. bits_per_cell * 8];
                        if (palette != 1 << bits_per_cell) {
                            const values: @Vector(bits_per_cell * 8, u8) = ranks.*;
                            inline for (0..8 / bits_per_cell) |part| {
                                const indices = (values >> @as(@Vector(bits_per_cell * 8, u3), @splat(part * bits_per_cell))) & @as(@Vector(bits_per_cell * 8, u8), @splat((@as(u16, 1) << bits_per_cell) - 1));
                                if (@reduce(.Or, indices >= @as(@Vector(bits_per_cell * 8, u8), @splat(@intCast(palette))))) return error.Corrupt;
                            }
                        }
                        cursor += length;
                    },
                    else => return error.Corrupt,
                }
                if (entries < dictionary.len) {
                    dictionary[entries] = offset;
                    entries += 1;
                }
                view.biome_offsets[column][section_index] = offset;
            }
        }
        if (remaining != 0) return error.Corrupt;
        for (view.terrain[0..count], 0..) |*terrain, index| {
            if (view.header.uniform & (@as(u32, 1) << @intCast(index)) != 0) continue;
            if (raw.len - cursor < 2) return error.Corrupt;
            const length = std.mem.readInt(u16, raw[cursor..][0..2], .little);
            cursor += 2;
            if (length > raw.len - cursor) return error.Corrupt;
            if (length != 0) terrain.* = try prepared.Section.validate(raw[cursor..][0..length]);
            cursor += length;
        }
        if (raw.len - cursor < 2) return error.Corrupt;
        const heightmap_length = std.mem.readInt(u16, raw[cursor..][0..2], .little);
        cursor += 2;
        if (heightmap_length != 0) {
            if (heightmap_length > prepared.Heightmap.maximum_fragment or raw.len - cursor < 8 or heightmap_length > raw.len - cursor - 8) return error.Corrupt;
            const sections = std.mem.readInt(u32, raw[cursor..][0..4], .little);
            if (count < 32 and sections >> @intCast(count) != 0) return error.Corrupt;
            const checksum = std.mem.readInt(u32, raw[cursor + 4 ..][0..4], .little);
            cursor += 8;
            view.heightmap = .{ .sections = sections, .packet = .{ .bytes = raw[cursor..][0..heightmap_length], .decoded = @intCast(prepared.Heightmap.kinds.len * (2 + prepared.Heightmap.wordCount(count) * 8)), .checksum = checksum } };
            cursor += heightmap_length;
        }
        for (0..2) |layer| for (0..@as(usize, count) + 2) |section_index| {
            if (cursor == raw.len) return error.Corrupt;
            const tag = raw[cursor];
            cursor += 1;
            const value: Layer.Reference = if (tag < 16) .uniform(@intCast(tag)) else dense: {
                if (tag != 16 or raw.len - cursor < 12) return error.Corrupt;
                const decoded = std.mem.readInt(u32, raw[cursor..][0..4], .little);
                const length = std.mem.readInt(u32, raw[cursor + 8 ..][0..4], .little);
                const offset: u32 = @intCast(cursor);
                cursor += 12;
                if (decoded != layer_bytes or length == 0 or length > 4096 or length > raw.len - cursor) return error.Corrupt;
                cursor += length;
                break :dense .encoded(offset);
            };
            view.layers[layer][section_index] = value;
            if (tag != 0) view.masks[layer] |= @as(u64, 1) << @intCast(section_index);
        };
        if (cursor != raw.len) return error.Corrupt;
        return view;
    }
};

test "stored heightmaps hold both packet copies in one fragment, with disclosure dependencies, without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    var decoder = try deflate.fragments.Decoder.init(bounded.allocator(), prepared.Heightmap.maximum_fragment);
    defer decoder.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var heights: [256]u16 = undefined;
    var words: [prepared.Heightmap.maximum_bytes]u8 = undefined;
    var expected: [prepared.Heightmap.packet_bytes]u8 = undefined;
    var actual: [prepared.Heightmap.packet_bytes]u8 = undefined;
    var alone: [prepared.Heightmap.maximum_fragment]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x482a);
    for (1..maximum_sections + 1) |count| {
        const all: u32 = @truncate((@as(u64, 1) << @intCast(count)) - 1);
        workspace.begin(.{ .rules = @splat(0), .minimum = -4, .count = @intCast(count), .skylight = false, .coverage = all, .revisions = @splat(0), .biomes = @splat(0), .uniform = all });
        for (0..count) |_| {
            _ = workspace.terrainSection();
            workspace.commitUniformTerrain(0);
        }
        for (&heights) |*height| height.* = random.random().intRangeAtMost(u16, 0, @intCast(count * 16));
        try workspace.heightmap(&heights);
        for (0..2 * (count + 2)) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        const view = try workspace.decode(try workspace.finish());
        const heightmap = view.heightmap.?;
        try std.testing.expectEqual(prepared.Heightmap.dependencies(count, &heights), heightmap.sections);
        const packed_words = prepared.Heightmap.pack(count, &heights, &words);
        try std.testing.expectEqualSlices(u8, prepared.Heightmap.packetPair(count, packed_words, &expected), try decoder.decode(heightmap.packet, &actual));
        // The second copy is one match of the first.
        const single = try workspace.fragment_baker.encode(packed_words, &alone);
        try std.testing.expect(heightmap.packet.bytes.len <= single.bytes.len + 8);
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored lighting preserves uniform and dense planes biomes and dependency revisions without allocation" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    const buffer = try bounded.allocator().alloc(u8, workspace.raw.len);
    defer bounded.allocator().free(buffer);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var header: Header = .{ .rules = @splat(0x73), .minimum = -4, .count = 3, .skylight = true, .coverage = 7, .revisions = .{ 4, 5, 6, 7, 8, 9, 10, 11, 12 }, .biomes = .{ 1, 0, 0, 0, 4, 0, 0, 0, 0 }, .uniform = 5 };
    header.states[0] = 42;
    header.states[2] = 59999;
    workspace.begin(header);
    const cells: [64]u16 = @splat(300);
    workspace.biome(&cells);
    workspace.biome(&cells);
    for (0..10) |section_index| {
        const output = workspace.section();
        if (section_index == 2) {
            for (output, 0..) |*byte, index| byte.* = @truncate(index);
        } else @memset(output, if (section_index < 5) 0 else 255);
        try workspace.commitSection();
    }
    const frame = try workspace.finish();
    const view = try workspace.decode(frame);
    try std.testing.expectEqualDeep(header, view.header);
    try std.testing.expectEqual([2]u64{ 4, 31 }, view.masks);
    try std.testing.expect(view.biome(0, 0) != null and view.biome(4, 2) != null and view.biome(1, 0) == null);
    for (0..64) |index| try std.testing.expectEqual(@as(u16, 300), view.biome(4, 2).?.get(@intCast(index)));
    var bytes: [2048]u8 = undefined;
    try view.layer(0, 2).write(&bytes);
    for (bytes, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate(index)), byte);
    try view.layer(1, 2).write(&bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 255));
    for ([_]usize{ buffer.len, view.bytes.len }) |capacity| {
        const destination = buffer[0..capacity];
        @memcpy(destination[destination.len - frame.len ..], frame);
        const inplace = try workspace.decode(destination[destination.len - frame.len ..]);
        try std.testing.expectEqualDeep(view.header, inplace.header);
        try std.testing.expectEqual(view.masks, inplace.masks);
        for (0..2) |layer| for (0..5) |section| {
            var expected: [2048]u8 = undefined;
            try view.layer(layer, section).write(&expected);
            try inplace.layer(layer, section).write(&bytes);
            try std.testing.expectEqualSlices(u8, &expected, &bytes);
        };
        for (0..9) |column| for (0..3) |section| {
            const expected = view.biome(column, section);
            const actual = inplace.biome(column, section);
            try std.testing.expectEqual(expected == null, actual == null);
            if (expected) |biome_| for (0..64) |cell| try std.testing.expectEqual(biome_.get(@intCast(cell)), actual.?.get(@intCast(cell)));
        };
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored lighting rejects invalid dimensions truncated planes and trailing data" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    const header: Header = .{ .rules = @splat(0), .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0) };
    for (0..6) |case| {
        workspace.begin(header);
        for (0..6) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        switch (case) {
            0 => workspace.raw[40] = maximum_sections + 1,
            1 => workspace.raw[header_bytes] = 17,
            2 => workspace.cursor -= 1,
            3 => {
                workspace.raw[workspace.cursor] = 0;
                workspace.cursor += 1;
            },
            4 => @memcpy(workspace.raw[0..4], "LRL9"),
            5 => std.mem.writeInt(u32, workspace.raw[156..160], 2, .little),
            else => unreachable,
        }
        const frame = try workspace.finish();
        if (case == 4) try std.testing.expectError(error.Outdated, workspace.decode(frame)) else try std.testing.expectError(error.Corrupt, workspace.decode(frame));
    }
}

test "prepared column metadata is borrowed and bounded without changing terrain or light" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var payload: [maximum_metadata]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index * 17);
    for ([_]usize{ 1, 80, maximum_metadata }) |length| {
        workspace.begin(.{ .rules = @splat(0), .minimum = -4, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = @splat(0), .uniform = 1 });
        workspace.metadata(@splat(42), payload[0..length]);
        _ = workspace.terrainSection();
        workspace.commitUniformTerrain(0);
        for (0..6) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        const frame = try workspace.finish();
        const view = try workspace.decode(frame);
        const metadata_ = view.metadata.?;
        const prefix = try Prefix.read(frame[0 .. prefix_bytes + 32 + length]);
        try std.testing.expectEqual(view.header.rules, prefix.rules);
        try std.testing.expectEqual(view.header.minimum, prefix.minimum);
        try std.testing.expectEqual(view.header.count, prefix.count);
        try std.testing.expectEqual(metadata_.identity, prefix.metadata.?.identity);
        try std.testing.expect(prefix.metadata.?.bytes.ptr == metadata_.bytes.ptr);
        try std.testing.expectError(error.Corrupt, Prefix.read(frame[0 .. prefix_bytes + 32 + length - 1]));
        try std.testing.expectEqual(@as([32]u8, @splat(42)), metadata_.identity);
        try std.testing.expectEqualSlices(u8, payload[0..length], metadata_.bytes);
        try std.testing.expect(metadata_.bytes.ptr == frame.ptr + prefix_bytes + 32);
        try std.testing.expectEqual(@as(u16, 0), view.header.states[0]);
        for (view.layers) |layers| for (layers[0..3]) |layer| try std.testing.expectEqual(@as(u4, 0), layer.level().?);
        std.mem.writeInt(u16, workspace.raw[42..44], maximum_metadata + 1, .little);
        try std.testing.expectError(error.Corrupt, Prefix.read(frame));
        try std.testing.expectError(error.Corrupt, workspace.decode(frame));
        std.mem.writeInt(u16, workspace.raw[42..44], @intCast(length), .little);
        try std.testing.expectError(error.Corrupt, workspace.decode(frame[0 .. header_bytes + 32 + length - 1]));
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored biome dictionaries preserve sparse columns palettes and long reference runs" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    for ([_]usize{ 1, 2, 3, 4, 5, 16, 17, 32, 64, 288 }) |materials| {
        const masks: [9]u32 = @splat(std.math.maxInt(u32));
        workspace.begin(.{ .rules = @splat(0), .minimum = -4, .count = 32, .skylight = true, .coverage = std.math.maxInt(u32), .revisions = @splat(0), .biomes = masks, .uniform = std.math.maxInt(u32) });
        for (0..288) |index| {
            var cells: [64]u16 = undefined;
            for (&cells, 0..) |*cell, at| cell.* = if (materials == 288) @intCast(index * 64 + at) else @intCast(at % materials);
            workspace.biome(&cells);
        }
        for (0..68) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        const frame = try workspace.finish();
        const view = try workspace.decode(frame);
        for (0..288) |index| {
            const biome = view.biome(index / 32, index % 32).?;
            for (0..64) |at| try std.testing.expectEqual(@as(u16, @intCast(if (materials == 288) index * 64 + at else at % materials)), biome.get(@intCast(at)));
            if (biome == .palette) for (0..4) |row_index| {
                const row = biome.palette.row(@intCast(row_index));
                for (row, 0..) |value, cell| try std.testing.expectEqual(@as(u16, @intCast((row_index * 16 + cell) % materials)), value);
            };
        }
        if (materials != 288) {
            try std.testing.expect(frame.len < header_bytes + 129 + 10 + 68);
            for (header_bytes..frame.len) |length| try std.testing.expectError(error.Corrupt, workspace.decode(frame[0..length]));
        }
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored biome reference runs preserve sparse section gaps and column boundaries" {
    var bounded = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var workspace = try Workspace.init(bounded.allocator());
    defer workspace.deinit();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var random = std.Random.DefaultPrng.init(0x61b07e);
    for (0..64) |trial| {
        var masks: [9]u32 = undefined;
        for (&masks) |*mask| mask.* = if (trial == 0) std.math.maxInt(u32) else if (trial == 1) 0x55555555 else random.random().int(u32);
        workspace.begin(.{ .rules = @splat(0), .minimum = -4, .count = 32, .skylight = true, .coverage = std.math.maxInt(u32), .revisions = @splat(0), .biomes = masks, .uniform = std.math.maxInt(u32) });
        var ordinal: usize = 0;
        for (masks) |mask| for (0..@popCount(mask)) |_| {
            var cells: [64]u16 = @splat(@intCast(ordinal / 97));
            if (trial % 2 != 0) {
                for (&cells, 0..) |*value, cell| value.* += @intCast(cell % 3);
            }
            workspace.biome(&cells);
            ordinal += 1;
        };
        for (0..68) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        const view = try workspace.decode(try workspace.finish());
        ordinal = 0;
        for (masks, 0..) |mask, column| for (0..32) |section| {
            const actual = view.biome(column, section);
            if (mask & (@as(u32, 1) << @intCast(section)) == 0) {
                try std.testing.expect(actual == null);
                continue;
            }
            for (0..64) |cell| try std.testing.expectEqual(@as(u16, @intCast(ordinal / 97 + if (trial % 2 != 0) cell % 3 else 0)), actual.?.get(@intCast(cell)));
            ordinal += 1;
        };
    }
    try std.testing.expect(!bounded.has_induced_failure);
}

test "stored biome references and palette indices reject malformed input" {
    var workspace = try Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    for (0..6) |case| {
        workspace.begin(.{ .rules = @splat(0), .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = @splat(0), .biomes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0 }, .uniform = 1 });
        var cells: [64]u16 = undefined;
        for (&cells, 0..) |*cell, index| cell.* = @intCast(index % 3);
        workspace.biome(&cells);
        for (0..6) |_| {
            @memset(workspace.section(), 0);
            try workspace.commitSection();
        }
        const frame = try workspace.finish();
        switch (case) {
            0 => workspace.raw[header_bytes] = 16,
            1 => workspace.raw[header_bytes] = 2,
            2 => workspace.raw[header_bytes + 1] = 0,
            3 => workspace.raw[header_bytes + 1] = 5,
            4 => workspace.raw[header_bytes + 8] = 255,
            5 => workspace.raw[header_bytes] = 15,
            else => unreachable,
        }
        try std.testing.expectError(error.Corrupt, workspace.decode(frame));
    }
}

test "delivery identity changes when a nonmaximum neighbor stamp changes" {
    var header: Header = .{ .rules = @splat(0), .minimum = 0, .count = 1, .skylight = true, .coverage = 1, .revisions = .{ 100, 2, 3, 4, 5, 6, 7, 8, 9 }, .biomes = @splat(0) };
    const previous = header.revision();
    header.revisions[1] = 1;
    try std.testing.expect(previous != header.revision());
}
