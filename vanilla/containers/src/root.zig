//! Containers and their menus: chests, furnaces, crafting tables and the recipe book.
const std = @import("std");

pub const containers = @import("containers.zig");
pub const furnace = @import("furnace.zig");
pub const inventory_menus = @import("inventory_menus.zig");
pub const recipe_book = @import("recipe_book.zig");
pub const recipe_commands = @import("recipe_commands.zig");

test {
    std.testing.refAllDecls(@This());
}
