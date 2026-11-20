//! The e2e library: the harness module test servers import, the runner, the Minecraft client
//! build, and the build API tests and suites use. A test is its own package (see
//! build/test.zig), and tests/ is the suite of this repository's tests (see build/suite.zig).

const std = @import("std");
const test_build = @import("build/test.zig");
const suite_build = @import("build/suite.zig");
const Clients = @import("build/clients.zig").Clients;

pub const Manifest = @import("src/manifest.zig").Manifest;
pub const Scenario = @import("src/manifest.zig").Scenario;
pub const Test = test_build.Test;
pub const TestOptions = test_build.Options;
pub const ServerOptions = test_build.ServerOptions;
pub const SuiteOptions = suite_build.Options;
pub const addTest = test_build.add;
pub const addSuite = suite_build.add;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Run all fixture services on the simulation owner") orelse false;
    const protocol_catalog = b.createModule(.{ .root_source_file = b.dependency("protocols", .{}).path("catalog.zig") });

    const runner = b.addExecutable(.{
        .name = "lightning-rod-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol_catalog", .module = protocol_catalog },
                .{ .name = "reload_execve", .module = b.dependency("reload_execve", .{ .target = target, .optimize = optimize }).module("reload_execve") },
            },
        }),
    });
    b.installArtifact(runner);
    for ([_][]const u8{ "fixtures", "matrix", "suite" }) |tool| {
        b.installArtifact(b.addExecutable(.{
            .name = b.fmt("e2e-{s}", .{tool}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{tool})),
                .target = b.graph.host,
                .optimize = .debug,
                .imports = &.{.{ .name = "protocol_catalog", .module = protocol_catalog }},
            }),
        }));
    }

    const names = .{ "chat", "chunks", "connection", "e2e_control", "entities", "host", "inventories", "lightning_rod", "minecraft_java", "players", "reload", "sessions", "terrain" };
    var imports: [names.len + 4]std.Build.Module.Import = undefined;
    inline for (names, 0..) |name, index| {
        imports[index] = .{ .name = name, .module = b.dependency(name, .{ .target = target, .optimize = optimize }).module(name) };
    }
    imports[names.len] = .{ .name = "vanilla", .module = b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6") };
    imports[names.len + 1] = .{ .name = "e2e_profile", .module = b.dependency("e2e_profile", .{ .target = target, .optimize = optimize, .@"single-threaded" = single_threaded }).module("e2e_profile") };
    imports[names.len + 2] = .{ .name = "wire_1_21_5", .module = b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire") };
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = @as([]const u8, "") });
    imports[names.len + 3] = .{ .name = "minecraft_model", .module = b.dependency("minecraft_model", .{ .target = target, .optimize = optimize }).module("minecraft_model") };
    const execution = b.addOptions();
    execution.addOption(bool, "single_threaded", single_threaded);
    const harness = b.addModule("e2e", .{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize, .imports = &imports });
    harness.addOptions("execution", execution);

    // A test server selects its protocols for the packet layer and the harness. Standalone, this
    // package selects every release for its own checks, as servers do by default.
    if (b.dep_prefix.len == 0) {
        b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
        harness.addImport("protocols", protocols.module("protocols"));
        b.dependency("e2e_control", .{ .target = target, .optimize = optimize }).module("e2e_control").addImport("protocols", protocols.module("protocols"));
    }

    const check_runner = b.step("check-runner", "Compile the E2E runner without starting Java");
    check_runner.dependOn(&runner.step);
    const performance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/performance.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test-performance", "Test performance budget accumulation and statistics").dependOn(&b.addRunArtifact(performance_tests).step);
    const test_harness = b.step("test-harness", "Verify E2E manifests, version selection, client launches and shutdown outcomes");
    for ([_][]const u8{ "child", "listener", "process_cleanup", "scheduling", "manifest", "client_bundle", "session_server" }) |name| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        }) });
        test_harness.dependOn(&b.addRunArtifact(tests).step);
    }
    const selection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/selection_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "protocol_catalog", .module = protocol_catalog }},
    }) });
    test_harness.dependOn(&b.addRunArtifact(selection_tests).step);
    const control_tests = b.addTest(.{ .root_module = b.dependency("e2e_control", .{ .target = target, .optimize = optimize }).module("e2e_control") });
    test_harness.dependOn(&b.addRunArtifact(control_tests).step);

    const artifacts_compile = b.addSystemCommand(&.{ "javac", "-d" });
    const artifacts_classes = artifacts_compile.addOutputDirectoryArg("classes");
    artifacts_compile.addFileArg(b.path("client/src/client/java/dev/lightningrod/e2e/Artifacts.java"));
    artifacts_compile.addFileArg(b.path("client/src/test/java/dev/lightningrod/e2e/ArtifactsTest.java"));
    const artifacts_test = b.addSystemCommand(&.{ "java", "-cp" });
    artifacts_test.addDirectoryArg(artifacts_classes);
    artifacts_test.addArg("dev.lightningrod.e2e.ArtifactsTest");
    b.step("test-artifacts", "Verify atomic Java artifact publication").dependOn(&artifacts_test.step);

    b.dependOnFileContents(b.path("client/gradle.properties"));
    const properties = std.Io.Dir.cwd().readFileAlloc(b.graph.io, (b.root.joinString(b.allocator, "client/gradle.properties") catch @panic("OOM")), b.allocator, .limited(4096)) catch @panic("Cannot read client version");
    var lines = std.mem.splitScalar(u8, properties, '\n');
    const default_version = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "minecraft_version=")) break std.mem.trim(u8, line["minecraft_version=".len..], "\r ");
    } else @panic("Missing default client version");
    const client_version = b.option([]const u8, "client-version", "Minecraft client release for prepare-client") orelse default_version;
    // The clients build reads this package's sources and tools through a dependency handle.
    const self = b.allocator.create(std.Build.Dependency) catch @panic("OOM");
    self.* = .{ .builder = b };
    var clients = Clients.init(b, self, null);
    const prepare_client = b.step("prepare-client", "Prepare the selected Minecraft client runtime without running an E2E");
    clients.bundle(client_version).addStepDependencies(prepare_client);
    const client_test = b.addRunArtifact(runner);
    client_test.setCwd(b.path("."));
    client_test.addArgs(&.{ "--test-client", default_version });
    client_test.addDirectoryArg(clients.bundle(default_version));
    client_test.has_side_effects = true;
    b.step("test-client", "Verify fixture messages and screenshot completion").dependOn(&client_test.step);

    const upgrade_versions = b.addRunArtifact(runner);
    upgrade_versions.addArg("--upgrade-releases");
    b.step("upgrade-releases", "List protocols supported by the previous upgrade fixture").dependOn(&upgrade_versions.step);
}
