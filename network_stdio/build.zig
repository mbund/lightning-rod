const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const networking = b.dependency("networking", .{}).module("networking");
    _ = b.addModule("network_stdio", .{
        .root_source_file = b.path("src/network.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "networking", .module = networking }},
    });
}
