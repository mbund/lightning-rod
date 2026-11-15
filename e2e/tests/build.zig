//! This repository's e2e tests. Each subdirectory is a test with its own build. Run one with
//! zig build e2e inside it, or any scenario from here with zig build e2e -Dscenario=NAME.

const std = @import("std");
const e2e = @import("lightning_rod_e2e");

pub fn build(b: *std.Build) void {
    e2e.addSuite(b, .{});
}
