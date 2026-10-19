const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime = b.addObject(.{
        .name = "lightning_rod_runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/memset.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runtime.bundle_compiler_rt = false;
    b.addNamedLazyPath("runtime", runtime.getEmittedBin());
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    const module = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "storage", .module = storage.module("storage") } },
    });
    const library = b.addLibrary(.{ .name = "lightning_rod", .root_module = module });
    b.getInstallStep().dependOn(&library.step);
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/work.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "metrics", .module = metrics }},
    }) });
    const test_step = b.step("test", "Run all unit tests");
    const runtime_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/memset.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const simulation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/simulation_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lightning_rod", .module = module }, .{ .name = "storage", .module = storage.module("storage") } },
    }) });
    test_step.dependOn(&b.addRunArtifact(simulation_tests).step);

    if (b.dep_prefix.len != 0) return;

    const suites = [_]struct { directory: []const u8, targets: []const []const u8 = &.{"test"} }{
        .{ .directory = "reload_execve" },
        .{ .directory = "nbt" },
        .{ .directory = "storage" },
        .{ .directory = "inventories" },
        .{ .directory = "test/storage" },
        .{ .directory = "records" },
        .{ .directory = "chunks" },
        .{ .directory = "bench/chunks" },
        .{ .directory = "fuzz" },
        .{ .directory = "sessions" },
        .{ .directory = "network_uring" },
        .{ .directory = "network_stdio" },
        .{ .directory = "metrics" },
        .{ .directory = "vanilla" },
        .{ .directory = "minecraft_java" },
        .{ .directory = "e2e", .targets = &.{ "test-performance", "test-harness", "test-artifacts", "test-client" } },
    };
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    for (suites) |suite| {
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
            b.fmt("-Dtarget={s}", .{triple}),
            b.fmt("-Dcpu={s}", .{cpu}),
        });
        run.setName(b.fmt("test {s}", .{suite.directory}));
        run.setCwd(b.path(suite.directory));
        run.addArgs(suite.targets);
        if (b.graph.max_jobs) |jobs| run.addArg(b.fmt("-j{d}", .{jobs}));
        // Inherited stdio serializes nested builds so each can use the full job budget.
        run.stdio = .inherit;
        test_step.dependOn(&run.step);
    }
}
