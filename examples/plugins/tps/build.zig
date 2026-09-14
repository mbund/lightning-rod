const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const bossbars = b.dependency("bossbars", .{ .target = target, .optimize = optimize });
    const module = b.addModule("tps", .{ .root_source_file = b.path("src/tps.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "lightning_rod", .module = rod.module("lightning_rod") },
        .{ .name = "bossbars", .module = bossbars.module("bossbars") },
    } });
    b.step("check", "Check TPS display").dependOn(&b.addLibrary(.{ .name = "tps", .root_module = module }).step);
}
