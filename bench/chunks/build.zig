const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const chunks = b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks");
    const records = b.dependency("records", .{ .target = target, .optimize = optimize }).module("records");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize }).module("storage");
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt");
    const anvil = b.dependency("anvil", .{ .target = target, .optimize = optimize }).module("anvil");
    const prepare = b.addExecutable(.{ .name = "chunks-world", .root_module = b.createModule(.{
        .root_source_file = b.path("src/prepare.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "nbt", .module = nbt } },
    }) });
    prepare.root_module.addImport("anvil", anvil);
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
    const fragments = b.addExecutable(.{ .name = "fragment-levels", .root_module = b.createModule(.{
        .root_source_file = b.path("src/fragment_levels.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "chunks", .module = chunks }, .{ .name = "storage", .module = storage }, .{ .name = "metrics", .module = metrics }, .{ .name = "records", .module = records }, .{ .name = "deflate", .module = chunks.import_table.get("deflate").? } },
    }) });
    const run_fragments = b.addRunArtifact(fragments);
    run_fragments.addPassthruArgs();
    b.step("fragment-levels", "Compare compression CPU and size for real cached fragments").dependOn(&run_fragments.step);
    const java = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).module("minecraft_java");
    const codec = b.addExecutable(.{ .name = "streaming-codec-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "minecraft_java", .module = java },
            .{ .name = "sessions", .module = java.import_table.get("sessions").? },
        },
    }) });
    const run_codec = b.addRunArtifact(codec);
    run_codec.addPassthruArgs();
    b.step("codec", "Replay captured packets to isolate compression and encryption CPU time").dependOn(&run_codec.step);
    const parallel_codec = b.addExecutable(.{ .name = "streaming-codec-parallel-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/codec_parallel.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sessions", .module = java.import_table.get("sessions").? },
            .{ .name = "networking", .module = java.import_table.get("sessions").?.import_table.get("networking").? },
            .{ .name = "protocols", .module = b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = "1.21.8" }).module("protocols") },
        },
    }) });
    const run_parallel_codec = b.addRunArtifact(parallel_codec);
    run_parallel_codec.addPassthruArgs();
    b.step("codec-parallel", "Compare inline and parallel production codecs on identical captured packets").dependOn(&run_parallel_codec.step);
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
    comparison.root_module.addImport("anvil", anvil);
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
    tests.root_module.addImport("anvil", anvil);
    b.step("test", "Verify corpus framing and reproducible access traces").dependOn(&b.addRunArtifact(tests).step);
}
