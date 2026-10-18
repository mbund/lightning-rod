const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dependency = b.dependency("networking", .{});
    const networking = dependency.module("networking");

    const module = b.addModule("network_stdio", .{
        .root_source_file = b.path("src/network.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "networking", .module = networking }, .{ .name = "networking_test", .module = dependency.module("networking_test") } },
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify socket handoff without peer progress").dependOn(&b.addRunArtifact(tests).step);
}
