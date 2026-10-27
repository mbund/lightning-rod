const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "lightning_rod", "game_data", "minecraft_packets", "minecraft_java", "sessions", "chunks", "entities", "inventories", "metrics", "records", "commands", "reload", "worlds", "storage" };
    var imports: [names.len + 2]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, i| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[i] = .{ .name = name, .module = dependency.module(name) };
    }

    imports[names.len] = .{
        .name = "minecraft_model",
        .module = b.dependency("minecraft_model", .{ .target = target, .optimize = optimize }).module("minecraft_model"),
    };
    imports[names.len + 1] = .{
        .name = "protocol_support",
        .module = b.dependency("protocol_support", .{ .target = target, .optimize = optimize }).module("encoding"),
    };

    const module = b.addModule("lightning_rod_vanilla_1_21_6", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_1_21_6", b.dependency("protocol_1_21_6", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_1_21_8", b.dependency("protocol_1_21_8", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_1_21_11", b.dependency("protocol_1_21_11", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_26_1", b.dependency("protocol_26_1", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_26_2", b.dependency("protocol_26_2", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_1_21_9", b.dependency("protocol_1_21_9", .{ .target = target, .optimize = optimize }).module("wire"));

    // Standalone development needs a concrete selection. Consumers supply their own.
    if (b.dep_prefix.len == 0) {
        const releases = b.option([]const u8, "releases", "Standalone development protocol releases") orelse "1.21.8";
        if (b.lazyDependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases })) |protocols| {
            module.addImport("protocols", protocols.module("protocols"));
            b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
        }
    }

    const test_step = b.step("test", "Verify encoding and batched gameplay records");
    for ([_][]const u8{ "src/chunk_encoding.zig", "src/block_sync.zig", "src/streaming.zig", "src/batch_test.zig", "src/pickup_test.zig", "src/merge_test.zig", "src/item_spatial_test.zig", "src/item_selection_test.zig", "src/placement_test.zig", "src/creative_inventory.zig", "src/command_dispatch_test.zig", "src/replication.zig", "src/visibility.zig", "src/visibility_replication_test.zig", "src/environment_test.zig", "src/configuration_test.zig", "src/session_keepalive.zig", "src/generation.zig", "src/random.zig" }) |source| {
        const test_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize });
        for (module.import_table.keys(), module.import_table.values()) |name, dependency|
            test_module.addImport(name, dependency);
        const tests = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const pipeline_module = b.createModule(.{ .root_source_file = b.path("src/pipeline_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        pipeline_module.addImport(name, dependency);
    pipeline_module.addImport("networking", b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions").import_table.get("networking").?);
    const pipeline_bench = b.addTest(.{ .root_module = pipeline_module, .filters = &.{"operation counts"} });
    const run_pipeline = std.Build.Step.Run.create(b, "gameplay pipeline operations");
    run_pipeline.addArtifactArg(pipeline_bench);
    test_step.dependOn(&run_pipeline.step);
    b.step("bench-pipeline", "Count gameplay operations without timing").dependOn(&run_pipeline.step);
    const check = b.addLibrary(.{ .name = "vanilla", .root_module = module });
    b.step("check", "Check the Vanilla module").dependOn(&check.step);
}
