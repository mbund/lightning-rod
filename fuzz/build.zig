const std = @import("std");

pub fn build(b: *std.Build) void {
    // Zig uses the job count to choose the number of communicating fuzz processes.
    b.graph.max_jobs = 1;
    b.graph.random_seed = b.option(u32, "seed", "Deterministic fuzz mutation seed") orelse 0;
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
        // Fuzz discovery needs the test results even when saved inputs already passed.
        run.has_side_effects = true;
        b.step(name, b.fmt("Fuzz {s}", .{name})).dependOn(&run.step);
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

fn fuzzRunner(b: *std.Build) std.Build.LazyPath {
    // Zig 0.16's fuzz runner calls the stack trace formatter with an error return trace.
    const source = b.graph.zig_lib_directory.handle.readFileAlloc(b.graph.io, "compiler/test_runner.zig", b.allocator, .limited(1024 * 1024)) catch |err|
        std.debug.panic("Cannot read Zig's test runner: {s}", .{@errorName(err)});
    const incorrect = "std.debug.writeStackTrace(trace, stderr)";
    var runner = replace(b, source, incorrect, "std.debug.writeErrorReturnTrace(trace, stderr)");
    runner = replace(b, runner, "const fuzz_abi = std.Build.abi.fuzz;", "const fuzz_abi = std.Build.abi.fuzz;\nconst environment = @import(\"environment.zig\");");
    runner = replace(b, runner, "pub fn main(init: std.process.Init.Minimal) void {\n    @disableInstrumentation();", "pub fn main(init: std.process.Init.Minimal) void {\n    @disableInstrumentation();\n    environment.initialize();");
    runner = replace(b, runner, "                const n_tests: u32 = try server.receiveBody_u32();", "                const n_tests: u32 = try server.receiveBody_u32();\n                assert(n_tests == 1);");
    // Zig 0.16's coverage runtime needs TLS startup. No thread creation is allowed.
    const limits = "                    .async_limit = .nothing,\n                    .concurrent_limit = .nothing,\n";
    const init_options = "                    .argv0 = .init(init.args),\n                    .environ = init.environ,\n";
    std.debug.assert(std.mem.count(u8, runner, init_options) == 2);
    runner = std.mem.replaceOwned(u8, b.allocator, runner, init_options, b.fmt("{s}{s}", .{ limits, init_options })) catch @panic("OOM");
    // Case I/O must outlive the testing allocator resets between inputs.
    runner = replace(b, runner, "                var io_instance: Io.Threaded = .init(gpa, .{", "                testing.io_instance = .init(gpa, .{");
    runner = replace(b, runner, "                defer io_instance.deinit();", "                defer testing.io_instance.deinit();");
    runner = replace(b, runner, "                const io = io_instance.io();", "                const io = testing.io;\n                testing.environ = init.environ;");
    runner = replace(b, runner, "                const main_instance = mode == .iterations or amount_or_instance == 0;", "                const main_instance = mode == .iterations or amount_or_instance == 0;\n                assert(main_instance);");
    runner = replace(b, runner, "                    .input_poller = undefined,\n", "");
    runner = replace(b, runner, "    input_poller: Io.Future(Io.Cancelable!void),\n", "");
    const start = std.mem.indexOf(u8, runner, "    export fn runner_start_input_poller() void {") orelse unreachable;
    const end = std.mem.indexOf(u8, runner, "    export fn runner_futex_wait(") orelse unreachable;
    // One worker has no peers and receives no corpus broadcasts.
    runner = b.fmt("{s}    export fn runner_start_input_poller() void {{}}\n    export fn runner_stop_input_poller() void {{}}\n\n{s}", .{ runner[0..start], runner[end..] });
    const poll_start = std.mem.indexOf(u8, runner, "    fn inputPoller() Io.Cancelable!void {") orelse unreachable;
    const poll_end = std.mem.indexOfPos(u8, runner, poll_start, "} else void = undefined;") orelse unreachable;
    runner = b.fmt("{s}{s}", .{ runner[0..poll_start], runner[poll_end..] });
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path("src/environment.zig"), "environment.zig");
    return files.add("test_runner.zig", runner);
}

fn replace(b: *std.Build, source: []const u8, before: []const u8, after: []const u8) []const u8 {
    std.debug.assert(std.mem.count(u8, source, before) == 1);
    return std.mem.replaceOwned(u8, b.allocator, source, before, after) catch @panic("OOM");
}
