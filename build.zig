const std = @import("std");
const protocol_graph = @import("build/protocol_graph.zig");
const test_steps = @import("build/test_steps.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nbt_dependency = b.dependency("nbt", .{ .target = target, .optimize = optimize });
    const nbt = nbt_dependency.module("nbt");
    const minecraft_registry = b.dependency("minecraft_registry", .{
        .target = target,
        .optimize = optimize,
    }).module("minecraft_registry");
    const protocols = protocol_graph.add(b, target, optimize, nbt, "1.21.6", "protocol");
    const preallocated = b.createModule(.{
        .root_source_file = b.path("src/preallocated.zig"),
        .target = target,
        .optimize = optimize,
    });
    const imports = [_]std.Build.Module.Import{
        .{ .name = "protocol", .module = protocols.wire },
        .{ .name = "protocol_catalog", .module = protocols.catalog },
        .{ .name = "protocol_support", .module = protocols.support },
        .{ .name = "nbt", .module = protocols.nbt },
        .{ .name = "minecraft_registry", .module = minecraft_registry },
        .{ .name = "registry_data", .module = protocols.registry },
        .{ .name = "preallocated", .module = preallocated },
    };
    const library = b.addModule("lightning_rod", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    const integration = b.createModule(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });
    test_steps.add(b, target, optimize, library, integration, protocols);
}
