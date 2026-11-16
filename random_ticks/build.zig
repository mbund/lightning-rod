const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const players = b.dependency("players", .{ .target = target, .optimize = optimize }).module("players");
    const module = b.addModule("random_ticks", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    module.addImport("domains", b.dependency("domains", .{ .target = target, .optimize = optimize }).module("domains"));
    module.addImport("chunks", b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks"));
    module.addImport("worlds", b.dependency("worlds", .{ .target = target, .optimize = optimize }).module("worlds"));

    // Standalone development selects every supported release, as a server does by default.
    // Consumers supply their own selection.
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
    tests.root_module.addImport("players", players);
    tests.root_module.addImport("records", b.dependency("records", .{ .target = target, .optimize = optimize }).module("records"));
    tests.root_module.addImport("storage", b.dependency("storage", .{ .target = target, .optimize = optimize }).module("storage"));
    tests.root_module.addImport("metrics", b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics"));
    b.step("test", "Verify random ticks").dependOn(&b.addRunArtifact(tests).step);
}
