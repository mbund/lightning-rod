const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("vanilla_content", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    inline for (.{ "block_properties", "chunks", "game_data", "lighting", "lightning_rod", "records", "storage", "worlds" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify vanilla identifiers, tags, registries and blocks");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // EXTRAS
}
