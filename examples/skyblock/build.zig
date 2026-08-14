const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = dependency(b, target, optimize);
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const worldguard = b.dependency("worldguard", .{ .target = target, .optimize = optimize });
    const library = lightning_rod.module("lightning_rod");
    const vanilla = b.createModule(.{
        .root_source_file = lightning_rod.path("src/vanilla_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = library }},
    });
    economy.module("economy").addImport("lightning_rod", library);
    worldguard.module("worldguard").addImport("lightning_rod", library);
    const skyblock = b.addModule("skyblock", .{
        .root_source_file = b.path("src/skyblock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "worldguard", .module = worldguard.module("worldguard") },
        },
    });
    const profile = addProfile(b, target, optimize, library, vanilla, economy, worldguard, skyblock);
    const tick_module = addTickModule(b, target, optimize, library, profile);
    const executable = addServer(b, target, optimize, library, profile);
    const install_tick = b.addInstallArtifact(tick_module, .{});
    b.getInstallStep().dependOn(&install_tick.step);
    b.installArtifact(executable);
    b.step("tick-module", "Build and install the Skyblock tick module")
        .dependOn(&install_tick.step);
    const test_step = b.step("test", "Build and test Skyblock");
    const profile_tests = b.addTest(.{ .root_module = profile });
    const skyblock_tests = b.addTest(.{ .root_module = skyblock });
    test_step.dependOn(&b.addRunArtifact(profile_tests).step);
    test_step.dependOn(&b.addRunArtifact(skyblock_tests).step);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Skyblock server").dependOn(&run.step);
}

fn dependency(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Dependency {
    return b.dependency("lightning_rod", .{
        .target = target,
        .optimize = optimize,
        .@"max-players" = b.option(usize, "max-players", "Maximum player capacity") orelse 64,
        .@"max-worlds" = 512,
        .@"status-reserve" = 16,
        .@"view-distance" = 32,
        .@"simulation-distance" = 32,
        .@"random-tick-speed" = 3,
        .@"output-buffers" = 512,
        .@"living-entities" = 4_096,
        .@"path-search-nodes" = 4_096,
        .@"path-nodes" = 128,
        .@"modified-sections" = 4_096,
        .@"checkpoint-ticks" = 20 * 60 * 5,
        .port = 25_565,
        .@"memory-guards" = b.option(bool, "memory-guards", "Protect expired tick memory") orelse false,
        .@"tick-virtual-bytes" = 8 * 1_024 * 1_024 * 1_024 * 1_024,
        .@"tick-module-path" = "zig-out/lib/liblightning_rod_tick.so",
        .@"reload-virtual-bytes" = 1_024 * 1_024 * 1_024 * 1_024,
        .@"tick-state-bytes" = 2 * 1_024 * 1_024 * 1_024,
    });
}

fn addProfile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    vanilla: *std.Build.Module,
    economy: *std.Build.Dependency,
    worldguard: *std.Build.Dependency,
    skyblock: *std.Build.Module,
) *std.Build.Module {
    return b.addModule("skyblock_profile", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "vanilla", .module = vanilla },
            .{ .name = "economy", .module = economy.module("economy") },
            .{ .name = "worldguard", .module = worldguard.module("worldguard") },
            .{ .name = "skyblock", .module = skyblock },
        },
    });
}

fn addTickModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    profile: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = "lightning_rod_tick",
        .linkage = .dynamic,
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tick_module.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .error_tracing = false,
            .imports = &.{
                .{ .name = "lightning_rod", .module = library },
                .{ .name = "skyblock_profile", .module = profile },
            },
        }),
    });
}

fn addServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    profile: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "lightning_rod_skyblock",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = library },
                .{ .name = "skyblock_profile", .module = profile },
            },
        }),
    });
}
