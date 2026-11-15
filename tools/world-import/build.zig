const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    inline for (.{ "entities", "chunks", "anvil", "lightning_rod", "vanilla", "game_data", "records", "inventories", "nbt" }) |name| {
        module.addImport(name, b.dependency(name, .{ .target = target, .optimize = optimize }).module(if (std.mem.eql(u8, name, "vanilla")) "lightning_rod_vanilla_1_21_6" else name));
    }
    // The server accepts every supported release unless told otherwise, and a client whose
    // encoding was not prepared here makes each column compile on first delivery.
    const releases = b.option([]const u8, "releases", "Comma-separated Minecraft releases to prepare chunk delivery for (default: every supported release)") orelse "";
    const protocols = (if (releases.len == 0)
        b.dependency("protocols", .{ .target = target, .optimize = optimize })
    else
        b.dependency("protocols", .{ .target = target, .optimize = optimize, .releases = releases })).module("protocols");
    module.addImport("protocols", protocols);
    module.import_table.get("vanilla").?.addImport("protocols", protocols);
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols);
    const executable = b.addExecutable(.{ .name = "world-import", .root_module = module });
    b.installArtifact(executable);
    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Import a Java world into a new Lightning Rod database").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Verify world import and native persistence").dependOn(&b.addRunArtifact(tests).step);
}
