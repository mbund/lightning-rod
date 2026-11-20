const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Operators = @import("commands").operators.Operators;

/// Alice plays in creative and may reload the server.
pub fn main(init: std.process.Init) !void {
    const operators = e2e.profile.aliceOperator();
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Operators, Operators.Configuration{ .operators = &operators }),
    });
    try e2e.profile.run(init, plugins, .{});
}
