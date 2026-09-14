const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "storage", "records" };
    var imports: [names.len]std.Build.Module.Import = undefined;

    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = dependency.module(name) };
    }

    _ = b.addModule("economy", .{ .root_source_file = b.path("src/economy.zig"), .target = target, .optimize = optimize, .imports = &imports });
}
