const std = @import("std");
const sessions = @import("sessions");
const selected_protocol = @import("protocols");
const wire = @import("wire");

pub const ExtraNegotiation = struct {
    pub const id = "example:extra_negotiation";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *selected_protocol.Input, phases: *sessions.Phases };
    pub const SessionConfigurationState = struct {
        requested: bool = false,
        answered: bool = false,
    };
    pub const SessionState = struct { configuration: SessionConfigurationState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ExtraNegotiation {
        const self = try allocator.create(ExtraNegotiation);
        try deps.input.configuration.on(.cookie_response, self, onResponse);
        try deps.phases.onConfiguration(self, onConfiguration);
        return self;
    }

    fn onResponse(_: *ExtraNegotiation, _: sessions.InputScope, state: *SessionConfigurationState, packet: wire.configuration.toServer.packet_common_cookie_response.Reader, _: []u8) !sessions.ConfigurationInputEffect {
        const key, const value = try packet.key();
        if (!std.mem.eql(u8, key, "example:probe") or !state.requested or state.answered) return error.InvalidExtraNegotiation;
        var optional = try value.value();
        switch (try (try optional.begin()).value()) {
            .none => |done| try (try optional.advance(done)).finish(),
            .some => return error.UnexpectedCookieValue,
        }
        state.answered = true;
        std.log.info("event=downstream_extra_negotiation", .{});
        return .none;
    }

    fn onConfiguration(_: *ExtraNegotiation, scope: sessions.PhaseScope, state: *SessionConfigurationState, event: sessions.PhaseEvent, output: []u8) !sessions.ConfigurationStep {
        switch (event) {
            .begin => {
                state.* = .{ .requested = true };
                return .{ .send = try sessions.packet_api.encodeFor(selected_protocol.implementations, writeRequest, scope.profile.protocol, output, .{}) };
            },
            .poll => return if (state.answered) .done else .wait,
            .admitted => return error.UnexpectedConfigurationEvent,
        }
    }

    fn writeRequest(packet: wire.configuration.toClient.packet_common_cookie_request.Writer) ![]u8 {
        return (try packet.cookie("example:probe")).finish();
    }
};
