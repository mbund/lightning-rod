const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("players", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    inline for (.{ "lightning_rod", "minecraft_model", "minecraft_packets", "records", "sessions", "worlds" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_26_2", b.dependency("protocol_26_2", .{ .target = target, .optimize = optimize }).module("wire"));

    // Standalone development selects every supported release, as a server does by default,
    // so encodings that differ between releases are always compiled and tested. Consumers
    // supply their own selection.
    if (b.dep_prefix.len == 0) {
        const single = b.option(bool, "single-release", "Select only the gameplay baseline release, the smallest catalog a server can run") orelse false;
        const releases = b.option([]const u8, "releases", "Comma-separated protocol releases, every supported one by default") orelse if (single) game_data.minecraft_version else "";
        const selected = if (releases.len == 0)
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize })
        else
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
        if (selected) |protocols| b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    }

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify player lifecycle, movement, input and spatial indexes");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // EXTRAS
}
