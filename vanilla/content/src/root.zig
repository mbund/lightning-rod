//! Vanilla content every other vanilla package builds on: identifiers, tags, registries, blocks and dimensions.
const std = @import("std");

pub const behavior = @import("behavior.zig");
pub const blocks = @import("blocks.zig");
pub const client_registries = @import("client_registries.zig");
pub const container_blocks = @import("container_blocks.zig");
pub const content_definitions = @import("content_definitions.zig");
pub const content_ids = @import("content_ids.zig");
pub const content_registries = @import("content_registries.zig");
pub const content_tags = @import("content_tags.zig");
pub const content_values = @import("content_values.zig");
pub const custom_data = @import("custom_data.zig");
pub const dimensions = @import("dimensions.zig");
pub const native_nbt = @import("native_nbt.zig");
pub const random = @import("random.zig");
pub const registry = @import("registry.zig");
pub const registry_identity = @import("registry_identity.zig");

test {
    std.testing.refAllDecls(@This());
}
