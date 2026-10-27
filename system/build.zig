const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("system", .{
        .root_source_file = b.path("src/system.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = module });
    const step = b.step("test", "Verify bounded allocation and native communication");
    step.dependOn(&b.addRunArtifact(tests).step);
    const memory_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/memory.zig"), .target = target, .optimize = optimize }) });
    step.dependOn(&b.addRunArtifact(memory_tests).step);
    const guard = b.addExecutable(.{ .name = "memory-guard", .root_module = b.createModule(.{ .root_source_file = b.path("src/memory_guard.zig"), .target = target, .optimize = optimize }) });
    for ([_]struct { operation: []const u8, message: []const u8 }{
        .{ .operation = "allocate", .message = "backing allocation after initialization\n" },
        .{ .operation = "resize", .message = "backing resize after initialization\n" },
        .{ .operation = "owner", .message = "memory owner registered after initialization\n" },
    }) |case| {
        const run = b.addRunArtifact(guard);
        run.addArg(case.operation);
        run.expectExitCode(86);
        run.expectStdErrEqual(case.message);
        step.dependOn(&run.step);
    }
}
