//! Connected players: the engine record, input dispatch, spatial indexes and audiences.
const std = @import("std");

pub const audience = @import("audience.zig");
pub const input = @import("input.zig");
pub const player_spatial = @import("player_spatial.zig");
pub const player_state = @import("player_state.zig");
pub const players = @import("players.zig");

test {
    std.testing.refAllDecls(@This());
}
