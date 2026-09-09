const std = @import("std");

const minecraft_version = "1.21.8";

const Input = union(enum) {
    file: std.Build.LazyPath,
    directory: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const assets = vanillaAssets(b);
    const module = addModuleWithAssets(b, target, optimize, assets);

    const tests = b.addTest(.{
        .root_module = module,
        .filters = if (test_filter) |value| &.{value} else &.{},
        .test_runner = .{
            .path = b.dependency("lightning_rod_test_runner", .{}).path("src/main.zig"),
            .mode = .simple,
        },
    });
    tests.use_llvm = true;
    tests.use_lld = true;
    b.step("test", "Run Vanilla world-generation tests")
        .dependOn(&b.addRunArtifact(tests).step);

    const benchmark = b.addExecutable(.{
        .name = "vanilla_worldgen_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
            .imports = &.{.{ .name = "vanilla_worldgen", .module = module }},
        }),
    });
    benchmark.use_llvm = true;
    benchmark.use_lld = true;
    const run_benchmark = b.addRunArtifact(benchmark);
    if (b.args) |arguments| run_benchmark.addArgs(arguments);
    b.step("benchmark", "Measure complete Vanilla chunk throughput")
        .dependOn(&run_benchmark.step);

    addSeedFinder(b, target, optimize, module);
    addFeatureCoverage(b, assets);
}

pub fn addModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return addModuleWithAssets(b, target, optimize, vanillaAssets(b));
}

fn addModuleWithAssets(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    assets: Assets,
) *std.Build.Module {
    const minecraft_registry = b.dependency("minecraft_registry", .{
        .target = target,
        .optimize = optimize,
    }).module("minecraft_registry");
    const nbt = b.dependency("nbt", .{
        .target = target,
        .optimize = optimize,
    }).module("nbt");
    const worldgen_data = generate(b, target, optimize, "worldgen", &.{
        .{ .file = assets.worldgen.path(b, "density_function/overworld/offset.json") },
        .{ .file = assets.reports.path(b, "biome_parameters/minecraft/overworld.json") },
        .{ .directory = assets.worldgen.path(b, "biome") },
    });
    const density_data = generate(b, target, optimize, "density", &.{
        .{ .directory = assets.worldgen.path(b, "density_function") },
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/overworld.json") },
    });
    const nether_density_data = generate(b, target, optimize, "density_nether", &.{
        .{ .directory = assets.worldgen.path(b, "density_function") },
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/nether.json") },
    });
    const end_density_data = generate(b, target, optimize, "density_end", &.{
        .{ .directory = assets.worldgen.path(b, "density_function") },
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/end.json") },
    });
    const surface_data = generate(b, target, optimize, "surface", &.{
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/overworld.json") },
    });
    const nether_surface_data = generate(b, target, optimize, "surface_nether", &.{
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/nether.json") },
    });
    const end_surface_data = generate(b, target, optimize, "surface_end", &.{
        .{ .directory = assets.worldgen.path(b, "noise") },
        .{ .file = assets.worldgen.path(b, "noise_settings/end.json") },
    });
    const carver_data = generate(b, target, optimize, "carver", &.{
        .{ .directory = assets.worldgen.path(b, "configured_carver") },
    });
    const feature_data = generate(b, target, optimize, "feature", &.{
        .{ .file = data(b, "implemented_features.manifest") },
        .{ .file = assets.reports.path(b, "biome_parameters/minecraft/overworld.json") },
        .{ .directory = assets.worldgen.path(b, "biome") },
    });
    const structure_data = generateStructures(b, target, optimize, assets.structures);
    const jigsaw_data = generateJigsawPools(b, target, optimize, assets.template_pools);
    const processor_data = generateProcessors(b, target, optimize, assets.processors);
    const preallocated = b.createModule(.{
        .root_source_file = b.path("src/preallocated.zig"),
        .target = target,
        .optimize = optimize,
    });
    return b.addModule("vanilla_worldgen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "worldgen_data", .module = worldgen_data },
            .{ .name = "density_data", .module = density_data },
            .{ .name = "surface_data", .module = surface_data },
            .{ .name = "carver_data", .module = carver_data },
            .{ .name = "feature_data", .module = feature_data },
            .{ .name = "structure_data", .module = structure_data },
            .{ .name = "jigsaw_data", .module = jigsaw_data },
            .{ .name = "processor_data", .module = processor_data },
            .{ .name = "preallocated", .module = preallocated },
            .{ .name = "minecraft_registry", .module = minecraft_registry },
            .{ .name = "nbt", .module = nbt },
            .{ .name = "nether_density_data", .module = nether_density_data },
            .{ .name = "end_density_data", .module = end_density_data },
            .{ .name = "nether_surface_data", .module = nether_surface_data },
            .{ .name = "end_surface_data", .module = end_surface_data },
        },
    });
}

fn generateProcessors(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    input: std.Build.LazyPath,
) *std.Build.Module {
    const executable = b.addExecutable(.{
        .name = "processor_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/processor_codegen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    command.addDirectoryArg(input);
    return b.createModule(.{
        .root_source_file = command.addOutputFileArg("processor_data_1.21.8.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn generateJigsawPools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    input: std.Build.LazyPath,
) *std.Build.Module {
    const executable = b.addExecutable(.{
        .name = "jigsaw_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/jigsaw_codegen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    command.addDirectoryArg(input);
    return b.createModule(.{
        .root_source_file = command.addOutputFileArg("jigsaw_data_1.21.8.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn addFeatureCoverage(b: *std.Build, assets: Assets) void {
    const executable = b.addExecutable(.{
        .name = "worldgen_feature_coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/feature_coverage.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(executable);
    run.addFileArg(data(b, "implemented_features.manifest"));
    run.addFileArg(assets.reports.path(b, "biome_parameters/minecraft/overworld.json"));
    run.addDirectoryArg(assets.worldgen.path(b, "biome"));
    run.addDirectoryArg(assets.worldgen.path(b, "placed_feature"));
    run.addDirectoryArg(assets.worldgen.path(b, "configured_feature"));
    b.step("feature-coverage", "List implemented and missing Vanilla biome features")
        .dependOn(&run.step);
}

fn generateStructures(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    input: std.Build.LazyPath,
) *std.Build.Module {
    const executable = b.addExecutable(.{
        .name = "structure_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/structure_codegen.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "nbt",
                .module = b.dependency("nbt", .{}).module("nbt"),
            }},
        }),
    });
    const command = b.addRunArtifact(executable);
    command.addDirectoryArg(input);
    const source = command.addOutputFileArg("structure_data_1.21.8.zig");
    _ = command.addOutputFileArg("structure_templates_1.21.8.bin");
    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
    });
}

fn generate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    inputs: []const Input,
) *std.Build.Module {
    const separator = std.mem.indexOfScalar(u8, name, '_');
    const generator_name = if (separator) |index| name[0..index] else name;
    const codegen_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("codegen/{s}_codegen.zig", .{generator_name})),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    if (std.mem.eql(u8, generator_name, "feature") or
        std.mem.eql(u8, generator_name, "surface"))
    {
        codegen_module.addImport("minecraft_registry", b.dependency("minecraft_registry", .{
            .target = b.graph.host,
            .optimize = .Debug,
        }).module("minecraft_registry"));
    }
    const executable = b.addExecutable(.{
        .name = b.fmt("{s}_codegen", .{name}),
        .root_module = codegen_module,
    });
    const command = b.addRunArtifact(executable);
    for (inputs) |input| switch (input) {
        .file => |path| command.addFileArg(path),
        .directory => |path| command.addDirectoryArg(path),
    };
    return b.createModule(.{
        .root_source_file = command.addOutputFileArg(
            b.fmt("{s}_data_{s}.zig", .{ name, minecraft_version }),
        ),
        .target = target,
        .optimize = optimize,
    });
}

fn data(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return b.path(b.fmt("data/vanilla-{s}/{s}", .{ minecraft_version, path }));
}

const Assets = struct {
    worldgen: std.Build.LazyPath,
    structures: std.Build.LazyPath,
    template_pools: std.Build.LazyPath,
    processors: std.Build.LazyPath,
    reports: std.Build.LazyPath,
};

fn vanillaAssets(b: *std.Build) Assets {
    const server_url = "https://piston-data.mojang.com/v1/objects/6bce4ef400e4efaa63a13d5e6f6b500be969ef81/server.jar";
    const server_sha1 = "6bce4ef400e4efaa63a13d5e6f6b500be969ef81";
    const server_jar = downloadFile(b, server_url, "minecraft-server-1.21.8.jar");

    const verifier = b.addExecutable(.{
        .name = "verify_minecraft_jar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/verify_jar.zig"),
            .target = b.graph.host,
        }),
    });
    const verify = b.addRunArtifact(verifier);
    verify.addFileArg(server_jar);
    verify.addArg(server_sha1);
    _ = verify.addOutputFileArg("verified");

    const runtime_directory = createDirectory(b, "minecraft-runtime");
    const reports_command = b.addSystemCommand(&.{ "java", "-DbundlerMainClass=net.minecraft.data.Main", "-jar" });
    reports_command.addFileArg(server_jar);
    reports_command.addArgs(&.{ "--reports", "--output" });
    const reports = reports_command.addOutputDirectoryArg("minecraft-reports");
    reports_command.setCwd(runtime_directory);
    reports_command.step.dependOn(&verify.step);

    const inner_jar = runtime_directory.path(
        b,
        "versions/1.21.8/server-1.21.8.jar",
    );
    const extracted = extractMinecraftData(b, inner_jar, "minecraft-data", &reports_command.step);
    const minecraft = extracted.path(b, "data/minecraft");
    return .{
        .worldgen = minecraft.path(b, "worldgen"),
        .structures = minecraft.path(b, "structure"),
        .template_pools = minecraft.path(b, "worldgen/template_pool"),
        .processors = minecraft.path(b, "worldgen/processor_list"),
        .reports = reports.path(b, "reports"),
    };
}

fn downloadFile(b: *std.Build, url: []const u8, name: []const u8) std.Build.LazyPath {
    const executable = b.addExecutable(.{
        .name = "worldgen_download",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/download.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    command.addArg(url);
    return command.addOutputFileArg(name);
}

fn createDirectory(b: *std.Build, name: []const u8) std.Build.LazyPath {
    const executable = b.addExecutable(.{
        .name = "worldgen_create_directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/create_directory.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    return command.addOutputDirectoryArg(name);
}

fn extractMinecraftData(
    b: *std.Build,
    jar: std.Build.LazyPath,
    name: []const u8,
    dependency: *std.Build.Step,
) std.Build.LazyPath {
    const executable = b.addExecutable(.{
        .name = "worldgen_extract_minecraft_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/extract_minecraft_data.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const command = b.addRunArtifact(executable);
    command.addFileArg(jar);
    command.step.dependOn(dependency);
    return command.addOutputDirectoryArg(name);
}

fn addSeedFinder(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
) void {
    const search = b.option([]const u8, "search", "Seed search: tall-cactus or quad-witch-hut") orelse
        "tall-cactus";
    if (!std.mem.eql(u8, search, "tall-cactus") and
        !std.mem.eql(u8, search, "quad-witch-hut"))
    {
        std.debug.panic("unknown seed search '{s}'", .{search});
    }
    const options = b.addOptions();
    options.addOption([]const u8, "mode", search);
    const executable = b.addExecutable(.{
        .name = "vanilla_seed_finder",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/seed-finder/src/main.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
            .imports = &.{
                .{ .name = "vanilla_worldgen", .module = module },
                .{ .name = "search_options", .module = options.createModule() },
            },
        }),
    });
    executable.use_llvm = true;
    executable.use_lld = true;
    const run = b.addRunArtifact(executable);
    if (b.args) |arguments| run.addArgs(arguments);
    b.step("seed-finder", "Run the parallel Vanilla seed finder")
        .dependOn(&run.step);
}
