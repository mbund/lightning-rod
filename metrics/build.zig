const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("metrics", .{
        .root_source_file = b.path("src/metrics.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify instruments and bounded observation streams").dependOn(&b.addRunArtifact(tests).step);
}
