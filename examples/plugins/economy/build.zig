const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const economy = b.addModule("economy", .{
        .root_source_file = b.path("src/economy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") }},
    });
    const tests = b.addTest(.{
        .root_module = economy,
        .test_runner = .{
            .path = lightning_rod.path("test-runner/src/main.zig"),
            .mode = .simple,
        },
    });
    b.step("test", "Run Economy plugin tests").dependOn(&b.addRunArtifact(tests).step);
}
