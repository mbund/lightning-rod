const std = @import("std");

pub const Field = struct { name: []const u8, tag: u8, payload: []const u8 };

pub const Compound = struct {
    body: []const u8,

    pub fn init(bytes: []const u8) !Compound {
        if (bytes.len < 2 or bytes[0] != 10) return error.InvalidCustomData;
        var reader = std.Io.Reader.fixed(bytes[1..]);
        try skipPayload(&reader, 10, 0);
        if (reader.seek != reader.end) return error.InvalidCustomData;
        return .{ .body = bytes[1..] };
    }

    pub fn fields(self: Compound) Fields {
        return .{ .reader = .fixed(self.body) };
    }

    pub fn get(self: Compound, name: []const u8) !?Field {
        var iterator = self.fields();
        var result: ?Field = null;
        while (try iterator.next()) |field| if (try stringEqual(field.name, name)) {
            result = field;
        };
        return result;
    }

    pub fn getDouble(self: Compound, name: []const u8) !?f64 {
        const field = try self.get(name) orelse return null;
        if (field.tag != 6 or field.payload.len != 8) return null;
        return @bitCast(std.mem.readInt(u64, field.payload[0..8], .big));
    }

    pub fn getInt(self: Compound, name: []const u8) !?i32 {
        const field = try self.get(name) orelse return null;
        if (field.tag != 3) return null;
        return std.mem.readInt(i32, field.payload[0..4], .big);
    }

    pub fn getString(self: Compound, name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
        const field = try self.get(name) orelse return null;
        if (field.tag != 8) return null;
        const length = std.mem.readInt(u16, field.payload[0..2], .big);
        return try decodeString(allocator, field.payload[2..][0..length]);
    }

    pub fn getCompound(self: Compound, name: []const u8) !?Compound {
        const field = try self.get(name) orelse return null;
        if (field.tag != 10) return null;
        return .{ .body = field.payload };
    }

    pub fn edit(self: Compound, allocator: std.mem.Allocator) !Editor {
        var editor: Editor = .{ .allocator = allocator };
        var iterator = self.fields();
        while (try iterator.next()) |field| try editor.values.append(allocator, field);
        return editor;
    }
};

pub const Fields = struct {
    reader: std.Io.Reader,
    done: bool = false,

    pub fn next(self: *Fields) !?Field {
        if (self.done) return null;
        const tag = try self.reader.takeByte();
        if (tag == 0) {
            self.done = true;
            return null;
        }
        const name = try self.reader.take(try self.reader.takeInt(u16, .big));
        const start = self.reader.seek;
        try skipPayload(&self.reader, tag, 0);
        return .{ .name = name, .tag = tag, .payload = self.reader.buffer[start..self.reader.seek] };
    }
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(Field) = .empty,

    pub fn setInt(self: *Editor, name: []const u8, value: i32) !void {
        const payload = try self.allocator.alloc(u8, 4);
        std.mem.writeInt(i32, payload[0..4], value, .big);
        try self.put(.{ .name = try encodeString(self.allocator, name), .tag = 3, .payload = payload });
    }

    pub fn setString(self: *Editor, name: []const u8, value: []const u8) !void {
        const encoded = try encodeString(self.allocator, value);
        const payload = try self.allocator.alloc(u8, encoded.len + 2);
        std.mem.writeInt(u16, payload[0..2], @intCast(encoded.len), .big);
        @memcpy(payload[2..], encoded);
        try self.put(.{ .name = try encodeString(self.allocator, name), .tag = 8, .payload = payload });
    }

    pub fn put(self: *Editor, field: Field) !void {
        if (field.name.len > std.math.maxInt(u16)) return error.NbtStringTooLong;
        var reader = std.Io.Reader.fixed(field.payload);
        try skipPayload(&reader, field.tag, 0);
        if (reader.seek != reader.end) return error.InvalidCustomData;
        for (0..self.values.items.len) |offset| {
            const index = self.values.items.len - offset - 1;
            if (!std.mem.eql(u8, self.values.items[index].name, field.name)) continue;
            self.values.items[index] = field;
            return;
        }
        try self.values.append(self.allocator, field);
    }

    pub fn remove(self: *Editor, name: []const u8) !void {
        var index: usize = 0;
        while (index < self.values.items.len) {
            if (try stringEqual(self.values.items[index].name, name)) {
                _ = self.values.orderedRemove(index);
            } else index += 1;
        }
    }

    pub fn finish(self: *Editor) ![]const u8 {
        var size: usize = 2;
        for (self.values.items) |field| size = try std.math.add(usize, size, 3 + field.name.len + field.payload.len);
        const bytes = try self.allocator.alloc(u8, size);
        var writer = std.Io.Writer.fixed(bytes);
        try writer.writeByte(10);
        try writeFields(self.allocator, &writer, self.values.items, 0);
        return bytes[0..writer.end];
    }
};

pub fn canonicalize(bytes: []const u8, output: []u8, scratch: std.mem.Allocator) ![]const u8 {
    const compound = try Compound.init(bytes);
    var writer = std.Io.Writer.fixed(output);
    try writer.writeByte(10);
    try writeCompound(scratch, &writer, compound, 0);
    return output[0..writer.end];
}

fn writeCompound(allocator: std.mem.Allocator, writer: *std.Io.Writer, compound: Compound, depth: usize) anyerror!void {
    var counter = compound.fields();
    var count: usize = 0;
    while (try counter.next() != null) count += 1;
    const fields = try allocator.alloc(Field, count);
    defer allocator.free(fields);
    var iterator = compound.fields();
    for (fields) |*field| field.* = (try iterator.next()).?;
    try writeFields(allocator, writer, fields, depth);
}

fn writeFields(allocator: std.mem.Allocator, writer: *std.Io.Writer, fields: []Field, depth: usize) anyerror!void {
    if (depth >= 128) return error.NbtDepthLimit;
    std.mem.sort(Field, fields, {}, struct {
        fn less(_: void, a: Field, b: Field) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    for (fields, 0..) |field, index| {
        // Compound decoding keeps the last occurrence of a duplicate field.
        if (index + 1 < fields.len and std.mem.eql(u8, field.name, fields[index + 1].name)) continue;
        try writer.writeByte(field.tag);
        try writer.writeInt(u16, @intCast(field.name.len), .big);
        try writer.writeAll(field.name);
        try writePayload(allocator, writer, field.tag, field.payload, depth + 1);
    }
    try writer.writeByte(0);
}

fn writePayload(allocator: std.mem.Allocator, writer: *std.Io.Writer, tag: u8, payload: []const u8, depth: usize) anyerror!void {
    if (depth >= 128) return error.NbtDepthLimit;
    if (tag == 10) return writeCompound(allocator, writer, .{ .body = payload }, depth);
    if (tag != 9) return writer.writeAll(payload);
    var reader = std.Io.Reader.fixed(payload);
    const child = try reader.takeByte();
    const length = try reader.takeInt(i32, .big);
    if (length < 0) return error.InvalidCustomData;
    try writer.writeByte(child);
    try writer.writeInt(i32, length, .big);
    if (child != 9 and child != 10) return writer.writeAll(payload[reader.seek..]);
    for (0..@intCast(length)) |_| {
        const start = reader.seek;
        try skipPayload(&reader, child, depth + 1);
        try writePayload(allocator, writer, child, payload[start..reader.seek], depth + 1);
    }
}

fn skipPayload(reader: *std.Io.Reader, tag: u8, depth: usize) anyerror!void {
    if (depth >= 128) return error.NbtDepthLimit;
    switch (tag) {
        1 => try reader.discardAll(1),
        2 => try reader.discardAll(2),
        3, 5 => try reader.discardAll(4),
        4, 6 => try reader.discardAll(8),
        8 => try reader.discardAll(try reader.takeInt(u16, .big)),
        7, 11, 12 => {
            const length = try reader.takeInt(i32, .big);
            if (length < 0) return error.InvalidCustomData;
            const size: usize = if (tag == 7) 1 else if (tag == 11) 4 else 8;
            try reader.discardAll(try std.math.mul(usize, @intCast(length), size));
        },
        9 => {
            const child = try reader.takeByte();
            const length = try reader.takeInt(i32, .big);
            if (length < 0 or (child == 0 and length != 0) or child > 12) return error.InvalidCustomData;
            const size: usize = switch (child) {
                1 => 1,
                2 => 2,
                3, 5 => 4,
                4, 6 => 8,
                else => 0,
            };
            if (size > 0) try reader.discardAll(try std.math.mul(usize, @intCast(length), size)) else for (0..@intCast(length)) |_| try skipPayload(reader, child, depth + 1);
        },
        10 => while (true) {
            const child = try reader.takeByte();
            if (child == 0) break;
            try reader.discardAll(try reader.takeInt(u16, .big));
            try skipPayload(reader, child, depth + 1);
        },
        else => return error.InvalidCustomData,
    }
}

test "custom data edits preserve nested fields and canonicalize duplicate keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var nested: Editor = .{ .allocator = allocator };
    try nested.setInt("charge", 7);
    const nested_bytes = try nested.finish();
    var source: Editor = .{ .allocator = allocator };
    try source.setString("owner", "test:player");
    try source.put(.{ .name = "state", .tag = 10, .payload = nested_bytes[1..] });
    const original = try Compound.init(try source.finish());
    var edited = try original.edit(allocator);
    try edited.setString("owner", "test:other");
    const changed = try Compound.init(try edited.finish());
    try std.testing.expectEqualStrings("test:player", (try original.getString("owner", allocator)).?);
    try std.testing.expectEqualStrings("test:other", (try changed.getString("owner", allocator)).?);
    try std.testing.expectEqual(@as(i32, 7), (try (try changed.getCompound("state")).?.getInt("charge")).?);
    try std.testing.expectError(error.InvalidCustomData, edited.put(.{ .name = "bad", .tag = 0, .payload = &.{} }));
    try std.testing.expectError(error.InvalidCustomData, edited.put(.{ .name = "bad", .tag = 3, .payload = &.{ 0, 0, 0, 0, 1 } }));

    const duplicate = &[_]u8{ 10, 3, 0, 1, 'z', 0, 0, 0, 1, 3, 0, 1, 'a', 0, 0, 0, 2, 3, 0, 1, 'z', 0, 0, 0, 3, 0 };
    var buffer: [128]u8 = undefined;
    const canonical = try canonicalize(duplicate, &buffer, allocator);
    const compound = try Compound.init(canonical);
    try std.testing.expectEqual(@as(i32, 3), (try compound.getInt("z")).?);
    var iterator = compound.fields();
    try std.testing.expectEqualStrings("a", (try iterator.next()).?.name);
    try std.testing.expectEqualStrings("z", (try iterator.next()).?.name);
    try std.testing.expect(try iterator.next() == null);
    var again: [128]u8 = undefined;
    try std.testing.expectEqualSlices(u8, canonical, try canonicalize(canonical, &again, allocator));
}

// NBT uses Java modified UTF-8, including surrogate pairs and a two-byte NUL.
pub fn writeString(writer: *std.Io.Writer, value: []const u8) !void {
    var view = (try std.unicode.Utf8View.init(value)).iterator();
    var length: usize = 0;
    while (view.nextCodepoint()) |point| length += if (point == 0) @as(usize, 2) else if (point <= 0x7f) @as(usize, 1) else if (point <= 0x7ff) @as(usize, 2) else if (point <= 0xffff) @as(usize, 3) else @as(usize, 6);
    if (length > std.math.maxInt(u16)) return error.NbtStringTooLong;
    try writer.writeInt(u16, @intCast(length), .big);
    view = (try std.unicode.Utf8View.init(value)).iterator();
    while (view.nextCodepoint()) |point| {
        var bytes: [6]u8 = undefined;
        try writer.writeAll(encodePoint(point, &bytes));
    }
}

fn encodePoint(point: u21, bytes: *[6]u8) []const u8 {
    if (point != 0 and point <= 0x7f) {
        bytes[0] = @intCast(point);
        return bytes[0..1];
    }
    if (point <= 0x7ff) {
        bytes[0] = 0xc0 | @as(u8, @intCast(point >> 6));
        bytes[1] = 0x80 | @as(u8, @intCast(point & 0x3f));
        return bytes[0..2];
    }
    if (point <= 0xffff) {
        encodeUnit(@intCast(point), bytes[0..3]);
        return bytes[0..3];
    }
    const offset = @as(u32, point) - 0x10000;
    encodeUnit(@intCast(0xd800 | (offset >> 10)), bytes[0..3]);
    encodeUnit(@intCast(0xdc00 | (offset & 0x3ff)), bytes[3..6]);
    return bytes;
}

fn encodeUnit(unit: u16, bytes: *[3]u8) void {
    bytes.* = .{ 0xe0 | @as(u8, @intCast(unit >> 12)), 0x80 | @as(u8, @intCast((unit >> 6) & 0x3f)), 0x80 | @as(u8, @intCast(unit & 0x3f)) };
}

fn encodeString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    try writeString(&writer.writer, value);
    return writer.written()[2..];
}

fn stringEqual(encoded: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, encoded, value)) return true;
    var iterator = (try std.unicode.Utf8View.init(value)).iterator();
    var offset: usize = 0;
    while (iterator.nextCodepoint()) |point| {
        var bytes: [6]u8 = undefined;
        const expected = encodePoint(point, &bytes);
        if (expected.len > encoded.len - offset or !std.mem.eql(u8, expected, encoded[offset..][0..expected.len])) return false;
        offset += expected.len;
    }
    return offset == encoded.len;
}

fn decodeString(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(encoded)) return encoded;
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(allocator);
    var offset: usize = 0;
    while (offset < encoded.len) {
        const first = encoded[offset];
        const length: usize = if (first < 0x80) 1 else if (first & 0xe0 == 0xc0) 2 else if (first & 0xf0 == 0xe0) 3 else return error.InvalidNbtString;
        if (length > encoded.len - offset) return error.InvalidNbtString;
        var unit: u16 = first & (if (length == 1) @as(u8, 0x7f) else if (length == 2) @as(u8, 0x1f) else @as(u8, 0x0f));
        for (encoded[offset + 1 ..][0 .. length - 1]) |byte| {
            if (byte & 0xc0 != 0x80) return error.InvalidNbtString;
            unit = (unit << 6) | (byte & 0x3f);
        }
        if ((length == 2 and unit != 0 and unit < 0x80) or (length == 3 and unit < 0x800)) return error.InvalidNbtString;
        try units.append(allocator, std.mem.nativeToLittle(u16, unit));
        offset += length;
    }
    return std.unicode.wtf16LeToWtf8Alloc(allocator, units.items);
}

test "custom data strings preserve NUL and supplementary Unicode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var editor: Editor = .{ .allocator = allocator };
    const name = "key\u{1f600}";
    const value = "a\x00\u{1f600}";
    try editor.setString(name, value);
    const compound = try Compound.init(try editor.finish());
    try std.testing.expectEqualStrings(value, (try compound.getString(name, allocator)).?);
    const field = (try compound.get(name)).?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 9, 'a', 0xc0, 0x80, 0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80 }, field.payload);
    try editor.remove(name);
    try std.testing.expectEqual(@as(usize, 0), editor.values.items.len);
}
