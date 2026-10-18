const std = @import("std");
const bootstrap = @import("e2e").server;

pub fn main(init: std.process.Init) !void {
    const args = try bootstrap.arguments(init);
    const status_probe = std.mem.eql(u8, args.fixture, "isolation");
    const plugins = bootstrap.plugins();
    try bootstrap.run(init, plugins, .{
        .plaintext = !status_probe,
        .compression_threshold = if (status_probe) null else 256,
    });
}
