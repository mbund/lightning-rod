const packets = @import("packets.zig");
const registry = @import("registry.zig");
const protocols = @import("protocols");
const support = @import("protocol_support");

pub const Packets = packets.Packets;
pub const Registry = registry.Registry;

pub fn nested(comptime handlers: anytype) type {
    return support.cursor.Nested(protocols.implementations, handlers);
}
