const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const wire_1_21_5 = @import("wire_1_21_5");

pub const Status = struct {
    pub const id = "minecraft:status";
    pub const Dependencies = struct { input: *protocols.Input };
    pub const SessionState = struct {};
    pub const Configuration = struct {
        description: []const u8 = "Lightning Rod",
        version: []const u8 = "Lightning Rod v0.1.0",
        favicon: ?[]const u8 = null,
    };

    configuration: Configuration,

    pub fn init(allocator: std.mem.Allocator, configuration: Configuration, deps: Dependencies) !*Status {
        if (configuration.description.len > 1024 or configuration.version.len > 256 or
            (configuration.favicon != null and configuration.favicon.?.len > 16 * 1024))
            return error.InvalidStatusConfiguration;
        const self = try allocator.create(Status);
        self.* = .{ .configuration = configuration };
        try deps.input.status.on(.ping_start, self, onRequest);
        try deps.input.status.on(.ping, self, onPing);
        return self;
    }

    fn onRequest(
        self: *Status,
        request: sessions.StatusRequest,
        packet: wire_1_21_5.status.toServer.packet_ping_start.Reader,
        output: []u8,
    ) ![]const u8 {
        try packet.finish();
        var storage: [32 * 1024]u8 = undefined;
        var json = std.Io.Writer.fixed(&storage);
        try std.json.Stringify.value(.{
            .version = .{ .name = self.configuration.version, .protocol = request.protocol },
            .players = .{
                .max = request.maximum_players,
                .online = request.online_players,
            },
            .description = .{ .text = self.configuration.description },
            .favicon = self.configuration.favicon,
        }, .{ .emit_null_optional_fields = false }, &json);
        return sessions.packet_api.encodeFor(protocols.implementations, writeResponse, request.protocol, output, .{json.buffered()});
    }

    fn onPing(
        _: *Status,
        request: sessions.StatusRequest,
        packet: wire_1_21_5.status.toServer.packet_ping.Reader,
        output: []u8,
    ) ![]const u8 {
        const time, const done = try packet.time();
        try done.finish();
        return sessions.packet_api.encodeFor(protocols.implementations, writePing, request.protocol, output, .{time});
    }

    fn writeResponse(packet: wire_1_21_5.status.toClient.packet_server_info.Writer, json: []const u8) ![]u8 {
        return (try packet.response(json)).finish();
    }

    fn writePing(packet: wire_1_21_5.status.toClient.packet_ping.Writer, time: i64) ![]u8 {
        return (try packet.time(time)).finish();
    }
};
