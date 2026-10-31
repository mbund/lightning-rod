const std = @import("std");
const builtin = @import("builtin");
const storage = @import("storage");
const metrics = @import("metrics");
const fault = @import("fault_disk.zig");
const testing = @import("testing.zig");

test "scoped roots and ticks recover together and discard an incomplete group" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/scopes", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128 };
    var roots: [2]storage.PageId = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
        defer store.deinit();
        const directory = try store.openSpace("worlds");
        for (&roots, 0..) |*root, index| {
            var scope = try storage.Scope.create(directory);
            root.* = scope.page;
            const space = try scope.transaction().openSpace("chunks");
            try std.testing.expect(space.store_is_new);
            try std.testing.expectEqual(null, try space.getRoot());
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const page: storage.Page = @splat(@intCast(index + 1));
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
            try scope.setTick(10 + index);
        }
        try std.testing.expectEqual(null, try (try store.openSpace("chunks")).getRoot());
        try store.waitDurable(try store.commit(1));
        for (roots, 0..) |root, index| {
            var scope = try storage.Scope.open(directory, root);
            const space = try scope.transaction().openSpace("chunks");
            const page: storage.Page = @splat(99);
            try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
            try scope.setTick(20 + index);
            try space.setRoot(null);
        }
    }
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 1), store.lastTick());
    const directory = try store.openSpace("worlds");
    for (roots, 0..) |root, index| {
        var scope = try storage.Scope.open(directory, root);
        try std.testing.expectEqual(@as(u64, 10 + index), scope.tick);
        const space = try scope.transaction().openSpace("chunks");
        try std.testing.expect(!space.store_is_new);
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
        try std.testing.expectError(error.InvalidArgument, scope.setTick(0));
    }
}

test "shared resources isolate databases and discard stale cache entries on reopen" {
    const Entropy = struct {
        fn fixed(_: ?*anyopaque, bytes: []u8) std.Io.RandomSecureError!void {
            @memset(bytes, 7);
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.randomSecure = Entropy.fixed;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var paths: [2][256]u8 = undefined;
    const first_path = try std.fmt.bufPrint(&paths[0], ".zig-cache/tmp/{s}/first", .{temporary.sub_path});
    const second_path = try std.fmt.bufPrint(&paths[1], ".zig-cache/tmp/{s}/second", .{temporary.sub_path});
    const resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 1 });
    defer resources.deinit();
    const first_options: storage.Store.Options = .{ .io_mode = .standard, .path = first_path, .resources = resources, .maximum_wal_pages = 64 };
    var second = try storage.Store.init(std.testing.allocator, io, .{ .path = second_path, .resources = resources, .maximum_wal_pages = 64 });
    defer second.deinit();
    {
        var first = try storage.Store.init(std.testing.allocator, io, first_options);
        defer first.deinit();
        for ([_]*storage.Store{ &first, &second }, 0..) |store, index| {
            const space = try store.openSpace("test");
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            const page: storage.Page = @splat(@intCast(index + 1));
            try space.writePages(&.{.{ .id = ids[0], .source = &page }});
            try space.setRoot(ids[0]);
            try store.waitDurable(try store.commit(1));
        }
        try std.testing.expectEqual(first.metadata.identity, second.metadata.identity);
        for (0..4) |_| for ([_]*storage.Store{ &first, &second }, 0..) |store, index| {
            const space = try store.openSpace("test");
            var page: storage.Page = undefined;
            try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
            for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte);
        };
        const space = try first.openSpace("test");
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
    }
    {
        var outside = try storage.Store.init(std.testing.allocator, io, .{ .path = first_path, .maximum_wal_pages = 64 });
        defer outside.deinit();
        const space = try outside.openSpace("test");
        const page: storage.Page = @splat(3);
        try space.writePages(&.{.{ .id = (try space.getRoot()).?, .source = &page }});
        try outside.waitDurable(try outside.commit(2));
    }
    var first = try storage.Store.init(std.testing.allocator, io, first_options);
    defer first.deinit();
    const space = try first.openSpace("test");
    var page: storage.Page = undefined;
    try space.readPages(&.{.{ .id = (try space.getRoot()).?, .destination = &page }});
    for (page) |byte| try std.testing.expectEqual(@as(u8, 3), byte);
}

test "stores retain exclusive shared buffers across native threads" {
    const Writer = struct {
        fn main(store: *storage.Store, io: std.Io, fill: u8, failure: *?anyerror) void {
            run(store, io, fill) catch |err| {
                failure.* = err;
            };
        }
        fn run(store: *storage.Store, _: std.Io, fill: u8) !void {
            const space = try store.openSpace("test");
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            try space.setRoot(ids[0]);
            for (1..9) |tick| {
                var page: storage.Page = @splat(fill);
                try space.writePages(&.{.{ .id = ids[0], .source = &page }});
                try store.waitDurable(try store.commit(tick));
                const deadline = std.Io.Clock.Timestamp.fromNow(store.io, .{ .clock = .awake, .raw = .fromSeconds(10) });
                while (true) {
                    const result = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
                    if (result == .idle) break;
                    if (std.Io.Clock.now(.awake, store.io).nanoseconds >= deadline.raw.nanoseconds) return error.MaintenanceStalled;
                    if (store.maintenance_io.active) try store.maintenance_io.wait(deadline) else std.Thread.yield() catch {};
                }
                try space.readPages(&.{.{ .id = ids[0], .destination = &page }});
                for (page) |byte| try std.testing.expectEqual(fill, byte);
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    var memory = storage.system.Memory.init(std.testing.allocator, std.testing.io);
    defer memory.deinit();
    const allocator = memory.allocator("storage");
    const resources = try storage.Resources.init(allocator, io, .{ .cache_pages = 2 });
    defer resources.deinit();
    var paths: [2][256]u8 = undefined;
    const first_path = try std.fmt.bufPrint(&paths[0], ".zig-cache/tmp/{s}/first", .{temporary.sub_path});
    const second_path = try std.fmt.bufPrint(&paths[1], ".zig-cache/tmp/{s}/second", .{temporary.sub_path});
    var first = try storage.Store.init(allocator, io, .{ .path = first_path, .resources = resources, .maximum_wal_pages = 64, .checkpoint_bytes = 64 });
    defer first.deinit();
    var second = try storage.Store.init(allocator, io, .{ .path = second_path, .resources = resources, .maximum_wal_pages = 64, .checkpoint_bytes = 64 });
    defer second.deinit();
    memory.seal();
    var failures: [2]?anyerror = @splat(null);
    const first_thread = try std.Thread.spawn(.{}, Writer.main, .{ &first, io, 11, &failures[0] });
    const second_thread = std.Thread.spawn(.{}, Writer.main, .{ &second, io, 22, &failures[1] }) catch |err| {
        first_thread.join();
        return err;
    };
    first_thread.join();
    second_thread.join();
    for (failures) |failure| if (failure) |err| {
        std.debug.print("shared storage owner failed: {t}\n", .{err});
        return err;
    };
}

test "independent storage owners share buffers across native threads" {
    const Writer = struct {
        fn main(io: std.Io, resources: *storage.Resources, path: []const u8, fill: u8, failure: *?anyerror) void {
            run(io, resources, path, fill) catch |err| {
                failure.* = err;
            };
        }
        fn run(io: std.Io, resources: *storage.Resources, path: []const u8, fill: u8) !void {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .resources = resources, .maximum_wal_pages = 64 });
            defer store.deinit();
            const space = try store.openSpace("test");
            var ids: [1]storage.PageId = undefined;
            try space.allocatePages(&ids);
            for (1..9) |tick| {
                var page: storage.Page = @splat(fill);
                try space.writePages(&.{.{ .id = ids[0], .source = &page }});
                try store.waitDurable(try store.commit(tick));
                try space.readPages(&.{.{ .id = ids[0], .destination = &page }});
                for (page) |byte| try std.testing.expectEqual(fill, byte);
            }
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var paths: [2][256]u8 = undefined;
    const first_path = try std.fmt.bufPrint(&paths[0], ".zig-cache/tmp/{s}/first", .{temporary.sub_path});
    const second_path = try std.fmt.bufPrint(&paths[1], ".zig-cache/tmp/{s}/second", .{temporary.sub_path});
    const resources = try storage.Resources.init(std.testing.allocator, std.testing.io, .{ .cache_pages = 2 });
    defer resources.deinit();
    var failures: [2]?anyerror = @splat(null);
    const first_thread = try std.Thread.spawn(.{}, Writer.main, .{ std.testing.io, resources, first_path, 11, &failures[0] });
    errdefer first_thread.join();
    const second_thread = try std.Thread.spawn(.{}, Writer.main, .{ std.testing.io, resources, second_path, 22, &failures[1] });
    first_thread.join();
    second_thread.join();
    for (failures) |failure| if (failure) |err| return err;
}

test "partial storage resource initialization releases all allocations" {
    const Initialization = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const resources = try storage.Resources.init(allocator, std.testing.io, .{});
            defer resources.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Initialization.run, .{});
}

test "recovery and WAL recycling reuse startup memory after allocation is sealed" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_bytes: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/bounded", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 64, .checkpoint_bytes = 64 };
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("test");
        var ids: [1]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const page: storage.Page = @splat(1);
        try space.writePages(&.{.{ .id = ids[0], .source = &page }});
        try space.setRoot(ids[0]);
        try store.waitDurable(try store.commit(1));
    }
    var memory = storage.system.Memory.init(std.testing.allocator, io);
    defer memory.deinit();
    var store = try storage.Store.init(memory.allocator("storage"), io, options);
    defer store.deinit();
    const filenames = store.name.len + store.wal_name.len + store.temporary_name.len;
    try std.testing.expect(memory.assigned_bytes <= store.memoryBytes() + filenames + 64);
    memory.seal();
    const allocated = memory.assigned_bytes;
    const space = try store.openSpace("test");
    const id = (try space.getRoot()).?;
    for (2..6) |tick| {
        var page: storage.Page = undefined;
        try space.readPages(&.{.{ .id = id, .destination = &page }});
        for (page) |byte| try std.testing.expectEqual(@as(u8, @intCast(tick - 1)), byte);
        @memset(&page, @intCast(tick));
        try space.writePages(&.{.{ .id = id, .source = &page }});
        try store.waitDurable(try store.commit(tick));
        for (0..32) |_| {
            if (try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 }) == .idle) break;
        } else return error.MaintenanceStalled;
        try std.testing.expectEqual(allocated, memory.assigned_bytes);
        try std.testing.expectEqual(tick, store.durableTick());
    }
}

test "deferred recovery preserves submitted commits without acknowledging durability" {
    const io = std.testing.io;
    for ([_]bool{ false, true }) |wait| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_bytes: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_bytes, ".zig-cache/tmp/{s}/deferred", .{temporary.sub_path});
        var options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 32 };
        var store = try storage.Store.init(std.testing.allocator, io, options);
        var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
        defer disk.deinit();
        const modeled = disk.interface();
        store.bindIo(modeled);
        _ = try store.commit(7);
        store.deinit();
        try std.testing.expectEqual(@as(usize, 0), disk.syncs);
        options.recovery = .deferred;
        store = try storage.Store.init(std.testing.allocator, modeled, options);
        try std.testing.expectEqual(@as(u64, 7), store.lastTick());
        try std.testing.expectEqual(@as(u64, 0), store.durableTick());
        try std.testing.expectEqual(@as(usize, 0), disk.syncs);
        if (wait) try store.waitDurable(store.lastCommit());
        store.deinit();
        disk.detach();
        disk.crash(.discard);
        store = try storage.Store.init(std.testing.allocator, disk.interface(), options);
        try std.testing.expectEqual(@as(u64, if (wait) 7 else 0), store.lastTick());
        store.deinit();
        disk.detach();
    }
}

test "new database refuses unavailable secure entropy" {
    const Entropy = struct {
        fn unavailable(_: ?*anyopaque, _: []u8) std.Io.RandomSecureError!void {
            return error.EntropyUnavailable;
        }
        fn fallback(_: ?*anyopaque, _: []u8) void {
            @panic("database identities must not fall back to insecure randomness");
        }
    };
    const base = std.testing.io;
    var vtable = base.vtable.*;
    vtable.randomSecure = Entropy.unavailable;
    vtable.random = Entropy.fallback;
    const io: std.Io = .{ .userdata = base.userdata, .vtable = &vtable };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/entropy", .{temporary.sub_path});
    try std.testing.expectError(error.EntropyUnavailable, storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 32 }));
}

test "recreating a database changes its identity and rejects its stale WAL" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/identity", .{temporary.sub_path});
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 32 };
    var original: [16]u8 = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        original = store.metadata.identity;
        try store.waitDurable(try store.commit(1));
    }
    try temporary.dir.deleteFile(io, "identity");
    try std.testing.expectError(error.Corrupt, storage.Store.init(std.testing.allocator, io, options));
    try temporary.dir.deleteFile(io, "identity");
    try temporary.dir.deleteFile(io, "identity.wal");
    var replacement: [16]u8 = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        replacement = store.metadata.identity;
        try std.testing.expect(!std.mem.eql(u8, &original, &replacement));
    }
    var reopened = try storage.Store.init(std.testing.allocator, io, options);
    defer reopened.deinit();
    try std.testing.expectEqualSlices(u8, &replacement, &reopened.metadata.identity);
}

test "closing a store releases its lock despite retained asynchronous file references" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lock", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 32 };
    var retained: std.Io.File = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        try store.waitDurable(try store.commit(1));
        try std.testing.expectError(error.DatabaseLocked, storage.Store.init(std.testing.allocator, io, options));

        // A duplicate retains the open file description just as an unfinished io_uring request does.
        const descriptor = std.os.linux.dup(store.database.handle);
        try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(descriptor));
        retained = .{ .handle = @intCast(descriptor), .flags = .{ .nonblocking = false } };
        errdefer retained.close(io);
        try store.maintenance_io.submit(&.{.{ .sync = store.database }});
    }
    defer retained.close(io);

    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    try std.testing.expectEqual(@as(u64, 1), store.lastTick());
    try std.testing.expectError(error.DatabaseLocked, storage.Store.init(std.testing.allocator, io, options));
}

test "ranged reads validate the entire page before copying into caller buffers" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/ranges", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
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
    store.resources.cache_index.clearRetainingCapacity();
    const location = store.locations.get(@backingInt(ids[0])).?;
    try store.wal.writePositionalAll(io, &.{page[2000] ^ 255}, location.current + 32 + 32 + 2000);
    try std.testing.expectError(error.Corrupt, space.readPages(&.{.{ .id = ids[0], .destination = output[1..16] }}));
    try std.testing.expectEqual(@as(u8, 255), output[0]);
}

test "short writes clear reused frame tails and survive durable reopen" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/short", .{directory.sub_path});
    const resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 1 });
    defer resources.deinit();
    const options: storage.Store.Options = .{ .path = path, .resources = resources };
    var ids: [2]storage.PageId = undefined;
    {
        var store = try storage.Store.init(std.testing.allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("short");
        try space.allocatePages(&ids);
        const page: storage.Page = @splat(255);
        try space.writePages(&.{ .{ .id = ids[0], .source = &page }, .{ .id = ids[1], .source = &page } });
        try store.waitDurable(try store.commit(1));
        try space.writePages(&.{ .{ .id = ids[0], .source = "prefix" }, .{ .id = ids[1], .source = &.{} } });
        try store.waitDurable(try store.commit(2));
    }
    var store = try storage.Store.init(std.testing.allocator, io, options);
    defer store.deinit();
    const space = try store.openSpace("short");
    var pages: [3]storage.Page = undefined;
    try space.readPages(&.{ .{ .id = ids[0], .destination = &pages[0] }, .{ .id = ids[1], .destination = &pages[1] }, .{ .id = ids[0], .destination = &pages[2] } });
    try std.testing.expectEqualStrings("prefix", pages[0][0..6]);
    try std.testing.expect(std.mem.allEqual(u8, pages[0][6..], 0));
    try std.testing.expect(std.mem.allEqual(u8, &pages[1], 0));
    try std.testing.expectEqualSlices(u8, &pages[0], &pages[2]);
}

test "uncommitted page rewrites reuse WAL frames without touching committed data" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = filename, .maximum_wal_pages = 1024 };
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
        const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128 };
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
    try space.readPages(&.{ .{ .id = root, .destination = &pages[0] }, .{ .id = @fromBackingInt(@intCast(@backingInt(root) + 1)), .destination = &pages[1] } });
    const expected: storage.Page = @splat(1);
    for (&pages) |*page| try std.testing.expectEqualSlices(u8, &expected, page);
}

test "empty transactions bind each commit to the preceding committed prefix" {
    const io = std.testing.io;
    var temporary = try testing.directory(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128 };
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
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
        for (0..3) |_| _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
        const changed: storage.Page = @splat(42);
        try space.writePages(&.{.{ .id = root, .source = &changed }});
        try store.waitDurable(try store.commit(round + 2));
        if (round == 0) continue;
        var steps: usize = 0;
        while (store.end != 64 or store.phase != .idle) : (steps += 1) {
            if (steps == store.limits.maximum_wal_pages * 16) return error.MaintenanceDidNotFinish;
            _ = try store.pollMaintenance(.{ .index_entries = 2, .pages = 2 });
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
    _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
    while (store.phase != .database_sync) _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
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
            owner.maintenance_io.io = modeled;
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
                owner.maintenance_io.io = modeled;
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
        if (steps == store.limits.maximum_wal_pages * 16) return error.MaintenanceDidNotFinish;
        _ = try store.pollMaintenance(.{ .index_entries = 8, .pages = 8 });
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128, .checkpoint_bytes = 64 };
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
            if (steps == store.limits.maximum_wal_pages * 16) return error.MaintenanceDidNotFinish;
            _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
        }
        while (store.locations.get(@backingInt(ids[0])).?.replacement == 0) {
            _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
        }
        const b = try store.openSpace("b");
        var allocated: [1]storage.PageId = undefined;
        try b.allocatePages(&allocated);
        reused = allocated[0];
        try std.testing.expectEqual(ids[0], reused);
        try b.setRoot(reused);
        while ((try store.wal.stat(io)).inode == inode or store.phase != .idle) : (steps += 1) {
            if (steps == store.limits.maximum_wal_pages * 16) return error.MaintenanceDidNotFinish;
            _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
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
        const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128, .checkpoint_bytes = 64 };
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
            try std.testing.expect(steps < store.limits.maximum_wal_pages * 16);
            _ = try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 });
        }
        _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
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
            try std.testing.expect(steps < store.limits.maximum_wal_pages * 16);
            _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .checkpoint_bytes = 64 };
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
        try std.testing.expect(steps < store.limits.maximum_wal_pages * 16);
        _ = try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 });
    }
    _ = try store.pollMaintenance(.{ .index_entries = 1, .pages = 1 });
    try store.waitDurable(try store.commit(2));
    _ = try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 });
    try std.testing.expectEqual(inode, (try store.wal.stat(io)).inode);
    while (store.end != 64 or store.phase != .idle) : (steps += 1) {
        try std.testing.expect(steps < store.limits.maximum_wal_pages * 16);
        _ = try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 });
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
                const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024, .checkpoint_bytes = 64 };
                var owner = try storage.Store.init(std.testing.allocator, io, options);
                const space = try owner.openSpace("test");
                var ids: [2]storage.PageId = undefined;
                try space.allocatePages(&ids);
                const page: storage.Page = @splat(1);
                try space.writePages(&.{.{ .id = ids[0], .source = &page }});
                try space.setRoot(ids[0]);
                try owner.waitDurable(try owner.commit(1));
                const old_inode = (try owner.wal.stat(io)).inode;
                const wal_name = try std.testing.allocator.dupeSentinel(u8, owner.wal_name, 0);
                defer std.testing.allocator.free(wal_name);
                try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(std.os.linux.linkat(owner.directory.handle, wal_name, owner.directory.handle, "previous.wal", 0)));
                const staging = try owner.directory.createFile(io, owner.temporary_name, .{ .read = true });
                defer staging.close(io);
                var disk = try fault.Disk.init(std.testing.allocator, io, &.{ owner.database, owner.wal, staging }, if (cut == 0) std.math.maxInt(usize) else cut, true);
                defer disk.deinit();
                const modeled = disk.interface();
                owner.io = modeled;
                owner.filesystem.io = modeled;
                owner.maintenance_io.io = modeled;
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

test "durable reopen rebuilds the WAL index and subsequent commits remain recoverable" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/world", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
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
        const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 128 };
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
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 1024 });
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 32 };
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
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 1024 };
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

test "bounded maintenance preserves foreground rewrites and a durable save" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/cooperative", .{temporary.sub_path});
    defer allocator.free(path);
    const options: storage.Store.Options = .{ .io_mode = .standard, .path = path, .maximum_wal_pages = 512, .checkpoint_bytes = 64 };
    var ids: [32]storage.PageId = undefined;
    var model: [32]u8 = @splat(1);
    {
        var store = try storage.Store.init(allocator, io, options);
        defer store.deinit();
        const space = try store.openSpace("world");
        try space.allocatePages(&ids);
        var pages: [32]storage.Page = @splat(@splat(1));
        var writes: [32]storage.Write = undefined;
        for (&writes, ids, &pages) |*write, id, *page| write.* = .{ .id = id, .source = page };
        try space.writePages(&writes);
        try store.waitDurable(try store.commit(1));
        for (&pages) |*page| @memset(page, 2);
        @memset(&model, 2);
        try space.writePages(&writes);
        for (0..128) |round| {
            const index = round % ids.len;
            const value: u8 = @intCast(round + 3);
            @memset(&pages[index], value);
            model[index] = value;
            try space.writePages(writes[index..][0..1]);
            _ = try store.pollMaintenance(.{ .index_entries = 8, .pages = 8 });
            var actual: storage.Page = undefined;
            try space.readPages(&.{.{ .id = ids[index], .destination = &actual }});
            try std.testing.expectEqualSlices(u8, &pages[index], &actual);
        }
        const commit = try store.commit(2);
        _ = try store.pollMaintenance(.{ .index_entries = 8, .pages = 8 });
        try store.waitDurable(commit);
        _ = try store.pollMaintenance(.{ .index_entries = 8, .pages = 8 });
    }
    var recovered = try storage.Store.init(allocator, io, options);
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 2), recovered.lastTick());
    const space = try recovered.openSpace("world");
    for (ids, model) |id, expected| {
        var actual: storage.Page = undefined;
        try space.readPages(&.{.{ .id = id, .destination = &actual }});
        for (actual) |byte| try std.testing.expectEqual(expected, byte);
    }
}

test "borrowed pages survive replacement and bounded cache pressure" {
    for ([_]@FieldType(storage.Store.Options, "io_mode"){ .standard, .uring }) |mode| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/borrowed", .{temporary.sub_path});
        const resources = try storage.Resources.init(std.testing.allocator, std.testing.io, .{ .cache_pages = 1 });
        defer resources.deinit();
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path, .io_mode = mode, .resources = resources });
        defer store.deinit();
        const space = try store.openSpace("pages");
        var ids: [2]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const first: storage.Page = @splat(11);
        const second: storage.Page = @splat(22);
        try space.writePages(&.{ .{ .id = ids[0], .source = &first }, .{ .id = ids[1], .source = &second } });
        var output: storage.Page = undefined;
        const Reader = struct {
            space: storage.Space,
            id: storage.PageId,
            entered: std.Io.Event = .unset,
            done: std.Io.Event = .unset,
            output: storage.Page = undefined,
            result: storage.Error!void = {},
            fn run(self: *@This()) void {
                self.entered.set(std.testing.io);
                self.result = self.space.readPages(&.{.{ .id = self.id, .destination = &self.output }});
                self.done.set(std.testing.io);
            }
        };
        var reader: Reader = .{ .space = space, .id = ids[1] };
        var thread: ?std.Thread = null;
        defer if (thread) |waiting| waiting.join();
        {
            var leases: [1]storage.PageLease = undefined;
            try space.borrowPages(ids[0..1], &leases);
            defer storage.PageLease.releaseMany(&leases);
            try std.testing.expect(std.mem.allEqual(u8, leases[0].bytes(), 11));
            try space.writePages(&.{.{ .id = ids[0], .source = &second }});
            try std.testing.expect(std.mem.allEqual(u8, leases[0].bytes(), 11));
            thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
            reader.entered.waitUncancelable(std.testing.io);
            try reader.done.waitTimeout(std.testing.io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } });
            try reader.result;
            var rejected: [1]storage.PageLease = undefined;
            try std.testing.expectError(error.CachePinned, space.borrowPages(ids[1..2], &rejected));
            try space.readPages(&.{.{ .id = ids[0], .destination = &output }});
            try std.testing.expectEqualSlices(u8, &second, &output);
            try std.testing.expect(std.mem.allEqual(u8, leases[0].bytes(), 11));
        }
        thread.?.join();
        thread = null;
        try reader.result;
        try std.testing.expectEqualSlices(u8, &second, &reader.output);
        try space.readPages(&.{.{ .id = ids[0], .destination = &output }});
        try std.testing.expectEqualSlices(u8, &second, &output);
        try store.waitDurable(try store.commit(1));
    }
}

test "page leases remain valid while other threads borrow and release the same page" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/shared-leases", .{temporary.sub_path});
    const resources = try storage.Resources.init(allocator, io, .{ .cache_pages = 1 });
    defer resources.deinit();
    var store = try storage.Store.init(allocator, io, .{ .path = path, .resources = resources });
    defer store.deinit();
    const space = try store.openSpace("pages");
    var ids: [1]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const page: storage.Page = @splat(37);
    try space.writePages(&.{.{ .id = ids[0], .source = &page }});
    var leases: [1]storage.PageLease = undefined;
    try space.borrowPages(&ids, &leases);
    defer storage.PageLease.releaseMany(&leases);
    const Borrower = struct {
        space: storage.Space,
        id: storage.PageId,
        start: std.Io.Event = .unset,
        result: anyerror!void = {},

        fn run(self: *@This()) void {
            self.start.waitUncancelable(std.testing.io);
            self.result = self.borrow();
        }

        fn borrow(self: *@This()) !void {
            for (0..2000) |_| {
                var borrowed: [1]storage.PageLease = undefined;
                try self.space.borrowPages(&.{self.id}, &borrowed);
                defer storage.PageLease.releaseMany(&borrowed);
                try std.testing.expect(std.mem.allEqual(u8, borrowed[0].bytes(), 37));
            }
        }
    };
    var borrower: Borrower = .{ .space = space, .id = ids[0] };
    {
        const thread = try std.Thread.spawn(.{}, Borrower.run, .{&borrower});
        defer thread.join();
        borrower.start.set(io);
        for (0..2000) |_| try std.testing.expectEqualSlices(u8, &page, leases[0].bytes());
    }
    try borrower.result;
}

test "partial borrow admission cannot publish unloaded cache pages" {
    for ([_]@FieldType(storage.Store.Options, "io_mode"){ .standard, .uring }) |mode| {
        for (2..6) |capacity| {
            for (1..capacity) |pinned_count| {
                var temporary = std.testing.tmpDir(.{});
                defer temporary.cleanup();
                var path_buffer: [256]u8 = undefined;
                const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/partial-borrow", .{temporary.sub_path});
                const resources = try storage.Resources.init(std.testing.allocator, std.testing.io, .{ .cache_pages = capacity });
                defer resources.deinit();
                var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path, .io_mode = mode, .resources = resources });
                defer store.deinit();
                const space = try store.openSpace("pages");
                var ids: [15]storage.PageId = undefined;
                var pages: [15]storage.Page = undefined;
                var writes: [15]storage.Write = undefined;
                const count = capacity * 3;
                try space.allocatePages(ids[0..count]);
                for (pages[0..count], writes[0..count], ids[0..count], 0..) |*page, *write, id, index| {
                    @memset(page, @intCast(index + 1));
                    write.* = .{ .id = id, .source = page };
                }
                try space.writePages(writes[0..count]);
                var pinned: [5]storage.PageLease = undefined;
                try space.borrowPages(ids[0..pinned_count], pinned[0..pinned_count]);
                {
                    defer storage.PageLease.releaseMany(pinned[0..pinned_count]);
                    var rejected: [5]storage.PageLease = @splat(pinned[0]);
                    try std.testing.expectError(error.CachePinned, space.borrowPages(ids[capacity..][0..capacity], rejected[0..capacity]));
                    for (rejected[0..capacity]) |lease| try std.testing.expect(std.meta.eql(pinned[0], lease));
                    var destinations: [5]storage.Page = undefined;
                    var reads: [5]storage.Read = undefined;
                    for (ids[capacity..][0..capacity], reads[0..capacity], destinations[0..capacity]) |id, *read, *destination| read.* = .{ .id = id, .destination = destination };
                    try space.readPages(reads[0..capacity]);
                    for (destinations[0..capacity], pages[capacity..][0..capacity]) |*actual, *expected| try std.testing.expectEqualSlices(u8, expected, actual);
                    for (pinned[0..pinned_count], pages[0..pinned_count]) |lease, *expected| try std.testing.expectEqualSlices(u8, expected, lease.bytes());
                }
                var duplicates: [2]storage.Page = undefined;
                try space.readPages(&.{ .{ .id = ids[count - 1], .destination = &duplicates[0] }, .{ .id = ids[count - 1], .destination = &duplicates[1] } });
                for (&duplicates) |*actual| try std.testing.expectEqualSlices(u8, &pages[count - 1], actual);
                try store.waitDurable(try store.commit(1));
            }
        }
    }
}

test "maintenance yields on unavailable resources and unfinished I/O while foreground writes proceed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/nonblocking", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 64, .checkpoint_bytes = 64 });
    defer store.deinit();
    const budget: storage.MaintenanceBudget = .{ .index_entries = 1, .pages = 1 };
    {
        try std.testing.expect(store.mutex.tryLock());
        defer store.mutex.unlock(io);
        try std.testing.expectEqual(.pending, try store.pollMaintenance(budget));
    }
    {
        try std.testing.expect(store.resources.mutex.tryLock());
        defer store.resources.mutex.unlock(io);
        try std.testing.expectEqual(.pending, try store.pollMaintenance(budget));
    }
    const raw = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(raw));
    const file: std.Io.File = .{ .handle = @intCast(raw), .flags = .{ .nonblocking = false } };
    defer file.close(io);
    var bytes: [8]u8 = undefined;
    try store.maintenance_io.submit(&.{.{ .read = .{ .file = file, .offset = 0, .bytes = &bytes } }});
    defer {
        const value: u64 = 1;
        _ = std.os.linux.write(file.handle, std.mem.asBytes(&value).ptr, @sizeOf(u64));
        store.maintenance_io.drain() catch {};
    }
    try std.testing.expectEqual(.pending, try store.pollMaintenance(budget));
    const space = try store.openSpace("foreground");
    var ids: [1]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const expected: storage.Page = @splat(73);
    try space.writePages(&.{.{ .id = ids[0], .source = &expected }});
    try space.setRoot(ids[0]);
    try store.submitSync(try store.commit(1));
    try store.filesystem.wait(null);
    try store.progress();
    try std.testing.expectEqual(@as(u64, 1), store.durableTick());
    var actual: storage.Page = undefined;
    try space.readPages(&.{.{ .id = ids[0], .destination = &actual }});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expect(store.maintenance_io.active);
    try std.testing.expectEqual(.pending, try store.pollMaintenance(budget));
}

test "maintenance preserves its committed snapshot while newer commits arrive" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/budget", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 64, .checkpoint_bytes = 64 });
    defer store.deinit();
    const space = try store.openSpace("test");
    var ids: [16]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const bytes: storage.Page = @splat(7);
    var writes: [16]storage.Write = undefined;
    for (ids, &writes) |id, *write| write.* = .{ .id = id, .source = &bytes };
    try space.writePages(&writes);
    try store.waitDurable(try store.commit(1));
    const budget: storage.MaintenanceBudget = .{ .index_entries = 3, .pages = 2 };
    _ = try store.pollMaintenance(budget);
    try std.testing.expectEqual(.collecting, store.phase);
    _ = try store.pollMaintenance(budget);
    try std.testing.expectEqual(@as(usize, 3), store.maintenance_at);
    try std.testing.expect(!store.maintenance_io.active);
    const changed: storage.Page = @splat(19);
    for (ids) |id| try space.writePages(&.{.{ .id = id, .source = &changed }});
    try store.waitDurable(try store.commit(2));
    while (store.phase == .collecting) {
        const before = store.maintenance_at;
        _ = try store.pollMaintenance(budget);
        try std.testing.expect(store.maintenance_at > before);
        try std.testing.expect(store.maintenance_at - before <= budget.index_entries);
    }
    try std.testing.expectEqual(@as(u64, 1), store.checkpoint_metadata.sequence);
    for (store.checkpoint_pages[0..store.checkpoint_count]) |page| {
        var block: [storage.page_size + 32]u8 = undefined;
        try std.testing.expectEqual(block.len, try store.wal.readPositionalAll(io, &block, page.offset + 32));
        try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, block[16..24], .little));
        if (page.id != 0) try std.testing.expectEqualSlices(u8, &bytes, block[32..]);
    }
    try std.testing.expectEqual(.copying, store.phase);
    _ = try store.pollMaintenance(budget);
    try std.testing.expectEqual(@as(usize, 2), store.maintenance_io.count);
    try std.testing.expect(store.maintenance_io.active);
}

test "a paused read preserves its WAL image while foreground work and rotation progress" {
    const Reader = struct {
        space: storage.Space,
        id: storage.PageId,
        gate: *fault.Disk.IoGate,
        bytes: storage.Page = undefined,
        result: storage.Error!void = {},
        fn run(self: *@This()) void {
            self.gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.space.readPages(&.{.{ .id = self.id, .destination = &self.bytes }});
        }
    };
    const Foreground = struct {
        space: storage.Space,
        ids: [2]storage.PageId,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.result = self.execute();
            self.done.set(std.testing.io);
        }
        fn execute(self: *@This()) !void {
            var actual: storage.Page = undefined;
            try self.space.readPages(&.{.{ .id = self.ids[1], .destination = &actual }});
            try std.testing.expect(std.mem.allEqual(u8, &actual, 22));
            const next: storage.Page = @splat(44);
            try self.space.writePages(&.{.{ .id = self.ids[0], .source = &next }});
            try self.space.store.submitSync(try self.space.store.commit(2));
            try self.space.readPages(&.{.{ .id = self.ids[0], .destination = &actual }});
            try std.testing.expectEqualSlices(u8, &next, &actual);
        }
    };
    const io = std.testing.io;
    for ([_]bool{ false, true }) |rotate| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/paused", .{temporary.sub_path});
        defer std.testing.allocator.free(path);
        const resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 1, .readers = 2, .io_mode = .standard });
        defer resources.deinit();
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .resources = resources, .io_mode = .standard, .maximum_wal_pages = 64, .checkpoint_bytes = 64 });
        defer store.deinit();
        const space = try store.openSpace("pages");
        var ids: [2]storage.PageId = undefined;
        try space.allocatePages(&ids);
        const first: storage.Page = @splat(11);
        const second: storage.Page = @splat(22);
        try space.writePages(&.{ .{ .id = ids[0], .source = &first }, .{ .id = ids[1], .source = &second } });
        try store.waitDurable(try store.commit(1));
        var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
        defer disk.deinit();
        const modeled = disk.interface();
        defer disk.detach();
        store.bindIo(modeled);
        const staged: storage.Page = @splat(33);
        try space.writePages(&.{.{ .id = ids[0], .source = &staged }});
        if (rotate) {
            var steps: usize = 0;
            while (store.phase != .replacement_copy) : (steps += 1) {
                if (steps == 1024) return error.MaintenanceStalled;
                _ = try store.pollMaintenance(.{ .index_entries = 16, .pages = 16 });
            }
        }
        var warm: storage.Page = undefined;
        try space.readPages(&.{.{ .id = ids[1], .destination = &warm }});
        const offset = store.locations.get(@backingInt(ids[0])).?.current;
        var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset + 32 };
        disk.read_gate = &gate;
        defer disk.read_gate = null;
        var reader: Reader = .{ .space = space, .id = ids[0], .gate = &gate };
        const background = try std.Thread.spawn(.{}, Reader.run, .{&reader});
        var joined = false;
        defer if (!joined) {
            gate.release.set(io);
            background.join();
        };
        try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        try std.testing.expectEqual(@as(usize, 1), store.inflight_reads);
        if (rotate) {
            var steps: usize = 0;
            while (store.phase != .replacement_rename) : (steps += 1) {
                if (steps == 1024) return error.MaintenanceStalled;
                _ = try store.pollMaintenance(.{ .index_entries = 16, .pages = 16 });
            }
            try std.testing.expectEqual(@as(usize, 1), store.retired_reads);
            try std.testing.expectEqual(.pending, try store.pollMaintenance(.{ .index_entries = 16, .pages = 16 }));
            try std.testing.expect(store.retired_wal != null);
        }
        var foreground: Foreground = .{ .space = space, .ids = ids };
        const worker = try std.Thread.spawn(.{}, Foreground.run, .{&foreground});
        var worker_joined = false;
        defer if (!worker_joined) {
            gate.release.set(io);
            worker.join();
        };
        try foreground.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
        worker.join();
        worker_joined = true;
        try foreground.result;
        if (!rotate) try std.testing.expect(store.locations.get(@backingInt(ids[0])).?.current != offset);
        if (rotate) {
            try std.testing.expectEqual(@as(u64, 1), store.durableTick());
            const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .clock = .awake, .raw = .fromMilliseconds(10) });
            try std.testing.expectError(error.Timeout, store.waitDurableUntil(store.lastCommit(), deadline));
            try std.testing.expectEqual(@as(usize, 1), store.retired_reads);
            try std.testing.expectEqual(@as(u64, 1), store.durableTick());
        }
        gate.release.set(io);
        background.join();
        joined = true;
        try reader.result;
        try std.testing.expectEqualSlices(u8, &staged, &reader.bytes);
        try std.testing.expectEqual(@as(usize, 0), store.inflight_reads);
        try std.testing.expectEqual(@as(usize, 0), store.retired_reads);
        try store.waitDurable(store.lastCommit());
        try std.testing.expectEqual(@as(u64, 2), store.durableTick());
        var actual: storage.Page = undefined;
        try space.readPages(&.{.{ .id = ids[0], .destination = &actual }});
        try std.testing.expect(std.mem.allEqual(u8, &actual, 44));
    }
}

test "a paused page overwrite blocks only its cold dependents and not unrelated reads" {
    const Writer = struct {
        space: storage.Space,
        id: storage.PageId,
        gate: *fault.Disk.IoGate,
        result: storage.Error!void = {},
        fn run(self: *@This()) void {
            self.gate.thread.store(std.Thread.getCurrentId(), .release);
            const bytes: storage.Page = @splat(44);
            self.result = self.space.writePages(&.{.{ .id = self.id, .source = &bytes }});
        }
    };
    const Reader = struct {
        space: storage.Space,
        ids: []const storage.PageId,
        expected: []const u8,
        poll: ?*storage.Store = null,
        entered: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        result: anyerror!void = {},
        fn run(self: *@This()) void {
            self.entered.set(std.testing.io);
            self.result = self.execute();
            self.done.set(std.testing.io);
        }
        fn execute(self: *@This()) !void {
            for (self.ids, self.expected) |id, expected| {
                var bytes: storage.Page = undefined;
                try self.space.readPages(&.{.{ .id = id, .destination = &bytes }});
                try std.testing.expect(std.mem.allEqual(u8, &bytes, expected));
            }
            if (self.poll) |store| {
                try store.progress();
                try std.testing.expectEqual(storage.MaintenanceResult.pending, try store.pollMaintenance(.{ .index_entries = 32, .pages = 32 }));
            }
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/write-pipeline", .{temporary.sub_path});
    defer std.testing.allocator.free(path);
    const resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 1, .readers = 2, .io_mode = .standard });
    defer resources.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard, .resources = resources });
    defer store.deinit();
    const space = try store.openSpace("pages");
    var ids: [3]storage.PageId = undefined;
    try space.allocatePages(&ids);
    for (ids, [_]u8{ 11, 22, 55 }) |id, value| {
        const bytes: storage.Page = @splat(value);
        try space.writePages(&.{.{ .id = id, .source = &bytes }});
    }
    var warm: storage.Page = undefined;
    try space.readPages(&.{.{ .id = ids[1], .destination = &warm }});
    const offset = store.locations.get(@backingInt(ids[0])).?.current;
    var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
    defer disk.deinit();
    const modeled = disk.interface();
    defer disk.detach();
    store.bindIo(modeled);
    var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset };
    disk.write_gate = &gate;
    var writer: Writer = .{ .space = space, .id = ids[0], .gate = &gate };
    const writing = try std.Thread.spawn(.{}, Writer.run, .{&writer});
    defer writing.join();
    defer gate.release.set(io);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var dependent: Reader = .{ .space = space, .ids = ids[0..1], .expected = &.{44} };
    const waiting = try std.Thread.spawn(.{}, Reader.run, .{&dependent});
    defer waiting.join();
    defer gate.release.set(io);
    try dependent.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var independent: Reader = .{ .space = space, .ids = ids[1..], .expected = &.{ 22, 55 }, .poll = &store };
    const reading = try std.Thread.spawn(.{}, Reader.run, .{&independent});
    defer reading.join();
    defer gate.release.set(io);
    try independent.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try independent.result;
    try std.testing.expect(!dependent.done.isSet());
    gate.release.set(io);
    try dependent.done.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    try dependent.result;
}

test "page ownership checks submit a batch and free groups survive partial allocation and reopen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/batch-contract", .{temporary.sub_path});
    defer allocator.free(path);
    var registry = try metrics.Registry.init(allocator, io, .{});
    defer registry.deinit();
    const options: storage.Store.Options = .{ .path = path, .metrics = &registry, .io_mode = .standard, .checkpoint_bytes = 64, .maximum_wal_pages = 128 };
    var store = try storage.Store.init(allocator, io, options);
    defer store.deinit();
    const space = try store.openSpace("batch");
    var ids: [64]storage.PageId = undefined;
    try space.allocatePages(&ids);
    var writes: [64]storage.Write = undefined;
    for (&writes, ids) |*write, id| write.* = .{ .id = id, .source = "initial" };
    try space.writePages(&writes);
    try store.waitDurable(try store.commit(1));
    while (true) {
        const state = try store.pollMaintenance(.{ .index_entries = 128, .pages = 32 });
        if (state == .idle) break;
        if (store.maintenance_io.active) try store.maintenance_io.wait(null);
    }
    store.resources.cache_index.clearRetainingCapacity();
    const before = store.read_batches.value();
    for (&writes) |*write| write.source = "updated";
    try space.writePages(&writes);
    try std.testing.expectEqual(@as(u64, 2), store.read_batches.value() - before);
    try space.freePages(&ids);
    try store.waitDurable(try store.commit(2));
    var first: [7]storage.PageId = undefined;
    try space.allocatePages(&first);
    try std.testing.expectEqual(@as(u64, 57), store.metadata.free_pages);
    try store.waitDurable(try store.commit(3));
    store.deinit();
    store = try storage.Store.init(allocator, io, options);
    try std.testing.expectEqual(@as(u64, 57), store.metadata.free_pages);
    var rest: [57]storage.PageId = undefined;
    const restored = try store.openSpace("batch");
    try restored.allocatePages(&rest);
    var seen: [65]bool = @splat(false);
    for (first) |id| {
        try std.testing.expect(!seen[@backingInt(id)]);
        seen[@backingInt(id)] = true;
    }
    for (rest) |id| {
        try std.testing.expect(!seen[@backingInt(id)]);
        seen[@backingInt(id)] = true;
    }
    try std.testing.expect(std.mem.allEqual(bool, seen[1..], true));
    try std.testing.expectEqual(@as(u64, 65), store.metadata.pages);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.free);
    try std.testing.expectEqual(@as(u16, 0), store.metadata.free_count);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.free_pages);
}

test "native maintenance completes from I/O notifications without simulation polling" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/maintenance-worker", .{directory.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .maximum_wal_pages = 256, .checkpoint_bytes = 64 });
    defer store.deinit();
    const space = try store.openSpace("pages");
    var ids: [64]storage.PageId = undefined;
    try space.allocatePages(&ids);
    var maintenance: storage.Maintenance = .{ .store = &store };
    try maintenance.start();
    defer maintenance.stop();
    for (1..3) |tick| {
        if (tick == 2) {
            maintenance.stop();
            try maintenance.start();
        }
        const bytes: storage.Page = @splat(@intCast(36 + tick));
        var writes: [64]storage.Write = undefined;
        for (ids, &writes) |id, *write| write.* = .{ .id = id, .source = &bytes };
        try space.writePages(&writes);
        try store.submitSync(try store.commit(tick));
        const deadline = std.Io.Clock.now(.awake, io).nanoseconds + 10 * std.time.ns_per_s;
        while (true) {
            try maintenance.check();
            const status = store.maintenanceStatus();
            if (!status.pending and @backingInt(status.checkpointed) == tick) break;
            if (std.Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.MaintenanceStalled;
            std.Thread.yield() catch {};
        }
        var actual: storage.Page = undefined;
        try space.readPages(&.{.{ .id = ids[63], .destination = &actual }});
        try std.testing.expectEqualSlices(u8, &bytes, &actual);
    }
    maintenance.stop();
    const raw = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(raw));
    const gate: std.Io.File = .{ .handle = @intCast(raw), .flags = .{ .nonblocking = false } };
    defer gate.close(io);
    var received: u64 = 0;
    const sent: u64 = 1;
    try store.maintenance_io.submit(&.{.{ .read = .{ .file = gate, .offset = 0, .bytes = std.mem.asBytes(&received) } }});
    defer {
        _ = std.os.linux.write(gate.handle, std.mem.asBytes(&sent).ptr, @sizeOf(u64));
        store.maintenance_io.drain() catch {};
    }
    try maintenance.start();
    maintenance.stop();
    try std.testing.expect(store.maintenance_io.active);
    try std.testing.expectEqual(@sizeOf(u64), std.os.linux.write(gate.handle, std.mem.asBytes(&sent).ptr, @sizeOf(u64)));
    try store.maintenance_io.drain();
    try std.testing.expectEqual(sent, received);
}

test "cache misses and read completions each notify a blocked maintenance owner" {
    const Reader = struct {
        space: storage.Space,
        id: storage.PageId,
        gate: *fault.Disk.IoGate,
        bytes: storage.Page = undefined,
        result: storage.Error!void = {},
        fn run(self: *@This()) void {
            self.gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.space.readPages(&.{.{ .id = self.id, .destination = &self.bytes }});
        }
    };
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/read-notifications", .{directory.sub_path});
    defer std.testing.allocator.free(path);
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = .standard, .maximum_wal_pages = 64 });
    defer store.deinit();
    const space = try store.openSpace("pages");
    var ids: [1]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const bytes: storage.Page = @splat(41);
    try space.writePages(&.{.{ .id = ids[0], .source = &bytes }});
    try store.waitDurable(try store.commit(1));
    const offset = store.locations.get(@backingInt(ids[0])).?.current + 32;
    var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
    defer disk.deinit();
    defer disk.detach();
    store.bindIo(disk.interface());
    store.resources.cache_index.clearRetainingCapacity();
    const raw = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    try std.testing.expectEqual(.SUCCESS, std.os.linux.errno(raw));
    const wake: std.Io.File = .{ .handle = @intCast(raw), .flags = .{ .nonblocking = true } };
    defer wake.close(io);
    var owner: storage.Maintenance = .{ .store = &store, .wake = wake.handle, .blocked = .init(true) };
    store.resources.background.store(&owner, .release);
    defer store.resources.background.store(null, .release);
    var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset };
    disk.read_gate = &gate;
    var reader: Reader = .{ .space = space, .id = ids[0], .gate = &gate };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        gate.release.set(io);
        thread.join();
    };
    try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var count: u64 = 0;
    try std.testing.expectEqual(@sizeOf(u64), std.os.linux.read(wake.handle, std.mem.asBytes(&count).ptr, @sizeOf(u64)));
    owner.notified.store(false, .release);
    gate.release.set(io);
    thread.join();
    joined = true;
    try reader.result;
    try std.testing.expectEqualSlices(u8, &bytes, &reader.bytes);
    try std.testing.expectEqual(@sizeOf(u64), std.os.linux.read(wake.handle, std.mem.asBytes(&count).ptr, @sizeOf(u64)));
    owner.notified.store(false, .release);
    var cached: storage.Page = undefined;
    try space.readPages(&.{.{ .id = ids[0], .destination = &cached }});
    try std.testing.expectEqualSlices(u8, &bytes, &cached);
    try std.testing.expectEqual(@sizeOf(u64), std.os.linux.read(wake.handle, std.mem.asBytes(&count).ptr, @sizeOf(u64)));
    try std.testing.expect(store.mutex.tryLock());
    store.mutex.unlock(io);
    try std.testing.expect(store.resources.mutex.tryLock());
    store.resources.mutex.unlock(io);
}

test "cache indexing preserves database identity and pinned versions under sealed churn" {
    const io = std.testing.io;
    for ([_]usize{ 1, 2, 7 }) |capacity| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var paths: [2][256]u8 = undefined;
        var memory = storage.system.Memory.init(std.testing.allocator, io);
        defer memory.deinit();
        const allocator = memory.allocator("cache");
        const resources = try storage.Resources.init(allocator, io, .{ .cache_pages = capacity, .io_mode = .standard });
        defer resources.deinit();
        var stores: [2]storage.Store = undefined;
        var initialized: usize = 0;
        defer for (stores[0..initialized]) |*store| store.deinit();
        var spaces: [2]storage.Space = undefined;
        var ids: [2][16]storage.PageId = undefined;
        var expected: [2][16]u8 = .{ @splat(0), @splat(1) };
        for (&stores, &spaces, &paths, &ids, 0..) |*store, *space, *path_buffer, *page, index| {
            const path = try std.fmt.bufPrint(path_buffer, ".zig-cache/tmp/{s}/cache-{d}", .{ temporary.sub_path, index });
            store.* = try storage.Store.init(allocator, io, .{ .path = path, .resources = resources, .io_mode = .standard, .maximum_wal_pages = 128 });
            initialized += 1;
            space.* = try store.openSpace("pages");
            try space.allocatePages(page);
            for (page) |id| try space.writePages(&.{.{ .id = id, .source = &.{@intCast(index)} }});
        }
        try std.testing.expectEqual(ids[0][0], ids[1][0]);
        const assigned = memory.assigned_bytes;
        memory.seal();
        for (0..128) |pass| {
            const index = pass % spaces.len;
            const space = spaces[index];
            const target = (pass / spaces.len) % ids[index].len;
            var pinned: [1]storage.PageLease = undefined;
            try space.borrowPages(ids[index][target..][0..1], &pinned);
            try std.testing.expect(!resources.cache[pinned[0].index].available);
            const previous = pinned[0].bytes()[0];
            const value: [1]u8 = .{@intCast(pass + 2)};
            try space.writePages(&.{.{ .id = ids[index][target], .source = &value }});
            expected[index][target] = value[0];
            try std.testing.expectEqual(previous, pinned[0].bytes()[0]);
            var output: [1]u8 = undefined;
            try space.readPages(&.{.{ .id = ids[index][target], .destination = &output }});
            try std.testing.expectEqualSlices(u8, &value, &output);
            storage.PageLease.releaseMany(&pinned);
            for (spaces, ids, expected) |other, pages, values| {
                for (pages, values) |id, byte| {
                    try other.readPages(&.{.{ .id = id, .destination = &output }});
                    try std.testing.expectEqual(byte, output[0]);
                }
            }
            var seen: [7]bool = @splat(false);
            var next = resources.oldest;
            var previous_slot: ?usize = null;
            while (next) |slot| {
                try std.testing.expect(!seen[slot]);
                seen[slot] = true;
                const entry = &resources.cache[slot];
                try std.testing.expectEqual(previous_slot, entry.previous);
                try std.testing.expect(entry.available and !entry.reading and entry.pins.load(.monotonic) == 0);
                previous_slot = slot;
                next = entry.next;
            }
            try std.testing.expectEqual(previous_slot, resources.newest);
            var indexed = resources.cache_index.iterator();
            while (indexed.next()) |mapping| {
                const entry = resources.cache[mapping.value_ptr.*];
                try std.testing.expect(entry.loaded);
                try std.testing.expectEqual(mapping.key_ptr.token, entry.token);
                try std.testing.expectEqual(mapping.key_ptr.id, entry.id);
            }
            for (resources.cache, 0..) |entry, slot| {
                try std.testing.expectEqual(entry.available, seen[slot]);
                try std.testing.expect(entry.available);
            }
        }
        try std.testing.expectEqual(assigned, memory.assigned_bytes);
    }
}

test "concurrent cache publication preserves both leases and indexes the current version" {
    const Reader = struct {
        space: storage.Space,
        id: storage.PageId,
        gate: *fault.Disk.IoGate,
        leases: [1]storage.PageLease = undefined,
        result: storage.Error!void = {},

        fn run(self: *@This()) void {
            self.gate.thread.store(std.Thread.getCurrentId(), .release);
            self.result = self.space.borrowPages(&.{self.id}, &self.leases);
        }
    };
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/concurrent-publication", .{temporary.sub_path});
    const resources = try storage.Resources.init(std.testing.allocator, io, .{ .cache_pages = 2, .readers = 2, .io_mode = .standard });
    defer resources.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .resources = resources, .io_mode = .standard, .maximum_wal_pages = 64 });
    defer store.deinit();
    const space = try store.openSpace("pages");
    var ids: [1]storage.PageId = undefined;
    try space.allocatePages(&ids);
    const first: storage.Page = @splat(17);
    try space.writePages(&.{.{ .id = ids[0], .source = &first }});
    try store.waitDurable(try store.commit(1));
    resources.cache_index.clearRetainingCapacity();
    var disk = try fault.Disk.init(std.testing.allocator, io, &.{ store.database, store.wal }, std.math.maxInt(usize), false);
    defer disk.deinit();
    store.bindIo(disk.interface());
    defer disk.detach();
    const offset = store.locations.get(@backingInt(ids[0])).?.current;
    var gate: fault.Disk.IoGate = .{ .file = store.wal, .offset = offset + 32 };
    disk.read_gate = &gate;
    defer disk.read_gate = null;
    var reader: Reader = .{ .space = space, .id = ids[0], .gate = &gate };
    const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var joined = false;
    defer if (!joined) {
        gate.release.set(io);
        thread.join();
        if (reader.result) |_| storage.PageLease.releaseMany(&reader.leases) else |_| {}
    };
    try gate.entered.waitTimeout(io, .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(5) } });
    var foreground: [1]storage.PageLease = undefined;
    try space.borrowPages(&ids, &foreground);
    defer storage.PageLease.releaseMany(&foreground);
    gate.release.set(io);
    thread.join();
    joined = true;
    try reader.result;
    defer storage.PageLease.releaseMany(&reader.leases);
    try std.testing.expect(foreground[0].index != reader.leases[0].index);
    try std.testing.expectEqualSlices(u8, &first, foreground[0].bytes());
    try std.testing.expectEqualSlices(u8, &first, reader.leases[0].bytes());
    try std.testing.expectEqual(@as(usize, 1), resources.cache_index.count());
    const second: storage.Page = @splat(29);
    try space.writePages(&.{.{ .id = ids[0], .source = &second }});
    var actual: storage.Page = undefined;
    try space.readPages(&.{.{ .id = ids[0], .destination = &actual }});
    try std.testing.expectEqualSlices(u8, &second, &actual);
    try std.testing.expectEqualSlices(u8, &first, foreground[0].bytes());
    try std.testing.expectEqualSlices(u8, &first, reader.leases[0].bytes());
}
