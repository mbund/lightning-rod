const std = @import("std");
const storage = @import("storage");
const testing = @import("storage_testing");

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
