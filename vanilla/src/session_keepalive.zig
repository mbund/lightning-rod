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
            .poll => |poll| {
                const now = poll.now;
                defer poll.wakeAt(state.due);
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

test "keepalive deadlines follow attachment, send, response, timeout, and parking" {
    const interval = 10 * std.time.ns_per_s;
    const timeout = 30 * std.time.ns_per_s;
    var keepalive: Keepalive = .{ .configuration = .{ .interval_ns = interval, .timeout_ns = timeout } };
    const profile: sessions.Profile = .{ .connection = .{ .index = 0, .generation = 1 }, .protocol = protocols.implementations[0].protocol_number, .uuid = 1, .name = "alice" };
    var state: Keepalive.SessionPlayState = .{};
    var output: [128]u8 = undefined;
    try std.testing.expectEqual(null, try keepalive.onPlay(profile, &state, .{ .attached = 1 }, &output));

    var poll: sessions.protocol.Poll = .{ .now = 1 };
    try std.testing.expectEqual(null, try keepalive.onPlay(profile, &state, .{ .poll = &poll }, &output));
    try std.testing.expectEqual(@as(?i96, 1 + interval), poll.deadline);

    poll = .{ .now = state.due };
    try std.testing.expect((try keepalive.onPlay(profile, &state, .{ .poll = &poll }, &output)) != null);
    try std.testing.expectEqual(@as(?i96, poll.now + timeout), poll.deadline);
    const expected = state.expected.?;

    var response: [128]u8 = undefined;
    const writer = try wire_1_21_5.play.toServer.write(&response).keep_alive();
    const bytes = (try writer.keepAliveId(expected)).finish();
    const header = try wire_1_21_5.play.toServer.readHeader(bytes);
    const now = poll.now + std.time.ns_per_s;
    const packet: wire_1_21_5.play.toServer.packet_keep_alive.Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body } };
    _ = try keepalive.onResponse(.{ .profile = profile, .io = std.testing.io, .now = now }, &state, packet, &output);
    try std.testing.expectEqual(null, state.expected);
    poll = .{ .now = now };
    try std.testing.expectEqual(null, try keepalive.onPlay(profile, &state, .{ .poll = &poll }, &output));
    try std.testing.expectEqual(@as(?i96, now + interval), poll.deadline);

    poll = .{ .now = state.due };
    try std.testing.expect((try keepalive.onPlay(profile, &state, .{ .poll = &poll }, &output)) != null);
    poll = .{ .now = state.due };
    try std.testing.expectError(error.KeepaliveTimeout, keepalive.onPlay(profile, &state, .{ .poll = &poll }, &output));
    try std.testing.expectEqual(null, try keepalive.onPlay(profile, &state, .park, &output));
    try std.testing.expectEqualDeep(Keepalive.SessionPlayState{}, state);
}
