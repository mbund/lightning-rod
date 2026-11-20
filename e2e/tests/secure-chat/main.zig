const e2e = @import("e2e");
const std = @import("std");
const lightning_rod = @import("lightning_rod");
const Operators = @import("commands").operators.Operators;

/// Alice and bob join in online mode, with chat keys from the runner's session server, and sign
/// what they say; alice may reload the server.
pub fn main(init: std.process.Init) !void {
    const operators = [_]u128{onlineUuid("alice")};
    const plugins = lightning_rod.plugin.replace(e2e.profile.plugins(), .{
        lightning_rod.plugin.configured(Operators, Operators.Configuration{ .operators = &operators }),
    });
    try e2e.profile.run(init, plugins, .{});
}

/// The UUID the runner's session server gives a player.
fn onlineUuid(name: []const u8) u128 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update("OnlinePlayer:");
    hash.update(name);
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}
