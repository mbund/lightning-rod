const std = @import("std");
const net = std.net;
const posix = std.posix;

const _ = @import("varint.zig");
const VarInt = @import("varint.zig").VarInt;
const String = @import("string.zig").String;

const nbt = @import("nbt.zig");

pub fn openNbtFile(name: []const u8, allocator: *std.mem.Allocator) !nbt.NbtData {
    const file = try std.fs.cwd().openFile(name, .{});
    defer file.close();
    var buf = std.mem.zeroes([16384]u8);
    var file_reader = file.reader(&buf);
    const data = try nbt.NbtData.read(&file_reader.interface, allocator);
    return data;
}

pub fn writeNbtFile(name: []const u8, data: nbt.NbtData) !void {
    const file = try std.fs.cwd().createFile(name, .{});
    defer file.close();
    var buf = std.mem.zeroes([16384]u8);
    var file_writer = file.writer(&buf);
    try data.write(&file_writer.interface);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const data = try openNbtFile("nbt", &allocator);
    data.print(0);

    try writeNbtFile("nbt-out", data);
}
