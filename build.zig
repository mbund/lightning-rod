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

    const nbt_module = b.addModule("nbt", .{
        .root_source_file = b.path("src/nbt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol_support_module = b.addModule("protocol_support", .{
        .root_source_file = b.path("codegen/protocol_support.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nbt", .module = nbt_module },
        },
    });

    const protocol_module = b.addModule("protocol", .{
        .root_source_file = protocol_zig_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol_support", .module = protocol_support_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "lightning_rod",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nbt", .module = nbt_module },
                .{ .name = "protocol", .module = protocol_module },
                .{ .name = "protocol_support", .module = protocol_support_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const nbt_tests = b.addTest(.{
        .root_module = nbt_module,
    });

    const run_nbt_tests = b.addRunArtifact(nbt_tests);

    const protocol_support_tests = b.addTest(.{
        .root_module = protocol_support_module,
    });

    const run_protocol_support_tests = b.addRunArtifact(protocol_support_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_nbt_tests.step);
    test_step.dependOn(&run_protocol_support_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
