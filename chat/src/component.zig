//! Text components, as chat lines are made of: runs of text, each with its own color and style,
//! hover text and click action. A component is written as the network NBT clients read, and keeps
//! its plain text beside it, which is what a client compares with a signed message.
const std = @import("std");
const assert = std.debug.assert;

pub const Click = union(enum) {
    run_command: []const u8,
    suggest_command: []const u8,
    open_url: []const u8,
    copy_to_clipboard: []const u8,
};

pub const Style = struct {
    /// A named color, such as "gold", or "#rrggbb".
    color: ?[]const u8 = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underlined: ?bool = null,
    strikethrough: ?bool = null,
    obfuscated: ?bool = null,
    /// What shift-clicking the text puts in the chat box.
    insertion: ?[]const u8 = null,
    click: ?Click = null,
    /// Plain text shown on hovering.
    hover: ?[]const u8 = null,
};

/// Builds a component of text runs into a caller's buffer. Text runs are kept in order as the
/// component's `extra`, below an empty root, as vanilla composes them.
pub const Component = struct {
    pub const Error = error{ComponentTooLarge};

    buffer: []u8,
    end: usize = 0,
    plain: []u8,
    plain_len: usize = 0,
    runs: u32 = 0,
    /// Where the count of runs goes, once there are any.
    count_at: usize = 0,

    /// A component writing into `buffer`, keeping its plain text in `plain`.
    pub fn init(buffer: []u8, plain_buffer: []u8) Component {
        return .{ .buffer = buffer, .plain = plain_buffer };
    }

    pub fn empty(self: *const Component) bool {
        return self.runs == 0;
    }

    /// Appends a run of text.
    pub fn text(self: *Component, value: []const u8, style: Style) Error!void {
        assert(self.end <= self.buffer.len and self.plain_len <= self.plain.len);
        assert(self.runs == 0 or self.count_at + 4 <= self.end);
        if (self.plain.len - self.plain_len < value.len) return error.ComponentTooLarge;
        var writer = std.Io.Writer.fixed(self.buffer[self.end..]);
        writeRun(&writer, self.runs == 0, value, style) catch return error.ComponentTooLarge;
        if (self.runs == 0) self.count_at = self.end + header.len;
        self.end += writer.end;
        @memcpy(self.plain[self.plain_len..][0..value.len], value);
        self.plain_len += value.len;
        self.runs += 1;
        assert(self.end <= self.buffer.len and self.plain_len <= self.plain.len);
    }

    /// The component's network NBT, or null if nothing was written.
    pub fn bytes(self: *Component) Error!?[]const u8 {
        if (self.runs == 0) return null;
        // The count follows the root's header, which the first run wrote.
        assert(self.count_at == header.len and self.end > self.count_at + 4);
        if (self.buffer.len - self.end < 2) return error.ComponentTooLarge;
        std.mem.writeInt(i32, self.buffer[self.count_at..][0..4], @intCast(self.runs), .big);
        // The end of the list's last run is written with it; the list and root close here.
        self.buffer[self.end] = 0;
        return self.buffer[0 .. self.end + 1];
    }

    pub fn plainText(self: *const Component) []const u8 {
        return self.plain[0..self.plain_len];
    }

    /// The root compound with an empty text, opening its list of runs: tag, name and type.
    const header = "\x0a" ++ "\x08\x00\x04text\x00\x00" ++ "\x09\x00\x05extra\x0a";

    fn writeRun(writer: *std.Io.Writer, first: bool, value: []const u8, style: Style) !void {
        if (first) {
            try writer.writeAll(header);
            try writer.writeInt(i32, 0, .big);
        }
        try string(writer, "text", value);
        if (style.color) |color| try string(writer, "color", color);
        inline for (.{ "bold", "italic", "underlined", "strikethrough", "obfuscated" }) |name| {
            if (@field(style, name)) |enabled| {
                try writer.writeByte(1);
                try name_(writer, name);
                try writer.writeByte(@intFromBool(enabled));
            }
        }
        if (style.insertion) |insertion| try string(writer, "insertion", insertion);
        if (style.click) |click| {
            try writer.writeByte(10);
            try name_(writer, "click_event");
            switch (click) {
                .run_command => |command| {
                    try string(writer, "action", "run_command");
                    try string(writer, "command", command);
                },
                .suggest_command => |command| {
                    try string(writer, "action", "suggest_command");
                    try string(writer, "command", command);
                },
                .open_url => |url| {
                    try string(writer, "action", "open_url");
                    try string(writer, "url", url);
                },
                .copy_to_clipboard => |value_| {
                    try string(writer, "action", "copy_to_clipboard");
                    try string(writer, "value", value_);
                },
            }
            try writer.writeByte(0);
        }
        if (style.hover) |hover| {
            try writer.writeByte(10);
            try name_(writer, "hover_event");
            try string(writer, "action", "show_text");
            try string(writer, "value", hover);
            try writer.writeByte(0);
        }
        // Ends the run's compound.
        try writer.writeByte(0);
    }
};

/// A text component of plain text, as a single string tag.
pub fn plain(buffer: []u8, value: []const u8) error{ComponentTooLarge}![]const u8 {
    if (value.len > std.math.maxInt(u16) or buffer.len < 3 + value.len) return error.ComponentTooLarge;
    buffer[0] = 8;
    std.mem.writeInt(u16, buffer[1..3], @intCast(value.len), .big);
    @memcpy(buffer[3..][0..value.len], value);
    return buffer[0 .. 3 + value.len];
}

/// A translatable component: vanilla's text for `key`, in the color given.
pub fn translatable(buffer: []u8, key: []const u8, color: ?[]const u8) error{ComponentTooLarge}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeByte(10) catch return error.ComponentTooLarge;
    string(&writer, "translate", key) catch return error.ComponentTooLarge;
    if (color) |value| string(&writer, "color", value) catch return error.ComponentTooLarge;
    writer.writeByte(0) catch return error.ComponentTooLarge;
    return writer.buffered();
}

fn name_(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeInt(u16, @intCast(value.len), .big);
    try writer.writeAll(value);
}

fn string(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    if (value.len > std.math.maxInt(u16)) return error.WriteFailed;
    try writer.writeByte(8);
    try name_(writer, name);
    try writer.writeInt(u16, @intCast(value.len), .big);
    try writer.writeAll(value);
}

const testing = std.testing;

test "a component of styled runs reads as NBT with its plain text kept" {
    var buffer: [512]u8 = undefined;
    var plain_buffer: [64]u8 = undefined;
    var component: Component = .init(&buffer, &plain_buffer);
    try testing.expect((try component.bytes()) == null);
    try component.text("[Admin] ", .{ .color = "red", .bold = true });
    try component.text("alice", .{ .color = "gold", .click = .{ .suggest_command = "/tell alice " }, .hover = "Message alice" });
    try testing.expectEqualStrings("[Admin] alice", component.plainText());
    const nbt = (try component.bytes()).?;

    // Read it back by hand: root compound, empty text, then a list of two compounds.
    var reader: std.Io.Reader = .fixed(nbt);
    try testing.expectEqual(@as(u8, 10), try reader.takeByte());
    try testing.expectEqualSlices(u8, "\x08\x00\x04text\x00\x00", try reader.take(9));
    try testing.expectEqualSlices(u8, "\x09\x00\x05extra\x0a", try reader.take(9));
    try testing.expectEqual(@as(i32, 2), try reader.takeInt(i32, .big));
    try testing.expectEqualSlices(u8, "\x08\x00\x04text\x00\x08[Admin] ", try reader.take(17));
    try testing.expectEqualSlices(u8, "\x08\x00\x05color\x00\x03red", try reader.take(13));
    try testing.expectEqualSlices(u8, "\x01\x00\x04bold\x01", try reader.take(8));
    try testing.expectEqual(@as(u8, 0), try reader.takeByte());
    try testing.expectEqualSlices(u8, "\x08\x00\x04text\x00\x05alice", try reader.take(14));
    // The last byte closes the root, after the second run's own end.
    try testing.expectEqual(@as(u8, 0), nbt[nbt.len - 1]);
    try testing.expectEqual(@as(u8, 0), nbt[nbt.len - 2]);
}

test "components refuse what does not fit" {
    var buffer: [24]u8 = undefined;
    var plain_buffer: [4]u8 = undefined;
    var component: Component = .init(&buffer, &plain_buffer);
    try testing.expectError(error.ComponentTooLarge, component.text("too long", .{}));
    try testing.expectError(error.ComponentTooLarge, component.text("ab", .{ .color = "red" }));
    var small: [4]u8 = undefined;
    try testing.expectError(error.ComponentTooLarge, plain(&small, "abcd"));
    try testing.expectEqualSlices(u8, "\x08\x00\x01a", try plain(&small, "a"));
}
