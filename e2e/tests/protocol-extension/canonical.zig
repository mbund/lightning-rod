const base = @import("base_data");

pub const schema = @import("schema");
pub const registry = @import("registry");
pub const entities: type = registry.entity_ids;
pub const items: type = registry.item_ids;
pub const encoding = base.encoding;

pub const registry_snapshot = @embedFile("registry_snapshot");
