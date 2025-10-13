const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

fn makeCodegen(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    const prog_node = options.progress_node;
    const b = step.owner;

    const c_source_path = translate_c.source.getPath2(b, step);
    try argv_list.append(c_source_path);

    const output_dir = try step.evalZigProcess(argv_list.items, prog_node, false, options.web_server, options.gpa);

    const basename = std.fs.path.stem(std.fs.path.basename(c_source_path));
    translate_c.out_basename = b.fmt("{s}.zig", .{basename});
    translate_c.output_file.path = output_dir.?.joinString(b.allocator, translate_c.out_basename) catch @panic("OOM");
}
