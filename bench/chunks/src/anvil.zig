const std = @import("std");
const nbt = @import("nbt");
const anvil = @import("anvil");
const corpus = @import("corpus.zig");

pub const Property = anvil.Property;
pub const stateKey = anvil.stateKey;
pub const Registry = anvil.Registry;
pub const Reader = anvil.Reader;
pub const section = anvil.section;

fn named(writer: *std.Io.Writer, node: nbt.Node) !void {
    try writer.writeByte(@backingInt(node.tag));
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
