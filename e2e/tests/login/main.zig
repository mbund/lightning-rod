const e2e = @import("e2e");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try e2e.profile.arguments(init);
    const status_probe = std.mem.eql(u8, args.fixture, "isolation");
    const plugins = e2e.profile.plugins();
    try e2e.profile.run(init, plugins, .{
        .plaintext = !status_probe,
        .compression_threshold = if (status_probe) null else 256,
    });
}
