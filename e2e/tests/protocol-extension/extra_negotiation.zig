const std = @import("std");
const sessions = @import("sessions");
const selected_protocol = @import("protocols");
const wire = @import("wire");

pub const ExtraNegotiation = struct {
    pub const id = "example:extra_negotiation";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *selected_protocol.Input, phases: *sessions.Phases };
    pub const SessionLoginState = struct {
        requested: bool = false,
        answered: bool = false,
    };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*ExtraNegotiation {
        const self = try allocator.create(ExtraNegotiation);
        try deps.input.login.on(.cookie_response, self, onResponse);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onResponse(_: *ExtraNegotiation, _: sessions.InputScope, state: *SessionLoginState, packet: wire.login.toServer.packet_common_cookie_response.Reader, _: []u8) !sessions.LoginInputEffect {
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

    fn onLogin(_: *ExtraNegotiation, scope: sessions.PhaseScope, state: *SessionLoginState, event: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        switch (event) {
            .begin => {
                state.* = .{ .requested = true };
                return .{ .send = try sessions.packet_api.encodeFor(selected_protocol.implementations, writeRequest, scope.profile.protocol, output, .{}) };
            },
            .poll => return if (state.answered) .done else .wait,
            .admitted => return error.UnexpectedLoginEvent,
        }
    }

    fn writeRequest(packet: wire.login.toClient.packet_common_cookie_request.Writer) ![]u8 {
        return (try packet.cookie("example:probe")).finish();
    }
};
