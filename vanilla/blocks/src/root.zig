//! Interacting with blocks: placement, mining, doors, block actions and block loot.
const std = @import("std");

pub const block_actions = @import("block_actions.zig");
pub const block_loot = @import("block_loot.zig");
pub const doors = @import("doors.zig");
pub const growth = @import("growth.zig");
pub const item_use = @import("item_use.zig");
pub const mining = @import("mining.zig");
pub const mining_behavior = @import("mining_behavior.zig");
pub const mining_registry = @import("mining_registry.zig");
pub const placement = @import("placement.zig");
pub const placement_behavior = @import("placement_behavior.zig");
pub const placement_registry = @import("placement_registry.zig");
pub const raycast = @import("raycast.zig");

test {
    std.testing.refAllDecls(@This());
}
