//! A suite of e2e tests: every subdirectory of a root that holds a test.zon and a build.zig.
//! Each test builds and runs itself. The suite finds the test that offers a scenario, prints
//! the CI matrix, and runs every scenario through its own test's build.

const std = @import("std");
const discovery = @import("../src/discovery.zig");

pub const Options = struct {
    /// The directory holding the tests, relative to the suite's build root.
    root: []const u8 = ".",
    /// This package's name in the suite's build.zig.zon.
    dependency: []const u8 = "lightning_rod_e2e",
};

pub fn add(b: *std.Build, options: Options) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const scenario = b.option([]const u8, "scenario", "Run one scenario (default: every scenario of every test)");
    const requested_version = b.option([]const u8, "client-version", "Minecraft client release");
    // Passed through to each test's build.
    const forwarded = [_]struct { name: []const u8, description: []const u8 }{
        .{ .name = "single-threaded", .description = "Run all fixture services on the simulation owner" },
        .{ .name = "realtime", .description = "Run the server and its threads with FIFO scheduling" },
        .{ .name = "server-releases", .description = "Minecraft releases selected for the test server" },
        .{ .name = "upgrade-from", .description = "Previous revision for upgrade scenarios" },
        .{ .name = "server", .description = "Override the test's server executable" },
        .{ .name = "address", .description = "Minecraft server address" },
        .{ .name = "artifacts", .description = "Override the artifact root (default: artifacts/ in each test directory)" },
    };
    var arguments: std.ArrayList([]const u8) = .empty;
    arguments.append(b.allocator, b.fmt("-Doptimize={s}", .{@tagName(optimize)})) catch @panic("OOM");
    if (!target.query.isNative()) {
        arguments.append(b.allocator, b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")})) catch @panic("OOM");
        arguments.append(b.allocator, b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")})) catch @panic("OOM");
    }
    for (forwarded) |option| {
        const value = b.option([]const u8, option.name, option.description) orelse continue;
        arguments.append(b.allocator, b.fmt("-D{s}={s}", .{ option.name, value })) catch @panic("OOM");
    }

    const root = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, b.root.joinString(b.allocator, options.root) catch @panic("OOM"), b.allocator) catch
        std.debug.panic("Cannot open the test root {s}", .{options.root});
    b.dependOnDirectoryMetadata(.{ .cwd_relative = root });
    const tests = discovery.discover(b.graph.io, b.allocator, b.allocator, root) catch |err|
        std.debug.panic("Cannot discover e2e tests in {s}: {s}", .{ root, @errorName(err) });
    for (tests) |found| b.dependOnFileContents(.{ .cwd_relative = b.pathJoin(&.{ root, found.directory, "test.zon" }) });

    const e2e = b.dependency(options.dependency, .{});
    const matrix = b.addRunArtifact(e2e.artifact("e2e-matrix"));
    matrix.has_side_effects = true;
    matrix.addArg(root);
    if (requested_version) |version| matrix.addArg(version);
    b.step("e2e-matrix", "Print the GitHub Actions matrix of every scenario as JSON").dependOn(&matrix.step);

    const list = b.addRunArtifact(e2e.artifact("e2e-matrix"));
    list.has_side_effects = true;
    list.addArgs(&.{ "--list", root });
    b.step("list-tests", "List every runnable scenario and its test directory").dependOn(&list.step);

    const servers = b.step("servers", "Build every test's server without starting clients");
    // One at a time, since each compiles a whole server.
    var previous_server: ?*std.Build.Step = null;
    for (tests) |found| {
        const build_server = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "server" });
        build_server.setName(b.fmt("server {s}", .{found.directory}));
        build_server.setCwd(.{ .cwd_relative = b.pathJoin(&.{ root, found.directory }) });
        build_server.addArgs(arguments.items);
        build_server.has_side_effects = true;
        if (previous_server) |step| build_server.step.dependOn(step);
        previous_server = &build_server.step;
        servers.dependOn(&build_server.step);
    }

    const suite = b.step("e2e", "Run every scenario of every test one after another (or select -Dscenario)");
    if (scenario) |name| {
        const found = discovery.find(tests, name) orelse std.debug.panic("Unknown e2e scenario '{s}'; use zig build list-tests", .{name});
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "e2e", b.fmt("-Dscenario={s}", .{name}) });
        run.setName(b.fmt("e2e {s}", .{name}));
        run.setCwd(.{ .cwd_relative = b.pathJoin(&.{ root, found.directory }) });
        run.addArgs(arguments.items);
        if (requested_version) |version| run.addArg(b.fmt("-Dclient-version={s}", .{version}));
        run.has_side_effects = true;
        suite.dependOn(&run.step);
    } else {
        const entries = b.addRunArtifact(e2e.artifact("e2e-matrix"));
        entries.has_side_effects = true;
        entries.addArg(root);
        if (requested_version) |version| entries.addArg(version);
        const run = b.addRunArtifact(e2e.artifact("e2e-suite"));
        run.addFileArg(entries.captureStdOut(.{}));
        run.addArgs(&.{ root, b.graph.zig_exe });
        run.addArgs(arguments.items);
        run.has_side_effects = true;
        suite.dependOn(&run.step);
    }
}
