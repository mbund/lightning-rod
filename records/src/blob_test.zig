const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const blob = @import("blob.zig");

test "independent blob indexes and payloads share bounded submissions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/blobs", .{temporary.sub_path});
    var registry = try metrics.Registry.init(allocator, io, .{ .capacity = 64 });
    defer registry.deinit();
    const options: storage.Store.Options = .{ .path = path, .metrics = &registry };
    var store = try storage.Store.init(allocator, io, options);
    defer store.deinit();
    var space = try store.openSpace("blobs");
    var values: [16][6000]u8 = undefined;
    var roots: [16]storage.PageId = undefined;
    var writes: [storage.batch_size]storage.Write = undefined;
    var writing: blob.WriteBatch = .{ .space = space, .writes = &writes };
    for (&values, &roots, 0..) |*value, *root, index| {
        @memset(value, @intCast(index));
        root.* = try writing.write(value);
    }
    try std.testing.expectEqual(@as(usize, 16), writing.count);
    try writing.flush();
    try store.waitDurable(try store.commit(1));
    store.deinit();
    store = try storage.Store.init(allocator, io, options);
    space = try store.openSpace("blobs");
    var reading: blob.ReadBatch = .{ .space = space };
    const before = store.read_batches.value();
    for (&values, 0..) |*value, index| {
        @memset(value, 0xff);
        _ = try reading.appendBlob(roots[roots.len - index - 1], value.len, value);
    }
    try std.testing.expectEqual(before, store.read_batches.value());
    try reading.flush();
    try std.testing.expectEqual(@as(u64, 2), store.read_batches.value() - before);
    for (&values, 0..) |*value, index| try std.testing.expect(std.mem.allEqual(u8, value, @intCast(values.len - index - 1)));
}
