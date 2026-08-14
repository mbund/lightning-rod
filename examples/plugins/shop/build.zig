const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const economy = b.dependency("economy", .{ .target = target, .optimize = optimize });
    const shop = b.addModule("shop", .{
        .root_source_file = b.path("src/shop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "economy", .module = economy.module("economy") },
        },
    });
    if (b.option(bool, "standalone-tests", "Build plugin tests with Lightning Rod") orelse false) {
        const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
        const library = lightning_rod.module("lightning_rod");
        economy.module("economy").addImport("lightning_rod", library);
        shop.addImport("lightning_rod", library);
        b.step("test", "Run Shop plugin tests")
            .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = shop })).step);
    }
}
