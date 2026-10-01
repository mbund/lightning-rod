const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    _ = b.addModule("encoding", .{
        .root_source_file = b.path("src/support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = nbt.module("nbt") }},
    });
}
