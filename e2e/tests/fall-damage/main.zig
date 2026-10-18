const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = @import("e2e").server;

pub fn main(init: std.process.Init) !void {
    const plugins = lr.plugin.replace(bootstrap.plugins(), .{
        lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 73, .z = 0.5 } }),
    });
    try bootstrap.run(init, plugins, .{});
}
