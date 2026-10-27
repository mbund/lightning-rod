const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        e2e.profile.plugins(),
        lightning_rod.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
    });
    try e2e.profile.run(init, plugins, .{});
}
