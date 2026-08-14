const std = @import("std");
const protocol_graph = @import("build/protocol_graph.zig");
const protocol_manifest = @import("build/protocols.zig");
const test_steps = @import("build/test_steps.zig");
const worldgen_graph = @import("build/worldgen_graph.zig");
const vanilla_gameplay_version = protocol_manifest.versions[protocol_manifest.canonical].minecraft_version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protocols = protocol_graph.add(b, target, optimize);
    const preallocated = b.createModule(.{
        .root_source_file = b.path("src/preallocated.zig"),
        .target = target,
        .optimize = optimize,
    });
    const worldgen = worldgen_graph.add(b, target, optimize, preallocated, vanilla_gameplay_version);
    const options = serverOptions(b);
    const options_module = options.createModule();
    const library = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "protocol", .module = protocols.wire },
            .{ .name = "protocol_catalog", .module = protocols.catalog },
            .{ .name = "protocol_support", .module = protocols.support },
            .{ .name = "nbt", .module = protocols.nbt },
            .{ .name = "registry_data", .module = protocols.registry },
            .{ .name = "server_options", .module = options_module },
            .{ .name = "preallocated", .module = preallocated },
            .{ .name = "worldgen", .module = worldgen },
        },
    });
    const vanilla = b.createModule(.{
        .root_source_file = b.path("src/vanilla_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = library }},
    });
    _ = b.addModule("lightning_rod_reload_test_support", .{
        .root_source_file = b.path("src/reload_test_support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "protocol", .module = protocols.wire },
        },
    });
    test_steps.add(b, target, optimize, library, vanilla, protocols, worldgen);
}

fn serverOptions(b: *std.Build) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(usize, "max_players", b.option(usize, "max-players", "Maximum player capacity") orelse 64);
    options.addOption(usize, "max_worlds", b.option(usize, "max-worlds", "Maximum loaded world instances") orelse 4096);
    options.addOption(usize, "status_connection_reserve", b.option(usize, "status-reserve", "Reserved status connections") orelse 16);
    options.addOption(i32, "view_distance_chunks", b.option(i32, "view-distance", "Maximum view distance") orelse 32);
    options.addOption(i32, "simulation_distance_chunks", b.option(i32, "simulation-distance", "Maximum simulation distance") orelse 32);
    options.addOption(u8, "random_tick_speed", b.option(u8, "random-tick-speed", "Default random tick speed") orelse 3);
    options.addOption(usize, "output_buffer_count", b.option(usize, "output-buffers", "Preallocated output buffers") orelse 256);
    options.addOption(usize, "max_living_entities", b.option(usize, "living-entities", "Living entity capacity") orelse 4096);
    options.addOption(usize, "max_path_search_nodes", b.option(usize, "path-search-nodes", "Path search node capacity") orelse 4096);
    options.addOption(usize, "max_path_nodes", b.option(usize, "path-nodes", "Maximum nodes in one path") orelse 128);
    options.addOption(usize, "max_modified_sections", b.option(usize, "modified-sections", "Modified section capacity") orelse 4096);
    options.addOption(usize, "max_resident_chunks", b.option(usize, "resident-chunks", "Resident chunk capacity") orelse 16 * 1024);
    options.addOption(usize, "max_item_entities", b.option(usize, "item-entities", "Item entity capacity") orelse 1024);
    options.addOption(u64, "checkpoint_interval_ticks", b.option(u64, "checkpoint-ticks", "Checkpoint interval") orelse 20 * 60 * 5);
    options.addOption(u16, "port", b.option(u16, "port", "Default listen port") orelse 25565);
    options.addOption(bool, "tick_input_memory_guards", b.option(bool, "memory-guards", "Protect expired tick memory") orelse false);
    options.addOption(usize, "tick_input_virtual_bytes", b.option(usize, "tick-virtual-bytes", "Reserved tick-input address space") orelse 8 * 1024 * 1024 * 1024 * 1024);
    options.addOption([]const u8, "tick_module_path", b.option([]const u8, "tick-module-path", "Reloadable tick module path") orelse "zig-out/lib/liblightning_rod_tick.so");
    options.addOption(usize, "reload_state_virtual_bytes", b.option(usize, "reload-virtual-bytes", "Reserved generation address space") orelse 1024 * 1024 * 1024 * 1024);
    options.addOption(usize, "tick_state_bytes", b.option(usize, "tick-state-bytes", "Tick module state capacity") orelse 2 * 1024 * 1024 * 1024);
    return options;
}
