const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize });
    const module = b.addModule("bossbars", .{ .root_source_file = b.path("src/bossbars.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
        .{ .name = "sessions", .module = sessions.module("sessions") },
        .{ .name = "protocols", .module = protocols.module("protocols") },
    } });
    b.step("check", "Check bossbars").dependOn(&b.addLibrary(.{ .name = "bossbars", .root_module = module }).step);
}
