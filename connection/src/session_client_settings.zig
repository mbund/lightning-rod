const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

/// Keeps what the client's settings say the server needs of them: the skin layers it shows and how
/// far it asks to see. Configuration settings come before the game knows the player; play changes
/// reach the game too, and are kept here so a reload restores them.
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
        try self.remember(scope.profile.connection, packet);
        return .none;
    }

    fn onPlaySettings(self: *ClientSettings, scope: sessions.InputScope, _: *SessionPlayState, packet: wire_1_21_5.play.toServer.packet_common_settings.Reader, _: []u8) !sessions.PlayInputEffect {
        try self.remember(scope.profile.connection, packet);
        return .none;
    }

    fn remember(self: *ClientSettings, connection: sessions.Handle, packet: anytype) !void {
        _, const a = try packet.locale();
        const view_distance, const b = try a.viewDistance();
        const chat_mode, const c = try b.chatFlags();
        _, const d = try c.chatColors();
        const skin_parts, _ = try d.skinParts();
        const profile = self.profiles.of(connection);
        profile.skin_parts = @bitCast(skin_parts);
        // Anything but a positive distance is no distance, as if the client had not said.
        profile.view_distance = std.math.cast(u8, view_distance) orelse 0;
        // Past the three modes there is nothing the client could mean; it shows everything.
        profile.chat_mode = if (chat_mode >= 0 and chat_mode <= 2) @intCast(chat_mode) else 0;
    }
};
