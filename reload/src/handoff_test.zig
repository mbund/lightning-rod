const std = @import("std");
const reload = @import("reload");

const frozen_v11 = "LRRESUME\x0b\x00\x00\x00\x01\x00\x00\x00" ++
    "\x08\x07\x06\x05\x04\x03\x02\x01" ++
    "\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01" ++
    "\x03\x00abc";

test "frozen v11 handoff header writes the established bytes" {
    const header: reload.handoff.Header = .{
        .tick = 0x0102030405060708,
        .started_ns = 0x0102030405060708090a0b0c,
        .reply_token = "abc",
    };
    var buffer: [frozen_v11.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try header.write(&writer);
    try std.testing.expectEqualSlices(u8, frozen_v11, writer.buffered());
}

test "frozen v11 handoff header reads the established bytes without consuming sessions" {
    var reader: std.Io.Reader = .fixed(frozen_v11 ++ "sessions");
    var token: [256]u8 = undefined;
    const header = try reload.handoff.Header.read(&reader, &token);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), header.tick);
    try std.testing.expectEqual(@as(i96, 0x0102030405060708090a0b0c), header.started_ns);
    try std.testing.expectEqualSlices(u8, "abc", header.reply_token);
    try std.testing.expectEqualSlices(u8, "sessions", try reader.take(8));
}

test "handoff header rejects truncated and incompatible headers" {
    var token: [256]u8 = undefined;
    for (0..frozen_v11.len) |length| {
        var reader: std.Io.Reader = .fixed(frozen_v11[0..length]);
        try std.testing.expectError(error.EndOfStream, reload.handoff.Header.read(&reader, &token));
    }
    var invalid = frozen_v11.*;
    invalid[8] = 10;
    var reader: std.Io.Reader = .fixed(&invalid);
    try std.testing.expectError(error.InvalidResume, reload.handoff.Header.read(&reader, &token));
    invalid = frozen_v11.*;
    invalid[36..38].* = .{ 1, 1 };
    reader = .fixed(&invalid);
    try std.testing.expectError(error.InvalidResume, reload.handoff.Header.read(&reader, &token));
}

test "handoff header accepts empty and maximum reply tokens" {
    const bytes: [256]u8 = @splat(0x81);
    for ([_]usize{ 0, 256 }) |length| {
        const header: reload.handoff.Header = .{ .tick = 1, .started_ns = 2, .reply_token = bytes[0..length] };
        var buffer: [38 + 256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try header.write(&writer);
        var reader: std.Io.Reader = .fixed(writer.buffered());
        var token: [256]u8 = undefined;
        const restored = try reload.handoff.Header.read(&reader, &token);
        try std.testing.expectEqualSlices(u8, bytes[0..length], restored.reply_token);
    }
    const oversized: [257]u8 = @splat(0);
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const header: reload.handoff.Header = .{ .tick = 1, .started_ns = 2, .reply_token = &oversized };
    try std.testing.expectError(error.InvalidResume, header.write(&writer));
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
}
