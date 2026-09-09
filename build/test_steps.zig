const std = @import("std");
const protocol_graph = @import("protocol_graph.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    integration: *std.Build.Module,
    protocols: protocol_graph.Result,
) void {
    const all = b.step("test", "Run the fast deterministic unit suite");
    const filter = b.option([]const u8, "test-filter", "Run unit tests whose names contain this text");
    const filters: []const []const u8 = if (filter) |value| &.{value} else &.{};
    const unit = addOwnedTest(b, library, filters);
    all.dependOn(&b.addRunArtifact(unit).step);
    all.dependOn(&b.addRunArtifact(addOwnedTest(b, protocols.support, filters)).step);

    const integration_tests = addOwnedTest(b, integration, filters);
    const integration_step = b.step("test-integration", "Run bounded core integration tests");
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    const fuzz = b.step("fuzz", "Fuzz raw and structurally valid protocol input");
    fuzz.dependOn(addFuzz(b, target, optimize, protocols, "fuzz-raw", "Fuzz arbitrary network bytes", "src/fuzz_raw.zig"));
    fuzz.dependOn(addFuzz(b, target, optimize, protocols, "fuzz-valid", "Fuzz generated valid gameplay packets", "src/fuzz_valid.zig"));
}

fn addOwnedTest(
    b: *std.Build,
    root: *std.Build.Module,
    filters: []const []const u8,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = root,
        .filters = filters,
        .test_runner = .{
            .path = b.dependency("lightning_rod_test_runner", .{}).path("src/main.zig"),
            .mode = .simple,
        },
    });
}

fn addFuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    protocols: protocol_graph.Result,
    name: []const u8,
    description: []const u8,
    source: []const u8,
) *std.Build.Step {
    const root = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocols.wire },
            .{ .name = "protocol_support", .module = protocols.support },
        },
    });
    const step = b.step(name, description);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    return step;
}
