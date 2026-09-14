const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "profiles", "network_uring" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = dependency.module(name) };
    }

    const module = b.addModule("lightning_rod_linux", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const check = b.addLibrary(.{ .name = "lightning_rod_linux", .root_module = module });
    b.step("check", "Check the Linux profile module").dependOn(&check.step);
}
