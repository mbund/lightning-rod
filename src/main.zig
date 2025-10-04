const std = @import("std");
const net = std.net;
const posix = std.posix;

const _ = @import("varint.zig");
const VarInt = @import("varint.zig").VarInt;
const String = @import("string.zig").String;

const nbt = @import("nbt.zig");

pub fn main() !void {
    const path = "/var/home/admin/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances/1.21.5/minecraft/saves/Super Flat Test 2/playerdata/dfd7dc6d-cffd-4f60-90b9-a4a5002f1111.dat";
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buf = std.mem.zeroes([100_000]u8);
    var buf2 = std.mem.zeroes([100_000]u8);
    var file_reader = file.reader(&buf2);
    var d = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &buf);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    _ = try nbt.NbtData.read(&d.reader, &allocator);
}
