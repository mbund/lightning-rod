const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("storage", .{ .root_source_file = b.path("src/storage.zig"), .target = target, .optimize = optimize });
}
