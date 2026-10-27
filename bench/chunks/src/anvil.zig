const std = @import("std");
const nbt = @import("nbt");
const corpus = @import("corpus.zig");
const common = @import("common.zig");

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

pub const Registry = struct {
    states: std.StringHashMap(u16),
    hash: [64]u8,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Registry {
        const bytes = try common.readFile(allocator, io, path, 32 * 1024 * 1024);
        defer allocator.free(bytes);
        const json = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer json.deinit();
        var states = std.StringHashMap(u16).init(allocator);
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
                if (states.contains(key)) return error.DuplicateState;
                try states.put(key, @intCast(id));
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
    version: i32,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, world: []const u8, version: i32) !Reader {
        var region = try std.fs.path.join(allocator, &.{ world, "dimensions/minecraft/overworld/region" });
        std.Io.Dir.cwd().access(io, region, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(region);
                region = try std.fs.path.join(allocator, &.{ world, "region" });
            },
            else => return err,
        };
        return .{ .allocator = allocator, .io = io, .region = region, .nodes = try allocator.alloc(nbt.Node, 131072), .bytes = try allocator.alloc(u8, maximum_chunk_bytes), .version = version };
    }

    pub fn load(self: *Reader, x: i32, z: i32) !nbt.Document {
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
        var header: [5]u8 = undefined;
        if (try file.readPositionalAll(self.io, &header, offset) != 5) return error.TruncatedRegion;
        const size = std.mem.readInt(u32, header[0..4], .big);
        var compressed: []u8 = undefined;
        if (header[4] & 128 != 0) {
            const external = try std.fmt.bufPrint(&name, "{s}/c.{d}.{d}.mcc", .{ self.region, x, z });
            compressed = try common.readFile(self.allocator, self.io, external, maximum_chunk_bytes);
        } else {
            if (size < 1 or size > (location & 255) * 4096 -| 4) return error.InvalidRegionLength;
            compressed = try self.allocator.alloc(u8, size - 1);
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
        if (try (doc.childNamed("xPos") orelse return error.MissingCoordinates).int() != x or try (doc.childNamed("zPos") orelse return error.MissingCoordinates).int() != z) return error.WrongCoordinates;
        if (try (doc.childNamed("DataVersion") orelse return error.MissingVersion).int() != self.version) return error.WrongWorldVersion;
        const status = try (doc.childNamed("Status") orelse return error.MissingStatus).string();
        if (!std.mem.eql(u8, status, "minecraft:full") and !std.mem.eql(u8, status, "full")) return error.ChunkNotGenerated;
        return doc;
    }
};

pub fn section(allocator: std.mem.Allocator, registry: *const Registry, doc: nbt.Document, node: ?nbt.Node, output: *[corpus.section_bytes]u8) ![]const u8 {
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
        const name = try (entry.childNamed(doc.nodes, "Name") orelse return error.MissingBlockName).string();
        var properties: [64]Property = undefined;
        var property_count: usize = 0;
        if (entry.childNamed(doc.nodes, "Properties")) |object| {
            var values = object.childIterator(doc.nodes);
            while (values.next()) |property| {
                if (property_count == properties.len) return error.TooManyProperties;
                properties[property_count] = .{ .name = property.name, .value = try property.string() };
                property_count += 1;
            }
        }
        const key = try stateKey(allocator, name, properties[0..property_count]);
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

fn named(writer: *std.Io.Writer, node: nbt.Node) !void {
    try writer.writeByte(@intFromEnum(node.tag));
    try writer.writeInt(u16, @intCast(node.name.len), .big);
    try writer.writeAll(node.name);
    try writer.writeAll(node.payload);
}

pub fn writeTerrain(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, doc: nbt.Document) !u64 {
    var terrain: std.Io.Writer.Allocating = .init(allocator);
    defer terrain.deinit();
    const writer = &terrain.writer;
    try writer.writeAll(&.{ 10, 0, 0 });
    for ([_][]const u8{ "DataVersion", "xPos", "zPos", "Status" }) |name|
        try named(writer, doc.childNamed(name) orelse return error.MissingChunkField);
    const sections = doc.childNamed("sections") orelse return error.MissingSections;
    var count: i32 = 0;
    var iterator = sections.childIterator(doc.nodes);
    while (iterator.next()) |node| {
        const y = try (node.childNamed(doc.nodes, "Y") orelse return error.MissingSectionY).byte();
        if (y >= corpus.minimum_y and y < corpus.minimum_y + corpus.section_count) count += 1;
    }
    try writer.writeByte(9);
    try writer.writeInt(u16, 8, .big);
    try writer.writeAll("sections");
    try writer.writeByte(10);
    try writer.writeInt(i32, count, .big);
    iterator = sections.childIterator(doc.nodes);
    while (iterator.next()) |node| {
        const y = node.childNamed(doc.nodes, "Y").?;
        const coordinate = try y.byte();
        if (coordinate < corpus.minimum_y or coordinate >= corpus.minimum_y + corpus.section_count) continue;
        try named(writer, y);
        if (node.childNamed(doc.nodes, "block_states")) |states| try named(writer, states);
        try writer.writeByte(0);
    }
    try writer.writeByte(0);
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 65536);
    defer compressed.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, &window, .zlib, .default);
    try compressor.writer.writeAll(writer.buffered());
    try compressor.finish();
    const bytes = compressed.written();
    const sectors = std.math.divCeil(usize, bytes.len + 5, 4096) catch unreachable;
    if (sectors > 255) return error.ChunkTooLarge;
    const x = try doc.childNamed("xPos").?.int();
    const z = try doc.childNamed("zPos").?.int();
    var path_bytes: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, "{s}/r.{d}.{d}.mca", .{ directory, @divFloor(x, 32), @divFloor(z, 32) });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    var offset = (try file.stat(io)).size;
    var submitted: u64 = 0;
    if (offset == 0) {
        const header: [8192]u8 = @splat(0);
        try file.writePositionalAll(io, &header, 0);
        offset = header.len;
        submitted += header.len;
    }
    if (offset % 4096 != 0 or offset / 4096 > 0xffffff) return error.InvalidRegionLength;
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(bytes.len + 1), .big);
    header[4] = 2;
    try file.writePositionalAll(io, &header, offset);
    try file.writePositionalAll(io, bytes, offset + 5);
    const padding: [4096]u8 = @splat(0);
    try file.writePositionalAll(io, padding[0 .. sectors * 4096 - bytes.len - 5], offset + 5 + bytes.len);
    var location: [4]u8 = undefined;
    std.mem.writeInt(u32, &location, @intCast((offset / 4096) << 8 | sectors), .big);
    const index: u64 = @intCast(@mod(x, 32) + @mod(z, 32) * 32);
    try file.writePositionalAll(io, &location, index * 4);
    return submitted + sectors * 4096 + location.len;
}
