const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const module = b.addModule("minecraft_packets", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sessions", .module = sessions.module("sessions") },
            .{ .name = "protocol_support", .module = b.dependency("protocol_support", .{ .target = target, .optimize = optimize }).module("encoding") },
        },
    });
    b.step("check", "Check the Minecraft packet plugin").dependOn(&b.addLibrary(.{
        .name = "minecraft_packets",
        .root_module = module,
    }).step);
}
