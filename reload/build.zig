const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("reload", .{
        .root_source_file = b.path("src/reload.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/handoff_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "reload", .module = module }},
    }) });
    b.step("test", "Verify the frozen reload handoff").dependOn(&b.addRunArtifact(tests).step);
}
