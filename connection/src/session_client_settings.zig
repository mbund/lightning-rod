const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

/// Keeps the skin layers the client says it shows. Configuration settings come before the game
/// knows the player; play changes reach the game too, and are kept here so a reload restores them.
pub const ClientSettings = struct {
    pub const id = "minecraft:client_settings";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *protocols.Input, profiles: *sessions.Profiles };
    pub const SessionConfigurationState = struct {};
    pub const SessionPlayState = struct {};
    pub const SessionState = struct { configuration: SessionConfigurationState = .{}, play: SessionPlayState = .{} };

    profiles: *sessions.Profiles,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ClientSettings {
        const self = try allocator.create(ClientSettings);
        self.* = .{ .profiles = deps.profiles };
        try deps.input.configuration.on(.settings, self, onSettings);
        try deps.input.play.on(.settings, self, onPlaySettings);
        return self;
    }

    fn onSettings(self: *ClientSettings, scope: sessions.InputScope, _: *SessionConfigurationState, packet: wire_1_21_5.configuration.toServer.packet_common_settings.Reader, _: []u8) !sessions.ConfigurationInputEffect {
        self.profiles.of(scope.profile.connection).skin_parts = try skinParts(packet);
        return .none;
    }

    fn onPlaySettings(self: *ClientSettings, scope: sessions.InputScope, _: *SessionPlayState, packet: wire_1_21_5.play.toServer.packet_common_settings.Reader, _: []u8) !sessions.PlayInputEffect {
        self.profiles.of(scope.profile.connection).skin_parts = try skinParts(packet);
        return .none;
    }

    fn skinParts(packet: anytype) !u8 {
        _, const a = try packet.locale();
        _, const b = try a.viewDistance();
        _, const c = try b.chatFlags();
        _, const d = try c.chatColors();
        const skin_parts, _ = try d.skinParts();
        return @bitCast(skin_parts);
    }
};
