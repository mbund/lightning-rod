const std = @import("std");
const wire_1_21_5 = @import("wire_1_21_5");
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

/// Answers a client's ping requests in play with their own ids, as vanilla does from its network
/// thread rather than in a tick, which a client times for the ping it shows. An answer goes once
/// the connection's output is free, behind what it was already sending, as vanilla's goes behind
/// what its connection had queued.
pub const Ping = struct {
    pub const id = "minecraft:ping";
    pub const Configuration = struct {};
    pub const Dependencies = struct { input: *protocols.Input, phases: *sessions.Phases };
    /// Requests not yet answered, oldest first. A client sends one at a time, waiting for each
    /// answer, so a few are room enough, and a client sending more loses the newest.
    pub const SessionPlayState = struct {
        pending: [4]i64 = undefined,
        count: u8 = 0,
    };
    pub const SessionState = struct { play: SessionPlayState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Ping {
        const self = try allocator.create(Ping);
        try deps.input.play.on(.ping_request, self, onRequest);
        try deps.phases.onPlay(self, onPlay);
        return self;
    }

    fn onRequest(_: *Ping, _: sessions.InputScope, state: *SessionPlayState, packet: wire_1_21_5.play.toServer.packet_ping_request.Reader, _: []u8) !sessions.PlayInputEffect {
        const value, const done = try packet.id();
        try done.finish();
        if (state.count == state.pending.len) return .none;
        state.pending[state.count] = value;
        state.count += 1;
        return .poll;
    }

    fn onPlay(_: *Ping, profile: sessions.Profile, state: *SessionPlayState, event: sessions.protocol.PlayEvent, output: []u8) !?[]const u8 {
        switch (event) {
            .attached, .park, .disconnect => state.* = .{},
            .poll => {
                if (state.count == 0) return null;
                const value = state.pending[0];
                std.mem.copyForwards(i64, state.pending[0 .. state.count - 1], state.pending[1..state.count]);
                state.count -= 1;
                return try sessions.packet_api.encodeFor(protocols.implementations, writeResponse, profile.protocol, output, .{value});
            },
        }
        return null;
    }

    fn writeResponse(packet: wire_1_21_5.play.toClient.packet_ping_response.Writer, value: i64) ![]u8 {
        return (try packet.id(value)).finish();
    }
};

fn request(buffer: []u8, value: i64) !wire_1_21_5.play.toServer.packet_ping_request.Reader {
    const bytes = (try (try wire_1_21_5.play.toServer.write(buffer).ping_request()).id(value)).finish();
    const header = try wire_1_21_5.play.toServer.readHeader(bytes);
    return .{ ._cursor = .{ .buffer = header.body, .rest = header.body } };
}

fn answered(bytes: []const u8) !i64 {
    const header = try wire_1_21_5.play.toClient.readHeader(bytes);
    const reader: wire_1_21_5.play.toClient.packet_ping_response.Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body } };
    const value, const done = try reader.id();
    try done.finish();
    return value;
}

test "ping requests are answered with their own ids in order, once output is free" {
    var ping: Ping = .{};
    const profile: sessions.Profile = .{ .connection = .{ .index = 0, .generation = 1 }, .protocol = protocols.implementations[0].protocol_number, .uuid = 1, .name = "alice" };
    const scope: sessions.InputScope = .{ .profile = profile, .io = std.testing.io, .now = 0 };
    var state: Ping.SessionPlayState = .{};
    var buffer: [64]u8 = undefined;
    var output: [64]u8 = undefined;
    try std.testing.expectEqual(null, try ping.onPlay(profile, &state, .{ .attached = 1 }, &output));
    try std.testing.expectEqual(sessions.PlayInputEffect.poll, try ping.onRequest(scope, &state, try request(&buffer, -1234567890123), &output));
    try std.testing.expectEqual(sessions.PlayInputEffect.poll, try ping.onRequest(scope, &state, try request(&buffer, 7), &output));

    var poll: sessions.protocol.Poll = .{ .now = 1 };
    try std.testing.expectEqual(@as(i64, -1234567890123), try answered((try ping.onPlay(profile, &state, .{ .poll = &poll }, &output)).?));
    try std.testing.expectEqual(@as(i64, 7), try answered((try ping.onPlay(profile, &state, .{ .poll = &poll }, &output)).?));
    try std.testing.expectEqual(null, try ping.onPlay(profile, &state, .{ .poll = &poll }, &output));

    // Requests past the room are dropped, and parking forgets the rest.
    for (0..6) |index| _ = try ping.onRequest(scope, &state, try request(&buffer, @intCast(index)), &output);
    try std.testing.expectEqual(@as(u8, 4), state.count);
    try std.testing.expectEqual(null, try ping.onPlay(profile, &state, .park, &output));
    try std.testing.expectEqual(@as(u8, 0), state.count);
}
