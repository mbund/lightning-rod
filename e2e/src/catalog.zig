const std = @import("std");

pub const maximum_peers = 8;

pub const LogRule = struct {
    text: []const u8,
    count: usize = 1,
    per_peer: bool = false,
    at_least: bool = false,
};

pub const Case = struct {
    name: []const u8,
    directory: []const u8 = "",
    fixture: ?[]const u8 = null,
    prepare: ?[]const u8 = null,
    peers: []const []const u8 = &.{"alice"},
    last_peer_connect_tick: usize = 40,
    internal: bool = false,
    crash_after: bool = false,
    versions: []const []const u8 = &.{},
    peer_versions: []const []const u8 = &.{},
    server_releases: ?[]const u8 = null,
    application: []const u8 = "vanilla",
    standalone: bool = false,
    reload: bool = false,
    protocol_mismatch: bool = false,
    required_logs: []const LogRule = &.{},
    forbidden_logs: []const []const u8 = &.{},
};

const Manifest = struct {
    client: []const u8,
    variants: []Case,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]Case {
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var cases: std.ArrayList(Case) = .empty;

    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        const path = try std.fs.path.join(allocator, &.{ root, entry.name });
        const manifest_path = try std.fs.path.join(allocator, &.{ path, "test.json" });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const manifest = try std.json.parseFromSliceLeaky(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
        if (manifest.variants.len == 0) return error.EmptyTest;

        for (manifest.variants) |variant| {
            if (variant.name.len == 0 or variant.peers.len == 0 or variant.peers.len > maximum_peers) return error.InvalidTest;
            if (variant.peer_versions.len != 0 and variant.peer_versions.len != variant.peers.len) return error.InvalidPeerVersions;
            if (variant.protocol_mismatch and !variant.reload) return error.InvalidTest;

            for (variant.required_logs) |rule| if (rule.text.len == 0 or rule.count == 0) return error.InvalidLogRule;
            for (variant.forbidden_logs) |text| if (text.len == 0) return error.InvalidLogRule;

            for (variant.name) |character|
                if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidTestName;
            if (find(cases.items, variant.name) != null) return error.DuplicateTest;

            for (variant.peers, 0..) |peer, i| {
                if (peer.len == 0 or peer.len > 16) return error.InvalidPeer;

                for (peer) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return error.InvalidPeer;

                for (variant.peers[0..i]) |previous| if (std.mem.eql(u8, peer, previous)) return error.DuplicatePeer;
            }

            var selected = variant;
            selected.directory = path;
            try cases.append(allocator, selected);
        }
    }

    std.mem.sort(Case, cases.items, {}, struct {
        fn less(_: void, a: Case, b: Case) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);

    for (cases.items) |case| {
        if (case.prepare) |name| {
            const preparation = find(cases.items, name) orelse return error.UnknownPreparation;
            if (preparation.prepare != null) return error.NestedPreparation;
        }
    }

    return cases.toOwnedSlice(allocator);
}

pub fn find(cases: []const Case, name: []const u8) ?Case {
    for (cases) |case| if (std.mem.eql(u8, name, case.name)) return case;
    return null;
}
