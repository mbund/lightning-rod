const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("reload", .{
        .root_source_file = b.path("src/reload.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
}
