const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const game_data = b.dependency("game_data", .{ .target = target, .optimize = optimize });
    const module = b.addModule("silk_spawners", .{
        .root_source_file = b.path("src/silk_spawners.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
            .{ .name = "game_data", .module = game_data.module("game_data") },
        },
    });
    b.step("check", "Check Silk Touch spawner drops").dependOn(&b.addLibrary(.{ .name = "silk_spawners", .root_module = module }).step);
}
