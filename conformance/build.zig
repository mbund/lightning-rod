const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod_dependency = b.dependency("lightning_rod", .{
        .target = target,
        .optimize = optimize,
    });
    const lightning_rod = lightning_rod_dependency.module("lightning_rod");
    const vanilla = b.dependency("vanilla", .{
        .target = target,
        .optimize = optimize,
    }).module("lightning_rod_vanilla_1_21_6");
    const registry = b.dependency("minecraft_registry", .{
        .target = target,
        .optimize = optimize,
    }).module("minecraft_registry");
    const nbt = b.dependency("nbt", .{
        .target = target,
        .optimize = optimize,
    }).module("nbt");
    const canonical_spec = canonicalSpec(b, target, optimize);
    const mcc = b.addModule("minecraft_conformance", .{
        .root_source_file = b.path("src/minecraft_conformance/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "canonical_spec", .module = canonical_spec },
            .{ .name = "nbt", .module = nbt },
            .{ .name = "protocol_catalog", .module = lightning_rod_dependency.module("protocol_catalog") },
            .{ .name = "minecraft_registry", .module = registry },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod },
                .{ .name = "vanilla", .module = vanilla },
                .{ .name = "minecraft_conformance", .module = mcc },
            },
        }),
        .test_runner = .{
            .path = lightning_rod_dependency.path("test-runner/src/main.zig"),
            .mode = .simple,
        },
    });
    const test_step = b.step("test", "Run Minecraft conformance suites through the Lightning Rod adapter");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const gameplay_fuzz = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_gameplay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod },
                .{ .name = "vanilla", .module = vanilla },
            },
        }),
    });
    b.step("fuzz-gameplay", "Fuzz raw and generated-valid Vanilla Play input")
        .dependOn(&b.addRunArtifact(gameplay_fuzz).step);

    const compare = b.addExecutable(.{
        .name = "lightning-rod-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/external_cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "minecraft_conformance", .module = mcc }},
        }),
    });
    const run_compare = b.addRunArtifact(compare);
    if (b.args) |args| run_compare.addArgs(args);
    b.step("external", "Compare canonical Vanilla/Fabric capture artifacts")
        .dependOn(&run_compare.step);
    b.step("external-check", "Compile the external capture comparison CLI")
        .dependOn(&compare.step);
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
    return b.addModule("canonical_spec", .{
        .root_source_file = command.addOutputFileArg("canonical_spec.zig"),
        .target = target,
        .optimize = optimize,
    });
}
