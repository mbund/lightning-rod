const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const executable = b.addExecutable(.{
        .name = "startup-world",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
                .{ .name = "vanilla", .module = b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6") },
                .{ .name = "chunks", .module = b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks") },
                .{ .name = "records", .module = b.dependency("records", .{ .target = target, .optimize = optimize }).module("records") },
            },
        }),
    });
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Generate a persisted superflat world for startup benchmarks").dependOn(&run.step);
}
