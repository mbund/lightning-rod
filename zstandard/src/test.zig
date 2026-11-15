const std = @import("std");
const zstandard = @import("zstandard");

test "static contexts reuse bounded memory and reject corrupt frames" {
    var encoder = try zstandard.Compressor.init(std.testing.allocator, 6, 32768);
    defer encoder.deinit();
    var decoder = try zstandard.Decompressor.init(std.testing.allocator);
    defer decoder.deinit();
    var source: [32768]u8 = undefined;
    var random = std.Random.DefaultPrng.init(20261031);
    random.random().bytes(&source);
    const encoded = try std.testing.allocator.alloc(u8, zstandard.bound(source.len));
    defer std.testing.allocator.free(encoded);
    var restored: [32768]u8 = undefined;
    for ([_]usize{ 0, 1, 127, 128, 129, 4096, 32768 }) |length| {
        const frame = try encoder.encode(source[0..length], encoded);
        try std.testing.expectEqual(length, try zstandard.decodedBound(frame, restored.len));
        try std.testing.expectEqualSlices(u8, source[0..length], try decoder.decode(frame, &restored));
        if (length != 0) {
            try std.testing.expectError(error.BufferTooSmall, zstandard.decodedBound(frame, length - 1));
            try std.testing.expectError(error.BufferTooSmall, decoder.decode(frame, restored[0 .. length - 1]));
        }
        for (0..frame.len) |truncated| {
            if (decoder.decode(frame[0..truncated], &restored)) |_| return error.AcceptedTruncation else |_| {}
        }
        encoded[frame.len - 1] ^= 1;
        try std.testing.expectError(error.Corrupt, decoder.decode(frame, &restored));
    }
    try std.testing.expectError(error.BufferTooSmall, encoder.encode(&source, encoded[0..1]));
    const retry = try encoder.encode(&source, encoded);
    try std.testing.expectEqualSlices(u8, &source, try decoder.decode(retry, &restored));
    try std.testing.expectError(error.InvalidArgument, encoder.encode(encoded, encoded));
}

test "compression never allocates after context initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var encoder = try zstandard.Compressor.init(allocator, 6, 32768);
    defer encoder.deinit();
    var decoder = try zstandard.Decompressor.init(allocator);
    defer decoder.deinit();
    const encoded = try allocator.alloc(u8, zstandard.bound(32768));
    defer allocator.free(encoded);
    failing.fail_index = failing.alloc_index;
    const source: [32768]u8 = @splat(17);
    var restored: [32768]u8 = undefined;
    for (0..10) |_| {
        const frame = try encoder.encode(&source, encoded);
        try std.testing.expectEqualSlices(u8, &source, try decoder.decode(frame, &restored));
    }
    try std.testing.expectEqual(failing.fail_index, failing.alloc_index);
}

test "borrowed encoders alternate parameters without changing frames or allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const maximum = 534000;
    const smaller = 177000;
    var owner = try zstandard.Compressor.init(allocator, 6, maximum);
    defer owner.deinit();
    var reference = try zstandard.Compressor.init(allocator, 6, smaller);
    defer reference.deinit();
    const shared = try owner.borrow(6, smaller);
    const source = try allocator.alloc(u8, maximum);
    defer allocator.free(source);
    const encoded = try allocator.alloc(u8, zstandard.bound(maximum));
    defer allocator.free(encoded);
    const expected = try allocator.alloc(u8, encoded.len);
    defer allocator.free(expected);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var random = std.Random.DefaultPrng.init(0x61a900);
    for ([_]bool{ false, true }) |incompressible| {
        if (incompressible) random.random().bytes(source) else for (source, 0..) |*byte, index| {
            byte.* = @truncate(index / 128 % 7);
        }
        const original = try owner.encode(source, expected);
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(original, &hash, .{});
        for ([_]usize{ 0, 1, 8192, 131072, smaller }) |length| {
            const independent = try reference.encode(source[0..length], expected);
            const borrowed = try shared.encode(source[0..length], encoded);
            try std.testing.expectEqualSlices(u8, independent, borrowed);
            const restored = try owner.encode(source, encoded);
            var after: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(restored, &after, .{});
            try std.testing.expectEqualSlices(u8, &hash, &after);
        }
        try std.testing.expectError(error.BufferTooSmall, shared.encode(source[0..smaller], encoded[0..1]));
        _ = try owner.encode(source, encoded);
        try std.testing.expectError(error.BufferTooSmall, owner.encode(source, encoded[0..1]));
        const independent = try reference.encode(source[0..smaller], expected);
        try std.testing.expectEqualSlices(u8, independent, try shared.encode(source[0..smaller], encoded));
    }
    try std.testing.expectError(error.InvalidArgument, shared.encode(source, encoded));
    try std.testing.expectError(error.InvalidArgument, owner.borrow(6, maximum + 1));
    try std.testing.expectError(error.InvalidArgument, owner.borrow(0, smaller));
    try std.testing.expect(!failing.has_induced_failure);
}

test "suffix decompression uses overlap space and falls back for dense frames without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    const maximum = 32768;
    var encoder = try zstandard.Compressor.init(allocator, 6, maximum);
    defer encoder.deinit();
    var decoder = try zstandard.Decompressor.init(allocator);
    defer decoder.deinit();
    const bound = zstandard.bound(maximum);
    const encoded = try allocator.alloc(u8, bound);
    defer allocator.free(encoded);
    const guarded = try allocator.alloc(u8, bound + 128);
    defer allocator.free(guarded);
    const scratch = try allocator.alloc(u8, bound);
    defer allocator.free(scratch);
    var source: [maximum]u8 = undefined;
    var random = std.Random.DefaultPrng.init(0x908f21);
    random.random().bytes(&source);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for ([_]usize{ 0, 1, 127, 4096, maximum }) |length| {
        const frame = try encoder.encode(source[0..length], encoded);
        @memset(guarded, 0xa7);
        @memset(scratch, 0x5a);
        const buffer = guarded[64..][0..bound];
        @memcpy(buffer[buffer.len - frame.len ..], frame);
        const decoded = try decoder.decodeSuffix(buffer, frame.len, maximum, scratch);
        try std.testing.expectEqualSlices(u8, source[0..length], decoded);
        try std.testing.expect(std.mem.allEqual(u8, guarded[0..64], 0xa7));
        try std.testing.expect(std.mem.allEqual(u8, guarded[bound + 64 ..], 0xa7));
        if (length <= maximum / 4) {
            try std.testing.expect(std.mem.allEqual(u8, scratch, 0x5a));
        } else try std.testing.expectEqualSlices(u8, frame, scratch[0..frame.len]);

        @memcpy(buffer[buffer.len - frame.len ..], frame);
        if (length != 0) try std.testing.expectError(error.BufferTooSmall, decoder.decodeSuffix(buffer, frame.len, length - 1, scratch));
        buffer[buffer.len - 1] ^= 1;
        try std.testing.expectError(error.Corrupt, decoder.decodeSuffix(buffer, frame.len, maximum, scratch));
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "suffix decompression bounds frames without a declared content size" {
    var decoder = try zstandard.Decompressor.init(std.testing.allocator);
    defer decoder.deinit();
    const frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0, 0, 0x19, 0, 0, 'a', 'b', 'c' };
    const maximum = try zstandard.decodedBound(&frame, 4096);
    try std.testing.expect(maximum >= 3 and maximum <= 4096);
    try std.testing.expectEqual(@as(usize, 2), try zstandard.decodedBound(&frame, 2));
    try std.testing.expectError(error.Corrupt, zstandard.decodedBound(frame[0 .. frame.len - 1], 4096));
    try std.testing.expectError(error.Corrupt, zstandard.decodedBound(&(frame ++ frame), 4096));
    var buffer: [4096]u8 = @splat(0xa7);
    var scratch: [4096]u8 = @splat(0x5a);
    @memcpy(buffer[buffer.len - frame.len ..], &frame);
    const result = try decoder.decodeSuffix(&buffer, frame.len, 4096, &scratch);
    try std.testing.expectEqualStrings("abc", result);
    try std.testing.expect(std.mem.allEqual(u8, &scratch, 0x5a));
}
