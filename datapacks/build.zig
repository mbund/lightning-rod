const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("datapacks", .{
        .root_source_file = b.path("src/datapacks.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Verify content layering and resource ownership").dependOn(&tests.step);
}
