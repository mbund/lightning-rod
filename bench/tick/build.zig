const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const releases = b.option([]const u8, "releases", "Supported Minecraft releases") orelse "";
    const selection = if (releases.len == 0) b.dependency("protocols", .{ .target = target, .optimize = optimize }) else b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
    const protocols = selection.module("protocols");
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6");
    vanilla.addImport("protocols", protocols);
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols);
    const sessions = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions");
    const executable = b.addExecutable(.{
        .name = "tick-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
                .{ .name = "vanilla", .module = vanilla },
                .{ .name = "sessions", .module = sessions },
                .{ .name = "networking", .module = sessions.import_table.get("networking").? },
                .{ .name = "protocols", .module = protocols },
                .{ .name = "tps", .module = b.dependency("tps", .{ .target = target, .optimize = optimize }).module("tps") },
            },
        }),
    });
    executable.root_module.addObjectFile(b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).namedLazyPath("runtime"));
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("bench", "Measure vanilla simulation ticks across player counts and audiences").dependOn(&run.step);

    const foundation = b.addExecutable(.{
        .name = "foundation-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/foundation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lightning_rod", .module = executable.root_module.import_table.get("lightning_rod").? }},
        }),
    });
    foundation.root_module.addObjectFile(b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).namedLazyPath("runtime"));
    b.installArtifact(foundation);
    const run_foundation = b.addRunArtifact(foundation);
    if (b.args) |args| run_foundation.addArgs(args);
    b.step("bench-foundation", "Measure plugin dispatch, instrumentation, and idle storage overhead").dependOn(&run_foundation.step);
}
