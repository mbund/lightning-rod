const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const releases = b.option([]const u8, "releases", "Comma-separated supported Minecraft releases") orelse "";
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize });
    const records = b.dependency("records", .{ .target = target, .optimize = optimize }).module("records");
    vanilla.module("lightning_rod_vanilla_1_21_6").addImport("protocols", protocols.module("protocols"));
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    const executable = b.addExecutable(.{
        .name = "lightning_rod_skyblock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocols", .module = protocols.module("protocols") },
                .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
                .{ .name = "host", .module = b.dependency("host", .{ .target = target, .optimize = optimize }).module("host") },
                .{ .name = "reload", .module = b.dependency("reload", .{ .target = target, .optimize = optimize }).module("reload") },
                .{ .name = "reload_execve", .module = b.dependency("reload_execve", .{ .target = target, .optimize = optimize }).module("reload_execve") },
                .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
                .{ .name = "records", .module = records },
                .{ .name = "vanilla", .module = vanilla.module("lightning_rod_vanilla_1_21_6") },
                .{ .name = "wire_1_21_5", .module = vanilla.module("lightning_rod_vanilla_1_21_6").import_table.get("wire_1_21_5").? },
                .{ .name = "game_data", .module = vanilla.module("lightning_rod_vanilla_1_21_6").import_table.get("game_data").? },
                .{ .name = "chunks", .module = vanilla.module("lightning_rod_vanilla_1_21_6").import_table.get("chunks").? },
            },
        }),
    });
    executable.root_module.addObjectFile(b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).namedLazyPath("runtime"));
    const module = b.addModule("skyblock", .{ .root_source_file = b.path("src/skyblock.zig"), .target = target, .optimize = optimize });
    for (executable.root_module.import_table.keys(), executable.root_module.import_table.values()) |name, dependency|
        module.addImport(name, dependency);
    b.installArtifact(executable);
    const run = b.addSystemCommand(&.{b.getInstallPath(.bin, executable.out_filename)});
    run.step.dependOn(b.getInstallStep());
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run independent islands on a bounded worker pool").dependOn(&run.step);
    const integration = b.addExecutable(.{
        .name = "skyblock-reload-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
                .{ .name = "host", .module = b.dependency("host", .{ .target = target, .optimize = optimize }).module("host") },
                .{ .name = "records", .module = records },
                .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
                .{ .name = "game_data", .module = vanilla.module("lightning_rod_vanilla_1_21_6").import_table.get("game_data").? },
            },
        }),
    });
    const verify = b.addRunArtifact(integration);
    verify.addArtifactArg(executable);
    _ = verify.addOutputDirectoryArg("world");
    verify.has_side_effects = true;
    const tests = b.step("test", "Verify island commands, membership, and durable process replacement");
    tests.dependOn(&verify.step);
    const catalog_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/catalog_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
            .{ .name = "records", .module = records },
            .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
        },
    }) });
    tests.dependOn(&b.addRunArtifact(catalog_tests).step);
    const terrain_module = b.createModule(.{ .root_source_file = b.path("src/terrain.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        terrain_module.addImport(name, dependency);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = terrain_module })).step);
    const island_module = b.createModule(.{ .root_source_file = b.path("src/island_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        island_module.addImport(name, dependency);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = island_module })).step);
    const pipeline_module = b.createModule(.{ .root_source_file = b.path("src/pipeline_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        pipeline_module.addImport(name, dependency);
    const pipeline_bench = b.addTest(.{ .filters = &.{"operation counts"}, .root_module = pipeline_module });
    const run_pipeline = std.Build.Step.Run.create(b, "worker pipeline operations");
    run_pipeline.addArtifactArg(pipeline_bench);
    b.step("bench-pipeline", "Count worker pause requests before waiting without threads or timing").dependOn(&run_pipeline.step);
    const chat_module = b.createModule(.{ .root_source_file = b.path("src/global_chat_test.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency|
        chat_module.addImport(name, dependency);
    tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = chat_module })).step);
    b.addNamedLazyPath("server", executable.getEmittedBin());
}
