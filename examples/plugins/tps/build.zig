const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const module = b.addModule("tps", .{ .root_source_file = b.path("src/tps.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
        .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
    } });
    b.step("check", "Check TPS display").dependOn(&b.addLibrary(.{ .name = "tps", .root_module = module }).step);
}
