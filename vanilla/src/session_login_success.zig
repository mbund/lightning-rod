const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const wire_26_2 = @import("wire_26_2");
const sessions = @import("sessions");
const protocols = @import("protocols");
const Disconnect = @import("session_disconnect.zig").Disconnect;

pub const LoginSuccess = struct {
    pub const id = "minecraft:login_success";
    pub const Configuration = struct {};
    pub const Dependencies = struct { disconnect: *Disconnect, input: *protocols.Input, phases: *sessions.Phases };
    pub const SessionLoginState = struct {
        stage: enum { initial, admitting, success_sent } = .initial,
        acknowledged: bool = false,
    };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*LoginSuccess {
        const self = try allocator.create(LoginSuccess);
        self.* = .{ .deps = deps };
        try deps.input.login.on(.login_acknowledged, self, onAcknowledged);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onLogin(self: *LoginSuccess, scope: sessions.PhaseScope, state: *SessionLoginState, event: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        switch (state.stage) {
            .initial => {
                if (scope.profile.uuid == 0) return error.Unauthenticated;
                state.stage = .admitting;
                return .admit;
            },
            .admitting => {
                if (event != .admitted) return .wait;
                if (event.admitted) |message| return .{ .reject = try self.deps.disconnect.login(scope.profile.protocol, message, output) };
                var session_uuid: u128 = 0;
                var needs_session_uuid = false;
                inline for (protocols.implementations) |Implementation| {
                    needs_session_uuid = needs_session_uuid or (scope.profile.protocol == Implementation.protocol_number and
                        comptime sessions.packet_api.select(Implementation, .{ writeSuccess, writeSuccessWithSession }) == 1);
                }
                if (needs_session_uuid) {
                    var session_id: [16]u8 = undefined;
                    try scope.io.randomSecure(&session_id);
                    session_id[6] = (session_id[6] & 0x0f) | 0x40;
                    session_id[8] = (session_id[8] & 0x3f) | 0x80;
                    session_uuid = std.mem.readInt(u128, &session_id, .big);
                }
                const bytes = try sessions.packet_api.encodeFor(protocols.implementations, .{ writeSuccess, writeSuccessWithSession }, scope.profile.protocol, output, .{ scope.profile.uuid, scope.profile.name, session_uuid });
                state.stage = .success_sent;
                return .{ .send = bytes };
            },
            .success_sent => return if (state.acknowledged) .done else .wait,
        }
    }

    fn writeSuccess(packet: wire_1_21_5.login.toClient.packet_success.Writer, uuid: u128, name: []const u8, _: u128) ![]u8 {
        const identified = try packet.uuid(uuid);
        const properties = try (try identified.username(name)).properties(0);
        return (try properties.finish()).finish();
    }

    fn writeSuccessWithSession(packet: wire_26_2.login.toClient.packet_success.Writer, uuid: u128, name: []const u8, session_uuid: u128) ![]u8 {
        const identified = try packet.uuid(uuid);
        const properties = try (try identified.username(name)).properties(0);
        return (try (try properties.finish()).sessionId(session_uuid)).finish();
    }

    fn onAcknowledged(_: *LoginSuccess, _: sessions.InputScope, state: *SessionLoginState, packet: wire_1_21_5.login.toServer.packet_login_acknowledged.Reader, _: []u8) !sessions.LoginInputEffect {
        try packet.finish();
        if (state.stage != .success_sent or state.acknowledged) return error.UnexpectedLoginPacket;
        state.acknowledged = true;
        return .none;
    }
};
