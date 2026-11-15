const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("occlusion", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    inline for (.{ "chunks", "game_data", "lighting", "records", "storage" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify section visibility, disclosure and hidden block replacement");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const bench_module = b.createModule(.{ .root_source_file = b.path("src/section_visibility_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| bench_module.addImport(name, dependency);
    const bench = b.addTest(.{ .root_module = bench_module, .filters = if (filter) |value| &.{value} else &.{ "shared section visibility workloads", "section topology workloads", "cached bend traversal workload" } });
    const bench_run = std.Build.Step.Run.create(b, "shared section visibility workloads");
    bench_run.addArtifactArg(bench);
    b.step("bench-sections", "Measure section traversal and sealed-source bounds").dependOn(&bench_run.step);
}
