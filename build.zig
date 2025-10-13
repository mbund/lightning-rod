const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const minecraft_data = b.dependency("minecraft_data", .{});

    const codegen_exe = b.addExecutable(.{
        .name = "codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codegen/codegen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const codegen_cmd = b.addRunArtifact(codegen_exe);
    codegen_cmd.addFileArg(minecraft_data.path("data/pc/1.21.8/protocol.json"));
    const protocol_zig_file = codegen_cmd.addOutputFileArg("protocol.zig");

    const protocol_module = b.createModule(.{
        .root_source_file = protocol_zig_file,
    });

    protocol_module.addAnonymousImport("protocol_support", .{
        .root_source_file = b.path("codegen/protocol_support.zig"),
    });

    const mod = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("protocol", protocol_module);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
