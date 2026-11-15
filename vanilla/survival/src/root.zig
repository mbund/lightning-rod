//! Survival mechanics: experience orbs and fall damage.
const std = @import("std");

pub const experience = @import("experience.zig");
pub const experience_replication = @import("experience_replication.zig");
pub const fall_damage = @import("fall_damage.zig");

test {
    std.testing.refAllDecls(@This());
}
