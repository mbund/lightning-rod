const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const releases = b.option([]const u8, "releases", "Comma-separated supported Minecraft releases") orelse "";
    const protocols = if (releases.len == 0)
        b.dependency("protocols", .{ .target = target, .optimize = optimize })
    else
        b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const packets = b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize });
    packets.module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    const profile = b.dependency("lightning_rod_linux", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize });
    vanilla.module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    const executable = b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "minecraft_java", .module = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).module("minecraft_java") },
                .{ .name = "protocols", .module = protocols.module("protocols") },
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "profile", .module = profile.module("lightning_rod_linux") },
                .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
                .{ .name = "lightning_rod_vanilla_1_21_6", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
                .{ .name = "tps", .module = b.dependency("tps", .{ .target = target, .optimize = optimize }).module("tps") },
                .{ .name = "storm_stick", .module = b.dependency("storm_stick", .{ .target = target, .optimize = optimize }).module("storm_stick") },
                .{ .name = "inventories", .module = b.dependency("inventories", .{ .target = target, .optimize = optimize }).module("inventories") },
                .{ .name = "game_data", .module = b.dependency("game_data", .{ .target = target, .optimize = optimize }).module("game_data") },
            },
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunFile(b.graph.path(.install_bin, executable.out_filename));
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    run.addPassthruArgs();
    b.step("run", "Run the Vanilla server").dependOn(&run.step);

    b.addNamedLazyPath("server", executable.getEmittedBin());
}
