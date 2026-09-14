const std = @import("std");
const generate = @import("build/generate.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nbt = b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt");
    const result = generate.add(b, target, optimize, nbt, "1.21.6", "protocol");
    const module = b.addModule("protocols", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wire", .module = result.wire },
            .{ .name = "catalog", .module = result.catalog },
            .{ .name = "registry", .module = result.registry },
            .{ .name = "support", .module = result.support },
            .{ .name = "nbt", .module = nbt },
        },
    });
    b.getInstallStep().dependOn(&b.addLibrary(.{ .name = "protocols", .root_module = module }).step);
}
