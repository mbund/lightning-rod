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
        try std.testing.expectEqualSlices(u8, source[0..length], try decoder.decode(frame, &restored));
        if (length != 0) try std.testing.expectError(error.BufferTooSmall, decoder.decode(frame, restored[0 .. length - 1]));
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
