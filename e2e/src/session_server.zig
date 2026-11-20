//! A session server standing in for Mojang's, for online mode scenarios. Clients join through it
//! and the server asks it whether they did, so a scenario checks that both sides computed the same
//! server hash. It knows each player under the UUID `onlineUuid` gives their name, and refuses
//! `rejected_name` whatever it joined with.
const std = @import("std");

pub const rejected_name = "mallory";
/// The textures property it gives every player it knows, unsigned for lack of Mojang's key.
pub const textures_value = "eyJ0ZXh0dXJlcyI6e319";

pub const SessionServer = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    serving: ?std.Io.Future(std.Io.Cancelable!void) = null,
    connections: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    joined: [16]Hash = undefined,
    joined_count: usize = 0,
    host_bytes: [64]u8 = undefined,
    host_len: usize = 0,

    const Hash = struct { bytes: [41]u8 = undefined, len: usize = 0 };

    pub fn start(self: *SessionServer, io: std.Io) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{ .io = io, .listener = try address.listen(io, .{}) };
        errdefer self.listener.deinit(io);
        self.host_len = (try std.fmt.bufPrint(&self.host_bytes, "http://127.0.0.1:{d}", .{self.listener.socket.address.getPort()})).len;
        self.serving = try io.concurrent(serve, .{self});
    }

    pub fn stop(self: *SessionServer) void {
        if (self.serving) |*serving| serving.cancel(self.io) catch {};
        self.connections.cancel(self.io);
        self.listener.deinit(self.io);
    }

    pub fn host(self: *const SessionServer) []const u8 {
        return self.host_bytes[0..self.host_len];
    }

    fn serve(self: *SessionServer) std.Io.Cancelable!void {
        while (true) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => continue,
            };
            self.connections.concurrent(self.io, connection, .{ self, stream }) catch stream.close(self.io);
        }
    }

    fn connection(self: *SessionServer, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        defer stream.close(self.io);
        var input: [8192]u8 = undefined;
        var output: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &input);
        var writer = stream.writer(self.io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = server.receiveHead() catch return;
            self.answer(&request) catch return;
        }
    }

    fn answer(self: *SessionServer, request: *std.http.Server.Request) !void {
        const target = request.head.target;
        if (request.head.method == .POST and std.mem.eql(u8, target, "/session/minecraft/join")) {
            var body: [4096]u8 = undefined;
            const reader = request.readerExpectNone(&body);
            const json = try reader.allocRemaining(std.heap.smp_allocator, .limited(4096));
            defer std.heap.smp_allocator.free(json);
            const Join = struct { serverId: []const u8 };
            const parsed = try std.json.parseFromSlice(Join, std.heap.smp_allocator, json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!self.remember(parsed.value.serverId)) return request.respond("", .{ .status = .bad_request });
            std.log.info("event=session_join server_id={s}", .{parsed.value.serverId});
            return request.respond("", .{ .status = .no_content });
        }
        const prefix = "/session/minecraft/hasJoined?username=";
        if (request.head.method == .GET and std.mem.startsWith(u8, target, prefix)) {
            const query = target[prefix.len..];
            const split = std.mem.indexOf(u8, query, "&serverId=") orelse return request.respond("", .{ .status = .bad_request });
            const name = query[0..split];
            const server_id = query[split + "&serverId=".len ..];
            const known = self.joinedWith(server_id);
            std.log.info("event=session_has_joined name={s} server_id={s} joined={}", .{ name, server_id, known });
            if (!known or std.mem.eql(u8, name, rejected_name) or name.len == 0 or name.len > 16) return request.respond("", .{ .status = .no_content });
            var response: [512]u8 = undefined;
            const json = try std.fmt.bufPrint(&response,
                \\{{"id":"{x:0>32}","name":"{s}","properties":[{{"name":"textures","value":"{s}"}}]}}
            , .{ onlineUuid(name), name, textures_value });
            return request.respond(json, .{ .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        }
        return request.respond("", .{ .status = .not_found });
    }

    fn remember(self: *SessionServer, server_id: []const u8) bool {
        if (server_id.len == 0 or server_id.len > 41) return false;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.joined_count == self.joined.len) return false;
        const slot = &self.joined[self.joined_count];
        @memcpy(slot.bytes[0..server_id.len], server_id);
        slot.len = server_id.len;
        self.joined_count += 1;
        return true;
    }

    fn joinedWith(self: *SessionServer, server_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.joined[0..self.joined_count]) |hash| if (std.mem.eql(u8, hash.bytes[0..hash.len], server_id)) return true;
        return false;
    }
};

/// The UUID this session server knows a player by: what Java's UUID.nameUUIDFromBytes gives for
/// "OnlinePlayer:" and the name, so fixtures compute it the same way, and never the offline one.
pub fn onlineUuid(name: []const u8) u128 {
    var hash = std.crypto.hash.Md5.init(.{});
    hash.update("OnlinePlayer:");
    hash.update(name);
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    digest[6] = (digest[6] & 15) | 0x30;
    digest[8] = (digest[8] & 63) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}

test "answers whether a player joined with the hash they gave" {
    const io = std.testing.io;
    var server: SessionServer = undefined;
    try server.start(io);
    defer server.stop();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var url: [256]u8 = undefined;

    const join = try client.fetch(.{
        .location = .{ .url = try std.fmt.bufPrint(&url, "{s}/session/minecraft/join", .{server.host()}) },
        .method = .POST,
        .payload = "{\"accessToken\":\"x\",\"selectedProfile\":\"y\",\"serverId\":\"-7c9d\"}",
    });
    try std.testing.expectEqual(std.http.Status.no_content, join.status);

    var body: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&body);
    const joined = try client.fetch(.{ .location = .{ .url = try std.fmt.bufPrint(&url, "{s}/session/minecraft/hasJoined?username=alice&serverId=-7c9d", .{server.host()}) }, .response_writer = &writer });
    try std.testing.expectEqual(std.http.Status.ok, joined.status);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), textures_value) != null);

    const unknown = try client.fetch(.{ .location = .{ .url = try std.fmt.bufPrint(&url, "{s}/session/minecraft/hasJoined?username=alice&serverId=1234", .{server.host()}) } });
    try std.testing.expectEqual(std.http.Status.no_content, unknown.status);
    const rejected = try client.fetch(.{ .location = .{ .url = try std.fmt.bufPrint(&url, "{s}/session/minecraft/hasJoined?username=mallory&serverId=-7c9d", .{server.host()}) } });
    try std.testing.expectEqual(std.http.Status.no_content, rejected.status);
}
