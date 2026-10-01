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
    const Backend = enum { uring, stdio };
    const backend: Backend = b.option(Backend, "io", "Networking implementation") orelse (if (target.result.os.tag == .linux) .uring else .stdio);
    const profile_name = if (backend == .uring) "lightning_rod_linux" else "lightning_rod_stdio";
    const profile = b.dependency(profile_name, .{ .target = target, .optimize = optimize });
    const tui = b.dependency("lightning_rod_tui", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize });
    vanilla.module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const shop = b.dependency("shop", .{ .target = target, .optimize = optimize });
    const economy_commands = b.dependency("economy_commands", .{ .target = target, .optimize = optimize });
    const shop_commands = b.dependency("shop_commands", .{ .target = target, .optimize = optimize });
    const executable = b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocols", .module = protocols.module("protocols") },
                .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
                .{ .name = "profile", .module = profile.module(profile_name) },
                .{ .name = "lightning_rod_tui", .module = tui.module("lightning_rod_tui") },
                .{ .name = "lightning_rod_vanilla_1_21_6", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
                .{ .name = "economy", .module = economy.module("economy") },
                .{ .name = "shop", .module = shop.module("shop") },
                .{ .name = "economy_commands", .module = economy_commands.module("economy_commands") },
                .{ .name = "shop_commands", .module = shop_commands.module("shop_commands") },
            },
        }),
    });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.setCwd(b.path("."));
    run.step.dependOn(b.getInstallStep());

    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Vanilla+ server").dependOn(&run.step);
}
