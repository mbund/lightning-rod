const lightning_rod = @import("lightning_rod");
const std = @import("std");

pub const Status = struct {
    pub const id = "minecraft:status";
    pub const Dependencies = struct {
        players: *lightning_rod.players.Players,
        sessions: *lightning_rod.sessions.Sessions,
    };
    pub const Configuration = struct {
        motd: []const u8 = "Lightning Rod",
        version_name: []const u8 = "Lightning Rod v" ++ lightning_rod.version,
        protocol: i32 = 772,
        maximum_players: ?u16 = null,
        favicon: ?[]const u8 = null,
        maximum_json_bytes: usize = 512,

        pub fn validate(self: Configuration) !void {
            if (self.maximum_json_bytes == 0) return error.InvalidStatusCapacity;
            if (self.motd.len > self.maximum_json_bytes or self.version_name.len > self.maximum_json_bytes) return error.InvalidStatusText;
            if (self.favicon) |favicon| if (favicon.len > self.maximum_json_bytes) return error.InvalidStatusText;
        }
    };

    deps: Dependencies,
    configuration: Configuration,
    json: []u8,
    json_len: usize = 0,
    online: usize = 0,
    revision: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies, configuration: Configuration) !*Status {
        try configuration.validate();
        const self = try allocator.create(Status);
        self.* = .{
            .deps = deps,
            .configuration = configuration,
            .json = try allocator.alloc(u8, configuration.maximum_json_bytes),
        };
        self.online = onlinePlayers(deps.players);
        try self.writeSnapshot();
        try deps.sessions.status(self.runtimeStatus());
        return self;
    }

    pub fn tick(self: *Status, _: std.mem.Allocator) void {
        const online = onlinePlayers(self.deps.players);
        if (online == self.online) return;
        self.online = online;
        self.writeSnapshot() catch @panic("configured status JSON buffer is too small");
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    pub fn runtimeStatus(self: *const Status) lightning_rod.sessions.Status {
        return .{ .context = self, .vtable = &.{ .snapshot = snapshot } };
    }

    fn snapshot(context: *const anyopaque) lightning_rod.session_api.StatusSnapshot {
        const self: *const Status = @ptrCast(@alignCast(context));
        return .{ .revision = self.revision, .json = self.json[0..self.json_len] };
    }

    fn writeSnapshot(self: *Status) !void {
        var writer = Writer{ .buffer = self.json };
        try writer.bytes("{\"version\":{\"name\":\"");
        try writer.json(self.configuration.version_name);
        try writer.bytes("\",\"protocol\":");
        try writer.integer(self.configuration.protocol);
        try writer.bytes("},\"players\":{\"max\":");
        try writer.integer(self.maximumPlayers());
        try writer.bytes(",\"online\":");
        try writer.integer(self.online);
        try writer.bytes("},\"description\":{\"text\":\"");
        try writer.json(self.configuration.motd);
        try writer.bytes("\"}");
        if (self.configuration.favicon) |favicon| {
            try writer.bytes(",\"favicon\":\"");
            try writer.json(favicon);
            try writer.bytes("\"");
        }
        try writer.bytes("}");
        self.json_len = writer.len;
    }

    fn maximumPlayers(self: *const Status) usize {
        return self.configuration.maximum_players orelse self.deps.players.active_slots.len;
    }
};

const Writer = struct {
    buffer: []u8,
    len: usize = 0,

    fn bytes(self: *Writer, value: []const u8) !void {
        if (value.len > self.buffer.len - self.len) return error.EndOfStream;
        @memcpy(self.buffer[self.len..][0..value.len], value);
        self.len += value.len;
    }

    fn integer(self: *Writer, value: anytype) !void {
        var storage: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&storage, "{d}", .{value});
        try self.bytes(text);
    }

    fn json(self: *Writer, value: []const u8) !void {
        for (value) |byte| switch (byte) {
            '\\' => try self.bytes("\\\\"),
            '"' => try self.bytes("\\\""),
            '\n' => try self.bytes("\\n"),
            '\r' => try self.bytes("\\r"),
            '\t' => try self.bytes("\\t"),
            0...8, 11...12, 14...31 => try self.control(byte),
            else => try self.bytes(&.{byte}),
        };
    }

    fn control(self: *Writer, byte: u8) !void {
        const hex = "0123456789abcdef";
        try self.bytes("\\u00");
        try self.bytes(&.{ hex[byte >> 4], hex[byte & 15] });
    }
};

fn onlinePlayers(players: *const lightning_rod.players.Players) usize {
    var count: usize = 0;
    for (players.records) |player| {
        if (player.state == .play) count += 1;
    }
    return count;
}

test "status JSON is bounded, escaped, and revised only for content changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const events = try lightning_rod.player_lifecycle.Events.init(arena.allocator(), .{});
    const worlds = try lightning_rod.worlds.Worlds.init(arena.allocator(), .{ .initial = &.{.{
        .key = .{ .value = 1 },
        .name = "test:overworld",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }}, .maximum_worlds = 1 });
    const players = try lightning_rod.players.Players.init(arena.allocator(), .{ .events = events, .worlds = worlds }, .{ .initial_world = .{ .value = 1 }, .maximum_connections = 2, .maximum_players = 2 });
    var session_settings = lightning_rod.sessions.Sessions.init(772);
    const status = try Status.init(arena.allocator(), .{ .players = players, .sessions = &session_settings }, .{ .motd = "A \"quoted\" line\n", .maximum_json_bytes = 256 });
    const initial = status.runtimeStatus().snapshot();
    status.tick(arena.allocator());
    try std.testing.expectEqual(initial.revision, status.runtimeStatus().snapshot().revision);
    players.records[0].state = .play;
    status.tick(arena.allocator());
    const changed = status.runtimeStatus().snapshot();
    try std.testing.expect(changed.revision != initial.revision);
    try std.testing.expect(std.mem.indexOf(u8, changed.json, "\\\"quoted\\\"") != null);
}
