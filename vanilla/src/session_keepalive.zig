const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("protocols");

pub const Keepalive = struct {
    pub const id = "minecraft:keepalive";
    pub const Configuration = sessions.Keepalive;
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
    pub const SessionPlayState = struct {
        expected: ?i64 = null,
        due: i96 = 0,
    };
    pub const SessionState = struct { play: SessionPlayState = .{} };

    configuration: Configuration,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Keepalive {
        const self = try allocator.create(Keepalive);
        self.* = .{ .configuration = configuration };
        try deps.input.play.on(.keep_alive, self, onResponse);
        try deps.phases.onPlay(self, onPlay);
        return self;
    }

    fn onResponse(self: *Keepalive, scope: sessions.InputScope, state: *SessionPlayState, packet: wire_1_21_5.play.toServer.packet_keep_alive.Reader, _: []u8) !sessions.PlayInputEffect {
        const value, const done = try packet.keepAliveId();
        try done.finish();
        if (state.expected) |expected| {
            if (value != expected) return error.InvalidKeepalive;
            state.expected = null;
            state.due = scope.now + self.configuration.interval_ns;
        }
        return .none;
    }

    fn onPlay(self: *Keepalive, profile: sessions.Profile, state: *SessionPlayState, event: sessions.protocol.PlayEvent, output: []u8) !?[]const u8 {
        switch (event) {
            .attached => |now| {
                if (self.configuration.interval_ns <= 0 or self.configuration.timeout_ns <= 0) return error.InvalidKeepalivePolicy;
                state.* = .{ .due = now + self.configuration.interval_ns };
            },
            .poll => |now| {
                if (now < state.due) return null;
                if (state.expected != null) return error.KeepaliveTimeout;
                const value: i64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
                state.expected = value;
                state.due = now + self.configuration.timeout_ns;
                return try sessions.packet_api.encodeFor(protocols.implementations, writeKeepalive, profile.protocol, output, .{value});
            },
            .park => state.* = .{},
            .disconnect => state.* = .{},
        }
        return null;
    }

    fn writeKeepalive(packet: wire_1_21_5.play.toClient.packet_keep_alive.Writer, value: i64) ![]u8 {
        return (try packet.keepAliveId(value)).finish();
    }
};
