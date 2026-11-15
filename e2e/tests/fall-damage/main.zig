const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Players = @import("players").players.Players;

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Players, Players.Configuration{ .render_distance = 2, .spawn = .{ .x = 0.5, .y = 73, .z = 0.5 } }),
        lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }),
    });
    try e2e.profile.run(init, plugins, .{});
}
