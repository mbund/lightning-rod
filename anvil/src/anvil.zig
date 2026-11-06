const std = @import("std");
const nbt = @import("nbt");
const tests = @import("test.zig");
pub const section_bytes = 8193;

const maximum_chunk_bytes = 8 * 1024 * 1024;
pub const Property = struct { name: []const u8, value: []const u8 };

pub fn stateKey(allocator: std.mem.Allocator, name: []const u8, properties: []Property) ![]const u8 {
    std.mem.sort(Property, properties, {}, struct {
        fn less(_: void, a: Property, b: Property) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var key: std.Io.Writer.Allocating = .init(allocator);
    errdefer key.deinit();
    try key.writer.writeAll(name);
    try key.writer.writeByte(0);
    for (properties) |property| {
        try key.writer.writeAll(property.name);
        try key.writer.writeByte('=');
        try key.writer.writeAll(property.value);
        try key.writer.writeByte(0);
    }
    return key.toOwnedSlice();
}

pub fn paletteKey(allocator: std.mem.Allocator, doc: nbt.Document, entry: nbt.Node) ![]const u8 {
    const legacy_name = entry.childNamed(doc.nodes, "Name");
    const modern_name = entry.childNamed(doc.nodes, "id");
    if (legacy_name != null and modern_name != null) return error.AmbiguousBlockName;
    const name_field = if (modern_name) |value| value else legacy_name orelse return error.MissingBlockName;
    const name = try name_field.string();
    const legacy_properties = entry.childNamed(doc.nodes, "Properties");
    const modern_properties = entry.childNamed(doc.nodes, "properties");
    if (legacy_properties != null and modern_properties != null) return error.AmbiguousBlockProperties;
    var properties: [64]Property = undefined;
    var count: usize = 0;
    const properties_field = if (modern_properties != null) modern_properties else legacy_properties;
    if (properties_field) |object| {
        _ = try object.expectTag(.compound);
        var fields = object.childIterator(doc.nodes);
        while (fields.next()) |property| {
            if (count == properties.len) return error.TooManyProperties;
            properties[count] = .{ .name = property.name, .value = try property.string() };
            count += 1;
        }
    }
    return stateKey(allocator, name, properties[0..count]);
}

pub const Registry = struct {
    states: std.StringHashMap(u16),
    hash: [64]u8,

    pub fn init(allocator: std.mem.Allocator, names: []const []const u8) !Registry {
        if (names.len > 65536) return error.StateIdTooLarge;
        var result: Registry = .{ .states = std.StringHashMap(u16).init(allocator), .hash = @splat(0) };
        errdefer result.deinit();
        var digest = std.crypto.hash.sha2.Sha256.init(.{});
        for (names, 0..) |name, id| {
            digest.update(name);
            digest.update(&.{0});
            const start = std.mem.indexOfScalar(u8, name, '[') orelse name.len;
            var properties: [64]Property = undefined;
            var count: usize = 0;
            if (start != name.len) {
                if (!std.mem.endsWith(u8, name, "]")) return error.InvalidBlockState;
                var fields = std.mem.splitScalar(u8, name[start + 1 .. name.len - 1], ',');
                while (fields.next()) |field| {
                    if (count == properties.len) return error.TooManyProperties;
                    const equal = std.mem.indexOfScalar(u8, field, '=') orelse return error.InvalidBlockState;
                    properties[count] = .{ .name = field[0..equal], .value = field[equal + 1 ..] };
                    count += 1;
                }
            }
            const key = try stateKey(allocator, name[0..start], properties[0..count]);
            errdefer allocator.free(key);
            const entry = try result.states.getOrPut(key);
            if (entry.found_existing) return error.DuplicateState;
            entry.value_ptr.* = @intCast(id);
        }
        var hash: [32]u8 = undefined;
        digest.final(&hash);
        result.hash = std.fmt.bytesToHex(hash, .lower);
        return result;
    }

    pub fn deinit(self: *Registry) void {
        var keys = self.states.keyIterator();
        while (keys.next()) |key| self.states.allocator.free(key.*);
        self.states.deinit();
        self.* = undefined;
    }

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Registry {
        const bytes = try readFile(allocator, io, path, 32 * 1024 * 1024);
        defer allocator.free(bytes);
        const json = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer json.deinit();
        var states = std.StringHashMap(u16).init(allocator);
        errdefer {
            var keys = states.keyIterator();
            while (keys.next()) |key| allocator.free(key.*);
            states.deinit();
        }
        var blocks = json.value.object.iterator();
        while (blocks.next()) |block| {
            for (block.value_ptr.object.get("states").?.array.items) |state| {
                var properties: [64]Property = undefined;
                var count: usize = 0;
                if (state.object.get("properties")) |object| {
                    var iterator = object.object.iterator();
                    while (iterator.next()) |property| {
                        if (count == properties.len) return error.TooManyProperties;
                        properties[count] = .{ .name = property.key_ptr.*, .value = property.value_ptr.string };
                        count += 1;
                    }
                }
                const id = state.object.get("id").?.integer;
                if (id < 0 or id > 65535) return error.StateIdTooLarge;
                const key = try stateKey(allocator, block.key_ptr.*, properties[0..count]);
                errdefer allocator.free(key);
                const entry = try states.getOrPut(key);
                if (entry.found_existing) return error.DuplicateState;
                entry.value_ptr.* = @intCast(id);
            }
        }
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
        return .{ .states = states, .hash = std.fmt.bytesToHex(hash, .lower) };
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    region: []const u8,
    nodes: []nbt.Node,
    bytes: []u8,
    version: ?i32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, world: []const u8, version: i32) !Reader {
        var region = try std.fs.path.join(allocator, &.{ world, "dimensions/minecraft/overworld/region" });
        defer allocator.free(region);
        std.Io.Dir.cwd().access(io, region, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const fallback = try std.fs.path.join(allocator, &.{ world, "region" });
                allocator.free(region);
                region = fallback;
            },
            else => return err,
        };
        return initRegion(allocator, io, region, version);
    }

    pub fn initRegion(allocator: std.mem.Allocator, io: std.Io, region: []const u8, version: ?i32) !Reader {
        const path = try allocator.dupe(u8, region);
        errdefer allocator.free(path);
        const nodes = try allocator.alloc(nbt.Node, 131072);
        errdefer allocator.free(nodes);
        const bytes = try allocator.alloc(u8, maximum_chunk_bytes);
        return .{ .allocator = allocator, .io = io, .region = path, .nodes = nodes, .bytes = bytes, .version = version };
    }

    pub fn deinit(self: *Reader) void {
        self.allocator.free(self.region);
        self.allocator.free(self.nodes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn read(self: *Reader, x: i32, z: i32) !nbt.Document {
        var name: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "{s}/r.{d}.{d}.mca", .{ self.region, @divFloor(x, 32), @divFloor(z, 32) });
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        var location_bytes: [4]u8 = undefined;
        const index: u64 = @intCast(@mod(x, 32) + @mod(z, 32) * 32);
        if (try file.readPositionalAll(self.io, &location_bytes, index * 4) != 4) return error.TruncatedRegion;
        const location = std.mem.readInt(u32, &location_bytes, .big);
        if (location == 0) return error.ChunkNotGenerated;
        const offset = @as(u64, location >> 8) * 4096;
        if (offset < 8192 or location & 255 == 0) return error.InvalidRegionLocation;
        var header: [5]u8 = undefined;
        if (try file.readPositionalAll(self.io, &header, offset) != 5) return error.TruncatedRegion;
        const size = std.mem.readInt(u32, header[0..4], .big);
        var compressed: []u8 = undefined;
        if (header[4] & 128 != 0) {
            const external = try std.fmt.bufPrint(&name, "{s}/c.{d}.{d}.mcc", .{ self.region, x, z });
            compressed = try readFile(self.allocator, self.io, external, maximum_chunk_bytes);
        } else {
            if (size < 1 or size > (location & 255) * 4096 -| 4) return error.InvalidRegionLength;
            if (offset + 4 + size > (try file.stat(self.io)).size) return error.TruncatedRegion;
            compressed = try self.allocator.alloc(u8, size - 1);
            errdefer self.allocator.free(compressed);
            if (try file.readPositionalAll(self.io, compressed, offset + 5) != compressed.len) return error.TruncatedRegion;
        }
        defer self.allocator.free(compressed);
        var input: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var output: std.Io.Writer = .fixed(self.bytes);
        const kind = header[4] & 127;
        if (kind == 3) {
            try output.writeAll(compressed);
        } else {
            if (kind != 1 and kind != 2) return error.UnsupportedRegionCompression;
            var inflater = std.compress.flate.Decompress.init(&input, if (kind == 1) .gzip else .zlib, &window);
            _ = try inflater.reader.streamRemaining(&output);
            if (kind == 2 and std.hash.Adler32.hash(output.buffered()) != inflater.container_metadata.zlib.adler) return error.RegionChecksum;
            if (kind == 1 and (std.hash.Crc32.hash(output.buffered()) != inflater.container_metadata.gzip.crc or output.buffered().len != inflater.container_metadata.gzip.count)) return error.RegionChecksum;
            if (input.seek != compressed.len) return error.TrailingCompressedData;
        }
        var frames: [64]nbt.Frame = undefined;
        const doc = try nbt.scan_named(output.buffered(), self.nodes, &frames);
        if (doc.rest.len != 0) return error.TrailingNbt;
        return doc;
    }

    pub fn loadFile(self: *Reader, path: []const u8) !nbt.Document {
        const compressed = try readFile(self.allocator, self.io, path, maximum_chunk_bytes);
        defer self.allocator.free(compressed);
        var input: std.Io.Reader = .fixed(compressed);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var output: std.Io.Writer = .fixed(self.bytes);
        var inflater = std.compress.flate.Decompress.init(&input, .gzip, &window);
        _ = try inflater.reader.streamRemaining(&output);
        if (std.hash.Crc32.hash(output.buffered()) != inflater.container_metadata.gzip.crc or output.buffered().len != inflater.container_metadata.gzip.count) return error.RegionChecksum;
        if (input.seek != compressed.len) return error.TrailingCompressedData;
        var frames: [64]nbt.Frame = undefined;
        const doc = try nbt.scan_named(output.buffered(), self.nodes, &frames);
        if (doc.rest.len != 0) return error.TrailingNbt;
        return doc;
    }

    pub fn load(self: *Reader, x: i32, z: i32) !nbt.Document {
        const doc = try self.read(x, z);
        if (try (doc.childNamed("xPos") orelse return error.MissingCoordinates).int() != x or try (doc.childNamed("zPos") orelse return error.MissingCoordinates).int() != z) return error.WrongCoordinates;
        const version = try (doc.childNamed("DataVersion") orelse return error.MissingVersion).int();
        if (self.version) |expected| if (version != expected) return error.WrongWorldVersion;
        const status = try (doc.childNamed("Status") orelse return error.MissingStatus).string();
        if (!std.mem.eql(u8, status, "minecraft:full") and !std.mem.eql(u8, status, "full")) return error.ChunkNotGenerated;
        return doc;
    }
};

pub fn section(allocator: std.mem.Allocator, registry: *const Registry, doc: nbt.Document, node: ?nbt.Node, output: *[section_bytes]u8) ![]const u8 {
    const air = registry.states.get("minecraft:air\x00") orelse return error.MissingAir;
    const block_states = if (node) |value| value.childNamed(doc.nodes, "block_states") else null;
    if (block_states == null) {
        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], air, .little);
        return output[0..3];
    }
    const palette_node = block_states.?.childNamed(doc.nodes, "palette") orelse return error.MissingPalette;
    if (palette_node.child_count == 0 or palette_node.child_count > 4096) return error.InvalidPalette;
    var palette: [4096]u16 = undefined;
    var iterator = palette_node.childIterator(doc.nodes);
    var count: usize = 0;
    while (iterator.next()) |entry| {
        const key = try paletteKey(allocator, doc, entry);
        defer allocator.free(key);
        palette[count] = registry.states.get(key) orelse return error.UnknownBlockState;
        count += 1;
    }
    if (count == 1) {
        output[0] = 0;
        std.mem.writeInt(u16, output[1..3], palette[0], .little);
        return output[0..3];
    }
    const data = try (block_states.?.childNamed(doc.nodes, "data") orelse return error.MissingBlockData).longArray();
    const bits: u6 = @intCast(@max(4, std.math.log2_int_ceil(usize, count)));
    const per_long = 64 / @as(usize, bits);
    if (data.len() != std.math.divCeil(usize, 4096, per_long) catch unreachable) return error.InvalidBlockData;
    const mask = (@as(u64, 1) << bits) - 1;
    output[0] = 1;
    var uniform = true;
    for (0..4096) |at| {
        const word: u64 = @bitCast(data.get(at / per_long));
        const index = (word >> @as(u6, @intCast(at % per_long * bits))) & mask;
        if (index >= count) return error.InvalidPaletteIndex;
        const state = palette[index];
        uniform = uniform and state == palette[0];
        std.mem.writeInt(u16, output[1 + at * 2 ..][0..2], state, .little);
    }
    if (uniform) {
        output[0] = 0;
        return output[0..3];
    }
    return output;
}

pub fn biomes(doc: nbt.Document, node: ?nbt.Node, names: []const []const u8, output: *[64]u16) !bool {
    const source = if (node) |section_node| section_node.childNamed(doc.nodes, "biomes") else null;
    const value = source orelse return false;
    const palette_node = value.childNamed(doc.nodes, "palette") orelse return error.MissingBiomePalette;
    _ = try palette_node.expectTag(.list);
    if (palette_node.child_count == 0 or palette_node.child_count > 64) return error.InvalidBiomePalette;
    var palette: [64]u16 = undefined;
    var count: usize = 0;
    var iterator = palette_node.childIterator(doc.nodes);
    while (iterator.next()) |entry| {
        const name = try entry.string();
        palette[count] = for (names, 0..) |known, index| {
            if (std.mem.eql(u8, name, known)) break std.math.cast(u16, index) orelse return error.BiomeIdTooLarge;
        } else return error.UnknownBiome;
        count += 1;
    }
    if (count == 1) {
        @memset(output, palette[0]);
        return true;
    }
    const data = try (value.childNamed(doc.nodes, "data") orelse return error.MissingBiomeData).longArray();
    const bits: u6 = @intCast(std.math.log2_int_ceil(usize, count));
    const per_word = 64 / @as(usize, bits);
    if (data.len() != (64 + per_word - 1) / per_word) return error.InvalidBiomeData;
    const mask = (@as(u64, 1) << bits) - 1;
    for (output, 0..) |*biome, index| {
        const word: u64 = @bitCast(data.get(index / per_word));
        const rank = (word >> @as(u6, @intCast(index % per_word * bits))) & mask;
        if (rank >= count) return error.InvalidBiomeIndex;
        biome.* = palette[rank];
    }
    return true;
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = (try file.stat(io)).size;
    if (size > limit) return error.FileTooLarge;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.TruncatedFile;
    return bytes;
}

test {
    _ = tests;
}
