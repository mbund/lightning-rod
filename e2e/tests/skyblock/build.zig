const std = @import("std");
const e2e = @import("lightning_rod_e2e");

pub fn build(b: *std.Build) void {
    const test_build = e2e.addTest(b, .{});
    // Skyblock builds its own server, so it selects the same protocols as this one.
    const skyblock = b.dependency("skyblock", .{ .target = test_build.target, .optimize = test_build.optimize, .releases = test_build.releases });
    _ = test_build.addServer(.{ .root_source_file = b.path("main.zig"), .imports = &.{.{ .name = "skyblock", .module = skyblock.module("skyblock") }} });
}
