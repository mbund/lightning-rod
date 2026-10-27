const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });

    const names = .{ "storage", "reload", "reload_execve", "sessions" };
    var imports: [names.len + 1]std.Build.Module.Import = undefined;
    imports[0] = .{ .name = "lightning_rod", .module = core.module("lightning_rod") };
    inline for (names, 0..) |name, index| {
        imports[index + 1] = .{ .name = name, .module = b.dependency(name, .{ .target = target, .optimize = optimize }).module(name) };
    }

    const module = b.addModule("host", .{
        .root_source_file = b.path("src/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const check = b.addLibrary(.{ .name = "host", .root_module = module });
    b.step("check", "Check the host components").dependOn(&check.step);
}
