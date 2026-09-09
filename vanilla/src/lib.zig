const lightning_rod = @import("lightning_rod");
const std = @import("std");
const vanilla_generation = @import("vanilla_generation.zig");
const composition = @import("composition.zig");
const vanilla_plugins = @import("vanilla_plugins.zig");

pub const minimum_minecraft_version = "1.21.6";
pub const WorldGeneration = vanilla_generation.Default;
pub const Status = vanilla_plugins.status.Status;
pub const PlayDecode = vanilla_plugins.play_decode.PlayDecode;
pub const Plugins = composition.Plugins;
pub const protocols = lightning_rod.protocol_versions.from(.v1_21_6);
pub const Protocols = @TypeOf(protocols);

pub fn plugins() Plugins {
    return composition.vanilla();
}

test "the gameplay baseline matches the compiled wire range" {
    try std.testing.expectEqual(lightning_rod.protocol_versions.all.len, protocols.len);
    try std.testing.expect(lightning_rod.protocol_versions.supportsRelease(
        protocols,
        .v1_21_6,
    ));
    try std.testing.expect(lightning_rod.protocol_versions.supportsRelease(protocols, .v1_21_7));
    try std.testing.expect(lightning_rod.protocol_versions.supportsRelease(protocols, .v1_21_8));
}

test {
    _ = @import("vanilla_configuration.zig");
    _ = @import("vanilla_plugins.zig");
    _ = composition;
}
