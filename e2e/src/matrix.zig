//! e2e-matrix ROOT [RELEASE]   prints the GitHub Actions matrix of every discovered scenario.
//! e2e-matrix --list ROOT       prints each runnable scenario and its test directory.

const std = @import("std");
const discovery = @import("discovery.zig");
const protocols = @import("protocol_catalog");
const selection = @import("selection.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--list")) {
        const tests = try discovery.discover(init.io, init.gpa, allocator, args[2]);
        for (tests) |found| for (found.manifest.scenarios) |scenario| {
            if (scenario.internal) continue;
            const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ scenario.name, found.directory });
            try std.Io.File.stdout().writeStreamingAll(init.io, line);
        };
        return;
    }
    if (args.len < 2 or args.len > 3) return error.ExpectedRootAndRelease;
    const tests = try discovery.discover(init.io, init.gpa, allocator, args[1]);
    const requested = if (args.len == 3) args[2] else null;

    const Entry = struct {
        scenario: []const u8,
        directory: []const u8,
        version: []const u8,
        clients: []const u8,
        group: []const u8,
        priority: enum { latest, mixed, other },
        upgrade: bool,
    };
    var entries: std.ArrayList(Entry) = .empty;
    for (tests) |found| for (found.manifest.scenarios) |case| {
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
            try entries.append(allocator, .{
                .scenario = case.name,
                .directory = found.directory,
                .version = version,
                .clients = try std.mem.join(allocator, ",", clients.items),
                .group = if (clients.items.len > 1) "mixed" else version,
                .priority = if (std.mem.eql(u8, version, protocols.latest.minecraft_version)) .latest else if (clients.items.len > 1) .mixed else .other,
                .upgrade = case.upgrade,
            });
        }
    };
    if (entries.items.len == 0 or entries.items.len > 256) return error.InvalidMatrixSize;

    const json = try std.json.Stringify.valueAlloc(allocator, .{ .include = entries.items }, .{});
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
