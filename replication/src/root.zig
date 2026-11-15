//! Players and entities as other players see them: visibility layers, replication and debug views.
const std = @import("std");

pub const entity_packets = @import("entity_packets.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const region_debug = @import("region_debug.zig");
pub const replication = @import("replication.zig");
pub const visibility = @import("visibility.zig");

test {
    std.testing.refAllDecls(@This());
}
