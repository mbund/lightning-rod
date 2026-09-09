const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const shop = b.addModule("shop", .{
        .root_source_file = b.path("src/shop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "economy", .module = economy.module("economy") },
            .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
        },
    });
    const tests = b.addTest(.{
        .root_module = shop,
        .test_runner = .{
            .path = lightning_rod.path("test-runner/src/main.zig"),
            .mode = .simple,
        },
    });
    b.step("test", "Run Shop plugin tests").dependOn(&b.addRunArtifact(tests).step);
}
