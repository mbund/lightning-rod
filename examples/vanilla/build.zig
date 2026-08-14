const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{
        .target = target,
        .optimize = optimize,
        .@"max-players" = b.option(usize, "max-players", "Maximum player capacity") orelse 64,
        .@"status-reserve" = 16,
        .@"view-distance" = 32,
        .@"simulation-distance" = 32,
        .@"random-tick-speed" = 3,
        .@"output-buffers" = 512,
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

    const library = lightning_rod.module("lightning_rod");
    const vanilla = b.createModule(.{
        .root_source_file = lightning_rod.path("src/vanilla_module.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = library }},
    });
    const reload_test_support = lightning_rod.module("lightning_rod_reload_test_support");
    const executable = b.addExecutable(.{
        .name = "lightning_rod",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = library },
                .{ .name = "vanilla", .module = vanilla },
            },
        }),
    });
    b.installArtifact(executable);

    const tick_module = b.addLibrary(.{
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
                .{ .name = "vanilla", .module = vanilla },
            },
        }),
    });
    const install_tick = b.addInstallArtifact(tick_module, .{});
    b.getInstallStep().dependOn(&install_tick.step);
    b.step("tick-module", "Build the Vanilla tick module").dependOn(&install_tick.step);

    const reject_module = b.addLibrary(.{
        .name = "lightning_rod_reject_tick",
        .linkage = .dynamic,
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = lightning_rod.path("tests/reject_tick_module.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lightning_rod", .module = library }},
        }),
    });
    const install_reject = b.addInstallArtifact(reject_module, .{});
    const worker_module = b.addLibrary(.{
        .name = "lightning_rod_worker_tick",
        .linkage = .dynamic,
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = lightning_rod.path("tests/worker_tick_module.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lightning_rod", .module = library }},
        }),
    });
    const install_worker = b.addInstallArtifact(worker_module, .{});
    const reload_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = lightning_rod.path("tests/hot_reload_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = library },
                .{ .name = "reload_test_support", .module = reload_test_support },
            },
        }),
    });
    const run_reload_test = b.addRunArtifact(reload_test);
    run_reload_test.setCwd(b.path("."));
    run_reload_test.step.dependOn(&install_tick.step);
    run_reload_test.step.dependOn(&install_reject.step);
    run_reload_test.step.dependOn(&install_worker.step);
    b.step("test", "Run the Vanilla server and reload tests").dependOn(&run_reload_test.step);

    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Vanilla server").dependOn(&run.step);
}
