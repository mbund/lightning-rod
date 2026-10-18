const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("networking", .{ .root_source_file = b.path("src/networking.zig") });
    _ = b.addModule("networking_test", .{ .root_source_file = b.path("src/testing.zig"), .imports = &.{.{ .name = "networking", .module = module }} });
}
