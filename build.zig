const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime = b.addObject(.{
        .name = "lightning_rod_runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/memset.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runtime.bundle_compiler_rt = false;
    b.addNamedLazyPath("runtime", runtime.getEmittedBin());
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    const module = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "storage", .module = storage.module("storage") } },
    });
    const library = b.addLibrary(.{ .name = "lightning_rod", .root_module = module });
    b.getInstallStep().dependOn(&library.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/work.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "metrics", .module = metrics }},
    }) });
    const test_step = b.step("test", "Verify simulation checkpoints and work attribution");
    const runtime_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/memset.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const simulation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/simulation_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lightning_rod", .module = module }, .{ .name = "storage", .module = storage.module("storage") } },
    }) });
    test_step.dependOn(&b.addRunArtifact(simulation_tests).step);
}
