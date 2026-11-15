//! Vanilla definitions as one set: content types, the definition provider, datapack adapters and the prepared defaults.
const std = @import("std");

pub const content_components = @import("content_components.zig");
pub const content_protocols = @import("content_protocols.zig");
pub const content_types = @import("content_types.zig");
pub const datapack_decoder = @import("datapack_decoder.zig");
pub const datapack_enchantments = @import("datapack_enchantments.zig");
pub const datapack_filters = @import("datapack_filters.zig");
pub const datapack_formats = @import("datapack_formats.zig");
pub const datapack_handlers = @import("datapack_handlers.zig");
pub const datapack_loot = @import("datapack_loot.zig");
pub const datapack_recipes = @import("datapack_recipes.zig");
pub const datapack_unlocks = @import("datapack_unlocks.zig");
pub const datapacks = @import("datapacks.zig");
pub const defaults = @import("defaults.zig");
pub const definition_provider = @import("definition_provider.zig");

test {
    std.testing.refAllDecls(@This());
}
