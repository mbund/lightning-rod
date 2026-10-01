const std = @import("std");
const catalog = @import("catalog.zig");
const protocols = @import("protocol_catalog");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const cases = try catalog.load(allocator, init.io, if (args.len == 2) args[1] else "tests");

    const Entry = struct { scenario: []const u8, version: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    for (cases) |case| {
        if (case.internal) continue;
        const versions = if (case.versions.len == 0) &.{protocols.latest.minecraft_version} else case.versions;
        for (versions) |version| {
            if (protocols.releaseIndex(version) == null) return error.UnsupportedClientVersion;
            try entries.append(allocator, .{ .scenario = case.name, .version = version });
        }
    }
    if (entries.items.len == 0 or entries.items.len > 256) return error.InvalidMatrixSize;

    const json = try std.json.Stringify.valueAlloc(allocator, .{ .include = entries.items }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
