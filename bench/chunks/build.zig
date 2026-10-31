const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const chunks = b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks");
    const records = b.dependency("records", .{ .target = target, .optimize = optimize }).module("records");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize }).module("storage");
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt");
    const prepare = b.addExecutable(.{ .name = "chunks-world", .root_module = b.createModule(.{
        .root_source_file = b.path("src/prepare.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "nbt", .module = nbt } },
    }) });
    const run_prepare = b.addRunArtifact(prepare);
    prepare.root_module.addImport("records", records);
    run_prepare.addPassthruArgs();
    b.step("world", "Pregenerate or import vanilla terrain into a frozen corpus").dependOn(&run_prepare.step);
    const benchmark = b.addExecutable(.{ .name = "chunks-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "metrics", .module = metrics } },
    }) });
    const run_benchmark = b.addRunArtifact(benchmark);
    benchmark.root_module.addImport("records", records);
    run_benchmark.addPassthruArgs();
    b.step("bench", "Measure terrain encoding and deterministic player access patterns").dependOn(&run_benchmark.step);
    const comparison = b.addExecutable(.{ .name = "storage-comparison", .root_module = b.createModule(.{
        .root_source_file = b.path("src/compare.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "chunks", .module = chunks },
            .{ .name = "storage", .module = storage },
            .{ .name = "metrics", .module = metrics },
            .{ .name = "nbt", .module = nbt },
            .{ .name = "sqlite", .module = b.dependency("comparison", .{ .target = target, .optimize = optimize }).module("sqlite") },
        },
    }) });
    const run_comparison = b.addRunArtifact(comparison);
    comparison.root_module.addImport("records", records);
    run_comparison.addPassthruArgs();
    b.step("compare", "Compare Anvil, SQLite, and native storage for the same terrain").dependOn(&run_comparison.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "nbt", .module = nbt } },
    }) });
    b.step("test", "Verify corpus framing and reproducible access traces").dependOn(&b.addRunArtifact(tests).step);
}
