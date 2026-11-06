const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const patch = @import("patch.zig");

const Section = struct {
    blocks: [4096]u16 = @splat(0),
    biomes: [64]u16 = @splat(0),

    fn equal(a: *const Section, b: *const Section) bool {
        return std.mem.eql(u16, &a.blocks, &b.blocks) and std.mem.eql(u16, &a.biomes, &b.biomes);
    }
};

test "section overlays coalesce repeated edits and select bounded encodings" {
    var bytes: [patch.maximum]u8 = undefined;
    for ([_]usize{ 0, 1, 100, 256, 257, 3839, 3840, 4096 }) |count| {
        var section: Section = .{};
        var changes: [4096]patch.Change = undefined;
        for (&changes, 0..) |*change, i| change.* = .{ .position = @intCast(i), .state = @intCast(i + 1) };
        var overlay: patch.Patch = .{};
        overlay.apply(&section.blocks, changes[0..count]);
        overlay.apply(&section.blocks, changes[0..count]);
        try std.testing.expectEqual(count, overlay.count);
        section.biomes = @splat(9);
        overlay.biomes = true;
        const encoded = try overlay.encode(&section.blocks, &section.biomes, 77, &bytes);
        try std.testing.expect(encoded.len <= patch.maximum);
        var restored: Section = .{};
        var loaded = try patch.Patch.decode(encoded, 77, &restored.blocks, &restored.biomes);
        try std.testing.expect(Section.equal(&section, &restored));
        loaded.apply(&restored.blocks, &.{.{ .position = 7, .state = 0 }});
        section.blocks[7] = 0;
        const next = try loaded.encode(&restored.blocks, &restored.biomes, 77, &bytes);
        restored = .{};
        _ = try patch.Patch.decode(next, 77, &restored.blocks, &restored.biomes);
        try std.testing.expect(Section.equal(&section, &restored));
    }
}

test "invalid or stale overlays cannot partially alter a section" {
    var section: Section = .{};
    var overlay: patch.Patch = .{};
    overlay.apply(&section.blocks, &.{ .{ .position = 0, .state = 17 }, .{ .position = 4095, .state = 31 } });
    var bytes: [patch.maximum]u8 = undefined;
    const encoded = try overlay.encode(&section.blocks, &section.biomes, 7, &bytes);
    var target: Section = .{};
    try std.testing.expectError(error.StaleBase, patch.Patch.decode(encoded, 8, &target.blocks, &target.biomes));
    for (0..encoded.len) |length| try std.testing.expectError(error.Corrupt, patch.Patch.decode(encoded[0..length], 7, &target.blocks, &target.biomes));
    bytes[16..18].* = bytes[12..14].*;
    try std.testing.expectError(error.Corrupt, patch.Patch.decode(encoded, 7, &target.blocks, &target.biomes));
    const unchanged: Section = .{};
    try std.testing.expect(Section.equal(&unchanged, &target));
}

test "moving block overlays recover atomically with associated data and replace history" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/overlays", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 128 };
    const resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1 });
    defer resources.deinit();
    var sections: [2]Section = @splat(.{});
    var overlays: [2]patch.Patch = @splat(.{});
    var buffers: [2][patch.maximum]u8 = undefined;
    var expected: [2]Section = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
        defer store.deinit();
        const table = records.Table.init(try store.openSpace("world"), resources);
        try table.putBatch(&.{.{ .key = "base", .value = "immutable base group" }});
        for (1..5) |save| {
            for (&sections, &overlays, 0..) |*section, *overlay, index| {
                var changes: [100]patch.Change = undefined;
                for (&changes, 0..) |*change, i| change.* = .{ .position = @intCast(i), .state = @intCast(save * 10 + index) };
                for (0..20) |_| overlay.apply(&section.blocks, &changes);
                try std.testing.expectEqual(@as(u16, 100), overlay.count);
            }
            const first = try overlays[0].encode(&sections[0].blocks, &sections[0].biomes, 1, &buffers[0]);
            const second = try overlays[1].encode(&sections[1].blocks, &sections[1].biomes, 1, &buffers[1]);
            try table.putBatch(&.{ .{ .key = "section-a", .value = first }, .{ .key = "section-b", .value = second }, .{ .key = "inventory", .value = if (save < 4) "committed" else "unfinished" } });
            if (save < 4) {
                try store.waitDurable(try store.commit(save));
                expected = sections;
            }
        }
    }
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 3), store.lastTick());
    const table = records.Table.init(try store.openSpace("world"), resources);
    var inventory: [32]u8 = undefined;
    var base: [32]u8 = undefined;
    var lengths: [4]?usize = undefined;
    try table.getBatch(&.{ .{ .key = "section-a", .destination = &buffers[0] }, .{ .key = "section-b", .destination = &buffers[1] }, .{ .key = "inventory", .destination = &inventory }, .{ .key = "base", .destination = &base } }, &lengths);
    for (&sections, 0..) |*section, index| {
        section.* = .{};
        _ = try patch.Patch.decode(buffers[index][0..lengths[index].?], 1, &section.blocks, &section.biomes);
        try std.testing.expect(Section.equal(&expected[index], section));
        try std.testing.expectEqual(@as(usize, 412), lengths[index].?);
    }
    try std.testing.expectEqualStrings("committed", inventory[0..lengths[2].?]);
    try std.testing.expectEqualStrings("immutable base group", base[0..lengths[3].?]);
}
