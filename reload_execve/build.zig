const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("reload_execve", .{
        .root_source_file = b.path("src/reload.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .imports = &.{.{ .name = "reload_execve", .module = module }},
    }) });
    b.step("test", "Verify reload metadata in the linked executable").dependOn(&b.addRunArtifact(tests).step);
}
