const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const server = b.dependency("server", .{ .target = target, .optimize = optimize });
    const profile = b.dependency("linux", .{ .target = target, .optimize = optimize }).module("lightning_rod_linux");
    const executable = b.addExecutable(.{
        .name = "startup-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "profile", .module = profile }},
        }),
    });
    const run = b.addRunArtifact(executable);
    run.addFileArg(server.namedLazyPath("server"));
    run.addPassthruArgs();
    b.step("bench", "Measure server startup and graceful shutdown against an existing world").dependOn(&run.step);
}
