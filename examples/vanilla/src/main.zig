const std = @import("std");
const lightning_rod = @import("lightning_rod");
const linux = @import("lightning_rod_linux");
const vanilla = @import("lightning_rod_vanilla_1_21_6");

pub const std_options: std.Options = .{ .logFn = lightning_rod.logging.logFn };

pub fn main(init: std.process.Init) !void {
    const plugins = vanilla.plugins();
    const Server = linux.Profile(vanilla.protocols, @TypeOf(plugins), .{});
    try Server.run(init, .{ .plugins = plugins });
}
