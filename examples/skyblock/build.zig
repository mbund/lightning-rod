const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const linux = b.dependency("lightning_rod_linux", .{ .target = target, .optimize = optimize });
    const tui = b.dependency("lightning_rod_tui", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize });
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const worldguard = b.dependency("worldguard", .{ .target = target, .optimize = optimize });
    const library = lightning_rod.module("lightning_rod");
    const skyblock = b.addModule("skyblock", .{
        .root_source_file = b.path("src/skyblock.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "worldguard", .module = worldguard.module("worldguard") },
        },
    });
    const application = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lightning_rod", .module = library },
            .{ .name = "lightning_rod_linux", .module = linux.module("lightning_rod_linux") },
            .{ .name = "lightning_rod_tui", .module = tui.module("lightning_rod_tui") },
            .{ .name = "lightning_rod_vanilla_1_21_6", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
            .{ .name = "economy", .module = economy.module("economy") },
            .{ .name = "worldguard", .module = worldguard.module("worldguard") },
            .{ .name = "skyblock", .module = skyblock },
        },
    });
    const executable = b.addExecutable(.{ .name = "lightning_rod_skyblock", .root_module = application });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Skyblock server").dependOn(&run.step);
}
