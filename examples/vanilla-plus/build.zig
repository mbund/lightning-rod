const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = lightningRod(b, target, optimize);
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const shop = b.dependency("shop", .{ .target = target, .optimize = optimize });
    const library = lightning_rod.module("lightning_rod");
    const vanilla = b.createModule(.{
        .root_source_file = lightning_rod.path("src/vanilla_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = library }},
    });
    economy.module("economy").addImport("lightning_rod", library);
    shop.module("shop").addImport("lightning_rod", library);
    const profile = addProfile(b, target, optimize, library, vanilla, economy, shop);
    const tick_library = addTickModule(b, target, optimize, library, profile);
    const executable = addServer(b, target, optimize, library, profile);
    const install_tick_library = b.addInstallArtifact(tick_library, .{});
    b.getInstallStep().dependOn(&install_tick_library.step);
    b.installArtifact(executable);
    b.step("tick-module", "Build and install the Vanilla+ tick module")
        .dependOn(&install_tick_library.step);
    const tests = b.step("test", "Build and test the Vanilla+ composition");
    const run_profile_tests = b.addRunArtifact(b.addTest(.{ .root_module = profile }));
    tests.dependOn(&run_profile_tests.step);
    const reload_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reload_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "reload_test_support",
                .module = lightning_rod.module("lightning_rod_reload_test_support"),
            }},
        }),
    });
    const run_reload_test = b.addRunArtifact(reload_test);
    run_reload_test.setCwd(b.path("."));
    run_reload_test.step.dependOn(&install_tick_library.step);
    run_reload_test.step.dependOn(&run_profile_tests.step);
    tests.dependOn(&run_reload_test.step);
    b.step("test-reload", "Run the disk-backed Vanilla+ reload test")
        .dependOn(&run_reload_test.step);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Vanilla+ server").dependOn(&run.step);
}

fn lightningRod(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Dependency {
    return b.dependency("lightning_rod", .{
        .target = target,
        .optimize = optimize,
        .@"max-players" = b.option(usize, "max-players", "Maximum player capacity") orelse 64,
        .@"status-reserve" = 16,
        .@"view-distance" = 32,
        .@"simulation-distance" = 32,
        .@"random-tick-speed" = 3,
        .@"living-entities" = 4096,
        .@"path-search-nodes" = 4096,
        .@"path-nodes" = 128,
        .@"modified-sections" = 4096,
        .@"checkpoint-ticks" = 20 * 60 * 5,
        .port = 25565,
        .@"memory-guards" = b.option(bool, "memory-guards", "Protect expired tick memory") orelse false,
        .@"tick-virtual-bytes" = 8 * 1024 * 1024 * 1024 * 1024,
        .@"tick-module-path" = "zig-out/lib/liblightning_rod_tick.so",
        .@"reload-virtual-bytes" = 1024 * 1024 * 1024 * 1024,
        .@"tick-state-bytes" = 2 * 1024 * 1024 * 1024,
    });
}

fn addProfile(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    vanilla: *std.Build.Module,
    economy: *std.Build.Dependency,
    shop: *std.Build.Dependency,
) *std.Build.Module {
    return b.addModule("vanilla_plus_profile", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "vanilla", .module = vanilla },
            .{ .name = "economy", .module = economy.module("economy") },
            .{ .name = "shop", .module = shop.module("shop") },
        },
    });
}

fn addTickModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, library: *std.Build.Module, profile: *std.Build.Module) *std.Build.Step.Compile {
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
                .{ .name = "vanilla_plus_profile", .module = profile },
            },
        }),
    });
}

fn addServer(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, library: *std.Build.Module, profile: *std.Build.Module) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "lightning_rod",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = library },
                .{ .name = "vanilla_plus_profile", .module = profile },
            },
        }),
    });
}
