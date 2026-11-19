//! The player inventory: its menu, creative mode, item pickup and item replication.
const std = @import("std");

pub const creative_inventory = @import("creative_inventory.zig");
pub const inventory_capacity = @import("inventory_capacity.zig");
pub const item_pickup = @import("item_pickup.zig");
pub const item_replication = @import("item_replication.zig");
pub const item_tick = @import("item_tick.zig");
pub const item_hazards = @import("item_hazards.zig");
pub const menu_click = @import("menu_click.zig");
pub const player_inventory = @import("player_inventory.zig");

test {
    std.testing.refAllDecls(@This());
}
