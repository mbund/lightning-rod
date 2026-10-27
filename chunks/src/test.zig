const storage = @import("storage");
const std = @import("std");
const chunks = @import("chunks.zig");
const encoding = @import("encoding.zig");
const metrics = @import("metrics");
const records = @import("records");

fn demandCancellationProbe(output: *std.Io.Writer) !void {
    const Source = struct {
        generated: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.generated += 1;
                request.result = chunks.uniform(7, request.output);
            }
        }
    };
    const io = std.testing.io;
    try output.writeAll("prefetched | demanded | slot shortfall | canceled requests | preserved requests | generated sections\n");
    const Case = struct { prefetched: usize, reserve: usize };
    for ([_]Case{ .{ .prefetched = 6, .reserve = 2 }, .{ .prefetched = 14, .reserve = 2 }, .{ .prefetched = 62, .reserve = 2 }, .{ .prefetched = 168, .reserve = 24 } }) |case| {
        const prefetched = case.prefetched;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cancellation", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = prefetched + case.reserve, .demand_sections = case.reserve, .cache_tiles = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
        });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        terrain.attach();
        defer terrain.stop();
        var sections: [192]chunks.Section = undefined;
        var prepared: [192]chunks.Lease = undefined;
        for (sections[0..prefetched], 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index / 24), .y = @as(i32, @intCast(index % 24)) - 4, .z = 0 };
        var ready: [1]bool = undefined;
        try terrain.prepareMany(&.{.{ .sections = sections[0..prefetched], .leases = prepared[0..prefetched], .priority = .{ .player = 1 } }}, &ready);
        try std.testing.expect(!ready[0]);
        try std.testing.expectEqual(prefetched, terrain.generation.queued_count);
        terrain.generation.update(1, .{ .world = 0, .x = 3, .z = 0, .radius = 32 });
        var requested: [32]chunks.Section = undefined;
        const needed = requested[0 .. case.reserve + 1];
        for (needed, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(8 + index / 24), .y = @as(i32, @intCast(index % 24)) - 4, .z = 0 };
        var demanded: [32]chunks.Lease = undefined;
        {
            try terrain.acquireMany(needed, demanded[0..needed.len]);
            defer terrain.releaseMany(demanded[0..needed.len]);
            for (demanded[0..needed.len]) |lease| try std.testing.expectEqual(@as(u16, 7), lease.get(0));
        }
        var preserved: usize = 0;
        for (sections[0..prefetched]) |section| preserved += @intFromBool(terrain.generation.index.contains(section));
        const shortfall = needed.len - (terrain.cache.entries.len - prefetched);
        try std.testing.expectEqual(shortfall, prefetched - preserved);
        try output.print("{d:10} | {d:8} | {d:14} | {d:17} | {d:18} | {d}\n", .{ prefetched, needed.len, shortfall, prefetched - preserved, preserved, source.generated });
        _ = terrain.generation.cancelPrefetch(192);
        try terrain.poll();
    }
}

pub fn benchmarkDemandCancellation() !void {
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &buffer);
    try demandCancellationProbe(&output.interface);
    try output.interface.flush();
}

test "demand reclaims only the missing capacity while retaining useful prefetch" {
    var buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&buffer);
    try demandCancellationProbe(&output.writer);
}

test {
    _ = @import("store_test.zig");
}

test "read windows reuse duplicate and retained views within cache capacity" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(@intCast(request.section.x + 7), request.output);
        }
    };
    for ([_]usize{ 1, 2 }) |capacity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/window", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        const terrain = try chunks.Chunks.init(arena.allocator(), std.testing.io, .{ .cache_sections = capacity, .demand_sections = 0, .cache_tiles = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(arena.allocator(), std.testing.io, .{}),
        });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        var window = chunks.ReadWindow(2).init(terrain);
        defer window.deinit();
        const a: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
        const b: chunks.Section = .{ .world = 0, .x = 1, .y = 0, .z = 0 };
        var views: [2]chunks.View = undefined;
        try window.readMany(&.{ a, a }, &views);
        try std.testing.expectEqual(@as(usize, 1), terrain.borrowed_count);
        for (views) |view| try std.testing.expectEqual(@as(u16, 7), view.get(0));
        try window.readMany(&.{b}, views[0..1]);
        try std.testing.expectEqual(@as(u16, 8), views[0].get(0));
        try std.testing.expectEqual(capacity, terrain.borrowed_count);
        if (capacity == 1) {
            try std.testing.expectError(error.WorkingSetTooLarge, window.readMany(&.{ a, b }, &views));
            try std.testing.expectEqual(@as(usize, 1), terrain.borrowed_count);
        } else {
            try window.readMany(&.{ a, b }, &views);
            try std.testing.expectEqual(@as(u16, 7), views[0].get(0));
            try std.testing.expectEqual(@as(u16, 8), views[1].get(0));
            try std.testing.expectEqual(@as(usize, 2), terrain.borrowed_count);
        }
        try window.readMany(&.{}, views[0..0]);
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    }
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
        var direct: [encoding.decoded_bytes]u8 = undefined;
        try std.testing.expectEqual(length, try encoding.decodeTo(bytes, &direct));
        try std.testing.expectEqualSlices(u8, decoded[0..length], direct[0..length]);
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
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 96 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .metrics = &registry });
        defer store.deinit();
        const tx = store.transaction();
        const space = try tx.openSpace(chunks.Chunks.id);
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 0, .cache_sections = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
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
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 48 });
        defer registry.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
        const tx = store.transaction();
        defer tx.fail();
        const space = try tx.openSpace(chunks.Chunks.id);
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 0, .cache_sections = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
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
    const table_resources = try records.Resources.init(std.testing.allocator, std.testing.io, .{ .readers = 1, .writers = 1 });
    defer table_resources.deinit();
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
    var cache = try records.Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .slots = 40, .key_bytes = 1, .value_bytes = encoding.decoded_bytes, .codec = encoding.codec, .scan_batch = 2 });
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
    var scan = try records.Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .slots = 1, .key_bytes = 1, .value_bytes = encoding.decoded_bytes, .codec = encoding.codec, .scan_batch = 2 });
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
    for (keys) |key| try std.testing.expectEqual(@as(?usize, 3203), try records.Table.init(space, table_resources).get(&key, &value));
}

test "simulation reads and edits progress without the attached background thread" {
    const Worker = struct {
        terrain: *chunks.Chunks,
        ready: std.Io.Event = .unset,
        stop_requested: std.Io.Event = .unset,
        io: std.Io = undefined,
        failure: ?anyerror = null,

        fn main(self: *@This()) void {
            self.execute() catch |err| {
                self.failure = err;
                self.ready.set(std.testing.io);
            };
        }
        fn execute(self: *@This()) !void {
            self.io = std.testing.io;
            self.terrain.attach();
            defer self.terrain.stop();
            self.ready.set(std.testing.io);
            self.stop_requested.waitUncancelable(self.io);
        }
        fn stop(self: *@This(), thread: std.Thread) void {
            self.stop_requested.set(self.io);
            self.terrain.ready().set(self.io);
            thread.join();
        }
    };
    const Source = struct {
        reads: std.atomic.Value(usize) = .init(0),
        destination: std.atomic.Value(usize) = .init(0),
        caller: std.Thread.Id = undefined,
        blocked: i32 = std.math.maxInt(i32),
        entered: std.Io.Event = .unset,
        release_read: std.Io.Event = .unset,
        fn read(self: *@This(), io: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests, 0..) |*request, index| {
                request.result = self.readOne(io, request.section, request.output);
                batch.complete(batch.requests[index..][0..1]);
            }
        }

        fn readOne(self: *@This(), source_io: std.Io, at: chunks.Section, destination: []u8) !usize {
            if (at.x == self.blocked) {
                self.entered.set(source_io);
                self.release_read.waitUncancelable(source_io);
            } else try std.testing.expectEqual(self.caller, std.Thread.getCurrentId());
            _ = self.reads.fetchAdd(1, .release);
            self.destination.store(@intFromPtr(destination.ptr), .release);
            return chunks.uniform(7, destination);
        }
    };
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/demand", .{temporary.sub_path});
    defer allocator.free(path);
    var store = try storage.Store.init(allocator, io, .{ .path = path, .maximum_wal_pages = 256 });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    defer registry.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 0, .cache_sections = 2, .cache_tiles = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
    var source: Source = .{ .caller = std.Thread.getCurrentId() };
    terrain.setSource(chunks.Source.init(&source, Source.read));
    var worker: Worker = .{ .terrain = terrain };
    const thread = try std.Thread.spawn(.{}, Worker.main, .{&worker});
    worker.ready.waitUncancelable(io);
    if (worker.failure) |err| {
        thread.join();
        return err;
    }
    defer worker.stop(thread);
    const section: chunks.Section = .{ .world = 0, .x = 3, .y = 4, .z = -2 };
    const old = try terrain.acquire(section);
    try std.testing.expectEqual(source.destination.load(.acquire), @intFromPtr(old.record.bytes.?.ptr));
    try std.testing.expectEqual(@as(u16, 7), old.get(0));
    const hit = try terrain.acquire(section);
    try std.testing.expectEqual(old.record.bytes.?.ptr, hit.record.bytes.?.ptr);
    hit.release();
    try std.testing.expectEqual(@as(usize, 1), source.reads.load(.acquire));
    const second = try terrain.acquire(.{ .world = 0, .x = 4, .y = 4, .z = -2 });
    try std.testing.expectError(error.CachePinned, terrain.acquire(.{ .world = 0, .x = 5, .y = 4, .z = -2 }));
    second.release();
    const third = try terrain.acquire(.{ .world = 0, .x = 5, .y = 4, .z = -2 });
    try std.testing.expectEqual(@as(u16, 7), old.get(0));
    third.release();
    const Writer = struct {
        terrain: *chunks.Chunks,
        section: chunks.Section,
        entered: std.Io.Event = .unset,
        done: std.atomic.Value(bool) = .init(false),
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.entered.set(std.testing.io);
            self.result = self.terrain.setBlocks(self.section, &.{.{ .index = 0, .state = 19 }});
            self.done.store(true, .release);
        }
    };
    var writer: Writer = .{ .terrain = terrain, .section = section };
    const writer_thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    {
        defer {
            old.release();
            writer_thread.join();
        }
        writer.entered.waitUncancelable(io);
        try std.testing.expect(!writer.done.load(.acquire));
        try std.testing.expectEqual(@as(u16, 7), old.get(0));
    }
    try writer.result;
    const updated = try terrain.acquire(section);
    try std.testing.expectEqual(@as(u16, 19), updated.get(0));
    updated.release();
    try terrain.checkpoint(space);
    try store.waitDurable(try store.commit(42));
    try std.testing.expectEqual(@as(u64, 42), store.lastTick());
    try std.testing.expectEqual(@as(u64, 42), store.durableTick());
    const Reader = struct {
        terrain: *chunks.Chunks,
        section: chunks.Section,
        done: std.Io.Event = .unset,
        result: anyerror!u16 = error.NotRead,
        fn run(self: *@This()) void {
            self.result = self.read();
            self.done.set(std.testing.io);
        }
        fn read(self: *@This()) !u16 {
            const lease = try self.terrain.acquire(self.section);
            defer lease.release();
            return lease.get(0);
        }
    };
    source.blocked = 6;
    var miss: Reader = .{ .terrain = terrain, .section = .{ .world = 0, .x = 6, .y = 4, .z = -2 } };
    const missing_thread = try std.Thread.spawn(.{}, Reader.run, .{&miss});
    defer missing_thread.join();
    defer source.release_read.set(io);
    try source.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    var cached: Reader = .{ .terrain = terrain, .section = section };
    const cached_thread = try std.Thread.spawn(.{}, Reader.run, .{&cached});
    defer cached_thread.join();
    errdefer source.release_read.set(io);
    try cached.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try std.testing.expectEqual(@as(u16, 19), try cached.result);
    source.release_read.set(io);
    try miss.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    try std.testing.expectEqual(@as(u16, 7), try miss.result);
}

test {
    _ = @import("generation.zig");
}

test "repeated sections in an edit batch observe preceding edits without extra buffers" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/batch", .{directory.sub_path});
    defer allocator.free(path);
    var store = try storage.Store.init(allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 0, .cache_sections = 3 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    try world.setSections(&.{
        .{ .section = section, .edits = &.{.{ .index = 0, .state = 17 }} },
        .{ .section = section, .edits = &.{.{ .index = 1, .state = 19 }} },
        .{ .section = section, .edits = &.{.{ .index = 0, .state = 23 }} },
    });
    const lease = try world.acquire(section);
    defer lease.release();
    try std.testing.expectEqual(@as(u16, 23), lease.get(0));
    try std.testing.expectEqual(@as(u16, 19), lease.get(1));
}

test "column preparation returns ready columns while independently queuing missing sections" {
    const Generator = struct {
        sections: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                self.sections += 1;
                request.result = chunks.uniform(19, request.output);
            }
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/preparation", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .demand_sections = 1, .cache_sections = 4 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const existing: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const missing: chunks.Section = .{ .world = 0, .x = 1, .y = 0, .z = 0 };
    try world.setBlocks(existing, &.{.{ .index = 0, .state = 17 }});
    var generator: Generator = .{};
    world.setSource(chunks.Source.init(&generator, Generator.read));
    world.attach();
    defer world.stop();
    var prepared: [3]chunks.Lease = undefined;
    const requests = [_]chunks.Chunks.Preparation{
        .{ .sections = &.{missing}, .leases = prepared[0..1], .priority = .{ .urgency = .occupied, .player = 0 } },
        .{ .sections = &.{existing}, .leases = prepared[1..2], .priority = .{ .urgency = .streaming, .player = 1 } },
    };
    var complete: [2]bool = undefined;
    world.ready().reset();
    try world.prepareMany(&requests, &complete);
    try std.testing.expect(world.ready().isSet());
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &complete);
    try std.testing.expectEqual(@as(usize, 0), generator.sections);
    world.releaseMany(prepared[1..2]);
    try std.testing.expect(try world.generation.processOne(io));
    try world.prepareMany(&requests, &complete);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &complete);
    try std.testing.expectEqual(@as(usize, 1), generator.sections);
    world.ready().reset();
    world.releaseMany(prepared[0..2]);
    try std.testing.expect(!world.ready().isSet());
    {
        const lease = try world.acquire(missing);
        defer lease.release();
        try std.testing.expectEqual(@as(u16, 19), lease.get(0));
    }
    const prefetched = [_]chunks.Section{
        .{ .world = 0, .x = 2, .y = 0, .z = 0 },
        .{ .world = 0, .x = 3, .y = 0, .z = 0 },
        .{ .world = 0, .x = 4, .y = 0, .z = 0 },
    };
    var ready: [1]bool = undefined;
    for (0..2) |_| try world.prepareMany(&.{.{ .sections = &prefetched, .leases = &prepared, .priority = .{} }}, &ready);
    try std.testing.expectEqual(@as(usize, 3), world.generating_count);
    try world.prepareMany(&.{.{ .sections = &.{.{ .world = 0, .x = 5, .y = 0, .z = 0 }}, .leases = prepared[0..1], .priority = .{} }}, &ready);
    try std.testing.expectEqual(@as(usize, 3), world.generating_count);
    {
        const demanded = try world.acquire(.{ .world = 0, .x = 6, .y = 0, .z = 0 });
        defer demanded.release();
        try std.testing.expectEqual(@as(u16, 19), demanded.get(0));
        try std.testing.expectEqual(@as(usize, 3), world.generating_count);
        try std.testing.expectEqual(@as(usize, 2), generator.sections);
    }
    _ = world.generation.cancelPrefetch(192);
    try world.poll();
    try std.testing.expectEqual(@as(usize, 0), world.generating_count);
}

test "checkpoint releases its dirty snapshot across multiple batches and failures" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(7, request.output);
        }
    };
    for ([_]bool{ false, true }) |fail| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/checkpoint", .{directory.sub_path});
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 64 });
        defer registry.deinit();
        const space = try store.openSpace("chunks");
        const terrain = try chunks.Chunks.init(arena.allocator(), std.testing.io, .{ .cache_sections = 193, .demand_sections = 0, .cache_tiles = 8 }, .{
            .storage = space,
            .metrics = &registry,
            .record_workspaces = try records.Workspaces.init(arena.allocator(), std.testing.io, .{}),
        });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        var sections: [193]chunks.Section = undefined;
        var leases: [193]chunks.Lease = undefined;
        for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index / 24), .y = @intCast(index % 24), .z = 0 };
        try terrain.acquireMany(&sections, &leases);
        terrain.releaseMany(&leases);
        if (fail) {
            terrain.cache.backend.store.tiles.failed = true;
            try std.testing.expectError(error.FailedTransaction, terrain.checkpoint(space));
        } else {
            try terrain.checkpoint(space);
            try std.testing.expectEqual(@as(u64, sections.len), terrain.cache.metrics.writes.value());
            try terrain.setBlock(0, .{ .x = 0, .y = 0, .z = 0 }, 3);
            try terrain.checkpoint(space);
            try std.testing.expectEqual(@as(u64, sections.len + 1), terrain.cache.metrics.writes.value());
            try std.testing.expectEqual(@as(u16, 3), try terrain.getBlock(0, .{ .x = 0, .y = 0, .z = 0 }));
        }
        try std.testing.expectEqual(@as(usize, 0), terrain.cache.pinned_entries);
        try std.testing.expectEqual(@as(usize, 0), terrain.writing_count);
        try std.testing.expect(!terrain.checkpointing);
        for (terrain.writing) |writing| try std.testing.expect(!writing);
    }
}

pub fn benchmarkDemandBatches() !void {
    const Source = struct {
        calls: usize = 0,
        sections: usize = 0,
        maximum: usize = 0,

        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            self.calls += 1;
            self.sections += batch.requests.len;
            self.maximum = @max(self.maximum, batch.requests.len);
            for (batch.requests) |*request| {
                std.debug.assert(request.section.x < 100);
                request.result = chunks.uniform(7, request.output);
            }
        }
    };
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &output_buffer);
    try output.interface.writeAll("required sections | source calls | maximum source batch | retained prefetch\n");
    for ([_]usize{ 8, 24, 96 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/generation-batch", .{temporary.sub_path});
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 192, .demand_sections = 0, .cache_tiles = 32 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("chunks"),
            .record_workspaces = try records.Workspaces.init(allocator, std.testing.io, .{}),
        });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        terrain.attach();
        defer terrain.stop();
        const prefetch: chunks.Section = .{ .world = 0, .x = 100, .y = 4, .z = 0 };
        var prepared: [1]chunks.Lease = undefined;
        var complete: [1]bool = undefined;
        try terrain.prepareMany(&.{.{ .sections = &.{prefetch}, .leases = &prepared, .priority = .{ .player = 1 } }}, &complete);
        try std.testing.expect(!complete[0]);
        var sections: [96]chunks.Section = undefined;
        var leases: [96]chunks.Lease = undefined;
        for (sections[0..count], 0..) |*section, index| section.* = .{
            .world = 0,
            .x = @intCast(index / 24),
            .y = @as(i32, @intCast(index % 24)) - 4,
            .z = 0,
        };
        try terrain.acquireMany(sections[0..count], leases[0..count]);
        for (leases[0..count]) |lease| try std.testing.expectEqual(@as(u16, 7), lease.get(0));
        terrain.releaseMany(leases[0..count]);
        try std.testing.expectEqual(count, source.sections);
        try std.testing.expectEqual((count + chunks.Source.batch_max - 1) / chunks.Source.batch_max, source.calls);
        try std.testing.expectEqual(chunks.Source.batch_max, source.maximum);
        try std.testing.expect(terrain.generation.index.contains(prefetch));
        try std.testing.expectEqual(@as(usize, 1), terrain.generation.queued_count);
        try output.interface.print("{d:17} | {d:12} | {d:20} | {d}\n", .{ count, source.calls, source.maximum, terrain.generation.queued_count });
        _ = terrain.generation.cancelPrefetch(1);
        try terrain.poll();
    }
    try output.interface.flush();
}

test "read windows release optional leases under external pressure and preserve required views" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(@intCast(request.section.x + 7), request.output);
        }
    };
    for ([_]usize{ 2, 4 }) |capacity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/retention", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 128 });
        defer registry.deinit();
        const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = capacity, .demand_sections = 0, .cache_tiles = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(allocator, std.testing.io, .{}),
        });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        failing.fail_index = failing.alloc_index;
        const a: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
        const b: chunks.Section = .{ .world = 0, .x = 1, .y = 0, .z = 0 };
        const c: chunks.Section = .{ .world = 0, .x = 2, .y = 0, .z = 0 };
        const d: chunks.Section = .{ .world = 0, .x = 3, .y = 0, .z = 0 };
        const e: chunks.Section = .{ .world = 0, .x = 4, .y = 0, .z = 0 };
        var window = chunks.ReadWindow(4).init(terrain);
        defer window.deinit();
        var views: [2]chunks.View = undefined;
        try window.readMany(&.{ a, b }, &views);
        const before = terrain.cache.metrics.acquired.value();
        try window.readMany(&.{b}, views[0..1]);
        try window.readMany(&.{ a, b }, &views);
        try std.testing.expectEqual(before, terrain.cache.metrics.acquired.value());
        try std.testing.expectEqual(@as(usize, 2), window.count);

        var external: [2]chunks.Lease = undefined;
        try terrain.acquireMany(if (capacity == 2) &.{ a, b } else &.{ c, d }, &external);
        try std.testing.expectEqual(@as(usize, 4), terrain.borrowed_count);
        if (capacity == 2) {
            try std.testing.expectError(error.CachePinned, window.readMany(&.{e}, views[0..1]));
            try std.testing.expectEqual(@as(usize, 0), window.count);
            try std.testing.expectEqual(@as(usize, 2), terrain.borrowed_count);
            terrain.releaseMany(&external);
            try window.readMany(&.{e}, views[0..1]);
            try std.testing.expectEqual(@as(u16, 11), views[0].get(0));
        } else {
            try window.readMany(&.{ a, e }, &views);
            try std.testing.expectEqual(@as(u16, 7), views[0].get(0));
            try std.testing.expectEqual(@as(u16, 11), views[1].get(0));
            try std.testing.expectEqual(@as(usize, 2), window.count);
            try std.testing.expectEqual(@as(usize, 4), terrain.borrowed_count);
            terrain.releaseMany(&external);
        }
        window.deinit();
        try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    }
}

test "two-state sections preserve every packed byte and little endian palette value" {
    var encoded: [519]u8 = undefined;
    encoded[0] = 2;
    std.mem.writeInt(u16, encoded[1..3], 2, .little);
    for ([_][2]u16{ .{ 0, 65535 }, .{ 17, 273 }, .{ 65535, 0 }, .{ 0x1234, 0xabcd } }) |palette| {
        std.mem.writeInt(u16, encoded[3..5], palette[0], .little);
        std.mem.writeInt(u16, encoded[5..7], palette[1], .little);
        for (0..256) |pattern| {
            @memset(encoded[7..], @intCast(pattern));
            var decoded: [encoding.decoded_bytes]u8 = undefined;
            try std.testing.expectEqual(decoded.len, try encoding.decodeTo(&encoded, &decoded));
            try std.testing.expectEqual(@as(u8, 1), decoded[0]);
            for (0..encoding.blocks) |index| {
                const selected = pattern >> @intCast(index % 8) & 1;
                try std.testing.expectEqual(palette[selected], std.mem.readInt(u16, decoded[1 + index * 2 ..][0..2], .little));
            }
            var inplace: [encoding.decoded_bytes]u8 = undefined;
            @memcpy(inplace[0..encoded.len], &encoded);
            try std.testing.expectEqual(inplace.len, try encoding.decode(&inplace, encoded.len));
            try std.testing.expectEqualSlices(u8, &decoded, &inplace);
        }
    }
    var output: [encoding.decoded_bytes]u8 = undefined;
    try std.testing.expectError(error.Corrupt, encoding.decodeTo(encoded[0 .. encoded.len - 1], &output));
    try std.testing.expectError(error.BufferTooSmall, encoding.decodeTo(&encoded, output[0 .. output.len - 1]));
}
