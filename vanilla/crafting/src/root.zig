//! Vanilla crafting: recipes, fuel, smelting, furnaces and the recipe book's data.
const std = @import("std");

pub const crafting = @import("crafting.zig");
pub const crafting_registry = @import("crafting_registry.zig");
pub const fuel = @import("fuel.zig");
pub const furnaces = @import("furnaces.zig");
pub const recipe_book_packets = @import("recipe_book_packets.zig");
pub const recipe_book_progress = @import("recipe_book_progress.zig");
pub const recipe_book_registry = @import("recipe_book_registry.zig");
pub const recipe_placement = @import("recipe_placement.zig");
pub const recipe_unlocks = @import("recipe_unlocks.zig");
pub const recipes = @import("recipes.zig");
pub const smelting = @import("smelting.zig");

test {
    std.testing.refAllDecls(@This());
}
