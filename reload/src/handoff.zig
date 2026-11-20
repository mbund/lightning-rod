const std = @import("std");
const fields = @import("fields.zig");

/// Opens every handoff and is embedded in every executable that can receive one. Everything after
/// it is tagged fields, so this stays version 1: new state is a new tag, never a new manifest.
pub const manifest: [12]u8 = "LRRESUME".* ++ [_]u8{ 1, 0, 0, 0 };
pub const reply_token_capacity = 256;

/// The handoff's first list: when the old process stopped and who asked for the reload. The
/// sessions' lists follow it.
pub const Header = struct {
    tick: u64,
    started_ns: i96,
    reply_token: []const u8,

    // Released tags; never change what one holds, add a new one.
    const tick_tag: fields.Tag = 1;
    const started_ns_tag: fields.Tag = 2;
    const reply_token_tag: fields.Tag = 3;

    pub fn write(self: Header, writer: *std.Io.Writer) !void {
        if (self.reply_token.len > reply_token_capacity) return error.InvalidResume;
        try writer.writeAll(&manifest);
        try fields.writeInt(writer, tick_tag, u64, self.tick);
        try fields.writeInt(writer, started_ns_tag, i96, self.started_ns);
        try fields.writeBytes(writer, reply_token_tag, self.reply_token);
        try fields.writeEnd(writer);
    }

    pub fn read(reader: *std.Io.Reader, reply_buffer: *[reply_token_capacity]u8) !Header {
        if (!std.mem.eql(u8, try reader.takeArray(manifest.len), &manifest)) return error.InvalidResume;
        var tick: ?u64 = null;
        var started_ns: ?i96 = null;
        var reply_token: []const u8 = &.{};
        var list: fields.Reader = .init(reader);
        while (try list.next()) |field| switch (field.tag) {
            tick_tag => tick = try list.int(field, u64),
            started_ns_tag => started_ns = try list.int(field, i96),
            reply_token_tag => reply_token = try list.bytes(field, reply_buffer),
            else => try list.skip(field),
        };
        return .{ .tick = tick orelse return error.InvalidResume, .started_ns = started_ns orelse return error.InvalidResume, .reply_token = reply_token };
    }
};
