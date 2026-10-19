const storage = @import("storage");
const std = @import("std");
const chunks = @import("chunks.zig");
const encoding = @import("encoding.zig");
const metrics = @import("metrics");
const records = @import("records");

test {
    _ = @import("store_test.zig");
}

test "section palettes round trip every bit width and fall back before expanding" {
    for ([_]u16{ 1, 2, 3, 4, 5, 8, 9, 16, 17, 32, 33, 64, 65, 128, 129, 256, 257, 512, 513, 1024, 1025, 1278, 1279, 1280, 2048, 4096 }) |count| {
        var dense: [encoding.decoded_bytes]u8 = undefined;
        dense[0] = 1;
        for (0..encoding.blocks) |i| {
            const state = @as(u16, @intCast(i % count)) *% 40503 +% 65535;
            std.mem.writeInt(u16, dense[1 + i * 2 ..][0..2], state, .little);
        }
        var encoded: [encoding.decoded_bytes]u8 = undefined;
        const bytes = try encoding.encode(&dense, &encoded);
        const expected = if (count == 1) 3 else @min(encoding.decoded_bytes, 3 + @as(usize, count) * 2 + 512 * @as(usize, std.math.log2_int_ceil(u16, count)));
        try std.testing.expectEqual(expected, bytes.len);
        if (count >= 1279) try std.testing.expectEqual(dense[0..].ptr, bytes.ptr);
        var decoded: [encoding.decoded_bytes]u8 = undefined;
        @memcpy(decoded[0..bytes.len], bytes);
        const length = try encoding.decode(&decoded, bytes.len);
        if (count == 1) {
            try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255 }, decoded[0..length]);
        } else {
            try std.testing.expectEqualSlices(u8, &dense, decoded[0..length]);
        }
    }
    var uniform: [3]u8 = .{ 0, 255, 255 };
    try std.testing.expectEqual(uniform[0..].ptr, (try encoding.encode(&uniform, &.{})).ptr);
}

test "section decoder rejects malformed lengths palettes and indices" {
    var bytes: [encoding.decoded_bytes]u8 = @splat(0);
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 0));
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, bytes.len + 1));
    for ([_]u8{ 0, 1, 2, 3, 255 }) |tag| {
        bytes[0] = tag;
        try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1));
    }
    bytes[0] = 2;
    for ([_]u16{ 0, 1, 1279, 2048, 65535 }) |count| {
        std.mem.writeInt(u16, bytes[1..3], count, .little);
        try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, bytes.len));
    }
    std.mem.writeInt(u16, bytes[1..3], 3, .little);
    bytes[9] = 3;
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1033));
    bytes[9] = 0;
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1032));
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1034));
    try std.testing.expectError(error.BufferTooSmall, encoding.decode(bytes[0..1033], 1033));
}

test "chunk eviction and reload preserve edits while clean sections are never rewritten" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/chunks", .{directory.sub_path});
    const options: storage.Store.Options = .{ .path = path };
    const a: chunks.Section = .{ .world = 0, .x = 0, .y = 4, .z = 0 };
    const b: chunks.Section = .{ .world = 0, .x = 1, .y = 4, .z = 0 };
    const c: chunks.Section = .{ .world = 0, .x = 2, .y = 4, .z = 0 };
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .metrics = &registry });
        defer store.deinit();
        const tx = store.transaction();
        const space = try tx.openSpace(chunks.Chunks.id);
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 2 }, .{ .metrics = &registry, .storage = space });
        try world.setBlocks(a, &.{ .{ .index = 0, .state = 9 }, .{ .index = 4095, .state = 65535 } });
        try world.setBlocks(b, &.{.{ .index = 123, .state = 17 }});
        try world.setBlocks(c, &.{.{ .index = 4095, .state = 42 }});
        try world.checkpoint(space);
        try std.testing.expect(store.wal_bytes.value() > 0);
        _ = try store.commit(1);
        try store.waitDurable(store.lastCommit());

        const before = store.wal_bytes.value();
        try world.setBlocks(a, &.{.{ .index = 0, .state = 9 }});
        try world.checkpoint(space);
        try std.testing.expectEqual(before, store.wal_bytes.value());
        try world.setBlocks(a, &.{.{ .index = 255, .state = 100 }});
        try world.checkpoint(space);
        try std.testing.expect(store.wal_bytes.value() > before);
        _ = try store.commit(2);
        try store.waitDurable(store.lastCommit());
    }
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
        const tx = store.transaction();
        defer tx.fail();
        const space = try tx.openSpace(chunks.Chunks.id);
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 2 }, .{ .metrics = &registry, .storage = space });
        for ([_]chunks.Section{ a, b, c, a }) |section| {
            const lease = try world.acquire(section);
            defer lease.release();
            for (0..encoding.blocks) |i| {
                const expected: u16 = if (section.x == 0) switch (i) {
                    0 => 9,
                    255 => 100,
                    4095 => 65535,
                    else => 0,
                } else if (section.x == 1 and i == 123) 17 else if (section.x == 2 and i == 4095) 42 else 0;
                try std.testing.expectEqual(expected, lease.get(@intCast(i)));
            }
        }
    }
}

test "encoded cache batches retain their bytes across flushes and decode scans" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/batches", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const tx = store.transaction();
    defer tx.fail();
    const space = try tx.openSpace(chunks.Chunks.id);
    var cache = try records.Cache.init(arena.allocator(), io, records.Table.init(space), .{ .slots = 40, .key_bytes = 1, .value_bytes = encoding.decoded_bytes, .codec = encoding.codec, .scan_batch = 2 });
    var keys: [40][1]u8 = undefined;
    var key_slices: [40][]const u8 = undefined;
    var leases: [40]records.Cache.Lease = undefined;
    for (&keys, &key_slices, 0..) |*key, *slice, i| {
        key.* = .{@intCast(i)};
        slice.* = key;
    }
    try cache.acquireMany(&key_slices, &leases);
    for (leases, 0..) |lease, section| {
        const value = lease.edit();
        value[0] = 1;
        for (0..encoding.blocks) |i| std.mem.writeInt(u16, value[1 + i * 2 ..][0..2], @intCast(section * 64 + i % 64), .little);
        lease.commit(encoding.decoded_bytes);
        lease.release();
    }
    try cache.flush();
    var scan = try records.Cache.init(arena.allocator(), io, records.Table.init(space), .{ .slots = 1, .key_bytes = 1, .value_bytes = encoding.decoded_bytes, .codec = encoding.codec, .scan_batch = 2 });
    var cursor_key: [1]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &cursor_key };
    var scan_keys: [2][1]u8 = undefined;
    var scan_values: [2][encoding.decoded_bytes]u8 = undefined;
    var entries: [2]records.ScanEntry = undefined;
    for (&entries, &scan_keys, &scan_values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
    var read: usize = 0;
    while (true) {
        const result = try scan.scan(&cursor, &entries);
        for (entries[0..result.count]) |entry| {
            try std.testing.expectEqual(read, entry.key[0]);
            try std.testing.expectEqual(encoding.decoded_bytes, entry.value_len);
            for (0..encoding.blocks) |i| try std.testing.expectEqual(@as(u16, @intCast(read * 64 + i % 64)), std.mem.readInt(u16, entry.value[1 + i * 2 ..][0..2], .little));
            read += 1;
        }
        if (!result.more) break;
    }
    try std.testing.expectEqual(keys.len, read);
    var value: [encoding.decoded_bytes]u8 = undefined;
    for (keys) |key| try std.testing.expectEqual(@as(?usize, 3203), try records.Table.init(space).get(&key, &value));
}
