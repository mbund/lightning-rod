const records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const Cache = @import("records").Cache;
const Store = @import("storage").Store;

test "cache edits and eviction cannot change submitted tick snapshots" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cache", .{directory.sub_path});
    var store_registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer store_registry.deinit();
    const options: Store.Options = .{ .metrics = &store_registry, .path = path };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var owner = try Store.init(std.testing.allocator, io, options);
    var open = true;
    defer if (open) owner.deinit();
    var transaction = owner.transaction();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(try transaction.openSpace("chunks")), .{ .metrics = &registry, .slots = 2, .value_bytes = 8193 });
    for (1..4) |tick| {
        if (tick != 1) transaction = owner.transaction();
        var lease = try cache.acquire("a");
        @memset(lease.edit(), @intCast(tick));
        lease.commit(8193);
        lease.release();
        const written_before_flush = owner.wal_bytes.value();
        try cache.flush();
        try std.testing.expect(owner.wal_bytes.value() > written_before_flush);
        lease = try cache.acquire("a");
        lease.edit()[0] = @intCast(10 + tick);
        lease.commit(8193);
        lease.release();
        for ([_][]const u8{ "b", "c", "d" }) |key| {
            lease = try cache.acquire(key);
            @memset(lease.edit(), @intCast(tick));
            lease.commit(8193);
            lease.release();
        }
        try cache.flush();
        if (tick == 3) transaction.fail() else _ = try owner.commit(tick);
    }
    try owner.waitDurable(owner.lastCommit());
    try std.testing.expectEqual(@as(u64, 2), owner.durableTick());
    try std.testing.expect(owner.wal_bytes.value() > 0);
    owner.deinit();
    open = false;
    owner = try Store.init(std.testing.allocator, io, options);
    open = true;
    const reading = owner.transaction();
    defer reading.fail();
    const space = try reading.openSpace("chunks");
    var value: [8193]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, value.len), try records.Table.init(space).get("a", &value));
    try std.testing.expectEqual(@as(u8, 12), value[0]);
    for (value[1..]) |byte| try std.testing.expectEqual(@as(u8, 2), byte);
    for ([_][]const u8{ "b", "c", "d" }) |key| {
        try std.testing.expectEqual(@as(?usize, value.len), try records.Table.init(space).get(key, &value));
        for (value) |byte| try std.testing.expectEqual(@as(u8, 2), byte);
    }
}

test "cache batches dirty eviction while protecting hits and duplicate requests" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cache", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var owner = try Store.init(std.testing.allocator, io, .{ .path = path });
    defer owner.deinit();
    const transaction = owner.transaction();
    defer transaction.fail();
    const space = try transaction.openSpace("records");
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(space), .{ .metrics = &registry, .slots = 4, .value_bytes = 8 });
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| {
        const lease = try cache.acquire(key);
        lease.edit()[0] = key[0];
        lease.commit(1);
        lease.release();
    }
    var leases: [4]Cache.Lease = undefined;
    const pinned = try cache.acquire("c");
    try std.testing.expectError(error.CachePinned, cache.acquireMany(&.{ "d", "e", "f", "g" }, &leases));
    try std.testing.expectEqual(@as(u64, 0), cache.metrics.writes.value());
    try std.testing.expectEqualStrings("c", pinned.read().?);
    pinned.release();
    try cache.acquireMany(&.{ "d", "e", "f", "e" }, &leases);
    try std.testing.expectEqualStrings("d", leases[0].read().?);
    try std.testing.expectEqual(leases[1].index, leases[3].index);
    for (leases[1..]) |lease| try std.testing.expect(lease.read() == null);
    for (leases) |lease| lease.release();
    try std.testing.expectEqual(@as(u64, 2), cache.metrics.writes.value());
    try std.testing.expectEqual(@as(u64, 1), cache.metrics.eviction_write.read().?.count);
    var bytes: [8]u8 = undefined;
    for ([_][]const u8{ "a", "b" }) |key| {
        try std.testing.expectEqual(@as(?usize, 1), try records.Table.init(space).get(key, &bytes));
        try std.testing.expectEqual(key[0], bytes[0]);
    }
}

test "a failed cache load cannot become a cached missing record" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/oversized", .{directory.sub_path});
    var owner = try Store.init(allocator, io, .{ .path = path });
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const transaction = owner.transaction();
    defer transaction.fail();
    const space = try transaction.openSpace("test");
    try records.Table.init(space).put("a", "oversized");
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(space), .{ .metrics = &registry, .slots = 2, .value_bytes = 4 });
    try std.testing.expectError(error.BufferTooSmall, cache.acquire("a"));
    try std.testing.expectError(error.FailedTransaction, cache.acquire("a"));
    try std.testing.expectError(error.FailedTransaction, owner.commit(1));
    for (cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
}

test "hot records coalesce across ticks and only the complete checkpoint survives reopen" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/coalesced", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    const options: Store.Options = .{ .metrics = &registry, .path = path };
    var owner = try Store.init(std.testing.allocator, io, options);
    defer owner.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const transaction = owner.transaction();
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(try transaction.openSpace("entities")), .{ .slots = 2, .value_bytes = 8 });
    for (1..1001) |tick| {
        const lease = try cache.acquire("position");
        std.mem.writeInt(u64, lease.edit()[0..8], tick, .little);
        lease.commit(8);
        lease.release();
    }
    try std.testing.expectEqual(@as(u64, 0), owner.wal_bytes.value());
    try cache.flush();
    try std.testing.expect(owner.wal_bytes.value() > 0);
    _ = try owner.commit(1000);
    try owner.waitDurable(owner.lastCommit());
    try std.testing.expectEqual(@as(u64, 1000), owner.durableTick());

    const incomplete = owner.transaction();
    const lease = try cache.acquire("position");
    std.mem.writeInt(u64, lease.edit()[0..8], 1001, .little);
    lease.commit(8);
    lease.release();
    try cache.flush();
    incomplete.fail();
    owner.deinit();
    owner = try Store.init(std.testing.allocator, io, options);
    const read = owner.transaction();
    defer read.fail();
    var value: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 8), try records.Table.init(try read.openSpace("entities")).get("position", &value));
    try std.testing.expectEqual(@as(u64, 1000), std.mem.readInt(u64, &value, .little));
}

const OrderedStore = struct {
    last: ?u16 = null,
    writes: usize = 0,
    deletes: usize = 0,

    pub fn getBatch(_: *OrderedStore, _: []const records.Get, lengths: []?usize) !void {
        @memset(lengths, null);
    }

    pub fn putBatch(self: *OrderedStore, writes: []const records.Write) !void {
        for (writes) |write| {
            const id = std.mem.readInt(u16, write.key[0..2], .big);
            if (self.last) |last| if (id <= last) return error.UnorderedFlush;
            self.last = id;
            self.writes += 1;
            self.deletes += @intFromBool(write.value == null);
        }
    }

    pub fn fail(_: *OrderedStore) void {}
};

test "checkpoint flushes dirty cache slots in key order including tombstones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try records.CacheFor(OrderedStore).init(arena.allocator(), std.testing.io, .{}, .{ .slots = 96, .key_bytes = 2, .value_bytes = 1 });
    var order: [96]u16 = undefined;
    for (&order, 0..) |*id, index| id.* = @intCast(index);
    var prng = std.Random.DefaultPrng.init(0x666c757368);
    prng.random().shuffle(u16, &order);
    for (order) |id| {
        var key: [2]u8 = undefined;
        std.mem.writeInt(u16, &key, id, .big);
        const lease = try cache.acquire(&key);
        lease.edit()[0] = @intCast(id);
        lease.commit(1);
        if (id % 2 == 0) lease.remove();
        lease.release();
    }
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 96), cache.backend.writes);
    try std.testing.expectEqual(@as(usize, 48), cache.backend.deletes);
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 96), cache.backend.writes);
}
