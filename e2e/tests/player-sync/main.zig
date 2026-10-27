const e2e = @import("e2e");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const plugins = e2e.profile.plugins();
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}
