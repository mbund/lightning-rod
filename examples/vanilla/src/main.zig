const std = @import("std");
const lightning_rod = @import("lightning_rod");
const vanilla = @import("vanilla");

pub const panic = lightning_rod.server_app.panic;
pub const std_options: std.Options = lightning_rod.server_app.std_options;

pub fn main(init: std.process.Init) !void {
    try lightning_rod.server_app.run(vanilla, init);
}
