const std = @import("std");
const fields = @import("reload").fields;

/// The sessions' first list in a handoff: the listening socket the next process takes over and
/// the compression threshold its connections were set up with. The connections' list follows it.
pub const Header = struct {
    listener: i32,
    compression_threshold: ?usize,

    // Released tags; never change what one holds, add a new one.
    const listener_tag: fields.Tag = 1;
    /// Absent when connections are not compressed.
    const compression_threshold_tag: fields.Tag = 2;

    pub fn write(self: Header, writer: *std.Io.Writer) !void {
        if (self.listener < 3) return error.InvalidResume;
        try fields.writeInt(writer, listener_tag, i32, self.listener);
        if (self.compression_threshold) |threshold|
            try fields.writeInt(writer, compression_threshold_tag, u32, std.math.cast(u32, threshold) orelse return error.InvalidResume);
        try fields.writeEnd(writer);
    }

    pub fn read(reader: *std.Io.Reader) !Header {
        var listener: ?i32 = null;
        var threshold: ?usize = null;
        var list: fields.Reader = .init(reader);
        while (try list.next()) |field| switch (field.tag) {
            listener_tag => listener = try list.int(field, i32),
            compression_threshold_tag => threshold = try list.int(field, u32),
            else => try list.skip(field),
        };
        const descriptor = listener orelse return error.InvalidResume;
        if (descriptor < 3) return error.InvalidResume;
        return .{ .listener = descriptor, .compression_threshold = threshold };
    }
};
