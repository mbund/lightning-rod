const std = @import("std");

// This is a wire ABI across executable replacement. Keep it independent of
// runtime layouts and protect changes with the fixed bytes in handoff_test.zig.
pub const manifest: [16]u8 = "LRRESUME".* ++ [_]u8{ 11, 0, 0, 0, 1, 0, 0, 0 };
pub const reply_token_capacity = 256;

pub const Header = struct {
    tick: u64,
    started_ns: i96,
    reply_token: []const u8,

    pub fn write(self: Header, writer: *std.Io.Writer) !void {
        if (self.reply_token.len > reply_token_capacity) return error.InvalidResume;
        try writer.writeAll(&manifest);
        try writer.writeInt(u64, self.tick, .little);
        try writer.writeInt(i96, self.started_ns, .little);
        try writer.writeInt(u16, @intCast(self.reply_token.len), .little);
        try writer.writeAll(self.reply_token);
    }

    pub fn read(reader: *std.Io.Reader, reply_buffer: *[reply_token_capacity]u8) !Header {
        if (!std.mem.eql(u8, try reader.takeArray(manifest.len), &manifest)) return error.InvalidResume;
        const tick = try reader.takeInt(u64, .little);
        const started_ns = try reader.takeInt(i96, .little);
        const length = try reader.takeInt(u16, .little);
        if (length > reply_buffer.len) return error.InvalidResume;
        const reply_token = reply_buffer[0..length];
        try reader.readSliceAll(reply_token);
        return .{ .tick = tick, .started_ns = started_ns, .reply_token = reply_token };
    }
};
