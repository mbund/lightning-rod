const packets = @import("packets.zig");
const registry = @import("registry.zig");
/// The protocol releases this server speaks. Whoever builds the server selects them, and
/// every package reaches the selection here.
pub const protocols = @import("protocols");
const support = @import("protocol_support");

pub const Packets = packets.Packets;
pub const Registry = registry.Registry;

pub fn nested(comptime handlers: anytype) type {
    return support.cursor.Nested(protocols.implementations, handlers);
}
