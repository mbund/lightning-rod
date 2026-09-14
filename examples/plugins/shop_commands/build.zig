const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shop = b.dependency("shop", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const module = b.addModule("shop_commands", .{
        .root_source_file = b.path("src/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "shop", .module = shop.module("shop") }, .{
            .name = "vanilla",
            .module = vanilla.module("lightning_rod_vanilla_1_21_6"),
        } },
    });
    const check = b.addLibrary(.{ .name = "shop_commands", .root_module = module });
    b.step("check", "Check the command module").dependOn(&check.step);
}
