const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("lighting", .{ .root_source_file = b.path("src/lighting.zig"), .target = target, .optimize = optimize });
    module.addImport("chunks", b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks"));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify bounded light propagation, SIMD packing and the light store").dependOn(&b.addRunArtifact(tests).step);
}
