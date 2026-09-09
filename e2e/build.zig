const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const linux = b.dependency("lightning_rod_linux", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize });
    const server = b.addExecutable(.{
        .name = "lightning-rod-e2e-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "lightning_rod_linux", .module = linux.module("lightning_rod_linux") },
                .{ .name = "lightning_rod_vanilla_1_21_6", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
            },
        }),
    });
    const runner = b.addExecutable(.{
        .name = "lightning-rod-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runner.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const cleanup_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/process_cleanup.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("test", "Verify owned test-process cleanup without running Java").dependOn(&b.addRunArtifact(cleanup_tests).step);
    const scenario = b.option([]const u8, "scenario", "chunks, chunks-full, chunks-flat, chunks-persisted, chunks-varied-disk, steady, reload, reload-failure, fatal-storage, auth-success, auth-reject, auth-timeout, skyblock-chat, or all") orelse "all";
    const artifacts = b.option([]const u8, "artifacts", "Artifact directory") orelse "artifacts";
    const capture_bytes = b.option(u64, "capture-bytes", "Recorder raw-packet capture limit in bytes (0 disables it)");
    const run = b.addRunArtifact(runner);
    run.setCwd(b.path("."));
    run.addArgs(&.{ "--scenario", scenario, "--artifacts", artifacts, "--client", "../conformance/tools/fabric-recorder", "--server" });
    const tested_server = if (std.mem.eql(u8, scenario, "skyblock-chat"))
        b.dependency("skyblock", .{ .target = target, .optimize = optimize, .port = @as(u16, 25575) }).artifact("lightning_rod_skyblock")
    else
        server;
    run.addArtifactArg(tested_server);
    if (capture_bytes) |value| run.addArgs(&.{ "--capture-bytes", b.fmt("{d}", .{value}) });
    if (std.mem.eql(u8, scenario, "all")) {
        run.addArg("--skyblock-server");
        run.addArtifactArg(b.dependency("skyblock", .{ .target = target, .optimize = optimize, .port = @as(u16, 25575) }).artifact("lightning_rod_skyblock"));
    }
    b.step("e2e", "Run real-client end-to-end tests (requires Java, Gradle, and Xvfb)").dependOn(&run.step);
    const check = b.step("check", "Compile the E2E runner and server without running Java");
    check.dependOn(&runner.step);
    check.dependOn(&server.step);
    b.step("check-runner", "Compile the E2E runner without compiling a server").dependOn(&runner.step);
    b.step("install-runner", "Install the E2E runner for testing an existing server executable").dependOn(&b.addInstallArtifact(runner, .{}).step);
}
