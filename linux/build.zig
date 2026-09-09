const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const lightning_rod = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const tui = b.dependency("lightning_rod_tui", .{ .target = target, .optimize = optimize });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "lightning_rod", .module = lightning_rod.module("lightning_rod") },
        .{ .name = "lightning_rod_tui", .module = tui.module("lightning_rod_tui") },
    };
    _ = b.addModule("lightning_rod_linux", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    b.step("test", "Run Linux host tests").dependOn(&b.addRunArtifact(tests).step);
    if (target.result.os.tag == .linux) {
        const integration = b.addExecutable(.{
            .name = "lightning_rod_reexec_integration",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/reexec_integration.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &imports,
            }),
        });
        b.step("test-reexec", "Run Linux re-exec integration test")
            .dependOn(&b.addRunArtifact(integration).step);
    }
}
