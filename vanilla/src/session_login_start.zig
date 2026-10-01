const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const LoginStart = struct {
    pub const id = "minecraft:login_start";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
    pub const SessionLoginState = struct { received: bool = false };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*LoginStart {
        const self = try allocator.create(LoginStart);
        try deps.input.login.on(.login_start, self, onStart);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onStart(_: *LoginStart, _: sessions.InputScope, state: *SessionLoginState, packet: wire_1_21_5.login.toServer.packet_login_start.Reader, _: []u8) !sessions.LoginInputEffect {
        const name, const a = try packet.username();
        _, const done = try a.playerUUID();
        try done.finish();

        if (name.len == 0 or name.len > 16) return error.InvalidName;
        for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidName;
        if (state.received) return error.UnexpectedLoginPacket;
        state.received = true;
        return .{ .name = name };
    }

    fn onLogin(_: *LoginStart, _: sessions.PhaseScope, state: *SessionLoginState, _: sessions.PhaseEvent, _: []u8) !sessions.LoginStep {
        return if (state.received) .done else .wait;
    }
};
