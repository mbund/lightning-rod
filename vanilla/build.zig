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
    const spawn_tests = b.step("test-spawn", "Verify vanilla world and player spawn selection");
    const lighting_tests = b.step("test-lighting", "Verify terrain lighting and chunk packet integration");
    const replication_tests = b.step("test-player-replication", "Verify player visibility and independent packet admission");
    const test_step = b.step("test", "Verify encoding and batched gameplay records");
    const occlusion_step = b.step("test-occlusion", "Verify conservative volume visibility");
    const disclosure_module = b.createModule(.{ .root_source_file = b.path("src/disclosure_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| disclosure_module.addImport(name, dependency);
    const disclosure_tests = b.addRunArtifact(b.addTest(.{ .root_module = disclosure_module }));
    occlusion_step.dependOn(&disclosure_tests.step);
    test_step.dependOn(&disclosure_tests.step);
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
    const debug_module = b.createModule(.{ .root_source_file = b.path("src/region_debug.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| debug_module.addImport(name, dependency);
    const debug_tests = b.addRunArtifact(b.addTest(.{ .root_module = debug_module }));
    const debug_step = b.step("test-region-debug", "Verify disclosure inspection and debug packets");
    debug_step.dependOn(&debug_tests.step);
    test_step.dependOn(&debug_tests.step);
    const section_visibility_module = b.createModule(.{ .root_source_file = b.path("src/section_visibility_world.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| section_visibility_module.addImport(name, dependency);
    const section_visibility_tests = b.addRunArtifact(b.addTest(.{ .root_module = section_visibility_module }));
    b.step("test-section-visibility", "Verify section portals and deterministic disclosure").dependOn(&section_visibility_tests.step);
    test_step.dependOn(&section_visibility_tests.step);
    occlusion_step.dependOn(&section_visibility_tests.step);
    const visibility_bench_module = b.createModule(.{ .root_source_file = b.path("src/section_visibility_bench.zig"), .target = target, .optimize = optimize });
    const visibility_bench = b.addTest(.{ .root_module = visibility_bench_module, .filters = if (filter) |value| &.{value} else &.{ "shared section visibility workloads", "section topology workloads", "cached bend traversal workload" } });
    const visibility_run = std.Build.Step.Run.create(b, "shared section visibility workloads");
    visibility_run.addArtifactArg(visibility_bench);
    b.step("bench-sections", "Measure section traversal and sealed-source bounds").dependOn(&visibility_run.step);
    for ([_][]const u8{ "src/chunk_encoding.zig", "src/lighting.zig", "src/container_blocks.zig", "src/furnace.zig", "src/block_sync.zig", "src/streaming.zig", "src/batch_test.zig", "src/pickup_test.zig", "src/merge_test.zig", "src/item_spatial_test.zig", "src/item_selection_test.zig", "src/placement_test.zig", "src/creative_inventory.zig", "src/command_dispatch_test.zig", "src/replication.zig", "src/visibility.zig", "src/visibility_replication_test.zig", "src/environment_test.zig", "src/configuration_test.zig", "src/session_keepalive.zig", "src/generation.zig", "src/random.zig", "src/raycast.zig", "src/spawn.zig", "src/spawn_test.zig" }) |source| {
        const test_module = b.createModule(.{ .root_source_file = b.path(source), .target = target, .optimize = optimize });
        for (module.import_table.keys(), module.import_table.values()) |name, dependency|
            test_module.addImport(name, dependency);
        const tests = b.addTest(.{ .root_module = test_module, .filters = if (filter) |value| &.{value} else &.{} });
        const run = b.addRunArtifact(tests);
        test_step.dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/streaming.zig")) debug_step.dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/replication.zig") or std.mem.eql(u8, source, "src/visibility_replication_test.zig")) replication_tests.dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/placement_test.zig")) b.step("test-placement", "Verify placement and collision raycasts").dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/block_sync.zig")) b.step("test-block-sync", "Verify block publication and visibility ordering").dependOn(&run.step);
        if (std.mem.eql(u8, source, "src/spawn.zig") or std.mem.eql(u8, source, "src/spawn_test.zig")) spawn_tests.dependOn(&run.step);
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
    const streaming_options = b.addOptions();
    streaming_options.addOption(usize, "radius", b.option(usize, "streaming-radius", "Render distance for the imported world benchmark") orelse 32);
    streaming_options.addOption(usize, "players", b.option(usize, "streaming-players", "Concurrent observers in the imported world benchmark") orelse 1);
    streaming_options.addOption(usize, "spacing", b.option(usize, "streaming-spacing", "Chunk spacing between surface observers, zero shares the same source") orelse 0);
    streaming_options.addOption(bool, "encryption", b.option(bool, "streaming-encryption", "Encrypt each recipient's stream with the production cipher") orelse false);
    streaming_options.addOption(bool, "stored_lighting", b.option(bool, "streaming-stored-lighting", "Use lighting baked into the chunk store") orelse true);
    streaming_options.addOption(?bool, "occlusion", b.option(bool, "streaming-occlusion", "Run only the selected occlusion mode"));
    streaming_options.addOption(?[]const u8, "corpus", b.option([]const u8, "streaming-corpus", "Export encoded packets and frames for isolated component benchmarks"));
    streaming_options.addOption(bool, "movement", b.option(bool, "streaming-movement", "Measure sustained flight after initial streaming") orelse false);
    streaming_options.addOption([]const u8, "flight_speeds", b.option([]const u8, "streaming-flight-speeds", "Comma separated flight speeds in blocks per second") orelse "80");
    streaming_options.addOption(bool, "flight_settle", b.option(bool, "streaming-flight-settle", "Complete every flight position for deterministic workload and bandwidth comparisons") orelse false);
    streaming_options.addOption(bool, "lighting_comparison", b.option(bool, "streaming-lighting-comparison", "Compare fresh and retained lighting with identical encoded packets") orelse false);
    streaming_options.addOption(?[]const u8, "world", b.option([]const u8, "streaming-world", "Native world copy for the streaming benchmark"));
    streaming_options.addOption(?[]const u8, "position", b.option([]const u8, "streaming-position", "Observer feet as X,Y,Z instead of automatic surface and cave positions"));
    streaming_options.addOption(?[]const u8, "hidden", b.option([]const u8, "streaming-hidden", "Semicolon separated X,Y,Z block positions that must remain concealed"));
    lighting_load_module.addOptions("streaming_benchmark_options", streaming_options);
    const streaming_bench = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world streaming"} });
    const streaming_fixture = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world fixture"} }));
    b.step("verify-streaming-world", "Verify complete and distinct terrain for streaming observers").dependOn(&streaming_fixture.step);
    const movement_tests = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"streaming movement"} }));
    b.step("test-streaming-movement", "Verify moving observers while chunk delivery catches up").dependOn(&movement_tests.step);
    lighting_tests.dependOn(&movement_tests.step);
    test_step.dependOn(&movement_tests.step);
    const cold_tests = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"cold lighting streams"} }));
    b.step("test-streaming-cold", "Verify cold lighting progress with separated observers and constrained caches").dependOn(&cold_tests.step);
    lighting_tests.dependOn(&cold_tests.step);
    test_step.dependOn(&cold_tests.step);
    const streaming_run = std.Build.Step.Run.create(b, "imported world streaming");
    streaming_run.addArtifactArg(streaming_bench);
    streaming_run.step.dependOn(&streaming_fixture.step);
    b.step("bench-streaming", "Measure real world chunk streaming without client rendering").dependOn(&streaming_run.step);
    const scaling_bench = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world player scaling"} });
    const scaling_run = std.Build.Step.Run.create(b, "imported world player scaling");
    scaling_run.addArtifactArg(scaling_bench);
    b.step("bench-streaming-scaling", "Measure shared and independent player streams with sealed allocation").dependOn(&scaling_run.step);
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
