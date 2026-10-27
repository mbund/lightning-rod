const std = @import("std");
const storage = @import("storage");
const environment = @import("environment.zig");

fn databaseHash(seed: u64) ![32]u8 {
    var state = try environment.Environment.init("replay", seed);
    defer state.deinit();
    const io = state.io();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = state.path, .maximum_wal_pages = 128, .io_mode = .standard });
    defer store.deinit();
    const space = try store.openSpace("replay");
    var ids: [2]storage.PageId = undefined;
    try space.allocatePages(&ids);
    try space.setRoot(ids[0]);
    var page: storage.Page = undefined;
    io.random(&page);
    try space.writePages(&.{ .{ .id = ids[0], .source = &page }, .{ .id = ids[1], .source = &page } });
    try store.waitDurable(try store.commit(1));
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var path_buffer: [256]u8 = undefined;
    for ([_][]const u8{ "", ".wal" }) |suffix| {
        const path = try std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ state.path, suffix });
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const length = try file.readPositionalAll(io, &buffer, offset);
            hash.update(buffer[0..length]);
            if (length < buffer.len) break;
            offset += length;
        }
    }
    return hash.finalResult();
}

test "database bytes replay independently of preceding inputs" {
    const first = try databaseHash(42);
    const other = try databaseHash(43);
    const replay = try databaseHash(42);
    try std.testing.expectEqualSlices(u8, &first, &replay);
    try std.testing.expect(!std.mem.eql(u8, &first, &other));
}

test "clock and entropy reset with each input" {
    var expected: [32]u8 = undefined;
    {
        var state = try environment.Environment.init("clock", 12);
        defer state.deinit();
        state.io().random(&expected);
    }
    var state = try environment.Environment.init("clock", 12);
    defer state.deinit();
    var actual: [32]u8 = undefined;
    try state.io().randomSecure(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(i96, 1), std.Io.Clock.awake.now(state.io()).nanoseconds);
    try state.io().sleep(.fromMilliseconds(20), .awake);
    try std.testing.expectEqual(@as(i96, 20_000_002), std.Io.Clock.awake.now(state.io()).nanoseconds);
}
