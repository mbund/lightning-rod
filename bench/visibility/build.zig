const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = game_data.minecraft_version }).module("protocols");
    const packets = b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets");
    packets.addImport("protocols", protocols);
    const occlusion = b.dependency("occlusion", .{ .target = target, .optimize = optimize }).module("occlusion");
    const root = b.createModule(.{ .root_source_file = b.path("src/visibility_bench.zig"), .target = target, .optimize = optimize });
    inline for (.{ "chunks", "game_data", "lighting", "metrics", "minecraft_java", "records", "sessions", "storage", "terrain", "worlds" }) |name|
        root.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    root.addImport("minecraft_packets", packets);
    root.addImport("occlusion", occlusion);
    for ([_][]const u8{ "oracle", "topology" }) |name| root.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})) });
    const executable = b.addExecutable(.{ .name = "visibility-bench", .root_module = root });
    const incremental_executable = b.addExecutable(.{ .name = "visibility-incremental-bench", .root_module = b.createModule(.{ .root_source_file = b.path("src/visibility_incremental_bench.zig"), .target = target, .optimize = optimize }) });
    for (root.import_table.keys(), root.import_table.values()) |name, dependency| incremental_executable.root_module.addImport(name, dependency);
    const incremental_run = b.addRunArtifact(incremental_executable);
    incremental_run.addPassthruArgs();
    b.step("incremental", "Measure cached visibility against fresh proofs").dependOn(&incremental_run.step);
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("bench", "Compare section disclosure with exact opaque voxel visibility").dependOn(&run.step);
    const cave_run = b.addRunArtifact(executable);
    cave_run.addArg("--caves");
    cave_run.addPassthruArgs();
    b.step("caves", "Compare imported underground cave visibility with the exact oracle").dependOn(&cave_run.step);
    const test_step = b.step("test", "Verify the independent visibility oracle and topology diagnostics");
    for ([_][]const u8{ "oracle.zig", "topology.zig" }) |source| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("src/{s}", .{source})), .target = target, .optimize = optimize }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const safety = b.createModule(.{ .root_source_file = b.path("src/occlusion_reference_test.zig"), .target = target, .optimize = optimize });
    for (root.import_table.keys(), root.import_table.values()) |name, dependency| safety.addImport(name, dependency);
    const safety_run = b.addRunArtifact(b.addTest(.{ .root_module = safety }));
    test_step.dependOn(&safety_run.step);
    b.step("test-disclosure", "Verify production disclosure against independent ray witnesses").dependOn(&safety_run.step);
    b.step("test-incremental", "Verify incremental visibility against fresh solves").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = occlusion, .filters = &.{"incremental edits"} })).step);
    const cave_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/visibility_caves.zig"), .target = target, .optimize = optimize }) });
    cave_tests.root_module.addImport("game_data", root.import_table.get("game_data").?);
    cave_tests.root_module.addAnonymousImport("topology", .{ .root_source_file = b.path("src/topology.zig") });
    const cave_test_run = b.addRunArtifact(cave_tests);
    test_step.dependOn(&cave_test_run.step);
    b.step("test-caves", "Verify deterministic underground viewpoint selection").dependOn(&cave_test_run.step);
    const camera_tests = b.addTest(.{ .root_module = root, .filters = &.{"camera witnesses are reproducible"} });
    const camera_test_run = b.addRunArtifact(camera_tests);
    test_step.dependOn(&camera_test_run.step);
    b.step("test-camera", "Verify independent camera coverage witnesses").dependOn(&camera_test_run.step);
}
