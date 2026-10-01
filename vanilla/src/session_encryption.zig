const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const LoginEncryption = struct {
    pub const id = "minecraft:login_encryption";
    pub const Key = struct {
        context: *anyopaque,
        public_key_der: []const u8,
        decrypt: *const fn (*anyopaque, std.Io, []const u8, []u8) error{ InvalidCiphertext, CryptoFailure }!void,
    };
    pub const Configuration = struct { key: ?Key = null };
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
    pub const SessionLoginState = struct {
        stage: enum { initial, challenge_sent, complete } = .initial,
        token: [4]u8 = undefined,
        secret: [16]u8 = @splat(0),
    };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    key: ?Key,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*LoginEncryption {
        if (configuration.key) |key| if (key.public_key_der.len == 0 or key.public_key_der.len > 512) return error.InvalidConfiguration;
        const self = try allocator.create(LoginEncryption);
        self.* = .{ .key = configuration.key };
        try deps.input.login.on(.encryption_begin, self, onResponse);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onLogin(self: *LoginEncryption, scope: sessions.PhaseScope, state: *SessionLoginState, _: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        const encryption = self.key orelse return .done;
        switch (state.stage) {
            .initial => {
                try scope.io.randomSecure(&state.token);
                const bytes = try sessions.packet_api.encodeFor(protocols.implementations, writeChallenge, scope.profile.protocol, output, .{ encryption.public_key_der, &state.token });
                state.stage = .challenge_sent;
                return .{ .send = bytes };
            },
            .challenge_sent => return .wait,
            .complete => return .done,
        }
    }

    fn writeChallenge(packet: wire_1_21_5.login.toClient.packet_encryption_begin.Writer, public_key: []const u8, token: *const [4]u8) ![]u8 {
        const a = try packet.serverId("");
        const b = try a.publicKey(public_key);
        const c = try b.verifyToken(token);
        return (try c.shouldAuthenticate(false)).finish();
    }

    fn onResponse(self: *LoginEncryption, scope: sessions.InputScope, state: *SessionLoginState, packet: wire_1_21_5.login.toServer.packet_encryption_begin.Reader, _: []u8) !sessions.LoginInputEffect {
        if (state.stage != .challenge_sent) return error.InvalidEncryption;
        const encrypted_secret, const a = try packet.sharedSecret();
        const encrypted_token, const done = try a.verifyToken();
        try done.finish();
        if (encrypted_secret.len == 0 or encrypted_secret.len > 512 or encrypted_token.len != encrypted_secret.len)
            return error.InvalidEncryption;

        errdefer std.crypto.secureZero(u8, &state.secret);
        var token: [4]u8 = undefined;
        defer std.crypto.secureZero(u8, &token);
        const encryption = self.key orelse return error.InvalidEncryption;
        encryption.decrypt(encryption.context, scope.io, encrypted_secret, &state.secret) catch return error.InvalidEncryption;
        encryption.decrypt(encryption.context, scope.io, encrypted_token, &token) catch return error.InvalidEncryption;
        if (!std.crypto.timing_safe.eql([4]u8, token, state.token)) return error.InvalidEncryption;
        state.stage = .complete;
        return .{ .encryption = &state.secret };
    }
};
