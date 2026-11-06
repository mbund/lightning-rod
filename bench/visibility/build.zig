const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const module = vanilla.module("lightning_rod_vanilla_1_21_6");
    const executable = b.addExecutable(.{ .name = "visibility-bench", .root_module = b.createModule(.{ .root_source_file = vanilla.builder.path("src/visibility_bench.zig"), .target = target, .optimize = optimize }) });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| executable.root_module.addImport(name, dependency);
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = game_data.minecraft_version }).module("protocols");
    executable.root_module.addImport("protocols", protocols);
    module.import_table.get("minecraft_packets").?.addImport("protocols", protocols);
    for ([_][]const u8{ "oracle", "topology" }) |name| executable.root_module.addAnonymousImport(name, .{ .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})) });
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
    const safety = b.createModule(.{ .root_source_file = vanilla.builder.path("src/occlusion_reference_test.zig"), .target = target, .optimize = optimize });
    for (executable.root_module.import_table.keys(), executable.root_module.import_table.values()) |name, dependency| safety.addImport(name, dependency);
    const safety_run = b.addRunArtifact(b.addTest(.{ .root_module = safety }));
    test_step.dependOn(&safety_run.step);
    b.step("test-disclosure", "Verify production disclosure against independent ray witnesses").dependOn(&safety_run.step);
    const cave_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = vanilla.builder.path("src/visibility_caves.zig"), .target = target, .optimize = optimize }) });
    cave_tests.root_module.addImport("game_data", module.import_table.get("game_data").?);
    cave_tests.root_module.addAnonymousImport("topology", .{ .root_source_file = b.path("src/topology.zig") });
    const cave_test_run = b.addRunArtifact(cave_tests);
    test_step.dependOn(&cave_test_run.step);
    b.step("test-caves", "Verify deterministic underground viewpoint selection").dependOn(&cave_test_run.step);
    const camera_tests = b.addTest(.{ .root_module = executable.root_module, .filters = &.{"camera witnesses are reproducible"} });
    const camera_test_run = b.addRunArtifact(camera_tests);
    test_step.dependOn(&camera_test_run.step);
    b.step("test-camera", "Verify independent camera coverage witnesses").dependOn(&camera_test_run.step);
}
