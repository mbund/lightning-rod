const storage = @import("storage");
const std = @import("std");
const chunks = @import("chunks.zig");
const encoding = @import("encoding.zig");
const metrics = @import("metrics");
const records = @import("records");

fn demandBesidePrefetchProbe(output: *std.Io.Writer) !void {
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
    try output.writeAll("prefetched | demanded | canceled requests | generated sections\n");
    const Case = struct { prefetched: usize, demanded: usize };
    for ([_]Case{ .{ .prefetched = 6, .demanded = 3 }, .{ .prefetched = 14, .demanded = 3 }, .{ .prefetched = 62, .demanded = 3 }, .{ .prefetched = 168, .demanded = 25 } }) |case| {
        const prefetched = case.prefetched;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/budgets", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        // The cache holds the two budgets and the edits budget and nothing more.
        const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .cache_sections = 1 + prefetched + case.demanded, .edit_sections = 1, .simulation_sections = 0, .cache_groups = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
        });
        const background = try terrain.client(.{ .name = "background", .sections = prefetched });
        const demand = try terrain.client(.{ .name = "demand", .sections = case.demanded });
        try std.testing.expectError(error.CacheBudgetExceeded, terrain.client(.{ .name = "extra", .sections = 1 }));
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        terrain.attach();
        defer terrain.stop();
        var sections: [192]chunks.Section = undefined;
        var prepared: [192]chunks.Lease = undefined;
        for (sections[0..prefetched], 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index / 24), .y = @as(i32, @intCast(index % 24)) - 4, .z = 0 };
        var ready: [1]bool = undefined;
        try background.prepareMany(&.{.{ .sections = sections[0..prefetched], .leases = prepared[0..prefetched], .priority = .{ .player = 1 } }}, &ready);
        try std.testing.expect(!ready[0]);
        try std.testing.expectEqual(prefetched, terrain.generation.queued_count);
        // Sections being generated for a preparation count against its client until ready.
        try std.testing.expectEqual(@as(usize, 0), background.available());
        const more: chunks.Section = .{ .world = 0, .x = 100, .y = 0, .z = 0 };
        // More waits until some of them are ready.
        try background.prepareMany(&.{.{ .sections = &.{more}, .leases = prepared[0..1], .priority = .{ .player = 1 } }}, &ready);
        try std.testing.expect(!ready[0]);
        try std.testing.expectEqual(prefetched, terrain.generation.queued_count);
        var requested: [32]chunks.Section = undefined;
        const needed = requested[0..case.demanded];
        for (needed, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(8 + index / 24), .y = @as(i32, @intCast(index % 24)) - 4, .z = 0 };
        var demanded: [32]chunks.Lease = undefined;
        {
            try demand.acquireMany(needed, demanded[0..needed.len]);
            defer terrain.releaseMany(demanded[0..needed.len]);
            for (demanded[0..needed.len]) |lease| try std.testing.expectEqual(@as(u16, 7), lease.get(0));
        }
        // Demand never takes what another client prepared.
        var preserved: usize = 0;
        for (sections[0..prefetched]) |section| preserved += @intFromBool(terrain.generation.index.contains(section));
        try std.testing.expectEqual(prefetched, preserved);
        try output.print("{d:10} | {d:8} | {d:17} | {d}\n", .{ prefetched, needed.len, prefetched - preserved, source.generated });
        terrain.generation.update(1, null);
        try terrain.poll();
        try std.testing.expectEqual(prefetched, background.available());
    }
}

pub fn benchmarkDemandBesidePrefetch() !void {
    var buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(std.testing.io, &buffer);
    try demandBesidePrefetchProbe(&output.interface);
    try output.interface.flush();
}

test "demand within its budget never cancels another client's prefetch" {
    var buffer: [256]u8 = undefined;
    var output = std.Io.Writer.Discarding.init(&buffer);
    try demandBesidePrefetchProbe(&output.writer);
}

test {
    _ = @import("prepared.zig");
    _ = @import("store_test.zig");
    _ = @import("patch_test.zig");
}

test "generation capacity is independent of retained terrain and drains larger demand batches" {
    const Source = struct {
        generated: usize = 0,
        fn read(self: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            self.generated += batch.requests.len;
            for (batch.requests) |*request| request.result = chunks.uniform(@intCast(request.section.x + 7), request.output);
        }
    };
    const io = std.testing.io;
    for ([_]usize{ 8, 256 }) |capacity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/generation-capacity", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = bounded.allocator();
        var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
        const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = capacity + 1, .generation_slots = 2, .cache_groups = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
        });
        const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
        try std.testing.expectEqual(@as(usize, 2), terrain.generation.slots.len);
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        bounded.fail_index = bounded.alloc_index;
        bounded.resize_fail_index = bounded.resize_index;
        var sections: [8]chunks.Section = undefined;
        var leases: [8]chunks.Lease = undefined;
        for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index), .y = 0, .z = 0 };
        try reader.acquireMany(&sections, &leases);
        defer terrain.releaseMany(&leases);
        for (leases, 0..) |lease, index| try std.testing.expectEqual(@as(u16, @intCast(index + 7)), lease.get(0));
        try std.testing.expectEqual(sections.len, source.generated);
        try std.testing.expectEqual(terrain.generation.slots.len, terrain.generation.free_count);
        try std.testing.expectEqual(@as(usize, 0), terrain.generating_count);
        try std.testing.expect(!bounded.has_induced_failure);
    }
}

test "the maximum pinned section batch fits incompressible terrain without runtime allocation" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                request.output[0] = 3;
                for (0..encoding.biome_cells) |index| std.mem.writeInt(u16, request.output[1 + index * 2 ..][0..2], @intCast(index), .little);
                request.output[encoding.biome_header_bytes] = 1;
                for (0..encoding.blocks) |index| std.mem.writeInt(u16, request.output[encoding.biome_header_bytes + 1 + index * 2 ..][0..2], @intCast(index), .little);
                request.result = encoding.maximum_decoded_bytes;
            }
        }
    };
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/maximum-pins", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 193 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
    });
    const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var sections: [192]chunks.Section = undefined;
    var leases: [192]chunks.Lease = undefined;
    for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index), .y = 0, .z = 0 };
    try reader.acquireMany(&sections, &leases);
    defer terrain.releaseMany(&leases);
    try std.testing.expectEqual(leases.len, terrain.cache.pinned_entries);
    var bytes: usize = 0;
    for (leases) |lease| {
        try std.testing.expect(lease.view() == .dense);
        try std.testing.expectEqual(@as(u16, 4095), lease.get(4095));
        try std.testing.expectEqual(@as(u16, 63), lease.biomes().?.get(63));
        bytes += lease.record.read().?.len;
    }
    try std.testing.expectEqual(leases.len * encoding.maximum_decoded_bytes, bytes);
    const slot = terrain.cache.values.len / terrain.cache.entries.len;
    try std.testing.expect(slot >= encoding.maximum_decoded_bytes and slot - encoding.maximum_decoded_bytes < 64);
    try std.testing.expect(!bounded.has_induced_failure);
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
        const terrain = try chunks.Chunks.init(arena.allocator(), std.testing.io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = capacity + 1, .cache_groups = 2 }, .{
            .metrics = &registry,
            .storage = try store.openSpace(chunks.Chunks.id),
            .record_workspaces = try records.Workspaces.init(arena.allocator(), std.testing.io, .{}),
        });
        const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        var window = chunks.ReadWindow(2).init(reader);
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
        var dense: [encoding.dense_block_bytes]u8 = undefined;
        dense[0] = 1;
        for (0..encoding.blocks) |i| {
            const state = @as(u16, @intCast(i % count)) *% 40503 +% 65535;
            std.mem.writeInt(u16, dense[1 + i * 2 ..][0..2], state, .little);
        }
        var encoded: [encoding.dense_block_bytes]u8 = undefined;
        const bytes = try encoding.encode(&dense, &encoded);
        const expected = if (count == 1) 3 else @min(encoding.dense_block_bytes, 3 + @as(usize, count) * 2 + 512 * @as(usize, std.math.log2_int_ceil(u16, count)));
        try std.testing.expectEqual(expected, bytes.len);
        if (count >= 1279) try std.testing.expectEqual(dense[0..].ptr, bytes.ptr);
        var decoded: [encoding.dense_block_bytes]u8 = undefined;
        @memcpy(decoded[0..bytes.len], bytes);
        const length = try encoding.decode(&decoded, bytes.len);
        var direct: [encoding.dense_block_bytes]u8 = undefined;
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
    var bytes: [encoding.dense_block_bytes]u8 = @splat(0);
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
    bytes[9] = 1;
    bytes[9 + 512] = 1;
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1033));
    bytes[9] = 0;
    bytes[9 + 512] = 0;
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1032));
    try std.testing.expectError(error.Corrupt, encoding.decode(&bytes, 1034));
    try std.testing.expectError(error.BufferTooSmall, encoding.decode(bytes[0..1033], 1033));
}

test "section edits preserve palettes biomes and caller order across rebuilds" {
    for ([_]usize{ 0, encoding.biome_header_bytes }) |offset| {
        for ([_]u16{ 1, 2, 3, 4, 17, 257, 1024, 1278, 1279, 1280, 4096 }) |count| {
            var reference: [encoding.maximum_decoded_bytes]u8 = undefined;
            var buffer: [encoding.maximum_decoded_bytes]u8 = undefined;
            var scratch: [encoding.maximum_decoded_bytes]u8 = undefined;
            if (offset != 0) {
                reference[0] = 3;
                for (0..encoding.biome_cells) |index| std.mem.writeInt(u16, reference[1 + index * 2 ..][0..2], @intCast(index * 101), .little);
            }
            reference[offset] = 1;
            for (0..encoding.blocks) |index| std.mem.writeInt(u16, reference[offset + 1 + index * 2 ..][0..2], @intCast(index % count), .little);
            const encoded = try encoding.encode(reference[0 .. offset + encoding.dense_block_bytes], &buffer);
            var length = encoded.len;
            if (encoded.ptr != buffer[0..].ptr) @memcpy(buffer[0..length], encoded);
            var additions: [16]chunks.BlockEdit = undefined;
            for (&additions, 0..) |*edit, index| edit.* = .{ .index = @intCast(128 + index), .state = @intCast(55000 + index) };
            for ([_][]const chunks.BlockEdit{
                &.{ .{ .index = 7, .state = 1 % count }, .{ .index = 15, .state = 0 }, .{ .index = 7, .state = 0 } },
                &.{ .{ .index = 0, .state = 65535 }, .{ .index = 4095, .state = 65535 } },
                &additions,
            }, 0..) |edits, step| {
                const before = length;
                length = try encoding.edit(&buffer, length, edits, &scratch);
                if (step == 0 and count >= 2 and count <= 1024) try std.testing.expectEqual(before, length);
                for (edits) |edit| std.mem.writeInt(u16, reference[offset + 1 + @as(usize, edit.index) * 2 ..][0..2], edit.state, .little);
                const view = try encoding.Packed.init(buffer[0..length]);
                for (0..256) |row| {
                    const states = view.row(@intCast(row));
                    for (states, 0..) |state, lane| {
                        const index = row * 16 + lane;
                        try std.testing.expectEqual(std.mem.readInt(u16, reference[offset + 1 + index * 2 ..][0..2], .little), state);
                        try std.testing.expectEqual(state, view.get(@intCast(index)));
                    }
                }
                for (0..128) |group| {
                    var rows: [2][16]u16 = undefined;
                    view.pair(@intCast(group), &rows[0], &rows[1]);
                    for (rows, 0..) |cells, half| try std.testing.expectEqualSlices(u16, &view.row(@intCast(group * 2 + half)), &cells);
                }
                try std.testing.expectEqualSlices(u8, reference[0..offset], buffer[0..offset]);
            }
            var replacement: [encoding.blocks]chunks.BlockEdit = undefined;
            for (&replacement, 0..) |*edit, index| edit.* = .{ .index = @intCast(index), .state = 42 };
            length = try encoding.edit(&buffer, length, &replacement, &scratch);
            try std.testing.expectEqual(offset + 3, length);
            try std.testing.expectEqualSlices(u8, reference[0..offset], buffer[0..offset]);
            try std.testing.expectEqual(@as(u16, 42), (try encoding.Packed.init(buffer[0..length])).get(4095));
            try std.testing.expectEqual(buffer[0..].ptr, (try encoding.encode(buffer[0..length], &scratch)).ptr);
        }
    }
}

test "generated loaded and edited sections stay paletted without runtime allocation" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| {
                request.output[0] = 3;
                for (0..encoding.biome_cells) |index| std.mem.writeInt(u16, request.output[1 + index * 2 ..][0..2], @intCast(index + 7), .little);
                request.output[encoding.biome_header_bytes] = 1;
                for (0..encoding.blocks) |index| std.mem.writeInt(u16, request.output[encoding.biome_header_bytes + 1 + index * 2 ..][0..2], @intCast(index % 2), .little);
                request.result = encoding.maximum_decoded_bytes;
            }
        }
    };
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/palette-cache", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 2, .cache_groups = 2 }, .{
        .metrics = &registry,
        .storage = space,
        .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
    });
    const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    const original: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    // Two other sections fill the two entries, so the original is evicted and loaded again.
    const others = [_]chunks.Section{ .{ .world = 0, .x = 1, .y = 0, .z = 0 }, .{ .world = 0, .x = 2, .y = 0, .z = 0 } };
    for (0..4) |step| {
        const lease = try reader.acquire(original);
        try std.testing.expect(lease.view() == .palette);
        try std.testing.expect(lease.record.read().?.len < encoding.maximum_decoded_bytes / 4);
        const expected: u16 = if (step == 0) 1 else 23;
        try std.testing.expectEqual(expected, lease.get(7));
        const row = lease.view().row(0);
        try std.testing.expectEqual(expected, row[7]);
        try std.testing.expectEqual(@as(u16, 10), lease.biomes().?.get(3));
        lease.release();
        try terrain.setBlocks(original, &.{ .{ .index = 6, .state = 1 }, .{ .index = 7, .state = 23 } });
        try terrain.checkpoint(space);
        for (others) |other| (try reader.acquire(other)).release();
    }
    try std.testing.expect(!bounded.has_induced_failure);
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
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
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
        const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
        const reader = try world.client(.{ .name = "test", .sections = @min(192, world.unbudgeted()) });
        for ([_]chunks.Section{ a, b, c, a }) |section| {
            const lease = try reader.acquire(section);
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
    var cache = try records.Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .slots = 40, .key_bytes = 1, .value_bytes = encoding.dense_block_bytes, .codec = encoding.codec, .scan_batch = 2 });
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
        lease.commit(encoding.dense_block_bytes);
        lease.release();
    }
    try cache.flush();
    var scan = try records.Cache.init(arena.allocator(), io, records.Table.init(space, table_resources), .{ .slots = 1, .key_bytes = 1, .value_bytes = encoding.dense_block_bytes, .codec = encoding.codec, .scan_batch = 2 });
    var cursor_key: [1]u8 = undefined;
    var cursor: records.ScanCursor = .{ .after = &cursor_key };
    var scan_keys: [2][1]u8 = undefined;
    var scan_values: [2][encoding.dense_block_bytes]u8 = undefined;
    var entries: [2]records.ScanEntry = undefined;
    for (&entries, &scan_keys, &scan_values) |*entry, *key, *value| entry.* = .{ .key = key, .value = value };
    var read: usize = 0;
    while (true) {
        const result = try scan.scan(&cursor, &entries);
        for (entries[0..result.count]) |entry| {
            try std.testing.expectEqual(read, entry.key[0]);
            try std.testing.expectEqual(encoding.dense_block_bytes, entry.value_len);
            for (0..encoding.blocks) |i| try std.testing.expectEqual(@as(u16, @intCast(read * 64 + i % 64)), std.mem.readInt(u16, entry.value[1 + i * 2 ..][0..2], .little));
            read += 1;
        }
        if (!result.more) break;
    }
    try std.testing.expectEqual(keys.len, read);
    var value: [encoding.dense_block_bytes]u8 = undefined;
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
    const terrain = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 3, .cache_groups = 2 }, .{ .metrics = &registry, .storage = space, .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}) });
    const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
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
    const old = try reader.acquire(section);
    try std.testing.expectEqual(source.destination.load(.acquire), @intFromPtr(old.record.bytes.?.ptr));
    try std.testing.expectEqual(@as(u16, 7), old.get(0));
    const hit = try reader.acquire(section);
    try std.testing.expectEqual(old.record.bytes.?.ptr, hit.record.bytes.?.ptr);
    hit.release();
    try std.testing.expectEqual(@as(usize, 1), source.reads.load(.acquire));
    const second = try reader.acquire(.{ .world = 0, .x = 4, .y = 4, .z = -2 });
    // Holding its whole budget, the reader may take no more.
    try std.testing.expectError(error.CacheBudgetExceeded, reader.acquire(.{ .world = 0, .x = 5, .y = 4, .z = -2 }));
    second.release();
    const third = try reader.acquire(.{ .world = 0, .x = 5, .y = 4, .z = -2 });
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
    const updated = try reader.acquire(section);
    try std.testing.expectEqual(@as(u16, 19), updated.get(0));
    updated.release();
    try terrain.checkpoint(space);
    try store.waitDurable(try store.commit(42));
    try std.testing.expectEqual(@as(u64, 42), store.lastTick());
    try std.testing.expectEqual(@as(u64, 42), store.durableTick());
    const Reader = struct {
        reader: chunks.Chunks.Client,
        section: chunks.Section,
        done: std.Io.Event = .unset,
        result: anyerror!u16 = error.NotRead,
        fn run(self: *@This()) void {
            self.result = self.read();
            self.done.set(std.testing.io);
        }
        fn read(self: *@This()) !u16 {
            const lease = try self.reader.acquire(self.section);
            defer lease.release();
            return lease.get(0);
        }
    };
    source.blocked = 6;
    var miss: Reader = .{ .reader = reader, .section = .{ .world = 0, .x = 6, .y = 4, .z = -2 } };
    const missing_thread = try std.Thread.spawn(.{}, Reader.run, .{&miss});
    defer missing_thread.join();
    defer source.release_read.set(io);
    try source.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
    var cached: Reader = .{ .reader = reader, .section = section };
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
    _ = @import("topology.zig");
    _ = @import("layer.zig");
    _ = @import("copies.zig");
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
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 3 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const reader = try world.client(.{ .name = "test", .sections = @min(192, world.unbudgeted()) });
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    try world.setSections(&.{
        .{ .section = section, .edits = &.{.{ .index = 0, .state = 17 }} },
        .{ .section = section, .edits = &.{.{ .index = 1, .state = 19 }} },
        .{ .section = section, .edits = &.{.{ .index = 0, .state = 23 }} },
    });
    const lease = try reader.acquire(section);
    defer lease.release();
    try std.testing.expectEqual(@as(u16, 23), lease.get(0));
    try std.testing.expectEqual(@as(u16, 19), lease.get(1));
}

test "copies read as the chunks do through edits and replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/chunks", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 1, .cache_sections = 4 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const copies = try chunks.Copies.init(arena.allocator(), world, 2);
    // Sections that exist, so their copies stay across ticks.
    for (0..3) |x| try world.setBlock(0, .{ .x = @as(i32, @intCast(x)) * 16, .y = 0, .z = 0 }, 1);
    try std.testing.expectEqual(@as(u16, 1), try copies.get(0, .{ .x = 0, .y = 0, .z = 0 }));
    try std.testing.expectEqual(@as(u16, 0), try copies.get(0, .{ .x = 1, .y = 0, .z = 0 }));
    // An edit by anyone reaches the copy without decoding it again.
    try world.setBlock(0, .{ .x = 1, .y = 0, .z = 0 }, 5);
    try copies.set(0, .{ .x = 2, .y = 0, .z = 0 }, 6);
    const decoded = copies.decoded;
    try std.testing.expectEqual(@as(u16, 5), try copies.get(0, .{ .x = 1, .y = 0, .z = 0 }));
    try std.testing.expectEqual(@as(u16, 6), try copies.get(0, .{ .x = 2, .y = 0, .z = 0 }));
    copies.endTick();
    try std.testing.expectEqual(@as(u16, 6), try copies.get(0, .{ .x = 2, .y = 0, .z = 0 }));
    try std.testing.expectEqual(decoded, copies.decoded);
    // Two copies held, a third section replaces one, and every read stays true.
    for (0..3) |_| for (0..3) |x| {
        try std.testing.expectEqual(@as(u16, 1), try copies.get(0, .{ .x = @as(i32, @intCast(x)) * 16, .y = 0, .z = 0 }));
    };
    try std.testing.expectEqual(@as(u16, 6), try copies.get(0, .{ .x = 2, .y = 0, .z = 0 }));
}

test "observers chain edits that land before the edit that caused them returns" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/chunks", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    // Each state below 3 placed at a cell places the next state one cell along, as a block
    // reacting in its neighbour update would.
    const Spreader = struct {
        owner: *chunks.Chunks,
        seen: usize = 0,

        fn changed(self: *@This(), _: chunks.Section, edits: []const chunks.BlockEdit, _: []const u16) void {
            for (edits) |edit| {
                self.seen += 1;
                if (edit.state == 0 or edit.state >= 3) continue;
                self.owner.chain(0, .{ .x = edit.index + 1, .y = 0, .z = 0 }, edit.state + 1) catch unreachable;
            }
        }
    };
    var spreader: Spreader = .{ .owner = world };
    try world.observe(chunks.Observer.init(&spreader, Spreader.changed));
    try world.setBlock(0, .{ .x = 0, .y = 0, .z = 0 }, 1);
    // The whole chain applied before setBlock returned, each link announced in turn.
    try std.testing.expectEqual(@as(usize, 3), spreader.seen);
    const reader = try world.client(.{ .name = "test", .sections = 1 });
    for ([_]u16{ 1, 2, 3, 0 }, 0..) |expected, x| try std.testing.expectEqual(expected, try reader.getBlock(0, .{ .x = @intCast(x), .y = 0, .z = 0 }));
}

test "observers receive the state each edited cell held before its batch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/chunks", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const Recorder = struct {
        const Call = struct { section: chunks.Section, count: usize, states: [2000]u16, previous: [2000]u16 };
        calls: []Call,
        count: usize = 0,

        fn changed(self: *@This(), section: chunks.Section, edits: []const chunks.BlockEdit, previous: []const u16) void {
            const call = &self.calls[self.count];
            self.count += 1;
            call.section = section;
            call.count = edits.len;
            for (edits, call.states[0..edits.len]) |edit, *state| state.* = edit.state;
            @memcpy(call.previous[0..previous.len], previous);
        }
    };
    var recorder: Recorder = .{ .calls = try arena.allocator().alloc(Recorder.Call, 6) };
    try world.observe(chunks.Observer.init(&recorder, Recorder.changed));
    const section: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };

    // A cell written twice in one batch reports the state before the batch both times.
    try world.setBlocks(section, &.{ .{ .index = 5, .state = 7 }, .{ .index = 9, .state = 3 }, .{ .index = 5, .state = 8 } });
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0, 0 }, recorder.calls[0].previous[0..recorder.calls[0].count]);
    // A batch that changes nothing is not announced.
    try world.setBlocks(section, &.{.{ .index = 5, .state = 8 }});
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    // Batches for one section apply in order, each seeing the one before it.
    recorder.count = 0;
    try world.setSections(&.{
        .{ .section = section, .edits = &.{.{ .index = 5, .state = 1 }} },
        .{ .section = section, .edits = &.{ .{ .index = 5, .state = 2 }, .{ .index = 9, .state = 4 } } },
    });
    try std.testing.expectEqual(@as(usize, 2), recorder.count);
    try std.testing.expectEqualSlices(u16, &.{8}, recorder.calls[0].previous[0..recorder.calls[0].count]);
    try std.testing.expectEqualSlices(u16, &.{ 1, 3 }, recorder.calls[1].previous[0..recorder.calls[1].count]);

    // Three sections carry more edits than one batch keeps previous states for, so the
    // call splits. Every observer still sees its own section's states.
    var edits: [3][2000]chunks.BlockEdit = undefined;
    var batches: [3]chunks.SectionEdits = undefined;
    for (0..2) |round| {
        for (&edits, &batches, 0..) |*list, *batch, at| {
            for (list, 0..) |*edit, index| edit.* = .{ .index = @intCast(index * 2), .state = @intCast(1000 * (at + 1) + index + round * 7000) };
            batch.* = .{ .section = .{ .world = 0, .x = @intCast(at + 1), .y = 0, .z = 0 }, .edits = list };
        }
        recorder.count = 0;
        try world.setSections(&batches);
        try std.testing.expectEqual(@as(usize, 3), recorder.count);
        for (recorder.calls[0..3], 0..) |call, at| {
            try std.testing.expectEqual(batches[at].section, call.section);
            try std.testing.expectEqual(@as(usize, 2000), call.count);
            for (call.previous[0..call.count], 0..) |previous, index| {
                const expected: u16 = if (round == 0) 0 else @intCast(1000 * (at + 1) + index);
                try std.testing.expectEqual(expected, previous);
            }
        }
    }
    try std.testing.expectError(error.WorkingSetTooLarge, world.setBlocks(section, &(@as([4097]chunks.BlockEdit, @splat(.{ .index = 0, .state = 1 })))));
}

test "palette property projections agree with scalar voxels and reject invalid palette indices" {
    var properties: [4096]u8 = undefined;
    var raw: [encoding.maximum_decoded_bytes]u8 = undefined;
    var encoded: [encoding.maximum_decoded_bytes]u8 = undefined;
    for (0..3) |mode| {
        for (&properties, 0..) |*value, state| value.* = switch (mode) {
            0 => 7,
            1 => @as(u8, 1) << @intCast(state % 2) | 8,
            else => @as(u8, 1) << @intCast(state % 8),
        };
        for ([_]usize{ 1, 2, 3, 4, 7, 16, 31, 255, 256, 511, 1024, 2047 }) |count| {
            for ([_]usize{ 0, encoding.biome_header_bytes }) |offset| {
                @memset(raw[0..offset], 0);
                if (offset != 0) raw[0] = 3;
                raw[offset] = 1;
                var expected: u8 = 255;
                for (0..4096) |index| {
                    const state: u16 = @intCast(index % count);
                    std.mem.writeInt(u16, raw[offset + 1 + index * 2 ..][0..2], state, .little);
                    expected &= properties[state];
                }
                const input = raw[0 .. offset + encoding.dense_block_bytes];
                const representation = try encoding.encode(input, &encoded);
                const borrowed = try encoding.Packed.init(representation);
                for (0..256) |row| {
                    const states = borrowed.row(@intCast(row));
                    for (states, 0..) |state, lane| {
                        const index = row * 16 + lane;
                        const expected_state = std.mem.readInt(u16, raw[offset + 1 + index * 2 ..][0..2], .little);
                        try std.testing.expectEqual(expected_state, state);
                        try std.testing.expectEqual(expected_state, borrowed.get(@intCast(index)));
                    }
                }
                for ([_]u8{ 1, 2, 128 }) |flag| {
                    var selected: [64]u64 = @splat(0);
                    for (0..4096) |index| {
                        const state = std.mem.readInt(u16, raw[offset + 1 + index * 2 ..][0..2], .little);
                        if (properties[state] & flag != 0) selected[index / 64] |= @as(u64, 1) << @intCast(index % 64);
                    }
                    const dense = try encoding.classify(input, &properties, flag);
                    const packed_section = try encoding.classify(representation, &properties, flag);
                    try std.testing.expectEqual(expected, dense.common);
                    try std.testing.expectEqual(expected, packed_section.common);
                    try std.testing.expectEqualSlices(u64, &selected, &dense.selected);
                    try std.testing.expectEqualSlices(u64, &selected, &packed_section.selected);
                }
            }
        }
    }
    var invalid: [3 + 6 + 1024]u8 = @splat(0);
    invalid[0] = 2;
    std.mem.writeInt(u16, invalid[1..3], 3, .little);
    std.mem.writeInt(u16, invalid[5..7], 1, .little);
    std.mem.writeInt(u16, invalid[7..9], 2, .little);
    @memset(&properties, 7);
    try std.testing.expectEqual(@as(u8, 7), (try encoding.classify(&invalid, &properties, 1)).common);
    invalid[9] = 1;
    invalid[9 + 512] = 1;
    try std.testing.expect(encoding.valid(&invalid));
    try std.testing.expectError(error.Corrupt, encoding.classify(&invalid, &properties, 1));
    invalid[9] = 0;
    invalid[9 + 512] = 0;
    properties[1] = 2;
    try std.testing.expectEqual(@as(u8, 2), (try encoding.classify(&invalid, &properties, 1)).common);
    try std.testing.expectError(error.Corrupt, encoding.classify(&.{ 0, 255, 255 }, &properties, 1));
}

test "mixed property requests share one compressed group read without allocating" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/mixed-properties", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{});
    defer registry.deinit();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 8, .cache_groups = 1, .storage_group_side = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
    });
    const sections = [_]chunks.Section{ .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .{ .world = 0, .x = 1, .y = 0, .z = 0 }, .{ .world = 0, .x = 0, .y = 1, .z = 0 } };
    const first = chunks.encodeKey(sections[0]);
    const second = chunks.encodeKey(sections[1]);
    var dense: [encoding.dense_block_bytes]u8 = undefined;
    dense[0] = 1;
    for (0..4096) |index| std.mem.writeInt(u16, dense[1 + index * 2 ..][0..2], if (index == 4095) 99 else 7, .little);
    try terrain.cache.backend.store.putBatch(&.{ .{ .key = &first, .value = &.{ 0, 7, 0 } }, .{ .key = &second, .value = &dense } });
    try terrain.cache.backend.store.flush();
    terrain.cache.backend.store.bases.invalidate(&first);
    terrain.attach();
    defer terrain.stop();
    bounded.fail_index = bounded.alloc_index;
    bounded.resize_fail_index = bounded.resize_index;
    var properties: [256]u8 = @splat(1);
    properties[99] = 2;
    var results: [5]encoding.Classification = undefined;
    const requests = [_]chunks.Chunks.ClassificationRequest{
        .{ .section = sections[0], .result = &results[0] },
        .{ .section = sections[1], .result = &results[1] },
        .{ .section = sections[1], .result = &results[2] },
        .{ .section = sections[2], .result = &results[3] },
        .{ .section = sections[0], .result = &results[4] },
    };
    const reads = terrain.cache.backend.store.bases.metrics.reads.value();
    try terrain.classify(&requests, &properties, 1);
    try std.testing.expectEqual(reads + 1, terrain.cache.backend.store.bases.metrics.reads.value());
    try std.testing.expectEqual(@as(u8, 1), results[0].known.common);
    try std.testing.expectEqualDeep(results[1], results[2]);
    try std.testing.expect(results[3] == .unavailable);
    try std.testing.expectEqual(@as(u8, 0), results[2].known.common);
    try std.testing.expectEqual(std.math.maxInt(u64) >> 1, results[2].known.selected[63]);
    try std.testing.expectEqualDeep(results[0], results[4]);
    try std.testing.expectEqual(@as(usize, 0), terrain.cache.lookup.count());
    try std.testing.expectEqual(@as(usize, 0), terrain.generation.queued_count);
    try std.testing.expect(!bounded.has_induced_failure);
}

test "property reads preserve pending edits without generating or admitting decoded sections" {
    const Generator = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(19, request.output);
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/properties", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = bounded.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    const space = try store.openSpace(chunks.Chunks.id);
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 8, .storage_group_side = 2 }, .{
        .metrics = &registry,
        .storage = space,
        .record_workspaces = try records.Workspaces.init(allocator, io, .{}),
    });
    const sections = [_]chunks.Section{ .{ .world = 0, .x = 0, .y = 0, .z = 0 }, .{ .world = 0, .x = 1, .y = 0, .z = 0 } };
    const watch = try chunks.Watch.init(allocator, terrain, 2);
    const region: chunks.Watch.Region = .{ .world = 0, .minimum = .{ .x = 0, .y = 0, .z = 0 }, .maximum = .{ .x = 1, .y = 0, .z = 0 } };
    var revisions: [2]u64 = undefined;
    watch.configure(region, &revisions);
    const key = chunks.encodeKey(sections[0]);
    var properties: [256]u8 = @splat(1);
    properties[99] = 2;
    _ = try terrain.registerClassification(allocator, &properties, 1, null);
    try terrain.cache.backend.store.putBatch(&.{.{ .key = &key, .value = &.{ 0, 7, 0 } }});
    try terrain.cache.backend.store.flush();
    var generator: Generator = .{};
    terrain.setSource(chunks.Source.init(&generator, Generator.read));
    terrain.attach();
    defer terrain.stop();
    bounded.fail_index = bounded.alloc_index;
    var values: [2]encoding.Classification = undefined;
    const columns = [_]chunks.classification.Column{
        .{ .world = 0, .x = 0, .z = 0, .minimum = 0, .count = 1 },
        .{ .world = 0, .x = 1, .z = 0, .minimum = 0, .count = 1 },
    };
    var summaries: [columns.len]chunks.classification.ColumnSummary = undefined;
    try terrain.summarize(&columns, &summaries, &properties, 1);
    try std.testing.expectEqual(@as(u32, 1), summaries[0].known);
    try std.testing.expectEqual(@as(u8, 1), summaries[0].common[0]);
    try std.testing.expectEqual(@as(u32, 0), summaries[1].known);
    const requests = [_]chunks.Chunks.ClassificationRequest{
        .{ .section = sections[0], .result = &values[0] },
        .{ .section = sections[1], .result = &values[1] },
    };
    try terrain.classify(&requests, &properties, 1);
    try std.testing.expectEqual(@as(u8, 1), values[0].known.common);
    for (values[0].known.selected) |word| try std.testing.expectEqual(std.math.maxInt(u64), word);
    try std.testing.expect(values[1] == .unavailable);
    try std.testing.expectEqual(@as(usize, 0), terrain.cache.lookup.count());
    try std.testing.expectEqual(@as(usize, 0), terrain.generation.queued_count);
    const group = terrain.storageGroup(.{ .world = 3, .x = -1, .y = -3, .z = 4 });
    try std.testing.expectEqual(@as(u8, 2), group.side);
    try std.testing.expectEqual(chunks.Section{ .world = 3, .x = -2, .y = -4, .z = 4 }, group.minimum);
    try terrain.setBlock(0, .{ .x = 0, .y = 0, .z = 0 }, 99);
    try std.testing.expect(!watch.unchanged());
    watch.configure(region, &revisions);
    try std.testing.expect(watch.unchanged());
    try terrain.classify(&requests, &properties, 1);
    try std.testing.expectEqual(@as(u8, 0), values[0].known.common);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, values[0].known.selected[0]);
    try std.testing.expect(values[1] == .unavailable);
    try terrain.summarize(&columns, &summaries, &properties, 1);
    try std.testing.expectEqual(@as(u32, 1), summaries[0].known);
    try std.testing.expectEqual(@as(u8, 0), summaries[0].common[0]);
    try std.testing.expectEqual(@as(u32, 0), summaries[0].prefixed);
    try std.testing.expectEqual(@as(u32, 0), summaries[1].known);
    try terrain.checkpoint(space);
    terrain.cache.invalidate(&key);
    try terrain.classify(&requests, &properties, 1);
    try std.testing.expectEqual(@as(u8, 0), values[0].known.common);
    try std.testing.expectEqual(std.math.maxInt(u64) - 1, values[0].known.selected[0]);
    try std.testing.expect(values[1] == .unavailable);
    try terrain.summarize(&columns, &summaries, &properties, 1);
    try std.testing.expectEqual(@as(u32, 1), summaries[0].known);
    try std.testing.expectEqual(@as(u8, 0), summaries[0].common[0]);
    try std.testing.expectEqual(@as(u32, 0), summaries[1].known);
    try std.testing.expectEqual(@as(usize, 0), terrain.cache.backend.store.readers);
    try std.testing.expectEqual(@as(usize, 0), terrain.generation.queued_count);
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try std.testing.expect(!bounded.has_induced_failure);
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
    const world = try chunks.Chunks.init(arena.allocator(), io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 5 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(arena.allocator(), io, .{}),
    });
    const background = try world.client(.{ .name = "background", .sections = 3 });
    const demand = try world.client(.{ .name = "demand", .sections = 1 });
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
    try background.prepareMany(&requests, &complete);
    try std.testing.expect(world.ready().isSet());
    try std.testing.expectEqualSlices(bool, &.{ false, true }, &complete);
    try std.testing.expectEqual(@as(usize, 0), generator.sections);
    world.releaseMany(prepared[1..2]);
    try std.testing.expect(try world.generation.processOne(io));
    try background.prepareMany(&requests, &complete);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, &complete);
    try std.testing.expectEqual(@as(usize, 1), generator.sections);
    world.ready().reset();
    world.releaseMany(prepared[0..2]);
    try std.testing.expect(!world.ready().isSet());
    {
        const lease = try demand.acquire(missing);
        defer lease.release();
        try std.testing.expectEqual(@as(u16, 19), lease.get(0));
    }
    const prefetched = [_]chunks.Section{
        .{ .world = 0, .x = 2, .y = 0, .z = 0 },
        .{ .world = 0, .x = 3, .y = 0, .z = 0 },
        .{ .world = 0, .x = 4, .y = 0, .z = 0 },
    };
    var ready: [1]bool = undefined;
    for (0..2) |_| try background.prepareMany(&.{.{ .sections = &prefetched, .leases = &prepared, .priority = .{} }}, &ready);
    try std.testing.expectEqual(@as(usize, 3), world.generating_count);
    // Its three sections being generated take the whole background budget, so a fourth waits.
    try background.prepareMany(&.{.{ .sections = &.{.{ .world = 0, .x = 5, .y = 0, .z = 0 }}, .leases = prepared[0..1], .priority = .{} }}, &ready);
    try std.testing.expect(!ready[0]);
    try std.testing.expectEqual(@as(usize, 3), world.generating_count);
    {
        const demanded = try demand.acquire(.{ .world = 0, .x = 6, .y = 0, .z = 0 });
        defer demanded.release();
        try std.testing.expectEqual(@as(u16, 19), demanded.get(0));
        try std.testing.expectEqual(@as(usize, 3), world.generating_count);
        try std.testing.expectEqual(@as(usize, 2), generator.sections);
    }
    world.generation.update(0, null);
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
        const terrain = try chunks.Chunks.init(arena.allocator(), std.testing.io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 193, .cache_groups = 8 }, .{
            .storage = space,
            .metrics = &registry,
            .record_workspaces = try records.Workspaces.init(arena.allocator(), std.testing.io, .{}),
        });
        const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        var sections: [193]chunks.Section = undefined;
        var leases: [193]chunks.Lease = undefined;
        for (&sections, 0..) |*section, index| section.* = .{ .world = 0, .x = @intCast(index / 24), .y = @intCast(index % 24), .z = 0 };
        // More dirty sections than one batch writes, leased in two batches as no budget holds them all.
        for ([_][2]usize{ .{ 0, 192 }, .{ 192, 193 } }) |range| {
            try reader.acquireMany(sections[range[0]..range[1]], leases[range[0]..range[1]]);
            terrain.releaseMany(leases[range[0]..range[1]]);
        }
        if (fail) {
            terrain.cache.backend.store.bases.failed = true;
            try std.testing.expectError(error.FailedTransaction, terrain.checkpoint(space));
        } else {
            try terrain.checkpoint(space);
            try std.testing.expectEqual(@as(u64, sections.len), terrain.cache.metrics.writes.value());
            try terrain.setBlock(0, .{ .x = 0, .y = 0, .z = 0 }, 3);
            try terrain.checkpoint(space);
            try std.testing.expectEqual(@as(u64, sections.len + 1), terrain.cache.metrics.writes.value());
            try std.testing.expectEqual(@as(u16, 3), try reader.getBlock(0, .{ .x = 0, .y = 0, .z = 0 }));
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
    var output = std.Io.File.stdout().writerStreaming(std.testing.io, &output_buffer);
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
        const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 192, .cache_groups = 32 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("chunks"),
            .record_workspaces = try records.Workspaces.init(allocator, std.testing.io, .{}),
        });
        const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
        var source: Source = .{};
        terrain.setSource(chunks.Source.init(&source, Source.read));
        terrain.attach();
        defer terrain.stop();
        const prefetch: chunks.Section = .{ .world = 0, .x = 100, .y = 4, .z = 0 };
        var prepared: [1]chunks.Lease = undefined;
        var complete: [1]bool = undefined;
        try reader.prepareMany(&.{.{ .sections = &.{prefetch}, .leases = &prepared, .priority = .{ .player = 1 } }}, &complete);
        try std.testing.expect(!complete[0]);
        var sections: [96]chunks.Section = undefined;
        var leases: [96]chunks.Lease = undefined;
        for (sections[0..count], 0..) |*section, index| section.* = .{
            .world = 0,
            .x = @intCast(index / 24),
            .y = @as(i32, @intCast(index % 24)) - 4,
            .z = 0,
        };
        try reader.acquireMany(sections[0..count], leases[0..count]);
        for (leases[0..count]) |lease| try std.testing.expectEqual(@as(u16, 7), lease.get(0));
        terrain.releaseMany(leases[0..count]);
        try std.testing.expectEqual(count, source.sections);
        try std.testing.expectEqual((count + chunks.Source.batch_max - 1) / chunks.Source.batch_max, source.calls);
        try std.testing.expectEqual(chunks.Source.batch_max, source.maximum);
        try std.testing.expect(terrain.generation.index.contains(prefetch));
        try std.testing.expectEqual(@as(usize, 1), terrain.generation.queued_count);
        try output.interface.print("{d:17} | {d:12} | {d:20} | {d}\n", .{ count, source.calls, source.maximum, terrain.generation.queued_count });
        terrain.generation.update(1, null);
        try terrain.poll();
    }
    try output.interface.flush();
}

test "read windows release optional leases to fit their budget and ignore other clients" {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(@intCast(request.section.x + 7), request.output);
        }
    };
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
    const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 5, .cache_groups = 2 }, .{
        .metrics = &registry,
        .storage = try store.openSpace(chunks.Chunks.id),
        .record_workspaces = try records.Workspaces.init(allocator, std.testing.io, .{}),
    });
    const windowed = try terrain.client(.{ .name = "window", .sections = 2 });
    const other = try terrain.client(.{ .name = "other", .sections = 2 });
    var source: Source = .{};
    terrain.setSource(chunks.Source.init(&source, Source.read));
    failing.fail_index = failing.alloc_index;
    const a: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const b: chunks.Section = .{ .world = 0, .x = 1, .y = 0, .z = 0 };
    const c: chunks.Section = .{ .world = 0, .x = 2, .y = 0, .z = 0 };
    const d: chunks.Section = .{ .world = 0, .x = 3, .y = 0, .z = 0 };
    const e: chunks.Section = .{ .world = 0, .x = 4, .y = 0, .z = 0 };
    // The window may retain more than its budget holds, and holds no more than the budget.
    var window = chunks.ReadWindow(4).init(windowed);
    defer window.deinit();
    var views: [2]chunks.View = undefined;
    try window.readMany(&.{ a, b }, &views);
    const before = terrain.cache.metrics.acquired.value();
    try window.readMany(&.{b}, views[0..1]);
    try window.readMany(&.{ a, b }, &views);
    try std.testing.expectEqual(before, terrain.cache.metrics.acquired.value());
    try std.testing.expectEqual(@as(usize, 2), window.count);

    // Another client holding the rest of the cache takes nothing from the window.
    var external: [2]chunks.Lease = undefined;
    try other.acquireMany(&.{ c, d }, &external);
    const after = terrain.cache.metrics.acquired.value();
    try window.readMany(&.{ a, b }, &views);
    try std.testing.expectEqual(after, terrain.cache.metrics.acquired.value());
    try std.testing.expectEqual(@as(usize, 4), terrain.borrowed_count);

    // A new section displaces a retained one to fit the budget, and the required view stays.
    try window.readMany(&.{ a, e }, &views);
    try std.testing.expectEqual(@as(u16, 7), views[0].get(0));
    try std.testing.expectEqual(@as(u16, 11), views[1].get(0));
    try std.testing.expectEqual(@as(usize, 2), window.count);
    try std.testing.expectEqual(@as(usize, 4), terrain.borrowed_count);
    var three: [3]chunks.View = undefined;
    try std.testing.expectError(error.WorkingSetTooLarge, window.readMany(&.{ a, b, e }, &three));
    terrain.releaseMany(&external);
    window.deinit();
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
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
            var decoded: [encoding.dense_block_bytes]u8 = undefined;
            try std.testing.expectEqual(decoded.len, try encoding.decodeTo(&encoded, &decoded));
            try std.testing.expectEqual(@as(u8, 1), decoded[0]);
            for (0..encoding.blocks) |index| {
                const selected = pattern >> @intCast(index % 8) & 1;
                try std.testing.expectEqual(palette[selected], std.mem.readInt(u16, decoded[1 + index * 2 ..][0..2], .little));
            }
            var inplace: [encoding.dense_block_bytes]u8 = undefined;
            @memcpy(inplace[0..encoded.len], &encoded);
            try std.testing.expectEqual(inplace.len, try encoding.decode(&inplace, encoded.len));
            try std.testing.expectEqualSlices(u8, &decoded, &inplace);
        }
    }
    var output: [encoding.dense_block_bytes]u8 = undefined;
    try std.testing.expectError(error.Corrupt, encoding.decodeTo(encoded[0 .. encoded.len - 1], &output));
    try std.testing.expectError(error.BufferTooSmall, encoding.decodeTo(&encoded, output[0 .. output.len - 1]));
}

test "snapshot watches invalidate only intersecting worlds and section bounds" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/watches", .{directory.sub_path});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    const allocator = arena.allocator();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
    const watch = try chunks.Watch.init(allocator, terrain, 2);
    const other = try chunks.Watch.init(allocator, terrain, 2);
    const invalidation = try chunks.Watch.initInvalidation(allocator, terrain);
    const first: chunks.Watch.Region = .{ .world = 0, .minimum = .{ .x = -1, .y = 4, .z = 0 }, .maximum = .{ .x = -1, .y = 5, .z = 0 } };
    const second: chunks.Watch.Region = .{ .world = 1, .minimum = .{ .x = -1, .y = 4, .z = 0 }, .maximum = .{ .x = -1, .y = 5, .z = 0 } };
    var previous: [2]u64 = undefined;
    watch.configure(first, &previous);
    invalidation.observe(first);
    other.configure(second, &previous);
    try std.testing.expectEqual([2]u64{ 0, 0 }, previous);
    try terrain.setBlock(0, .{ .x = 0, .y = 64, .z = 0 }, 1);
    try terrain.setBlock(0, .{ .x = -1, .y = 96, .z = 0 }, 1);
    try std.testing.expectEqual(@as(u64, 0), watch.revision(0));
    try std.testing.expect(invalidation.unchanged());
    try terrain.setBlock(0, .{ .x = -1, .y = 64, .z = 0 }, 1);
    try std.testing.expect(!invalidation.unchanged());
    invalidation.observe(second);
    try std.testing.expect(invalidation.unchanged());
    try std.testing.expectEqual(@as(u64, 1), watch.revision(0));
    try terrain.setBlock(0, .{ .x = -1, .y = 64, .z = 0 }, 1);
    try std.testing.expectEqual(@as(u64, 1), watch.revision(0));
    try std.testing.expectEqual(@as(u64, 0), other.revision(0));
    try terrain.setBlock(1, .{ .x = -1, .y = 95, .z = 0 }, 1);
    try std.testing.expect(!invalidation.unchanged());
    try std.testing.expectEqual(@as(u64, 1), other.revision(1));
    watch.configure(second, &previous);
    try std.testing.expectEqual([2]u64{ 1, 0 }, previous);
    other.configure(first, &previous);
    try std.testing.expectEqual([2]u64{ 0, 1 }, previous);
    try std.testing.expectEqual(@as(u64, 0), watch.revision(0));
    try terrain.setBlock(0, .{ .x = -1, .y = 64, .z = 0 }, 0);
    try std.testing.expectEqual(@as(u64, 0), watch.revision(0));
    try std.testing.expectEqual(@as(u64, 1), other.revision(0));
    const captured = try chunks.Watch.init(allocator, terrain, 2);
    try std.testing.expect(!captured.capture(other, &.{ 0, 0 }));
    try std.testing.expect(captured.capture(other, &.{ 1, 0 }));
    try std.testing.expect(captured.unchanged());
    try terrain.setBlock(0, .{ .x = -1, .y = 80, .z = 0 }, 1);
    try std.testing.expect(!captured.unchanged());
    try std.testing.expect(!captured.capture(other, &.{ 1, 0 }));
    try std.testing.expect(captured.capture(other, &.{ 1, 1 }));
    try std.testing.expect(captured.unchanged());
}

test "unaligned biome views detect uniform little endian values without changing scalar reads" {
    var bytes: [129]u8 = undefined;
    const view: chunks.BiomeView = .{ .bytes = bytes[1..129] };
    for ([_]u16{ 0, 1, 255, 256, 65535 }) |value| {
        for (0..64) |cell| std.mem.writeInt(u16, bytes[1 + cell * 2 ..][0..2], value, .little);
        try std.testing.expectEqual(@as(?u16, value), view.uniform());
        for (0..64) |cell| {
            bytes[1 + cell * 2] ^= 1;
            try std.testing.expect(view.uniform() == null);
            for (0..64) |index| try std.testing.expectEqual(if (index == cell) value ^ 1 else value, view.get(@intCast(index)));
            bytes[1 + cell * 2] ^= 1;
        }
    }
}

test {
    _ = chunks.Delivery;
    _ = chunks.Light;
}

test "cached leases and the unsaved snapshot never read storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cached", .{temporary.sub_path});
    var database = try storage.Store.init(allocator, io, .{ .path = path, .io_mode = .standard });
    defer database.deinit();
    var registry = try metrics.Registry.init(allocator, io, .{});
    const terrain = try chunks.Chunks.init(allocator, io, .{ .edit_sections = 1, .simulation_sections = 0, .cache_sections = 8 }, .{ .metrics = &registry, .storage = try database.openSpace(chunks.Chunks.id), .record_workspaces = try records.Workspaces.init(allocator, io, .{}) });
    const reader = try terrain.client(.{ .name = "test", .sections = @min(192, terrain.unbudgeted()) });
    const here: chunks.Section = .{ .world = 0, .x = 0, .y = 0, .z = 0 };
    const far: chunks.Section = .{ .world = 0, .x = 9, .y = 0, .z = 0 };
    var leases: [2]chunks.Lease = undefined;
    // Nothing is in memory, so nothing is leased and nothing is read.
    try std.testing.expect(!reader.acquireCached(&.{ here, far }, &leases));
    try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
    try terrain.setBlock(0, .{ .x = 1, .y = 2, .z = 3 }, 5);
    try std.testing.expect(reader.acquireCached(&.{here}, leases[0..1]));
    try std.testing.expectEqual(@as(u16, 5), leases[0].view().get(chunks.localIndex(.{ .x = 1, .y = 2, .z = 3 })));
    terrain.releaseMany(leases[0..1]);
    try std.testing.expect(!reader.acquireCached(&.{ here, far }, &leases));

    // The edit is in memory only, dated by its batch.
    var unsaved: [4]chunks.Chunks.Unsaved = undefined;
    const first = terrain.unsavedAround(.{ .world = 0, .x = 1, .z = 1 }, 0, 1, &unsaved).?;
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(here, unsaved[0].section);
    try std.testing.expectEqual(first.stamp, unsaved[0].since);
    // A column whose neighbourhood does not reach the edit sees nothing.
    try std.testing.expectEqual(@as(usize, 0), terrain.unsavedAround(.{ .world = 0, .x = 2, .z = 0 }, 0, 1, &unsaved).?.count);
    // A later edit of the same dirty section keeps the date of the first.
    try terrain.setBlock(0, .{ .x = 2, .y = 2, .z = 3 }, 6);
    const second = terrain.unsavedAround(.{ .world = 0, .x = 0, .z = 0 }, 0, 1, &unsaved).?;
    try std.testing.expect(second.stamp > first.stamp);
    try std.testing.expectEqual(first.stamp, unsaved[0].since);
    // Saving it leaves nothing unsaved and moves the write mark.
    try terrain.checkpoint(try database.openSpace(chunks.Chunks.id));
    const saved = terrain.unsavedAround(.{ .world = 0, .x = 0, .z = 0 }, 0, 1, &unsaved).?;
    try std.testing.expectEqual(@as(usize, 0), saved.count);
    try std.testing.expect(saved.write_mark != second.write_mark);
    // Dirty again, it is dated by the edit that made it so.
    try terrain.setBlock(0, .{ .x = 1, .y = 2, .z = 3 }, 7);
    const again = terrain.unsavedAround(.{ .world = 0, .x = 0, .z = 0 }, 0, 1, &unsaved).?;
    try std.testing.expectEqual(again.stamp, unsaved[0].since);
    try std.testing.expect(again.stamp > second.stamp);
    // More dirty sections than the caller has room for is no answer at all.
    try terrain.setBlock(0, .{ .x = 17, .y = 2, .z = 3 }, 7);
    try std.testing.expectEqual(@as(?chunks.Chunks.UnsavedSnapshot, null), terrain.unsavedAround(.{ .world = 0, .x = 0, .z = 0 }, 0, 1, unsaved[0..1]));
}
