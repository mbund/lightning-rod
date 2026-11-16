const std = @import("std");
const light = @import("light.zig");
const delivery = @import("delivery.zig");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const zstandard = @import("zstandard");
const fault = @import("fault_disk");
const chunks = @import("chunks.zig");
const encoding = @import("encoding.zig");
const patch = @import("patch.zig");
const ChunkStore = @import("store.zig").Store;

test "group staging remains bounded when cache capacity exceeds the batch width" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/batch-capacity", .{temporary.sub_path});
    var database = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 8, &registry, try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 }), .{ .side = 1, .batch_groups = 2 });
    try std.testing.expectEqual(@as(usize, 8), store.bases.capacity);
    try std.testing.expectEqual(try records.PooledValues.slots(8), store.bases.entries.len);
    try std.testing.expectEqual(@as(usize, 2), store.bases.backend.capacity);
    try std.testing.expectEqual(@as(usize, 2), store.merger.slots.len);
    try std.testing.expectEqual(2 * store.bases.backend.stride, store.bases.backend.frame_bytes);
    try std.testing.expectEqual(@max(store.bases.backend.frame_bytes, store.window * (1 + patch.maximum)), store.bases.backend.staging.len);
    for (store.bases.backend.readers) |reader| {
        try std.testing.expectEqual(@max(store.bases.backend.stride, store.window * (1 + patch.maximum)), reader.bytes.len);
        try std.testing.expect(reader.bytes.len >= store.window * (1 + patch.maximum));
    }

    var keys: [5][16]u8 = undefined;
    var writes: [5]records.Write = undefined;
    var reads: [5]records.Get = undefined;
    const destination_bytes = zstandard.bound(10 + encoding.maximum_decoded_bytes);
    var values: [5][]u8 = undefined;
    for (&values) |*value| value.* = try allocator.alloc(u8, destination_bytes);
    var lengths: [5]?usize = undefined;
    for (&keys, &writes, &reads, &values, 0..) |*key, *write, *read, value, index| {
        key.* = chunks.encodeKey(.{ .world = 0, .x = @intCast(index), .z = 0, .y = 0 });
        write.* = .{ .key = key, .value = "abc" };
        read.* = .{ .key = key, .destination = value };
    }
    try store.bases.backend.putBatch(&writes);
    try store.bases.backend.getBatch(&reads, &lengths);
    for (values, lengths) |value, length| {
        try std.testing.expectEqual(@as(?usize, 3), length);
        try std.testing.expectEqualStrings("abc", value[0..length.?]);
    }
}

test "packed write staging retains small batches and drains incompressible frames without allocating" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/packed-staging", .{temporary.sub_path});
    var database = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    const maximum = 10 + encoding.maximum_decoded_bytes;
    const stride = zstandard.bound(maximum);
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 8, &registry, try records.Resources.init(allocator, io, .{}), .{ .side = 1, .batch_groups = 8, .write_bytes = 2 * stride });
    try std.testing.expectEqual(@as(usize, 8), store.bases.backend.capacity);
    try std.testing.expectEqual(2 * stride, store.bases.backend.frame_bytes);
    try std.testing.expectEqual(@as(usize, 2), store.merger.slots.len);
    const input = try allocator.alloc(u8, 8 * maximum);
    const output = try allocator.alloc(u8, 8 * stride);
    var keys: [8][16]u8 = undefined;
    var writes: [8]records.Write = undefined;
    var reads: [8]records.Get = undefined;
    var lengths: [8]?usize = undefined;
    for (&keys, &writes, &reads, 0..) |*key, *write, *read, index| {
        key.* = chunks.encodeKey(.{ .world = 0, .x = @intCast(index), .y = 0, .z = 0 });
        write.* = .{ .key = key, .value = input[index * maximum ..][0..maximum] };
        read.* = .{ .key = key, .destination = output[index * stride ..][0..stride] };
    }
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var random = std.Random.DefaultPrng.init(0x100929);
    for ([_]bool{ false, true }) |dense| {
        const staging = store.bases.backend.beginStaging(.patches);
        try std.testing.expectEqual(store.bases.backend.staging.ptr, staging.bytes.ptr);
        try std.testing.expectEqual(store.window * (patch.maximum + 1), staging.bytes.len);
        @memset(staging.bytes, 0xa5);
        staging.end();
        if (dense) random.random().bytes(input) else @memset(input, 37);
        try store.bases.backend.putBatch(&writes);
        if (!dense) for (writes, store.bases.backend.writes) |expected, staged|
            try std.testing.expectEqualSlices(u8, expected.key, staged.key);
        try store.bases.backend.getBatch(&reads, &lengths);
        for (writes, reads, lengths) |write, read, length|
            try std.testing.expectEqualSlices(u8, write.value.?, read.destination[0..length.?]);
    }
    try std.testing.expectError(error.InvalidArgument, store.bases.backend.putBatch(&.{.{ .key = &keys[0], .value = input[0 .. maximum + 1] }}));
    try std.testing.expectEqual(.idle, store.bases.backend.writer_phase.load(.acquire));
    try std.testing.expectEqual(@max(store.bases.backend.frame_bytes, store.bases.backend.patch_bytes), store.bases.backend.staging.len);
    try std.testing.expect(store.bases.backend.staging.len < store.bases.backend.frame_bytes + store.bases.backend.patch_bytes);
    try std.testing.expect(!failing.has_induced_failure);
}

fn lightSnapshot(store: *ChunkStore, column: light.Column, destination: ?[]u8, revisions: *[9]u64) !?usize {
    const input = [_]light.Request{.{ .column = column, .minimum = 0, .count = 1 }};
    var dependencies: [1]light.Dependencies = .{.{ .revisions = undefined, .clean = true }};
    try store.lightDependencies(&input, &dependencies);
    revisions.* = dependencies[0].revisions;
    const bytes = destination orelse return null;
    var frames: [1]?[]const u8 = undefined;
    var complete: [1]bool = undefined;
    var clean: [1]bool = .{true};
    var batch: light.FrameBatch = .{ .bytes = bytes, .frames = &frames, .complete = &complete, .clean = &clean };
    try store.lightFrames(&input, &batch);
    try std.testing.expect(complete[0]);
    return if (frames[0]) |frame| copied: {
        std.mem.copyForwards(u8, bytes[0..frame.len], frame);
        break :copied frame.len;
    } else null;
}

test "adding sections preserves borrowed group bytes and persists through consolidation" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/borrowed-additions", .{temporary.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const resources = try records.Resources.init(allocator, io, .{ .readers = 1 });
    const first = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 0, .z = 0 });
    const middle = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 1, .z = 0 });
    const last = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 2, .z = 0 });
    const incoming = chunks.encodeKey(.{ .world = 0, .x = 4, .y = 0, .z = 0 });
    var output: [encoding.maximum_decoded_bytes]u8 = undefined;
    var lengths: [1]?usize = undefined;
    {
        var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
        defer disk.deinit();
        var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, resources, .{ .side = 4 });
        const window = try store.createGroupWindow(allocator, 1);
        try store.putBatch(&.{ .{ .key = &first, .value = &.{ 0, 1, 0 } }, .{ .key = &last, .value = &.{ 0, 2, 0 } } });
        window.begin(.{ .world = 0, .x = 0, .z = 0, .minimum = 0, .count = 3 });
        var borrowed = true;
        defer if (borrowed) window.reset();
        try store.getBatch(&.{.{ .key = &first, .destination = &output }}, &lengths);
        try std.testing.expectEqual(@as(usize, 1), window.count);
        const before = try allocator.dupe(u8, window.leases[0].read().?);
        const revision = window.leases[0].revision();
        const parsed = store.layout_builds;
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        try store.flush();
        try std.testing.expectEqualSlices(u8, before, window.leases[0].read().?);
        try std.testing.expectEqual(@as(usize, 1), store.readers);
        for ([_]u8{ 0, 17, 93 }) |state| {
            try store.putBatch(&.{.{ .key = &middle, .value = &.{ 0, state, 0 } }});
            // The retained group keeps the bytes it was read with while edits go to the overlay.
            try std.testing.expectEqualSlices(u8, before, window.leases[0].read().?);
            try std.testing.expectEqual(revision, window.leases[0].revision());
            try store.getBatch(&.{.{ .key = &last, .destination = &output }}, &lengths);
            try std.testing.expectEqual(@as(u16, 2), (try encoding.Packed.init(output[0..lengths[0].?])).get(42));
            try store.getBatch(&.{.{ .key = &middle, .destination = &output }}, &lengths);
            try std.testing.expectEqual(@as(u16, state), (try encoding.Packed.init(output[0..lengths[0].?])).get(42));
        }
        try std.testing.expectEqual(parsed, store.layout_builds);
        window.reset();
        borrowed = false;
        try std.testing.expectEqual(@as(usize, 0), store.readers);
        try store.flush();
        while (try store.prepareMerge()) {}
        try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
        try disk.waitDurable(try disk.commit(1));
        const group = try store.groupKey(&incoming);
        var keys: [64][16]u8 = undefined;
        store.sectionKeys(&group, &keys);
        {
            const empty = try store.bases.acquire(&group);
            defer empty.release();
            try std.testing.expect(empty.read() == null);
            var writes: [63]records.Write = undefined;
            for (keys[0..writes.len], &writes) |*key, *write| write.* = .{ .key = key, .value = &.{ 0, 17, 0 } };
            try store.putBatch(&writes);
            try std.testing.expect(empty.read() == null);
        }
        try store.putBatch(&.{.{ .key = &keys[63], .value = &.{ 0, 19, 0 } }});
        try store.getBatch(&.{.{ .key = &incoming, .destination = &output }}, &lengths);
        try std.testing.expectEqual(@as(u16, 17), (try encoding.Packed.init(output[0..lengths[0].?])).get(42));
        try store.flush();
        while (try store.prepareMerge()) {}
        try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
        try disk.waitDurable(try disk.commit(2));
        try std.testing.expect(!bounded.has_induced_failure);
    }

    var reopened_disk = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer reopened_disk.deinit();
    var reopened = try ChunkStore.init(arena.allocator(), io, try reopened_disk.openSpace("chunks"), 1, &registry, resources, .{ .side = 4 });
    try reopened.getBatch(&.{.{ .key = &middle, .destination = &output }}, &lengths);
    try std.testing.expectEqual(@as(u16, 93), (try encoding.Packed.init(output[0..lengths[0].?])).get(42));
    try reopened.getBatch(&.{.{ .key = &incoming, .destination = &output }}, &lengths);
    try std.testing.expectEqual(@as(u16, 17), (try encoding.Packed.init(output[0..lengths[0].?])).get(42));
}

test "single group staging bounds overlay windows for large section batches" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/overlay-window", .{temporary.sub_path});
    var database = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 8, &registry, try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 }), .{ .side = 4, .batch_groups = 1 });
    var keys: [96][16]u8 = undefined;
    var writes: [96]records.Write = undefined;
    var gets: [96]records.Get = undefined;
    var contents: [96][3]u8 = undefined;
    var results: [96]encoding.Classification = undefined;
    var reads: [96]ChunkStore.ClassificationRead = undefined;
    var lengths: [96]?usize = undefined;
    for (&keys, &writes, &gets, &contents, &results, &reads, 0..) |*key, *write, *get, *bytes, *result, *read, index| {
        key.* = chunks.encodeKey(.{ .world = 0, .x = @intCast(index % 4), .z = @intCast(index / 4 % 4), .y = @intCast(index / 16) });
        bytes.* = .{ 0, @intCast(index % 2), 0 };
        write.* = .{ .key = key, .value = bytes };
        get.* = .{ .key = key, .destination = bytes };
        read.* = .{ .key = key, .result = result };
    }
    try std.testing.expect(store.window < keys.len);
    try store.putBatch(&writes);
    try store.classify(&reads, &.{ 0, 1 }, 1);
    for (results, 0..) |result, index| {
        try std.testing.expect(result == .known);
        try std.testing.expectEqual(@as(u8, @intCast(index % 2)), result.known.common);
    }
    try store.decodeBatch(&gets, &lengths);
    for (contents, lengths, 0..) |bytes, length, index| {
        try std.testing.expectEqual(@as(?usize, 3), length);
        try std.testing.expectEqual([3]u8{ 0, @intCast(index % 2), 0 }, bytes);
    }
    try std.testing.expectEqual(@as(usize, 0), store.readers);
}

fn savedLight(workspace: *light.Workspace, label: []const u8, revisions: [9]u64) ![]const u8 {
    var rules: [32]u8 = @splat(0);
    @memcpy(rules[0..label.len], label);
    workspace.begin(.{ .rules = rules, .minimum = 0, .count = 1, .skylight = false, .coverage = 1, .revisions = revisions, .biomes = @splat(0), .uniform = 1 });
    for (0..6) |_| {
        @memset(workspace.section(), 0);
        try workspace.commitSection();
    }
    return workspace.finish();
}

test "packed light frames bound memory and distinguish missing from deferred entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/light-batches", .{temporary.sub_path});
    var database = try storage.Store.init(allocator, io, .{ .path = path });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(allocator, io, .{}), .{ .side = 2 });
    var workspace = try light.Workspace.init(allocator);
    const columns = [_]light.Column{ .{ .world = 0, .x = 0, .z = 0 }, .{ .world = 0, .x = 1, .z = 0 }, .{ .world = 0, .x = 2, .z = 0 } };
    const encoded = try savedLight(&workspace, "batch", @splat(0));
    try std.testing.expect(try store.putLight(columns[0], @splat(0), encoded));
    try std.testing.expect(try store.putLight(columns[2], @splat(0), encoded));
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const input = [_]light.Request{
        .{ .column = columns[0], .minimum = 0, .count = 1 },
        .{ .column = columns[1], .minimum = 0, .count = 1 },
        .{ .column = columns[2], .minimum = 0, .count = 1 },
    };
    var bytes: [1024]u8 = undefined;
    var frames: [3]?[]const u8 = undefined;
    var complete: [3]bool = undefined;
    var clean: [3]bool = @splat(true);
    var batch: light.FrameBatch = .{ .bytes = bytes[0 .. (encoded.len + delivery.Column.header_size) * 2 - 1], .frames = &frames, .complete = &complete, .clean = &clean };
    try store.lightFrames(&input, &batch);
    try std.testing.expectEqual(encoded.len + delivery.Column.header_size, batch.used);
    try std.testing.expectEqual([3]bool{ true, true, false }, complete);
    try std.testing.expectEqualSlices(u8, encoded, frames[0].?);
    try std.testing.expect(frames[1] == null and frames[2] == null);
    try std.testing.expectEqual(@intFromPtr(bytes[0..].ptr) + delivery.Column.header_size, @intFromPtr(frames[0].?.ptr));
    batch = .{ .bytes = &bytes, .frames = frames[2..3], .complete = complete[2..3], .clean = clean[2..3] };
    try store.lightFrames(input[2..3], &batch);
    try std.testing.expect(complete[2]);
    try std.testing.expectEqualSlices(u8, encoded, frames[2].?);
    batch.bytes = bytes[0 .. encoded.len - 1];
    try std.testing.expectError(error.BufferTooSmall, store.lightFrames(input[2..3], &batch));
    batch.bytes = &bytes;
    try store.lightFrames(input[2..3], &batch);
    try std.testing.expectEqualSlices(u8, encoded, frames[2].?);
    try std.testing.expect(!bounded.has_induced_failure);
}

fn expectLightPrefix(store: *ChunkStore, column: light.Column, expected: ?[]const u8) !void {
    var bytes: [light.prefix_bytes + 32 + light.maximum_metadata]u8 = undefined;
    var result: [1]light.PrefixSnapshot = .{.{ .length = null, .clean = true }};
    try store.lightPrefixes(&.{.{ .column = column, .minimum = 0, .count = 1, .destination = &bytes }}, &result);
    if (expected) |frame| {
        const length = try light.Prefix.encodedLength(frame);
        try std.testing.expectEqual(@as(?usize, length), result[0].length);
        try std.testing.expectEqualSlices(u8, frame[0..length], bytes[0..length]);
    } else try std.testing.expect(result[0].length == null);
}

fn expectLightFrame(store: *ChunkStore, column: light.Column, expected: ?[]const u8) !void {
    var bytes: [1024]u8 = undefined;
    var frames: [1]?[]const u8 = undefined;
    var complete: [1]bool = undefined;
    var clean: [1]bool = .{true};
    var batch: light.FrameBatch = .{ .bytes = &bytes, .frames = &frames, .complete = &complete, .clean = &clean };
    try store.lightFrames(&.{.{ .column = column, .minimum = 0, .count = 1 }}, &batch);
    try std.testing.expect(complete[0]);
    if (expected) |frame| try std.testing.expectEqualSlices(u8, frame, frames[0].?) else try std.testing.expect(frames[0] == null);
}

test "a damaged cache is emptied in place and serves again until damage keeps recurring" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/damaged", .{temporary.sub_path});
    const properties = [_]u8{ 0, 1, 2, 1 };
    const key = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 0, .z = 0 });
    const value = [_]u8{ 0, 1, 0 };
    // Far from the written chunk, so its dependency revisions stay zero.
    const column: light.Column = .{ .world = 0, .x = 100, .z = 0 };
    for (0..3) |phase| {
        if (phase != 0) {
            // Every page past the cache root is torn, as an interrupted write in an earlier
            // process leaves them. Opening the file validates only the roots.
            const file = try temporary.dir.openFile(io, "damaged.cache", .{ .mode = .read_write });
            defer file.close(io);
            const pages = (try file.stat(io)).size / 4096;
            try std.testing.expect(pages > 2);
            for (2..pages) |id| {
                var byte: [1]u8 = undefined;
                try std.testing.expectEqual(@as(usize, 1), try file.readPositionalAll(io, &byte, id * 4096 + 100));
                byte[0] = ~byte[0];
                try file.writePositionalAll(io, &byte, id * 4096 + 100);
            }
        }
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
        defer database.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{});
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
        const cache = store.derived;
        var workspace = try light.Workspace.init(allocator);
        const encoded = try savedLight(&workspace, "damage", @splat(0));
        var result: encoding.Classification = undefined;
        const reads = [_]ChunkStore.ClassificationRead{.{ .key = &key, .result = &result }};
        if (phase == 0) {
            try store.putBatch(&.{.{ .key = &key, .value = &value }});
            try store.flush();
            try database.waitDurable(try database.commit(1));
        }
        if (phase == 2) {
            // Damage first met by a read while serving.
            try expectLightFrame(&store, column, null);
            try std.testing.expectEqual(.damaged, cache.state.load(.acquire));
        }
        // Damage met while opening an index must not stop the store from starting.
        const index = try store.registerClassification(allocator, &properties, 1, null);
        try std.testing.expectEqual(@as(storage.DiskCache.State, if (phase == 1) .damaged else .ready), cache.state.load(.acquire));
        try std.testing.expectEqual(@as(u32, @intFromBool(phase == 2)), cache.generation.load(.acquire));
        // The server seals allocation before it serves, so recovery must reuse what it holds.
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        if (phase != 0) try expectLightFrame(&store, column, null);
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
        try std.testing.expectEqual(.ready, cache.state.load(.acquire));
        try std.testing.expectEqual(@as(u32, @intFromBool(phase != 0)), cache.generation.load(.acquire));
        try std.testing.expect(try store.putLight(column, @splat(0), encoded));
        try expectLightFrame(&store, column, encoded);
        // The cache answers from its own records again.
        const loaded = store.bases.metrics.reads.value();
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
        try std.testing.expectEqual(loaded, store.bases.metrics.reads.value());
        if (phase != 2) continue;

        for (1..storage.DiskCache.resets_max) |round| {
            cache.store.failed = true;
            // A write that failed also latches the file. The reset gives a new file and
            // must not keep that latch, or every write after it fails too.
            if (round == 1) cache.store.filesystem.failed = true;
            try expectLightFrame(&store, column, null);
            try std.testing.expectEqual(.damaged, cache.state.load(.acquire));
            try std.testing.expect(try store.putLight(column, @splat(0), encoded));
            try std.testing.expectEqual(@as(u32, @intCast(round + 1)), cache.generation.load(.acquire));
            try expectLightFrame(&store, column, encoded);
            try store.classify(&reads, index.properties, 1);
            try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
        }
        try std.testing.expectEqual(@as(u64, storage.DiskCache.resets_max), store.derived_resets.value());
        try std.testing.expectEqual(@as(u64, 0), store.derived_disables.value());

        cache.store.failed = true;
        try expectLightFrame(&store, column, null);
        try std.testing.expect(!try store.putLight(column, @splat(0), encoded));
        try std.testing.expectEqual(.discarded, cache.state.load(.acquire));
        try std.testing.expectEqual(@as(u64, 1), store.derived_disables.value());
        try std.testing.expectError(error.FileNotFound, temporary.dir.access(io, "damaged.cache", .{}));
        try expectLightFrame(&store, column, null);
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
        try std.testing.expect(!try store.putLight(column, @splat(0), encoded));
        try std.testing.expectEqual(@as(u64, 1), store.derived_disables.value());
        try std.testing.expect(!bounded.has_induced_failure);
    }
}

test "stores sharing a cache file follow a reset made by one of them" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/shared", .{temporary.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registries = [_]metrics.Registry{ try .init(allocator, io, .{}), try .init(allocator, io, .{}) };
    var first = try ChunkStore.init(allocator, io, try database.openSpace("first"), 1, &registries[0], try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    var second = try ChunkStore.init(allocator, io, try database.openSpace("second"), 1, &registries[1], try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    try std.testing.expectEqual(first.derived, second.derived);
    const cache = first.derived;
    var workspace = try light.Workspace.init(allocator);
    const encoded = try savedLight(&workspace, "shared", @splat(0));
    const column: light.Column = .{ .world = 0, .x = 3, .z = 0 };
    try std.testing.expect(try first.putLight(column, @splat(0), encoded));
    try std.testing.expect(try second.putLight(column, @splat(0), encoded));
    try expectLightFrame(&second, column, encoded);

    cache.store.failed = true;
    try expectLightFrame(&first, column, null);
    // Damage belongs to the file, so the other store stops reading it too.
    try expectLightFrame(&second, column, null);
    try std.testing.expect(try first.putLight(column, @splat(0), encoded));
    try std.testing.expectEqual(@as(u32, 1), cache.generation.load(.acquire));
    try expectLightFrame(&first, column, encoded);
    // The second store's roots went with the old pages. Its next write roots it again
    // without emptying what the first store has written since.
    try expectLightFrame(&second, column, null);
    try std.testing.expect(try second.putLight(column, @splat(0), encoded));
    try expectLightFrame(&second, column, encoded);
    try expectLightFrame(&first, column, encoded);
    try std.testing.expectEqual(@as(u32, 1), cache.generation.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), first.derived_resets.value());
    try std.testing.expectEqual(@as(u64, 0), second.derived_resets.value());
}

test "lighting dependencies recover with terrain and distinguish neighboring from distant writes" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/light-recovery", .{temporary.sub_path});
    const column: light.Column = .{ .world = 0, .x = 0, .z = 0 };
    var expected: [9]u64 = undefined;
    for (0..4) |phase| {
        var database = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer database.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
        defer registry.deinit();
        var store = try ChunkStore.init(arena.allocator(), io, try database.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(arena.allocator(), io, .{ .readers = 1, .writers = 1 }), .{ .side = 2 });
        var revisions: [9]u64 = undefined;
        var frame: [1024]u8 = undefined;
        var light_workspace = try light.Workspace.init(arena.allocator());
        const center = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 0, .z = 0 });
        const neighbor = chunks.encodeKey(.{ .world = 0, .x = 1, .y = 0, .z = 0 });
        const distant = chunks.encodeKey(.{ .world = 0, .x = 8, .y = 0, .z = 8 });
        if (phase == 0) {
            try store.putBatch(&.{.{ .key = &center, .value = &.{ 0, 1, 0 } }});
            try store.flush();
            _ = try lightSnapshot(&store, column, null, &expected);
            try std.testing.expect(expected[4] != 0 and expected[5] == 0);
            try std.testing.expect(try store.putLight(column, expected, try savedLight(&light_workspace, "saved-light", expected)));
            const missing: light.Column = .{ .world = 0, .x = 4, .z = 7 };
            var frames: [2]?[]const u8 = undefined;
            var complete: [2]bool = undefined;
            var clean: [2]bool = @splat(true);
            var batch: light.FrameBatch = .{ .bytes = &frame, .frames = &frames, .complete = &complete, .clean = &clean };
            try store.lightFrames(&.{
                .{ .column = column, .minimum = 0, .count = 1 },
                .{ .column = missing, .minimum = 0, .count = 1 },
            }, &batch);
            try std.testing.expectEqualSlices(u8, try savedLight(&light_workspace, "saved-light", expected), frames[0].?);
            try std.testing.expect(complete[0] and complete[1] and frames[1] == null);
            var dependency: [1]light.Dependencies = .{.{ .revisions = undefined, .clean = true }};
            try store.lightDependencies(&.{.{ .column = column, .minimum = 0, .count = 1 }}, &dependency);
            try std.testing.expectEqualSlices(u64, &expected, &dependency[0].revisions);
            try expectLightPrefix(&store, column, try savedLight(&light_workspace, "saved-light", expected));
            try expectLightPrefix(&store, missing, null);
            try database.waitDurable(try database.commit(1));
        } else {
            const length = try lightSnapshot(&store, column, &frame, &revisions);
            try expectLightPrefix(&store, column, if (phase < 3) try savedLight(&light_workspace, "saved-light", expected) else null);
            if (phase < 3) try std.testing.expectEqualSlices(u8, try savedLight(&light_workspace, "saved-light", expected), frame[0..length.?]) else try std.testing.expect(length == null);
            if (phase < 3) {
                try std.testing.expectEqualSlices(u64, &expected, &revisions);
                try store.putBatch(&.{.{ .key = &neighbor, .value = &.{ 0, 2, 0 } }});
                try store.flush();
                const previous_revisions = revisions;
                try std.testing.expect(try lightSnapshot(&store, column, &frame, &revisions) == null);
                try expectLightPrefix(&store, column, null);
                try std.testing.expect(!try store.putLight(column, expected, try savedLight(&light_workspace, "stale-light", expected)));
                try std.testing.expect(!std.mem.eql(u64, &revisions, &previous_revisions));
                if (phase == 2) try database.waitDurable(try database.commit(2));
            } else {
                try std.testing.expectEqual(expected[4], revisions[4]);
                try std.testing.expect(revisions[5] != expected[5]);
                expected = revisions;
                try std.testing.expect(try store.putLight(column, expected, try savedLight(&light_workspace, "updated-light", expected)));
                try store.putBatch(&.{.{ .key = &distant, .value = &.{ 0, 3, 0 } }});
                try store.flush();
                const updated_length = (try lightSnapshot(&store, column, &frame, &revisions)).?;
                try std.testing.expectEqualSlices(u8, try savedLight(&light_workspace, "updated-light", expected), frame[0..updated_length]);
                try std.testing.expectEqualSlices(u64, &expected, &revisions);
                try expectLightPrefix(&store, column, try savedLight(&light_workspace, "updated-light", expected));
                try database.waitDurable(try database.commit(3));
            }
        }
    }
}

const count = 12;

fn keyFor(id: usize) [16]u8 {
    var key: [16]u8 = undefined;
    std.mem.writeInt(u32, key[0..4], @intCast(id / 4), .big);
    std.mem.writeInt(i32, key[4..8], -2 + @as(i32, @intCast(id % 4 / 2)), .big);
    std.mem.writeInt(i32, key[8..12], -2 + @as(i32, @intCast(id % 2)), .big);
    std.mem.writeInt(i32, key[12..16], @as(i32, @intCast(id / 8)) - 4, .big);
    return key;
}

fn valueFor(tick: u64, id: usize, output: []u8) ?[]const u8 {
    if ((tick == 2 and id % 3 == 0) or tick == 4) return null;
    const states: usize = if (tick == 1) 1279 else if (tick == 2) 5 else 1;
    var dense: [8193]u8 = undefined;
    dense[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, dense[1 + index * 2 ..][0..2], @intCast(index % states + id * 1280), .little);
    const encoded = encoding.encode(&dense, output) catch unreachable;
    if (encoded.ptr != output.ptr) @memcpy(output[0..encoded.len], encoded);
    return output[0..encoded.len];
}

fn change(store: *storage.Store, tick: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .capacity = 32 });
    defer registry.deinit();
    var chunks_store = try ChunkStore.init(arena.allocator(), store.io, try store.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(arena.allocator(), store.io, .{ .readers = 1, .writers = 1 }), .{ .side = 2 });
    const properties = try arena.allocator().alloc(u8, count * 1280);
    for (properties, 0..) |*property, index| property.* = @intCast(index % 2);
    _ = try chunks_store.registerClassification(arena.allocator(), properties, 1, null);
    var keys: [count][16]u8 = undefined;
    var values: [count][8193]u8 = undefined;
    var writes: [count]records.Write = undefined;
    for (&keys, &values, &writes, 0..) |*key, *value, *write, id| {
        key.* = keyFor(id);
        write.* = .{ .key = key, .value = valueFor(tick, id, value) };
    }
    try chunks_store.putBatch(&writes);
    try chunks_store.flush();
    _ = try store.commit(tick);
}

fn verify(store: *storage.Store, tick: u64) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .capacity = 32 });
    defer registry.deinit();
    var chunks_store = try ChunkStore.init(arena.allocator(), store.io, try store.openSpace(chunks.Chunks.id), 1, &registry, try records.Resources.init(arena.allocator(), store.io, .{ .readers = 1, .writers = 1 }), .{ .side = 2 });
    const properties = try arena.allocator().alloc(u8, count * 1280);
    for (properties, 0..) |*property, index| property.* = @intCast(index % 2);
    _ = try chunks_store.registerClassification(arena.allocator(), properties, 1, null);
    var keys: [count][16]u8 = undefined;
    var values: [count][8193]u8 = undefined;
    var requests: [count]records.Get = undefined;
    var lengths: [count]?usize = undefined;
    for (&keys, &values, &requests, 0..) |*key, *value, *request, id| {
        key.* = keyFor(count - 1 - id);
        request.* = .{ .key = key, .destination = value };
    }
    try chunks_store.getBatch(&requests, &lengths);
    var classifications: [count]encoding.Classification = undefined;
    var classification_reads: [count]ChunkStore.ClassificationRead = undefined;
    for (&classification_reads, &keys, &classifications) |*read, *key, *result| read.* = .{ .key = key, .result = result };
    try chunks_store.classify(&classification_reads, properties, 1);
    const decoded_before = chunks_store.bases.metrics.reads.value();
    try chunks_store.classify(&classification_reads, properties, 1);
    try std.testing.expectEqual(decoded_before, chunks_store.bases.metrics.reads.value());
    var buffer: [8193]u8 = undefined;
    for (values, lengths, 0..) |value, length, id| {
        const expected = valueFor(tick, count - 1 - id, &buffer);
        try std.testing.expectEqual(@as(?usize, if (expected) |bytes| bytes.len else null), length);
        if (expected) |bytes| {
            try std.testing.expectEqualSlices(u8, bytes, value[0..length.?]);
            try std.testing.expectEqualDeep(try encoding.classify(bytes, properties, 1), classifications[id].known);
        } else try std.testing.expect(classifications[id] == .unavailable);
    }
    const before = store.wal_bytes.value();
    try chunks_store.flush();
    try std.testing.expectEqual(before, store.wal_bytes.value());
}

test "spatial records preserve neighbors through growth shrink deletion and eviction" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/tiles", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path };
    for (1..6) |tick| {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        errdefer store.deinit();
        try change(&store, tick);
        try store.waitDurable(store.lastCommit());
        store.deinit();
        store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try verify(&store, tick);
    }
}

fn scenario(store: *storage.Store, acknowledged: *u64) !void {
    try change(store, 2);
    try store.waitDurable(store.lastCommit());
    acknowledged.* = 2;
    {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, store.io, .{ .capacity = 32 });
        defer registry.deinit();
        var chunks_store = try ChunkStore.init(arena.allocator(), store.io, try store.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(arena.allocator(), store.io, .{ .readers = 1, .writers = 1 }), .{ .side = 2 });
        while (try chunks_store.prepareMerge()) {}
        _ = try chunks_store.publishPrepared();
    }
    try change(store, 3);
}

test "power loss while repacking spatial records recovers an atomic save" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/crash", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try change(&store, 1);
        try store.waitDurable(store.lastCommit());
    }
    for ([_]bool{ false, true }) |short| {
        var events: usize = 0;
        {
            var store = try storage.Store.init(std.testing.allocator, io, options);
            _ = try store.openCache(".cache", .{});
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), short);
            defer disk.deinit();
            const modeled = disk.interface();
            store.io = modeled;
            store.filesystem.io = modeled;
            store.maintenance_io.io = modeled;
            var acknowledged: u64 = 1;
            try scenario(&store, &acknowledged);
            events = disk.events;
            store.deinit();
            disk.detach();
        }
        try std.testing.expect(events != 0);
        for (1..events + 1) |cut| for (std.enums.values(fault.Disk.Mode)) |mode| {
            errdefer std.debug.print("chunk power loss short={} cut={d}/{d} mode={t}\n", .{ short, cut, events, mode });
            var store = try storage.Store.init(std.testing.allocator, io, options);
            _ = try store.openCache(".cache", .{});
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, cut, short);
            defer disk.deinit();
            const modeled = disk.interface();
            store.io = modeled;
            store.filesystem.io = modeled;
            store.maintenance_io.io = modeled;
            var acknowledged: u64 = 1;
            scenario(&store, &acknowledged) catch |err| switch (err) {
                error.IoFailure, error.FailedTransaction, error.NoSpace => {},
                else => return err,
            };
            store.deinit();
            disk.detach();
            disk.crash(mode);
            disk.cut = std.math.maxInt(usize);
            disk.failed = false;
            var recovered = try storage.Store.init(std.testing.allocator, disk.interface(), options);
            defer {
                recovered.deinit();
                disk.detach();
            }
            try std.testing.expect(recovered.lastTick() >= acknowledged and recovered.lastTick() <= 3);
            try verify(&recovered, recovered.lastTick());
        };
    }
}

test "unrelated base group reads progress during cold reads and mutations" {
    const Actor = struct {
        store: *ChunkStore,
        key: [16]u8,
        bytes: [8193]u8 = undefined,
        gate: ?*fault.Disk.IoGate = null,
        writing: bool = false,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            if (self.gate) |gate| gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.read();
            self.done.set(std.testing.io);
        }
        fn read(self: *@This()) !void {
            if (self.writing) {
                try self.store.putBatch(&.{.{ .key = &self.key, .value = &.{ 0, 11, 0 } }});
                return;
            }
            var lengths: [1]?usize = undefined;
            try self.store.decodeBatch(&.{.{ .key = &self.key, .destination = &self.bytes }}, &lengths);
            try std.testing.expectEqual(@as(?usize, 3), lengths[0]);
            try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, self.bytes[1..3], .little));
        }
    };
    const io = std.testing.io;
    for ([_]bool{ false, true }) |mutation| {
        errdefer std.debug.print("unrelated base group mutation={}\n", .{mutation});
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/concurrent-tiles", .{temporary.sub_path});
        const pages = try storage.Resources.init(allocator, io, .{ .cache_pages = 1, .readers = 2, .io_mode = .standard });
        defer pages.deinit();
        var store = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .resources = pages, .maximum_wal_pages = 128 });
        defer store.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
        defer registry.deinit();
        const resources = try records.Resources.init(allocator, io, .{ .readers = 2, .writers = 1 });
        defer resources.deinit();
        const space = try store.openSpace("chunks");
        var initial = try ChunkStore.init(allocator, io, space, 2, &registry, resources, .{ .side = 2 });
        var keys = [_][16]u8{ keyFor(0), keyFor(8) };
        const value = [_]u8{ 0, 7, 0 };
        try initial.putBatch(&.{ .{ .key = &keys[0], .value = &value }, .{ .key = &keys[1], .value = &value } });
        try initial.flush();
        var reader = try ChunkStore.init(allocator, io, space, 2, &registry, resources, .{ .side = 2 });
        var warm: Actor = .{ .store = &reader, .key = keys[1] };
        if (mutation) try warm.read();
        const root = (try space.getRoot()).?;
        var directory: storage.Page = undefined;
        try space.readPages(&.{.{ .id = root, .destination = &directory }});
        const root_offset = reader.bases.backend.table.root_offset;
        const base_root = std.mem.readInt(u64, directory[root_offset..][0..8], .little);
        try std.testing.expect(base_root != 0);
        const offset = store.locations.get(base_root).?.current;
        var disk = try fault.Disk.init(allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
        defer disk.deinit();
        const modeled = disk.interface();
        defer disk.detach();
        store.bindIo(modeled);
        store.resources.cache_index.clearRetainingCapacity();
        var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset + 32 };
        disk.read_gate = &gate;
        var paused: Actor = .{ .store = &reader, .key = keys[0], .gate = &gate, .writing = mutation };
        const first = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Actor.run, .{&paused});
        defer first.join();
        defer gate.release.set(io);
        try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        var independent: Actor = .{ .store = &reader, .key = keys[1] };
        const second = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Actor.run, .{&independent});
        defer second.join();
        defer gate.release.set(io);
        try independent.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try independent.result;
        try std.testing.expect(!paused.done.isSet());
        gate.release.set(io);
        try paused.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try paused.result;
    }
}

test "interleaved duplicate base group writes preserve the final caller value across cache windows" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    for ([_]usize{ 1, 2 }) |capacity| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/ordered-{d}", .{ temporary.sub_path, capacity });
        var disk = try storage.Store.init(allocator, std.testing.io, .{ .path = path, .io_mode = .standard });
        defer disk.deinit();
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .enabled = false });
        defer registry.deinit();
        var store = try ChunkStore.init(allocator, std.testing.io, try disk.openSpace("chunks"), capacity, &registry, try records.Resources.init(allocator, std.testing.io, .{ .readers = 1, .writers = 1 }), .{ .side = 2 });
        const a = keyFor(0);
        const b = keyFor(4);
        try store.putBatch(&.{
            .{ .key = &a, .value = &.{ 0, 1, 0 } },
            .{ .key = &b, .value = &.{ 0, 2, 0 } },
            .{ .key = &a, .value = &.{ 0, 3, 0 } },
            .{ .key = &b, .value = null },
            .{ .key = &a, .value = &.{ 0, 4, 0 } },
            .{ .key = &b, .value = &.{ 0, 5, 0 } },
        });
        var values: [3][3]u8 = undefined;
        var lengths: [3]?usize = undefined;
        try store.getBatch(&.{
            .{ .key = &b, .destination = &values[0] },
            .{ .key = &a, .destination = &values[1] },
            .{ .key = &a, .destination = &values[2] },
        }, &lengths);
        for (lengths) |length| try std.testing.expectEqual(@as(?usize, 3), length);
        try std.testing.expectEqualSlices(u8, &.{ 0, 5, 0 }, &values[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 4, 0 }, &values[1]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 4, 0 }, &values[2]);
    }
}

test "prepared consolidation skips pinned bases and rejects edits after its snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/prepared", .{temporary.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 1024 });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 2 });
    const key = keyFor(0);
    var initial: [8193]u8 = undefined;
    initial[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, initial[1 + index * 2 ..][0..2], @intCast(index % 17), .little);
    try store.putBatch(&.{.{ .key = &key, .value = &initial }});
    try store.flush();
    try disk.waitDurable(try disk.commit(1));
    const next: [3]u8 = .{ 0, 17, 0 };
    try store.putBatch(&.{.{ .key = &key, .value = &next }});
    try store.flush();
    try disk.waitDurable(try disk.commit(2));
    while (try store.prepareMerge()) {}
    const group = try store.groupKey(&key);
    const held = try store.bases.acquire(&group);
    try std.testing.expectEqual(@as(usize, 0), try store.publishPrepared());
    held.release();
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    try disk.waitDurable(try disk.commit(3));
    const changed: [3]u8 = .{ 0, 33, 0 };
    try store.putBatch(&.{.{ .key = &key, .value = &changed }});
    try store.flush();
    while (try store.prepareMerge()) {}
    const newer: [3]u8 = .{ 0, 49, 0 };
    try store.putBatch(&.{.{ .key = &key, .value = &newer }});
    try std.testing.expectEqual(@as(usize, 0), try store.publishPrepared());
    try store.flush();
    try disk.waitDurable(try disk.commit(4));
    var output: [8193]u8 = undefined;
    var lengths: [1]?usize = undefined;
    try store.decodeBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    const view: chunks.View = if (output[0] == 0) .{ .uniform = std.mem.readInt(u16, output[1..3], .little) } else .{ .dense = output[1..8193] };
    for (0..4096) |index| try std.testing.expectEqual(@as(u16, 49), view.get(@intCast(index)));
}

test "biomes survive block overlays eviction consolidation and reopening" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/biomes", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 1024 };
    const key = keyFor(0);
    var section: [encoding.maximum_decoded_bytes]u8 = undefined;
    section[0] = 3;
    for (0..64) |index| std.mem.writeInt(u16, section[1 + index * 2 ..][0..2], @intCast(index), .little);
    section[encoding.biome_header_bytes] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, section[encoding.biome_header_bytes + 1 + index * 2 ..][0..2], @intCast(index % 7), .little);
    {
        var disk = try storage.Store.init(allocator, io, options);
        defer disk.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
        defer registry.deinit();
        var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
        try store.putBatch(&.{.{ .key = &key, .value = &section }});
        try store.flush();
        try disk.waitDurable(try disk.commit(1));
        std.mem.writeInt(u16, section[1..3], 41, .little);
        for (0..4096) |index| std.mem.writeInt(u16, section[encoding.biome_header_bytes + 1 + index * 2 ..][0..2], 65535, .little);
        try store.putBatch(&.{.{ .key = &key, .value = &section }});
        try store.flush();
        while (try store.prepareMerge()) {}
        try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
        try disk.waitDurable(try disk.commit(2));
    }
    var disk = try storage.Store.init(allocator, io, options);
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
    var output: [encoding.maximum_decoded_bytes]u8 = undefined;
    var lengths: [1]?usize = undefined;
    try store.decodeBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    var expanded: [encoding.maximum_decoded_bytes]u8 = undefined;
    const length = lengths[0].?;
    if (length == section.len) {
        try std.testing.expectEqualSlices(u8, &section, output[0..length]);
    } else {
        @memcpy(expanded[0..encoding.biome_header_bytes], output[0..encoding.biome_header_bytes]);
        expanded[encoding.biome_header_bytes] = 1;
        for (0..4096) |index| std.mem.writeInt(u16, expanded[encoding.biome_header_bytes + 1 + index * 2 ..][0..2], std.mem.readInt(u16, output[encoding.biome_header_bytes + 1 ..][0..2], .little), .little);
        try std.testing.expectEqualSlices(u8, &section, &expanded);
    }
}

test "chunk format and persisted group size reject incompatible configuration" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/format", .{temporary.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer disk.deinit();
    const space = try disk.openSpace("chunks");
    const resources = try records.Resources.init(allocator, io, .{ .readers = 1 });
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, space, 1, &registry, resources, .{ .side = 2 });
    store.side = 4;
    try std.testing.expectError(error.UnsupportedFormat, store.open());
    store.side = 2;
    try store.open();
    const root = (try space.getRoot()).?;
    var page: storage.Page = undefined;
    try space.readPages(&.{.{ .id = root, .destination = &page }});
    @memcpy(page[0..8], "LRCHNK03");
    try space.writePages(&.{.{ .id = root, .source = &page }});
    try std.testing.expectError(error.UnsupportedFormat, store.open());
}

test "chunk compression and consolidation allocate only during initialization" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/sealed", .{temporary.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 1024 });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
    failing.fail_index = failing.alloc_index;
    const key = keyFor(0);
    var initial: [8193]u8 = undefined;
    initial[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, initial[1 + index * 2 ..][0..2], @as(u16, @intCast(index)) *% 40503, .little);
    try store.putBatch(&.{.{ .key = &key, .value = &initial }});
    try store.flush();
    try disk.waitDurable(try disk.commit(1));
    var section: [8193]u8 = undefined;
    section[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, section[1 + index * 2 ..][0..2], @intCast(index % 31), .little);
    try store.putBatch(&.{.{ .key = &key, .value = &section }});
    try store.flush();
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    try disk.waitDurable(try disk.commit(2));
    var output: [8193]u8 = undefined;
    var lengths: [1]?usize = undefined;
    try store.decodeBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    try std.testing.expectEqualSlices(u8, &section, output[0..lengths[0].?]);
    try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
}

test "incompressible overlay snapshots retain dense bytes across consolidation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/dense", .{temporary.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 1024 });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 1 });
    const key = keyFor(0);
    const initial: [3]u8 = .{ 0, 1, 0 };
    try store.putBatch(&.{.{ .key = &key, .value = &initial }});
    try store.flush();
    try disk.waitDurable(try disk.commit(1));
    var section: [8193]u8 = undefined;
    section[0] = 1;
    var random = std.Random.DefaultPrng.init(20261031);
    random.random().bytes(section[1..]);
    try store.putBatch(&.{.{ .key = &key, .value = &section }});
    try store.flush();
    var output: [8193]u8 = undefined;
    var lengths: [1]?usize = undefined;
    try store.getBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    try std.testing.expectEqualSlices(u8, &section, output[0..lengths[0].?]);
    while (try store.prepareMerge()) {}
    _ = try store.publishPrepared();
    try disk.waitDurable(try disk.commit(2));
    try store.decodeBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    try std.testing.expectEqualSlices(u8, &section, output[0..lengths[0].?]);
}

test "consolidation preserves unrelated frames and publishes one group per call" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/group-publication", .{directory.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 2, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
    const a = chunks.encodeKey(.{ .world = 0, .x = 0, .z = 0, .y = 0 });
    const b = chunks.encodeKey(.{ .world = 0, .x = 8, .z = 0, .y = 0 });
    var initial: [8193]u8 = undefined;
    initial[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, initial[1 + index * 2 ..][0..2], @intCast(index % 17), .little);
    try store.putBatch(&.{ .{ .key = &a, .value = &initial }, .{ .key = &b, .value = &initial } });
    try store.flush();
    try disk.waitDurable(try disk.commit(1));
    try store.putBatch(&.{.{ .key = &a, .value = &.{ 0, 17, 0 } }});
    try store.flush();
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 1), store.prepared.value());
    try store.putBatch(&.{.{ .key = &b, .value = &.{ 0, 29, 0 } }});
    try store.flush();
    try std.testing.expectEqual(@as(u64, 0), store.merged.value());
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 2), store.prepared.value());
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    try std.testing.expectEqual(@as(usize, 0), try store.publishPrepared());
    try std.testing.expectEqual(@as(u64, 2), store.merged.value());
    try disk.waitDurable(try disk.commit(2));
    var output: [2][8193]u8 = undefined;
    var lengths: [2]?usize = undefined;
    try store.decodeBatch(&.{ .{ .key = &a, .destination = &output[0] }, .{ .key = &b, .destination = &output[1] } }, &lengths);
    try std.testing.expectEqualSlices(u8, &.{ 0, 17, 0 }, output[0][0..lengths[0].?]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 29, 0 }, output[1][0..lengths[1].?]);
}

test "dense group consolidation scans keys once without runtime allocation" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/key-discovery", .{directory.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
    const group = chunks.encodeKey(.{ .world = 0, .x = 0, .z = 0, .y = 0 });
    var keys: [64][16]u8 = undefined;
    store.sectionKeys(&group, &keys);
    var initial: [8193]u8 = undefined;
    initial[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, initial[1 + index * 2 ..][0..2], @intCast(index % 17), .little);
    var writes: [64]records.Write = undefined;
    failing.fail_index = failing.alloc_index;
    for (&keys, &writes) |*key, *write| write.* = .{ .key = key, .value = &initial };
    try store.putBatch(&writes);
    try store.flush();
    try disk.waitDurable(try disk.commit(1));
    for (&writes) |*write| write.value = &.{ 0, 17, 0 };
    try store.putBatch(&writes);
    try store.flush();
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 1), store.discovery_scans.value());
    try std.testing.expectEqual(@as(u64, 1), store.prepared.value());
    try store.flush();
    try std.testing.expectEqual(@as(u64, 0), store.merged.value());
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    try disk.waitDurable(try disk.commit(2));
    var output: [8193]u8 = undefined;
    var lengths: [1]?usize = undefined;
    for (&keys) |*key| {
        try store.decodeBatch(&.{.{ .key = key, .destination = &output }}, &lengths);
        try std.testing.expectEqualSlices(u8, &.{ 0, 17, 0 }, output[0..lengths[0].?]);
    }
    try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
}

test "consolidation retries invalidated groups without waiting for another edit" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/retry-group", .{directory.sub_path});
    var disk = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer disk.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    var store = try ChunkStore.init(allocator, io, try disk.openSpace("chunks"), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1 }), .{ .side = 4 });
    const key = keyFor(0);
    var initial: [8193]u8 = undefined;
    initial[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, initial[1 + index * 2 ..][0..2], @intCast(index % 17), .little);
    try store.putBatch(&.{.{ .key = &key, .value = &initial }});
    try store.putBatch(&.{.{ .key = &key, .value = &.{ 0, 17, 0 } }});
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 0), store.prepared.value());
    try store.flush();
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 1), store.prepared.value());
    try store.putBatch(&.{.{ .key = &key, .value = &.{ 0, 29, 0 } }});
    while (try store.prepareMerge()) {}
    try std.testing.expectEqual(@as(u64, 2), store.prepared.value());
    try std.testing.expectEqual(@as(usize, 1), try store.publishPrepared());
    var output: [8193]u8 = undefined;
    var lengths: [1]?usize = undefined;
    try store.decodeBatch(&.{.{ .key = &key, .destination = &output }}, &lengths);
    try std.testing.expectEqualSlices(u8, &.{ 0, 29, 0 }, output[0..lengths[0].?]);
}

test "incompressible groups progress through bounded packed reads without losing fills" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/packed-groups", .{temporary.sub_path});
    var database = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 32 });
    defer registry.deinit();
    const resources = try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 8, &registry, resources, .{ .side = 4 });
    var random = std.Random.DefaultPrng.init(0xac12319);
    const sections = try allocator.alloc([encoding.dense_block_bytes]u8, 64);
    for (sections) |*section| {
        section[0] = 1;
        random.random().bytes(section[1..]);
    }
    var groups: [8][16]u8 = undefined;
    var keys: [512][16]u8 = undefined;
    var writes: [512]records.Write = undefined;
    for (&groups, 0..) |*group, index| {
        const section: chunks.Section = .{ .world = 0, .x = @intCast(index * 4), .y = 0, .z = 0 };
        const key = chunks.encodeKey(section);
        group.* = try store.groupKey(&key);
        store.sectionKeys(group, keys[index * 64 ..][0..64]);
        for (keys[index * 64 ..][0..64], sections, writes[index * 64 ..][0..64]) |*at, *value, *write| write.* = .{ .key = at, .value = value };
    }
    try store.putBatch(&writes);
    try store.flush();
    try database.waitDurable(try database.commit(1));
    for (&groups) |*group| store.bases.invalidate(group);
    var group_keys: [8][]const u8 = undefined;
    for (&groups, &group_keys) |*group, *key| key.* = group;
    var frame_lengths: [8]?usize = undefined;
    try store.bases.backend.table.lengthsBatch(&group_keys, &frame_lengths);
    var compressed_bytes: usize = 0;
    for (frame_lengths) |length| compressed_bytes += length.?;
    try std.testing.expect(compressed_bytes > store.bases.backend.readers[0].bytes.len);
    const output = try allocator.alloc([encoding.dense_block_bytes]u8, 8);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var reads: [8]records.Get = undefined;
    for (&reads, output, 0..) |*read, *bytes, index| read.* = .{ .key = &keys[index * 64], .destination = bytes };
    const before = store.bases.metrics.reads.value();
    var lengths: [8]?usize = undefined;
    try store.getBatch(&reads, &lengths);
    for (output, lengths) |bytes, length| try std.testing.expectEqualSlices(u8, &sections[0], bytes[0..length.?]);
    try std.testing.expectEqual(before + 8, store.bases.metrics.reads.value());
    try std.testing.expectEqual(@as(usize, 0), store.bases.pinned_entries);
    try std.testing.expect(store.bases.value_storage.peak_bytes <= store.bases.values.len);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "tile ownership leaves foreground capacity and rebuilds current prepared classifications" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/owned-tile", .{temporary.sub_path});
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    const resources = try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
    const space = try database.openSpace(chunks.Chunks.id);
    var store = try ChunkStore.init(allocator, io, space, 2, &registry, resources, .{ .side = 1 });
    var properties: [256]u8 = undefined;
    for (&properties, 0..) |*property, index| property.* = @intCast(index % 2);
    const Prefix = struct {
        fn encode(value: *const encoding.Classification.Known, output: []u8) storage.Error!usize {
            std.mem.writeInt(u64, output[0..8], value.selected[0], .little);
            return 8;
        }
    };
    const codec: chunks.classification.Codec = .{ .identity = "test:prefix", .maximum = 8, .prefix_bytes = 8, .encode = Prefix.encode };
    const projection = try store.registerClassification(allocator, &properties, 1, codec);
    var contents: [5][encoding.dense_block_bytes]u8 = undefined;
    var keys: [5][16]u8 = undefined;
    var slices: [5][]const u8 = undefined;
    var writes: [5]records.Write = undefined;
    for (&contents, &keys, &slices, &writes, 0..) |*value, *key, *slice, *write, group| {
        value[0] = 1;
        for (0..4096) |index| std.mem.writeInt(u16, value[1 + index * 2 ..][0..2], @intCast((index + group) % 256), .little);
        key.* = keyFor(0);
        std.mem.writeInt(i32, key[12..16], @intCast(group), .big);
        slice.* = key;
        write.* = .{ .key = key, .value = value };
    }
    try store.putBatch(&writes);
    const window = try store.createGroupWindow(allocator, 3);
    const output = try allocator.alloc([encoding.dense_block_bytes]u8, 5);
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    window.begin(.{ .world = 0, .x = -2, .z = -2, .minimum = 0, .count = 3 });
    try std.testing.expectEqual(@as(usize, 2), store.bases.capacity);
    try std.testing.expectEqual(@as(usize, 5), store.bases.physical_capacity);
    try std.testing.expectEqual(@as(usize, 0), store.pipeline_pins);
    var reads: [5]records.Get = undefined;
    var lengths: [5]?usize = undefined;
    for (&reads, &keys, output) |*read, *key, *value| read.* = .{ .key = key, .destination = value };
    try store.getBatch(reads[0..3], lengths[0..3]);
    try std.testing.expectEqual(@as(usize, 3), store.pipeline_pins);
    try store.getBatch(reads[3..], lengths[3..]);
    const before = store.bases.metrics.reads.value();
    for (0..2) |_| try store.getBatch(reads[0..3], lengths[0..3]);
    try std.testing.expectEqual(before, store.bases.metrics.reads.value());
    for (contents, output, lengths) |expected, actual, length| try std.testing.expectEqualSlices(u8, &expected, actual[0..length.?]);
    std.mem.writeInt(u16, contents[0][1..3], 3, .little);
    try store.putBatch(&.{.{ .key = &keys[0], .value = &contents[0] }});
    try store.decodeBatch(reads[0..1], lengths[0..1]);
    try std.testing.expectEqualSlices(u8, &contents[0], output[0][0..lengths[0].?]);
    try std.testing.expectEqual(@as(usize, 3), store.pipeline_pins);
    window.reset();
    try std.testing.expectEqual(@as(usize, 0), store.pipeline_pins);
    try std.testing.expectEqual(@as(usize, 0), store.readers);
    try store.flush();
    try database.waitDurable(try database.commit(1));
    var reopened = try ChunkStore.init(arena.allocator(), io, space, 1, &registry, resources, .{ .side = 1 });
    const loaded_projection = try reopened.registerClassification(arena.allocator(), projection.properties, 1, codec);
    var results: [5]encoding.Classification = undefined;
    var classifications: [5]ChunkStore.ClassificationRead = undefined;
    for (&classifications, &keys, &results) |*read, *key, *result| read.* = .{ .key = key, .result = result };
    var prepared_bytes: [8]u8 = undefined;
    var prepared: chunks.classification.Prepared = .{ .bytes = &prepared_bytes };
    classifications[0].prepared = &prepared;
    try reopened.classify(&classifications, loaded_projection.properties, 1);
    const reads_before = reopened.bases.metrics.reads.value();
    try reopened.classify(&classifications, loaded_projection.properties, 1);
    try std.testing.expectEqual(reads_before, reopened.bases.metrics.reads.value());
    for (results, contents) |result, value| try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
    const decoded_flags = reopened.classification_decoded_bytes.value();
    for (&classifications) |*read| {
        read.projection = .flags;
        read.prepared = null;
    }
    try reopened.classify(&classifications, loaded_projection.properties, 1);
    try std.testing.expectEqual(decoded_flags, reopened.classification_decoded_bytes.value());
    for (results, contents) |result, value| {
        const expected = try encoding.classify(&value, &properties, 1);
        try std.testing.expectEqual(expected.common, result.summary.common);
        try std.testing.expectEqual(expected.property, result.summary.property);
    }
    for (&classifications) |*read| read.projection = .prefix;
    try reopened.classify(&classifications, loaded_projection.properties, 1);
    try std.testing.expectEqual(decoded_flags, reopened.classification_decoded_bytes.value());
    for (results, contents) |result, value| {
        const expected = try encoding.classify(&value, &properties, 1);
        try std.testing.expectEqual(@as(u8, 8), result.summary.prefix_len);
        try std.testing.expectEqual(expected.selected[0], std.mem.readInt(u64, result.summary.prefix[0..8], .little));
    }
    for (&classifications, 0..) |*read, index| read.projection = if (index % 2 == 0) .flags else .full;
    try reopened.classify(&classifications, loaded_projection.properties, 1);
    for (results, contents, 0..) |result, value, index| {
        const expected = try encoding.classify(&value, &properties, 1);
        if (index % 2 == 0) try std.testing.expectEqual(expected.common, result.summary.common) else try std.testing.expectEqualDeep(expected, result.known);
    }
    for (&classifications) |*read| read.projection = .full;
    classifications[0].prepared = &prepared;
    try reopened.putBatch(&.{
        .{ .key = &keys[0], .value = &.{ 0, 2, 0 } },
        .{ .key = &keys[1], .value = null },
        .{ .key = &keys[2], .value = &.{ 0, 7, 0 } },
        .{ .key = &keys[2], .value = &contents[2] },
    });
    try reopened.flush();
    try database.waitDurable(try database.commit(2));
    var updated = try ChunkStore.init(arena.allocator(), io, space, 1, &registry, resources, .{ .side = 1 });
    const updated_projection = try updated.registerClassification(arena.allocator(), projection.properties, 1, codec);
    try updated.classify(&classifications, updated_projection.properties, 1);
    prepared.length = 1;
    const decoded_before = updated.bases.metrics.reads.value();
    try updated.classify(&classifications, updated_projection.properties, 1);
    try std.testing.expectEqual(decoded_before, updated.bases.metrics.reads.value());
    try std.testing.expectEqual(@as(usize, 8), prepared.length);
    try std.testing.expectEqualDeep(try encoding.classify(&.{ 0, 2, 0 }, &properties, 1), results[0].known);
    try std.testing.expect(results[1] == .unavailable);
    for (results[2..], contents[2..]) |result, value| try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);

    try std.testing.expect(!bounded.has_induced_failure);
}

test "column summaries preserve negative coordinates partial groups and prepared prefixes without allocation" {
    const io = std.testing.io;
    const Prefix = struct {
        fn encode(value: *const encoding.Classification.Known, output: []u8) storage.Error!usize {
            std.mem.writeInt(u64, output[0..8], value.selected[0], .little);
            return 8;
        }
    };
    for ([_]u8{ 1, 2, 4 }) |side| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/column-summaries", .{temporary.sub_path});
        var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
        defer database.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 8, &registry, try records.Resources.init(allocator, io, .{}), .{ .side = side });
        const properties = [_]u8{ 2, 1, 2 };
        _ = try store.registerClassification(allocator, &properties, 1, .{ .identity = "test:column-prefix", .maximum = 8, .prefix_bytes = 8, .encode = Prefix.encode });
        const columns = [_]chunks.classification.Column{
            .{ .world = 0, .x = -5, .z = -1, .minimum = -3, .count = 7 },
            .{ .world = 0, .x = -4, .z = 0, .minimum = -3, .count = 7 },
            .{ .world = 1, .x = 2, .z = 3, .minimum = -3, .count = 7 },
            .{ .world = 2, .x = -5, .z = -1, .minimum = -3, .count = 7 },
        };
        const values = try allocator.alloc([encoding.dense_block_bytes]u8, 21);
        var keys: [21][16]u8 = undefined;
        var writes: [21]records.Write = undefined;
        for (values, &keys, &writes, 0..) |*value, *key, *write, index| {
            const column = columns[index / 7];
            key.* = chunks.encodeKey(.{ .world = column.world, .x = column.x, .z = column.z, .y = column.minimum + @as(i32, @intCast(index % 7)) });
            if (index % 3 == 2) {
                value[0] = 1;
                for (0..4096) |cell| std.mem.writeInt(u16, value[1 + cell * 2 ..][0..2], @intCast(1 + cell % 2), .little);
                write.* = .{ .key = key, .value = value };
            } else {
                value[0] = 0;
                std.mem.writeInt(u16, value[1..3], @intCast(1 + index % 3), .little);
                write.* = .{ .key = key, .value = value[0..3] };
            }
        }
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        try store.putBatch(&writes);
        try store.flush();
        var summaries: [columns.len]chunks.classification.ColumnSummary = undefined;
        try store.summarize(&columns, &summaries, &properties, 1);
        for (summaries[0..3], 0..) |summary_, column| {
            try std.testing.expectEqual(@as(u32, 127), summary_.known);
            for (0..7) |section_index| {
                const expected = try encoding.classify(writes[column * 7 + section_index].value.?, &properties, 1);
                try std.testing.expectEqual(expected.common, summary_.common[section_index]);
                const prefixed = summary_.prefixed & (@as(u32, 1) << @intCast(section_index)) != 0;
                try std.testing.expect(prefixed);
                if (prefixed) try std.testing.expectEqual(expected.selected[0], std.mem.readInt(u64, summary_.prefixes[section_index][0..8], .little));
            }
        }
        try std.testing.expectEqual(@as(u32, 0), summaries[3].known);
        try std.testing.expect(!bounded.has_induced_failure);
    }
}

test "delivery columns share source frames across encodings and reopen without allocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    const io = std.testing.io;
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/delivery", .{temporary.sub_path});
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    const resources = try records.Resources.init(allocator, io, .{});
    const column: light.Column = .{ .world = 7, .x = -3, .z = 19 };
    const identity: [32]u8 = @splat(17);
    const key = delivery.key(column);
    var source_workspace = try light.Workspace.init(allocator);
    const source_bytes = try savedLight(&source_workspace, "compiled", @splat(0));
    const source_frame = try source_workspace.decode(source_bytes);
    const source = delivery.Source.fromHeader(&source_frame.header);
    var record: [delivery.header_bytes + delivery.work_entry_bytes + 1 + 16]u8 = @splat(0);
    var writer = try delivery.Writer.begin(&record, source, 1024);
    try writer.append(0, .header, .{ .bytes = &.{ 0, 0, 0, 255, 255 }, .decoded = 1, .checksum = 1 });
    writer.aggregate(0, null);
    const compiled = writer.finish();
    var column_bytes: [2048]u8 = undefined;
    var builder = try delivery.Column.Builder.begin(&column_bytes, column, source_bytes, 1);
    @memcpy(builder.destination()[0..compiled.len], compiled);
    builder.append(identity, builder.destination()[0..compiled.len]);
    const cached_column = builder.finish();
    {
        var database = try storage.Store.init(allocator, io, .{ .path = path });
        defer database.deinit();
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 2, &registry, resources, .{ .side = 2 });
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        try std.testing.expect(try store.putLight(column, @splat(0), source_bytes));
        try store.putDeliveryRecords(&.{.{ .key = &key, .value = cached_column }});
        try database.waitDurable(try database.commit(9));
        try std.testing.expect(!bounded.has_induced_failure);
    }
    bounded.fail_index = std.math.maxInt(usize);
    bounded.resize_fail_index = std.math.maxInt(usize);
    {
        var database = try storage.Store.init(allocator, io, .{ .path = path });
        defer database.deinit();
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 2, &registry, resources, .{ .side = 2 });
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        var bytes: [1024]u8 = undefined;
        var frames: [1]?[]const u8 = undefined;
        var complete: [1]bool = undefined;
        var clean: [1]bool = .{true};
        var batch: light.FrameBatch = .{ .bytes = &bytes, .frames = &frames, .complete = &complete, .clean = &clean };
        var compiled_bytes: [1024]u8 = undefined;
        var values: [1]?[]const u8 = undefined;
        var finished: [1]bool = undefined;
        var variant_batch: records.PackedRead = .{ .bytes = &compiled_bytes, .values = &values, .complete = &finished };
        var additional: delivery.ReadBatch = .{ .keys = &.{key}, .output = &variant_batch };
        try store.deliveryFrames(&.{.{ .column = column, .minimum = 0, .count = 1 }}, &batch, &additional);
        try std.testing.expect(additional.submitted and complete[0] and clean[0] and finished[0]);
        try std.testing.expectEqualSlices(u8, source_bytes, frames[0].?);
        const loaded = try delivery.Column.read(values[0].?);
        _ = try delivery.View.read(loaded.find(identity).?, source);
        try std.testing.expectEqual(@intFromPtr(loaded.frame.ptr), @intFromPtr(frames[0].?.ptr));
        try std.testing.expectEqual(@as(usize, 0), batch.used);
        var cursor_buffer: [64]u8 = undefined;
        var cursor: records.ScanCursor = .{ .after = &cursor_buffer };
        var columns: [2]light.Column = undefined;
        const scanned = try store.savedLightColumns(&cursor, &columns);
        try std.testing.expectEqual(@as(usize, 1), scanned.count);
        try std.testing.expectEqualDeep(column, columns[0]);
        if (scanned.more) {
            const next = try store.savedLightColumns(&cursor, &columns);
            try std.testing.expectEqual(@as(usize, 0), next.count);
            try std.testing.expect(!next.more);
        }
        var changed = source;
        changed.revision = 1;
        try std.testing.expectError(error.Outdated, delivery.View.read(loaded.find(identity).?, changed));
        try std.testing.expectEqual(@as(u64, 9), database.lastTick());
        const section = chunks.encodeKey(.{ .world = column.world, .x = column.x, .y = 0, .z = column.z });
        try store.putBatch(&.{.{ .key = &section, .value = &.{ 0, 1, 0 } }});
        try store.putDeliveryRecords(&.{.{ .key = &key, .value = cached_column }});
        try store.lightFrames(&.{.{ .column = column, .minimum = 0, .count = 1 }}, &batch);
        try std.testing.expect(complete[0] and frames[0] == null);
        var current: [encoding.maximum_decoded_bytes]u8 = undefined;
        var length: [1]?usize = undefined;
        try store.getBatch(&.{.{ .key = &section, .destination = &current }}, &length);
        try std.testing.expectEqualSlices(u8, &.{ 0, 1, 0 }, current[0..length[0].?]);
        const publication_count = light.dependency_batch_max + 1;
        var buffers: [publication_count][1024]u8 = undefined;
        var keys: [publication_count][delivery.key_bytes]u8 = undefined;
        var writes: [publication_count]records.Write = undefined;
        for (&buffers, &keys, &writes, 0..) |*buffer, *target, *write, index| {
            const at: light.Column = .{ .world = column.world, .x = @intCast(100 + index), .z = column.z };
            var record_builder = try delivery.Column.Builder.begin(buffer, at, source_bytes, 1);
            const destination = record_builder.destination()[0..compiled.len];
            @memcpy(destination, compiled);
            record_builder.append(identity, destination);
            target.* = delivery.key(at);
            write.* = .{ .key = target, .value = record_builder.finish() };
        }
        try store.putDeliveryRecords(&writes);
        const last: light.Column = .{ .world = column.world, .x = 100 + publication_count - 1, .z = column.z };
        try store.lightFrames(&.{.{ .column = last, .minimum = 0, .count = 1 }}, &batch);
        try std.testing.expectEqualSlices(u8, source_bytes, frames[0].?);
        try expectLightPrefix(&store, last, source_bytes);
        try std.testing.expect(!bounded.has_induced_failure);
    }
}

test "disposable projections rebuild after deletion without writing the authoritative world" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/derived", .{temporary.sub_path});
    const properties = [_]u8{ 0, 1, 2, 1 };
    const key = chunks.encodeKey(.{ .world = 0, .x = -7, .y = -2, .z = 9 });
    const Prefix = struct {
        fn encode(value: *const encoding.Classification.Known, output: []u8) storage.Error!usize {
            output[0] = value.common;
            return 1;
        }
    };
    for (0..3) |phase| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
        defer database.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
        const resources = try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 });
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 1, &registry, resources, .{ .side = 1 });
        const index = try store.registerClassification(allocator, &properties, 1, .{ .identity = if (phase == 2) "test:projection:2" else "test:projection:1", .maximum = 1, .prefix_bytes = 1, .encode = Prefix.encode });
        if (phase == 0) {
            try store.putBatch(&.{.{ .key = &key, .value = &.{ 0, 1, 0 } }});
            try store.flush();
            try database.waitDurable(try database.commit(1));
        }
        const before = database.wal_bytes.value();
        const commit = database.lastCommit();
        var result: encoding.Classification = undefined;
        var prepared_bytes: [1]u8 = undefined;
        var prepared: chunks.classification.Prepared = .{ .bytes = &prepared_bytes };
        const reads = [_]ChunkStore.ClassificationRead{.{ .key = &key, .result = &result, .prepared = &prepared }};
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(&.{ 0, 1, 0 }, &properties, 1), result.known);
        try std.testing.expectEqual(@as(usize, 1), prepared.length);
        const loaded = store.bases.metrics.reads.value();
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqual(loaded, store.bases.metrics.reads.value());
        try std.testing.expectEqual(before, database.wal_bytes.value());
        try std.testing.expectEqual(commit, database.lastCommit());
        try std.testing.expectEqual(@as(u64, 1), database.lastTick());
        var root: storage.Page = undefined;
        try store.overlays.space.readPages(&.{.{ .id = (try store.overlays.space.getRoot()).?, .destination = &root }});
        try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, root[40..48], .little));
        if (phase == 0) {
            // Unlinking the open cache preserves its lifetime until the store closes.
            // The next process must rebuild from the authoritative file alone.
            try temporary.dir.deleteFile(io, "derived.cache");
        }
    }
}

test "cache stamps distinguish divergent writes after an interrupted tick" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/rollback-cache", .{temporary.sub_path});
    const properties = [_]u8{ 0, 1, 2, 1 };
    const key = chunks.encodeKey(.{ .world = 0, .x = 0, .y = 0, .z = 0 });
    var abandoned: u64 = undefined;
    for (0..2) |phase| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
        defer database.deinit();
        var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
        var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
        const index = try store.registerClassification(allocator, &properties, 1, null);
        if (phase == 0) {
            try store.putBatch(&.{.{ .key = &key, .value = &.{ 0, 0, 0 } }});
            try store.flush();
            try database.waitDurable(try database.commit(1));
        } else try std.testing.expectEqual(@as(u64, 1), database.lastTick());
        const value = [_]u8{ 0, if (phase == 0) 1 else 2, 0 };
        try store.putBatch(&.{.{ .key = &key, .value = &value }});
        try store.flush();
        var dependencies: [1]light.Dependencies = undefined;
        try store.lightDependencies(&.{.{ .column = .{ .world = 0, .x = 0, .z = 0 }, .minimum = 0, .count = 1 }}, &dependencies);
        if (phase == 0) abandoned = dependencies[0].revisions[4] else try std.testing.expect(abandoned != dependencies[0].revisions[4]);
        var result: encoding.Classification = undefined;
        const reads = [_]ChunkStore.ClassificationRead{.{ .key = &key, .result = &result }};
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
        try store.derived.publish();
        if (phase == 1) {
            store.derived.store.failed = true;
            try store.classify(&reads, index.properties, 1);
            // The cache was emptied in place rather than switched off.
            try std.testing.expectEqual(.ready, store.derived.state.load(.acquire));
            try std.testing.expectEqual(@as(u32, 1), store.derived.generation.load(.acquire));
            try std.testing.expectEqualDeep(try encoding.classify(&value, &properties, 1), result.known);
            try database.waitDurable(try database.commit(2));
            try std.testing.expectEqual(@as(u64, 2), database.lastTick());
        }
    }
}

test "patched light records are stored replaced and deleted beside the frames of their column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/patched-light", .{temporary.sub_path});
    var database = try storage.Store.init(allocator, io, .{ .path = path });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(allocator, io, .{}), .{ .side = 2 });
    var workspace = try light.Workspace.init(allocator);
    const column: light.Column = .{ .world = 3, .x = -7, .z = 12 };
    const other: light.Column = .{ .world = 3, .x = -6, .z = 12 };
    const destination = try allocator.alloc(u8, 128 * 1024);
    var values: [2]?[]const u8 = undefined;
    var complete: [2]bool = undefined;
    var read: records.PackedRead = .{ .bytes = destination, .values = &values, .complete = &complete };
    store.patchedLights(&.{ column, other }, &read);
    try std.testing.expectEqual(@as(?[]const u8, null), values[0]);
    try std.testing.expect(complete[0] and complete[1]);

    // A record as large as a column of fully dense light fits.
    const large = try allocator.alloc(u8, 2 * 26 * 2048 + 64);
    for (large, 0..) |*byte, index| byte.* = @truncate(index * 31);
    try std.testing.expect(store.putPatchedLights(&.{column}, &.{large}));
    store.patchedLights(&.{ column, other }, &read);
    try std.testing.expectEqualSlices(u8, large, values[0].?);
    try std.testing.expectEqual(@as(?[]const u8, null), values[1]);

    // It shares the column with a baked frame and neither disturbs the other.
    const encoded = try savedLight(&workspace, "beside", @splat(0));
    try std.testing.expect(try store.putLight(column, @splat(0), encoded));
    store.patchedLights(&.{ column, other }, &read);
    try std.testing.expectEqualSlices(u8, large, values[0].?);

    // One write replaces a record and adds another.
    try std.testing.expect(store.putPatchedLights(&.{ column, other }, &.{ "replaced", "second" }));
    store.patchedLights(&.{ column, other }, &read);
    try std.testing.expectEqualSlices(u8, "replaced", values[0].?);
    try std.testing.expectEqualSlices(u8, "second", values[1].?);

    // A value the buffer has no room left for is not complete and reads alone later.
    try std.testing.expect(store.putPatchedLights(&.{column}, &.{large}));
    var small: records.PackedRead = .{ .bytes = destination[0 .. large.len + 3], .values = &values, .complete = &complete };
    store.patchedLights(&.{ column, other }, &small);
    try std.testing.expectEqualSlices(u8, large, values[0].?);
    try std.testing.expect(complete[0] and !complete[1] and values[1] == null);
    var alone: records.PackedRead = .{ .bytes = destination, .values = values[0..1], .complete = complete[0..1] };
    store.patchedLights(&.{other}, &alone);
    try std.testing.expectEqualSlices(u8, "second", values[0].?);

    // Deleting leaves the frame of the column alone. Deleting what is not there is not an error.
    try std.testing.expect(store.putPatchedLights(&.{column}, &.{null}));
    try std.testing.expect(store.putPatchedLights(&.{column}, &.{null}));
    store.patchedLights(&.{ column, other }, &read);
    try std.testing.expectEqual(@as(?[]const u8, null), values[0]);
    try std.testing.expectEqualSlices(u8, "second", values[1].?);

    // Clearing removes every patched record and nothing else.
    for (0..150) |index| {
        try std.testing.expect(store.putPatchedLights(&.{.{ .world = 9, .x = @intCast(index), .z = -3 }}, &.{"left behind"}));
    }
    var passes: usize = 1;
    while (store.clearPatchedLights()) passes += 1;
    try std.testing.expect(passes >= 3);
    store.patchedLights(&.{ other, .{ .world = 9, .x = 149, .z = -3 } }, &read);
    try std.testing.expectEqual(@as(?[]const u8, null), values[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), values[1]);
    var after: [64]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &after };
    var saved: [4]light.Column = undefined;
    const scan = try store.savedLightColumns(&cursor, &saved);
    try std.testing.expectEqual(@as(usize, 1), scan.count);
    try std.testing.expectEqual(column, saved[0]);
}

test "a store opens and works without a place in the cache" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/unplaced", .{temporary.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registries = [_]metrics.Registry{ try .init(allocator, io, .{}), try .init(allocator, io, .{}), try .init(allocator, io, .{}) };
    var workspace = try light.Workspace.init(allocator);
    const encoded = try savedLight(&workspace, "unplaced", @splat(0));
    const column: light.Column = .{ .world = 0, .x = 3, .z = 0 };

    // A store placed while the cache had room keeps working when it fills up.
    var placed = try ChunkStore.init(allocator, io, try database.openSpace("placed"), 1, &registries[0], try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    try std.testing.expect(!placed.derived_unplaced);
    const cache = placed.derived;
    // Every name the cache has is taken, as by stores of other scopes opened before.
    var taken: usize = 0;
    var name_buffer: [32]u8 = undefined;
    while (cache.openSpace(try std.fmt.bufPrint(&name_buffer, "other_{d}", .{taken}))) |_| taken += 1 else |err| try std.testing.expectEqual(error.NoSpace, err);
    try std.testing.expect(taken != 0);

    var late = try ChunkStore.init(allocator, io, try database.openSpace("late"), 1, &registries[1], try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    try std.testing.expect(late.derived_unplaced);
    // It stores terrain as any store does, and derives everything else each time.
    try late.putBatch(&.{.{ .key = &chunks.encodeKey(.{ .world = 0, .x = 0, .y = 0, .z = 0 }), .value = &.{ 0, 1, 0 } }});
    try std.testing.expect(!try late.putLight(column, @splat(0), encoded));
    try expectLightFrame(&late, column, null);
    try std.testing.expect(!late.putPatchedLights(&.{column}, &.{"light"}));
    try std.testing.expect(!late.clearPatchedLights());
    try std.testing.expect(try placed.putLight(column, @splat(0), encoded));
    try expectLightFrame(&placed, column, encoded);

    // A cache dropped for the rest of the process leaves a new store unplaced as well.
    try std.testing.expect(try cache.discard());
    var after = try ChunkStore.init(allocator, io, try database.openSpace("after"), 1, &registries[2], try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    try std.testing.expect(after.derived_unplaced);
    try expectLightFrame(&after, column, null);
    try expectLightFrame(&placed, column, null);
}

test "light metadata of superseded revisions is deleted when a frame is written again" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/superseded", .{temporary.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 2, &registry, try records.Resources.init(allocator, io, .{}), .{ .side = 1 });
    var workspace = try light.Workspace.init(allocator);
    const column: light.Column = .{ .world = 0, .x = 4, .z = -2 };
    const beside: light.Column = .{ .world = 0, .x = 5, .z = -2 };

    const Count = struct {
        /// Metadata records the cache holds for a column, under any revisions.
        fn of(owner: *ChunkStore, at: light.Column) !usize {
            var keys: [16][64]u8 = undefined;
            var entries: [16]records.ScanKey = undefined;
            for (&keys, &entries) |*key, *entry| entry.* = .{ .key = key };
            var after: [64]u8 = undefined;
            const prefix = at.key(.metadata);
            @memcpy(after[0..13], &prefix);
            var cursor: records.ScanCursor = .{ .after = &after, .after_len = 13 };
            const result = try owner.lights.scanKeys(&cursor, &entries);
            var found: usize = 0;
            for (entries[0..result.count]) |entry| found += @intFromBool(entry.key_len == 21 and std.mem.eql(u8, entry.key[0..13], &prefix));
            return found;
        }
    };

    // Each save of a neighbouring column gives the frame new revisions to be written for.
    var revisions: [9]u64 = @splat(0);
    var revisions_beside: [9]u64 = @splat(0);
    for (0..5) |round| {
        const encoded = try savedLight(&workspace, "superseded", revisions);
        try std.testing.expect(try store.putLight(column, revisions, encoded));
        try std.testing.expect(try store.putLight(beside, revisions_beside, try savedLight(&workspace, "superseded", revisions_beside)));
        try expectLightPrefix(&store, column, try savedLight(&workspace, "superseded", revisions));
        // One record for the revisions it has now, however often they changed before.
        try std.testing.expectEqual(@as(usize, 1), try Count.of(&store, column));
        try std.testing.expectEqual(@as(usize, 1), try Count.of(&store, beside));
        // The centre column of both neighbourhoods overlaps, so one write moves both.
        var key: [16]u8 = chunks.encodeKey(.{ .world = 0, .x = 4, .y = 0, .z = -2 });
        try store.putBatch(&.{.{ .key = &key, .value = &.{ 0, @intCast(round + 1), 0 } }});
        var snapshot: [1]light.Dependencies = undefined;
        try store.lightDependencies(&.{.{ .column = column, .minimum = 0, .count = 1 }}, &snapshot);
        try std.testing.expect(!std.mem.eql(u64, &revisions, &snapshot[0].revisions));
        revisions = snapshot[0].revisions;
        try store.lightDependencies(&.{.{ .column = beside, .minimum = 0, .count = 1 }}, &snapshot);
        revisions_beside = snapshot[0].revisions;
        try expectLightPrefix(&store, column, null);
    }
}

test "classification records of superseded revisions are deleted when a column is classified again" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/reclassified", .{temporary.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    var store = try ChunkStore.init(allocator, io, try database.openSpace(chunks.Chunks.id), 1, &registry, try records.Resources.init(allocator, io, .{ .readers = 1, .writers = 1 }), .{ .side = 1 });
    const properties = [_]u8{ 0, 1, 1, 0, 1, 0, 1, 1 };
    const index = try store.registerClassification(allocator, &properties, 1, null);
    const key = chunks.encodeKey(.{ .world = 0, .x = 7, .y = 0, .z = -3 });
    const other = chunks.encodeKey(.{ .world = 0, .x = 8, .y = 0, .z = -3 });

    const Count = struct {
        /// Records the index holds, of every kind and for every column and revision.
        fn of(table: records.Table) !usize {
            var keys: [64][64]u8 = undefined;
            var entries: [64]records.ScanKey = undefined;
            for (&keys, &entries) |*slot, *entry| entry.* = .{ .key = slot };
            var after: [64]u8 = undefined;
            after[0] = 0;
            var cursor: records.ScanCursor = .{ .after = &after, .after_len = 1 };
            const result = try table.scanKeys(&cursor, &entries);
            try std.testing.expect(!result.more);
            return result.count;
        }
    };

    var result: encoding.Classification = undefined;
    var beside: encoding.Classification = undefined;
    const reads = [_]ChunkStore.ClassificationRead{ .{ .key = &key, .result = &result }, .{ .key = &other, .result = &beside } };
    var settled: ?usize = null;
    for (1..6) |round| {
        // A mixed section, so that it has a record of its own beside the header.
        var dense: [8193]u8 = undefined;
        dense[0] = 1;
        for (0..4096) |cell| std.mem.writeInt(u16, dense[1 + cell * 2 ..][0..2], @intCast((cell + round) % properties.len), .little);
        var value: [encoding.maximum_decoded_bytes]u8 = undefined;
        const packed_section = try encoding.encode(&dense, &value);
        const stored = value[0..packed_section.len];
        if (packed_section.ptr != stored.ptr) @memcpy(stored, packed_section);
        try store.putBatch(&.{ .{ .key = &key, .value = stored }, .{ .key = &other, .value = stored } });
        try store.flush();
        try database.waitDurable(try database.commit(round));
        try store.classify(&reads, index.properties, 1);
        try std.testing.expectEqualDeep(try encoding.classify(stored, &properties, 1), result.known);
        const held = try Count.of(index.table);
        try std.testing.expect(held != 0);
        // What two columns need at one revision, however many revisions came before.
        if (settled) |expected| try std.testing.expectEqual(expected, held);
        settled = held;
    }
}
