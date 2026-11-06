const std = @import("std");
const anvil = @import("anvil.zig");
const nbt = @import("nbt");

test "block state registry keys normalize property order without losing values" {
    var first = [_]anvil.Property{ .{ .name = "waterlogged", .value = "false" }, .{ .name = "axis", .value = "y" } };
    var second = [_]anvil.Property{ first[1], first[0] };
    const a = try anvil.stateKey(std.testing.allocator, "minecraft:oak_log", &first);
    defer std.testing.allocator.free(a);
    const b = try anvil.stateKey(std.testing.allocator, "minecraft:oak_log", &second);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    second[0].value = "x";
    const c = try anvil.stateKey(std.testing.allocator, "minecraft:oak_log", &second);
    defer std.testing.allocator.free(c);
    try std.testing.expect(!std.mem.eql(u8, a, c));
}

fn named(writer: *std.Io.Writer, kind: u8, name: []const u8) !void {
    try writer.writeByte(kind);
    try writer.writeInt(u16, @intCast(name.len), .big);
    try writer.writeAll(name);
}

test "Anvil import preserves global states across Java padded palette words" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry: anvil.Registry = .{ .states = std.StringHashMap(u16).init(allocator), .hash = @splat(0) };
    try registry.states.put("minecraft:air\x00", 0);
    for ([_]u16{ 1, 2, 17, 33, 257 }) |count| {
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        const writer = &bytes.writer;
        try named(writer, 10, "");
        try named(writer, 10, "block_states");
        try named(writer, 9, "palette");
        try writer.writeByte(10);
        try writer.writeInt(u32, count, .big);
        for (0..count) |id| {
            const name = try std.fmt.allocPrint(allocator, "minecraft:test_{d}", .{id});
            const key = try anvil.stateKey(allocator, name, &.{});
            try registry.states.put(key, @intCast(40000 + id));
            try named(writer, 8, "Name");
            try writer.writeInt(u16, @intCast(name.len), .big);
            try writer.writeAll(name);
            try writer.writeByte(0);
        }
        if (count > 1) {
            const bits: u6 = @intCast(@max(4, std.math.log2_int_ceil(u16, count)));
            const per_word: usize = 64 / @as(usize, bits);
            const words = (4096 + per_word - 1) / per_word;
            try named(writer, 12, "data");
            try writer.writeInt(u32, @intCast(words), .big);
            for (0..words) |word_index| {
                var word: u64 = 0;
                for (0..per_word) |offset| {
                    const index = word_index * per_word + offset;
                    if (index < 4096) word |= @as(u64, index % count) << @as(u6, @intCast(offset * bits));
                }
                try writer.writeInt(u64, word, .big);
            }
        }
        try writer.writeAll(&.{ 0, 0 });
        const nodes = try allocator.alloc(nbt.Node, 1024);
        var frames: [64]nbt.Frame = undefined;
        const doc = try nbt.scan_named(bytes.written(), nodes, &frames);
        var decoded: [anvil.section_bytes]u8 = undefined;
        const section = try anvil.section(allocator, &registry, doc, doc.root_node(), &decoded);
        for (0..4096) |index| {
            const state = std.mem.readInt(u16, section[if (section[0] == 0) 1 else 1 + index * 2..][0..2], .little);
            try std.testing.expectEqual(@as(u16, @intCast(40000 + index % count)), state);
        }
    }
}

test "baseline state names resolve independently of NBT property order" {
    var registry = try anvil.Registry.init(std.testing.allocator, &.{ "minecraft:air", "minecraft:oak_log[waterlogged=false,axis=y]" });
    defer registry.deinit();
    try std.testing.expectEqual(@as(?u16, 0), registry.states.get("minecraft:air\x00"));
    try std.testing.expectEqual(@as(?u16, 1), registry.states.get("minecraft:oak_log\x00axis=y\x00waterlogged=false\x00"));
    try std.testing.expectError(error.DuplicateState, anvil.Registry.init(std.testing.allocator, &.{ "minecraft:air", "minecraft:air" }));
}

test "chunk payload bounds reject truncation and permit unpadded sectors" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "r.0.0.mca", .{});
    defer file.close(io);
    var header: [8192]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], 2 * 256 + 1, .big);
    try file.writePositionalAll(io, &header, 0);
    const chunk: [5]u8 = .{ 0, 0, 0, 3, 3 };
    try file.writePositionalAll(io, &chunk, 8192);
    var path: [4096]u8 = undefined;
    var reader = try anvil.Reader.initRegion(std.testing.allocator, io, path[0..try temporary.dir.realPath(io, &path)], null);
    defer reader.deinit();
    try std.testing.expectError(error.TruncatedRegion, reader.read(0, 0));
    const complete = [_]u8{ 0, 0, 0, 5, 3, 10, 0, 0, 0 };
    try file.writePositionalAll(io, &complete, 8192);
    const document = try reader.read(0, 0);
    try std.testing.expectEqual(nbt.Tag.compound, document.root_node().tag);
}

test "palette entries accept both vanilla field encodings without ambiguous aliases" {
    for ([_]bool{ false, true }) |modern| {
        var bytes: [1024]u8 = undefined;
        var write_frames: [8]nbt.WriteFrame = undefined;
        var writer = nbt.Writer.init(&bytes, &write_frames);
        try writer.beginNamedCompound("");
        try writer.putString(if (modern) "id" else "Name", "minecraft:oak_log");
        try writer.beginNamedCompound(if (modern) "properties" else "Properties");
        try writer.putString("axis", "y");
        try writer.endCompound();
        try writer.endCompound();
        var nodes: [16]nbt.Node = undefined;
        var read_frames: [8]nbt.Frame = undefined;
        const document = try nbt.scan_named(try writer.finish(), &nodes, &read_frames);
        const key = try anvil.paletteKey(std.testing.allocator, document, document.root_node());
        defer std.testing.allocator.free(key);
        try std.testing.expectEqualStrings("minecraft:oak_log\x00axis=y\x00", key);
    }
    var bytes: [256]u8 = undefined;
    var frames: [4]nbt.WriteFrame = undefined;
    var writer = nbt.Writer.init(&bytes, &frames);
    try writer.beginNamedCompound("");
    try writer.putString("Name", "minecraft:stone");
    try writer.putString("id", "minecraft:air");
    try writer.endCompound();
    var nodes: [8]nbt.Node = undefined;
    var read_frames: [4]nbt.Frame = undefined;
    const document = try nbt.scan_named(try writer.finish(), &nodes, &read_frames);
    try std.testing.expectError(error.AmbiguousBlockName, anvil.paletteKey(std.testing.allocator, document, document.root_node()));
}

test "biome palettes preserve all quart cells across padded word widths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var names: [64][]const u8 = undefined;
    for (&names, 0..) |*name, index| name.* = try std.fmt.allocPrint(allocator, "minecraft:biome_{d}", .{index});
    for ([_]usize{ 1, 2, 3, 8, 9, 64 }) |count| {
        var bytes: std.Io.Writer.Allocating = .init(allocator);
        const writer = &bytes.writer;
        try named(writer, 10, "");
        try named(writer, 10, "biomes");
        try named(writer, 9, "palette");
        try writer.writeByte(8);
        try writer.writeInt(u32, @intCast(count), .big);
        for (0..count) |index| {
            const name = names[63 - index];
            try writer.writeInt(u16, @intCast(name.len), .big);
            try writer.writeAll(name);
        }
        if (count > 1) {
            const bits: u6 = @intCast(std.math.log2_int_ceil(usize, count));
            const per_word = 64 / @as(usize, bits);
            const words = (64 + per_word - 1) / per_word;
            try named(writer, 12, "data");
            try writer.writeInt(u32, @intCast(words), .big);
            for (0..words) |word| {
                var word_bits: u64 = 0;
                for (0..per_word) |offset| {
                    const index = word * per_word + offset;
                    if (index < 64) word_bits |= @as(u64, index % count) << @intCast(offset * bits);
                }
                try writer.writeInt(u64, word_bits, .big);
            }
        }
        try writer.writeAll(&.{ 0, 0 });
        const nodes = try allocator.alloc(nbt.Node, 256);
        var frames: [32]nbt.Frame = undefined;
        const doc = try nbt.scan_named(bytes.written(), nodes, &frames);
        var values: [64]u16 = undefined;
        try std.testing.expect(try anvil.biomes(doc, doc.root_node(), &names, &values));
        for (values, 0..) |biome, index| try std.testing.expectEqual(@as(u16, @intCast(63 - index % count)), biome);
    }
}
