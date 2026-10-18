const std = @import("std");
const corpus = @import("corpus.zig");
const trace = @import("trace.zig");
const anvil = @import("anvil.zig");
const common = @import("common.zig");
const nbt = @import("nbt");

fn fixture(allocator: std.mem.Allocator) !corpus.Corpus {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();
    try bytes.writer.writeAll("LRWORLD2");
    try bytes.writer.writeInt(u32, 4 * 16 * 16, .little);
    try bytes.writer.writeInt(i16, -4, .little);
    try bytes.writer.writeInt(i16, 24, .little);
    var at: usize = 0;
    for ([_]i32{ 0, 128 }) |ox| for (0..16) |x| {
        for ([_]i32{ 0, 128 }) |oz| for (0..16) |z| {
            try bytes.writer.writeInt(i32, ox + @as(i32, @intCast(x)), .little);
            try bytes.writer.writeInt(i32, oz + @as(i32, @intCast(z)), .little);
            try bytes.writer.writeInt(i32, 64, .little);
            try bytes.writer.writeInt(u32, 0, .little);
            try bytes.writer.writeInt(u64, 16 + 1024 * 24 + at * 24 * 5, .little);
            at += 1;
        };
    };
    for (0..1024 * 24) |_| try bytes.writer.writeAll(&.{ 3, 0, 0, 1, 0 });
    return corpus.Corpus.parse(allocator, try bytes.toOwnedSlice());
}

test "corpus validates framing ordering and complete section boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var world = try fixture(allocator);
    try std.testing.expectEqual(@as(?u32, 0), world.find(0, 0));
    try std.testing.expectEqual(@as(?u32, null), world.find(32, 0));
    var bytes: [8193]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try world.read(.{ .world = 0, .x = 0, .z = 0, .y = -4 }, &bytes));
    try std.testing.expectError(error.SectionOutsideCorpus, world.read(.{ .world = 0, .x = 0, .z = 0, .y = 20 }, &bytes));
    try std.testing.expectError(error.InvalidCorpus, corpus.Corpus.parse(allocator, world.bytes[0..15]));
    try std.testing.expectError(error.InvalidCorpus, corpus.Corpus.parse(allocator, world.bytes[0 .. world.bytes.len - 1]));
    const damaged = try allocator.dupe(u8, world.bytes);
    std.mem.writeInt(i32, damaged[16 + 24 ..][0..4], -1, .little);
    try std.testing.expectError(error.UnsortedCorpus, corpus.Corpus.parse(allocator, damaged));
}

test "mapped corpus ownership survives repeated opens and spatial replication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const original = try fixture(arena.allocator());
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(io, .{ .sub_path = "corpus", .data = original.bytes });
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/corpus", .{directory.sub_path});
    defer std.testing.allocator.free(path);
    for (0..4) |_| {
        var mapped = try corpus.Corpus.load(std.testing.allocator, io, path);
        defer mapped.deinit(std.testing.allocator, io);
        try std.testing.expectEqualSlices(u8, &original.hash, &mapped.hash);
        try mapped.replicate(std.testing.allocator, 4);
        var bytes: [8193]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 3), try mapped.read(.{ .world = 0, .x = 3072, .z = 0, .y = -4 }, &bytes));
        try std.testing.expectEqualSlices(u8, original.columns[0].sections[0], bytes[0..3]);
    }
}

test "every access pattern is repeatable bounded and preserves its final edit model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const world = try fixture(allocator);
    for (std.enums.values(trace.Pattern)) |pattern| {
        const a = try trace.generate(allocator, &world, pattern, 20261017, 128, 2);
        const b = try trace.generate(allocator, &world, pattern, 20261017, 128, 2);
        try std.testing.expectEqualSlices(u8, &a.hash, &b.hash);
        var expected = std.AutoHashMap(u64, u16).init(allocator);
        for (a.steps, b.steps, 0..) |left, right, step| {
            try std.testing.expectEqualSlices(u32, left.columns, right.columns);
            try std.testing.expectEqual((step + 1) % 32 == 0, left.save);
            for (left.columns) |id| {
                try std.testing.expect(id < world.columns.len);
                try std.testing.expect(a.touched[id]);
            }
            for (left.edits) |edit| {
                try std.testing.expect(edit.column < world.columns.len and edit.section < corpus.section_count);
                try expected.put(trace.editKey(edit), edit.state);
            }
        }
        try std.testing.expectEqual(expected.count(), a.final_edits.count());
        var iterator = expected.iterator();
        while (iterator.next()) |entry| try std.testing.expectEqual(entry.value_ptr.*, a.final_edits.get(entry.key_ptr.*).?);
        if (pattern == .walk) try std.testing.expect(a.requests < 128 * 25);
        if (pattern == .revisit) try std.testing.expectEqual(@as(usize, 4 * 6 * 25), a.requests);
    }
    const a = try trace.generate(allocator, &world, .random, 1, 16, 2);
    const b = try trace.generate(allocator, &world, .random, 2, 16, 2);
    try std.testing.expect(!std.mem.eql(u8, &a.hash, &b.hash));
}

test "scaled corpora share terrain bytes and spread players across independent coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var world = try fixture(allocator);
    const original = world.columns[0].sections[0];
    try world.replicate(allocator, 4);
    try std.testing.expectEqual(@as(usize, 4096), world.columns.len);
    try std.testing.expectEqual(original.ptr, world.columns[3072].sections[0].ptr);
    try std.testing.expectEqual(@as(?u32, 3072), world.find(3072, 0));
    const a = try trace.generate(allocator, &world, .multiplayer, 20261017, 128, 2);
    const b = try trace.generate(allocator, &world, .multiplayer, 20261017, 128, 2);
    try std.testing.expectEqualSlices(u8, &a.hash, &b.hash);
    var seen: [4]bool = @splat(false);
    for (a.steps[0].columns) |id| seen[@intCast(@divFloor(world.columns[id].x, 1024))] = true;
    for (seen) |present| try std.testing.expect(present);
    try std.testing.expectError(error.InvalidCopies, world.replicate(allocator, 2));
}

test "walking traces stay within their region when neighboring regions touch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const side = 2 * corpus.origin_stride;
    const columns = try allocator.alloc(corpus.Column, side * side);
    for (columns, 0..) |*column, index| column.* = .{
        .x = @intCast(index / side),
        .z = @intCast(index % side),
        .surface_y = 64,
        .sections = @splat(&.{ 0, 1, 0 }),
    };
    const world: corpus.Corpus = .{ .bytes = &.{}, .columns = columns, .hash = @splat(0) };
    for ([_]trace.Pattern{ .walk, .multiplayer, .revisit, .edits, .exploration }) |pattern| {
        const generated = try trace.generate(allocator, &world, pattern, 20261017, 256, 12);
        for (generated.steps) |step| {
            for (step.columns) |id| try std.testing.expect(id < columns.len);
            for (step.edits) |edit| try std.testing.expect(edit.column < columns.len);
        }
    }
}

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

test "tail percentiles retain the maximum for short benchmark samples" {
    var samples = [_]u64{ 16, 1, 15, 2, 14, 3, 13, 4, 12, 5, 11, 6, 10, 7, 9, 8 };
    const distribution = common.Distribution.summarize(&samples);
    try std.testing.expectEqual(@as(u64, 136), distribution.total_ns);
    try std.testing.expectEqual(@as(u64, 8), distribution.p50_ns);
    try std.testing.expectEqual(@as(u64, 16), distribution.p95_ns);
    try std.testing.expectEqual(@as(u64, 16), distribution.p99_ns);
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
        var decoded: [corpus.section_bytes]u8 = undefined;
        const section = try anvil.section(allocator, &registry, doc, doc.root_node(), &decoded);
        for (0..4096) |index| {
            const state = std.mem.readInt(u16, section[if (section[0] == 0) 1 else 1 + index * 2..][0..2], .little);
            try std.testing.expectEqual(@as(u16, @intCast(40000 + index % count)), state);
        }
    }
}
