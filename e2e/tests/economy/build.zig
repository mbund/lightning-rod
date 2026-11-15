const std = @import("std");
const e2e = @import("lightning_rod_e2e");

pub fn build(b: *std.Build) void {
    const test_build = e2e.addTest(b, .{});
    _ = test_build.addServer(.{ .root_source_file = b.path("main.zig"), .imports = &.{
        test_build.import("economy"),
        test_build.import("economy_commands"),
        test_build.import("shop"),
        test_build.import("shop_commands"),
    } });
}
