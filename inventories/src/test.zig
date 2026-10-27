const std = @import("std");
const records = @import("records");
const inventories = @import("inventories");
const storage = @import("storage");
const metrics = @import("metrics");

test "inventory slot blocks and large shared definitions survive reopen and reclamation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .maximum_wal_pages = 1024 };
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
        const inventory = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_items = 2, .cache_slots = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
        if (round == 0) {
            item = try inventory.defineItem(&.{&definition});
            const split = try inventory.defineItem(&.{ definition[0..1], &.{}, definition[1..8193], definition[8193..] });
            try std.testing.expectEqualSlices(u8, &item, &split);
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
            const recreated = try inventory.defineItem(&.{&definition});
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

test "reference batches coalesce duplicates and slot swaps cancel reference changes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/references", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    const space = try store.openSpace(inventories.Inventories.id);
    const inventory = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_slots = 2, .cache_items = 1 }, .{
        .metrics = &registry,
        .storage = space,
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const first = try inventory.defineItem(&.{"first"});
    const second = try inventory.defineItem(&.{"second"});
    const before = inventory.references.metrics.acquisition.read().?.count;
    try inventory.retainItems(&.{ first, second, first, second, first });
    try std.testing.expectEqual(before + 1, inventory.references.metrics.acquisition.read().?.count);
    {
        var leases: [2]@TypeOf(inventory.references).Lease = undefined;
        try inventory.references.acquireMany(&.{ &first, &second }, &leases);
        defer for (leases) |lease| lease.release();
        try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, leases[0].read().?[0..8], .little));
        try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, leases[1].read().?[0..8], .little));
    }
    const a: inventories.Slot = .{ .owner = 1, .index = 0 };
    const b: inventories.Slot = .{ .owner = 1, .index = 1 };
    try std.testing.expect(try inventory.editMany(&.{
        .{ .slot = a, .revision = 0, .stack = .{ .item = first, .count = 1 } },
        .{ .slot = b, .revision = 0, .stack = .{ .item = second, .count = 1 } },
    }));
    const before_swap = inventory.references.metrics.acquisition.read().?.count;
    try std.testing.expect(try inventory.editMany(&.{
        .{ .slot = a, .revision = 1, .stack = .{ .item = second, .count = 1 } },
        .{ .slot = b, .revision = 1, .stack = .{ .item = first, .count = 1 } },
    }));
    try std.testing.expectEqual(before_swap, inventory.references.metrics.acquisition.read().?.count);
    try inventory.releaseItems(&.{ first, second, first, second, first });
    try std.testing.expect(try inventory.editMany(&.{
        .{ .slot = a, .revision = 2, .stack = null },
        .{ .slot = b, .revision = 2, .stack = null },
    }));
    try inventory.checkpoint(space);
    try std.testing.expectError(error.UnknownItem, inventory.acquireItem(first));
    try std.testing.expectError(error.UnknownItem, inventory.acquireItem(second));
    try store.waitDurable(try store.commit(1));
}

test "slot observers track exact mutations independently without global history" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/changes", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const inventory = try inventories.Inventories.init(arena.allocator(), io, .{ .cache_slots = 2, .cache_items = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace("inventory"),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const item = try inventory.defineItem(&.{"item"});
    const source: inventories.Slot = .{ .owner = 1, .index = 36 };
    const destination: inventories.Slot = .{ .owner = 2, .index = 45 };
    const first = try inventory.observe(arena.allocator(), 3);
    const second = try inventory.observe(arena.allocator(), 1);
    var dirty: [3]u64 = @splat(0);
    var independent: u64 = 0;
    const retired: inventories.Slot = .{ .owner = 3, .index = 0 };
    var pending = try storage.system.IndexSet.init(arena.allocator(), 3);
    first.watch(source.owner, &.{source.index}, .{ .dirty = &dirty[0], .changed = .{ .set = &pending, .index = 0 } });
    first.watch(destination.owner, &.{destination.index}, .{ .dirty = &dirty[1], .changed = .{ .set = &pending, .index = 1 } });
    first.watch(retired.owner, &.{retired.index}, .{ .dirty = &dirty[2], .changed = .{ .set = &pending, .index = 2 } });
    second.watch(source.owner, &.{source.index}, .{ .dirty = &independent });
    try std.testing.expectEqual([_]u64{ 1, 1, 1 }, dirty);
    try std.testing.expectEqual(@as(u64, 1), independent);
    try std.testing.expectEqual(@as(usize, 3), pending.count);
    pending.clear();
    dirty = @splat(0);
    independent = 0;
    try std.testing.expect(try inventory.set(source, 0, .{ .item = item, .count = 10 }));
    try std.testing.expectEqualSlices(usize, &.{0}, pending.values());
    try std.testing.expectEqual([_]u64{ 1, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 1), independent);
    dirty = @splat(0);
    independent = 0;
    try std.testing.expect(!try inventory.set(source, 0, null));
    try std.testing.expect(!try inventory.editMany(&.{.{ .slot = source, .revision = 0, .stack = null }}));
    try std.testing.expectEqual([_]u64{ 0, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 0), independent);
    try std.testing.expect(try inventory.editMany(&.{.{ .slot = source, .revision = 1, .stack = .{ .item = item, .count = 8 } }}));
    try std.testing.expectEqual([_]u64{ 1, 0, 0 }, dirty);
    try std.testing.expectEqual(inventories.MoveResult.moved, try inventory.move(.{
        .from = source,
        .to = destination,
        .from_revision = 2,
        .to_revision = 0,
        .count = 3,
        .maximum_stack = 64,
    }));
    try std.testing.expectEqual([_]u64{ 1, 1, 0 }, dirty);
    try inventory.retire(retired);
    try std.testing.expectEqual([_]u64{ 1, 1, 1 }, dirty);
    dirty = @splat(0);
    independent = 0;
    for (0..1024) |index| try std.testing.expect(try inventory.set(.{ .owner = 99, .index = 0 }, index, .{ .item = item, .count = @intCast(1 + index % 2) }));
    try std.testing.expectEqual([_]u64{ 0, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 0), independent);
    first.unwatch(source.owner);
    try std.testing.expect(try inventory.set(source, 3, null));
    try std.testing.expectEqual([_]u64{ 0, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 1), independent);
    first.watch(source.owner, &.{ 36, 45 }, .{ .dirty = &dirty[0] });
    dirty = @splat(0);
    independent = 0;
    try std.testing.expect(try inventory.set(.{ .owner = source.owner, .index = 37 }, 0, .{ .item = item, .count = 1 }));
    try std.testing.expectEqual([_]u64{ 0, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 0), independent);
    try std.testing.expect(try inventory.set(.{ .owner = source.owner, .index = 45 }, 0, .{ .item = item, .count = 1 }));
    try std.testing.expectEqual([_]u64{ 2, 0, 0 }, dirty);
    try std.testing.expectEqual(@as(u64, 0), independent);
    inventory.unobserve(arena.allocator(), second);
    inventory.unobserve(arena.allocator(), first);
    try std.testing.expectEqual(null, inventory.observers);
}

test "slot backend scratch preserves duplicate ordering and survives reuse" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/slot-scratch", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const inventory = try inventories.Inventories.init(arena.allocator(), std.testing.io, .{ .cache_slots = 4, .cache_items = 1 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(inventories.Inventories.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), std.testing.io, .{}),
    });
    const backend = &inventory.cache.backend;
    var keys: [4][18]u8 = undefined;
    for (&keys, [_]u16{ 0, 1, 16, 17 }) |*key, index| {
        std.mem.writeInt(u128, key[0..16], 1, .big);
        std.mem.writeInt(u16, key[16..18], index, .big);
    }
    const first: [42]u8 = @splat(1);
    const second: [42]u8 = @splat(2);
    var values: [4][42]u8 = undefined;
    var reads: [4]records.Get = undefined;
    var lengths: [4]?usize = undefined;
    for (&keys, &values, &reads) |*key, *value, *read| read.* = .{ .key = key, .destination = value };
    for (0..3) |_| {
        try backend.putBatch(&.{
            .{ .key = &keys[0], .value = &first },
            .{ .key = &keys[2], .value = &second },
            .{ .key = &keys[1], .value = &first },
            .{ .key = &keys[0], .value = &second },
        });
        try backend.getBatch(&reads, &lengths);
        try std.testing.expectEqualSlices(?usize, &.{ 42, 42, 42, null }, &lengths);
        try std.testing.expectEqualSlices(u8, &second, &values[0]);
        try std.testing.expectEqualSlices(u8, &first, &values[1]);
        try std.testing.expectEqualSlices(u8, &second, &values[2]);
        try backend.putBatch(&.{
            .{ .key = &keys[0], .value = null },
            .{ .key = &keys[1], .value = null },
            .{ .key = &keys[2], .value = null },
        });
        try backend.getBatch(&reads, &lengths);
        try std.testing.expectEqualSlices(?usize, &.{ null, null, null, null }, &lengths);
    }
}

test "slot block reads preserve unsorted duplicate and missing request positions" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    const space = try store.openSpace(inventories.Inventories.id);
    const inventory = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
    const item = try inventory.defineItem(&.{"item"});
    var keys: [80][18]u8 = undefined;
    var expected: [64][42]u8 = undefined;
    var edits: [64]inventories.Edit = undefined;
    const indices = [_]u16{ 0, 1, 15, 16, 17, 31, 32, 65535 };
    for (&keys, 0..) |*key, index| {
        std.mem.writeInt(u128, key[0..16], index / indices.len + 1, .big);
        std.mem.writeInt(u16, key[16..18], indices[index % indices.len], .big);
        if (index < edits.len) edits[index] = .{ .slot = .{ .owner = index / indices.len + 1, .index = indices[index % indices.len] }, .revision = 0, .stack = .{ .item = item, .count = @intCast(index + 1) } };
    }
    try std.testing.expect(try inventory.editMany(&edits));
    for (keys[0..expected.len], &expected) |key, *value| {
        const lease = try inventory.cache.acquire(&key);
        defer lease.release();
        @memcpy(value, lease.read().?);
    }
    try inventory.checkpoint(space);
    for (0..3) |pass| {
        var requests: [128]records.Get = undefined;
        var output: [128][42]u8 = undefined;
        var lengths: [128]?usize = undefined;
        for (&requests, &output, 0..) |*request, *destination, position| {
            const index = (position * 73 + pass) % requests.len % keys.len;
            request.* = .{ .key = &keys[index], .destination = destination };
        }
        try inventory.cache.backend.getBatch(&requests, &lengths);
        for (output, lengths, 0..) |value, length, position| {
            const index = (position * 73 + pass) % requests.len % keys.len;
            if (index >= expected.len) {
                try std.testing.expectEqual(null, length);
            } else {
                try std.testing.expectEqual(@as(?usize, 42), length);
                try std.testing.expectEqualSlices(u8, &expected[index], &value);
            }
        }
    }
}
