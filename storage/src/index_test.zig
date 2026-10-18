const std = @import("std");
const wal_index = @import("index.zig");

test "index deletion preserves wrapped collision chains" {
    var keys: [14]u64 = undefined;
    var found: usize = 0;
    var candidate: u64 = 0;
    while (found < keys.len) : (candidate += 1) {
        if (std.hash.int(candidate) & 31 != 30) continue;
        keys[found] = candidate;
        found += 1;
    }
    for (keys) |removed| {
        var index = try wal_index.Index.init(std.testing.allocator, 16);
        defer index.deinit(std.testing.allocator);
        for (keys, 0..) |key, i| index.putAssumeCapacity(key, .{ .current = i + 1, .owner = 1 });
        try std.testing.expect(index.remove(removed));
        try std.testing.expect(!index.remove(removed));
        for (keys, 0..) |key, i| {
            if (key == removed) {
                try std.testing.expectEqual(null, index.get(key));
            } else try std.testing.expectEqual(i + 1, index.get(key).?.current);
        }
        index.putAssumeCapacity(removed, .{ .current = 99, .owner = 2 });
        try std.testing.expectEqual(keys.len, index.count());
        try std.testing.expectEqual(@as(u64, 99), index.getPtr(removed).?.current);
    }
}

test "index churn agrees with an independent membership model" {
    var index = try wal_index.Index.init(std.testing.allocator, 128);
    defer index.deinit(std.testing.allocator);
    var expected: [256]?u64 = @splat(null);
    var random = std.Random.DefaultPrng.init(0x696e646578);
    for (0..20_000) |step| {
        const key = random.random().uintLessThan(usize, expected.len);
        if (random.random().boolean()) {
            try std.testing.expectEqual(expected[key] != null, index.remove(key));
            expected[key] = null;
        } else if (expected[key] != null or index.count() < 128) {
            index.putAssumeCapacity(key, .{ .current = step, .owner = 1 });
            expected[key] = step;
        }
        if (step % 32 != 0) continue;
        var count: usize = 0;
        for (expected, 0..) |value, id| {
            try std.testing.expectEqual(value != null, index.contains(id));
            if (value) |current| {
                try std.testing.expectEqual(current, index.get(id).?.current);
                count += 1;
            }
        }
        try std.testing.expectEqual(count, index.count());
        var iterator = index.iterator();
        while (iterator.next()) |entry| {
            try std.testing.expectEqual(expected[entry.key_ptr.*].?, entry.value_ptr.current);
            count -= 1;
        }
        try std.testing.expectEqual(@as(usize, 0), count);
    }
}
