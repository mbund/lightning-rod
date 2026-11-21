//! Vanilla items: item data and components, registries, enchantments, loot and item actions.
const std = @import("std");

pub const attack_effects = @import("attack_effects.zig");
pub const enchantment_effects = @import("enchantment_effects.zig");
pub const enchantment_registry = @import("enchantment_registry.zig");
pub const enchantments = @import("enchantments.zig");
pub const equipment_attributes = @import("equipment_attributes.zig");
pub const item_actions = @import("item_actions.zig");
pub const item_components = @import("item_components.zig");
pub const item_cooldowns = @import("item_cooldowns.zig");
pub const item_content = @import("item_content.zig");
pub const item_data = @import("item_data.zig");
pub const item_inputs = @import("item_inputs.zig");
pub const item_lore = @import("item_lore.zig");
pub const item_packets = @import("item_packets.zig");
pub const item_properties = @import("item_properties.zig");
pub const item_registry = @import("item_registry.zig");
pub const item_using = @import("item_using.zig");
pub const items = @import("items.zig");
pub const loot = @import("loot.zig");
pub const loot_registry = @import("loot_registry.zig");
pub const vanilla_properties = @import("vanilla_properties.zig");

test {
    std.testing.refAllDecls(@This());
}
