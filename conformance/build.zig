const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod_dependency = b.dependency("lightning_rod", .{
        .target = target,
        .optimize = optimize,
        .@"max-players" = 8,
        .@"max-worlds" = 64,
        .@"status-reserve" = 4,
        .@"view-distance" = 8,
        .@"simulation-distance" = 8,
        .@"output-buffers" = 32,
        .@"living-entities" = 4096,
        .@"item-entities" = 1024,
        .@"path-search-nodes" = 1024,
        .@"modified-sections" = 256,
        .@"resident-chunks" = 512,
        .@"tick-state-bytes" = 512 * 1024 * 1024,
    });
    const lightning_rod = lightning_rod_dependency.module("lightning_rod");
    const vanilla = b.createModule(.{
        .root_source_file = lightning_rod_dependency.path("src/vanilla_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = lightning_rod }},
    });
    const nbt = lightning_rod_dependency.module("nbt");
    const protocol_catalog = lightning_rod_dependency.module("protocol_catalog");
    const canonical_spec = canonicalSpec(b, target, optimize);
    const mcc = b.addModule("minecraft_conformance", .{
        .root_source_file = b.path("src/minecraft_conformance/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "canonical_spec", .module = canonical_spec },
            .{ .name = "protocol_catalog", .module = protocol_catalog },
        },
    });
    const black_box = b.addModule("lightning_rod_black_box", .{
        .root_source_file = b.path("src/black_box.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = lightning_rod },
            .{ .name = "vanilla", .module = vanilla },
        },
    });
    const adapter = b.addModule("lightning_rod_adapter", .{
        .root_source_file = b.path("src/lightning_rod_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "black_box", .module = black_box },
            .{ .name = "lightning_rod", .module = lightning_rod },
            .{ .name = "minecraft_conformance", .module = mcc },
        },
    });
    const codec = b.addLibrary(.{
        .name = "minecraft_conformance_codec",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/minecraft_conformance/codec_exports.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nbt", .module = nbt },
                .{ .name = "canonical_spec", .module = canonical_spec },
                .{ .name = "protocol_catalog", .module = protocol_catalog },
            },
        }),
    });
    addTests(b, target, optimize, mcc, adapter, codec);
    addBenchmark(b, target, optimize, black_box);
    addVanillaCli(
        b,
        target,
        optimize,
        mcc,
        lightning_rod_dependency.module("worldgen"),
        codec,
    );
}

fn addVanillaCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mcc: *std.Build.Module,
    worldgen: *std.Build.Module,
    codec: *std.Build.Step.Compile,
) void {
    const vanilla_adapter = b.createModule(.{
        .root_source_file = b.path("src/vanilla_adapter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "minecraft_conformance", .module = mcc }},
    });
    const scenarios = b.createModule(.{
        .root_source_file = b.path("tests/scenarios.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "minecraft_conformance", .module = mcc }},
    });
    const executable = b.addExecutable(.{
        .name = "minecraft_vanilla_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vanilla_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minecraft_conformance", .module = mcc },
                .{ .name = "vanilla_conformance_adapter", .module = vanilla_adapter },
                .{ .name = "conformance_scenarios", .module = scenarios },
                .{ .name = "worldgen", .module = worldgen },
            },
        }),
    });
    executable.root_module.linkLibrary(codec);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("vanilla", "Run scenarios or worldgen queries against Vanilla")
        .dependOn(&run.step);
}

fn canonicalSpec(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const generator = b.addExecutable(.{
        .name = "canonical_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/canonical_codegen.zig"),
            .target = b.graph.host,
        }),
    });
    const command = b.addRunArtifact(generator);
    const source = command.addOutputFileArg("canonical_spec.zig");
    return b.addModule("canonical_spec", .{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
    });
}

fn addTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mcc: *std.Build.Module,
    adapter: *std.Build.Module,
    codec: *std.Build.Step.Compile,
) void {
    const adapter_suite = b.addExecutable(.{
        .name = "lightning_rod_conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/adapter_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minecraft_conformance", .module = mcc },
                .{ .name = "conformance_adapter", .module = adapter },
            },
        }),
    });
    adapter_suite.root_module.linkLibrary(codec);

    const coverage_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/coverage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "minecraft_conformance", .module = mcc }},
        }),
    });
    coverage_tests.root_module.linkLibrary(codec);

    const coverage_report = b.addExecutable(.{
        .name = "minecraft_conformance_coverage",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/coverage.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "minecraft_conformance", .module = mcc }},
        }),
    });
    coverage_report.root_module.linkLibrary(codec);
    b.step("coverage", "Print quantified Vanilla implementation coverage")
        .dependOn(&b.addRunArtifact(coverage_report).step);

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "mccore", .module = mcc }},
        }),
    });
    core_tests.root_module.linkLibrary(codec);

    const test_step = b.step("test", "Run the conformance core and Lightning Rod adapter tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    test_step.dependOn(&b.addRunArtifact(coverage_tests).step);
    test_step.dependOn(&b.addRunArtifact(adapter_suite).step);
}

fn addBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    black_box: *std.Build.Module,
) void {
    const benchmark = b.addExecutable(.{
        .name = "lightning_rod_conformance_benchmark",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
            .single_threaded = true,
            .imports = &.{.{ .name = "black_box", .module = black_box }},
        }),
    });
    b.step("benchmark", "Measure the in-process conformance target")
        .dependOn(&b.addRunArtifact(benchmark).step);
}
