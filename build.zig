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

    const suites = [_]struct { directory: []const u8, targets: []const []const u8 = &.{"test"}, arguments: []const []const u8 = &.{} }{
        .{ .directory = "reload" },
        .{ .directory = "reload_execve" },
        .{ .directory = "nbt" },
        .{ .directory = "anvil" },
        .{ .directory = "tools/world-import" },
        .{ .directory = "datapacks" },
        .{ .directory = "system" },
        .{ .directory = "storage" },
        .{ .directory = "inventories" },
        .{ .directory = "test/storage" },
        .{ .directory = "examples/skyblock" },
        .{ .directory = "records" },
        .{ .directory = "chunks" },
        .{ .directory = "zstandard" },
        .{ .directory = "deflate" },
        .{ .directory = "lighting" },
        .{ .directory = "block_properties" },
        .{ .directory = "bench/chunks" },
        .{ .directory = "bench/visibility" },
        .{ .directory = "fuzz" },
        .{ .directory = "sessions" },
        .{ .directory = "protocols" },
        .{ .directory = "metrics" },
        .{ .directory = "host" },
        // Every supported release by default. The suites that depend on the protocol
        // catalog run again with the one release a minimal server selects.
        .{ .directory = "players" },
        .{ .directory = "occlusion" },
        .{ .directory = "terrain" },
        .{ .directory = "terrain", .arguments = &.{"-Dsingle-release=true"} },
        .{ .directory = "replication" },
        .{ .directory = "connection" },
        .{ .directory = "commands" },
        .{ .directory = "chat" },
        .{ .directory = "bossbars" },
        .{ .directory = "vanilla/content" },
        .{ .directory = "vanilla/world" },
        .{ .directory = "vanilla/player" },
        .{ .directory = "vanilla/items" },
        .{ .directory = "vanilla/crafting" },
        .{ .directory = "vanilla/item_entities" },
        .{ .directory = "vanilla/inventory" },
        .{ .directory = "vanilla/survival" },
        .{ .directory = "vanilla/blocks" },
        .{ .directory = "vanilla/containers" },
        .{ .directory = "vanilla/equipment" },
        .{ .directory = "vanilla/definitions" },
        .{ .directory = "vanilla" },
        .{ .directory = "minecraft_java" },
        .{ .directory = "e2e", .targets = &.{ "test-performance", "test-harness", "test-artifacts", "test-client" } },
        .{ .directory = "e2e/tests", .targets = &.{"list-tests"} },
    };
    // Nested suites run one after another, so CI splits them across runners.
    const shard_option = b.option([]const u8, "shard", "Run only every COUNT-th suite starting at INDEX, given as INDEX/COUNT") orelse "0/1";
    const separator = std.mem.indexOfScalar(u8, shard_option, '/') orelse std.debug.panic("-Dshard takes INDEX/COUNT, not {s}", .{shard_option});
    const shard_index = std.fmt.parseInt(usize, shard_option[0..separator], 10) catch std.debug.panic("-Dshard takes INDEX/COUNT, not {s}", .{shard_option});
    const shard_count = std.fmt.parseInt(usize, shard_option[separator + 1 ..], 10) catch std.debug.panic("-Dshard takes INDEX/COUNT, not {s}", .{shard_option});
    if (shard_count == 0 or shard_index >= shard_count) std.debug.panic("-Dshard takes INDEX/COUNT with INDEX below COUNT, not {s}", .{shard_option});
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    for (suites, 0..) |suite, suite_index| {
        if (suite_index % shard_count != shard_index) continue;
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
            b.fmt("-Dtarget={s}", .{triple}),
            b.fmt("-Dcpu={s}", .{cpu}),
        });
        run.addArg("--cache-dir");
        run.addDirectoryArg(.cache_root);
        run.setName(if (suite.arguments.len == 0) b.fmt("test {s}", .{suite.directory}) else b.fmt("test {s} {s}", .{ suite.directory, suite.arguments[0] }));
        run.setCwd(b.path(suite.directory));
        run.addArgs(suite.targets);
        run.addArgs(suite.arguments);
        // Inherited stdio serializes nested builds so each can use the full job budget.
        run.stdio = .inherit;
        test_step.dependOn(&run.step);
    }
}
