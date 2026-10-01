const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const networking = b.dependency("networking", .{}).module("networking");
    const module = b.addModule("sessions", .{
        .root_source_file = b.path("src/sessions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "metrics", .module = metrics }, .{ .name = "networking", .module = networking } },
    });
    const check = b.addLibrary(.{ .name = "sessions", .root_module = module });
    b.step("check", "Check the Sessions module").dependOn(&check.step);
}
