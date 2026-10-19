const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const metrics = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics");
    const records = b.dependency("records", .{ .target = target, .optimize = optimize });
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });

    const module = b.addModule("chunks", .{
        .root_source_file = b.path("src/chunks.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "metrics", .module = metrics },
            .{ .name = "records", .module = records.module("records") },
            .{ .name = "storage", .module = storage.module("storage") },
        },
    });
    const test_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| test_module.addImport(name, dependency);
    test_module.addImport("fault_disk", b.createModule(.{ .root_source_file = storage.path("src/fault_disk.zig"), .target = target, .optimize = optimize }));
    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = test_module, .filters = if (filter) |value| &.{value} else &.{} });
    b.step("test", "Verify section encoding, incremental writes, and recovery").dependOn(&b.addRunArtifact(tests).step);
}
