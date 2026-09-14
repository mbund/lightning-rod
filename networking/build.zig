const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("networking", .{ .root_source_file = b.path("src/networking.zig") });
}
