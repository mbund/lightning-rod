const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runner = fuzzRunner(b);
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
    for ([_][]const u8{ "storage", "records", "chunks" }) |name| {
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
                    .{ .name = "storage_testing", .module = storage_testing },
                    .{ .name = "model", .module = model },
                    .{ .name = "encoding", .module = encoding },
                },
            }),
            .filters = &.{"fuzz"},
            .test_runner = .{ .path = runner, .mode = .server },
        });
        const run = b.addRunArtifact(tests);
        b.step(name, b.fmt("Fuzz {s}", .{name})).dependOn(&run.step);
        test_step.dependOn(&run.step);
    }
}

fn fuzzRunner(b: *std.Build) std.Build.LazyPath {
    // Zig 0.16's fuzz runner calls the stack trace formatter with an error return trace.
    const source = b.graph.zig_lib_directory.handle.readFileAlloc(b.graph.io, "compiler/test_runner.zig", b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("Cannot read Zig's test runner: {s}", .{@errorName(err)});
    const incorrect = "std.debug.writeStackTrace(trace, stderr)";
    std.debug.assert(std.mem.count(u8, source, incorrect) == 1);
    const corrected = std.mem.replaceOwned(u8, b.allocator, source, incorrect, "std.debug.writeErrorReturnTrace(trace, stderr)") catch @panic("OOM");
    return b.addWriteFiles().add("test_runner.zig", corrected);
}
