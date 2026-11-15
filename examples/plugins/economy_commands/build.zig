const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const module = b.addModule("economy_commands", .{
        .root_source_file = b.path("src/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "economy", .module = economy.module("economy") }},
    });
    inline for (.{ "commands", "players" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    const check = b.addLibrary(.{ .name = "economy_commands", .root_module = module });
    b.step("check", "Check the command module").dependOn(&check.step);
}
