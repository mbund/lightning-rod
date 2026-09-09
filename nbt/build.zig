const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const module = b.addModule("nbt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = module,
        .filters = if (test_filter) |value| &.{value} else &.{},
        .test_runner = .{
            .path = b.dependency("lightning_rod_test_runner", .{}).path("src/main.zig"),
            .mode = .simple,
        },
    });
    b.step("test", "Run NBT tests").dependOn(&b.addRunArtifact(tests).step);
}
