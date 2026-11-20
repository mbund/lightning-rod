const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const java = @import("minecraft_java");
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

pub const LoginEncryption = struct {
    pub const id = "minecraft:login_encryption";
    pub const Configuration = struct {
        key: ?*const java.RsaPrivateKey = null,
        /// Asks clients to prove to Mojang that they joined, as online mode does.
        authenticate: bool = false,
    };
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases, profiles: *sessions.Profiles };
    pub const SessionLoginState = struct {
        stage: enum { initial, challenge_sent, verifying, complete } = .initial,
        token: [4]u8 = undefined,
        key: ?*const java.RsaPrivateKey = null,
        // The connection retains its input until the verification task completes.
        encrypted_secret: []const u8 = &.{},
        encrypted_token: []const u8 = &.{},
        server_hash: [20]u8 = undefined,
    };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    key: ?*const java.RsaPrivateKey,
    authenticate: bool,
    profiles: *sessions.Profiles,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*LoginEncryption {
        if (configuration.authenticate and configuration.key == null) return error.AuthenticationNeedsEncryption;
        const self = try allocator.create(LoginEncryption);
        self.* = .{ .key = configuration.key, .authenticate = configuration.authenticate, .profiles = deps.profiles };
        try deps.input.login.on(.encryption_begin, self, onResponse);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onLogin(self: *LoginEncryption, scope: sessions.PhaseScope, state: *SessionLoginState, _: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        const encryption = self.key orelse return .done;
        switch (state.stage) {
            .initial => {
                try scope.io.randomSecure(&state.token);
                const bytes = try sessions.packet_api.encodeFor(protocols.implementations, writeChallenge, scope.profile.protocol, output, .{ encryption.publicKey(), &state.token, self.authenticate });
                state.stage = .challenge_sent;
                return .{ .send = bytes };
            },
            .challenge_sent, .verifying => return .wait,
            .complete => {
                // What authentication asks Mojang about, for the connection it belongs to.
                self.profiles.of(scope.profile.connection).server_hash = state.server_hash;
                return .done;
            },
        }
    }

    fn writeChallenge(packet: wire_1_21_5.login.toClient.packet_encryption_begin.Writer, public_key: []const u8, token: *const [4]u8, authenticate: bool) ![]u8 {
        const a = try packet.serverId(server_id);
        const b = try a.publicKey(public_key);
        const c = try b.verifyToken(token);
        return (try c.shouldAuthenticate(authenticate)).finish();
    }

    fn onResponse(self: *LoginEncryption, _: sessions.InputScope, state: *SessionLoginState, packet: wire_1_21_5.login.toServer.packet_encryption_begin.Reader, _: []u8) !sessions.LoginInputEffect {
        if (state.stage != .challenge_sent) return error.InvalidEncryption;
        const encrypted_secret, const a = try packet.sharedSecret();
        const encrypted_token, const done = try a.verifyToken();
        try done.finish();
        if (encrypted_secret.len != java.RsaPrivateKey.ciphertext_bytes or encrypted_token.len != encrypted_secret.len)
            return error.InvalidEncryption;

        state.key = self.key orelse return error.InvalidEncryption;
        state.encrypted_secret = encrypted_secret;
        state.encrypted_token = encrypted_token;
        state.stage = .verifying;
        return .{ .verify = sessions.protocol.LoginVerification.init(state, verify) };
    }

    fn verify(state: *SessionLoginState) ![16]u8 {
        std.debug.assert(state.stage == .verifying);
        defer state.encrypted_secret = &.{};
        defer state.encrypted_token = &.{};
        var secret: [16]u8 = undefined;
        errdefer std.crypto.secureZero(u8, &secret);
        var token: [4]u8 = undefined;
        defer std.crypto.secureZero(u8, &token);
        const encryption = state.key.?;
        encryption.decrypt(state.encrypted_secret, &secret) catch return error.InvalidEncryption;
        encryption.decrypt(state.encrypted_token, &token) catch return error.InvalidEncryption;
        if (!std.crypto.timing_safe.eql([4]u8, token, state.token)) return error.InvalidEncryption;
        state.server_hash = serverHash(&secret, encryption.publicKey());
        state.stage = .complete;
        return secret;
    }
};

/// Vanilla servers send no server id; the hash still covers it.
const server_id = "";

/// What client and server each tell Mojang the client joined: SHA-1 over the server id, the
/// shared secret and the server's public key.
fn serverHash(secret: *const [16]u8, public_key: []const u8) [20]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(server_id);
    hash.update(secret);
    hash.update(public_key);
    var digest: [20]u8 = undefined;
    hash.final(&digest);
    return digest;
}
