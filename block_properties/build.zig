const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("block_properties", .{ .root_source_file = b.path("src/block_properties.zig"), .target = target, .optimize = optimize });
    module.addImport("lighting", b.dependency("lighting", .{ .target = target, .optimize = optimize }).module("lighting"));
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify block property listeners and entity types").dependOn(&b.addRunArtifact(tests).step);
}
