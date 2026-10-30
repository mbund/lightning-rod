const base = @import("base_data");
pub const schema = @import("schema");
pub const registry = @import("registry");

pub const canonical_version = "1.21.9";
pub const canonical_identity: [32]u8 = @embedFile("canonical_identity")[0..32].*;
pub const entities: type = registry.entity_ids;
pub const items: type = registry.item_ids;
pub const encoding = base.encoding;
pub const snapshot = base.snapshot;

pub const registry_snapshot = @embedFile("registry_snapshot");
pub const vanilla_pack = @embedFile("vanilla_pack");

pub const lighting = base.lighting_data.Data(registry.block_state_names.len, @embedFile("lighting_snapshot"));
pub const physics_data = base.physics_data;
pub const physics = physics_data.Data(registry.block_state_names.len, registry.blocks.len, @embedFile("physics_snapshot"));

pub const fuels = base.fuel_data.Data(registry.items.len, @embedFile("fuel_snapshot"));
