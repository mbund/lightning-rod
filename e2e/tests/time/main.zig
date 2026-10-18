const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");
const bootstrap = e2e.server;

pub fn main(init: std.process.Init) !void {
    const operators = bootstrap.aliceOperator();
    const plugins = lightning_rod.plugin.replace(bootstrap.plugins(), .{
        lightning_rod.plugin.configured(vanilla.Players, .{ .maximum = 2, .render_distance = 2 }),
        lightning_rod.plugin.configured(vanilla.Operators, .{ .operators = &operators }),
        lightning_rod.plugin.configured(vanilla.Time, .{ .daylight_cycle = false }),
    });
    try bootstrap.run(init, plugins, .{ .plaintext = true, .reload_executable = "/proc/self/exe" });
}
