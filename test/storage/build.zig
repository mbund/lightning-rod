const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const storage = b.dependency("storage", .{ .target = target, .optimize = optimize });
    const tests = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize });
    for ([_][]const u8{ "storage", "records", "chunks", "inventories", "metrics" }) |name| {
        tests.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    }
    tests.addImport("fault_disk", b.createModule(.{ .root_source_file = storage.path("src/fault_disk.zig"), .target = target, .optimize = optimize }));
    tests.addImport("storage_testing", b.createModule(.{ .root_source_file = storage.path("src/testing.zig"), .target = target, .optimize = optimize }));
    const options = b.addOptions();
    options.addOption(usize, "rounds", b.option(usize, "rounds", "Mixed workload rounds per backend") orelse 64);
    tests.addOptions("options", options);
    const filter = b.option([]const u8, "test-filter", "Run matching mixed storage tests");
    const artifact = b.addTest(.{ .root_module = tests, .filters = if (filter) |value| &.{value} else &.{} });
    b.step("test", "Verify atomic saves across chunk and inventory plugins").dependOn(&b.addRunArtifact(artifact).step);
}
