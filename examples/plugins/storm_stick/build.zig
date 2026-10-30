const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const game_data = b.dependency("game_data", .{ .target = target, .optimize = optimize });
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize });
    const wire = b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize });
    const module = b.addModule("storm_stick", .{
        .root_source_file = b.path("src/storm_stick.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
            .{ .name = "game_data", .module = game_data.module("game_data") },
            .{ .name = "sessions", .module = sessions.module("sessions") },
            .{ .name = "wire_1_21_5", .module = wire.module("wire") },
        },
    });
    b.step("check", "Check Storm Calling stick enchantment").dependOn(&b.addLibrary(.{ .name = "storm_stick", .root_module = module }).step);
}
