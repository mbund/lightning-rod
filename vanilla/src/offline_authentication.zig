const std = @import("std");
const sessions = @import("sessions");

pub const OfflineAuthentication = struct {
    pub const id = "minecraft:offline_authentication";
    pub const Configuration = struct {};
    pub const Dependencies = struct { phases: *sessions.Phases };
    pub const SessionLoginState = struct {};
    pub const SessionState = struct { login: SessionLoginState = .{} };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*OfflineAuthentication {
        const self = try allocator.create(OfflineAuthentication);
        try deps.phases.onLogin(self, onLogin);
        return self;
    }

    fn onLogin(
        _: *OfflineAuthentication,
        scope: sessions.PhaseScope,
        _: *SessionLoginState,
        event: sessions.PhaseEvent,
        _: []u8,
    ) !sessions.LoginStep {
        if (event != .begin) return error.UnexpectedLoginEvent;

        var hash = std.crypto.hash.Md5.init(.{});
        hash.update("OfflinePlayer:");
        hash.update(scope.profile.name);
        var digest: [16]u8 = undefined;
        hash.final(&digest);
        digest[6] = (digest[6] & 15) | 0x30;
        digest[8] = (digest[8] & 63) | 0x80;
        try scope.authenticate(std.mem.readInt(u128, &digest, .big));
        return .done;
    }
};
