//! Dropped items as entities: storage, physics, merging and spatial queries.
const std = @import("std");

pub const item = @import("item.zig");
pub const item_entities = @import("item_entities.zig");
pub const item_merging = @import("item_merging.zig");
pub const item_physics = @import("item_physics.zig");
pub const item_selection = @import("item_selection.zig");
pub const item_spatial = @import("item_spatial.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("item_selection_test.zig");
    _ = @import("item_spatial_test.zig");
}
