const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Players = @import("players").players.Players;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 2 }),
    });
    try e2e.profile.run(init, plugins, .{ .plaintext = true });
}
