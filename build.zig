const std = @import("std");
const cache_clean = @import("src/cache_clean.zig");

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
    const system = b.dependency("system", .{ .target = target, .optimize = optimize }).module("system");
    const module = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "storage", .module = storage.module("storage") }, .{ .name = "system", .module = system } },
    });
    const library = b.addLibrary(.{ .name = "lightning_rod", .root_module = module });
    b.getInstallStep().dependOn(&library.step);
    const test_step = b.step("test", "Run all unit tests");
    const core_test_step = b.step("test-core", "Verify simulation lifecycle");
    const allocation_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/plugin_allocator_test.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    test_step.dependOn(&allocation_tests.step);
    core_test_step.dependOn(&allocation_tests.step);
    const cache_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/cache_clean.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    test_step.dependOn(&cache_tests.step);
    core_test_step.dependOn(&cache_tests.step);
    const runtime_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/runtime/memset.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    const simulation_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/simulation_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "lightning_rod", .module = module }, .{ .name = "storage", .module = storage.module("storage") } },
    }) });
    const simulation_tests_run = b.addRunArtifact(simulation_tests);
    test_step.dependOn(&simulation_tests_run.step);
    core_test_step.dependOn(&simulation_tests_run.step);

    if (b.dep_prefix.len != 0) return;

    cache_clean.add(b);

    const suites = [_]struct { directory: []const u8, targets: []const []const u8 = &.{"test"} }{
        .{ .directory = "reload" },
        .{ .directory = "reload_execve" },
        .{ .directory = "nbt" },
        .{ .directory = "system" },
        .{ .directory = "storage" },
        .{ .directory = "inventories" },
        .{ .directory = "test/storage" },
        .{ .directory = "examples/skyblock" },
        .{ .directory = "records" },
        .{ .directory = "chunks" },
        .{ .directory = "lighting" },
        .{ .directory = "bench/chunks" },
        .{ .directory = "fuzz" },
        .{ .directory = "sessions" },
        .{ .directory = "metrics" },
        .{ .directory = "vanilla" },
        .{ .directory = "minecraft_java" },
        .{ .directory = "e2e", .targets = &.{ "test-performance", "test-harness", "test-artifacts", "test-client" } },
    };
    const shared_cache = b.cache_root.handle.realPathFileAlloc(b.graph.io, ".", b.allocator) catch @panic("Cannot resolve build cache");
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    for (suites) |suite| {
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "--cache-dir",
            shared_cache,
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
