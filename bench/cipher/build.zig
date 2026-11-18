const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const executable = b.addExecutable(.{
        .name = "cipher-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "java", .module = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).module("minecraft_java") }},
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("bench", "Measure CFB8 encryption one stream at a time against streams side by side").dependOn(&run.step);
}
