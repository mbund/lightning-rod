const e2e = @import("e2e");
const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const operators = bootstrap.aliceOperator();
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = .survival }),
            lr.plugin.configured(vanilla.Operators, vanilla.Operators.Configuration{ .operators = &operators }),
        }),
        lr.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
    });
    try bootstrap.run(init, plugins, .{});
}
