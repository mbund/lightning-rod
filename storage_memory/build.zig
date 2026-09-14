const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize }).module("storage");
    _ = b.addModule("storage_memory", .{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "storage", .module = storage }},
    });
}
