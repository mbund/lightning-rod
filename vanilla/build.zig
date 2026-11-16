const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("lightning_rod_vanilla_1_21_6", .{ .root_source_file = b.path("src/lib.zig"), .target = target, .optimize = optimize });
    inline for (.{ "block_properties", "bossbars", "chat", "chunks", "commands", "connection", "domains", "entities", "game_data", "inventories", "lightning_rod", "metrics", "minecraft_model", "minecraft_packets", "players", "random_ticks", "records", "reload", "replication", "sessions", "storage", "terrain", "ticks", "vanilla_blocks", "vanilla_containers", "vanilla_content", "vanilla_crafting", "vanilla_definitions", "vanilla_equipment", "vanilla_inventory", "vanilla_item_entities", "vanilla_items", "vanilla_mobs", "vanilla_player", "vanilla_survival", "vanilla_world", "worlds" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("protocol_support", b.dependency("protocol_support", .{ .target = target, .optimize = optimize }).module("encoding"));
    module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));

    // Standalone development selects every supported release, as a server does by default,
    // so encodings that differ between releases are always compiled and tested. Consumers
    // supply their own selection.
    if (b.dep_prefix.len == 0) {
        const single = b.option(bool, "single-release", "Select only the gameplay baseline release, the smallest catalog a server can run") orelse false;
        const releases = b.option([]const u8, "releases", "Comma-separated protocol releases, every supported one by default") orelse if (single) game_data.minecraft_version else "";
        const selected = if (releases.len == 0)
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize })
        else
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
        if (selected) |protocols| b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    }

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const test_step = b.step("test", "Verify vanilla gameplay across its packages");
    const fault_disk = b.createModule(.{ .root_source_file = b.dependency("storage", .{ .target = target, .optimize = optimize }).path("src/fault_disk.zig"), .target = target, .optimize = optimize });
    // Native content must compose without the datapack package, so these tests see a
    // definitions module that has none.
    const definitions = b.dependency("vanilla_definitions", .{ .target = target, .optimize = optimize });
    const native_definitions = b.createModule(.{ .root_source_file = definitions.path("src/root.zig"), .target = target, .optimize = optimize });
    const definitions_module = definitions.module("vanilla_definitions");
    for (definitions_module.import_table.keys(), definitions_module.import_table.values()) |name, dependency|
        if (!std.mem.eql(u8, name, "datapacks")) native_definitions.addImport(name, dependency);
    const Root = struct { source: []const u8, step: ?[]const u8 = null, description: []const u8 = "", native: bool = false };
    for ([_]Root{
        .{ .source = "batch_test" },
        .{ .source = "pickup_test" },
        .{ .source = "merge_test", .step = "test-item-merging", .description = "Verify bounded item merging and ownership" },
        .{ .source = "placement_test", .step = "test-placement", .description = "Verify placement and collision raycasts" },
        .{ .source = "creative_inventory_test" },
        .{ .source = "visibility_replication_test", .step = "test-player-replication", .description = "Verify player visibility and independent packet admission" },
        .{ .source = "environment_test" },
        .{ .source = "spawn_test", .step = "test-spawn", .description = "Verify vanilla world and player spawn selection" },
        .{ .source = "enchantment_test", .step = "test-enchantments", .description = "Verify native and datapack enchantment behavior" },
        .{ .source = "registry_test", .step = "test-registries", .description = "Verify independently owned gameplay definitions" },
        .{ .source = "menu_test", .step = "test-menus", .description = "Verify crafting and container ownership across persistence" },
        .{ .source = "recipe_book_test", .step = "test-recipe-book", .description = "Verify recipe book displays placement and persistence" },
        .{ .source = "definition_provider_test", .step = "test-content", .description = "Verify loaded content and client registry configuration", .native = true },
        .{ .source = "native_content_test", .step = "test-native-content", .description = "Verify gameplay composition without the datapack package", .native = true },
        .{ .source = "datapacks_test", .step = "test-datapacks", .description = "Verify optional datapack adapters and native composition" },
    }) |root| {
        const test_module = b.createModule(.{ .root_source_file = b.path(b.fmt("src/{s}.zig", .{root.source})), .target = target, .optimize = optimize });
        for (module.import_table.keys(), module.import_table.values()) |name, dependency|
            test_module.addImport(name, if (root.native and std.mem.eql(u8, name, "vanilla_definitions")) native_definitions else dependency);
        test_module.addImport("fault_disk", fault_disk);
        const run = b.addRunArtifact(b.addTest(.{ .root_module = test_module, .filters = if (filter) |value| &.{value} else &.{} }));
        test_step.dependOn(&run.step);
        if (root.step) |name| b.step(name, root.description).dependOn(&run.step);
    }

    const pipeline_module = b.createModule(.{ .root_source_file = b.path("src/pipeline_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| pipeline_module.addImport(name, dependency);
    pipeline_module.addImport("networking", b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions").import_table.get("networking").?);
    const pipeline_bench = b.addTest(.{ .root_module = pipeline_module, .filters = if (filter) |value| &.{value} else &.{"operation counts"} });
    const run_pipeline = std.Build.Step.Run.create(b, "gameplay pipeline operations");
    run_pipeline.addArtifactArg(pipeline_bench);
    test_step.dependOn(&run_pipeline.step);
    b.step("bench-pipeline", "Count gameplay operations without timing").dependOn(&run_pipeline.step);
    const check = b.addLibrary(.{ .name = "vanilla", .root_module = module });
    b.step("check", "Check the Vanilla module").dependOn(&check.step);
}

/// Builds the vanilla server for game data other than the default, such as an older canonical
/// release. Every package that reads game data gets this one, and the vanilla definitions are
/// generated again with the host build of it.
pub fn replaceGameData(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, gameplay: *std.Build.Module, host_gameplay: *std.Build.Module) void {
    inline for (.{ "occlusion", "terrain", "replication", "vanilla_content", "vanilla_world", "vanilla_items", "vanilla_crafting", "vanilla_item_entities", "vanilla_inventory", "vanilla_survival", "vanilla_blocks", "vanilla_mobs", "vanilla_containers", "vanilla_definitions" }) |name|
        b.dependency(name, .{ .target = target, .optimize = optimize }).module(name).addImport("game_data", gameplay);
    b.modules.get("lightning_rod_vanilla_1_21_6").?.addImport("game_data", gameplay);
    const definitions = b.dependency("vanilla_definitions", .{ .target = target, .optimize = optimize });
    // A server built for the host in debug shares its packages with the generator, which then
    // reads the server's game data.
    const shared = definitions.builder.dependency("vanilla_items", .{ .target = b.graph.host, .optimize = .debug }) == definitions.builder.dependency("vanilla_items", .{ .target = target, .optimize = optimize });
    const generator = @import("vanilla_definitions").contentGenerator(definitions.builder, if (shared) gameplay else host_gameplay);
    const prepared = b.addRunArtifact(generator).addOutputFileArg("vanilla_content.zig");
    definitions.module("vanilla_definitions").addAnonymousImport("generated_definitions", .{ .root_source_file = prepared });
}
