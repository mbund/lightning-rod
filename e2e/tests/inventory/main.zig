const e2e = @import("e2e");
const std = @import("std");
const lr = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const args = try bootstrap.arguments(init);
    const plugins = lr.plugin.compose(.{
        lr.plugin.replace(bootstrap.plugins(), .{
            lr.plugin.configured(vanilla.Players, vanilla.Players.Configuration{ .render_distance = 2, .gamemode = if (std.mem.eql(u8, args.fixture, "inventory_creative")) .creative else .survival }),
        }),
        lr.plugin.configured(e2e.Inventory, .{ .starting_bread = 17 }),
    });
    try bootstrap.run(init, plugins, .{});
}
