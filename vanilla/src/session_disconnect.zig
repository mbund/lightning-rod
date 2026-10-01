const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");

pub const Disconnect = struct {
    pub const id = "minecraft:disconnect";
    pub const Configuration = struct {};
    pub const Dependencies = struct { phases: *sessions.Phases };
    pub const SessionPlayState = struct {};
    pub const SessionState = struct { play: SessionPlayState = .{} };

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Disconnect {
        const self = try allocator.create(Disconnect);
        try deps.phases.onPlay(self, onPlay);
        return self;
    }

    pub fn login(_: *Disconnect, protocol: i32, message: []const u8, output: []u8) ![]const u8 {
        var buffer: [2048]u8 = undefined;
        var json = std.Io.Writer.fixed(&buffer);
        try std.json.Stringify.value(.{ .text = message }, .{}, &json);
        return sessions.packet_api.encodeFor(protocols.implementations, writeLoginDisconnect, protocol, output, .{json.buffered()});
    }

    fn onPlay(_: *Disconnect, profile: sessions.Profile, _: *SessionPlayState, event: sessions.protocol.PlayEvent, output: []u8) !?[]const u8 {
        const message = switch (event) {
            .disconnect => |text| text,
            .attached, .poll, .park => return null,
        };
        var component: [1024]u8 = undefined;
        if (message.len > component.len - 3) return error.BufferTooSmall;
        component[0] = 8;
        std.mem.writeInt(u16, component[1..3], @intCast(message.len), .big);
        @memcpy(component[3..][0..message.len], message);
        return try sessions.packet_api.encodeFor(protocols.implementations, writePlayDisconnect, profile.protocol, output, .{component[0 .. 3 + message.len]});
    }

    fn writeLoginDisconnect(packet: wire_1_21_5.login.toClient.packet_disconnect.Writer, json: []const u8) ![]u8 {
        return (try packet.reason(json)).finish();
    }

    fn writePlayDisconnect(packet: wire_1_21_5.play.toClient.packet_kick_disconnect.Writer, component: []const u8) ![]u8 {
        return (try packet.reason(component)).finish();
    }
};
