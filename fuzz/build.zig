const std = @import("std");

pub fn build(b: *std.Build) void {
    const seed = b.option(u32, "seed", "Deterministic fuzz mutation seed") orelse 0;
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runner = fuzzRunner(b, seed);
    const lighting = b.dependency("lighting", .{ .target = target, .optimize = optimize }).module("lighting");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    const records = b.dependency("records", .{ .target = target, .optimize = optimize });
    const chunks = b.dependency("chunks", .{ .target = target, .optimize = optimize });
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const storage_testing = b.createModule(.{ .root_source_file = storage.path("src/testing.zig"), .target = target, .optimize = optimize });
    const model = b.createModule(.{
        .root_source_file = records.path("src/model_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "records", .module = records.module("records") },
            .{ .name = "storage", .module = storage.module("storage") },
            .{ .name = "metrics", .module = metrics },
            .{ .name = "storage_testing", .module = storage_testing },
        },
    });
    const encoding = b.createModule(.{
        .root_source_file = chunks.path("src/encoding.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "records", .module = records.module("records") }, .{ .name = "storage", .module = storage.module("storage") } },
    });
    const test_step = b.step("test", "Run saved inputs for every fuzzer");
    for ([_][]const u8{ "storage", "records", "chunks", "lighting" }) |name| {
        const tests = b.addTest(.{
            .name = b.fmt("{s}-fuzz", .{name}),
            // The native Debug backend does not emit the coverage tables required by fuzzing.
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "storage", .module = storage.module("storage") },
                    .{ .name = "lighting", .module = lighting },
                    .{ .name = "storage_testing", .module = storage_testing },
                    .{ .name = "model", .module = model },
                    .{ .name = "encoding", .module = encoding },
                },
            }),
            .filters = &.{"fuzz"},
            .test_runner = .{ .path = runner, .mode = .server },
        });
        const run = b.addRunArtifact(tests);
        // Fuzz discovery needs the test results even when saved inputs already passed.
        run.has_side_effects = true;
        b.step(name, b.fmt("Fuzz {s} with --fuzz -j1", .{name})).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
    const environment_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/environment_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "storage", .module = storage.module("storage") }},
        }),
        .test_runner = .{ .path = runner, .mode = .server },
    });
    test_step.dependOn(&b.addRunArtifact(environment_tests).step);
    const guard = b.addExecutable(.{
        .name = "fuzz-thread-guard",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/thread_guard_test.zig"), .target = target, .optimize = optimize }),
    });
    const check_guard = b.addRunArtifact(guard);
    check_guard.addCheck(.{ .expect_term = .{ .signal = .SYS } });
    test_step.dependOn(&check_guard.step);
}

fn fuzzRunner(b: *std.Build, seed: u32) std.Build.LazyPath {
    const executable = b.addExecutable(.{
        .name = "prepare-fuzz-runner",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/prepare_runner.zig"), .target = b.graph.host, .optimize = .debug }),
    });
    const prepare = b.addRunArtifact(executable);
    prepare.addFileArg(std.Build.LazyPath.zig_lib.path(b, "compiler/test_runner.zig"));
    prepare.addArg(b.fmt("{d}", .{seed}));
    const source = prepare.addOutputFileArg("test_runner.zig");
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("src/environment.zig"), "environment.zig");
    return files.addCopyFile(source, "test_runner.zig");
}
