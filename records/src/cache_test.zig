const records = @import("records");
const metrics = @import("metrics");
const std = @import("std");
const Cache = @import("records").Cache;
const Store = @import("storage").Store;
const storage = @import("storage");

test "resident batches preserve caller ordering and duplicate leases without backend access" {
    const Backend = struct {
        pub const write_batch_size = 192;
        reject_reads: bool = false,

        pub fn getBatch(self: *@This(), requests: []const records.Get, lengths: []?usize) !void {
            if (self.reject_reads) return error.UnexpectedRead;
            for (requests, lengths) |request, *length| {
                request.destination[0] = request.key[0];
                length.* = 1;
            }
        }

        pub fn putBatch(_: *@This(), _: []const records.Write) !void {
            return error.UnexpectedWrite;
        }

        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var memory: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var cache = try TestCache.init(allocator.allocator(), std.testing.io, .{}, .{ .slots = 192, .key_bytes = 1, .value_bytes = 1 });
    const assigned = allocator.end_index;
    var keys: [96][1]u8 = undefined;
    var requests: [192][]const u8 = undefined;
    var leases: [192]TestCache.Lease = undefined;
    for (&keys, requests[0..keys.len], 0..) |*key, *request, index| {
        key.* = .{@intCast(index)};
        request.* = key;
    }
    try cache.acquireMany(requests[0..keys.len], leases[0..keys.len]);
    for (leases[0..keys.len]) |lease| lease.release();
    cache.backend.reject_reads = true;
    for (0..4) |pass| {
        for (&requests, 0..) |*request, index| request.* = &keys[(index * 73 + pass) % keys.len];
        try cache.acquireMany(&requests, &leases);
        try std.testing.expectEqual(keys.len, cache.pinned_entries);
        try std.testing.expectEqual(leases[0].index, leases[keys.len].index);
        for (requests, leases) |request, lease| try std.testing.expectEqualSlices(u8, request, lease.read().?);
        for (leases) |lease| lease.release();
        try std.testing.expectEqual(@as(usize, 0), cache.pinned_entries);
    }
    cache.backend.reject_reads = false;
    try cache.acquireMany(&.{ &keys[0], &.{250}, &keys[0] }, leases[0..3]);
    try std.testing.expectEqual(@as(usize, 2), cache.pinned_entries);
    try std.testing.expectEqual(leases[0].index, leases[2].index);
    for (leases[0..3]) |lease| lease.release();
    var victims: [1]TestCache.Lease = undefined;
    try std.testing.expect((try cache.reserveMany(&.{&.{251}}, leases[0..1], &victims, cache.entries.len)) == .ready);
    leases[0].release();
    try std.testing.expectError(error.CacheLoading, cache.acquireMany(&.{ &keys[0], &.{251} }, leases[0..2]));
    try std.testing.expectEqual(@as(usize, 0), cache.pinned_entries);
    try std.testing.expectError(error.InvalidArgument, cache.acquireMany(&.{ &keys[0], "" }, leases[0..2]));
    try std.testing.expectEqual(@as(usize, 0), cache.pinned_entries);
    try std.testing.expectEqual(assigned, allocator.end_index);
}

test "cache edits and eviction cannot change submitted tick snapshots" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
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
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(try transaction.openSpace("chunks"), table_resources), .{ .metrics = &registry, .slots = 2, .value_bytes = 8193 });
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
    try std.testing.expectEqual(@as(?usize, value.len), try records.Table.init(space, table_resources).get("a", &value));
    try std.testing.expectEqual(@as(u8, 12), value[0]);
    for (value[1..]) |byte| try std.testing.expectEqual(@as(u8, 2), byte);
    for ([_][]const u8{ "b", "c", "d" }) |key| {
        try std.testing.expectEqual(@as(?usize, value.len), try records.Table.init(space, table_resources).get(key, &value));
        for (value) |byte| try std.testing.expectEqual(@as(u8, 2), byte);
    }
}

test "cache batches dirty eviction while protecting hits and duplicate requests" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
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
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .metrics = &registry, .slots = 4, .value_bytes = 8 });
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
        try std.testing.expectEqual(@as(?usize, 1), try records.Table.init(space, table_resources).get(key, &bytes));
        try std.testing.expectEqual(key[0], bytes[0]);
    }
}

test "a failed cache load cannot become a cached missing record" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
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
    try records.Table.init(space, table_resources).put("a", "oversized");
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .metrics = &registry, .slots = 2, .value_bytes = 4 });
    try std.testing.expectError(error.BufferTooSmall, cache.acquire("a"));
    try std.testing.expectError(error.FailedTransaction, cache.acquire("a"));
    try std.testing.expectError(error.FailedTransaction, owner.commit(1));
    for (cache.entries) |entry| try std.testing.expectEqual(@as(usize, 0), entry.pins);
}

test "hot records coalesce across ticks and only the complete checkpoint survives reopen" {
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
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
    var cache = try Cache.init(arena.allocator(), io, records.Table.init(try transaction.openSpace("entities"), table_resources), .{ .slots = 2, .value_bytes = 8 });
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
    try std.testing.expectEqual(@as(?usize, 8), try records.Table.init(try read.openSpace("entities"), table_resources).get("position", &value));
    try std.testing.expectEqual(@as(u64, 1000), std.mem.readInt(u64, &value, .little));
}

const OrderedStore = struct {
    pub const write_batch_size = 192;
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

test "unpublished fills pin final buffers without poisoning temporary readers or checkpoints" {
    const Backend = struct {
        pub const write_batch_size = 192;
        writes: usize = 0,
        pub fn getBatch(_: *@This(), _: []const records.Get, lengths: []?usize) !void {
            @memset(lengths, null);
        }
        pub fn putBatch(self: *@This(), writes: []const records.Write) !void {
            self.writes += writes.len;
        }
        pub fn fail(_: *@This()) void {}
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try records.CacheFor(Backend).init(arena.allocator(), std.testing.io, .{}, .{ .slots = 1, .key_bytes = 1, .value_bytes = 8193 });
    const initial = try cache.acquire("a");
    const canceled = initial.reserve();
    initial.release();
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 0), cache.backend.writes);
    try std.testing.expectError(error.CachePinned, cache.acquire("b"));
    canceled.cancel();
    const next = try cache.acquire("b");
    const fill = next.reserve();
    next.release();
    @memset(fill.bytes, 7);
    fill.publish(fill.bytes.len);
    const read = try cache.acquire("b");
    try std.testing.expectEqual(fill.bytes.ptr, read.read().?.ptr);
    try std.testing.expectEqual(@as(u8, 7), read.read().?[8192]);
    read.release();
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 1), cache.backend.writes);
}

test "fully pinned caches preserve batched reads and record progress at every small capacity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for (1..5) |capacity| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/pinned", .{directory.sub_path});
        var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
        defer registry.deinit();
        const page_resources = try storage.Resources.init(allocator, io, .{ .cache_pages = capacity });
        defer page_resources.deinit();
        const table_resources = try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
        defer table_resources.deinit();
        var store = try Store.init(allocator, io, .{ .path = path, .resources = page_resources, .metrics = &registry });
        defer store.deinit();
        const space = try store.openSpace("pages");
        var ids: [storage.batch_size + 4]storage.PageId = undefined;
        try space.allocatePages(ids[0 .. capacity + storage.batch_size]);
        const pinned: storage.Page = @splat(11);
        const requested: storage.Page = @splat(22);
        var writes: [storage.batch_size + 4]storage.Write = undefined;
        for (ids[0 .. capacity + storage.batch_size], writes[0 .. capacity + storage.batch_size], 0..) |id, *write, index| write.* = .{ .id = id, .source = if (index < capacity) &pinned else &requested };
        try space.writePages(writes[0 .. capacity + storage.batch_size]);
        const destinations = try allocator.alloc(storage.Page, storage.batch_size);
        defer allocator.free(destinations);
        var leases: [4]storage.PageLease = undefined;
        {
            try space.borrowPages(ids[0..capacity], leases[0..capacity]);
            defer storage.PageLease.releaseMany(leases[0..capacity]);
            var reads: [storage.batch_size]storage.Read = undefined;
            for (ids[capacity..][0..storage.batch_size], destinations, &reads) |id, *destination, *read| read.* = .{ .id = id, .destination = destination };
            const before = store.read_batches.value();
            try space.readPages(&reads);
            try std.testing.expectEqual(@as(u64, 1), store.read_batches.value() - before);
            for (destinations) |*destination| try std.testing.expectEqualSlices(u8, &requested, destination);
            const table = records.Table.init(try store.openSpace("tree"), table_resources);
            const large: [8193]u8 = @splat(37);
            try table.putBatch(&.{ .{ .key = "small", .value = "value" }, .{ .key = "large", .value = &large } });
            var small: [5]u8 = undefined;
            var big: [8193]u8 = undefined;
            var lengths: [2]?usize = undefined;
            try table.getBatch(&.{ .{ .key = "small", .destination = &small }, .{ .key = "large", .destination = &big } }, &lengths);
            try std.testing.expectEqual(@as(?usize, small.len), lengths[0]);
            try std.testing.expectEqual(@as(?usize, large.len), lengths[1]);
            try std.testing.expectEqualStrings("value", &small);
            try std.testing.expectEqualSlices(u8, &large, &big);
            for (leases[0..capacity]) |lease| try std.testing.expectEqualSlices(u8, &pinned, lease.bytes());
        }
        try store.waitDurable(try store.commit(1));
    }
}

test "cache churn keeps lookup bounded and rebuilds ordering only for scans" {
    const Backend = struct {
        pub const write_batch_size = 192;
        pub fn getBatch(_: @This(), _: []const records.Get, lengths: []?usize) !void {
            @memset(lengths, null);
        }
        pub fn putBatch(_: @This(), _: []const records.Write) !void {}
        pub fn fail(_: @This()) void {}
        pub fn scan(_: @This(), _: *records.ScanCursor, _: []records.ScanEntry) !records.ScanResult {
            return .{ .count = 0, .more = false };
        }
    };
    var memory: [128 * 1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&memory);
    var cache = try records.CacheFor(Backend).init(fixed.allocator(), std.testing.io, .{}, .{ .slots = 16, .key_bytes = 8, .value_bytes = 8, .scan_batch = 16 });
    const assigned = fixed.end_index;
    const capacity = cache.lookup.capacity();
    for (0..4096) |index| {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, 4095 - index, .big);
        const lease = try cache.acquire(&key);
        try std.testing.expect(lease.read() == null);
        lease.edit()[0] = @intCast(index % 256);
        lease.commit(1);
        lease.release();
        try std.testing.expectEqual(capacity, cache.lookup.capacity());
    }
    try std.testing.expect(cache.index_dirty);
    var cursor_bytes: [8]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &cursor_bytes };
    var rows: [16]records.BorrowedEntry = undefined;
    const result = try cache.scanBorrowed(&cursor, &rows);
    try std.testing.expectEqual(@as(usize, 16), result.count);
    try std.testing.expect(!result.more and !cache.index_dirty);
    for (rows[0..result.count], 0..) |row, index| {
        try std.testing.expectEqual(@as(u64, index), std.mem.readInt(u64, row.key[0..8], .big));
        try std.testing.expectEqual(@as(u8, @intCast(255 - index)), row.value[0]);
    }
    try cache.flush();
    const zero: [8]u8 = @splat(0);
    cache.invalidate(&zero);
    var new_key: [8]u8 = undefined;
    std.mem.writeInt(u64, &new_key, 1000, .big);
    const replacement = try cache.acquire(&new_key);
    replacement.edit()[0] = 37;
    replacement.commit(1);
    replacement.release();
    cursor.after_len = 0;
    const updated = try cache.scanBorrowed(&cursor, &rows);
    try std.testing.expectEqual(cache.lookup.count(), updated.count);
    for (rows[0..updated.count], 0..) |row, index| {
        try std.testing.expect(!std.mem.eql(u8, &zero, row.key));
        if (index != 0) try std.testing.expect(std.mem.order(u8, rows[index - 1].key, row.key) == .lt);
    }
    try std.testing.expectEqualSlices(u8, &new_key, rows[updated.count - 1].key);
    try std.testing.expectEqual(@as(u8, 37), rows[updated.count - 1].value[0]);
    try cache.flush();
    while (cache.lookup.count() != 0) cache.invalidate(cache.lookup.keys()[0]);
    try std.testing.expectEqual(@as(usize, 0), cache.lookup.count());
    try std.testing.expectEqual(assigned, fixed.end_index);
}

test "blocked reservations report the exact deficit without retaining hits or touching storage" {
    const Backend = struct {
        pub const write_batch_size = 192;
        reads: usize = 0,
        pub fn getBatch(self: *@This(), requests: []const records.Get, lengths: []?usize) !void {
            self.reads += requests.len;
            @memset(lengths, null);
        }
        pub fn putBatch(_: *@This(), _: []const records.Write) !void {
            return error.UnexpectedWrite;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 4, .value_bytes = 1 });
    const a = try cache.acquire("a");
    defer a.release();
    const b = try cache.acquire("b");
    defer b.release();
    const c = try cache.acquire("c");
    var held = true;
    defer if (held) c.release();
    var leases: [4]TestCache.Lease = undefined;
    var victims: [4]TestCache.Lease = undefined;
    const reads = cache.backend.reads;
    const result = try cache.reserveMany(&.{ "a", "x", "x", "y" }, &leases, &victims, cache.entries.len);
    try std.testing.expectEqual(@as(usize, 1), result.blocked);
    try std.testing.expectEqual(reads, cache.backend.reads);
    try std.testing.expectEqual(@as(usize, 1), cache.entries[a.index].pins);
    try std.testing.expectEqual(@as(usize, 1), cache.entries[b.index].pins);
    try std.testing.expectEqual(@as(usize, 1), cache.entries[c.index].pins);
    c.release();
    held = false;
    try std.testing.expect((try cache.reserveMany(&.{ "a", "x", "x", "y" }, &leases, &victims, cache.entries.len)) == .ready);
    try std.testing.expectEqual(reads, cache.backend.reads);
    for (leases) |lease| lease.release();
    try std.testing.expectEqual(@as(usize, 1), cache.entries[a.index].pins);
}

test "reservation transfers only selected dirty victims without backend writes" {
    const Backend = struct {
        pub const write_batch_size = 192;
        writes: usize = 0,
        pub fn getBatch(_: *@This(), _: []const records.Get, lengths: []?usize) !void {
            @memset(lengths, null);
        }
        pub fn putBatch(self: *@This(), entries: []const records.Write) !void {
            self.writes += entries.len;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 4, .value_bytes = 1 });
    for ([_][]const u8{ "a", "b", "c", "d" }) |key| {
        const lease = try cache.acquire(key);
        lease.edit()[0] = key[0];
        lease.commit(1);
        lease.release();
    }
    var leases: [1]TestCache.Lease = undefined;
    var victims: [1]TestCache.Lease = undefined;
    const reservation = try cache.reserveMany(&.{"e"}, &leases, &victims, cache.entries.len);
    try std.testing.expect(reservation == .writeback);
    try std.testing.expectEqual(@as(usize, 1), reservation.writeback.len);
    try std.testing.expectEqual(@as(usize, 0), cache.backend.writes);
    const victim = reservation.writeback[0];
    try std.testing.expectEqual(@as(usize, 1), cache.entries[victim.index].pins);
    const old = victim.read().?[0];
    const replacement = try cache.acquire("e");
    defer replacement.release();
    try std.testing.expect(replacement.index != victim.index);
    try std.testing.expectEqual(old, victim.read().?[0]);
    victim.release();
}

test "empty cache batches do no timed work and preserve failure checks" {
    const Backend = struct {
        pub const write_batch_size = 192;
        calls: usize = 0,
        pub fn getBatch(self: *@This(), _: []const records.Get, lengths: []?usize) !void {
            self.calls += 1;
            @memset(lengths, null);
        }
        pub fn putBatch(self: *@This(), _: []const records.Write) !void {
            self.calls += 1;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 32 });
    defer registry.deinit();
    var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 1, .value_bytes = 1, .metrics = &registry });
    var empty: [0]TestCache.Lease = .{};
    for (0..1000) |_| {
        try cache.acquireMany(&.{}, &empty);
        const reservation = try cache.reserveMany(&.{}, &empty, &empty, cache.entries.len);
        try std.testing.expect(reservation == .ready);
    }
    try std.testing.expectEqual(@as(usize, 0), cache.backend.calls);
    try std.testing.expectEqual(@as(u64, 0), cache.metrics.acquisition.read().?.count);
    cache.failed = true;
    try std.testing.expectError(error.FailedTransaction, cache.acquireMany(&.{}, &empty));
    try std.testing.expectError(error.FailedTransaction, cache.reserveMany(&.{}, &empty, &empty, cache.entries.len));
}

test "distinct pin accounting includes duplicate leases fills writeback and failures" {
    const Backend = struct {
        pub const write_batch_size = 192;
        fail_reads: bool = false,
        pub fn getBatch(self: *@This(), _: []const records.Get, lengths: []?usize) !void {
            if (self.fail_reads) return error.InjectedFailure;
            @memset(lengths, null);
        }
        pub fn putBatch(_: *@This(), _: []const records.Write) !void {}
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    const Verify = struct {
        fn count(cache: *const TestCache, expected: usize) !void {
            var actual: usize = 0;
            for (cache.entries) |entry| actual += @intFromBool(entry.pins != 0);
            try std.testing.expectEqual(expected, actual);
            try std.testing.expectEqual(actual, cache.pinned_entries);
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 2, .value_bytes = 8 });
    var duplicates: [2]TestCache.Lease = undefined;
    try cache.acquireMany(&.{ "a", "a" }, &duplicates);
    try Verify.count(&cache, 1);
    const fill = duplicates[0].reserve();
    duplicates[0].release();
    duplicates[1].release();
    try Verify.count(&cache, 1);
    fill.load(null);
    try Verify.count(&cache, 0);
    const dirty = try cache.acquire("a");
    dirty.edit()[0] = 1;
    dirty.commit(1);
    dirty.release();
    const second = try cache.acquire("b");
    const retained = second.retain();
    try Verify.count(&cache, 1);
    var output: [2]TestCache.Lease = undefined;
    var victims: [2]TestCache.Lease = undefined;
    try std.testing.expect((try cache.reserveMany(&.{ "c", "d" }, &output, &victims, cache.entries.len)) == .blocked);
    try Verify.count(&cache, 1);
    const reservation = try cache.reserveMany(&.{"c"}, output[0..1], &victims, cache.entries.len);
    try std.testing.expect(reservation == .writeback);
    try Verify.count(&cache, 2);
    for (reservation.writeback) |lease| lease.release();
    second.release();
    try Verify.count(&cache, 1);
    retained.release();
    try Verify.count(&cache, 0);
    const repinned = cache.pin(dirty.index);
    try Verify.count(&cache, 1);
    repinned.release();
    try Verify.count(&cache, 0);
    cache.backend.fail_reads = true;
    try std.testing.expectError(error.InjectedFailure, cache.acquireMany(&.{ "c", "d" }, &output));
    try Verify.count(&cache, 0);
}

test "blocked reservations preserve pins and replacement state" {
    const Backend = struct {
        pub const write_batch_size = 192;
        pub fn getBatch(_: *@This(), requests: []const records.Get, lengths: []?usize) !void {
            for (requests, lengths) |request, *length| {
                request.destination[0] = request.key[0];
                length.* = 1;
            }
        }
        pub fn putBatch(_: *@This(), _: []const records.Write) !void {
            return error.UnexpectedWrite;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 4, .key_bytes = 1, .value_bytes = 1 });
    var held: [4]TestCache.Lease = undefined;
    try cache.acquireMany(&.{ "a", "b", "c", "d" }, &held);
    defer for (held) |lease| lease.release();
    const replacement = cache.replacement;
    var output: [3]TestCache.Lease = undefined;
    var victims: [3]TestCache.Lease = undefined;
    for (0..64) |_| {
        const result = try cache.reserveMany(&.{ "a", "e", "e" }, &output, &victims, cache.entries.len);
        try std.testing.expectEqual(@as(usize, 1), result.blocked);
        try std.testing.expectEqual(@as(usize, 4), cache.pinned_entries);
        try std.testing.expectEqual(@as(usize, 1), cache.entries[held[0].index].pins);
        try std.testing.expectEqual(replacement, cache.replacement);
        for (cache.entries) |entry| try std.testing.expect(entry.referenced);
    }
}

test "batched checkpoint honors backend capacity with encoded and borrowed values" {
    const Backend = struct {
        pub const write_batch_size = 7;
        calls: usize = 0,
        records: usize = 0,

        pub fn getBatch(_: *@This(), _: []const records.Get, lengths: []?usize) !void {
            @memset(lengths, null);
        }
        pub fn putBatch(self: *@This(), writes: []const records.Write) !void {
            try std.testing.expect(writes.len > 0 and writes.len <= write_batch_size);
            self.calls += 1;
            self.records += writes.len;
        }
        pub fn fail(_: *@This()) void {}
        fn encode(input: []const u8, _: []u8) storage.Error![]const u8 {
            return input;
        }
    };
    for ([_]bool{ false, true }) |encoded| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var cache = try records.CacheFor(Backend).init(arena.allocator(), std.testing.io, .{}, .{
            .slots = 64,
            .key_bytes = 1,
            .value_bytes = 1,
            .codec = if (encoded) .{ .encode = Backend.encode } else null,
        });
        for (0..64) |index| {
            const key = [_]u8{@intCast(index)};
            const lease = try cache.acquire(&key);
            lease.edit()[0] = @intCast(index);
            lease.commit(1);
            lease.release();
        }
        try cache.flush();
        try std.testing.expectEqual(@as(usize, 10), cache.backend.calls);
        try std.testing.expectEqual(@as(usize, 64), cache.backend.records);
        try cache.flush();
        try std.testing.expectEqual(@as(usize, 10), cache.backend.calls);
        var keys: [20][1]u8 = undefined;
        var writes: [20]records.Write = undefined;
        const value = [_]u8{1};
        for (&keys, &writes, 0..) |*key, *write, index| {
            key.* = .{@intCast(index)};
            write.* = .{ .key = key, .value = &value };
        }
        try cache.writeBack(&writes);
        try std.testing.expectEqual(@as(usize, 13), cache.backend.calls);
        try std.testing.expectEqual(@as(usize, 84), cache.backend.records);
    }
}

test "large acquisitions protect later hits before evicting any records" {
    const Backend = struct {
        pub const write_batch_size = 192;
        reads: usize = 0,
        reject_reads: bool = false,
        writes: usize = 0,
        pub fn getBatch(self: *@This(), requests: []const records.Get, lengths: []?usize) !void {
            if (self.reject_reads) return error.InjectedReadFailure;
            self.reads += requests.len;
            for (requests, lengths) |request, *length| {
                request.destination[0] = 1;
                length.* = 1;
            }
        }
        pub fn putBatch(self: *@This(), writes: []const records.Write) !void {
            self.writes += writes.len;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    for ([_]bool{ false, true }) |hits_first| {
        for ([_]bool{ false, true }) |reject_reads| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var cache = try TestCache.init(arena.allocator(), std.testing.io, .{}, .{ .slots = 384, .key_bytes = 4, .value_bytes = 1 });
            var bytes: [576][4]u8 = undefined;
            for (&bytes, 0..) |*key, index| std.mem.writeInt(u32, key, @intCast(index), .big);
            for (bytes[0..384], 0..) |key, index| {
                const lease = try cache.acquire(&key);
                if (index < 192) {
                    lease.edit()[0] = 2;
                    lease.commit(1);
                }
                lease.release();
            }
            cache.backend.reads = 0;
            cache.backend.writes = 0;
            var keys: [384][]const u8 = undefined;
            for (0..192) |index| {
                keys[if (hits_first) index else 192 + index] = &bytes[index];
                keys[if (hits_first) 192 + index else index] = &bytes[384 + index];
            }
            var leases: [384]TestCache.Lease = undefined;
            cache.backend.reject_reads = reject_reads;
            if (reject_reads) {
                try std.testing.expectError(error.InjectedReadFailure, cache.acquireMany(&keys, &leases));
                try std.testing.expectEqual(@as(usize, 0), cache.pinned_entries);
                continue;
            }
            try cache.acquireMany(&keys, &leases);
            defer for (leases) |lease| lease.release();
            try std.testing.expectEqual(@as(usize, 192), cache.backend.reads);
            try std.testing.expectEqual(@as(usize, 0), cache.backend.writes);
            for (leases, keys) |lease, key| {
                const hot = std.mem.readInt(u32, key[0..4], .big) < 192;
                try std.testing.expectEqual(@as(u8, if (hot) 2 else 1), lease.read().?[0]);
            }
        }
    }
}

test "reservation pin budgets count distinct hits and misses and unwind blocked requests" {
    const Backend = struct {
        pub const write_batch_size = 192;
        reads: usize = 0,
        pub fn getBatch(self: *@This(), requests: []const records.Get, lengths: []?usize) !void {
            self.reads += requests.len;
            for (requests, lengths) |request, *length| {
                request.destination[0] = request.key[0];
                length.* = 1;
            }
        }
        pub fn putBatch(_: *@This(), _: []const records.Write) !void {
            return error.UnexpectedWrite;
        }
        pub fn fail(_: *@This()) void {}
    };
    const TestCache = records.CacheFor(Backend);
    var memory: [64 * 1024]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&memory);
    var cache = try TestCache.init(allocator.allocator(), std.testing.io, .{}, .{ .slots = 4, .key_bytes = 1, .value_bytes = 1 });
    const assigned = allocator.end_index;
    var warm: [4]TestCache.Lease = undefined;
    try cache.acquireMany(&.{ "a", "b", "c", "d" }, &warm);
    for (warm) |lease| lease.release();
    const a = try cache.acquire("a");
    var output: [3]TestCache.Lease = undefined;
    var victims: [3]TestCache.Lease = undefined;
    try std.testing.expect((try cache.reserveMany(&.{ "b", "b" }, output[0..2], &victims, 2)) == .ready);
    try std.testing.expectEqual(output[0].index, output[1].index);
    try std.testing.expectEqual(@as(usize, 2), cache.pinned_entries);
    for (output[0..2]) |lease| lease.release();
    for ([_][3][]const u8{ .{ "a", "b", "c" }, .{ "b", "x", "x" } }) |keys| {
        const blocked = try cache.reserveMany(&keys, &output, &victims, 2);
        try std.testing.expectEqual(@as(usize, 1), blocked.blocked);
        try std.testing.expectEqual(@as(usize, 1), cache.pinned_entries);
        try std.testing.expect(!cache.lookup.contains("x"));
    }
    try std.testing.expectEqual(@as(usize, 1), (try cache.reserveMany(&.{"a"}, output[0..1], &victims, 0)).blocked);
    try std.testing.expectEqual(@as(usize, 1), cache.pinned_entries);
    const b = try cache.acquire("b");
    try std.testing.expectEqual(@as(usize, 2), (try cache.reserveMany(&.{"x"}, output[0..1], &victims, 1)).blocked);
    try std.testing.expectEqual(@as(usize, 2), cache.pinned_entries);
    a.release();
    b.release();
    try std.testing.expect((try cache.reserveMany(&.{ "x", "x" }, output[0..2], &victims, 1)) == .ready);
    try std.testing.expectEqual(output[0].index, output[1].index);
    try std.testing.expectEqual(@as(usize, 1), cache.pinned_entries);
    for (output[0..2]) |lease| lease.release();
    try std.testing.expectEqual(@as(usize, 0), cache.pinned_entries);
    try std.testing.expectEqual(@as(usize, 4), cache.backend.reads);
    try std.testing.expectEqual(assigned, allocator.end_index);
}

test "dirty flushes preserve key ordering and exclude acknowledged writeback" {
    const Backend = struct {
        pub const write_batch_size = 192;
        batches: usize = 0,
        writes: usize = 0,
        last: [128]u16 = undefined,
        pub fn getBatch(_: *@This(), _: []const records.Get, lengths: []?usize) !void {
            @memset(lengths, null);
        }
        pub fn putBatch(self: *@This(), writes: []const records.Write) !void {
            self.batches += 1;
            self.writes += writes.len;
            for (writes, 0..) |write, index| self.last[index] = std.mem.readInt(u16, write.key[0..2], .big);
        }
        pub fn fail(_: *@This()) void {}
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const TestCache = records.CacheFor(Backend);
    var cache = try TestCache.init(failing.allocator(), std.testing.io, .{}, .{ .slots = 128, .key_bytes = 2, .value_bytes = 8 });
    failing.fail_index = failing.alloc_index;
    var keys: [128][2]u8 = undefined;
    var slices: [128][]const u8 = undefined;
    var leases: [128]TestCache.Lease = undefined;
    for (&keys, &slices, 0..) |*key, *slice, index| {
        std.mem.writeInt(u16, key, @intCast(index), .big);
        slice.* = key;
    }
    try cache.acquireMany(&slices, &leases);
    for (leases) |lease| lease.release();
    for ([_]usize{ 64, 16 }) |index| {
        const lease = try cache.acquire(&keys[index]);
        lease.edit()[0] = 17;
        lease.commit(1);
        lease.release();
    }
    try std.testing.expectEqual(@as(usize, 2), cache.dirty_entries.count);
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 1), cache.backend.batches);
    try std.testing.expectEqualSlices(u16, &.{ 16, 64 }, cache.backend.last[0..2]);
    try std.testing.expectEqual(@as(usize, 0), cache.dirty_entries.count);
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 1), cache.backend.batches);
    const lease = try cache.acquire(&keys[64]);
    lease.edit()[0] = 19;
    lease.commit(1);
    try cache.writeBack(&.{.{ .key = lease.key(), .value = lease.read() }});
    lease.markWritten();
    lease.release();
    try cache.flush();
    try std.testing.expectEqual(@as(usize, 2), cache.backend.batches);
    try std.testing.expectEqual(@as(usize, 3), cache.backend.writes);
    try std.testing.expectEqual(@as(usize, 0), cache.dirty_entries.count);
}
