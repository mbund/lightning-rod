const std = @import("std");
const builtin = @import("builtin");
const backend = @import("io.zig");
const format = @import("format.zig");

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

test "scatter reads coalesce complete pages while preserving every destination boundary" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "scatter", .{ .read = true });
    defer file.close(io);
    var disk = try backend.Io.init(io, .uring);
    defer disk.deinit();
    const expected = try std.testing.allocator.alloc([4096]u8, backend.maximum_batch);
    defer std.testing.allocator.free(expected);
    const scratch = try std.testing.allocator.alloc([4096]u8, expected.len);
    defer std.testing.allocator.free(scratch);
    const outputs = try std.testing.allocator.alloc([4096]u8, expected.len);
    defer std.testing.allocator.free(outputs);
    var reads: [backend.maximum_batch]backend.Io.Read = undefined;
    for (expected, scratch, outputs, &reads, 0..) |*page, *frame, *output, *read, index| {
        for (page, 0..) |*byte, offset| byte.* = @truncate(index * 71 + offset * 13);
        @memset(output, 231);
        const offset = if (index == 0) 0 else index * 97 % 4064;
        const length = if (index == 0) 4064 else @min(index * 35, 4064 - offset);
        read.* = .{ .file = file, .offset = index * 4096, .prefix = frame[0 .. 32 + offset], .bytes = output[11..][0..length], .suffix = frame[32 + offset + length ..] };
    }
    try disk.write(file, std.mem.sliceAsBytes(expected), 0);
    try disk.read(&reads);
    for (reads, expected, outputs) |read, *page, *output| {
        try std.testing.expectEqualSlices(u8, page[0..read.prefix.len], read.prefix);
        try std.testing.expectEqualSlices(u8, page[read.prefix.len..][0..read.bytes.len], read.bytes);
        try std.testing.expectEqualSlices(u8, page[read.prefix.len + read.bytes.len ..], read.suffix);
        try std.testing.expect(std.mem.allEqual(u8, output[0..11], 231));
        try std.testing.expect(std.mem.allEqual(u8, output[11 + read.bytes.len ..], 231));
    }
}

test "split checksum validation matches contiguous pages and detects corruption in every segment" {
    var block: format.Block = undefined;
    var payload: format.Page = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @truncate(index * 11);
    format.seal(&block, 17, 3, 29, &payload);
    try format.validate(&block, 17, 3);
    const saved = block;
    for ([_][2]usize{ .{ 0, 4064 }, .{ 0, 0 }, .{ 1, 1 }, .{ 31, 97 }, .{ 33, 4000 }, .{ 4064, 0 } }) |range| {
        const begin = 32 + range[0];
        const end = begin + range[1];
        try format.validateParts(block[0..begin], block[begin..end], block[end..], 17, 3);
        try std.testing.expectEqualSlices(u8, &saved, &block);
        for ([_]usize{ 0, 24, 32, 2048, 4095 }) |offset| {
            block[offset] ^= 1;
            try std.testing.expectError(error.Corrupt, format.validateParts(block[0..begin], block[begin..end], block[end..], 17, 3));
            block[offset] ^= 1;
            try std.testing.expectEqualSlices(u8, &saved, &block);
        }
    }
}
