const std = @import("std");
const Cipher = @import("java").Cipher;

test "streams side by side encrypt as each would alone" {
    var random = std.Random.DefaultPrng.init(0x5eed);
    const lengths = [_]usize{ 0, 1, 15, 16, 17, 31, 33, 100, 255, 1, 64, 0, 7, 500, 16, 3, 48, 2, 999, 21 };
    var plain: [lengths.len][1000]u8 = undefined;
    var together: [lengths.len][1000]u8 = undefined;
    var alone: [lengths.len][1000]u8 = undefined;
    var ciphers: [lengths.len]Cipher = undefined;
    var references: [lengths.len]Cipher = undefined;
    var streams: [lengths.len]Cipher.Stream = undefined;
    for (lengths, 0..) |length, index| {
        var secret: [16]u8 = undefined;
        random.random().bytes(&secret);
        random.random().bytes(plain[index][0..length]);
        ciphers[index] = .init(secret);
        references[index] = .init(secret);
        // A stream already part way along.
        var warm: [5]u8 = @splat(@intCast(index));
        references[index].transform(.encrypt, &warm, &warm);
        warm = @splat(@intCast(index));
        ciphers[index].transform(.encrypt, &warm, &warm);
        @memcpy(together[index][0..length], plain[index][0..length]);
        streams[index] = .{ .cipher = &ciphers[index], .bytes = together[index][0..length] };
        references[index].transform(.encrypt, plain[index][0..length], alone[index][0..length]);
    }
    inline for ([_]usize{ 1, 4, 16 }) |lanes| {
        var copies = ciphers;
        var copied: [lengths.len]Cipher.Stream = undefined;
        var buffers = together;
        for (&copied, &copies, &buffers, lengths) |*stream, *cipher, *buffer, length| stream.* = .{ .cipher = cipher, .bytes = buffer[0..length] };
        Cipher.encryptStreamsWith(lanes, &copied);
        for (lengths, 0..) |length, index| {
            try std.testing.expectEqualSlices(u8, alone[index][0..length], buffers[index][0..length]);
            try std.testing.expectEqualSlices(u8, &references[index].feedback, &copies[index].feedback);
        }
    }
    Cipher.encryptStreams(&streams);
    for (lengths, 0..) |length, index| try std.testing.expectEqualSlices(u8, alone[index][0..length], together[index][0..length]);
}
