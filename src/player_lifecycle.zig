const hot_reload_abi = @import("hot_reload_abi.zig");

pub const LeaveReason = enum(u8) {
    peer_closed,
    timeout,
    transport_error,
    kicked,
    server_shutdown,
};

pub const PlayStartReason = enum(u8) {
    login,
    reconfiguration,
};

pub const PlayerLeft = struct {
    slot: u16,
    connection: hot_reload_abi.ConnectionHandle,
    reason: LeaveReason,
};

pub const PlayerJoined = struct {
    slot: u16,
    connection: hot_reload_abi.ConnectionHandle,
};

pub const PlayStarted = struct {
    slot: u16,
    connection: hot_reload_abi.ConnectionHandle,
    reason: PlayStartReason,
};

pub const JoinedBatch = struct {
    values: []const PlayerJoined = &.{},
};

pub const LeftBatch = struct {
    values: []const PlayerLeft = &.{},
};

pub const Events = struct {
    joined: JoinedBatch = .{},
    left: LeftBatch = .{},
    play_started: []const PlayStarted = &.{},

    pub fn begin(
        self: *Events,
        joined: JoinedBatch,
        left: LeftBatch,
        play_started: []const PlayStarted,
    ) void {
        self.joined = joined;
        self.left = left;
        self.play_started = play_started;
    }
};
