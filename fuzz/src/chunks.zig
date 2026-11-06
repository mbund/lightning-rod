const std = @import("std");
const encoding = @import("encoding");

fn fuzzDecode(_: void, smith: *std.testing.Smith) !void {
    var dense: [encoding.maximum_decoded_bytes]u8 = undefined;
    const offset: usize = if (smith.valueWithHash(bool, 8)) encoding.biome_header_bytes else 0;
    dense[0] = if (offset == 0) 1 else 3;
    if (offset != 0) for (0..64) |index| std.mem.writeInt(u16, dense[1 + index * 2 ..][0..2], @intCast(index * 997), .little);
    dense[offset] = 1;
    const dense_length = offset + encoding.dense_block_bytes;
    const count: u16 = 2 + smith.valueWithHash(u11, 1) % 1277;
    var prng = std.Random.DefaultPrng.init(smith.valueWithHash(u64, 2));
    for (0..encoding.blocks) |i| {
        const index: u16 = if (i < count) @intCast(i) else prng.random().int(u16) % count;
        std.mem.writeInt(u16, dense[offset + 1 + i * 2 ..][0..2], index *% 40503 +% 65535, .little);
    }
    var bytes: [encoding.maximum_decoded_bytes]u8 = undefined;
    const encoded = try encoding.encode(dense[0..dense_length], &bytes);
    if (encoded.ptr != bytes[0..].ptr) @memcpy(bytes[0..encoded.len], encoded);
    const length = encoded.len;
    var original = bytes;
    try std.testing.expectEqual(dense_length, try encoding.decode(&original, length));
    try std.testing.expectEqualSlices(u8, dense[0..dense_length], original[0..dense_length]);
    for (0..1 + @as(usize, smith.valueWithHash(u3, 3))) |_| bytes[smith.valueWithHash(u16, 4) % length] ^= smith.valueWithHash(u8, 5);
    const truncated = if (smith.valueWithHash(bool, 6)) smith.valueWithHash(u16, 7) % (length + 1) else length;
    if (encoding.decode(&bytes, truncated)) |decoded| {
        try std.testing.expect(decoded == 3 or decoded == encoding.dense_block_bytes or decoded == encoding.biome_header_bytes + 3 or decoded == encoding.maximum_decoded_bytes);
    } else |err| try std.testing.expectEqual(error.Corrupt, err);
}

test "fuzz section decoder" {
    try std.testing.fuzz({}, fuzzDecode, .{});
}
