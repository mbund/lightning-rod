const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const experience = @import("experience_state.zig");

pub const encoded_size = 45;

pub const Stage = enum {
    login,
    brand,
    tab,
    border,
    teleport,
    awaiting_teleport,
    health,
    selection,
    ready,
    respawn,
};

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
    revision: u64 = 0,
    gamemode: minecraft.GameMode = .creative,
    health: f32 = 20,
    gamemode_sent: ?minecraft.GameMode = null,
    abilities_sent: ?u8 = null,
    flying: bool = false,
    health_sent: f32 = 20,
    life: u32 = 1,
    selected_slot: u4 = 0,
    experience: experience.State = .{},
    experience_delay: u8 = 0,
    saved: [encoded_size]u8 = @splat(0),
    saved_experience: [experience.State.encoded_size]u8 = @splat(0),

    pub fn inWorld(self: Player) bool {
        return self.handle != null;
    }

    pub fn inPlay(self: Player) bool {
        return self.handle != null and !self.configuring and self.stage != .login and self.stage != .brand and self.stage != .tab;
    }
};
