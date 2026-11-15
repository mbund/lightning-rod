const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const module = b.addModule("tps", .{ .root_source_file = b.path("src/tps.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
    } });
    inline for (.{"bossbars"}) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    b.step("check", "Check TPS display").dependOn(&b.addLibrary(.{ .name = "tps", .root_module = module }).step);
}
