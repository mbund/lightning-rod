const std = @import("std");
const catalog = @import("src/catalog.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    if (b.release_mode == .off) b.release_mode = .safe;
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(enum { uring, stdio }, "io", "Fixture networking implementation") orelse .uring;
    const profile = if (backend == .uring) "lightning_rod_linux" else "lightning_rod_stdio";
    const names = .{ "lightning_rod", "lightning_rod_linux", "vanilla", "sessions", "protocols", "bossbars", "tps" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, i| {
        const selected = if (comptime std.mem.eql(u8, name, "lightning_rod_linux")) profile else name;
        const dependency = b.dependency(selected, .{ .target = target, .optimize = optimize });
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
            .imports = &imports,
        }),
    });
    const check_runner = b.step("check-runner", "Compile the E2E runner without starting Java");
    check_runner.dependOn(&runner.step);
    const list = b.addRunArtifact(runner);
    list.setCwd(b.path("."));
    list.addArg("--list");
    b.step("list-tests", "List automatically discovered E2E tests and their directories").dependOn(&list.step);

    const server = b.option([]const u8, "server", "Override the test's server executable");
    const address = b.option([]const u8, "address", "Minecraft server address") orelse "127.0.0.1:25565";
    const strace = b.option(bool, "strace", "Collect server syscall counts (distorts timings)") orelse false;
    const scenario = b.option([]const u8, "scenario", "Run one E2E scenario (default: all)");
    const cases = catalog.load(b.allocator, b.graph.io, b.pathFromRoot("tests")) catch |err| std.debug.panic("Cannot discover E2E tests: {s}", .{@errorName(err)});

    if (scenario) |name| {
        if (catalog.find(cases, name) == null) std.debug.panic("Unknown E2E test '{s}'; use zig build list-tests", .{name});
    }

    const client_version = b.option([]const u8, "client-version", "Minecraft client release") orelse "1.21.8";
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
        run.addArgs(&.{ "--strace", if (strace) "true" else "false" });

        if (server) |path| {
            run.addArgs(&.{ "--server", path });
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
                const application = b.dependency(b.fmt("{s}_server", .{selected.application}), .{ .target = target, .optimize = optimize, .io = @tagName(backend) });
                run.addArg("--server");
                run.addArtifactArg(application.artifact("lightning_rod"));
                servers.dependOn(&application.artifact("lightning_rod").step);
            }
        }
    }

    suite.dependOn(previous orelse std.debug.panic("No E2E tests discovered", .{}));
}
