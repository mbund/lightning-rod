const std = @import("std");
const records = @import("records");
const storage = @import("storage");
const metrics = @import("metrics");
const structure = @import("structure_test.zig");
const testing = @import("storage_testing");
const fault = @import("fault_disk");

const Row = struct { bytes: [8193]u8 = undefined, length: usize = 0, present: bool = false };

test "record workspaces remain bounded after initialization across splits and deletion" {
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/workspace", .{temporary.sub_path});
    var memory = storage.system.Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("records");
    const table_resources = try records.Resources.init(allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path, .maximum_wal_pages = 256 });
    defer store.deinit();
    const table = records.Table.init(try store.openSpace("records"), table_resources);
    const reserved = memory.assigned_bytes;
    memory.seal();
    var keys: [256][2]u8 = undefined;
    var writes: [256]records.Write = undefined;
    const value: [700]u8 = @splat(17);
    for (&keys, &writes, 0..) |*key, *write, index| {
        std.mem.writeInt(u16, key, @intCast(index), .big);
        write.* = .{ .key = key, .value = &value };
    }
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    var output: [700]u8 = undefined;
    for (keys) |key| {
        try std.testing.expectEqual(@as(?usize, value.len), try table.get(&key, &output));
        try std.testing.expectEqualSlices(u8, &value, &output);
    }
    for (&writes) |*write| write.value = null;
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(2));
    try std.testing.expectEqual(null, try table.space.getRoot());
    try std.testing.expectEqual(reserved, memory.assigned_bytes);
    try std.testing.expectEqual(@as(usize, 0), table_resources.borrowed.load(.acquire));
}

test "overflow remainders share a leaf and recover across representation changes" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/prefix", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    var keys: [2][64]u8 = @splat(@splat(0));
    keys[1][0] = 1;
    var payload: [7064]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    try table.putBatch(&.{ .{ .key = &keys[0], .value = payload[0..5964] }, .{ .key = &keys[1], .value = payload[0..5964] } });
    try std.testing.expectEqual(@as(u64, 4), store.metadata.pages);
    try std.testing.expectEqual(@as(usize, 1), (try structure.inspect(table)).pages);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    var output: [7064]u8 = undefined;
    for (&keys) |key| {
        try std.testing.expectEqual(@as(?usize, 5964), try table.get(&key, &output));
        try std.testing.expectEqualSlices(u8, payload[0..5964], output[0..5964]);
    }
    try table.putBatch(&.{ .{ .key = &keys[0], .value = payload[0..1500] }, .{ .key = &keys[1], .value = &payload } });
    try store.waitDurable(try store.commit(2));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    for (&keys, [_]usize{ 1500, payload.len }) |key, length| {
        try std.testing.expectEqual(@as(?usize, length), try table.get(&key, &output));
        try std.testing.expectEqualSlices(u8, payload[0..length], output[0..length]);
    }
    _ = try structure.inspect(table);
    try table.putBatch(&.{ .{ .key = &keys[0], .value = null }, .{ .key = &keys[1], .value = null } });
    try std.testing.expectEqual(null, try table.space.getRoot());
    _ = try structure.inspect(table);
}

test "record decoding rejects invalid inline prefixes and older node versions" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/prefix", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const table = records.Table.init(try store.openSpace("records"), table_resources);
        const value: [5964]u8 = @splat(17);
        try table.put("key", &value);
        try store.waitDurable(try store.commit(1));
    }
    const Invalid = struct { representation: u16, length: u32 = 5964, version: u8 = 1 };
    const cases = [_]Invalid{
        .{ .representation = 3 | (1899 << 2) },
        .{ .representation = 3 | (6000 << 2) },
        .{ .representation = 1 | (1 << 2) },
        .{ .representation = 0 | (1 << 2) },
        .{ .representation = 3 | (1900 << 2), .length = 1900 },
        .{ .representation = 3 | (1900 << 2), .version = 0 },
    };
    for (cases) |invalid| {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("records");
        const root = (try space.getRoot()).?;
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = root, .destination = &page }});
        page[5] = invalid.version;
        std.mem.writeInt(u16, page[18..20], invalid.representation, .little);
        std.mem.writeInt(u32, page[20..24], invalid.length, .little);
        try space.writePages(&.{.{ .id = root, .source = &page }});
        var value: [5964]u8 = undefined;
        try std.testing.expectError(error.Corrupt, records.Table.init(space, table_resources).get("key", &value));
    }
}

test "overflow reads share submissions across records and preserve caller ordering" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/batch", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    const page_resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 1 });
    defer page_resources.deinit();
    const options: storage.Store.Options = .{ .path = path, .metrics = &registry, .resources = page_resources };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    const count = 64;
    const values = try std.testing.allocator.alloc([8193]u8, count);
    defer std.testing.allocator.free(values);
    var keys: [count][2]u8 = undefined;
    var writes: [count]records.Write = undefined;
    for (&keys, values, &writes, 0..) |*key, *value, *write, i| {
        std.mem.writeInt(u16, key, @intCast(i), .big);
        @memset(value, @intCast(i));
        write.* = .{ .key = key, .value = value };
    }
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    var reads: [count]records.Get = undefined;
    var lengths: [count]?usize = undefined;
    for (&reads, values, 0..) |*read, *value, i| read.* = .{ .key = &keys[count - 1 - i], .destination = value };
    const before = store.read_batches.value();
    try table.getBatch(&reads, &lengths);
    try std.testing.expect(store.read_batches.value() - before < count / 4);
    for (lengths, values, 0..) |length, *value, i| {
        try std.testing.expectEqual(@as(?usize, 8193), length);
        for (value) |byte| try std.testing.expectEqual(@as(u8, @intCast(count - 1 - i)), byte);
    }
}

test "record trees reclaim sparse leaves and branches through shrink growth and aborted saves" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 8192 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    const count = 2048;
    const values = try std.testing.allocator.alloc([8193]u8, 192);
    defer std.testing.allocator.free(values);
    var keys: [192][16]u8 = undefined;
    var writes: [192]records.Write = undefined;
    var full_pages: usize = 0;
    var high_water: u64 = 0;
    for (0..7) |phase| {
        for (0..2) |attempt| {
            var begin: usize = 0;
            while (begin < count) {
                const length = @min(writes.len, count - begin);
                for (keys[0..length], values[0..length], writes[0..length], begin..) |*key, *value, *write, id| {
                    std.mem.writeInt(u128, key, id, .big);
                    const size = churnLength(phase, id);
                    @memset(value[0..size], @truncate(id * 17 + phase));
                    write.* = .{ .key = key, .value = if (size == 0) null else value[0..size] };
                }
                try table.putBatch(writes[0..length]);
                begin += length;
            }
            const shape = try structure.inspect(table);
            if (phase == 0) full_pages = shape.pages;
            if (phase == 1) try std.testing.expect(shape.pages * 3 < full_pages * 2);
            if (phase == 5) {
                try std.testing.expectEqual(@as(usize, 1), shape.pages);
                try std.testing.expectEqual(@as(usize, 1), shape.height);
            }
            if (phase == 4) high_water = store.metadata.pages;
            if (phase == 6) try std.testing.expect(store.metadata.pages <= high_water);
            if (phase == 3 and attempt == 0) {
                store.deinit();
                store = try storage.Store.init(std.testing.allocator, io, options);
                table = records.Table.init(try store.openSpace("records"), table_resources);
            } else {
                try store.waitDurable(try store.commit(phase + 1));
                store.deinit();
                store = try storage.Store.init(std.testing.allocator, io, options);
                table = records.Table.init(try store.openSpace("records"), table_resources);
            }
            _ = try structure.inspect(table);
            const expected_phase = if (phase == 3 and attempt == 0) phase - 1 else phase;
            for (0..count) |id| {
                var key: [16]u8 = undefined;
                std.mem.writeInt(u128, &key, id, .big);
                const expected = churnLength(expected_phase, id);
                const actual = try table.get(&key, &values[0]);
                try std.testing.expectEqual(@as(?usize, if (expected == 0) null else expected), actual);
                for (values[0][0..expected]) |byte| try std.testing.expectEqual(@as(u8, @truncate(id * 17 + expected_phase)), byte);
            }
            if (phase != 3 or attempt != 0) break;
        }
    }
}

fn churnLength(phase: usize, id: usize) usize {
    return switch (phase) {
        0, 6 => 519,
        1 => if (id % 2 == 0) 0 else 519,
        2 => if (id % 7 == 0) 8193 else if (id % 5 == 0) 768 else 519,
        3 => 3,
        4 => 1035,
        5 => if (id == 0) 3 else 0,
        else => unreachable,
    };
}

test "structural inspection rejects lost pages and scanning rejects cyclic leaf links" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const table = records.Table.init(try store.openSpace("records"), table_resources);
    try table.put("key", "value");
    var leaked: [1]storage.PageId = undefined;
    try table.space.allocatePages(&leaked);
    const zero: storage.Page = @splat(0);
    try table.space.writePages(&.{.{ .id = leaked[0], .source = &zero }});
    try std.testing.expectError(error.Corrupt, structure.inspect(table));
    try table.space.freePages(&leaked);
    _ = try structure.inspect(table);
    const root = (try table.space.getRoot()).?;
    var page: storage.Page = undefined;
    try table.space.readPages(&.{.{ .id = root, .destination = &page }});
    std.mem.writeInt(u64, page[8..16], @intFromEnum(root), .little);
    try table.space.writePages(&.{.{ .id = root, .source = &page }});
    try std.testing.expectError(error.Corrupt, structure.inspect(table));
    var after: [16]u8 = undefined;
    var key: [16]u8 = undefined;
    var value: [16]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var entries: [2]records.ScanEntry = @splat(.{ .key = &key, .value = &value });
    try std.testing.expectError(error.Corrupt, table.scan(&cursor, &entries));
}

test "a failed scan batch preserves its cursor for retry" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const table = records.Table.init(try store.openSpace("records"), table_resources);
    try table.putBatch(&.{ .{ .key = "a", .value = "first" }, .{ .key = "b", .value = "second" }, .{ .key = "c", .value = "third" } });
    var after: [16]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after, .after_len = 1 };
    after[0] = 'a';
    var keys: [2][16]u8 = undefined;
    var values: [2][16]u8 = undefined;
    var entries: [2]records.ScanEntry = .{ .{ .key = &keys[0], .value = &values[0] }, .{ .key = &keys[1], .value = values[1][0..1] } };
    try std.testing.expectError(error.BufferTooSmall, table.scan(&cursor, &entries));
    try std.testing.expectEqualStrings("a", cursor.after[0..cursor.after_len]);
    entries[1].value = &values[1];
    const result = try table.scan(&cursor, &entries);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expect(!result.more);
    try std.testing.expectEqualStrings("b", entries[0].key[0..entries[0].key_len]);
    try std.testing.expectEqualStrings("second", entries[0].value[0..entries[0].value_len]);
    try std.testing.expectEqualStrings("c", entries[1].key[0..entries[1].key_len]);
    try std.testing.expectEqualStrings("third", entries[1].value[0..entries[1].value_len]);
}

test "an overflowing leaf uses space on its left before allocating another page" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("sections"), table_resources);
    var keys: [21][16]u8 = undefined;
    var writes: [21]records.Write = undefined;
    const value: [519]u8 = @splat(17);
    for (&keys, &writes, 0..) |*key, *write, index| {
        std.mem.writeInt(u128, key, index * 2, .big);
        write.* = .{ .key = key, .value = &value };
    }
    try table.putBatch(&writes);
    for (writes[0..3]) |*write| write.value = null;
    try table.putBatch(writes[0..3]);
    try store.waitDurable(try store.commit(1));
    const pages_before = store.metadata.pages;
    var inserted: [16]u8 = undefined;
    std.mem.writeInt(u128, &inserted, 17, .big);
    try table.put(&inserted, &value);
    try std.testing.expectEqual(pages_before, store.metadata.pages);
    try store.waitDurable(try store.commit(2));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("sections"), table_resources);
    var buffer: [value.len]u8 = undefined;
    for (keys, 0..) |key, index| {
        const length = try table.get(&key, &buffer);
        try std.testing.expectEqual(@as(?usize, if (index < 3) null else value.len), length);
        if (length != null) try std.testing.expectEqualSlices(u8, &value, &buffer);
    }
    try std.testing.expectEqual(@as(?usize, value.len), try table.get(&inserted, &buffer));
    try std.testing.expectEqualSlices(u8, &value, &buffer);
    var after: [16]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var entry: [1]records.ScanEntry = .{.{ .key = &inserted, .value = &buffer }};
    var count: usize = 0;
    while (true) {
        const result = try table.scan(&cursor, &entry);
        if (result.count != 0) {
            const expected = if (count < 6) (count + 3) * 2 else if (count == 6) 17 else (count + 2) * 2;
            try std.testing.expectEqual(@as(u128, expected), std.mem.readInt(u128, &inserted, .big));
            try std.testing.expectEqualSlices(u8, &value, &buffer);
            count += 1;
        }
        if (!result.more) break;
    }
    try std.testing.expectEqual(@as(usize, keys.len - 3 + 1), count);
}

test "one record batch writes a shared parent only once" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    const table = records.Table.init(try store.openSpace("sections"), table_resources);
    var keys: [192][16]u8 = undefined;
    var writes: [192]records.Write = undefined;
    const value: [519]u8 = @splat(17);
    for (&keys, &writes, 0..) |*key, *write, index| {
        std.mem.writeInt(u128, key, index, .big);
        write.* = .{ .key = key, .value = &value };
    }
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    const leaf_capacity = (storage.page_size - 16) / (8 + keys[0].len + value.len);
    const leaves = 16;
    for (writes[0..leaves], 0..) |*write, index| write.* = .{ .key = &keys[(index + 1) * leaf_capacity - 1], .value = null };
    const before = store.wal_bytes.value();
    try table.putBatch(writes[0..leaves]);
    const frame_bytes = storage.page_size + 64;
    try std.testing.expectEqual(@as(u64, (leaves + 1) * frame_bytes), store.wal_bytes.value() - before);
    try store.waitDurable(try store.commit(2));
    for (writes[0..leaves]) |write| {
        var buffer: [value.len]u8 = undefined;
        try std.testing.expectEqual(null, try table.get(write.key, &buffer));
    }
}

test "fresh section indexes stay shallow and packed for every insertion order and batch size" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const count = 2048;
    const Order = enum { ascending, descending, shuffled };
    const io = std.testing.io;
    for ([_]Order{ .ascending, .descending, .shuffled }) |pattern| {
        for ([_]usize{ 1, 32, 192 }) |batch_size| {
            errdefer std.debug.print("section index order={t} batch_size={d}\n", .{ pattern, batch_size });
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
            defer std.testing.allocator.free(path);
            const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 4096 };
            var store = try storage.Store.init(std.testing.allocator, io, options);
            defer store.deinit();
            var table = records.Table.init(try store.openSpace("sections"), table_resources);
            var order: [count]u16 = undefined;
            for (&order, 0..) |*id, index| id.* = @intCast(if (pattern == .descending) count - 1 - index else index);
            if (pattern == .shuffled) {
                var random = std.Random.DefaultPrng.init(0x73656374696f6e73);
                random.random().shuffle(u16, &order);
            }
            var keys: [192][16]u8 = undefined;
            var values: [192][519]u8 = undefined;
            var writes: [192]records.Write = undefined;
            var begin: usize = 0;
            while (begin < order.len) {
                const length = @min(batch_size, order.len - begin);
                for (keys[0..length], values[0..length], writes[0..length], order[begin..][0..length]) |*key, *value, *write, id| {
                    std.mem.writeInt(u128, key, id, .big);
                    @memset(value, @truncate(id));
                    std.mem.writeInt(u16, value[0..2], id, .little);
                    write.* = .{ .key = key, .value = value };
                }
                try table.putBatch(writes[0..length]);
                begin += length;
            }
            const shape = try structure.inspect(table);
            try std.testing.expectEqual(@as(usize, count), shape.records);
            try std.testing.expect(shape.height <= 3);
            try std.testing.expect(shape.used_bytes * 3 >= shape.pages * storage.page_size * 2);
            try store.waitDurable(try store.commit(1));
            store.deinit();
            store = try storage.Store.init(std.testing.allocator, io, options);
            table = records.Table.init(try store.openSpace("sections"), table_resources);
            var after: [16]u8 = undefined;
            var cursor: records.ScanCursor = .{ .after = &after };
            var entries: [192]records.ScanEntry = undefined;
            for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
            var index: usize = 0;
            while (true) {
                const result = try table.scan(&cursor, &entries);
                for (entries[0..result.count]) |entry| {
                    try std.testing.expectEqual(@as(usize, 16), entry.key_len);
                    try std.testing.expectEqual(@as(u128, index), std.mem.readInt(u128, entry.key[0..16], .big));
                    try std.testing.expectEqual(@as(usize, 519), entry.value_len);
                    try std.testing.expectEqual(@as(u16, @intCast(index)), std.mem.readInt(u16, entry.value[0..2], .little));
                    for (entry.value[2..entry.value_len]) |byte| try std.testing.expectEqual(@as(u8, @truncate(index)), byte);
                    index += 1;
                }
                var reads: [192]records.Get = undefined;
                var lengths: [192]?usize = undefined;
                for (entries[0..result.count], reads[0..result.count]) |entry, *read| read.* = .{ .key = entry.key[0..entry.key_len], .destination = entry.value };
                try table.getBatch(reads[0..result.count], lengths[0..result.count]);
                for (entries[0..result.count], lengths[0..result.count]) |entry, length| {
                    try std.testing.expectEqual(@as(?usize, entry.value_len), length);
                    const id: u16 = @intCast(std.mem.readInt(u128, entry.key[0..16], .big));
                    try std.testing.expectEqual(id, std.mem.readInt(u16, entry.value[0..2], .little));
                }
                if (!result.more) break;
            }
            try std.testing.expectEqual(@as(usize, count), index);
        }
    }
}

fn verify(table: records.Table, expected: *const [64]Row) !void {
    _ = try structure.inspect(table);
    var after: [2]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var keys: [8][2]u8 = undefined;
    var values: [8][8193]u8 = undefined;
    var entries: [8]records.ScanEntry = undefined;
    for (&entries, &keys, &values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
    var index: usize = 0;
    while (true) {
        const result = try table.scan(&cursor, &entries);
        for (entries[0..result.count]) |entry| {
            while (index < expected.len and !expected[index].present) index += 1;
            try std.testing.expect(index < expected.len);
            try std.testing.expectEqual(@as(usize, 2), entry.key_len);
            try std.testing.expectEqual(index, std.mem.readInt(u16, entry.key[0..2], .big));
            try std.testing.expectEqualSlices(u8, expected[index].bytes[0..expected[index].length], entry.value[0..entry.value_len]);
            index += 1;
        }
        if (!result.more) break;
    }
    while (index < expected.len and !expected[index].present) index += 1;
    try std.testing.expectEqual(expected.len, index);
}

pub fn run(input: []const u8) !void {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    try runAt(io, path, input);
}

pub fn runAt(io: std.Io, path: []const u8, input: []const u8) !void {
    const table_resources = try records.Resources.init(std.testing.allocator, io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 4096, .checkpoint_bytes = 64, .io_mode = .standard };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 0), store.lastTick());
    var table = records.Table.init(try store.openSpace("model"), table_resources);
    var expected: [64]Row = @splat(.{});
    var saved = expected;
    var tick: u64 = 0;
    var step: usize = 0;
    while (step + 2 < input.len) : (step += 3) {
        errdefer std.debug.print("records step={d} op={d} target={d} tick={d} phase={t}\n", .{ step / 3, input[step] % 8, input[step + 1] % expected.len, store.lastTick(), store.phase });
        const id = input[step + 1] % expected.len;
        var key: [2]u8 = undefined;
        std.mem.writeInt(u16, &key, @intCast(id), .big);
        switch (input[step] % 8) {
            0, 1 => {
                const lengths = [_]usize{ 0, 3, 42, 519, 1035, 8193 };
                const length = lengths[input[step + 2] % lengths.len];
                for (expected[id].bytes[0..length], 0..) |*byte, index| byte.* = @truncate(id * 7 + step + index);
                expected[id].length = length;
                expected[id].present = true;
                try table.put(&key, expected[id].bytes[0..length]);
            },
            2 => {
                try table.put(&key, null);
                expected[id].present = false;
            },
            3 => {
                var bytes: [8193]u8 = undefined;
                const length = try table.get(&key, &bytes);
                try std.testing.expectEqual(expected[id].present, length != null);
                if (length) |size| try std.testing.expectEqualSlices(u8, expected[id].bytes[0..expected[id].length], bytes[0..size]);
            },
            4 => {
                tick += 1;
                try store.waitDurable(try store.commit(tick));
                saved = expected;
                for (0..input[step + 2] % 8) |_| _ = try store.pollMaintenance(.{ .index_entries = 4, .pages = 4 });
            },
            5 => {
                store.deinit();
                store = try storage.Store.init(std.testing.allocator, io, options);
                table = records.Table.init(try store.openSpace("model"), table_resources);
                expected = saved;
                try verify(table, &expected);
            },
            6 => try verify(table, &expected),
            7 => {
                const count = 1 + input[step + 2] % 8;
                var keys: [8][2]u8 = undefined;
                var values: [8][8193]u8 = undefined;
                var writes: [8]records.Write = undefined;
                for (keys[0..count], values[0..count], writes[0..count], 0..) |*batch_key, *value, *write, index| {
                    const target = (id + index * (input[step + 2] % 3)) % expected.len;
                    std.mem.writeInt(u16, batch_key, @intCast(target), .big);
                    const lengths = [_]usize{ 0, 42, 1277, 1278, 1900, 3000, 4064, 4065, 5964, 7064, 8193 };
                    const length = lengths[(index + input[step + 2]) % lengths.len];
                    const remove = (index + input[step + 2]) % 5 == 0;
                    for (value[0..length], 0..) |*byte, offset| byte.* = @truncate(target * 7 + step + index + offset);
                    write.* = .{ .key = batch_key, .value = if (remove) null else value[0..length] };
                    expected[target].present = !remove;
                    if (!remove) {
                        expected[target].length = length;
                        @memcpy(expected[target].bytes[0..length], value[0..length]);
                    }
                }
                try table.putBatch(writes[0..count]);
            },
            else => unreachable,
        }
    }
    try verify(table, &expected);
}

test "record pages match a reference model through splits deletion reuse and reopen" {
    var input: [3072]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0xe848f71d);
    random.random().bytes(&input);
    try run(&input);
    for (0..64) |index| {
        input[index * 3] = 0;
        input[index * 3 + 1] = @intCast(index);
        input[index * 3 + 2] = 3;
        input[192 + index * 3] = 2;
        input[192 + index * 3 + 1] = @intCast(index);
        input[192 + index * 3 + 2] = 0;
    }
    try run(input[0..384]);
}

test "single values cross page boundaries and reuse their overflow pages" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 1024 };
    var payload: [65536]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    for ([_]usize{ 0, 18, storage.page_size - 24, storage.page_size - 23, 65536, 42, 0 }, 0..) |length, tick| {
        const value = records.Value.init(try store.openSpace("value"));
        try value.write(payload[0..length]);
        try store.waitDurable(try store.commit(tick + 1));
        store.deinit();
        store = try storage.Store.init(std.testing.allocator, io, options);
        const restored = records.Value.init(try store.openSpace("value"));
        var destination: [65536]u8 = undefined;
        try std.testing.expectEqual(@as(?usize, length), try restored.read(&destination));
        try std.testing.expectEqualSlices(u8, payload[0..length], destination[0..length]);
    }
    try std.testing.expect(store.metadata.pages < 24);
}

test "batched records preserve ordering through a three-level tree and complete deletion" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 4096 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    var order: [2048]u16 = undefined;
    for (&order, 0..) |*id, index| id.* = @intCast(index);
    var random = std.Random.DefaultPrng.init(0xb8532a96);
    random.random().shuffle(u16, &order);
    var keys: [128][16]u8 = undefined;
    var values: [128][1035]u8 = undefined;
    var writes: [128]records.Write = undefined;
    for (0..16) |batch| {
        for (&keys, &values, &writes, order[batch * 128 ..][0..128]) |*key, *value, *write, id| {
            std.mem.writeInt(u128, key, id, .big);
            @memset(value, @truncate(id));
            std.mem.writeInt(u32, value[0..4], id, .little);
            write.* = .{ .key = key, .value = value };
        }
        try table.putBatch(&writes);
    }
    try store.waitDurable(try store.commit(1));
    const high_water = store.metadata.pages;
    for (0..15) |batch| {
        for (&keys, &writes, 0..) |*key, *write, index| {
            std.mem.writeInt(u128, key, batch * 128 + index, .big);
            write.* = .{ .key = key, .value = null };
        }
        try table.putBatch(&writes);
    }
    try store.waitDurable(try store.commit(2));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    var reads: [128]records.Get = undefined;
    var lengths: [128]?usize = undefined;
    for (&keys, &values, &reads, 0..) |*key, *value, *read, index| {
        std.mem.writeInt(u128, key, 1920 + index, .big);
        read.* = .{ .key = key, .destination = value };
    }
    try table.getBatch(&reads, &lengths);
    for (lengths, &values, 0..) |length, *value, index| {
        try std.testing.expectEqual(@as(?usize, value.len), length);
        try std.testing.expectEqual(@as(u32, @intCast(1920 + index)), std.mem.readInt(u32, value[0..4], .little));
    }
    for (&keys, &writes) |*key, *write| write.* = .{ .key = key, .value = null };
    try table.putBatch(&writes);
    try std.testing.expectEqual(null, try table.space.getRoot());
    for (&keys, &values, &writes) |*key, *value, *write| write.* = .{ .key = key, .value = value };
    try table.putBatch(&writes);
    try std.testing.expect(store.metadata.pages <= high_water);
}

test "one batch grows multiple tree levels and changes overflow representations" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 1024 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    var keys: [192][64]u8 = @splat(@splat(0));
    const value: [1277]u8 = @splat(17);
    var writes: [192]records.Write = undefined;
    for (&keys, &writes, 0..) |*key, *write, index| {
        std.mem.writeInt(u64, key[0..8], index, .big);
        write.* = .{ .key = key, .value = &value };
    }
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    var destination: [1277]u8 = undefined;
    for (&keys) |*key| {
        try std.testing.expectEqual(@as(?usize, value.len), try table.get(key, &destination));
        try std.testing.expectEqualSlices(u8, &value, &destination);
    }
    for (&writes) |*write| write.value = null;
    try table.putBatch(&writes);
    try std.testing.expectEqual(null, try table.space.getRoot());
    const payload = try std.testing.allocator.alloc(u8, 2100000);
    defer std.testing.allocator.free(payload);
    const restored = try std.testing.allocator.alloc(u8, payload.len);
    defer std.testing.allocator.free(restored);
    for (payload, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    for ([_]usize{ 1277, 1278, 2626, 2627, 3976, 3977, 4064, 4065, 65536, 700000, 2100000, 8193, 0 }, 0..) |length, tick| {
        try table.put(&keys[0], payload[0..length]);
        try store.waitDurable(try store.commit(tick + 2));
        store.deinit();
        store = try storage.Store.init(std.testing.allocator, io, options);
        table = records.Table.init(try store.openSpace("records"), table_resources);
        try std.testing.expectEqual(@as(?usize, length), try table.get(&keys[0], restored));
        try std.testing.expectEqualSlices(u8, payload[0..length], restored[0..length]);
        _ = try structure.inspect(table);
    }
}

test "bulk sorting bounds writes and preserves last writes across sorting windows" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bulk", .{temporary.sub_path});
    defer allocator.free(path);
    const options: storage.Store.Options = .{ .path = path };
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), table_resources);
    const keys = try allocator.alloc([16]u8, 4096);
    defer allocator.free(keys);
    const writes = try allocator.alloc(records.Write, 8192);
    defer allocator.free(writes);
    var order: [4096]u16 = undefined;
    const value: [519]u8 = @splat(17);
    for (keys, &order, 0..) |*key, *id, at| {
        std.mem.writeInt(u128, key, at, .big);
        id.* = @intCast(at);
    }
    var prng = std.Random.DefaultPrng.init(0x6261746368);
    prng.random().shuffle(u16, &order);
    for (writes[0..4096], order) |*write, id| write.* = .{ .key = &keys[id], .value = &value };
    try table.putBatch(writes[0..4096]);
    try std.testing.expect(store.wal_bytes.value() < 4096 * value.len * 2);
    for (writes[4096..], order) |*write, id| write.* = .{ .key = &keys[id], .value = if (id % 3 == 0) null else "last" };
    try table.putBatch(writes);
    _ = try structure.inspect(table);
    try store.waitDurable(try store.commit(1));
    store.deinit();
    store = try storage.Store.init(allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), table_resources);
    _ = try structure.inspect(table);
    var bytes: [519]u8 = undefined;
    for (keys, 0..) |*key, id| {
        const length = try table.get(key, &bytes);
        if (id % 3 == 0) {
            try std.testing.expectEqual(null, length);
        } else {
            try std.testing.expectEqual(@as(?usize, 4), length);
            try std.testing.expectEqualStrings("last", bytes[0..length.?]);
        }
    }
}

test "batched multi-index blobs survive reopen deletion and page reuse" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const resources = try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
    defer resources.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/large", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .path = path };
    var store = try storage.Store.init(allocator, io, options);
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), resources);
    const size = 1400000;
    const source = try allocator.alloc(u8, size);
    defer allocator.free(source);
    const destination = try allocator.alloc(u8, size * 2);
    defer allocator.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    const writes = [_]records.Write{ .{ .key = "a", .value = source }, .{ .key = "b", .value = source[0 .. size - 17] } };
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    const pages = store.metadata.pages;
    store.deinit();
    store = try storage.Store.init(allocator, io, options);
    table = records.Table.init(try store.openSpace("records"), resources);
    const requests = [_]records.Get{ .{ .key = "b", .destination = destination[0..size] }, .{ .key = "a", .destination = destination[size..] } };
    var lengths: [2]?usize = undefined;
    try table.getBatch(&requests, &lengths);
    try std.testing.expectEqual(@as(?usize, size - 17), lengths[0]);
    try std.testing.expectEqual(@as(?usize, size), lengths[1]);
    try std.testing.expectEqualSlices(u8, source[0 .. size - 17], destination[0 .. size - 17]);
    try std.testing.expectEqualSlices(u8, source, destination[size..]);
    try table.putBatch(&.{ .{ .key = "a", .value = null }, .{ .key = "b", .value = null } });
    try table.putBatch(&writes);
    try std.testing.expectEqual(pages, store.metadata.pages);
    try store.waitDurable(try store.commit(2));
    _ = try structure.inspect(table);
}

test "independent lookups and mutations progress around a paused read on small stacks" {
    const Actor = struct {
        table: records.Table,
        length: usize,
        expected: u8,
        write: bool = false,
        gate: ?*fault.Disk.IoGate = null,
        bytes: [8193]u8 = undefined,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            if (self.gate) |gate| gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.execute();
            self.done.set(std.testing.io);
        }
        fn execute(self: *@This()) !void {
            if (self.write) {
                @memset(self.bytes[0..self.length], self.expected);
                try self.table.put("key", self.bytes[0..self.length]);
            }
            try std.testing.expectEqual(@as(?usize, self.length), try self.table.get("key", &self.bytes));
            try std.testing.expect(std.mem.allEqual(u8, self.bytes[0..self.length], self.expected));
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/readers", .{temporary.sub_path});
    defer allocator.free(path);
    const pages = try storage.Resources.init(allocator, io, .{ .cache_pages = 1, .readers = 2, .io_mode = .standard });
    defer pages.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .resources = pages, .maximum_wal_pages = 128 });
    defer store.deinit();
    const resources = try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 });
    defer resources.deinit();
    const a = try store.openSpace("a");
    const b = try store.openSpace("b");
    const c = try store.openSpace("c");
    const first = records.Table.init(a, resources);
    const second = records.Table.init(b, resources);
    const third = records.Table.init(c, resources);
    const large: [8193]u8 = @splat(31);
    const small: [32]u8 = @splat(22);
    try first.put("key", &large);
    try second.put("key", &small);
    const root = (try a.getRoot()).?;
    const offset = store.locations.get(@intFromEnum(root)).?.current;
    var disk = try fault.Disk.init(allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
    defer disk.deinit();
    const modeled = disk.interface();
    defer disk.detach();
    store.bindIo(modeled);
    var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset + 32 };
    disk.read_gate = &gate;
    var paused: Actor = .{ .table = first, .length = large.len, .expected = 31, .gate = &gate };
    const background = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Actor.run, .{&paused});
    defer background.join();
    defer gate.release.set(io);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var lookup: Actor = .{ .table = second, .length = small.len, .expected = 22 };
    const reader = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Actor.run, .{&lookup});
    defer reader.join();
    defer gate.release.set(io);
    try lookup.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try lookup.result;
    var mutation: Actor = .{ .table = third, .length = 32, .expected = 17, .write = true };
    const writer = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Actor.run, .{&mutation});
    defer writer.join();
    defer gate.release.set(io);
    try mutation.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try mutation.result;
    try std.testing.expect(!paused.done.isSet());
    gate.release.set(io);
    try paused.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try paused.result;
}

test "batched checkpoint retains upcoming leaves and recovers complete replacements" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/prefetch", .{temporary.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 128 });
    defer registry.deinit();
    const resources = try records.Resources.init(std.testing.allocator, io, .{ .readers = 1, .writers = 1 });
    defer resources.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .metrics = &registry });
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), resources);
    const count = 512;
    const values = try std.testing.allocator.alloc([2048]u8, count);
    defer std.testing.allocator.free(values);
    var keys: [count][8]u8 = undefined;
    var writes: [count]records.Write = undefined;
    for (&keys, values, &writes, 0..) |*key, *value, *write, index| {
        std.mem.writeInt(u64, key, index, .big);
        @memset(value, @truncate(index));
        write.* = .{ .key = key, .value = value };
    }
    try table.putBatch(&writes);
    try store.waitDurable(try store.commit(1));
    const shape = try structure.inspect(table);
    try std.testing.expectEqual(@as(usize, count), shape.records);
    for (values, 0..) |*value, index| @memset(value, @truncate(index + 1));
    const before = store.read_batches.value();
    try table.putBatch(&writes);
    const windows = try std.math.divCeil(usize, count, storage.batch_size);
    try std.testing.expect(store.read_batches.value() - before <= windows * (shape.height + 1));
    try store.waitDurable(try store.commit(2));
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    try std.testing.expectEqual(@as(u64, 2), store.lastTick());
    table = records.Table.init(try store.openSpace("records"), resources);
    var bytes: [2048]u8 = undefined;
    for (keys, values) |key, value| {
        try std.testing.expectEqual(@as(?usize, bytes.len), try table.get(&key, &bytes));
        try std.testing.expectEqualSlices(u8, &value, &bytes);
    }
    try std.testing.expectEqual(@as(usize, count), (try structure.inspect(table)).records);
}

test "sparse record batches preserve duplicate missing and caller ordered results" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/audit", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const resources = try records.Resources.init(std.testing.allocator, io, .{ .readers = 1, .writers = 1 });
    defer resources.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 16384 });
    defer store.deinit();
    var table = records.Table.init(try store.openSpace("records"), resources);
    var keys: [192][16]u8 = undefined;
    var values: [192][1035]u8 = undefined;
    var writes: [192]records.Write = undefined;
    var start: usize = 0;
    while (start < 2048) {
        const count = @min(writes.len, 2048 - start);
        for (keys[0..count], values[0..count], writes[0..count], 0..) |*key, *value, *write, index| {
            std.mem.writeInt(u128, key, start + index, .big);
            @memset(value, 0);
            std.mem.writeInt(u32, value[0..4], @intCast(start + index), .little);
            write.* = .{ .key = key, .value = value };
        }
        try table.putBatch(writes[0..count]);
        start += count;
    }
    _ = try store.commit(1);
    for ([_]usize{ 1, 24, 96, 192 }) |count| {
        var reads: [192]records.Get = undefined;
        var lengths: [192]?usize = undefined;
        for (keys[0..count], values[0..count], reads[0..count], 0..) |*key, *value, *read, index| {
            const id = if (index % 11 == 0) 3000 + index else if (index % 7 == 0) 0 else index * 2048 / count;
            std.mem.writeInt(u128, key, id, .big);
            read.* = .{ .key = key, .destination = value };
        }
        try table.getBatch(reads[0..count], lengths[0..count]);
        for (lengths[0..count], values[0..count], 0..) |length, value, index| {
            if (index % 11 == 0) {
                try std.testing.expectEqual(null, length);
            } else {
                const id = if (index % 7 == 0) 0 else index * 2048 / count;
                try std.testing.expectEqual(@as(?usize, 1035), length);
                try std.testing.expectEqual(@as(u32, @intCast(id)), std.mem.readInt(u32, value[0..4], .little));
            }
        }
    }
}

test "borrowed node navigation invalidates after page rewrite and detects new corruption" {
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/navigation", .{temporary.sub_path});
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const resources = try records.Resources.init(allocator, std.testing.io, .{ .readers = 1, .writers = 1, .navigation_pages = 1 });
    defer resources.deinit();
    var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    const space = try store.openSpace("records");
    const table = records.Table.init(space, resources);
    var value: [16]u8 = undefined;
    try table.put("key", "first");
    try std.testing.expectEqual(@as(?usize, 5), try table.get("key", &value));
    try std.testing.expectEqualSlices(u8, "first", value[0..5]);
    const root = (try space.getRoot()).?;
    var held: [1]storage.PageLease = undefined;
    try space.borrowPages(&.{root}, &held);
    defer held[0].release();
    try table.put("key", "second");
    try std.testing.expectEqual(@as(?usize, 6), try table.get("key", &value));
    try std.testing.expectEqualSlices(u8, "second", value[0..6]);
    var page: storage.Page = undefined;
    try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
    std.mem.writeInt(u16, page[16..18], 0, .little);
    try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
    try std.testing.expectError(error.Corrupt, table.get("key", &value));
}
