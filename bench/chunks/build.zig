const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const chunks = b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks");
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
    if (b.args) |args| run_prepare.addArgs(args);
    b.step("world", "Pregenerate or import vanilla terrain into a frozen corpus").dependOn(&run_prepare.step);
    const benchmark = b.addExecutable(.{ .name = "chunks-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "metrics", .module = metrics } },
    }) });
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |args| run_benchmark.addArgs(args);
    b.step("bench", "Measure terrain encoding and deterministic player access patterns").dependOn(&run_benchmark.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "nbt", .module = nbt } },
    }) });
    b.step("test", "Verify corpus framing and reproducible access traces").dependOn(&b.addRunArtifact(tests).step);
}
