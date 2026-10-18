const std = @import("std");
const inventories = @import("inventories");
const storage = @import("storage");
const metrics = @import("metrics");

test "inventory slot blocks and large shared definitions survive reopen and reclamation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
    var definition: [65536]u8 = undefined;
    for (&definition, 0..) |*byte, index| byte.* = @truncate(index *% 73);
    var item: inventories.ItemId = undefined;
    const indexes = [_]u16{ 0, 63, 64, 65535 };
    for (0..2) |round| {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        const space = try store.openSpace(inventories.Inventories.id);
        const inventory = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_items = 2, .cache_slots = 2 }, .{ .metrics = &registry, .storage = space });
        if (round == 0) {
            item = try inventory.defineItem(&definition);
            for (indexes) |index| try std.testing.expect(try inventory.set(.{ .owner = 99, .index = index }, 0, .{ .item = item, .count = 10 }));
            try inventory.checkpoint(space);
            try store.waitDurable(try store.commit(1));
            continue;
        }
        for (indexes) |index| {
            const value = try inventory.get(.{ .owner = 99, .index = index });
            try std.testing.expectEqual(@as(u16, 10), value.stack.?.count);
            try std.testing.expectEqualSlices(u8, &item, &value.stack.?.item);
        }
        {
            const lease = try inventory.acquireItem(item);
            defer lease.release();
            try std.testing.expectEqualSlices(u8, &definition, lease.read().?);
        }
        for (indexes) |index| try std.testing.expect(try inventory.set(.{ .owner = 99, .index = index }, 1, null));
        try inventory.checkpoint(space);
        try std.testing.expectError(error.UnknownItem, inventory.acquireItem(item));
        try store.waitDurable(try store.commit(2));
        const high_water = store.metadata.pages;
        for (0..10) |cycle| {
            const recreated = try inventory.defineItem(&definition);
            try std.testing.expectEqualSlices(u8, &item, &recreated);
            const slot: inventories.Slot = .{ .owner = 100, .index = 0 };
            const previous = try inventory.get(slot);
            try std.testing.expect(try inventory.set(slot, previous.revision, .{ .item = item, .count = 1 }));
            try inventory.retainItems(&.{item});
            try std.testing.expect(try inventory.set(slot, previous.revision + 1, null));
            try inventory.checkpoint(space);
            const lease = try inventory.acquireItem(item);
            try std.testing.expectEqualSlices(u8, &definition, lease.read().?);
            lease.release();
            try inventory.releaseItems(&.{item});
            try inventory.checkpoint(space);
            try std.testing.expectError(error.UnknownItem, inventory.acquireItem(item));
            try store.waitDurable(try store.commit(cycle + 3));
        }
        try std.testing.expect(store.metadata.pages <= high_water + 8);
    }
}
