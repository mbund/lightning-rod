//! Players and entities as other players see them: visibility layers, replication and debug views.
const std = @import("std");

pub const entity_packets = @import("entity_packets.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const replication_test = @import("replication_test.zig");
pub const player_changes = @import("player_changes.zig");
pub const tracking = @import("tracking.zig");
pub const tracking_test = @import("tracking_test.zig");
pub const region_debug = @import("region_debug.zig");
pub const replication = @import("replication.zig");
pub const visibility = @import("visibility.zig");

test {
    std.testing.refAllDecls(@This());
}
