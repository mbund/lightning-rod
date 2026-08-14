const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("worldguard", .{
        .root_source_file = b.path("src/worldguard.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (b.option(bool, "standalone-tests", "Build plugin tests with Lightning Rod") orelse false) {
        const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
        const test_module = b.createModule(.{
            .root_source_file = b.path("src/worldguard.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") }},
        });
        b.step("test", "Run WorldGuard plugin tests")
            .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = test_module })).step);
    }
}
