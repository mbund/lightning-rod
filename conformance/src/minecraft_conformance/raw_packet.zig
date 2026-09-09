pub const Clientbound = struct {
    recipient: []const u8,
    payload: []const u8,
};

pub const Identity = struct {
    alias: []const u8,
    entity_id: i32,
    uuid: u128 = 0,
    position: [3]f64 = .{ 0, 0, 0 },
    position_known: bool = false,
};
