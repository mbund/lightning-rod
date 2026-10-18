const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("minecraft_model", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.step("check", "Check the Minecraft model").dependOn(&b.addLibrary(.{
        .name = "minecraft_model",
        .root_module = module,
    }).step);
}
