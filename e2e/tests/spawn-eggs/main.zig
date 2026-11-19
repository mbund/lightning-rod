const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;

/// The example server's view: occlusion on, one ring past the view, the default distances.
pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Players, .{ .maximum = 1, .render_distance = 32, .simulation_distance = 8 }),
        lightning_rod.plugin.configured(Streaming, .{ .prefetch = 1, .hull = true }),
    });
    try e2e.profile.run(init, plugins, .{});
}
