const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "lightning_rod", "sessions", "storage_local", "reload_execve", "reload" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = dependency.module(name) };
    }

    const module = b.addModule("profiles", .{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const check = b.addLibrary(.{ .name = "profiles", .root_module = module });
    b.step("check", "Check the profile module").dependOn(&check.step);
}
