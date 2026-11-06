const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("anvil", .{
        .root_source_file = b.path("src/anvil.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nbt", .module = b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt") }},
    });
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify Anvil decoding and block state mapping").dependOn(&b.addRunArtifact(tests).step);
}
