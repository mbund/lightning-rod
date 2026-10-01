const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const ConfigurationFinish = struct {
    pub const id = "minecraft:configuration_finish";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
    pub const SessionConfigurationState = struct {
        sent: bool = false,
        acknowledged: bool = false,
    };
    pub const SessionPlayState = struct {};
    pub const SessionState = struct {
        configuration: SessionConfigurationState = .{},
        play: SessionPlayState = .{},
    };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ConfigurationFinish {
        const self = try allocator.create(ConfigurationFinish);
        try deps.input.configuration.on(.finish_configuration, self, onFinishAcknowledged);
        try deps.input.play.on(.configuration_acknowledged, self, onReconfigureAcknowledged);
        try deps.phases.onConfiguration(self, onConfiguration);
        try deps.phases.onPlay(self, onPlay);
        return self;
    }

    fn onFinishAcknowledged(_: *ConfigurationFinish, _: sessions.InputScope, state: *SessionConfigurationState, packet: wire_1_21_5.configuration.toServer.packet_finish_configuration.Reader, _: []u8) !sessions.ConfigurationInputEffect {
        try packet.finish();
        if (!state.sent or state.acknowledged) return error.UnexpectedConfigurationPacket;
        state.acknowledged = true;
        return .none;
    }

    fn onReconfigureAcknowledged(_: *ConfigurationFinish, _: sessions.InputScope, _: *SessionPlayState, packet: wire_1_21_5.play.toServer.packet_configuration_acknowledged.Reader, _: []u8) !sessions.PlayInputEffect {
        try packet.finish();
        return .reconfigure;
    }

    fn onConfiguration(_: *ConfigurationFinish, scope: sessions.PhaseScope, state: *SessionConfigurationState, event: sessions.PhaseEvent, output: []u8) !sessions.ConfigurationStep {
        switch (event) {
            .begin => {
                state.* = .{ .sent = true };
                return .{ .send = try sessions.packet_api.encodeFor(protocols.implementations, writeFinish, scope.profile.protocol, output, .{}) };
            },
            .poll => return if (state.acknowledged) .done else .wait,
            .admitted => return error.UnexpectedConfigurationEvent,
        }
    }

    fn onPlay(_: *ConfigurationFinish, profile: sessions.Profile, _: *SessionPlayState, event: sessions.protocol.PlayEvent, output: []u8) !?[]const u8 {
        return switch (event) {
            .park => try sessions.packet_api.encodeFor(protocols.implementations, writeReconfigure, profile.protocol, output, .{}),
            .attached, .poll, .disconnect => null,
        };
    }

    fn writeFinish(packet: wire_1_21_5.configuration.toClient.packet_finish_configuration.Writer) ![]u8 {
        return packet.finish();
    }

    fn writeReconfigure(packet: wire_1_21_5.play.toClient.packet_start_configuration.Writer) ![]u8 {
        return packet.finish();
    }
};
