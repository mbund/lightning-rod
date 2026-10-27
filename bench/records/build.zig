const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const source = b.dependency("sqlite", .{});
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = source.path("sqlite3.c"),
        .flags = &.{ "-std=c99", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });
    const executable = b.addExecutable(.{
        .name = "records-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "records", .module = b.dependency("records", .{ .target = target, .optimize = optimize }).module("records") },
                .{ .name = "storage", .module = b.dependency("storage", .{ .target = target, .optimize = optimize }).module("storage") },
                .{ .name = "metrics", .module = b.dependency("metrics", .{ .target = target, .optimize = optimize }).module("metrics") },
            },
        }),
    });
    executable.root_module.addIncludePath(source.path(""));
    executable.root_module.linkLibrary(sqlite);
    const backend = b.addModule("sqlite", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for (executable.root_module.import_table.keys(), executable.root_module.import_table.values()) |name, module|
        backend.addImport(name, module);
    backend.addIncludePath(source.path(""));
    backend.linkLibrary(sqlite);
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("bench", "Compare record growth and churn against SQLite").dependOn(&run.step);
}
