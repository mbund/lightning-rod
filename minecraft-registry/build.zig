const std = @import("std");
const minecraft_version = "1.21.8";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this text");
    const data = b.dependency("minecraft_data", .{});
    const generator = b.addExecutable(.{
        .name = "minecraft_registry_codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/codegen.zig"),
            .target = b.graph.host,
        }),
    });
    const command = b.addRunArtifact(generator);
    command.addFileArg(data.path("data/pc/" ++ minecraft_version ++ "/blocks.json"));
    command.addArg(minecraft_version);
    const generated = b.createModule(.{
        .root_source_file = command.addOutputFileArg("blocks_1_21_8.zig"),
        .target = target,
        .optimize = optimize,
    });
    const module = b.addModule("minecraft_registry", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "generated_blocks", .module = generated }},
    });
    const tests = b.addTest(.{
        .root_module = module,
        .filters = if (test_filter) |value| &.{value} else &.{},
        .test_runner = .{
            .path = b.dependency("lightning_rod_test_runner", .{}).path("src/main.zig"),
            .mode = .simple,
        },
    });
    b.step("test", "Run canonical Minecraft registry tests")
        .dependOn(&b.addRunArtifact(tests).step);
}
