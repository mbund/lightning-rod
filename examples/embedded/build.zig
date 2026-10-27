const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const releases = b.option([]const u8, "releases", "Comma-separated supported Minecraft releases") orelse "";
    const protocols = if (releases.len == 0)
        b.dependency("protocols", .{ .target = target, .optimize = optimize })
    else
        b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    vanilla.module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    const executable = b.addExecutable(.{
        .name = "lightning_rod_embedded",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .imports = &.{
                .{ .name = "protocols", .module = protocols.module("protocols") },
                .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
                .{ .name = "profile", .module = b.dependency("embedded", .{ .target = target, .optimize = optimize }).module("lightning_rod_embedded") },
                .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
                .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
            },
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run all server services on one thread").dependOn(&run.step);
    b.addNamedLazyPath("server", executable.getEmittedBin());
}
