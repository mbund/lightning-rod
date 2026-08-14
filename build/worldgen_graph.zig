const std = @import("std");

const Input = union(enum) {
    file: std.Build.LazyPath,
    directory: std.Build.LazyPath,
};

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    preallocated: *std.Build.Module,
    minecraft_version: []const u8,
) *std.Build.Module {
    const worldgen_data = generate(b, target, optimize, minecraft_version, "worldgen", &.{
        .{ .file = data(b, minecraft_version, "overworld_offset_spline.json") },
        .{ .file = data(b, minecraft_version, "overworld_biome_tree.json") },
        .{ .directory = data(b, minecraft_version, "biome") },
    });
    const density_data = generate(b, target, optimize, minecraft_version, "density", &.{
        .{ .directory = data(b, minecraft_version, "density_function") },
        .{ .directory = data(b, minecraft_version, "noise") },
        .{ .file = data(b, minecraft_version, "overworld_noise_settings.json") },
    });
    const surface_data = generate(b, target, optimize, minecraft_version, "surface", &.{
        .{ .directory = data(b, minecraft_version, "noise") },
        .{ .file = data(b, minecraft_version, "overworld_noise_settings.json") },
    });
    const carver_data = generate(b, target, optimize, minecraft_version, "carver", &.{
        .{ .directory = data(b, minecraft_version, "configured_carver") },
    });
    const feature_data = generate(b, target, optimize, minecraft_version, "feature", &.{
        .{ .file = data(b, minecraft_version, "overworld_features.json") },
        .{ .file = data(b, minecraft_version, "overworld_biome_tree.json") },
        .{ .directory = data(b, minecraft_version, "biome") },
    });
    return b.addModule("worldgen", .{
        .root_source_file = b.path("src/worldgen/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "worldgen_data", .module = worldgen_data },
            .{ .name = "density_data", .module = density_data },
            .{ .name = "surface_data", .module = surface_data },
            .{ .name = "carver_data", .module = carver_data },
            .{ .name = "feature_data", .module = feature_data },
            .{ .name = "preallocated", .module = preallocated },
        },
    });
}

fn generate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    minecraft_version: []const u8,
    name: []const u8,
    inputs: []const Input,
) *std.Build.Module {
    const executable = b.addExecutable(.{
        .name = b.fmt("{s}_codegen", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("codegen/{s}_codegen.zig", .{name})),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    for (inputs) |input| switch (input) {
        .file => |path| command.addFileArg(path),
        .directory => |path| command.addDirectoryArg(path),
    };
    return b.createModule(.{
        .root_source_file = command.addOutputFileArg(b.fmt("{s}_data_{s}.zig", .{ name, minecraft_version })),
        .target = target,
        .optimize = optimize,
    });
}

fn data(b: *std.Build, minecraft_version: []const u8, path: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("tools/worldgen/vanilla-{s}/{s}", .{ minecraft_version, path }));
}
