const std = @import("std");
const e2e = @import("lightning_rod_e2e");

pub fn build(b: *std.Build) void {
    const test_build = e2e.addTest(b, .{});
    _ = test_build.addServer(.{ .root_source_file = b.path("main.zig") });
}
