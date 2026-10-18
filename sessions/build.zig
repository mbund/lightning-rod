const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const networking = b.dependency("networking", .{}).module("networking");
    const module = b.addModule("sessions", .{
        .root_source_file = b.path("src/sessions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "networking", .module = networking } },
    });
    const check = b.addLibrary(.{ .name = "sessions", .root_module = module });
    b.step("check", "Check the Sessions module").dependOn(&check.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "networking", .module = networking }},
    }) });
    const test_step = b.step("test", "Verify shared packet storage and workspace ownership");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const endpoint_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/endpoint_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "networking", .module = networking }},
    }) });
    test_step.dependOn(&b.addRunArtifact(endpoint_tests).step);
}
