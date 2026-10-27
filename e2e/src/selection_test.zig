const std = @import("std");
const catalog = @import("catalog.zig");
const protocols = @import("protocol_catalog");
const selection = @import("selection.zig");

test "ordinary scenarios follow latest and use one version for all peers" {
    const allocator = std.testing.allocator;
    const case: catalog.Case = .{ .name = "ordinary", .peers = &.{ "alice", "bob" } };
    const versions = try selection.matrixVersions(protocols, allocator, case, null);
    defer allocator.free(versions);
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings(protocols.latest.minecraft_version, versions[0]);
    const peers = try selection.peerVersions(protocols, allocator, case, versions[0]);
    defer allocator.free(peers);
    for (peers) |version| try std.testing.expectEqualStrings(versions[0], version);
}

test "mixed matrix covers the catalog and rotates the primary through peer versions" {
    const allocator = std.testing.allocator;
    const case: catalog.Case = .{ .name = "mixed", .mixed_versions = true, .peers = &.{ "alice", "bob", "carol", "dave", "eve", "frank", "grace", "heidi" } };
    const supported = protocols.versions;
    const versions = try selection.matrixVersions(protocols, allocator, case, null);
    defer allocator.free(versions);
    try std.testing.expectEqual(supported.len, versions.len);
    for (supported, versions) |supported_version, primary| {
        try std.testing.expectEqualStrings(supported_version.minecraft_version, primary);
        const peers = try selection.peerVersions(protocols, allocator, case, primary);
        defer allocator.free(peers);
        for (peers, 0..) |version, peer| try std.testing.expectEqualStrings(protocols.versions[(protocols.releaseIndex(primary).? + peer) % protocols.versions.len].minecraft_version, version);
        try std.testing.expect(!std.mem.eql(u8, peers[0], peers[1]));
    }
}

test "legacy pins retain their primary and mix with supported gameplay versions" {
    const allocator = std.testing.allocator;
    const case: catalog.Case = .{ .name = "legacy", .version = "1.21.5", .mixed_versions = true, .peers = &.{ "alice", "bob" } };
    const versions = try selection.matrixVersions(protocols, allocator, case, null);
    defer allocator.free(versions);
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    const peers = try selection.peerVersions(protocols, allocator, case, versions[0]);
    defer allocator.free(peers);
    try std.testing.expectEqualStrings("1.21.5", peers[0]);
    try std.testing.expectEqualStrings(protocols.versions[1].minecraft_version, peers[1]);
    try std.testing.expectError(error.UnsupportedTestVersion, selection.peerVersions(protocols, allocator, case, protocols.latest.minecraft_version));
}

test "invalid versions and mixed scenarios fail before launch" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedClientVersion, selection.matrixVersions(protocols, allocator, .{ .name = "invalid", .version = "invalid" }, null));
    try std.testing.expectError(error.UnsupportedClientVersion, selection.peerVersions(protocols, allocator, .{ .name = "invalid" }, "invalid"));
    try std.testing.expectError(error.InvalidPeerVersions, selection.peerVersions(protocols, allocator, .{ .name = "invalid", .mixed_versions = true }, protocols.latest.minecraft_version));
}

test "latest mixed clients retain coverage of the oldest protocol" {
    const allocator = std.testing.allocator;
    const peers = try selection.peerVersions(protocols, allocator, .{ .name = "mixed", .mixed_versions = true, .peers = &.{ "alice", "bob" } }, protocols.latest.minecraft_version);
    defer allocator.free(peers);
    try std.testing.expectEqualStrings(protocols.latest.minecraft_version, peers[0]);
    try std.testing.expectEqualStrings(protocols.versions[0].minecraft_version, peers[1]);
}

test "suite override selects ordinary and mixed primaries while preserving pins" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |mixed| {
        const versions = try selection.matrixVersions(protocols, allocator, .{ .name = "override", .mixed_versions = mixed }, "1.21.7");
        defer allocator.free(versions);
        try std.testing.expectEqual(@as(usize, 1), versions.len);
        try std.testing.expectEqualStrings("1.21.8", versions[0]);
    }
    const pinned: catalog.Case = .{ .name = "pinned", .version = "1.21.5" };
    const versions = try selection.matrixVersions(protocols, allocator, pinned, "1.21.8");
    defer allocator.free(versions);
    try std.testing.expectEqualStrings("1.21.5", versions[0]);
    try std.testing.expectError(error.UnsupportedClientVersion, selection.matrixVersions(protocols, allocator, pinned, "invalid"));
}

test "upgrade runs once at latest with two existing clients and one newly supported client" {
    const allocator = std.testing.allocator;
    const case: catalog.Case = .{ .name = "upgrade", .upgrade = true, .peers = &.{ "alice", "bob", "newcomer" } };
    const versions = try selection.matrixVersions(protocols, allocator, case, null);
    defer allocator.free(versions);
    try std.testing.expectEqual(@as(usize, 1), versions.len);
    try std.testing.expectEqualStrings(protocols.latest.minecraft_version, versions[0]);
    const peers = try selection.peerVersions(protocols, allocator, case, versions[0]);
    defer allocator.free(peers);
    try std.testing.expectEqualStrings(peers[0], peers[1]);
    try std.testing.expect(protocols.versions[protocols.releaseIndex(peers[0]).?].protocol_number < protocols.latest.protocol_number);
    try std.testing.expectEqualStrings(protocols.latest.minecraft_version, peers[2]);
    const overridden = try selection.matrixVersions(protocols, allocator, case, peers[0]);
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings(protocols.latest.minecraft_version, overridden[0]);
    try std.testing.expectError(error.UnsupportedTestVersion, selection.peerVersions(protocols, allocator, case, peers[0]));
}
