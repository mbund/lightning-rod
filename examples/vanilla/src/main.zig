const std = @import("std");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const tui = @import("lightning_rod_tui");

pub const std_options: std.Options = .{ .logFn = lightning_rod.logging.logFn };

pub fn main(init: std.process.Init) !void {
    const plugins = lightning_rod.plugin.compose(.{
        vanilla.plugins(),
        lightning_rod.plugin.configured(tui.Plugin, tui.Plugin.Configuration{}),
    });
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{});
    try Server.run(init, .{ .plugins = plugins });
}
