const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const system = b.dependency("system", .{ .target = target, .optimize = optimize }).module("system");
    const core = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const lightning_rod = core.module("lightning_rod");
    const reload = b.dependency("reload", .{ .target = target, .optimize = optimize }).module("reload");
    const networking = b.dependency("networking", .{}).module("networking");
    const module = b.addModule("sessions", .{
        .root_source_file = b.path("src/sessions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "system", .module = system }, .{ .name = "reload", .module = reload }, .{ .name = "lightning_rod", .module = lightning_rod }, .{ .name = "metrics", .module = metrics }, .{ .name = "networking", .module = networking } },
    });
    const transport_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/transport_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "system", .module = b.dependency("system", .{ .target = target, .optimize = optimize }).module("system") } },
    }) });
    transport_tests.root_module.addObjectFile(core.namedLazyPath("runtime"));
    const check = b.addLibrary(.{ .name = "sessions", .root_module = module });
    b.step("check", "Check the Sessions module").dependOn(&check.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "networking", .module = networking }},
    }) });
    const test_step = b.step("test", "Verify shared packet storage and workspace ownership");
    const handoff_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/handoff_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "metrics", .module = metrics }, .{ .name = "system", .module = system } },
    }) });
    test_step.dependOn(&b.addRunArtifact(handoff_tests).step);
    const pipeline_bench = b.addTest(.{ .filters = &.{"operation counts"}, .root_module = b.createModule(.{
        .root_source_file = b.path("src/pipeline_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "metrics", .module = metrics }, .{ .name = "system", .module = system } },
    }) });
    const run_pipeline = std.Build.Step.Run.create(b, "session pipeline operations");
    run_pipeline.addArtifactArg(pipeline_bench);
    b.step("bench-pipeline", "Count session pipeline operations without threads or timing").dependOn(&run_pipeline.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/output_test.zig"), .target = target, .optimize = optimize }) })).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/buffers.zig"), .target = target, .optimize = optimize }) })).step);
    test_step.dependOn(&b.addRunArtifact(transport_tests).step);
    const initialization_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/initialization_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "metrics", .module = metrics }, .{ .name = "system", .module = system } },
    }) });
    test_step.dependOn(&b.addRunArtifact(initialization_tests).step);
    const threaded_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/threaded.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "metrics", .module = metrics }, .{ .name = "system", .module = system } },
    }) });
    test_step.dependOn(&b.addRunArtifact(threaded_tests).step);
    const endpoint_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/endpoint_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "networking", .module = networking }},
    }) });
    test_step.dependOn(&b.addRunArtifact(endpoint_tests).step);
}
