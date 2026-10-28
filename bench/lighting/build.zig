const std = @import("std");
const game_data = @import("game_data");
const registry_snapshotter = @import("registry_snapshotter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const client = b.option([]const u8, "client", "Prepared gameplay baseline Minecraft runtime bundle");
    const lighting = b.dependency("lighting", .{ .target = target, .optimize = optimize }).module("lighting");
    const prepare = b.addExecutable(.{ .name = "lighting-oracle", .root_module = b.createModule(.{ .root_source_file = b.path("src/prepare.zig"), .target = b.graph.host, .optimize = .Debug }) });
    const baseline = b.addOptions();
    baseline.addOption([]const u8, "version", game_data.minecraft_version);
    prepare.root_module.addOptions("baseline", baseline);
    const run_prepare = b.addRunArtifact(prepare);
    const snapshotter = b.dependency("registry_snapshotter", .{ .@"minecraft-version" = game_data.minecraft_version });
    const api = registry_snapshotter.apiForVersion(snapshotter.builder, game_data.minecraft_version);
    const adapter = if (std.mem.eql(u8, api, "modern")) "current" else api;
    run_prepare.addFileArg(b.path("java/LightingOracle.java"));
    run_prepare.addFileArg(b.path(b.fmt("java/{s}/OracleApi.java", .{adapter})));
    run_prepare.addArg(b.pathFromRoot(".zig-cache/oracle.bin"));
    _ = run_prepare.addOutputDirectoryArg("oracle-classes");
    run_prepare.has_side_effects = true;
    if (client) |path| run_prepare.addArg(path);
    b.step("oracle", "Capture vanilla light values using the prepared canonical Minecraft client").dependOn(&run_prepare.step);
    const benchmark = b.addExecutable(.{ .name = "lighting-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lighting", .module = lighting }},
    }) });
    const run = b.addRunArtifact(benchmark);
    b.installArtifact(benchmark);
    run.step.dependOn(&run_prepare.step);
    run.addArg(b.pathFromRoot(".zig-cache/oracle.bin"));
    b.step("bench", "Measure lighting and assert every center-column light value against vanilla").dependOn(&run.step);
}
