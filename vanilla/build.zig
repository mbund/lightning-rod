const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const worldgen = b.dependency("vanilla_worldgen", .{ .target = target, .optimize = optimize });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
        .{ .name = "worldgen", .module = worldgen.module("vanilla_worldgen") },
    };
    const terrain = b.addModule("vanilla_terrain", .{
        .root_source_file = b.path("src/vanilla_terrain.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const vanilla = b.addModule("lightning_rod_vanilla_1_21_6", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
            .{ .name = "worldgen", .module = worldgen.module("vanilla_worldgen") },
            .{ .name = "vanilla_terrain", .module = terrain },
        },
    });
    const test_filter = b.option([]const u8, "test-filter", "Run matching Vanilla tests");
    const tests = b.addTest(.{ .root_module = vanilla, .filters = if (test_filter) |filter| &.{filter} else &.{} });
    tests.use_llvm = true;
    tests.use_lld = true;
    b.step("test", "Run Vanilla 1.21.6 plugin tests").dependOn(&b.addRunArtifact(tests).step);
    const benchmark = b.addExecutable(.{
        .name = "lightning_rod_worldgen_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "vanilla_terrain", .module = terrain },
                .{ .name = "worldgen", .module = worldgen.module("vanilla_worldgen") },
            },
        }),
    });
    benchmark.use_llvm = true;
    benchmark.use_lld = true;
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |arguments| run_benchmark.addArgs(arguments);
    b.step("benchmark", "Profile Vanilla chunk generation").dependOn(&run_benchmark.step);
    const streaming_benchmark = b.addExecutable(.{
        .name = "lightning_rod_streaming_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/streaming_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "vanilla_terrain", .module = terrain },
            },
        }),
    });
    streaming_benchmark.use_llvm = true;
    streaming_benchmark.use_lld = true;
    const run_streaming_benchmark = b.addRunArtifact(streaming_benchmark);
    b.step("benchmark-streaming", "Profile loaded chunk projection").dependOn(&run_streaming_benchmark.step);
}
