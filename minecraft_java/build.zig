const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const encoding = b.dependency("encoding", .{ .target = target, .optimize = optimize });
    const minecraft = b.dependency("minecraft_model", .{ .target = target, .optimize = optimize });
    const chunks = b.dependency("chunks", .{ .target = target, .optimize = optimize });
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const module = b.addModule("minecraft_java", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sessions", .module = sessions.module("sessions") },
            .{ .name = "chunks", .module = chunks.module("chunks") },
            .{ .name = "support", .module = encoding.module("encoding") },
            .{ .name = "minecraft_model", .module = minecraft.module("minecraft_model") },
        },
    });
    b.step("check", "Check Java protocol support").dependOn(&b.addLibrary(.{ .name = "minecraft_java", .root_module = module }).step);
}
