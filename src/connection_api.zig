pub const StatusDraft = struct {
    slot: u16,
    version_name: []const u8,
    protocol_number: i32,
    motd: []const u8,
    maximum_players: usize,
    online_players: usize,
    cancelled: bool = false,
};

pub const LoginDraft = struct {
    slot: u16,
    username: []const u8,
    uuid: u128,
    current_players: usize,
    maximum_players: usize,
    accepted: bool = true,
    rejection_reason: []const u8 = "",

    pub fn reject(self: *LoginDraft, reason: []const u8) void {
        self.accepted = false;
        self.rejection_reason = reason;
    }
};
