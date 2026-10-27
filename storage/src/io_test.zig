const std = @import("std");
const builtin = @import("builtin");
const backend = @import("io.zig");

test "batched completions preserve read buffers while durability completes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "pages", .{ .read = true });
    defer file.close(io);
    var disk = try backend.Io.init(io, .uring);
    defer disk.deinit();
    var buffers: [backend.maximum_batch][4096]u8 = undefined;
    var writes: [backend.maximum_batch]backend.Io.Write = undefined;
    var reads: [backend.maximum_batch]backend.Io.Read = undefined;
    for (&buffers, &writes, &reads, 0..) |*buffer, *write, *read, index| {
        write.* = .{ .file = file, .offset = index * buffer.len, .bytes = buffer };
        read.* = .{ .file = file, .offset = index * buffer.len, .bytes = buffer };
    }
    for (0..8) |round| {
        for (&buffers, 0..) |*buffer, index| @memset(buffer, @intCast(index + round));
        try disk.writeBatch(&writes);
        try disk.startSync(file);
        for (&buffers) |*buffer| @memset(buffer, 255);
        try disk.read(&reads);
        for (&buffers, 0..) |*buffer, index| try std.testing.expect(std.mem.allEqual(u8, buffer, @intCast(index + round)));
        try disk.wait(null);
        try std.testing.expect(disk.sync_complete and !disk.pending);
    }
}

test "a failed read batch retains all destinations until successful reads complete" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "pages", .{ .read = true });
    defer file.close(io);
    var disk = try backend.Io.init(io, .uring);
    defer disk.deinit();
    const expected: [4096]u8 = @splat(37);
    try disk.write(file, &expected, 0);
    var buffers: [backend.maximum_batch][4096]u8 = @splat(@splat(255));
    var reads: [backend.maximum_batch]backend.Io.Read = undefined;
    for (&reads, &buffers, 0..) |*read, *buffer, index| read.* = .{ .file = if (index == reads.len / 2) .{ .handle = -1, .flags = .{ .nonblocking = false } } else file, .offset = 0, .bytes = buffer };
    try std.testing.expectError(error.IoFailure, disk.read(&reads));
    for (&buffers, 0..) |*buffer, index| {
        if (index == reads.len / 2) continue;
        try std.testing.expectEqualSlices(u8, &expected, buffer);
    }
}
