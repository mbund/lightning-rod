const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const system = b.dependency("system", .{ .target = target, .optimize = optimize }).module("system");
    const module = b.addModule("metrics", .{
        .root_source_file = b.path("src/metrics.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "system", .module = system }},
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify instruments and bounded observation streams").dependOn(&b.addRunArtifact(tests).step);
}
