pub const schema = @import("schema");
pub const registry = @import("registry");
pub const encoding = @import("support");
pub const canonical_version = @import("canonical_version").value;
pub const canonical_identity: [32]u8 = @embedFile("canonical_identity")[0..32].*;

pub const entities: type = registry.entity_ids;
pub const items: type = registry.item_ids;
pub const registry_snapshot = @embedFile("registry_snapshot");
