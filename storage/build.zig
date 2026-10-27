const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const system = b.dependency("system", .{ .target = target, .optimize = optimize }).module("system");
    const module = b.addModule("storage", .{ .root_source_file = b.path("src/storage.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "system", .module = system } } });
    const filter = b.option([]const u8, "test-filter", "Run matching storage tests");
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize, .imports = &.{ .{ .name = "storage", .module = module }, .{ .name = "metrics", .module = metrics } } }), .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify page transactions, WAL recovery, and maintenance");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const io_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/io_test.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "system", .module = system }} }), .filters = if (filter) |value| &.{value} else &.{} });
    test_step.dependOn(&b.addRunArtifact(io_tests).step);
    const index_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/index_test.zig"), .target = target, .optimize = optimize }), .filters = if (filter) |value| &.{value} else &.{} });
    test_step.dependOn(&b.addRunArtifact(index_tests).step);
}
