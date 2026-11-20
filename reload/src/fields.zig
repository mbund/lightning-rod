//! Tagged fields, the encoding of everything a reload hands to the next process. A field is a
//! tag, its value's length and the value; a list of fields ends with tag 0. Readers skip tags they
//! do not know and give missing ones their default, so adding state is a new tag and never a new
//! version. A tag's encoding never changes once released: to change one, retire it for a new tag.
//! Integers are little-endian, as wide as their type.
const std = @import("std");

pub const Tag = u16;
/// Ends a list.
pub const end: Tag = 0;
/// A field's tag and length, ahead of its value.
pub const header_bytes = @sizeOf(Tag) + @sizeOf(u32);

/// What a field with a value of this many bytes takes.
pub fn fieldBytes(value_len: usize) usize {
    return header_bytes + value_len;
}

/// The bytes an integer is written as, its width rather than its size in memory: an i96 is 12.
pub fn intWidth(comptime T: type) usize {
    return @divExact(@bitSizeOf(T), 8);
}

/// What an integer field takes.
pub fn intBytes(comptime T: type) usize {
    return fieldBytes(intWidth(T));
}

/// What the end of a list takes.
pub const end_bytes = header_bytes;

pub fn writeHeader(writer: *std.Io.Writer, tag: Tag, value_len: usize) !void {
    std.debug.assert(tag != end);
    try writer.writeInt(Tag, tag, .little);
    try writer.writeInt(u32, std.math.cast(u32, value_len) orelse return error.FieldTooLarge, .little);
}

pub fn writeInt(writer: *std.Io.Writer, tag: Tag, comptime T: type, value: T) !void {
    try writeHeader(writer, tag, intWidth(T));
    try writer.writeInt(T, value, .little);
}

pub fn writeBytes(writer: *std.Io.Writer, tag: Tag, bytes: []const u8) !void {
    try writeHeader(writer, tag, bytes.len);
    try writer.writeAll(bytes);
}

pub fn writeEnd(writer: *std.Io.Writer) !void {
    try writer.writeInt(Tag, end, .little);
    try writer.writeInt(u32, 0, .little);
}

pub const Field = struct { tag: Tag, len: u32 };

/// Reads one list. Each field's value must be consumed whole, by the reader's helpers or by the
/// caller reading exactly `len` bytes from `in`, before the next field.
pub const Reader = struct {
    in: *std.Io.Reader,
    /// What a nested list may still take of the field holding it; null for a list on its own.
    remaining: ?u64 = null,

    pub fn init(in: *std.Io.Reader) Reader {
        return .{ .in = in };
    }

    /// The list held by `field`, which must end exactly where the field does.
    pub fn nested(self: *const Reader, field: Field) Reader {
        return .{ .in = self.in, .remaining = field.len };
    }

    /// The next field, or null at the end of the list.
    pub fn next(self: *Reader) !?Field {
        try self.take(header_bytes);
        const tag = try self.in.takeInt(Tag, .little);
        const len = try self.in.takeInt(u32, .little);
        if (tag == end) {
            if (len != 0) return error.InvalidResume;
            if (self.remaining) |remaining| if (remaining != 0) return error.InvalidResume;
            return null;
        }
        try self.take(len);
        return .{ .tag = tag, .len = len };
    }

    fn take(self: *Reader, count: u64) !void {
        const remaining = &(self.remaining orelse return);
        if (count > remaining.*) return error.InvalidResume;
        remaining.* -= count;
    }

    pub fn int(self: *Reader, field: Field, comptime T: type) !T {
        if (field.len != intWidth(T)) return error.InvalidResume;
        return self.in.takeInt(T, .little);
    }

    /// The value, read into `buffer`, which it must fit.
    pub fn bytes(self: *Reader, field: Field, buffer: []u8) ![]u8 {
        if (field.len > buffer.len) return error.InvalidResume;
        try self.in.readSliceAll(buffer[0..field.len]);
        return buffer[0..field.len];
    }

    pub fn skip(self: *Reader, field: Field) !void {
        try self.in.discardAll(field.len);
    }
};

const testing = std.testing;

test "a list reads back what was written and skips what it does not know" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeInt(&writer, 1, u32, 0xdeadbeef);
    try writeBytes(&writer, 9, "unknown");
    try writeBytes(&writer, 2, "name");
    try writeEnd(&writer);

    var in: std.Io.Reader = .fixed(writer.buffered());
    var list: Reader = .init(&in);
    var number: ?u32 = null;
    var name_buffer: [16]u8 = undefined;
    var name: ?[]u8 = null;
    while (try list.next()) |field| switch (field.tag) {
        1 => number = try list.int(field, u32),
        2 => name = try list.bytes(field, &name_buffer),
        else => try list.skip(field),
    };
    try testing.expectEqual(@as(?u32, 0xdeadbeef), number);
    try testing.expectEqualStrings("name", name.?);
    try testing.expectEqual(writer.buffered().len, in.seek);
}

test "a nested list ends exactly where its field does" {
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const inner_len = intBytes(u8) + end_bytes;
    try writeHeader(&writer, 3, inner_len);
    try writeInt(&writer, 1, u8, 7);
    try writeEnd(&writer);
    try writeInt(&writer, 4, u8, 8);
    try writeEnd(&writer);

    var in: std.Io.Reader = .fixed(writer.buffered());
    var list: Reader = .init(&in);
    const holder = (try list.next()).?;
    try testing.expectEqual(@as(Tag, 3), holder.tag);
    var inner = list.nested(holder);
    try testing.expectEqual(@as(u8, 7), try inner.int((try inner.next()).?, u8));
    try testing.expectEqual(@as(?Field, null), try inner.next());
    try testing.expectEqual(@as(u8, 8), try list.int((try list.next()).?, u8));
    try testing.expectEqual(@as(?Field, null), try list.next());

    // A nested list that runs past its field, or ends short of it, is refused.
    var short: [64]u8 = undefined;
    var bad: std.Io.Writer = .fixed(&short);
    try writeHeader(&bad, 3, end_bytes + 1);
    try writeEnd(&bad);
    var bad_in: std.Io.Reader = .fixed(bad.buffered());
    var bad_list: Reader = .init(&bad_in);
    var bad_inner = bad_list.nested((try bad_list.next()).?);
    try testing.expectError(error.InvalidResume, bad_inner.next());
}

test "values of the wrong size and ends with a length are refused" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeInt(&writer, 1, u16, 5);
    try writer.writeInt(Tag, end, .little);
    try writer.writeInt(u32, 1, .little);
    var in: std.Io.Reader = .fixed(writer.buffered());
    var list: Reader = .init(&in);
    const field = (try list.next()).?;
    try testing.expectError(error.InvalidResume, list.int(field, u32));
    var again: std.Io.Reader = .fixed(writer.buffered()[intBytes(u16)..]);
    var tail: Reader = .init(&again);
    try testing.expectError(error.InvalidResume, tail.next());
}
