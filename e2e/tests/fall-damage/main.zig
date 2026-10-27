const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival, .spawn = .{ .x = 0.5, .y = 73, .z = 0.5 } }),
    });
    try e2e.profile.run(init, plugins, .{});
}
