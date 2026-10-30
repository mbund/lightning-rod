pub const schema = @import("schema");
pub const registry = @import("registry");
pub const encoding = @import("support");
pub const canonical_version = @import("canonical_version").value;
pub const canonical_identity: [32]u8 = @embedFile("canonical_identity")[0..32].*;

pub const entities: type = registry.entity_ids;
pub const items: type = registry.item_ids;
pub const registry_snapshot = @embedFile("registry_snapshot");
pub const snapshot = @import("snapshot.zig");
pub const vanilla_pack = @embedFile("vanilla_pack");

pub const lighting_data = @import("lighting.zig");
pub const lighting = lighting_data.Data(registry.block_state_names.len, @embedFile("lighting_snapshot"));
pub const physics_data = @import("physics.zig");
pub const physics = physics_data.Data(registry.block_state_names.len, registry.blocks.len, @embedFile("physics_snapshot"));

pub const fuel_data = @import("fuels.zig");
pub const fuels = fuel_data.Data(registry.items.len, @embedFile("fuel_snapshot"));
