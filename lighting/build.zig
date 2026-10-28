const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("lighting", .{ .root_source_file = b.path("src/lighting.zig"), .target = target, .optimize = optimize });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify bounded light propagation and SIMD packing").dependOn(&b.addRunArtifact(tests).step);
}
