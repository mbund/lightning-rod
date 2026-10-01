const std = @import("std");
const catalog = @import("src/catalog.zig");
const protocol_catalog = @import("protocols").catalog;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    if (b.release_mode == .off) b.release_mode = .safe;
    const optimize = b.standardOptimizeOption(.{});
    const tests_root = b.option([]const u8, "tests", "Directory containing E2E fixtures") orelse "tests";
    const server_releases = b.option([]const u8, "server-releases", "Minecraft releases selected for the test server");
    const client_version = b.option([]const u8, "client-version", "Minecraft client release") orelse protocol_catalog.latest.minecraft_version;
    const scenario = b.option([]const u8, "scenario", "Run one E2E scenario (default: all)");
    const cases = catalog.load(b.allocator, b.graph.io, b.pathFromRoot(tests_root)) catch |err| std.debug.panic("Cannot discover E2E tests: {s}", .{@errorName(err)});
    const selected_case = if (scenario) |name| catalog.find(cases, name) orelse
        std.debug.panic("Unknown E2E test '{s}'; use zig build list-tests", .{name}) else null;
    const selected_releases = server_releases orelse if (selected_case) |selected|
        selected.server_releases orelse if (selected.peer_versions.len != 0)
            std.mem.join(b.allocator, ",", selected.peer_versions) catch @panic("out of memory")
        else
            client_version
    else
        "";
    const protocols = b.dependency("protocols", .{
        .target = target,
        .optimize = optimize,
        .releases = selected_releases,
    });
    const matrix = b.addExecutable(.{
        .name = "e2e-matrix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/matrix.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "protocol_catalog",
                .module = b.createModule(.{ .root_source_file = protocols.path("catalog.zig") }),
            }},
        }),
    });
    const emit_matrix = b.addRunArtifact(matrix);
    emit_matrix.setCwd(b.path("."));
    emit_matrix.addArg(b.pathFromRoot(tests_root));
    b.step("e2e-matrix", "Print the GitHub Actions E2E matrix as JSON").dependOn(&emit_matrix.step);

    const backend = b.option(enum { uring, stdio }, "io", "Fixture networking implementation") orelse .uring;
    const profile = if (backend == .uring) "lightning_rod_linux" else "lightning_rod_stdio";
    const names = .{ "lightning_rod", "lightning_rod_linux", "vanilla", "sessions", "protocols", "bossbars", "tps" };
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, i| {
        const selected = if (comptime std.mem.eql(u8, name, "lightning_rod_linux")) profile else name;
        const dependency = if (comptime std.mem.eql(u8, name, "protocols")) protocols else b.dependency(selected, .{ .target = target, .optimize = optimize });
        imports[i] = .{
            .name = name,
            .module = dependency.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else selected),
        };
    }

    const fixture_server = b.addExecutable(.{
        .name = "fixture-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
            .link_libc = true,
        }),
    });
    fixture_server.root_module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));

    if (b.option([]const u8, "crypto-directory", "OpenSSL library directory for the fixture server") orelse b.graph.environ_map.get("OPENSSL_LIB_DIR")) |directory| {
        fixture_server.root_module.addLibraryPath(.{ .cwd_relative = directory });
        fixture_server.root_module.addRPath(.{ .cwd_relative = directory });
    }

    fixture_server.root_module.linkSystemLibrary("crypto", .{ .use_pkg_config = .no });
    b.step("fixture-server", "Build the server fixtures (requires OpenSSL)").dependOn(&b.addInstallArtifact(fixture_server, .{}).step);
    const runner = b.addExecutable(.{
        .name = "lightning-rod-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "reload_execve",
                .module = b.dependency("reload_execve", .{ .target = target, .optimize = optimize }).module("reload_execve"),
            }},
        }),
    });
    const check_runner = b.step("check-runner", "Compile the E2E runner without starting Java");
    check_runner.dependOn(&runner.step);
    const list = b.addRunArtifact(runner);
    list.setCwd(b.path("."));
    list.addArg("--list");
    list.addArgs(&.{ "--tests", b.pathFromRoot(tests_root) });
    b.step("list-tests", "List automatically discovered E2E tests and their directories").dependOn(&list.step);

    const server = b.option([]const u8, "server", "Override the test's server executable");
    const address = b.option([]const u8, "address", "Minecraft server address") orelse "127.0.0.1:25565";
    const strace = b.option(bool, "strace", "Collect server syscall counts (distorts timings)") orelse false;
    const artifacts = b.option([]const u8, "artifacts", "Artifact directory") orelse "artifacts";
    const suite = b.step("e2e", "Run all discovered E2E tests sequentially (or select -Dscenario)");
    const servers = b.step("build-test-servers", "Build servers for the selected E2E tests without running Java");
    var previous: ?*std.Build.Step = null;

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
        run.addArgs(&.{ "--scenario", selected.name, "--artifacts", artifacts, "--client", "client" });
        run.addArgs(&.{ "--address", address });
        run.addArgs(&.{ "--client-version", client_version });
        run.addArgs(&.{ "--tests", b.pathFromRoot(tests_root) });
        run.addArgs(&.{ "--strace", if (strace) "true" else "false" });

        if (server) |path| {
            run.addArgs(&.{ "--server", path });
        } else if (selected.standalone) {
            const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-j2", b.fmt("-Doptimize={s}", .{@tagName(optimize)}), "--prefix" });
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
                const test_server = b.addExecutable(.{
                    .name = b.fmt("e2e-{s}", .{selected.name}),
                    .root_module = b.createModule(.{
                        .root_source_file = .{ .cwd_relative = main_path },
                        .target = target,
                        .optimize = optimize,
                        .imports = &imports,
                    }),
                });
                run.addArg("--server");
                run.addArtifactArg(test_server);
                servers.dependOn(&test_server.step);
            } else if (selected.fixture != null) {
                run.addArg("--server");
                run.addArtifactArg(fixture_server);
                servers.dependOn(&fixture_server.step);
            } else {
                const compile = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-j2", b.fmt("-Doptimize={s}", .{@tagName(optimize)}), b.fmt("-Dio={s}", .{@tagName(backend)}) });
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

    suite.dependOn(previous orelse std.debug.panic("No E2E tests discovered", .{}));
}
