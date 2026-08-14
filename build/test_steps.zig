const std = @import("std");
const protocol_graph = @import("protocol_graph.zig");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: *std.Build.Module,
    vanilla: *std.Build.Module,
    protocols: protocol_graph.Result,
    worldgen: *std.Build.Module,
) void {
    const all = b.step("test", "Run the bounded unit suite");
    const filter = b.option([]const u8, "test-filter", "Run unit tests whose names contain this text");
    const filters: []const []const u8 = if (filter) |value| &.{value} else &.{};
    all.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = library, .filters = filters })).step);
    all.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vanilla, .filters = filters })).step);
    all.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = protocols.support, .filters = filters })).step);

    const worldgen_tests = b.addTest(.{ .root_module = worldgen });
    worldgen_tests.use_llvm = true;
    worldgen_tests.use_lld = true;
    const run_worldgen = b.addRunArtifact(worldgen_tests);
    b.step("test-worldgen", "Run Vanilla world-generation parity tests").dependOn(&run_worldgen.step);

    const worldgen_benchmark = b.addExecutable(.{
        .name = "lightning_rod_worldgen_benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/worldgen_benchmark.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lightning_rod", .module = library }},
        }),
    });
    worldgen_benchmark.use_llvm = true;
    worldgen_benchmark.use_lld = true;
    b.step("benchmark-worldgen", "Profile Vanilla chunk-generation stages")
        .dependOn(&b.addRunArtifact(worldgen_benchmark).step);

    addFuzz(b, target, optimize, protocols, "fuzz-raw", "src/fuzz_raw.zig");
    addFuzz(b, target, optimize, protocols, "fuzz-valid", "src/fuzz_valid.zig");
}

fn addFuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    protocols: protocol_graph.Result,
    name: []const u8,
    source: []const u8,
) void {
    const root = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocols.wire },
            .{ .name = "protocol_support", .module = protocols.support },
        },
    });
    b.step(name, "Run bounded protocol fuzzing")
        .dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
}
