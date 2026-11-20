const std = @import("std");
const lightning_rod = @import("lightning_rod");
const sessions = @import("sessions");
const Disconnect = @import("session_disconnect.zig").Disconnect;
const mojang_sessions = @import("mojang_sessions.zig");
const Authenticator = mojang_sessions.Authenticator;

/// Who a connecting player is. Offline, the UUID follows from the name, as vanilla's does. Online,
/// Mojang's session server says whether the player joined with the hash encryption gave both
/// sides, and with what UUID, name and skin; login waits for its answer without the sessions
/// thread waiting.
pub const Authentication = struct {
    pub const id = "minecraft:authentication";
    pub const Configuration = struct {
        online: bool = false,
        session_host: []const u8 = "https://sessionserver.mojang.com",
        /// Mojang questions asked at once; logins past this wait their turn.
        workers: u16 = 16,
        timeout: std.Io.Duration = .fromSeconds(10),

        fn options(self: Configuration) mojang_sessions.Options {
            return .{ .session_host = self.session_host, .workers = self.workers, .timeout = self.timeout };
        }
    };
    pub const Dependencies = struct {
        phases: *sessions.Phases,
        profiles: *sessions.Profiles,
        wake: *sessions.Wake,
        disconnect: *Disconnect,
    };
    pub const SessionLoginState = struct { asked: bool = false };
    pub const SessionState = struct { login: SessionLoginState = .{} };

    deps: Dependencies,
    authenticator: ?*Authenticator,

    /// Online mode's workers, queue and root certificates, which grow with the server.
    pub fn memoryBytes(configuration: Configuration, connections: usize) usize {
        return if (configuration.online) Authenticator.memoryBytes(configuration.options(), connections) else 0;
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, configuration: Configuration, deps: Dependencies) !*Authentication {
        const self = try allocator.create(Authentication);
        const authenticator = if (configuration.online) try Authenticator.init(allocator, io, configuration.options(), deps.profiles.entries.len, deps.wake) else null;
        self.* = .{ .deps = deps, .authenticator = authenticator };
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    pub fn close(self: *Authentication, closing: *lightning_rod.Closing) void {
        const token = closing.begin();
        defer token.finish();
        if (self.authenticator) |authenticator| authenticator.close();
    }

    fn onLogin(self: *Authentication, scope: sessions.PhaseScope, state: *SessionLoginState, _: sessions.PhaseEvent, output: []u8) !sessions.LoginStep {
        const authenticator = self.authenticator orelse {
            try scope.authenticate(offlineUuid(scope.profile.name));
            return .done;
        };
        const connection = scope.profile.connection;
        if (!state.asked) {
            // Encryption runs first, and leaves the hash both sides tell Mojang.
            const server_hash = self.deps.profiles.of(connection).server_hash orelse return error.Unencrypted;
            authenticator.ask(connection, scope.profile.name, server_hash) catch |err| {
                std.log.warn("event=authentication_not_asked connection={d}:{d} reason={t}", .{ connection.index, connection.generation, err });
                return .{ .reject = try self.deps.disconnect.login(scope.profile.protocol, unavailable_message, output) };
            };
            state.asked = true;
            return .wait;
        }
        const answer = authenticator.answer(connection) orelse return .wait;
        switch (answer) {
            .joined => |profile| {
                // Mojang matches names without regard to case; the name stays as the client gave it.
                if (!std.ascii.eqlIgnoreCase(profile.nameText(), scope.profile.name)) return .{ .reject = try self.deps.disconnect.login(scope.profile.protocol, unverified_message, output) };
                try scope.authenticate(profile.uuid);
                if (profile.textures_value_len != 0) try self.deps.profiles.of(connection).setTextures(profile.textures_value[0..profile.textures_value_len], profile.textures_signature[0..profile.textures_signature_len]);
                return .done;
            },
            .unverified => return .{ .reject = try self.deps.disconnect.login(scope.profile.protocol, unverified_message, output) },
            .unavailable => return .{ .reject = try self.deps.disconnect.login(scope.profile.protocol, unavailable_message, output) },
        }
    }

    // Vanilla's English texts for multiplayer.disconnect.unverified_username and authservers_down.
    const unverified_message = "Failed to verify username!";
    const unavailable_message = "Authentication servers are down. Please try again later, sorry!";
};

/// The UUID vanilla gives a player in offline mode: a version 3 UUID of "OfflinePlayer:" and the name.
pub fn offlineUuid(name: []const u8) u128 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update("OfflinePlayer:");
    hash.update(name);
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}

test "offline players get vanilla's UUID for their name" {
    try std.testing.expectEqual(@as(u128, 0xb50ad385829d3141a2167e7d7539ba7f), offlineUuid("Notch"));
}

test {
    _ = mojang_sessions;
}
