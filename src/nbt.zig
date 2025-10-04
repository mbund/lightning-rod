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

pub const NbtPayload = union(enum) {
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

    pub fn read(reader: *std.Io.Reader, allocator: *std.mem.Allocator, tag: Tag) anyerror!NbtPayload {
        switch (tag) {
            Tag.compound => {
                var list = try std.ArrayList(NbtData).initCapacity(allocator.*, 0);
                while (true) {
                    const t = try reader.peekByte();
                    if (t == 0) {
                        std.debug.print("exiting compound\n", .{});
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
                // std.debug.print("reading list of type: {} len: {}\n", .{ list_tag, size });
                var list = NbtList{ .tag = list_tag, .items = try std.ArrayList(NbtPayload).initCapacity(allocator.*, @intCast(size)) };
                for (0..@intCast(size)) |_| {
                    // std.debug.print("reading item: {}\n", .{i});
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
                @panic("ahhhh!!!!!!!!");
            },
        }
        unreachable;
    }
};

pub const NbtData = struct {
    name: []u8,
    data: NbtPayload,

    pub fn read(reader: *std.Io.Reader, allocator: *std.mem.Allocator) anyerror!NbtData {
        const tag: Tag = @enumFromInt(try reader.takeByte());
        const len: u16 = try reader.takeInt(u16, std.builtin.Endian.big);
        const name = try reader.readAlloc(allocator.*, len);
        std.debug.print("tag: {} name_len: {} name: {s}\n", .{ tag, len, name });
        const data = try NbtPayload.read(reader, allocator, tag);

        return NbtData{ .name = name, .data = data };
    }
};
