const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize });
    const module = b.addModule("minecraft", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "protocols", .module = protocols.module("protocols") }},
    });
    const check = b.addLibrary(.{ .name = "minecraft", .root_module = module });
    b.step("check", "Check the Minecraft module").dependOn(&check.step);
}
