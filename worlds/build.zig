const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    _ = b.addModule("worlds", .{
        .root_source_file = b.path("src/worlds.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "storage", .module = storage.module("storage") }},
    });
}
