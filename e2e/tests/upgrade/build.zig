const std = @import("std");
const e2e = @import("lightning_rod_e2e");

pub fn build(b: *std.Build) void {
    const test_build = e2e.addTest(b, .{});
    // The upgrade replaces the previous revision's vanilla server with this one in place.
    const server = b.dependency("vanilla_server", .{ .target = test_build.target, .optimize = test_build.optimize, .releases = test_build.releases });
    test_build.useServer(server.artifact("lightning_rod").getEmittedBin());
}
