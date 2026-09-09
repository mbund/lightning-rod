const std = @import("std");
const index = @import("lightning_rod").persistence_index;

pub const CachePage = struct {
    id: index.PageId = 0,
    age: u64 = 0,
    bytes: [index.page_size]u8 = undefined,
};

pub const Metrics = struct {
    hits: u64 = 0,
    staged_hits: u64 = 0,
    reads: u64 = 0,
    writes: u64 = 0,
    written_pages: u64 = 0,
};

pub const File = struct {
    io: std.Io,
    file: std.Io.File,
    maximum_pages: u64,
    written_pages: u64,
    pending_pages: usize = 0,
    pending: []u8,
    cache: []CachePage,
    age: u64 = 0,
    failed: bool = false,
    metrics: Metrics = .{},

    /// Borrows the file and fixed buffers. seal() must complete before publishing a new tree root.
    pub fn init(io: std.Io, file: std.Io.File, maximum_pages: u64, pending: []u8, cache: []CachePage) !File {
        if (maximum_pages == 0 or maximum_pages > std.math.maxInt(u64) / index.page_size or
            pending.len == 0 or pending.len % index.page_size != 0) return error.InvalidCapacity;
        const bytes = (try file.stat(io)).size;
        if (bytes % index.page_size != 0 or bytes / index.page_size > maximum_pages) return error.Corrupt;
        for (cache) |*entry| {
            entry.id = 0;
            entry.age = 0;
        }
        return .{
            .io = io,
            .file = file,
            .maximum_pages = maximum_pages,
            .written_pages = bytes / index.page_size,
            .pending = pending,
            .cache = cache,
        };
    }

    pub fn interface(self: *File) index.Io {
        return .{ .context = self, .read_fn = read, .append_fn = append };
    }

    pub fn cachedPages(self: *const File) usize {
        var count: usize = 0;
        for (self.cache) |entry| {
            if (entry.id != 0) count += 1;
        }
        return count;
    }

    pub fn seal(self: *File) index.AppendError!void {
        if (self.failed) return error.IoFailure;
        try self.flush();
        self.file.sync(self.io) catch {
            self.failed = true;
            return error.IoFailure;
        };
    }

    fn flush(self: *File) index.AppendError!void {
        if (self.failed) return error.IoFailure;
        if (self.pending_pages == 0) return;
        const bytes = self.pending[0 .. self.pending_pages * index.page_size];
        self.file.writePositionalAll(self.io, bytes, self.written_pages * index.page_size) catch |err| {
            self.failed = true;
            return switch (err) {
                error.NoSpaceLeft => error.DiskFull,
                else => error.IoFailure,
            };
        };
        self.written_pages += self.pending_pages;
        self.metrics.writes += 1;
        self.metrics.written_pages += self.pending_pages;
        self.pending_pages = 0;
    }

    fn append(context: *anyopaque, bytes: *const [index.page_size]u8) index.AppendError!index.PageId {
        const self: *File = @ptrCast(@alignCast(context));
        if (self.failed) return error.IoFailure;
        if (self.written_pages + self.pending_pages == self.maximum_pages) return error.DiskFull;
        if (self.pending_pages == self.pending.len / index.page_size) try self.flush();
        const offset = self.pending_pages * index.page_size;
        @memcpy(self.pending[offset..][0..index.page_size], bytes);
        self.pending_pages += 1;
        return self.written_pages + self.pending_pages;
    }

    fn read(context: *anyopaque, id: index.PageId, destination: *[index.page_size]u8) index.ReadError!void {
        const self: *File = @ptrCast(@alignCast(context));
        if (self.failed) return error.IoFailure;
        if (id == 0 or id > self.written_pages + self.pending_pages) {
            self.failed = true;
            return error.IoFailure;
        }
        if (id > self.written_pages) {
            const offset: usize = @intCast((id - self.written_pages - 1) * index.page_size);
            @memcpy(destination, self.pending[offset..][0..index.page_size]);
            self.metrics.staged_hits += 1;
            return;
        }
        if (self.age == std.math.maxInt(u64)) {
            for (self.cache) |*entry| entry.age = 0;
            self.age = 0;
        }
        self.age += 1;
        var oldest: ?*CachePage = null;
        for (self.cache) |*entry| {
            if (entry.id == id) {
                @memcpy(destination, &entry.bytes);
                entry.age = self.age;
                self.metrics.hits += 1;
                return;
            }
            if (oldest == null or entry.age < oldest.?.age) oldest = entry;
        }
        const length = self.file.readPositionalAll(self.io, destination, (id - 1) * index.page_size) catch {
            self.failed = true;
            return error.IoFailure;
        };
        if (length != index.page_size) {
            self.failed = true;
            return error.IoFailure;
        }
        self.metrics.reads += 1;
        if (oldest) |entry| {
            @memcpy(&entry.bytes, destination);
            entry.id = id;
            entry.age = self.age;
        }
    }
};

test "disk index batches pages and reopens immutable roots with one cached page" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(io, "index", .{ .read = true });
    defer file.close(io);
    var pending: [8 * index.page_size]u8 = undefined;
    var cache: [1]CachePage = undefined;
    var storage = try File.init(io, file, 65536, &pending, &cache);
    var workspace: index.Workspace = .{};
    var root: index.Root = .{};
    var saved: index.Root = .{};
    for (0..9000) |number| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(number), .big);
        root = try index.apply(storage.interface(), root, &workspace, "chunk", &key, .{ .put = .{ .pack = 1, .offset = number * 16, .length = 16 } });
        if (number == 99) saved = root;
    }
    try storage.seal();
    try std.testing.expect(storage.metrics.writes < storage.metrics.written_pages);
    var reopened = try File.init(io, file, 65536, &pending, &cache);
    var cursor = index.Cursor.init(reopened.interface(), root, &workspace);
    var item = try cursor.seek("chunk", "");
    var count: u32 = 0;
    while (item) |record| : (item = try cursor.next()) {
        try std.testing.expectEqual(count, std.mem.readInt(u32, record.key[0..4], .big));
        try std.testing.expectEqual(@as(u64, count) * 16, record.location.offset);
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 9000), count);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 99, .big);
    try std.testing.expectEqual(@as(u64, 99 * 16), (try index.lookup(reopened.interface(), saved, &workspace, "chunk", &key)).?.offset);
    std.mem.writeInt(u32, &key, 100, .big);
    try std.testing.expectEqual(null, try index.lookup(reopened.interface(), saved, &workspace, "chunk", &key));
}

test "disk index store exceeds former key capacity with fixed working memory" {
    const persistence = @import("lightning_rod").persistence;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const file = try directory.dir.createFile(io, "index", .{ .read = true });
    defer file.close(io);
    const values = try directory.dir.createFile(io, "values", .{ .read = true });
    defer values.close(io);
    var pending: [8 * index.page_size]u8 = undefined;
    var cache: [1]CachePage = undefined;
    var storage = try File.init(io, file, 65536, &pending, &cache);
    const configuration: persistence.Configuration = .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 64,
        .maximum_requests = 1,
        .maximum_namespace_bytes = 5,
        .maximum_key_bytes = 4,
        .maximum_value_bytes = 4,
        .maximum_checkpoint_bytes = 4096,
    };
    const memory = try std.testing.allocator.alloc(u8, try persistence.Store.maximumDiskIndexBytes(configuration, .live));
    defer std.testing.allocator.free(memory);
    var allocator = std.heap.FixedBufferAllocator.init(memory);
    var store = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .live, storage.interface());
    const allocated = allocator.end_index;
    var root: index.Root = .{};
    var offset: u64 = 0;
    for (0..9000) |number| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(number), .big);
        try std.testing.expectEqual(.ready, store.stage(.{ .namespace = "chunk", .key = &key, .operation = .{ .put = &key } }));
        if (number % 64 != 63 and number != 8999) continue;
        try std.testing.expectEqual(.pending, store.flush());
        const bytes = store.checkpointBytes();
        try values.writePositionalAll(io, bytes, offset);
        try values.sync(io);
        root = try store.prepareDiskIndex(1, offset);
        try storage.seal();
        offset += bytes.len;
        store.markDurableInPack(1, offset - bytes.len);
        try std.testing.expectEqual(@as(usize, 1), store.complete(1));
        try std.testing.expectEqual(.ready, store.checkpointProgress());
        try std.testing.expectEqual(allocated, allocator.end_index);
    }
    try std.testing.expectEqual(@as(u64, 9000), root.count);
    var reopened = try File.init(io, file, 65536, &pending, &cache);
    allocator.reset();
    store = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .live, reopened.interface());
    try store.openDiskIndex(root, 141);
    var after: [4]u8 = undefined;
    var count: u32 = 0;
    while (true) {
        var records: [17]persistence.ScanRecord = undefined;
        const batch = try store.scan("chunk", if (count == 0) "" else &after, &records);
        for (records[0..batch.count]) |record| {
            try std.testing.expectEqual(count, std.mem.readInt(u32, record.key[0..4], .big));
            const location = store.startupLocation("chunk", record.key).?;
            var value: [4]u8 = undefined;
            try std.testing.expectEqual(@as(usize, 4), try values.readPositionalAll(io, &value, location.offset));
            try std.testing.expectEqualSlices(u8, record.key, &value);
            @memcpy(&after, record.key);
            count += 1;
        }
        if (!batch.more) break;
    }
    try std.testing.expectEqual(@as(u32, 9000), count);
    try std.testing.expectEqual(allocated, allocator.end_index);
    var live_cursor: persistence.LiveCursor = .{};
    const first_live = (try store.nextLive(&live_cursor)).?;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, first_live.key[0..4], .big));
    try store.openDiskIndex(.{}, 0);
    count = 1;
    while (try store.nextLive(&live_cursor)) |record| {
        try std.testing.expectEqual(count, std.mem.readInt(u32, record.key[0..4], .big));
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 9000), count);
    var empty_cursor: persistence.LiveCursor = .{};
    try std.testing.expectEqual(null, try store.nextLive(&empty_cursor));
    try store.openDiskIndex(root, 141);
    try std.testing.expectEqual(null, try store.nextLive(&empty_cursor));
    var deleted: [4]u8 = undefined;
    std.mem.writeInt(u32, &deleted, 1, .big);
    try std.testing.expectEqual(.ready, store.stage(.{ .namespace = "chunk", .key = &deleted, .operation = .delete }));
    var inserted: [4]u8 = undefined;
    std.mem.writeInt(u32, &inserted, 9000, .big);
    try std.testing.expectEqual(.ready, store.stage(.{ .namespace = "chunk", .key = &inserted, .operation = .{ .put = "new!" } }));
    var records: [3]persistence.ScanRecord = undefined;
    const first = try store.scan("chunk", "", &records);
    try std.testing.expectEqual(@as(usize, 3), first.count);
    try std.testing.expect(first.more);
    for ([_]u32{ 0, 2, 3 }, records) |expected, record|
        try std.testing.expectEqual(expected, std.mem.readInt(u32, record.key[0..4], .big));
    std.mem.writeInt(u32, &after, 8998, .big);
    const last = try store.scan("chunk", &after, &records);
    try std.testing.expectEqual(@as(usize, 2), last.count);
    try std.testing.expect(!last.more);
    try std.testing.expectEqual(@as(u32, 9000), std.mem.readInt(u32, records[1].key[0..4], .big));
    try std.testing.expectEqual(.pending, store.flush());
    reopened.maximum_pages = reopened.written_pages;
    try std.testing.expectError(error.DiskFull, store.prepareDiskIndex(2, 0));
    try std.testing.expectEqual(.failed, store.checkpointProgress());
    try std.testing.expectEqual(.failed, store.currentValue("chunk", &deleted));
    try std.testing.expectError(error.StorageFailed, store.scan("chunk", "", &records));
    allocator.reset();
    store = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .live, reopened.interface());
    try store.openDiskIndex(root, 141);
    try std.testing.expect(store.startupLocation("chunk", &deleted) != null);
    try std.testing.expectEqual(null, store.startupLocation("chunk", &inserted));
}

test "disk index production packs rotate scratch through repeated compaction and recovery" {
    const persistence = @import("lightning_rod").persistence;
    const Driver = @import("local_packs.zig").Driver(.{
        .maximum_in_flight_reads = 4,
        .maximum_packs = 8,
        .maximum_path_bytes = 512,
    });
    const configuration: persistence.Configuration = .{
        .maximum_keys = 1,
        .maximum_checkpoint_records = 2,
        .maximum_requests = 2,
        .maximum_namespace_bytes = 1,
        .maximum_key_bytes = 1,
        .maximum_value_bytes = 4,
        .maximum_checkpoint_bytes = 128,
    };
    const bytes = try persistence.Store.maximumDiskIndexBytes(configuration, .live) +
        try persistence.Store.maximumDiskIndexBytes(configuration, .recovery) +
        try persistence.Store.maximumDiskIndexBytes(configuration, .compaction);
    const memory = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(memory);
    var allocator = std.heap.FixedBufferAllocator.init(memory);
    var driver: Driver = undefined;
    var store = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .live, driver.diskIndexIo());
    const source = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .recovery, driver.diskIndexIo());
    const output = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .compaction, driver.compactionIndexIo());
    const allocated = allocator.end_index;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path: [512]u8 = undefined;
    const prefix = try directory.dir.realPath(io, &path);
    const suffix = try std.fmt.bufPrint(path[prefix..], "/world.root", .{});
    const root_path = path[0 .. prefix + suffix.len];
    var recovery: [128]u8 = undefined;
    var scratch: [4]u8 = undefined;
    try driver.init(io, root_path, store, &recovery);
    var running = true;
    defer if (running) driver.deinit();
    try driver.configureMaintenance(source, output, &scratch, &recovery);
    for (0..32) |number| {
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, @intCast(number), .little);
        try store.drain(io);
        try std.testing.expectEqual(.ready, store.stageBatch(&.{
            .{ .namespace = "n", .key = "a", .operation = .{ .put = &value } },
            .{ .namespace = "n", .key = "b", .operation = .{ .put = &value } },
        }));
        try std.testing.expectEqual(.pending, store.requestCheckpoint());
        store.drain(io) catch |err| {
            std.debug.print("checkpoint {d}: {t}, write={t}, maintenance={t}, store={t}, packs={d}\n", .{
                number, err, driver.write_phase, driver.maintenance_state, store.commit, driver.root.count,
            });
            return err;
        };
        try std.testing.expectEqual(allocated, allocator.end_index);
        try std.testing.expectEqual(@as(usize, 2), store.live_count);
        var loaded: [4]u8 = undefined;
        try std.testing.expectEqualDeep(persistence.LoadResult{ .value = 4 }, try driver.loader().read("n", "a", &loaded));
        try std.testing.expectEqualSlices(u8, &value, &loaded);
    }
    try std.testing.expect(driver.root.next_id > 32);
    driver.deinit();
    running = false;
    allocator.reset();
    store = try persistence.Store.initDiskIndex(allocator.allocator(), configuration, .live, driver.diskIndexIo());
    try driver.init(io, root_path, store, &recovery);
    running = true;
    var loaded: [4]u8 = undefined;
    for ([_][]const u8{ "a", "b" }) |key| {
        try std.testing.expectEqualDeep(persistence.LoadResult{ .value = 4 }, try driver.loader().read("n", key, &loaded));
        try std.testing.expectEqual(@as(u32, 31), std.mem.readInt(u32, &loaded, .little));
    }
    try std.testing.expectEqual(@as(usize, 2), store.live_count);
}
