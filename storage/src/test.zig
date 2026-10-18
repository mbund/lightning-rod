const std = @import("std");
const storage = @import("storage");
const fault = @import("fault_disk.zig");
const testing = @import("testing.zig");

test "ranged reads validate the entire page before copying into caller buffers" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/ranges", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .submission = .standard });
    defer store.deinit();
    const space = try store.openSpace("ranges");
    var ids: [1]storage.PageId = undefined;
    try space.allocatePages(&ids);
    var page: storage.Page = undefined;
    for (&page, 0..) |*byte, i| byte.* = @truncate(i * 17);
    try space.writePages(&.{.{ .id = ids[0], .source = &page }});
    try store.waitDurable(try store.commit(1));
    var output: [17]u8 = @splat(255);
    for ([_]u16{ 0, 63, storage.page_size - output.len }) |offset| {
        try space.readPages(&.{.{ .id = ids[0], .destination = output[1..16], .offset = offset }});
        try std.testing.expectEqualSlices(u8, page[offset..][0..15], output[1..16]);
        try std.testing.expectEqual(@as(u8, 255), output[0]);
        try std.testing.expectEqual(@as(u8, 255), output[16]);
    }
    try space.readPages(&.{.{ .id = ids[0], .destination = &.{}, .offset = storage.page_size }});
    @memset(store.cache, .{});
    const location = store.locations.get(@intFromEnum(ids[0])).?;
    try store.wal.writePositionalAll(io, &.{page[2000] ^ 255}, location.current + 32 + 32 + 2000);
    try std.testing.expectError(error.Corrupt, space.readPages(&.{.{ .id = ids[0], .destination = output[1..16] }}));
    try std.testing.expectEqual(@as(u8, 255), output[0]);
}

test "uncommitted page rewrites reuse WAL frames without touching committed data" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var space = try store.openSpace("test");
    var ids: [3]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const frame_bytes = storage.page_size + 64;
    for (0..8) |version| {
        var data: [ids.len]storage.Page = undefined;
        var writes: [ids.len]storage.Write = undefined;
        for (&data, &writes, 0..) |*page, *write, index| {
            @memset(page, @intCast(version * ids.len + index));
            write.* = .{ .id = ids[index], .source = page };
        }
        try space.writePages(&.{ .{ .id = ids[0], .source = &data[1] }, writes[0], writes[2], .{ .id = ids[1], .source = &data[2] }, writes[1] });
        try std.testing.expectEqual(@as(u64, 64 + ids.len * frame_bytes), (try store.wal.stat(io)).size);
    }
    try space.setRoot(ids[0]);
    try store.waitDurable(try store.commit(1));
    const committed_end = (try store.wal.stat(io)).size;
    try std.testing.expectEqual(@as(u64, 64 + (ids.len + 1) * frame_bytes), committed_end);
    const prefix = try std.testing.allocator.alloc(u8, @intCast(committed_end));
    defer std.testing.allocator.free(prefix);
    try std.testing.expectEqual(prefix.len, try store.wal.readPositionalAll(io, prefix, 0));
    const changed: storage.Page = @splat(99);
    for (0..4) |_| try space.writePages(&.{.{ .id = ids[0], .source = &changed }});
    try std.testing.expectEqual(committed_end + frame_bytes, (try store.wal.stat(io)).size);
    const actual = try std.testing.allocator.alloc(u8, prefix.len);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqual(actual.len, try store.wal.readPositionalAll(io, actual, 0));
    try std.testing.expectEqualSlices(u8, prefix, actual);
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    space = try store.openSpace("test");
    var page: storage.Page = undefined;
    for (ids, 0..) |id, index| {
        try space.readPages(&.{.{ .id = id, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(7 * ids.len + index)), byte);
    }
    try std.testing.expectEqual(@as(u64, 1), store.lastTick());
    try std.testing.expectEqual(committed_end, (try store.wal.stat(io)).size);
}

test "WAL page transactions recover complete saves" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try directory.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const filename = try std.fs.path.join(std.testing.allocator, &.{ path, "world" });
    defer std.testing.allocator.free(filename);
    const options: storage.Store.Options = .{ .path = filename, .submission = .standard, .maximum_wal_pages = 1024 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var ids: [2]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const data: storage.Page = @splat(42);
        try space.writePages(&.{.{ .id = ids[0], .source = &data }});
        try space.setRoot(ids[0]);
        const commit = try store.commit(9);
        try store.waitDurable(commit);
        const partial: storage.Page = @splat(17);
        try space.writePages(&.{.{ .id = ids[0], .source = &partial }});
    }
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 9), store.lastTick());
        const space = try store.openSpace("test");
        var data: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &data }});
        try std.testing.expectEqual(@as(u8, 42), data[0]);
    }
}

test "WAL recovery rejects damaged frames and invalid embedded block headers" {
    const io = std.testing.io;
    const frame_size = storage.page_size + 64;
    for ([_]enum { payload, header }{ .payload, .header }) |damage| {
        var temporary = try testing.directory(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
        defer std.testing.allocator.free(path);
        const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
        var committed_end: u64 = undefined;
        var previous_hash: u64 = undefined;
        {
            var store = try storage.Store.init(std.testing.allocator, io, options);
            defer store.deinit();
            const space = try store.openSpace("test");
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const original: storage.Page = @splat(1);
            try space.writePages(&.{.{ .id = ids[0], .source = &original }});
            try space.setRoot(ids[0]);
            try store.waitDurable(try store.commit(1));
            committed_end = (try store.wal.stat(io)).size;
            previous_hash = store.commit_hash;
            const changed: storage.Page = @splat(2);
            try space.writePages(&.{.{ .id = ids[0], .source = &changed }});
            _ = try store.commit(2);
            try std.testing.expectEqual(committed_end + 2 * frame_size, (try store.wal.stat(io)).size);
            var frames: [2][frame_size]u8 = undefined;
            try std.testing.expectEqual(@sizeOf(@TypeOf(frames)), try store.wal.readPositionalAll(io, std.mem.asBytes(&frames), committed_end));
            switch (damage) {
                .payload => frames[0][64] ^= 255,
                .header => {
                    frames[0][32] ^= 255;
                    // Keep both outer checksums valid to exercise the embedded header check.
                    @memset(frames[0][16..24], 0);
                    std.mem.writeInt(u64, frames[0][16..24], std.hash.XxHash64.hash(0x4c52504147455231, &frames[0]), .little);
                    var digest = std.hash.XxHash64.init(0x4c52504147455231);
                    var previous: [8]u8 = undefined;
                    std.mem.writeInt(u64, &previous, previous_hash, .little);
                    digest.update(&previous);
                    digest.update(frames[0][16..24]);
                    std.mem.writeInt(u64, frames[1][24..32], digest.final(), .little);
                    @memset(frames[1][16..24], 0);
                    std.mem.writeInt(u64, frames[1][16..24], std.hash.XxHash64.hash(0x4c52504147455231, &frames[1]), .little);
                },
            }
            try store.wal.writePositionalAll(io, std.mem.asBytes(&frames), committed_end);
        }
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        try std.testing.expectEqual(committed_end, (try store.wal.stat(io)).size);
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        const expected: storage.Page = @splat(1);
        try std.testing.expectEqualSlices(u8, &expected, &page);
    }
}

test "transaction checksum rejects a complete stale frame from an earlier write" {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 128 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var ids: [2]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const original: storage.Page = @splat(1);
        try space.writePages(&.{ .{ .id = ids[0], .source = &original }, .{ .id = ids[1], .source = &original } });
        try space.setRoot(ids[0]);
        try store.waitDurable(try store.commit(1));
        const offset = store.end;
        const transient: storage.Page = @splat(2);
        try space.writePages(&.{ .{ .id = ids[0], .source = &transient }, .{ .id = ids[1], .source = &transient } });
        var stale: [storage.page_size + 64]u8 = undefined;
        try std.testing.expectEqual(stale.len, try store.wal.readPositionalAll(io, &stale, offset));
        const final: storage.Page = @splat(3);
        try space.writePages(&.{ .{ .id = ids[0], .source = &final }, .{ .id = ids[1], .source = &final } });
        _ = try store.commit(2);
        try store.wal.writePositionalAll(io, &stale, offset);
    }
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 1), store.lastTick());
    const space = try store.openSpace("test");
    const root = (try space.getRoot()).?;
    var pages: [2]storage.Page = undefined;
    try space.readPages(&.{ .{ .id = root, .destination = &pages[0] }, .{ .id = @enumFromInt(@intFromEnum(root) + 1), .destination = &pages[1] } });
    const expected: storage.Page = @splat(1);
    for (&pages) |*page| try std.testing.expectEqualSlices(u8, &expected, page);
}

test "empty transactions bind each commit to the preceding committed prefix" {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 128 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        for (1..5) |tick| try store.waitDurable(try store.commit(tick));
    }
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 4), store.lastTick());
    try store.waitDurable(try store.commit(5));
}

test "page reuse and roots roll back together after an incomplete save" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
    var root: storage.PageId = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const a = try store.openSpace("a");
        var ids: [1]storage.PageId = undefined;
        try a.allocatePages(&ids);
        root = ids[0];
        const page: storage.Page = @splat(91);
        try a.writePages(&.{.{ .id = root, .source = &page }});
        try a.setRoot(root);
        try store.waitDurable(try store.commit(1));
        try a.setRoot(null);
        try a.freePages(&ids);
        const b = try store.openSpace("b");
        try b.allocatePages(&ids);
        try std.testing.expectEqual(root, ids[0]);
        const changed: storage.Page = @splat(18);
        try b.writePages(&.{.{ .id = ids[0], .source = &changed }});
        try b.setRoot(ids[0]);
    }
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const a = try store.openSpace("a");
        try std.testing.expectEqual(root, (try a.getRoot()).?);
        var page: storage.Page = undefined;
        try a.readPages(&.{.{ .id = root, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 91), byte);
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        try std.testing.expectEqual(null, try (try store.openSpace("b")).getRoot());
    }
}

test "WAL checkpointing survives interleaved commits and recycles only durable pages" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
    for (0..3) |round| {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        if (round == 0) {
            var ids: [8]storage.PageId = undefined;
            try space.allocatePages(&ids);
            for (ids, 0..) |id, index| {
                const page: storage.Page = @splat(@intCast(index));
                try space.writePages(&.{.{ .id = id, .source = &page }});
            }
            try space.setRoot(ids[0]);
            try store.waitDurable(try store.commit(1));
        }
        const root = (try space.getRoot()).?;
        var actual: storage.Page = undefined;
        try space.readPages(&.{.{ .id = root, .destination = &actual }});
        try std.testing.expectEqual(@as(u8, if (round == 0) 0 else 42), actual[0]);
        for (0..3) |_| _ = try store.maintain(1);
        const changed: storage.Page = @splat(42);
        try space.writePages(&.{.{ .id = root, .source = &changed }});
        try store.waitDurable(try store.commit(round + 2));
        if (round == 0) continue;
        var steps: usize = 0;
        while (store.end != 64 or store.phase != .idle) : (steps += 1) {
            if (steps == 100) return error.MaintenanceDidNotFinish;
            _ = try store.maintain(2);
        }
        try space.readPages(&.{.{ .id = root, .destination = &actual }});
        for (actual) |byte| try std.testing.expectEqual(@as(u8, 42), byte);
    }
}

fn scenario(store: *storage.Store, acknowledged: *u64) !void {
    const a = try store.openSpace("a");
    const b = try store.openSpace("b");
    var ids: [2]storage.PageId = undefined;
    const spaces: [2]storage.Space = .{ a, b };
    for (spaces) |space| {
        const old = (try space.getRoot()).?;
        try space.setRoot(null);
        try space.freePages(&.{old});
        try space.allocatePages(&ids);
        const page: storage.Page = @splat(2);
        const transient: storage.Page = @splat(77);
        try space.writePages(&.{ .{ .id = ids[0], .source = &transient }, .{ .id = ids[1], .source = &transient } });
        try space.writePages(&.{ .{ .id = ids[0], .source = &page }, .{ .id = ids[1], .source = &page } });
        try space.setRoot(ids[0]);
    }
    try store.waitDurable(try store.commit(2));
    acknowledged.* = 2;
    _ = try store.maintain(1);
    while (store.phase == .copying) _ = try store.maintain(1);
    for (spaces) |space| {
        const page: storage.Page = @splat(3);
        const transient: storage.Page = @splat(99);
        try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &transient }});
        try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
    }
    _ = try store.commit(3);
}

test "power loss at every write and sync preserves a complete durable save" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        for ([_][]const u8{ "a", "b" }) |name| {
            const space = try store.openSpace(name);
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const page: storage.Page = @splat(1);
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
        }
        try store.waitDurable(try store.commit(1));
    }
    var total_events: usize = 0;
    for ([_]bool{ false, true }) |short| {
        var events: usize = 0;
        {
            var owner = try storage.Store.init(std.testing.allocator, io, options);
            var disk = try fault.Disk.init(std.testing.allocator, io, &.{ owner.database, owner.wal }, std.math.maxInt(usize), short);
            defer disk.deinit();
            const modeled = disk.interface();
            owner.io = modeled;
            owner.filesystem.io = modeled;
            owner.checkpoint_io.io = modeled;
            var acknowledged: u64 = 1;
            try scenario(&owner, &acknowledged);
            events = disk.events;
            owner.deinit();
            disk.detach();
        }
        var cut: usize = 1;
        while (cut <= events) : (cut += 1) {
            for (std.enums.values(fault.Disk.Mode)) |mode| {
                var owner = try storage.Store.init(std.testing.allocator, io, options);
                var disk = try fault.Disk.init(std.testing.allocator, io, &.{ owner.database, owner.wal }, std.math.maxInt(usize), short);
                defer disk.deinit();
                const modeled = disk.interface();
                owner.io = modeled;
                owner.filesystem.io = modeled;
                owner.checkpoint_io.io = modeled;
                disk.cut = cut;
                var acknowledged: u64 = 1;
                scenario(&owner, &acknowledged) catch |err| switch (err) {
                    error.IoFailure, error.FailedTransaction, error.NoSpace => {},
                    else => return err,
                };
                events = @max(events, disk.events);
                owner.deinit();
                disk.detach();
                disk.crash(mode);
                disk.cut = std.math.maxInt(usize);
                disk.failed = false;
                var recovered = try storage.Store.init(std.testing.allocator, disk.interface(), options);
                defer {
                    recovered.deinit();
                    disk.detach();
                }
                try std.testing.expect(recovered.lastTick() >= acknowledged);
                try std.testing.expect(recovered.lastTick() <= 3);
                for ([_][]const u8{ "a", "b" }) |name| {
                    const space = try recovered.openSpace(name);
                    var page: storage.Page = undefined;
                    try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
                    for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(recovered.lastTick())), byte);
                }
                total_events += 1;
            }
        }
    }
    try std.testing.expect(total_events > 100);
}

fn recycle(store: *storage.Store, acknowledged: *u64) !void {
    const inode = (try store.wal.stat(store.io)).inode;
    const space = try store.openSpace("test");
    const page: storage.Page = @splat(2);
    try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
    var steps: usize = 0;
    while ((try store.wal.stat(store.io)).inode == inode or store.phase != .idle) : (steps += 1) {
        if (steps == 100) return error.MaintenanceDidNotFinish;
        _ = try store.maintain(8);
    }
    try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
    try store.waitDurable(try store.commit(2));
    acknowledged.* = 2;
}

test "WAL replacement preserves a copied slot reused as an unwritten zero page" {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 128, .checkpoint_bytes = 64 };
    var reused: storage.PageId = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const a = try store.openSpace("a");
        var ids: [2]storage.PageId = undefined;
        try a.allocatePages(&ids);
        const page: storage.Page = @splat(42);
        try a.writePages(&.{ .{ .id = ids[0], .source = &page }, .{ .id = ids[1], .source = &page } });
        try store.waitDurable(try store.commit(1));
        try a.freePages(ids[0..1]);
        try a.writePages(&.{.{ .id = ids[1], .source = &page }});
        const inode = (try store.wal.stat(io)).inode;
        var steps: usize = 0;
        while (store.phase != .replacement_copy) : (steps += 1) {
            if (steps == 100) return error.MaintenanceDidNotFinish;
            _ = try store.maintain(1);
        }
        _ = try store.maintain(1);
        try std.testing.expect(store.locations.get(@intFromEnum(ids[0])).?.replacement != 0);
        const b = try store.openSpace("b");
        var allocated: [1]storage.PageId = undefined;
        try b.allocatePages(&allocated);
        reused = allocated[0];
        try std.testing.expectEqual(ids[0], reused);
        try b.setRoot(reused);
        while ((try store.wal.stat(io)).inode == inode or store.phase != .idle) : (steps += 1) {
            if (steps == 100) return error.MaintenanceDidNotFinish;
            _ = try store.maintain(1);
        }
        try store.waitDurable(try store.commit(2));
    }
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    const b = try store.openSpace("b");
    try std.testing.expectEqual(@as(u64, 2), store.lastTick());
    try std.testing.expectEqual(reused, (try b.getRoot()).?);
    var actual: storage.Page = undefined;
    try b.readPages(&.{.{ .id = reused, .destination = &actual }});
    const expected: storage.Page = @splat(0);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "WAL recycling carries unfinished writes and recopies pages changed during replacement" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |commit| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/carry", .{temporary.sub_path});
        defer std.testing.allocator.free(path);
        const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 128, .checkpoint_bytes = 64 };
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        var space = try store.openSpace("test");
        var ids: [48]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const original: storage.Page = @splat(1);
        const changed: storage.Page = @splat(2);
        for (ids) |id| try space.writePages(&.{.{ .id = id, .source = &original }});
        try space.setRoot(ids[0]);
        try store.waitDurable(try store.commit(1));
        for (ids) |id| try space.writePages(&.{.{ .id = id, .source = &changed }});
        const inode = (try store.wal.stat(io)).inode;
        var steps: usize = 0;
        while (store.phase != .replacement_copy) : (steps += 1) {
            try std.testing.expect(steps < 100);
            _ = try store.maintain(32);
        }
        _ = try store.maintain(1);
        const latest: storage.Page = @splat(3);
        try space.writePages(&.{.{ .id = ids[0], .source = &latest }});
        try space.freePages(ids[1..2]);
        var reused: [1]storage.PageId = undefined;
        try space.allocatePages(&reused);
        try std.testing.expectEqual(ids[1], reused[0]);
        try space.writePages(&.{.{ .id = reused[0], .source = &latest }});
        var allocated: [1]storage.PageId = undefined;
        try space.allocatePages(&allocated);
        while ((try store.wal.stat(io)).inode == inode or store.phase != .idle) : (steps += 1) {
            try std.testing.expect(steps < 200);
            _ = try store.maintain(1);
        }
        try std.testing.expectEqual(@as(usize, ids.len + 1), store.locations.count());
        try std.testing.expectEqual(@as(u64, 64 + ids.len * (storage.page_size + 64)), store.end);
        var actual: storage.Page = undefined;
        for (ids, 0..) |id, index| {
            try space.readPages(&.{.{ .id = id, .destination = &actual }});
            try std.testing.expectEqualSlices(u8, if (index < 2) &latest else &changed, &actual);
        }
        if (commit) try store.waitDurable(try store.commit(2));
        store.deinit();
        store = try storage.Store.init(std.testing.allocator, io, options);
        space = try store.openSpace("test");
        try std.testing.expectEqual(@as(u64, if (commit) 2 else 1), store.lastTick());
        for (ids, 0..) |id, index| {
            try space.readPages(&.{.{ .id = id, .destination = &actual }});
            try std.testing.expectEqualSlices(u8, if (!commit) &original else if (index < 2) &latest else &changed, &actual);
        }
        if (commit) {
            try space.readPages(&.{.{ .id = allocated[0], .destination = &actual }});
            for (actual) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "a newer commit cancels a replacement based on an older database snapshot" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/newer", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .checkpoint_bytes = 64 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    var space = try store.openSpace("test");
    var ids: [2]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const original: storage.Page = @splat(1);
    const changed: storage.Page = @splat(2);
    for (ids) |id| try space.writePages(&.{.{ .id = id, .source = &original }});
    try space.setRoot(ids[0]);
    try store.waitDurable(try store.commit(1));
    for (ids) |id| try space.writePages(&.{.{ .id = id, .source = &changed }});
    const inode = (try store.wal.stat(io)).inode;
    var steps: usize = 0;
    while (store.phase != .replacement_copy) : (steps += 1) {
        try std.testing.expect(steps < 100);
        _ = try store.maintain(32);
    }
    _ = try store.maintain(1);
    try store.waitDurable(try store.commit(2));
    _ = try store.maintain(32);
    try std.testing.expectEqual(inode, (try store.wal.stat(io)).inode);
    while (store.end != 64 or store.phase != .idle) : (steps += 1) {
        try std.testing.expect(steps < 200);
        _ = try store.maintain(32);
    }
    store.deinit();
    store = try storage.Store.init(std.testing.allocator, io, options);
    space = try store.openSpace("test");
    try std.testing.expectEqual(@as(u64, 2), store.lastTick());
    var actual: storage.Page = undefined;
    for (ids) |id| {
        try space.readPages(&.{.{ .id = id, .destination = &actual }});
        try std.testing.expectEqualSlices(u8, &changed, &actual);
    }
}

test "power loss during WAL replacement preserves both possible directory outcomes" {
    const io = std.testing.io;
    var events: usize = 0;
    var cut: usize = 0;
    while (cut <= events) : (cut += 1) {
        for ([_]fault.Disk.Mode{ .discard, .persist, .torn, .torn_inverse }) |mode| {
            for ([_]bool{ false, true }) |restore_old_name| {
                var temporary = std.testing.tmpDir(.{});
                defer temporary.cleanup();
                const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
                defer std.testing.allocator.free(path);
                const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
                var owner = try storage.Store.init(std.testing.allocator, io, options);
                const space = try owner.openSpace("test");
                var ids: [2]storage.PageId = undefined;
                try space.allocatePages(&ids);
                const page: storage.Page = @splat(1);
                try space.writePages(&.{.{ .id = ids[0], .source = &page }});
                try space.setRoot(ids[0]);
                try owner.waitDurable(try owner.commit(1));
                const old_inode = (try owner.wal.stat(io)).inode;
                const wal_name = try std.testing.allocator.dupeZ(u8, owner.wal_name);
                defer std.testing.allocator.free(wal_name);
                try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.linkat(owner.directory.handle, wal_name, owner.directory.handle, "previous.wal", 0)));
                const staging = try owner.directory.createFile(io, owner.temporary_name, .{ .read = true });
                defer staging.close(io);
                var disk = try fault.Disk.init(std.testing.allocator, io, &.{ owner.database, owner.wal, staging }, if (cut == 0) std.math.maxInt(usize) else cut, true);
                defer disk.deinit();
                const modeled = disk.interface();
                owner.io = modeled;
                owner.filesystem.io = modeled;
                owner.checkpoint_io.io = modeled;
                var acknowledged: u64 = 1;
                recycle(&owner, &acknowledged) catch |err| switch (err) {
                    error.IoFailure, error.FailedTransaction, error.NoSpace => {},
                    else => return err,
                };
                if (cut == 0) events = @max(events, disk.events);
                const renamed = (try owner.wal.stat(io)).inode != old_inode;
                owner.deinit();
                disk.detach();
                disk.crash(mode);
                if (renamed and disk.directory_syncs == 0 and restore_old_name) try temporary.dir.rename("previous.wal", temporary.dir, "world.wal", io);
                disk.cut = std.math.maxInt(usize);
                disk.failed = false;
                var recovered = try storage.Store.init(std.testing.allocator, disk.interface(), options);
                defer {
                    recovered.deinit();
                    disk.detach();
                }
                try std.testing.expect(recovered.lastTick() >= acknowledged);
                try std.testing.expect(recovered.lastTick() <= 2);
                const restored = try recovered.openSpace("test");
                var actual: storage.Page = undefined;
                try restored.readPages(&.{.{ .id = (try restored.getRoot()).?, .destination = &actual }});
                for (actual) |byte| try std.testing.expectEqual(@as(u8, @intCast(recovered.lastTick())), byte);
            }
        }
    }
    try std.testing.expect(events > 10);
}

fn fuzzPager(_: void, smith: *std.testing.Smith) !void {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 0), store.lastTick());
    var expected: [16]?u8 = @splat(null);
    var saved = expected;
    var program: [96 * 3]u8 = undefined;
    smith.bytesWithHash(&program, 1);
    for (0..96) |step| {
        errdefer std.debug.print("pager step={d} committed={d} phase={t}\n", .{ step, store.lastTick(), store.phase });
        const index = program[step * 3 + 1] % expected.len;
        var name: [32]u8 = undefined;
        const space = try store.openSpace(try std.fmt.bufPrint(&name, "page-{d}", .{index}));
        switch (program[step * 3] % 6) {
            0, 1 => {
                const id = try space.getRoot() orelse blk: {
                    var ids: [1]storage.PageId = undefined;
                    try space.allocatePages(&ids);
                    try space.setRoot(ids[0]);
                    break :blk ids[0];
                };
                const value = program[step * 3 + 2];
                const page: storage.Page = @splat(value);
                try space.writePages(&.{.{ .id = id, .source = &page }});
                expected[index] = value;
            },
            2 => if (try space.getRoot()) |id| {
                try space.setRoot(null);
                try space.freePages(&.{id});
                expected[index] = null;
            },
            3 => {
                try store.waitDurable(try store.commit(step + 1));
                saved = expected;
            },
            4 => {
                store.deinit();
                store = try storage.Store.init(std.testing.allocator, io, options);
                expected = saved;
            },
            5 => {
                _ = try store.maintain(4);
            },
            else => unreachable,
        }
        for (expected, 0..) |value, at| {
            const reading = try store.openSpace(try std.fmt.bufPrint(&name, "page-{d}", .{at}));
            const root = try reading.getRoot();
            try std.testing.expectEqual(value != null, root != null);
            if (root) |id| {
                var page: storage.Page = undefined;
                try reading.readPages(&.{.{ .id = id, .destination = &page }});
                for (page) |byte| try std.testing.expectEqual(value.?, byte);
            }
        }
    }
}

test "fuzz page allocation roots commits maintenance and crash reopen" {
    try std.testing.fuzz({}, fuzzPager, .{ .corpus = &.{&.{ 0, 0, 1, 3, 0, 0, 0, 1, 2, 5, 0, 0, 0, 0, 3, 5, 0, 0, 4, 0, 0, 2, 0, 0, 3, 0, 0, 4, 0, 0 }} });
}

test "durable reopen rebuilds the WAL index and subsequent commits remain recoverable" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var ids: [1]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const page: storage.Page = @splat(17);
        try space.writePages(&.{.{ .id = ids[0], .source = &page }});
        try space.setRoot(ids[0]);
        try store.waitDurable(try store.commit(1));
    }
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 17), byte);
        @memset(&page, 23);
        try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
        try store.waitDurable(try store.commit(2));
    }
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 23), byte);
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
    }
}

test "recovery applies capacity limits only after validating the transaction commit" {
    const io = std.testing.io;
    for ([_]enum { unfinished, torn_commit, committed }{ .unfinished, .torn_commit, .committed }) |ending| {
        var temporary = try testing.directory(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
        defer std.testing.allocator.free(path);
        const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 128 };
        var committed_end: u64 = undefined;
        var full_end: u64 = undefined;
        {
            var store = try storage.Store.init(std.testing.allocator, io, options);
            defer store.deinit();
            const space = try store.openSpace("test");
            var root: [1]storage.PageId = undefined;
            try space.allocatePages(&root);
            const original: storage.Page = @splat(17);
            try space.writePages(&.{.{ .id = root[0], .source = &original }});
            try space.setRoot(root[0]);
            try store.waitDurable(try store.commit(1));
            committed_end = store.end;

            var ids: [64]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const changed: storage.Page = @splat(23);
            var writes: [ids.len]storage.Write = undefined;
            for (&writes, ids) |*write, id| write.* = .{ .id = id, .source = &changed };
            try space.writePages(&writes);
            try space.setRoot(ids[0]);
            if (ending != .unfinished) try store.waitDurable(try store.commit(2));
            if (ending == .torn_commit) try store.wal.setLength(io, store.end - 1);
            full_end = (try store.wal.stat(io)).size;
        }
        var smaller = options;
        smaller.maximum_wal_pages = 32;
        if (ending == .committed) {
            try std.testing.expectError(error.NoSpace, storage.Store.init(std.testing.allocator, io, smaller));
        } else {
            var store = try storage.Store.init(std.testing.allocator, io, smaller);
            defer store.deinit();
            try std.testing.expectEqual(@as(u64, 1), store.lastTick());
            try std.testing.expectEqual(committed_end, (try store.wal.stat(io)).size);
            const space = try store.openSpace("test");
            var page: storage.Page = undefined;
            try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
            const original: storage.Page = @splat(17);
            try std.testing.expectEqualSlices(u8, &original, &page);
        }
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(if (ending == .committed) full_end else committed_end, (try store.wal.stat(io)).size);
        try std.testing.expectEqual(@as(u64, if (ending == .committed) 2 else 1), store.lastTick());
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        const expected: storage.Page = @splat(if (ending == .committed) 23 else 17);
        try std.testing.expectEqualSlices(u8, &expected, &page);
    }
}

test "uring batches retain buffers while durability and writeback complete" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .submission = .uring, .maximum_wal_pages = 1024 });
    defer store.deinit();
    const space = try store.openSpace("test");
    var ids: [64]storage.PageId = undefined;
    try space.allocatePages(&ids);
    var pages: [64]storage.Page = undefined;
    var writes: [64]storage.Write = undefined;
    var reads: [64]storage.Read = undefined;
    for (0..12) |round| {
        for (&pages, &writes, &reads, ids, 0..) |*page, *write, *read, id, index| {
            @memset(page, @intCast(round + index));
            write.* = .{ .id = id, .source = page };
            read.* = .{ .id = id, .destination = page };
        }
        try space.writePages(&writes);
        try store.submitSync(try store.commit(round + 1));
        @memset(std.mem.asBytes(&pages), 0);
        try space.readPages(&reads);
        for (pages, 0..) |page, index| for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(round + index)), byte);
    }
    try store.waitDurable(store.lastCommit());
    try std.testing.expectEqual(@as(u64, 12), store.durableTick());
}

test "capacity exhaustion cannot publish a partial transaction" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 32 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var root: [1]storage.PageId = undefined;
        try space.allocatePages(&root);
        const page: storage.Page = @splat(7);
        try space.writePages(&.{.{ .id = root[0], .source = &page }});
        try space.setRoot(root[0]);
        try store.waitDurable(try store.commit(1));
        var excessive: [32]storage.PageId = undefined;
        try std.testing.expectError(error.NoSpace, space.allocatePages(&excessive));
        try std.testing.expectError(error.FailedTransaction, store.commit(2));
    }
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 7), byte);
    }
}

test "opening with a smaller limit never truncates a durable transaction" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .path = path, .submission = .standard, .maximum_wal_pages = 1024 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var ids: [6]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const page: storage.Page = @splat(11);
        try space.writePages(&.{.{ .id = ids[5], .source = &page }});
        try space.setRoot(ids[5]);
        try store.waitDurable(try store.commit(1));
    }
    var smaller = options;
    smaller.maximum_pages = 2;
    try std.testing.expectError(error.NoSpace, storage.Store.init(std.testing.allocator, io, smaller));
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try std.testing.expectEqual(@as(u64, 1), store.lastTick());
        const space = try store.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, 11), byte);
    }
}
