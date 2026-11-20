const std = @import("std");
const reload = @import("reload");
const fields = reload.fields;

// The released encoding of the header list; new state is a new tag, so these bytes stay valid.
const frozen = "LRRESUME\x01\x00\x00\x00" ++
    "\x01\x00\x08\x00\x00\x00" ++ "\x08\x07\x06\x05\x04\x03\x02\x01" ++
    "\x02\x00\x0c\x00\x00\x00" ++ "\x0c\x0b\x0a\x09\x08\x07\x06\x05\x04\x03\x02\x01" ++
    "\x03\x00\x03\x00\x00\x00" ++ "abc" ++
    "\x00\x00\x00\x00\x00\x00";

test "frozen handoff header writes the released bytes" {
    const header: reload.handoff.Header = .{
        .tick = 0x0102030405060708,
        .started_ns = 0x0102030405060708090a0b0c,
        .reply_token = "abc",
    };
    var buffer: [frozen.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try header.write(&writer);
    try std.testing.expectEqualSlices(u8, frozen, writer.buffered());
}

test "frozen handoff header reads the released bytes without consuming sessions" {
    var reader: std.Io.Reader = .fixed(frozen ++ "sessions");
    var token: [256]u8 = undefined;
    const header = try reload.handoff.Header.read(&reader, &token);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), header.tick);
    try std.testing.expectEqual(@as(i96, 0x0102030405060708090a0b0c), header.started_ns);
    try std.testing.expectEqualSlices(u8, "abc", header.reply_token);
    try std.testing.expectEqualSlices(u8, "sessions", try reader.take(8));
}

test "handoff header skips fields it does not know and requires the tick and start" {
    var token: [256]u8 = undefined;
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll(&reload.handoff.manifest);
    try fields.writeBytes(&writer, 99, "from a newer build");
    try fields.writeInt(&writer, 1, u64, 7);
    try fields.writeInt(&writer, 2, i96, 8);
    try fields.writeEnd(&writer);
    var reader: std.Io.Reader = .fixed(writer.buffered());
    const header = try reload.handoff.Header.read(&reader, &token);
    try std.testing.expectEqual(@as(u64, 7), header.tick);
    try std.testing.expectEqualSlices(u8, "", header.reply_token);

    writer = .fixed(&buffer);
    try writer.writeAll(&reload.handoff.manifest);
    try fields.writeInt(&writer, 2, i96, 8);
    try fields.writeEnd(&writer);
    reader = .fixed(writer.buffered());
    try std.testing.expectError(error.InvalidResume, reload.handoff.Header.read(&reader, &token));
}

test "handoff header rejects truncated headers and other manifests" {
    var token: [256]u8 = undefined;
    for (0..frozen.len) |length| {
        var reader: std.Io.Reader = .fixed(frozen[0..length]);
        try std.testing.expectError(error.EndOfStream, reload.handoff.Header.read(&reader, &token));
    }
    var invalid = frozen.*;
    invalid[8] = 2;
    var reader: std.Io.Reader = .fixed(&invalid);
    try std.testing.expectError(error.InvalidResume, reload.handoff.Header.read(&reader, &token));
}

test "handoff header accepts empty and maximum reply tokens" {
    const bytes: [256]u8 = @splat(0x81);
    for ([_]usize{ 0, 256 }) |length| {
        const header: reload.handoff.Header = .{ .tick = 1, .started_ns = 2, .reply_token = bytes[0..length] };
        var buffer: [128 + 256]u8 = undefined;
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
