//! Survival mechanics: experience orbs, damage types and the damage players take.
const std = @import("std");

pub const experience = @import("experience.zig");
pub const experience_replication = @import("experience_replication.zig");
pub const damage_types = @import("damage_types.zig");
pub const fall_damage = @import("fall_damage.zig");
pub const player_damage = @import("player_damage.zig");

test {
    std.testing.refAllDecls(@This());
}
