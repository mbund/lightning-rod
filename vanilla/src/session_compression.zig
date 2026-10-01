const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");

pub const LoginCompression = struct {
    pub const id = "minecraft:login_compression";
    pub const Configuration = struct {};
    pub const Dependencies = struct { phases: *sessions.Phases };
    pub const SessionLoginState = struct {
        stage: enum { initial, sent, enabled } = .initial,
    };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*LoginCompression {
        const self = try allocator.create(LoginCompression);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onLogin(_: *LoginCompression, scope: sessions.PhaseScope, state: *SessionLoginState, _: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        switch (state.stage) {
            .initial => {
                const threshold = scope.compression_threshold orelse return .done;
                if (threshold > std.math.maxInt(i32)) return error.InvalidCompressionThreshold;
                const bytes = try sessions.packet_api.encodeFor(protocols.implementations, writeCompression, scope.profile.protocol, output, .{@as(i32, @intCast(threshold))});
                state.stage = .sent;
                return .{ .send = bytes };
            },
            .sent => {
                state.stage = .enabled;
                return .enable_compression;
            },
            .enabled => return .done,
        }
    }

    fn writeCompression(packet: wire_1_21_5.login.toClient.packet_compress.Writer, threshold: i32) ![]u8 {
        return (try packet.threshold(threshold)).finish();
    }
};
