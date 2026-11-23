const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const records = b.dependency("records", .{ .target = target, .optimize = optimize });
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });

    _ = b.addModule("entities", .{
        .root_source_file = b.path("src/entities.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "metrics", .module = metrics },
            .{ .name = "records", .module = records.module("records") },
            .{ .name = "storage", .module = storage.module("storage") },
        },
    });

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "metrics", .module = metrics },
            .{ .name = "records", .module = records.module("records") },
            .{ .name = "storage", .module = storage.module("storage") },
        },
    }) });
    b.step("test", "Run the entities tests").dependOn(&b.addRunArtifact(tests).step);
}
