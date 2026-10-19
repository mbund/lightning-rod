const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    const module = b.addModule("records", .{
        .root_source_file = b.path("src/cache.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "storage", .module = storage.module("storage") } },
    });
    const filter = b.option([]const u8, "test-filter", "Run matching record tests");
    const test_step = b.step("test", "Verify cached records and persistent indexes");
    const fault = b.createModule(.{ .root_source_file = storage.path("src/fault_disk.zig"), .target = target, .optimize = optimize });
    const storage_testing = b.createModule(.{ .root_source_file = storage.path("src/testing.zig"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "src/cache_test.zig", "src/model_test.zig", "src/fault_test.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "records", .module = module }, .{ .name = "metrics", .module = metrics }, .{ .name = "storage", .module = storage.module("storage") }, .{ .name = "fault_disk", .module = fault }, .{ .name = "storage_testing", .module = storage_testing } },
        }), .filters = if (filter) |value| &.{value} else &.{} });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
