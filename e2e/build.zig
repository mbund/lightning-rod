const protocol_definitions = @import("protocols");
const std = @import("std");
const catalog = @import("src/catalog.zig");
const selection = @import("src/selection.zig");
const client_build = @import("src/client_build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Run all fixture services on the simulation owner") orelse false;
    const realtime = b.option(bool, "realtime", "Run the server and its threads with FIFO scheduling") orelse false;
    const tests_root = b.option([]const u8, "tests", "Directory containing E2E fixtures") orelse "tests";
    const server_releases = b.option([]const u8, "server-releases", "Minecraft releases selected for the test server");
    const requested_version = b.option([]const u8, "client-version", "Minecraft client release");
    const scenario = b.option([]const u8, "scenario", "Run one E2E scenario (default: all)");
    const upgrade_from = b.option([]const u8, "upgrade-from", "Previous revision for the upgrade E2E") orelse "HEAD^";
    const tests_path = if (std.fs.path.isAbsolute(tests_root)) tests_root else b.root.joinString(b.allocator, tests_root) catch @panic("OOM");
    b.dependOnDirectoryContents(.{ .cwd_relative = tests_path });
    const tests_directory = std.Io.Dir.cwd().openDir(b.graph.io, tests_path, .{ .iterate = true }) catch @panic("Cannot open E2E tests");
    defer tests_directory.close(b.graph.io);
    var entries = tests_directory.iterate();
    while (entries.next(b.graph.io) catch @panic("Cannot discover E2E test directories")) |entry| {
        if (entry.kind == .directory) b.dependOnDirectoryContents(.{ .cwd_relative = b.pathJoin(&.{ tests_path, entry.name }) });
    }
    const cases = catalog.load(b.allocator, b.graph.io, tests_path) catch |err| std.debug.panic("Cannot discover E2E tests: {s}", .{@errorName(err)});
    for (cases) |selected| b.dependOnFileContents(.{ .cwd_relative = b.pathJoin(&.{ selected.directory, "test.json" }) });
    const selected_case = if (scenario) |name| catalog.find(cases, name) orelse
        std.debug.panic("Unknown E2E test '{s}'; use zig build list-tests", .{name}) else null;
    const client_version = requested_version orelse (if (selected_case) |selected| selected.version else null) orelse protocol_definitions.catalog.latest.minecraft_version;
    const peer_versions = if (selected_case) |selected|
        selection.peerVersions(protocol_definitions.catalog, b.allocator, selected, client_version) catch |err|
            std.debug.panic("Cannot select E2E clients: {s}", .{@errorName(err)})
    else
        &.{};
    var upgrade_releases: [protocol_definitions.catalog.versions.len][]const u8 = undefined;
    for (protocol_definitions.catalog.versions, &upgrade_releases) |version, *name| name.* = version.minecraft_version;
    const selected_releases = server_releases orelse if (selected_case != null and selected_case.?.upgrade)
        std.mem.join(b.allocator, ",", &upgrade_releases) catch @panic("out of memory")
    else if (selected_case != null and !selected_case.?.full_protocols)
        std.mem.join(b.allocator, ",", peer_versions) catch @panic("out of memory")
    else
        "";
    const protocols = b.dependency("protocols", .{
        .target = target,
        .optimize = optimize,
        .releases = selected_releases,
    });
    const protocol_catalog_module = b.createModule(.{ .root_source_file = protocols.path("catalog.zig") });
    const matrix = b.addExecutable(.{
        .name = "e2e-matrix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/matrix.zig"),
            .target = b.graph.host,
            .optimize = .debug,
            .imports = &.{.{
                .name = "protocol_catalog",
                .module = protocol_catalog_module,
            }},
        }),
    });
    const emit_matrix = b.addRunArtifact(matrix);
    emit_matrix.setCwd(b.path("."));
    emit_matrix.addArg(tests_path);
    if (requested_version) |version| emit_matrix.addArg(version);
    b.step("e2e-matrix", "Print the GitHub Actions E2E matrix as JSON").dependOn(&emit_matrix.step);

    const names = .{ "records", "inventories", "e2e_profile", "host", "lightning_rod", "vanilla", "game_data", "minecraft_java", "minecraft_model", "sessions", "protocols", "tps", "economy", "shop", "silk_spawners", "storm_stick", "economy_commands", "shop_commands", "e2e_control", "skyblock" };
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, i| {
        const dependency = if (comptime std.mem.eql(u8, name, "protocols")) protocols else if (comptime std.mem.eql(u8, name, "skyblock")) b.dependency(name, .{ .target = target, .optimize = optimize, .releases = selected_releases }) else if (comptime std.mem.eql(u8, name, "e2e_profile")) b.dependency(name, .{ .target = target, .optimize = optimize, .@"single-threaded" = single_threaded }) else b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[i] = .{
            .name = name,
            .module = dependency.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name),
        };
    }

    const runner = b.addExecutable(.{
        .name = "lightning-rod-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol_catalog", .module = protocol_catalog_module },
                .{
                    .name = "reload_execve",
                    .module = b.dependency("reload_execve", .{ .target = target, .optimize = optimize }).module("reload_execve"),
                },
            },
        }),
    });
    const selection_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/selection_test.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "protocol_catalog", .module = protocol_catalog_module }},
    }) });
    const check_runner = b.step("check-runner", "Compile the E2E runner without starting Java");
    check_runner.dependOn(&runner.step);
    const performance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/performance.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_performance = b.addRunArtifact(performance_tests);
    b.step("test-performance", "Test performance budget accumulation and statistics").dependOn(&test_performance.step);
    const child_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/child.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_harness = b.step("test-harness", "Verify E2E version selection and shutdown outcomes");
    const listener_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/listener.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_harness.dependOn(&b.addRunArtifact(listener_tests).step);
    const cleanup_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/process_cleanup.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_harness.dependOn(&b.addRunArtifact(cleanup_tests).step);
    const scheduling_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/scheduling.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_harness.dependOn(&b.addRunArtifact(scheduling_tests).step);
    test_harness.dependOn(&b.addRunArtifact(child_tests).step);
    test_harness.dependOn(&b.addRunArtifact(selection_tests).step);
    const artifacts_compile = b.addSystemCommand(&.{ "javac", "-d" });
    const artifacts_classes = artifacts_compile.addOutputDirectoryArg("classes");
    artifacts_compile.addFileArg(b.path("client/src/client/java/dev/lightningrod/e2e/Artifacts.java"));
    artifacts_compile.addFileArg(b.path("client/src/test/java/dev/lightningrod/e2e/ArtifactsTest.java"));
    const artifacts_test = b.addSystemCommand(&.{ "java", "-cp" });
    artifacts_test.addDirectoryArg(artifacts_classes);
    artifacts_test.addArg("dev.lightningrod.e2e.ArtifactsTest");
    b.step("test-artifacts", "Verify atomic Java artifact publication").dependOn(&artifacts_test.step);

    var clients = client_build.Clients.init(b, tests_path);
    const prepare_client = b.step("prepare-client", "Prepare the selected Minecraft client without running an E2E");
    if (b.graph.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS") == null) {
        const bundle = clients.get(client_version);
        bundle.addStepDependencies(prepare_client);
    }
    const client_test_step = b.step("test-client", "Verify fixture messages and screenshot completion");
    const client_test = b.addRunArtifact(runner);
    client_test.setCwd(b.path("."));
    b.dependOnFileContents(b.path("client/gradle.properties"));
    const properties = std.Io.Dir.cwd().readFileAlloc(b.graph.io, (b.root.joinString(b.allocator, "client/gradle.properties") catch @panic("OOM")), b.allocator, .limited(4096)) catch @panic("Cannot read client version");
    var lines = std.mem.splitScalar(u8, properties, '\n');
    const default_version = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "minecraft_version=")) break std.mem.trim(u8, line["minecraft_version=".len..], "\r ");
    } else @panic("Missing default client version");
    client_test.addArgs(&.{ "--test-client", default_version });
    if (b.graph.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS") == null) client_test.addDirectoryArg(clients.get(default_version));
    client_test.has_side_effects = true;
    client_test_step.dependOn(&client_test.step);

    const list = b.addRunArtifact(runner);
    const upgrade_versions = b.addRunArtifact(runner);
    upgrade_versions.addArg("--upgrade-releases");
    b.step("upgrade-releases", "List protocols supported by the previous upgrade fixture").dependOn(&upgrade_versions.step);
    list.setCwd(b.path("."));
    list.addArg("--list");
    list.addArgs(&.{ "--tests", tests_path });
    b.step("list-tests", "List automatically discovered E2E tests and their directories").dependOn(&list.step);

    const server = b.option([]const u8, "server", "Override the test's server executable");
    const address = b.option([]const u8, "address", "Minecraft server address") orelse "127.0.0.1:0";
    const artifacts = b.option([]const u8, "artifacts", "Override artifact root (default: each test directory's artifacts/)");
    const suite = b.step("e2e", "Run all discovered E2E tests sequentially (or select -Dscenario)");
    const servers = b.step("build-test-servers", "Build servers for the selected E2E tests without running Java");
    var previous: ?*std.Build.Step = null;
    var test_servers: std.StringHashMap(*std.Build.Step.Compile) = .init(b.allocator);

    const execution = b.addOptions();
    execution.addOption(bool, "single_threaded", single_threaded);
    const harness_module = b.createModule(.{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize, .imports = &imports });
    harness_module.addOptions("execution", execution);
    harness_module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));
    const control_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.dependency("e2e_control", .{ .target = target, .optimize = optimize }).path("src/control.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    }) });
    test_harness.dependOn(&b.addRunArtifact(control_tests).step);
    for (cases) |selected| {
        if (scenario) |name| {
            if (!std.mem.eql(u8, selected.name, name)) continue;
        } else if (selected.internal) continue;
        const run = b.addRunArtifact(runner);
        run.step.name = b.fmt("e2e {s}", .{selected.name});
        run.has_side_effects = true;
        run.step.dependOn(servers);

        if (previous) |step| run.step.dependOn(step);
        previous = &run.step;
        run.setCwd(b.path("."));
        if (scenario != null and b.graph.environ_map.get("LIGHTNING_ROD_E2E_CLIENTS") == null) {
            const versions = selection.peerVersions(protocol_definitions.catalog, b.allocator, selected, client_version) catch @panic("Cannot select client versions");
            for (versions, 0..) |version, index| {
                if (for (versions[0..index]) |previous_version| {
                    if (std.mem.eql(u8, version, previous_version)) break true;
                } else false) continue;
                run.addArg("--clients");
                run.addDirectoryArg(clients.get(version));
            }
        }
        const key_path = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).builder.root.joinString(b.allocator, "tests/fixtures/rsa-key.der") catch @panic("OOM");
        const key = std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, key_path, b.allocator) catch @panic("Cannot resolve the fixture encryption key");
        run.setEnvironmentVariable("LIGHTNING_ROD_E2E_KEY", key);
        run.addArgs(&.{ "--scenario", selected.name, "--realtime", if (realtime) "true" else "false" });
        if (artifacts) |directory| run.addArgs(&.{ "--artifacts", directory });
        run.addArgs(&.{ "--address", address });
        run.addArgs(&.{ "--client-version", client_version });
        if (selected.upgrade) run.addArgs(&.{ "--upgrade-from", upgrade_from });
        run.addArgs(&.{ "--tests", tests_path });

        if (server) |path| {
            run.addArgs(&.{ "--server", path });
        } else if (selected.standalone) {
            const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Doptimize={s}", .{@tagName(optimize)}) });

            compile.addArg("--prefix");
            compile.has_side_effects = true;
            compile.setCwd(.{ .cwd_relative = selected.directory });
            const output = compile.addOutputDirectoryArg("server");
            run.addArg("--server");
            run.addFileArg(output.path(b, "bin/lightning_rod"));
            servers.dependOn(&compile.step);
        } else {
            const main_path = b.pathJoin(&.{ selected.directory, "main.zig" });
            const file = std.Io.Dir.cwd().openFile(b.graph.io, main_path, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => std.debug.panic("Cannot read test server: {s}", .{@errorName(err)}),
            };

            if (file) |source| {
                source.close(b.graph.io);
                if (test_servers.get(selected.directory)) |test_server| {
                    run.addArg("--server");
                    run.addArtifactArg(test_server);
                    continue;
                }
                const test_server = b.addExecutable(.{
                    .name = b.fmt("e2e-{s}", .{std.fs.path.basename(selected.directory)}),
                    .root_module = b.createModule(.{
                        .root_source_file = .{ .cwd_relative = main_path },
                        .target = target,
                        .optimize = optimize,
                        .single_threaded = single_threaded,
                        .imports = &imports,
                    }),
                });
                test_server.root_module.addImport("e2e", harness_module);
                test_server.root_module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));
                test_servers.put(selected.directory, test_server) catch @panic("out of memory");
                run.addArg("--server");
                run.addArtifactArg(test_server);
                servers.dependOn(&test_server.step);
            } else if (selected.fixture != null) {
                std.debug.panic("E2E fixture {s} needs a main.zig in {s}", .{ selected.name, selected.directory });
            } else {
                const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build", b.fmt("-Doptimize={s}", .{@tagName(optimize)}) });

                if (selected_releases.len != 0)
                    compile.addArg(b.fmt("-Dreleases={s}", .{selected_releases}));
                compile.addArg("--prefix");
                compile.has_side_effects = true;
                compile.setCwd(.{ .cwd_relative = b.fmt("../examples/{s}", .{selected.application}) });
                const output = compile.addOutputDirectoryArg("server");
                run.addArg("--server");
                run.addFileArg(output.path(b, "bin/lightning_rod"));
                servers.dependOn(&compile.step);
            }
        }
    }

    if (scenario != null) {
        suite.dependOn(previous orelse std.debug.panic("No E2E tests discovered", .{}));
    } else {
        const suite_matrix = b.addRunArtifact(matrix);
        suite_matrix.setCwd(b.path("."));
        suite_matrix.addArg(tests_path);
        if (requested_version) |version| suite_matrix.addArg(version);
        const suite_runner = b.addExecutable(.{ .name = "e2e-suite", .root_module = b.createModule(.{
            .root_source_file = b.path("src/suite.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }) });
        const run_suite = b.addRunArtifact(suite_runner);
        run_suite.addFileArg(suite_matrix.captureStdOut(.{}));
        run_suite.addArgs(&.{ b.graph.zig_exe, b.fmt("-Doptimize={s}", .{@tagName(optimize)}), b.fmt("-Dtests={s}", .{tests_root}), b.fmt("-Daddress={s}", .{address}) });

        run_suite.addArg(b.fmt("-Drealtime={s}", .{if (realtime) "true" else "false"}));
        run_suite.addArg(b.fmt("-Dsingle-threaded={s}", .{if (single_threaded) "true" else "false"}));
        if (!target.query.isNative()) {
            run_suite.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("out of memory")}));
            run_suite.addArg(b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("out of memory")}));
        }
        if (server_releases) |releases| run_suite.addArg(b.fmt("-Dserver-releases={s}", .{releases}));
        run_suite.addArg(b.fmt("-Dupgrade-from={s}", .{upgrade_from}));
        if (server) |path| run_suite.addArg(b.fmt("-Dserver={s}", .{path}));
        if (artifacts) |path| run_suite.addArg(b.fmt("-Dartifacts={s}", .{path}));
        run_suite.has_side_effects = true;
        run_suite.setCwd(b.path("."));
        suite.dependOn(&run_suite.step);
    }
}
