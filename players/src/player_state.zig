const std = @import("std");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");

/// Version, position, rotation, entity flags, ground and world.
pub const encoded_size = 39;
pub const encoded_version = 4;

pub const Stage = enum {
    login,
    brand,
    tab,
    teleport,
    awaiting_teleport,
    ready,
    respawn,
};

/// What the engine keeps for each connected player. Game rules keep their own state per
/// slot beside it.
pub const Player = struct {
    handle: ?sessions.Handle = null,
    uuid: u128 = 0,
    world: u32 = 0,
    teleport_id: i32 = 1,
    keep_respawn_data: bool = false,
    protocol: i32 = 0,
    name: [16]u8 = undefined,
    name_len: u8 = 0,
    position: minecraft.Position = .{ .x = 0.5, .y = 65, .z = 0.5 },
    rotation: minecraft.Rotation = .{ .yaw = 0, .pitch = 0 },
    stage: Stage = .login,
    configuring: bool = false,
    loaded: bool = false,
    on_ground: bool = false,
    flags: minecraft.EntityFlags = .{},
    /// The skin layers the player's client shows, one bit each, as its settings say.
    skin_parts: u8 = 0,
    /// How many chunks around them the player is sent: what its client asked for, no fewer than 2
    /// and no more than the server sends anyone, as vanilla's ChunkMap.getPlayerViewDistance.
    /// Joining sets it, to 2 if the client has not said, as vanilla's ServerPlayer starts; a
    /// record that never joined has no limit of its own.
    view_distance: i32 = std.math.maxInt(i32),
    revision: u64 = 0,
    /// Whether blocks hide from the player what it cannot see. Spectators see through them.
    occluded: bool = true,
    /// Rises on every respawn and every change of world, as the client then forgets what
    /// it was shown.
    life: u32 = 1,
    /// Positions the client has confirmed since it joined. Whoever sends state once a
    /// player arrives watches it.
    arrivals: u32 = 0,
    saved: [encoded_size]u8 = @splat(0),

    pub fn encode(player: *const Player) [encoded_size]u8 {
        var bytes: [encoded_size]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        writer.writeByte(encoded_version) catch unreachable;
        inline for (.{ player.position.x, player.position.y, player.position.z }) |value|
            writer.writeInt(u64, @bitCast(value), .little) catch unreachable;
        inline for (.{ player.rotation.yaw, player.rotation.pitch }) |value|
            writer.writeInt(u32, @bitCast(value), .little) catch unreachable;
        writer.writeByte(@bitCast(player.flags)) catch unreachable;
        writer.writeByte(@intFromBool(player.on_ground)) catch unreachable;
        writer.writeInt(u32, player.world, .little) catch unreachable;
        std.debug.assert(writer.end == bytes.len);
        return bytes;
    }

    pub fn inWorld(self: Player) bool {
        return self.handle != null;
    }

    pub fn inPlay(self: Player) bool {
        return self.handle != null and !self.configuring and self.stage != .login and self.stage != .brand and self.stage != .tab;
    }
};
