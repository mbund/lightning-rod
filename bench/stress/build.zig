const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize });
    const vanilla = b.dependency("vanilla", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6");
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize }).module("protocols");
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols);
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .error_tracing = true });
    inline for (.{ "connection", "inventories", "players", "replication", "terrain" }) |name|
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("vanilla", vanilla);
    module.addImport("protocols", protocols);
    module.addImport("lightning_rod", core.module("lightning_rod"));
    inline for (.{ "sessions", "host", "tps" }) |name| module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(name));
    module.addImport("minecraft_java", b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).module("minecraft_java"));
    module.addImport("game_data", vanilla.import_table.get("game_data").?);
    module.addImport("chunks", vanilla.import_table.get("chunks").?);
    const executable = b.addExecutable(.{ .name = "stress-bench", .root_module = module });
    module.addObjectFile(core.namedLazyPath("runtime"));
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("bench", "Stress the production components with real protocol clients and report memory occupancy").dependOn(&run.step);
}
