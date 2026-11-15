const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("vanilla_definitions", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    inline for (.{ "datapacks", "game_data", "lighting", "lightning_rod", "vanilla_blocks", "vanilla_content", "vanilla_crafting", "vanilla_items" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("protocol_support", b.dependency("protocol_support", .{ .target = target, .optimize = optimize }).module("encoding"));

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
    const tests = b.addTest(.{ .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify vanilla definitions and datapack adapters");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The generator decodes the vanilla datapack at build time into native definitions,
    // which the module embeds instead of decoding at startup.
    const generator = contentGenerator(b, b.dependency("game_data", .{ .target = b.graph.host, .optimize = .debug }).module("game_data"));
    const run_prepare = b.addRunArtifact(generator);
    const prepared_definitions = run_prepare.addOutputFileArg("vanilla_content.zig");
    module.addAnonymousImport("generated_definitions", .{ .root_source_file = prepared_definitions });
    b.step("prepare-content", "Generate vanilla gameplay definitions").dependOn(&run_prepare.step);
    const prepared_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/vanilla_content_test.zig"), .target = b.graph.host, .optimize = .debug }) });
    for (generator.root_module.import_table.keys(), generator.root_module.import_table.values()) |name, dependency| prepared_tests.root_module.addImport(name, dependency);
    prepared_tests.root_module.addAnonymousImport("generated_definitions", .{ .root_source_file = prepared_definitions });
    const test_content = b.addRunArtifact(prepared_tests);
    test_step.dependOn(&test_content.step);
    b.step("test-prepared-content", "Verify compiled vanilla gameplay definitions").dependOn(&test_content.step);
}

/// The program that decodes the vanilla datapack into native definitions with the given game
/// data. A server built for other game data generates its definitions with that data.
pub fn contentGenerator(b: *std.Build, gameplay: *std.Build.Module) *std.Build.Step.Compile {
    const host = b.graph.host;
    const module = b.createModule(.{ .root_source_file = b.path("src/prepare_content.zig"), .target = host, .optimize = .debug });
    module.addImport("game_data", gameplay);
    inline for (.{ "datapacks", "lighting", "lightning_rod" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = host, .optimize = .debug }).module(name));
    // The definitions are decoded by these packages too, so they read the same game data.
    inline for (.{ "vanilla_blocks", "vanilla_content", "vanilla_crafting", "vanilla_items" }) |name| {
        const package = b.dependency(name, .{ .target = host, .optimize = .debug }).module(name);
        package.addImport("game_data", gameplay);
        module.addImport(name, package);
    }
    module.addImport("protocol_support", b.dependency("protocol_support", .{ .target = host, .optimize = .debug }).module("encoding"));
    return b.addExecutable(.{ .name = "prepare-vanilla-content", .root_module = module });
}
