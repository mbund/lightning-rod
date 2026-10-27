const std = @import("std");

// These bytes follow the profile header. They must survive plugin refactors.
pub const Header = struct {
    listener: i32,
    compression_threshold: ?usize,

    pub fn write(self: Header, writer: *std.Io.Writer) !void {
        if (self.listener < 3 or (self.compression_threshold != null and self.compression_threshold.? > std.math.maxInt(i32))) return error.InvalidResume;
        try writer.writeInt(i32, self.listener, .little);
        try writer.writeInt(i32, if (self.compression_threshold) |threshold| @intCast(threshold) else -1, .little);
    }

    pub fn read(reader: *std.Io.Reader) !Header {
        const listener = try reader.takeInt(i32, .little);
        const threshold = try reader.takeInt(i32, .little);
        if (listener < 3 or threshold < -1) return error.InvalidResume;
        return .{ .listener = listener, .compression_threshold = if (threshold == -1) null else @intCast(threshold) };
    }
};
