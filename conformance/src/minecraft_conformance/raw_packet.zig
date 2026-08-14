/// A Minecraft packet body at the conformance boundary. `payload` starts with
/// the packet id VarInt and deliberately excludes length framing,
/// compression, and encryption. The target owns the bytes until its next
/// `step` call.
pub const Clientbound = struct {
    recipient: []const u8,
    payload: []const u8,
};

/// Runtime identities are supplied by fixture restoration so the shared
/// canonicalizer can replace unstable entity ids with fixture aliases.
pub const Identity = struct {
    alias: []const u8,
    entity_id: i32,
    uuid: u128 = 0,
    position: [3]f64 = .{ 0, 0, 0 },
    position_known: bool = false,
};
