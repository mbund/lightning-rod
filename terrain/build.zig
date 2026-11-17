const std = @import("std");
const game_data = @import("game_data");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("terrain", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    inline for (.{ "block_properties", "chunks", "deflate", "game_data", "lighting", "lightning_rod", "metrics", "minecraft_java", "minecraft_packets", "occlusion", "players", "records", "sessions", "storage", "worlds", "zstandard" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("protocol_support", b.dependency("protocol_support", .{ .target = target, .optimize = optimize }).module("encoding"));
    module.addImport("wire_1_21_5", b.dependency("protocol_1_21_5", .{ .target = target, .optimize = optimize }).module("wire"));
    module.addImport("wire_26_1", b.dependency("protocol_26_1", .{ .target = target, .optimize = optimize }).module("wire"));

    // Standalone development selects every supported release, as a server does by default,
    // so encodings that differ between releases are always compiled and tested. Consumers
    // supply their own selection.
    if (b.dep_prefix.len == 0) {
        const single = b.option(bool, "single-release", "Select only the gameplay baseline release, the smallest catalog a server can run") orelse false;
        const releases = b.option([]const u8, "releases", "Comma-separated protocol releases, every supported one by default") orelse if (single) game_data.minecraft_version else "";
        const selected = if (releases.len == 0)
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize })
        else
            b.lazyDependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases });
        if (selected) |protocols| b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols.module("protocols"));
    }

    const filter = b.option([]const u8, "test-filter", "Run matching tests");
    const tests = b.addTest(.{ .root_module = module, .filters = if (filter) |value| &.{value} else &.{} });
    const test_step = b.step("test", "Verify lighting, chunk encoding, delivery and streaming");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const networking = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions").import_table.get("networking").?;
    const lighting_bench_module = b.createModule(.{ .root_source_file = b.path("src/lighting_bench.zig"), .target = target, .optimize = optimize });
    for (module.import_table.keys(), module.import_table.values()) |name, dependency| lighting_bench_module.addImport(name, dependency);
    lighting_bench_module.addImport("networking", networking);
    const lighting_bench = b.addTest(.{ .root_module = lighting_bench_module, .filters = if (filter) |value| &.{value} else &.{"lighting pipeline"} });
    const lighting_bench_run = std.Build.Step.Run.create(b, "lighting pipeline operations");
    lighting_bench_run.addArtifactArg(lighting_bench);
    test_step.dependOn(&lighting_bench_run.step);
    const lighting_load_module = b.createModule(.{ .root_source_file = b.path("src/lighting_load.zig"), .target = target, .optimize = optimize });
    for (lighting_bench_module.import_table.keys(), lighting_bench_module.import_table.values()) |name, dependency| lighting_load_module.addImport(name, dependency);
    const streaming_options = b.addOptions();
    streaming_options.addOption(usize, "radius", b.option(usize, "streaming-radius", "Render distance for the imported world benchmark") orelse 32);
    streaming_options.addOption(u2, "prefetch", b.option(u2, "streaming-prefetch", "Additional delivery distance beyond the measured render horizon") orelse 0);
    streaming_options.addOption(usize, "players", b.option(usize, "streaming-players", "Concurrent observers in the imported world benchmark") orelse 1);
    streaming_options.addOption([]const u8, "horizon_players", b.option([]const u8, "streaming-horizon-players", "Comma separated player counts for moving horizon comparisons") orelse "1,8,32");
    streaming_options.addOption(usize, "flight_ticks", b.option(usize, "streaming-flight-ticks", "Flight duration in ticks, zero measures initial loading only") orelse 600);
    streaming_options.addOption(usize, "spacing", b.option(usize, "streaming-spacing", "Chunk spacing between surface observers, zero shares the same source") orelse 0);
    streaming_options.addOption(bool, "encryption", b.option(bool, "streaming-encryption", "Encrypt each recipient's stream with the production cipher") orelse false);
    streaming_options.addOption(?[]const u8, "codec_workers", b.option([]const u8, "streaming-codec-workers", "Comma separated production codec worker counts, zero runs inline"));
    streaming_options.addOption(bool, "validate_output", b.option(bool, "streaming-validate-output", "Decode production output and compare final terrain between worker counts") orelse false);
    streaming_options.addOption(bool, "detailed_timers", b.option(bool, "streaming-detailed-timers", "Collect per-stage CPU timings instead of measuring normal production throughput") orelse false);
    streaming_options.addOption(bool, "stored_lighting", b.option(bool, "streaming-stored-lighting", "Use lighting baked into the chunk store") orelse true);
    streaming_options.addOption(?bool, "occlusion", b.option(bool, "streaming-occlusion", "Run only the selected occlusion mode"));
    streaming_options.addOption(?[]const u8, "corpus", b.option([]const u8, "streaming-corpus", "Export encoded packets and frames for isolated component benchmarks"));
    streaming_options.addOption(bool, "movement", b.option(bool, "streaming-movement", "Measure sustained flight after initial streaming") orelse false);
    streaming_options.addOption([]const u8, "flight_speeds", b.option([]const u8, "streaming-flight-speeds", "Comma separated flight speeds in blocks per second") orelse "80");
    streaming_options.addOption(bool, "flight_settle", b.option(bool, "streaming-flight-settle", "Complete every flight position for deterministic workload and bandwidth comparisons") orelse false);
    streaming_options.addOption(bool, "flight_straight", b.option(bool, "streaming-flight-straight", "Fly straight through fresh terrain instead of turning within each observer area") orelse false);
    streaming_options.addOption(bool, "lighting_comparison", b.option(bool, "streaming-lighting-comparison", "Compare fresh and retained lighting with identical encoded packets") orelse false);
    streaming_options.addOption(?[]const u8, "world", b.option([]const u8, "streaming-world", "Native world copy for the streaming benchmark"));
    streaming_options.addOption(?[]const u8, "position", b.option([]const u8, "streaming-position", "Observer feet as X,Y,Z instead of automatic surface and cave positions"));
    streaming_options.addOption(?[]const u8, "hidden", b.option([]const u8, "streaming-hidden", "Semicolon separated X,Y,Z block positions that must remain concealed"));
    lighting_load_module.addOptions("streaming_benchmark_options", streaming_options);
    const streaming_bench = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world streaming"} });
    const streaming_fixture = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world fixture"} }));
    b.step("verify-streaming-world", "Verify complete and distinct terrain for streaming observers").dependOn(&streaming_fixture.step);
    const movement_tests = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"streaming movement"} }));
    b.step("test-streaming-movement", "Verify moving observers while chunk delivery catches up").dependOn(&movement_tests.step);
    test_step.dependOn(&movement_tests.step);
    const cold_tests = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"cold lighting streams"} }));
    b.step("test-streaming-cold", "Verify cold lighting progress with separated observers and constrained caches").dependOn(&cold_tests.step);
    test_step.dependOn(&cold_tests.step);
    const edit_tests = b.addRunArtifact(b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"edited light"} }));
    b.step("test-streaming-edits", "Verify light updates after block edits against a client model").dependOn(&edit_tests.step);
    test_step.dependOn(&edit_tests.step);
    const streaming_run = std.Build.Step.Run.create(b, "imported world streaming");
    b.step("build-streaming", "Compile the imported world streaming benchmark").dependOn(&streaming_bench.step);
    streaming_run.addArtifactArg(streaming_bench);
    streaming_run.step.dependOn(&streaming_fixture.step);
    b.step("bench-streaming", "Measure real world chunk streaming without client rendering").dependOn(&streaming_run.step);
    const scaling_bench = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world player scaling"} });
    const scaling_run = std.Build.Step.Run.create(b, "imported world player scaling");
    scaling_run.addArtifactArg(scaling_bench);
    b.step("bench-streaming-scaling", "Measure shared and independent player streams with sealed allocation").dependOn(&scaling_run.step);
    const horizon_bench = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"imported world horizon scaling"} });
    b.step("build-horizon", "Compile the moving horizon benchmark").dependOn(&b.addInstallArtifact(horizon_bench, .{ .dest_sub_path = "chunk-horizon" }).step);
    const horizon_run = std.Build.Step.Run.create(b, "imported world moving horizons");
    horizon_run.addArtifactArg(horizon_bench);
    b.step("bench-streaming-horizon", "Measure moving horizons with compression encryption and immediately completed output").dependOn(&horizon_run.step);
    const lighting_load = b.addTest(.{ .root_module = lighting_load_module, .filters = &.{"lighting load"} });
    const lighting_load_run = std.Build.Step.Run.create(b, "lighting streaming load");
    lighting_load_run.addArtifactArg(lighting_load);
    const benchmark_lighting = b.step("bench-lighting", "Measure deterministic lighting pipeline operation counts");
    benchmark_lighting.dependOn(&lighting_bench_run.step);
    benchmark_lighting.dependOn(&lighting_load_run.step);
}
