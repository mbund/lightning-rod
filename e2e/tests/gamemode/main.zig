const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const Operators = @import("commands").operators.Operators;
const Players = @import("players").players.Players;

pub fn main(init: std.process.Init) !void {
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(e2e.profile.plugins(), .{
            lightning_rod.plugin.configured(Players, Players.Configuration{ .render_distance = 2 }),
            lightning_rod.plugin.configured(vanilla.PlayerStates, .{ .gamemode = .survival }),
            lightning_rod.plugin.configured(Operators, Operators.Configuration{ .operators = &operators }),
        }),
        lightning_rod.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
    });
    try e2e.profile.run(init, plugins, .{});
}
