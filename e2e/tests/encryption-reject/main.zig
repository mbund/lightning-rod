const std = @import("std");
const bootstrap = @import("e2e").server;

pub fn main(init: std.process.Init) !void {
    const plugins = bootstrap.plugins();
    try bootstrap.run(init, plugins, .{});
}
