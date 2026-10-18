const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "lightning_rod", "sessions", "vanilla" };
    var imports: [names.len]std.Build.Module.Import = undefined;
    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = dependency.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name) };
    }
    _ = b.addModule("e2e_control", .{
        .root_source_file = b.path("src/control.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
}
