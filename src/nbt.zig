const std = @import("std");

pub const Tag = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,
};

pub const NbtList = struct { tag: Tag, items: std.ArrayList(NbtPayload) };

pub const NbtReadError = error{
    UnknownTag,
};

pub const NbtPayload = union(Tag) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []u8,
    string: []u8,
    list: NbtList,
    compound: std.ArrayList(NbtData),
    int_array: []i32,
    long_array: []i64,

    pub fn read(reader: *std.Io.Reader, allocator: *std.mem.Allocator, tag: Tag) !NbtPayload {
        switch (tag) {
            Tag.compound => {
                var list = try std.ArrayList(NbtData).initCapacity(allocator.*, 0);
                while (true) {
                    const t = try reader.peekByte();
                    if (t == 0) {
                        reader.toss(1);
                        return NbtPayload{ .compound = list };
                    }
                    _ = try list.append(allocator.*, try NbtData.read(reader, allocator));
                }
            },
            Tag.byte => {
                const b: i8 = @bitCast(try reader.takeByte());
                return NbtPayload{ .byte = b };
            },
            Tag.short => {
                const b = try reader.takeInt(i16, std.builtin.Endian.big);
                return NbtPayload{ .short = b };
            },
            Tag.int => {
                const b = try reader.takeInt(i32, std.builtin.Endian.big);
                return NbtPayload{ .int = b };
            },
            Tag.long => {
                const b: i64 = try reader.takeInt(i64, std.builtin.Endian.big);
                return NbtPayload{ .long = b };
            },
            Tag.float => {
                const b = try reader.takeInt(i32, std.builtin.Endian.big);
                const f: f32 = @bitCast(b);
                return NbtPayload{ .float = f };
            },
            Tag.double => {
                const b = try reader.takeInt(i64, std.builtin.Endian.big);
                const f: f64 = @bitCast(b);
                return NbtPayload{ .double = f };
            },
            Tag.byte_array => {
                const size = try reader.takeInt(i32, std.builtin.Endian.big);
                const bytes = try reader.readAlloc(allocator.*, @intCast(size));
                return NbtPayload{ .byte_array = bytes };
            },
            Tag.string => {
                const size = try reader.takeInt(i16, std.builtin.Endian.big);
                // std.debug.print("reading string of len:  {}\n", .{size});
                const bytes = try reader.readAlloc(allocator.*, @intCast(size));
                return NbtPayload{ .string = bytes };
            },
            Tag.list => {
                const list_tag: Tag = @enumFromInt(try reader.takeByte());
                const size = try reader.takeInt(i32, std.builtin.Endian.big);
                var list = NbtList{ .tag = list_tag, .items = try std.ArrayList(NbtPayload).initCapacity(allocator.*, @intCast(size)) };
                for (0..@intCast(size)) |_| {
                    const item = try NbtPayload.read(reader, allocator, list_tag);
                    _ = try list.items.append(allocator.*, item);
                }
                return NbtPayload{ .list = list };
            },
            Tag.int_array => {
                const size = try reader.takeInt(i32, std.builtin.Endian.big);
                const buf = try allocator.alloc(i32, @intCast(size));
                _ = try reader.readSliceAll(@ptrCast(buf));
                return NbtPayload{ .int_array = @ptrCast(buf) };
            },
            Tag.long_array => {
                const size = try reader.takeInt(i32, std.builtin.Endian.big);
                const buf = try allocator.alloc(i64, @intCast(size));
                _ = try reader.readSliceAll(@ptrCast(buf));
                return NbtPayload{ .int_array = @ptrCast(buf) };
            },
            else => {
                return NbtReadError.UnknownTag;
            },
        }
        unreachable;
    }

    pub fn write(self: NbtPayload, writer: *std.Io.Writer) anyerror!void {
        switch (self) {
            Tag.end => {
                unreachable;
            },
            Tag.byte => {
                try writer.writeInt(i8, self.byte, std.builtin.Endian.big);
            },
            Tag.short => {
                try writer.writeInt(i16, self.short, std.builtin.Endian.big);
            },
            Tag.int => {
                try writer.writeInt(i32, self.int, std.builtin.Endian.big);
            },
            Tag.long => {
                try writer.writeInt(i64, self.long, std.builtin.Endian.big);
            },
            Tag.float => {
                try writer.writeInt(i32, @bitCast(self.float), std.builtin.Endian.big);
            },
            Tag.double => {
                try writer.writeInt(i64, @bitCast(self.double), std.builtin.Endian.big);
            },
            Tag.byte_array => {
                try writer.writeInt(i32, @intCast(self.byte_array.len), std.builtin.Endian.big);
                try writer.writeAll(self.byte_array);
            },
            Tag.string => {
                try writer.writeInt(u16, @intCast(self.string.len), std.builtin.Endian.big);
                try writer.writeAll(self.string);
            },
            Tag.list => {
                try writer.writeInt(u8, @intFromEnum(self.list.tag), std.builtin.Endian.big);
                try writer.writeInt(i32, @intCast(self.list.items.items.len), std.builtin.Endian.big);
                for (self.list.items.items) |item| {
                    try item.write(writer);
                }
            },
            Tag.compound => {
                for (self.compound.items) |item| {
                    try item.write(writer);
                }
                try writer.writeByte(@intFromEnum(Tag.end));
            },
            Tag.int_array => {
                try writer.writeInt(i32, @intCast(self.int_array.len), std.builtin.Endian.big);
                try writer.writeSliceEndian(i32, self.int_array, std.builtin.Endian.big);
            },
            Tag.long_array => {
                try writer.writeInt(i32, @intCast(self.long_array.len), std.builtin.Endian.big);
                try writer.writeSliceEndian(i64, self.long_array, std.builtin.Endian.big);
            },
        }
    }

    pub fn print(self: NbtPayload, indent: u32) void {
        switch (self) {
            Tag.end => unreachable,
            Tag.byte => {
                std.debug.print("{}", .{self.byte});
            },
            Tag.short => {
                std.debug.print("{}", .{self.short});
            },
            Tag.int => {
                std.debug.print("{}", .{self.int});
            },
            Tag.long => {
                std.debug.print("{}", .{self.long});
            },
            Tag.float => {
                std.debug.print("{}", .{self.float});
            },
            Tag.double => {
                std.debug.print("{}", .{self.double});
            },
            Tag.byte_array => {
                std.debug.print("byte_array: {any}", .{self.byte_array});
            },
            Tag.string => {
                std.debug.print("string: {s}", .{self.string});
            },
            Tag.list => {
                for (self.list.items.items) |item| {
                    std.debug.print(" ", .{});
                    item.print(0);
                }
            },
            Tag.compound => {
                std.debug.print("\n", .{});
                for (self.compound.items) |item| {
                    item.print(indent + 2);
                }
            },
            Tag.int_array => {
                std.debug.print("int_array: {any}", .{self.int_array});
            },
            Tag.long_array => {
                std.debug.print("long_array: {any}", .{self.long_array});
            },
        }
    }
};

pub const NbtData = struct {
    name: []u8,
    data: NbtPayload,

    pub fn read(reader: *std.Io.Reader, allocator: *std.mem.Allocator) anyerror!NbtData {
        const tag: Tag = @enumFromInt(try reader.takeByte());
        const len: u16 = try reader.takeInt(u16, std.builtin.Endian.big);
        const name = try reader.readAlloc(allocator.*, len);
        const data = try NbtPayload.read(reader, allocator, tag);

        return NbtData{ .name = name, .data = data };
    }

    pub fn write(self: NbtData, writer: *std.Io.Writer) !void {
        const tag: u8 = @intFromEnum(self.data);
        const len: u16 = @intCast(self.name.len);
        try writer.writeInt(u8, tag, std.builtin.Endian.big);
        try writer.writeInt(u16, len, std.builtin.Endian.big);
        try writer.writeAll(self.name);
        try self.data.write(writer);
        std.debug.print("writing: {s} ", .{self.name});
        try writer.flush();
    }

    pub fn print(self: NbtData, indent: u32) void {
        for (0..indent) |_| {
            std.debug.print(" ", .{});
        }
        std.debug.print("{s} {s}: ", .{ @tagName(self.data), self.name });
        self.data.print(indent);
        std.debug.print("\n", .{});
    }
};
