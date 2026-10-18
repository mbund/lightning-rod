const e2e = @import("e2e");
const std = @import("std");
const lr = @import("lightning_rod");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const plugins = lr.plugin.compose(.{
        bootstrap.plugins(),
        lr.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
    });
    try bootstrap.run(init, plugins, .{});
}
