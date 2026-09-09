const lightning_rod = @import("lightning_rod");
const std = @import("std");
const vanilla_generation = @import("vanilla_generation.zig");
const composition = @import("composition.zig");
const vanilla_plugins = @import("vanilla_plugins.zig");

pub const minimum_minecraft_version = "1.21.6";
pub const WorldGeneration = vanilla_generation.Default;
pub const Status = vanilla_plugins.status.Status;
pub const TabList = vanilla_plugins.tab_list.TabList;
pub const LocalRoster = vanilla_plugins.tab_list.LocalRoster;
pub const PlayDecode = vanilla_plugins.play_decode.PlayDecode;
pub const decodePlayPacket = vanilla_plugins.play_decode.dispatchWith;
pub const PlayerInput = vanilla_plugins.player_input.PlayerInput;
pub const Mining = vanilla_plugins.mining.Mining;
pub const Persistence = vanilla_plugins.persistence.Persistence;
pub const Materializer = vanilla_plugins.persistence.Materializer;
pub const ChunkWork = vanilla_plugins.persistence.ChunkWork;
pub const ChunkStreaming = vanilla_plugins.chunk_streaming.ChunkStreaming;
pub const Lighting = vanilla_plugins.lighting.Lighting;
pub const CollisionProjection = vanilla_plugins.collision_projection.CollisionProjection;
pub const ChunkTickets = vanilla_plugins.chunk_tickets.ChunkTickets;
pub const chunk_tickets = vanilla_plugins.chunk_tickets;
pub const SimulationAdmission = vanilla_plugins.simulation_admission.SimulationAdmission;
pub const simulation_admission = vanilla_plugins.simulation_admission;
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
    _ = @import("vanilla_generation.zig");
    _ = @import("vanilla_configuration.zig");
    _ = @import("vanilla_plugins.zig");
    _ = composition;
}
