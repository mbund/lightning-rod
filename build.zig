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
    // Nested suites run one after another, so CI runs each as its own job, by the name
    // list-suites prints. The e2e suite runs Java and needs the client runtime.
    var names: [suites.len][]const u8 = undefined;
    for (suites, &names) |suite, *name| name.* = if (suite.arguments.len == 0)
        suite.directory
    else
        b.fmt("{s} {s}", .{ suite.directory, std.mem.join(b.allocator, " ", suite.arguments) catch @panic("OOM") });
    const selected_suite = b.option([]const u8, "suite", "Run only the suite of this name, as list-suites prints it");
    // The root package's own tests form the core suite.
    if (selected_suite) |wanted| if (!std.mem.eql(u8, wanted, "core")) {
        for (names) |name| {
            if (std.mem.eql(u8, name, wanted)) break;
        } else std.debug.panic("Unknown suite '{s}'; use zig build list-suites", .{wanted});
        test_step.dependencies.clearRetainingCapacity();
    };
    const Entry = struct { suite: []const u8, java: bool };
    var entries: [suites.len + 1]Entry = undefined;
    entries[0] = .{ .suite = "core", .java = false };
    for (suites, names, entries[1..]) |suite, name, *entry| entry.* = .{ .suite = name, .java = std.mem.eql(u8, suite.directory, "e2e") };
    const matrix = std.json.Stringify.valueAlloc(b.allocator, .{ .include = entries }, .{}) catch @panic("OOM");
    const print_suites = b.addSystemCommand(&.{"cat"});
    print_suites.addFileArg(b.addWriteFiles().add("suites.json", matrix));
    print_suites.has_side_effects = true;
    b.step("list-suites", "Print the CI matrix of test suites as JSON").dependOn(&print_suites.step);
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    for (suites, names) |suite, name| {
        if (selected_suite) |wanted| if (!std.mem.eql(u8, name, wanted)) continue;
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
            b.fmt("-Dtarget={s}", .{triple}),
            b.fmt("-Dcpu={s}", .{cpu}),
        });
        run.addArg("--cache-dir");
        run.addDirectoryArg(.cache_root);
        run.setName(b.fmt("test {s}", .{name}));
        run.setCwd(b.path(suite.directory));
        run.addArgs(suite.targets);
        run.addArgs(suite.arguments);
        // Inherited stdio serializes nested builds so each can use the full job budget.
        run.stdio = .inherit;
        test_step.dependOn(&run.step);
    }
}
