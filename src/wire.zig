const std = @import("std");
const protocol_support = @import("protocol_support");

pub const FramedPacket = struct {
    payload: []const u8,
    total_len: usize,
};

/// Returns a zero-copy view of one complete Minecraft frame. Incomplete input
/// is not an error and remains owned by the caller.
pub fn nextPacket(buffer: []const u8) !?FramedPacket {
    if (buffer.len == 0) return null;
    const len, const payload = protocol_support.read_varint(buffer) catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };
    if (len < 0) return error.MalformedPacketLength;
    const payload_len: usize = @intCast(len);
    const prefix_len = buffer.len - payload.len;
    if (payload_len > buffer.len -| prefix_len) return null;
    const total_len = prefix_len + payload_len;
    const framed = FramedPacket{ .payload = buffer[prefix_len..total_len], .total_len = total_len };
    std.debug.assert(framed.total_len <= buffer.len);
    std.debug.assert(framed.payload.len == payload_len);
    return framed;
}

test "framing is zero copy and incremental" {
    const bytes = [_]u8{ 3, 1, 2, 3, 2, 4, 5 };
    try std.testing.expectEqual(null, try nextPacket(bytes[0..3]));
    const first = (try nextPacket(&bytes)).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, first.payload);
    try std.testing.expectEqual(@as(usize, 4), first.total_len);
    const second = (try nextPacket(bytes[first.total_len..])).?;
    try std.testing.expectEqualSlices(u8, &.{ 4, 5 }, second.payload);
}
