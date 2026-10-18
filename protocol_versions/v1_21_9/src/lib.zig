const java = @import("minecraft_java");
const version = @import("version.zig");
const prepared = @import("registry_packets");
pub const Protocol = @import("wire");
pub const Registry = @import("registry");

pub const protocol_number = version.protocol_number;
pub const minecraft_name = version.minecraft_name;
pub const releases = version.releases;

pub const registry_snapshot = @embedFile("registry_snapshot");
pub const registry_packets = prepared.value;
pub const RegistryProvider = java.Registries(@This());
pub const Connection = java.Connection(Protocol);
pub const Bootstrap = java.Bootstrap;
