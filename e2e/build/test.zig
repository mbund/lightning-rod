//! The build of one e2e test: its server, its fixtures and a run step per scenario.
//!
//! A test is a package with a build.zig, a build.zig.zon that depends on this package, a
//! test.zon manifest, the server's sources and a client/ directory of Java fixtures in
//! package dev.lightningrod.e2e. Its build.zig is usually
//!
//!     const test_build = @import("lightning_rod_e2e").addTest(b, .{});
//!     _ = test_build.addServer(.{ .root_source_file = b.path("main.zig") });

const std = @import("std");
const protocol_catalog = @import("protocols").catalog;
const manifest = @import("../src/manifest.zig");
const selection = @import("../src/selection.zig");
const Clients = @import("clients.zig").Clients;

const assert = std.debug.assert;

pub const Options = struct {
    /// The manifest, relative to the test's build root.
    manifest: []const u8 = "test.zon",
    /// This package's name in the test's build.zig.zon.
    dependency: []const u8 = "lightning_rod_e2e",
};

pub const ServerOptions = struct {
    root_source_file: std.Build.LazyPath,
    /// Modules beyond the standard set, such as plugins the test declares itself.
    imports: []const std.Build.Module.Import = &.{},
};

/// Modules every test server can import, with the dependency of this package that provides each.
const standard_modules = [_]struct { name: []const u8, dependency: []const u8, module: []const u8 }{
    .{ .name = "bossbars", .dependency = "bossbars", .module = "bossbars" },
    .{ .name = "chat", .dependency = "chat", .module = "chat" },
    .{ .name = "chunks", .dependency = "chunks", .module = "chunks" },
    .{ .name = "commands", .dependency = "commands", .module = "commands" },
    .{ .name = "connection", .dependency = "connection", .module = "connection" },
    .{ .name = "e2e_control", .dependency = "e2e_control", .module = "e2e_control" },
    .{ .name = "entities", .dependency = "entities", .module = "entities" },
    .{ .name = "game_data", .dependency = "game_data", .module = "game_data" },
    .{ .name = "host", .dependency = "host", .module = "host" },
    .{ .name = "inventories", .dependency = "inventories", .module = "inventories" },
    .{ .name = "lightning_rod", .dependency = "lightning_rod", .module = "lightning_rod" },
    .{ .name = "minecraft_java", .dependency = "minecraft_java", .module = "minecraft_java" },
    .{ .name = "minecraft_model", .dependency = "minecraft_model", .module = "minecraft_model" },
    .{ .name = "players", .dependency = "players", .module = "players" },
    .{ .name = "records", .dependency = "records", .module = "records" },
    .{ .name = "reload", .dependency = "reload", .module = "reload" },
    .{ .name = "replication", .dependency = "replication", .module = "replication" },
    .{ .name = "sessions", .dependency = "sessions", .module = "sessions" },
    .{ .name = "terrain", .dependency = "terrain", .module = "terrain" },
    .{ .name = "vanilla", .dependency = "vanilla", .module = "lightning_rod_vanilla_1_21_6" },
    .{ .name = "wire_1_21_5", .dependency = "protocol_1_21_5", .module = "wire" },
    .{ .name = "worlds", .dependency = "worlds", .module = "worlds" },
};

pub const Test = struct {
    b: *std.Build,
    e2e: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    single_threaded: bool,
    manifest: manifest.Manifest,
    /// Comma-separated releases the selected scenarios need. Empty selects every release.
    releases: []const u8,
    runs: []const *std.Build.Step.Run,
    server_step: *std.Build.Step,
    /// The test directory name, which names the server.
    name: []const u8,
    /// -Dserver replaces whatever server the test builds.
    server_override: bool,
    has_server: bool,

    /// A module of the standard set, built for this test's target.
    pub fn module(self: *Test, name: []const u8) *std.Build.Module {
        if (std.mem.eql(u8, name, "e2e")) return self.e2e.module("e2e");
        if (std.mem.eql(u8, name, "protocols")) return self.protocols().module("protocols");
        if (std.mem.eql(u8, name, "e2e_profile")) return self.e2e.builder.dependency("e2e_profile", .{
            .target = self.target,
            .optimize = self.optimize,
            .@"single-threaded" = self.single_threaded,
        }).module("e2e_profile");
        for (standard_modules) |standard| {
            if (!std.mem.eql(u8, standard.name, name)) continue;
            return self.e2e.builder.dependency(standard.dependency, .{ .target = self.target, .optimize = self.optimize }).module(standard.module);
        }
        std.debug.panic("{s} is not a standard e2e module", .{name});
    }

    /// The module a dependency of the test's own build.zig.zon exports under its dependency name,
    /// such as a plugin, built for this test's target.
    pub fn import(self: *Test, name: []const u8) std.Build.Module.Import {
        return .{ .name = name, .module = self.b.dependency(name, .{ .target = self.target, .optimize = self.optimize }).module(name) };
    }

    /// Builds the test server from `root_source_file` with the standard modules, the selected
    /// protocols and `imports`, and runs every scenario against it.
    pub fn addServer(self: *Test, options: ServerOptions) *std.Build.Step.Compile {
        const b = self.b;
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        for (standard_modules) |standard| imports.append(b.allocator, .{ .name = standard.name, .module = self.module(standard.name) }) catch @panic("OOM");
        for ([_][]const u8{ "e2e", "e2e_profile", "protocols" }) |name| imports.append(b.allocator, .{ .name = name, .module = self.module(name) }) catch @panic("OOM");
        imports.appendSlice(b.allocator, options.imports) catch @panic("OOM");
        // The packet layer and the harness read the selected protocols, which only a server chooses.
        self.e2e.builder.dependency("minecraft_packets", .{ .target = self.target, .optimize = self.optimize })
            .module("minecraft_packets").addImport("protocols", self.module("protocols"));
        self.e2e.module("e2e").addImport("protocols", self.module("protocols"));
        const server = b.addExecutable(.{
            .name = b.fmt("e2e-{s}", .{self.name}),
            .root_module = b.createModule(.{
                .root_source_file = options.root_source_file,
                .target = self.target,
                .optimize = self.optimize,
                .single_threaded = self.single_threaded,
                .imports = imports.items,
            }),
        });
        b.installArtifact(server);
        self.useServer(server.getEmittedBin());
        return server;
    }

    /// Runs every scenario against an executable built elsewhere, such as an example
    /// application or a server with its own protocols.
    pub fn useServer(self: *Test, executable: std.Build.LazyPath) void {
        if (self.server_override) return;
        assert(!self.has_server);
        self.has_server = true;
        for (self.runs) |run| {
            run.addArg("--server");
            run.addFileArg(executable);
        }
        executable.addStepDependencies(self.server_step);
    }

    fn protocols(self: *Test) *std.Build.Dependency {
        return self.e2e.builder.dependency("protocols", .{ .target = self.target, .optimize = self.optimize, .releases = self.releases });
    }
};

pub fn add(b: *std.Build, options: Options) *Test {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Run all fixture services on the simulation owner") orelse false;
    const realtime = b.option(bool, "realtime", "Run the server and its threads with FIFO scheduling") orelse false;
    const server_releases = b.option([]const u8, "server-releases", "Minecraft releases selected for the test server");
    const requested_version = b.option([]const u8, "client-version", "Minecraft client release");
    const requested_scenario = b.option([]const u8, "scenario", "Run one scenario (default: every scenario of this test)");
    const upgrade_from = b.option([]const u8, "upgrade-from", "Previous revision for upgrade scenarios") orelse "HEAD^";
    const server_override = b.option([]const u8, "server", "Override the test's server executable");
    const address = b.option([]const u8, "address", "Minecraft server address") orelse "127.0.0.1:0";
    const artifacts = b.option([]const u8, "artifacts", "Override the artifact root (default: artifacts/ in the test directory)");

    b.dependOnFileContents(b.path(options.manifest));
    const manifest_path = b.root.joinString(b.allocator, options.manifest) catch @panic("OOM");
    const test_manifest = manifest.read(b.graph.io, b.allocator, b.allocator, manifest_path) catch |err|
        std.debug.panic("Cannot read {s}: {s}", .{ manifest_path, @errorName(err) });

    var selected: std.ArrayList(manifest.Scenario) = .empty;
    if (requested_scenario) |name| {
        const scenario = test_manifest.find(name) orelse {
            for (test_manifest.scenarios) |scenario| std.log.info("scenario: {s}", .{scenario.name});
            std.debug.panic("Unknown scenario '{s}' in {s}", .{ name, manifest_path });
        };
        selected.append(b.allocator, scenario) catch @panic("OOM");
    } else for (test_manifest.scenarios) |scenario| {
        if (!scenario.internal) selected.append(b.allocator, scenario) catch @panic("OOM");
    }

    const latest = protocol_catalog.latest.minecraft_version;
    // Each run's peers, by primary release.
    const versions = b.allocator.alloc([]const u8, selected.items.len) catch @panic("OOM");
    const peers = b.allocator.alloc([]const []const u8, selected.items.len) catch @panic("OOM");
    var releases: std.ArrayList([]const u8) = .empty;
    var every_release = false;
    for (selected.items, versions, peers) |scenario, *version, *peer_versions| {
        version.* = requested_version orelse scenario.version orelse latest;
        peer_versions.* = selection.peerVersions(protocol_catalog, b.allocator, scenario, version.*) catch |err|
            std.debug.panic("Cannot select clients for {s}: {s}", .{ scenario.name, @errorName(err) });
        every_release = every_release or scenario.full_protocols;
        if (scenario.upgrade) {
            for (protocol_catalog.versions) |release| appendUnique(b, &releases, release.minecraft_version);
        } else for (peer_versions.*) |release| appendUnique(b, &releases, release);
    }
    const selected_releases = server_releases orelse if (every_release)
        ""
    else
        std.mem.join(b.allocator, ",", releases.items) catch @panic("OOM");

    const e2e = b.dependency(options.dependency, .{
        .target = target,
        .optimize = optimize,
        .@"single-threaded" = single_threaded,
    });
    const sources = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, b.root.joinString(b.allocator, "client") catch @panic("OOM"), b.allocator) catch
        std.debug.panic("A test keeps its Java fixtures in client/", .{});
    var clients = Clients.init(b, e2e, sources);
    const directory = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, b.root.joinString(b.allocator, ".") catch @panic("OOM"), b.allocator) catch @panic("Cannot resolve the test directory");
    const key = e2e.builder.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).path("tests/fixtures/rsa-key.der");

    const run_step = b.step("e2e", "Run this test's scenarios one after another (or select -Dscenario)");
    const server_step = b.step("server", "Build the test server without starting clients");
    const fixtures_step = b.step("fixtures", "Compile the Java fixtures for the selected clients");
    const runs = b.allocator.alloc(*std.Build.Step.Run, selected.items.len) catch @panic("OOM");
    var previous: ?*std.Build.Step = null;
    for (selected.items, versions, peers, runs) |scenario, version, peer_versions, *run| {
        run.* = b.addRunArtifact(e2e.artifact("lightning-rod-e2e"));
        run.*.setName(b.fmt("e2e {s} {s}", .{ scenario.name, version }));
        run.*.has_side_effects = true;
        run.*.setCwd(.{ .cwd_relative = directory });
        run.*.step.dependOn(server_step);
        if (previous) |step| run.*.step.dependOn(step);
        previous = &run.*.step;
        run.*.addArg("--manifest");
        run.*.addFileArg(b.path(options.manifest));
        run.*.addArgs(&.{ "--directory", directory, "--scenario", scenario.name, "--client-version", version, "--address", address });
        run.*.addArgs(&.{ "--realtime", if (realtime) "true" else "false" });
        // Tick budgets measure release servers. Debug compiles faster and reports them only.
        run.*.addArgs(&.{ "--performance-budget", if (optimize == .debug) "report" else "enforce" });
        if (artifacts) |path| run.*.addArgs(&.{ "--artifacts", path });
        if (scenario.upgrade) run.*.addArgs(&.{ "--upgrade-from", upgrade_from });
        run.*.addArg("--key");
        run.*.addFileArg(key);
        for (peer_versions, 0..) |release, index| {
            if (contains(peer_versions[0..index], release)) continue;
            run.*.addArgs(&.{ "--client", release });
            run.*.addDirectoryArg(clients.bundle(release));
            run.*.addDirectoryArg(clients.compiled(release));
            clients.compiled(release).addStepDependencies(fixtures_step);
        }
        run_step.dependOn(&run.*.step);
    }

    const result = b.allocator.create(Test) catch @panic("OOM");
    result.* = .{
        .b = b,
        .e2e = e2e,
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
        .manifest = test_manifest,
        .releases = selected_releases,
        .runs = runs,
        .server_step = server_step,
        .name = std.fs.path.basename(directory),
        .server_override = server_override != null,
        .has_server = server_override != null,
    };
    if (server_override) |path| for (runs) |run| run.addArgs(&.{ "--server", path });
    return result;
}

fn contains(values: []const []const u8, value: []const u8) bool {
    for (values) |existing| if (std.mem.eql(u8, existing, value)) return true;
    return false;
}

fn appendUnique(b: *std.Build, values: *std.ArrayList([]const u8), value: []const u8) void {
    if (!contains(values.items, value)) values.append(b.allocator, value) catch @panic("OOM");
}
