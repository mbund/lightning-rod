const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "lighting", "lightning_rod", "game_data", "datapacks", "minecraft_packets", "minecraft_java", "sessions", "chunks", "entities", "inventories", "metrics", "records", "commands", "reload", "worlds", "storage" };
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
        const releases = b.option([]const u8, "releases", "Standalone development protocol releases") orelse game_data.minecraft_version;
        if (b.lazyDependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases })) |protocols| {
            module.addImport("protocols", protocols.module("protocols"));
            b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
        }
    }

    const prepare_content = contentGenerator(b, b.dependency("game_data", .{ .target = b.graph.host, .optimize = .debug }).module("game_data"));
    const generator_module = prepare_content.root_module;
    const run_prepare = b.addRunArtifact(prepare_content);
    const prepared_definitions = run_prepare.addOutputFileArg("vanilla_content.zig");
    module.addAnonymousImport("vanilla_definitions", .{ .root_source_file = prepared_definitions });
    b.step("prepare-content", "Generate vanilla gameplay definitions").dependOn(&run_prepare.step);

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const lighting_tests = b.step("test-lighting", "Verify terrain lighting and chunk packet integration");
    const test_step = b.step("test", "Verify encoding and batched gameplay records");
    const prepared_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/vanilla_content_test.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    for (generator_module.import_table.keys(), generator_module.import_table.values()) |name, dependency| prepared_tests.root_module.addImport(name, dependency);
    prepared_tests.root_module.addAnonymousImport("vanilla_definitions", .{ .root_source_file = prepared_definitions });
    const test_content = b.addRunArtifact(prepared_tests);
    test_step.dependOn(&test_content.step);
    b.step("test-prepared-content", "Verify compiled vanilla gameplay definitions").dependOn(&test_content.step);
    for ([_][]const u8{ "src/chunk_encoding.zig", "src/lighting.zig", "src/container_blocks.zig", "src/furnace.zig", "src/block_sync.zig", "src/streaming.zig", "src/batch_test.zig", "src/pickup_test.zig", "src/merge_test.zig", "src/item_spatial_test.zig", "src/item_selection_test.zig", "src/placement_test.zig", "src/creative_inventory.zig", "src/command_dispatch_test.zig", "src/replication.zig", "src/visibility.zig", "src/visibility_replication_test.zig", "src/environment_test.zig", "src/configuration_test.zig", "src/session_keepalive.zig", "src/generation.zig", "src/random.zig", "src/raycast.zig" }) |source| {
        const test_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize });
        for (module.import_table.keys(), module.import_table.values()) |name, dependency|
            test_module.addImport(name, dependency);
        const tests = b.addTest(.{ .root_module = test_module, .filters = if (filter) |value| &.{value} else &.{} });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/placement_test.zig")) b.step("test-placement", "Verify placement and collision raycasts").dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/raycast.zig")) b.step("test-raycast", "Verify bounded voxel traversal").dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/lighting.zig") or std.mem.eql(u8, source, "src/chunk_encoding.zig") or std.mem.eql(u8, source, "src/streaming.zig"))
            lighting_tests.dependOn(&run.step);
    }

    const enchantment_module = b.createModule(.{ .root_source_file = b.path("src/enchantment_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| enchantment_module.addImport(name, dependency);
    const enchantment_tests = b.addRunArtifact(b.addTest(.{ .root_module = enchantment_module }));
    b.step("test-enchantments", "Verify native and datapack enchantment behavior").dependOn(&enchantment_tests.step);
    test_step.dependOn(&enchantment_tests.step);

    const registry_module = b.createModule(.{ .root_source_file = b.path("src/registry_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| registry_module.addImport(name, dependency);
    const registry_tests = b.addRunArtifact(b.addTest(.{ .root_module = registry_module }));
    b.step("test-registries", "Verify independently owned gameplay definitions").dependOn(&registry_tests.step);
    test_step.dependOn(&registry_tests.step);

    const menu_module = b.createModule(.{ .root_source_file = b.path("src/menu_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| menu_module.addImport(name, dependency);
    menu_module.addImport("fault_disk", b.createModule(.{ .root_source_file = b.dependency("storage", .{ .target = target, .optimize = optimize }).path("src/fault_disk.zig"), .target = target, .optimize = optimize }));
    const menu_tests = b.addRunArtifact(b.addTest(.{ .root_module = menu_module }));
    b.step("test-menus", "Verify crafting and container ownership across persistence").dependOn(&menu_tests.step);
    test_step.dependOn(&menu_tests.step);
    const book_module = b.createModule(.{ .root_source_file = b.path("src/recipe_book_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| book_module.addImport(name, dependency);
    const book_tests = b.addRunArtifact(b.addTest(.{ .root_module = book_module }));
    b.step("test-recipe-book", "Verify recipe book displays placement and persistence").dependOn(&book_tests.step);
    test_step.dependOn(&book_tests.step);
    const recipe_module = b.createModule(.{ .root_source_file = b.path("src/recipes.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| recipe_module.addImport(name, dependency);
    const recipe_tests = b.addRunArtifact(b.addTest(.{ .root_module = recipe_module }));
    b.step("test-recipes", "Verify typed and JSON recipe preparation").dependOn(&recipe_tests.step);
    test_step.dependOn(&recipe_tests.step);
    const content_module = b.createModule(.{ .root_source_file = b.path("src/definition_provider_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| content_module.addImport(name, dependency);
    _ = content_module.import_table.swapRemove("datapacks");
    const content_tests = b.addRunArtifact(b.addTest(.{ .root_module = content_module }));
    b.step("test-content", "Verify loaded content and client registry configuration").dependOn(&content_tests.step);
    test_step.dependOn(&content_tests.step);
    const native_content_module = b.createModule(.{ .root_source_file = b.path("src/native_content_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| if (!std.mem.eql(u8, name, "datapacks")) native_content_module.addImport(name, dependency);
    const native_content_tests = b.addRunArtifact(b.addTest(.{ .root_module = native_content_module }));
    b.step("test-native-content", "Verify gameplay composition without the datapack package").dependOn(&native_content_tests.step);
    test_step.dependOn(&native_content_tests.step);
    const datapack_module = b.createModule(.{ .root_source_file = b.path("src/datapacks_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| datapack_module.addImport(name, dependency);
    const datapack_tests = b.addRunArtifact(b.addTest(.{ .root_module = datapack_module }));
    b.step("test-datapacks", "Verify optional datapack adapters and native composition").dependOn(&datapack_tests.step);
    test_step.dependOn(&datapack_tests.step);
    const loot_module = b.createModule(.{ .root_source_file = b.path("src/loot.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| loot_module.addImport(name, dependency);
    const loot_tests = b.addRunArtifact(b.addTest(.{ .root_module = loot_module }));
    b.step("test-loot", "Verify prepared block loot and pack overrides").dependOn(&loot_tests.step);
    test_step.dependOn(&loot_tests.step);

    const pipeline_module = b.createModule(.{ .root_source_file = b.path("src/pipeline_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        pipeline_module.addImport(name, dependency);
    pipeline_module.addImport("networking", b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions").import_table.get("networking").?);
    const pipeline_bench = b.addTest(.{ .root_module = pipeline_module, .filters = if (filter) |value| &.{value} else &.{"operation counts"} });
    const run_pipeline = std.Build.Step.Run.create(b, "gameplay pipeline operations");
    run_pipeline.addArtifactArg(pipeline_bench);
    test_step.dependOn(&run_pipeline.step);
    b.step("bench-pipeline", "Count gameplay operations without timing").dependOn(&run_pipeline.step);
    const lighting_bench_module = b.createModule(.{ .root_source_file = b.path("src/lighting_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        lighting_bench_module.addImport(name, dependency);
    lighting_bench_module.addImport("networking", b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions").import_table.get("networking").?);
    const lighting_bench = b.addTest(.{ .root_module = lighting_bench_module, .filters = if (filter) |value| &.{value} else &.{"lighting pipeline"} });
    const lighting_bench_run = std.Build.Step.Run.create(b, "lighting pipeline operations");
    lighting_bench_run.addArtifactArg(lighting_bench);
    test_step.dependOn(&lighting_bench_run.step);
    lighting_tests.dependOn(&lighting_bench_run.step);
    const lighting_load_module = b.createModule(.{ .root_source_file = b.path("src/lighting_load.zig"), .target = target, .optimize = optimize });
    for (lighting_bench_module.import_table.keys(), lighting_bench_module.import_table.values()) |name, dependency|
        lighting_load_module.addImport(name, dependency);
    const lighting_load = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"lighting load"} });
    const lighting_load_run = std.Build.Step.Run.create(b, "lighting streaming load");
    lighting_load_run.addArtifactArg(lighting_load);
    const benchmark_lighting = b.step("bench-lighting", "Measure deterministic lighting pipeline operation counts");
    benchmark_lighting.dependOn(&lighting_bench_run.step);
    benchmark_lighting.dependOn(&lighting_load_run.step);
    const check = b.addLibrary(.{ .name = "vanilla", .root_module = module });
    b.step("check", "Check the Vanilla module").dependOn(&check.step);
}

pub fn contentGenerator(b: *std.Build, gameplay: *std.Build.Module) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path("src/prepare_content.zig"), .target = b.graph.host, .optimize = .debug });
    module.addImport("game_data", gameplay);
    inline for (.{ "datapacks", "lighting", "minecraft_model", "inventories", "sessions" }) |name| {
        module.addImport(name, b.dependency(name, .{ .target = b.graph.host, .optimize = .debug }).module(name));
    }
    module.addImport("protocol_support", b.dependency("protocol_support", .{ .target = b.graph.host, .optimize = .debug }).module("encoding"));
    return b.addExecutable(.{ .name = "prepare-vanilla-content", .root_module = module });
}
