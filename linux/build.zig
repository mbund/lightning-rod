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
    const test_filter = b.option([]const u8, "test-filter", "Run matching Linux tests");
    const tests = b.addTest(.{
        .filters = if (test_filter) |filter| &.{filter} else &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &imports,
        }),
    });
    b.step("test", "Run Linux host tests").dependOn(&b.addRunArtifact(tests).step);
    if (target.result.os.tag == .linux) {
        const persistence_benchmark = b.addExecutable(.{
            .name = "lightning_rod_persistence_benchmark",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/persistence_benchmark.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &imports,
            }),
        });
        const run_persistence_benchmark = b.addRunArtifact(persistence_benchmark);
        b.step("benchmark-persistence", "Profile batched local persistence reads")
            .dependOn(&run_persistence_benchmark.step);
    }
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
