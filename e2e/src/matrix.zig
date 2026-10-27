const std = @import("std");
const catalog = @import("catalog.zig");
const protocols = @import("protocol_catalog");
const selection = @import("selection.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len > 3) return error.UnexpectedArgument;
    const cases = try catalog.load(allocator, init.io, if (args.len >= 2) args[1] else "tests");
    const requested = if (args.len == 3) args[2] else null;

    const Entry = struct { scenario: []const u8, version: []const u8, clients: []const u8, upgrade: bool };
    var entries: std.ArrayList(Entry) = .empty;
    for (cases) |case| {
        if (case.internal) continue;
        const versions = try selection.matrixVersions(protocols, allocator, case, requested);
        for (versions) |version| {
            const peers = try selection.peerVersions(protocols, allocator, case, version);
            var clients: std.ArrayList([]const u8) = .empty;
            for (peers) |peer| {
                var duplicate = false;
                for (clients.items) |existing| duplicate = duplicate or std.mem.eql(u8, peer, existing);
                if (!duplicate) try clients.append(allocator, peer);
            }
            try entries.append(allocator, .{ .scenario = case.name, .version = version, .clients = try std.mem.join(allocator, ",", clients.items), .upgrade = case.upgrade });
        }
    }
    if (entries.items.len == 0 or entries.items.len > 256) return error.InvalidMatrixSize;

    const json = try std.json.Stringify.valueAlloc(allocator, .{ .include = entries.items }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
