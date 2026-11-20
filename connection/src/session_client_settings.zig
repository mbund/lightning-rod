const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

/// Keeps the skin layers the client says it shows while it configures. Play receives changes
/// itself; the client sends its settings in configuration first, before the game knows the player.
pub const ClientSettings = struct {
    pub const id = "minecraft:client_settings";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *protocols.Input, profiles: *sessions.Profiles };
    pub const SessionConfigurationState = struct {};
    pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

    profiles: *sessions.Profiles,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ClientSettings {
        const self = try allocator.create(ClientSettings);
        self.* = .{ .profiles = deps.profiles };
        try deps.input.configuration.on(.settings, self, onSettings);
        return self;
    }

    fn onSettings(self: *ClientSettings, scope: sessions.InputScope, _: *SessionConfigurationState, packet: wire_1_21_5.configuration.toServer.packet_common_settings.Reader, _: []u8) !sessions.ConfigurationInputEffect {
        _, const a = try packet.locale();
        _, const b = try a.viewDistance();
        _, const c = try b.chatFlags();
        _, const d = try c.chatColors();
        const skin_parts, _ = try d.skinParts();
        self.profiles.of(scope.profile.connection).skin_parts = @bitCast(skin_parts);
        return .none;
    }
};
