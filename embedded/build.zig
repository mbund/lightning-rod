const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "host", "reload", "lightning_rod", "sessions", "vanilla" };
    var imports: [names.len]std.Build.Module.Import = undefined;
    inline for (names, 0..) |name, index| {
        const dependency = b.dependency(name, .{ .target = target, .optimize = optimize });
        imports[index] = .{ .name = name, .module = dependency.module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name) };
    }
    const module = b.addModule("lightning_rod_embedded", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    module.addObjectFile(b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).namedLazyPath("runtime"));
    const check = b.addLibrary(.{ .name = "lightning_rod_embedded", .root_module = module });
    b.step("check", "Check the embedded profile module").dependOn(&check.step);
}
