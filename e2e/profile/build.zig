const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const single_threaded = b.option(bool, "single-threaded", "Use the embedded profile") orelse false;
    const profile = if (single_threaded)
        b.dependency("embedded", .{ .target = target, .optimize = optimize }).module("lightning_rod_embedded")
    else
        b.dependency("linux", .{ .target = target, .optimize = optimize }).module("lightning_rod_linux");
    const core = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    _ = b.addModule("e2e_profile", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "profile", .module = profile },
            .{ .name = "lightning_rod", .module = core.module("lightning_rod") },
        },
    });
}
