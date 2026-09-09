const std = @import("std");
const connection = @import("connection_api.zig");
const geometry = @import("world/geometry.zig");
const world_identity = @import("world/identity.zig");
const limits = @import("world/limits.zig");

pub const LeaveReason = connection.DisconnectReason;

pub const PlayStartReason = enum(u8) { joined, reconfigured };

pub const PlayerLeft = struct {
    slot: u16,
    connection: connection.Handle,
    reason: LeaveReason,
    player: DetachedPlayer = .{},
};

pub const DetachedPlayer = struct {
    world: world_identity.Handle = world_identity.invalid,
    entity_id: i32 = 0,
    uuid: u128 = 0,
    name: [limits.username_bytes]u8 = @splat(0),
    name_len: u8 = 0,
    dig_position: ?geometry.BlockPos = null,

    pub fn nameSlice(self: *const DetachedPlayer) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const PlayerJoined = struct {
    slot: u16,
    connection: connection.Handle,
};

pub const PlayStarted = struct {
    slot: u16,
    connection: connection.Handle,
    reason: PlayStartReason,
    new_player: bool = false,
    project_to_observers: bool = false,
};

pub const JoinedBatch = struct {
    values: []const PlayerJoined = &.{},
};

pub const LeftBatch = struct {
    values: []const PlayerLeft = &.{},
};

pub const Events = struct {
    pub const id = "lightning_rod:player_lifecycle";
    pub const Configuration = struct {};

    joined: JoinedBatch = .{},
    left: LeftBatch = .{},
    play_started: []const PlayStarted = &.{},

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*Events {
        const self = try allocator.create(Events);
        self.* = .{};
        return self;
    }

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
