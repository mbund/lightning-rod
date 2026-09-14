const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "lightning_rod", "protocols", "minecraft", "sessions", "chunks", "entities", "inventories", "metrics", "records", "commands", "reload", "worlds" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, i| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[i] = .{ .name = name, .module = dependency.module(name) };
    }

    const module = b.addModule("lightning_rod_vanilla_1_21_6", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const check = b.addLibrary(.{ .name = "vanilla", .root_module = module });
    b.step("check", "Check the Vanilla module").dependOn(&check.step);
}
