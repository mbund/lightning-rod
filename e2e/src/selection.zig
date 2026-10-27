const std = @import("std");
const catalog = @import("catalog.zig");

pub fn matrixVersions(comptime protocols: type, allocator: std.mem.Allocator, case: catalog.Case, requested: ?[]const u8) ![]const []const u8 {
    const requested_index = if (requested) |version| protocols.releaseIndex(version) orelse return error.UnsupportedClientVersion else null;
    if (case.upgrade) {
        return allocator.dupe([]const u8, &.{protocols.latest.minecraft_version});
    }
    const index = if (case.version) |version| protocols.releaseIndex(version) orelse return error.UnsupportedClientVersion else requested_index;
    if (index) |selected| return allocator.dupe([]const u8, &.{protocols.versions[selected].minecraft_version});
    if (!case.mixed_versions) return allocator.dupe([]const u8, &.{protocols.latest.minecraft_version});
    const versions = protocols.versions;
    const result = try allocator.alloc([]const u8, versions.len);
    for (versions, result) |version, *name| name.* = version.minecraft_version;
    return result;
}

pub fn peerVersions(comptime protocols: type, allocator: std.mem.Allocator, case: catalog.Case, primary: []const u8) ![]const []const u8 {
    if (case.peers.len == 0 or case.peers.len > catalog.maximum_peers) return error.InvalidPeerVersions;
    const index = protocols.releaseIndex(primary) orelse return error.UnsupportedClientVersion;
    if (case.version) |version| {
        const required = protocols.releaseIndex(version) orelse return error.UnsupportedClientVersion;
        if (index != required) return error.UnsupportedTestVersion;
    }
    const result = try allocator.alloc([]const u8, case.peers.len);
    errdefer allocator.free(result);
    if (case.upgrade) {
        if (result.len != 3 or index == 0 or protocols.versions[index].protocol_number != protocols.latest.protocol_number) return error.UnsupportedTestVersion;
        result[0] = protocols.versions[index - 1].minecraft_version;
        result[1] = protocols.versions[index - 1].minecraft_version;
        result[2] = protocols.latest.minecraft_version;
        return result;
    }
    @memset(result, protocols.versions[index].minecraft_version);
    if (case.mixed_versions) {
        if (result.len < 2) return error.InvalidPeerVersions;
        const count = protocols.versions.len;
        if (count < 2) return error.InsufficientMixedVersions;
        for (result[1..], 1..) |*version, peer| {
            version.* = protocols.versions[(index + peer) % count].minecraft_version;
        }
    }
    return result;
}
