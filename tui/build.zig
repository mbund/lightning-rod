const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const module = b.addModule("lightning_rod_tui", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run TUI plugin tests").dependOn(&b.addRunArtifact(tests).step);
}
