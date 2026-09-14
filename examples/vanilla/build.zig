const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const Backend = enum { uring, stdio };
    const backend: Backend = b.option(Backend, "io", "Networking implementation") orelse (if (target.result.os.tag == .linux) .uring else .stdio);
    const profile_name = if (backend == .uring) "lightning_rod_linux" else "lightning_rod_stdio";
    const profile = b.dependency(profile_name, .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize });
    const tui = b.dependency("lightning_rod_tui", .{ .target = target, .optimize = optimize });
    const bossbars = b.dependency("bossbars", .{ .target = target, .optimize = optimize });
    const tps = b.dependency("tps", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "profile", .module = profile.module(profile_name) },
                .{ .name = "lightning_rod_vanilla_1_21_6", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
                .{ .name = "lightning_rod_tui", .module = tui.module("lightning_rod_tui") },
                .{ .name = "bossbars", .module = bossbars.module("bossbars") },
                .{ .name = "tps", .module = tps.module("tps") },
            },
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Vanilla server").dependOn(&run.step);
}
