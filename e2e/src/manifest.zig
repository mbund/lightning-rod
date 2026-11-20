//! A test's `test.zon`: the Java fixture class its clients run and the scenarios it offers.
//! The build, the runner and suite discovery all read it through `parse`.

const std = @import("std");

const assert = std.debug.assert;

pub const maximum_peers = 8;
pub const maximum_scenarios = 64;
pub const maximum_bytes = 64 * 1024;

pub const Scenario = struct {
    name: []const u8,
    /// Passed to the server as --fixture.
    fixture: ?[]const u8 = null,
    /// A scenario of the same test that runs first against the same world.
    prepare: ?[]const u8 = null,
    peers: []const []const u8 = &.{"alice"},
    last_peer_connect_tick: usize = 40,
    /// Runs only as another scenario's preparation.
    internal: bool = false,
    crash_after: bool = false,
    /// The only client release the scenario supports.
    version: ?[]const u8 = null,
    /// Peers after the first join on the following releases.
    mixed_versions: bool = false,
    /// The server supports every release, not only the ones its peers use.
    full_protocols: bool = false,
    /// The runner replaces the server binary in place between rounds.
    reload: bool = false,
    /// With `reload`, the runner reloads once, as a player asks with /reload, instead of running
    /// every reload round.
    reload_once: bool = false,
    /// The runner starts the previous revision's server and upgrades it in place.
    upgrade: bool = false,
    protocol_mismatch: bool = false,
    /// The server runs in online mode against a session server the runner hosts, which clients
    /// join through.
    session_server: bool = false,
};

pub const Manifest = struct {
    /// The fixture class in package dev.lightningrod.e2e.
    client: []const u8,
    /// The test measures throughput a debug server cannot reach, so its build optimizes the
    /// server and enforces the tick budget even when debug is requested.
    release: bool = false,
    scenarios: []const Scenario,

    pub fn find(self: Manifest, name: []const u8) ?Scenario {
        for (self.scenarios) |scenario| if (std.mem.eql(u8, scenario.name, name)) return scenario;
        return null;
    }
};

pub const Error = error{ OutOfMemory, ParseZon, InvalidTest, InvalidTestName, InvalidClient, InvalidPeer, InvalidPeerVersions, DuplicatePeer, DuplicateTest, UnknownPreparation, NestedPreparation };

/// Parses and validates a manifest. Results live in `arena`. Parse errors are logged with `path`.
pub fn parse(gpa: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, path: []const u8) Error!Manifest {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{ .gpa = gpa, .arena = arena, .source = source, .diagnostics = &diagnostics }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(path);
        return err;
    };
    try validate(manifest);
    return manifest;
}

/// Reads and validates the manifest at `path`.
pub fn read(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8) !Manifest {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(maximum_bytes), .of(u8), 0);
    return parse(gpa, arena, source, path);
}

pub fn validate(manifest: Manifest) Error!void {
    if (manifest.client.len == 0 or !std.ascii.isAlphabetic(manifest.client[0])) return error.InvalidClient;
    for (manifest.client) |character| if (!std.ascii.isAlphanumeric(character)) return error.InvalidClient;
    if (manifest.scenarios.len == 0 or manifest.scenarios.len > maximum_scenarios) return error.InvalidTest;

    for (manifest.scenarios, 0..) |scenario, index| {
        if (scenario.name.len == 0 or scenario.peers.len == 0 or scenario.peers.len > maximum_peers) return error.InvalidTest;
        if (scenario.mixed_versions and scenario.peers.len < 2) return error.InvalidPeerVersions;
        if (scenario.protocol_mismatch and !scenario.reload) return error.InvalidTest;
        if (scenario.reload_once and (!scenario.reload or scenario.protocol_mismatch)) return error.InvalidTest;
        if (scenario.upgrade and (scenario.peers.len != 3 or scenario.reload or scenario.fixture != null or scenario.prepare != null)) return error.InvalidTest;
        for (scenario.name) |character|
            if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidTestName;
        for (manifest.scenarios[0..index]) |previous| if (std.mem.eql(u8, previous.name, scenario.name)) return error.DuplicateTest;

        for (scenario.peers, 0..) |peer, i| {
            if (peer.len == 0 or peer.len > 16) return error.InvalidPeer;
            for (peer) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return error.InvalidPeer;
            for (scenario.peers[0..i]) |previous| if (std.mem.eql(u8, peer, previous)) return error.DuplicatePeer;
        }
    }

    for (manifest.scenarios) |scenario| {
        const name = scenario.prepare orelse continue;
        const preparation = manifest.find(name) orelse return error.UnknownPreparation;
        if (preparation.prepare != null) return error.NestedPreparation;
    }
}

fn testParse(source: [:0]const u8) Error!void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const manifest = try parse(std.testing.allocator, arena.allocator(), source, "test.zon");
    assert(manifest.scenarios.len > 0);
}

test "manifests parse and reject invalid scenarios" {
    try testParse(
        \\.{ .client = "ChunksFixture", .release = true, .scenarios = .{
        \\    .{ .name = "chunks" },
        \\    .{ .name = "chunks-disk", .prepare = "chunks-prepare", .fixture = "disk" },
        \\    .{ .name = "chunks-prepare", .internal = true, .peers = .{ "alice", "bob" } },
        \\} }
    );
    try std.testing.expectError(error.UnknownPreparation, testParse(
        \\.{ .client = "A", .scenarios = .{.{ .name = "a", .prepare = "b" }} }
    ));
    try std.testing.expectError(error.DuplicateTest, testParse(
        \\.{ .client = "A", .scenarios = .{ .{ .name = "a" }, .{ .name = "a" } } }
    ));
    try std.testing.expectError(error.InvalidTestName, testParse(
        \\.{ .client = "A", .scenarios = .{.{ .name = "A" }} }
    ));
    try std.testing.expectError(error.InvalidClient, testParse(
        \\.{ .client = "dev.A", .scenarios = .{.{ .name = "a" }} }
    ));
    try std.testing.expectError(error.DuplicatePeer, testParse(
        \\.{ .client = "A", .scenarios = .{.{ .name = "a", .peers = .{ "alice", "alice" } }} }
    ));
    try std.testing.expectError(error.InvalidPeerVersions, testParse(
        \\.{ .client = "A", .scenarios = .{.{ .name = "a", .mixed_versions = true }} }
    ));
}
