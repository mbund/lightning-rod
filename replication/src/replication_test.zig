//! Player replication at scale: slots drain before reuse, late joins, per-observer visibility,
//! chat and game mode changes, crowds that never cost anyone their connection, and observers
//! that fall behind catching up with relative moves.

const std = @import("std");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const protocols = @import("minecraft_packets").protocols;
const minecraft = @import("minecraft_model");
const Players = @import("players").players.Players;
const Replication = @import("replication.zig").Replication;
const Visibility = @import("visibility.zig").Visibility;
const Tracking = @import("tracking.zig").Tracking;

const Client = protocols.implementations[0].Protocol.play.toClient;

/// How many packets of each id each client received.
const Log = struct {
    ids: [][256]u32,
    counts: []usize,

    fn clear(self: *Log) void {
        @memset(self.counts, 0);
        for (self.ids) |*client| @memset(client, 0);
    }

    fn count(self: *const Log, client: usize, id: i32) usize {
        return self.ids[client][@intCast(id)];
    }
};

const Fixture = struct {
    service: *sessions.Service,
    players: Players,
    visibility: *Visibility,
    replication: *Replication,
    log: Log,
    modes: []minecraft.GameMode,

    const Rules = struct {
        fn gameMode(self: *Fixture, slot: usize) minecraft.GameMode {
            return self.modes[slot];
        }
        fn spawnWorld(_: *Fixture) u32 {
            return 0;
        }
        fn spawnPoint(_: *Fixture, _: *const Players.Player) anyerror!?Players.Rules.Spawn {
            return null;
        }
    };

    fn init(self: *Fixture, allocator: std.mem.Allocator, count: usize) !void {
        const selected = comptime definitions: {
            var result: [protocols.implementations.len]sessions.Protocol = undefined;
            for (protocols.implementations, 0..) |Version, i| result[i] = .{ .number = Version.protocol_number };
            break :definitions result;
        };
        const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = count, .pages = 64 * count, .page_bytes = 4096, .credit_bytes = 4 * 1024 * 1024, .protocols = &selected });
        const records = try allocator.alloc(Players.Player, count);
        for (records, 0..) |*player, index| {
            player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .protocol = selected[0].number, .name = @splat('a'), .name_len = 1, .stage = .ready, .loaded = true, .on_ground = true, .position = .{ .x = 8, .y = 65, .z = 8 } };
            service.occupied[index].store(true, .release);
        }
        self.* = .{
            .service = service,
            .players = .{ .deps = .{ .sessions = service, .packets = try packets.Packets.init(allocator, .{ .sessions = service }), .input = undefined, .storage = undefined, .worlds = undefined, .record_workspaces = undefined }, .config = .{ .maximum = count, .render_distance = 2 }, .spawn_world = 0, .records = records, .dig_handlers = &.{} },
            .visibility = undefined,
            .replication = undefined,
            .log = .{ .ids = try allocator.alloc([256]u32, count), .counts = try allocator.alloc(usize, count) },
            .modes = try allocator.alloc(minecraft.GameMode, count),
        };
        @memset(self.modes, .survival);
        self.log.clear();
        try self.players.initIndexes(allocator);
        self.players.rebuildIndexes();
        self.players.setRules(.init(Fixture, self, Rules.gameMode, Rules.spawnWorld, Rules.spawnPoint));
        self.visibility = try Visibility.init(allocator, .{}, .{ .players = &self.players });
        self.replication = try Replication.init(allocator, .{ .update_interval = 1 }, .{ .players = &self.players, .visibility = self.visibility, .tracking = try Tracking.forTests(allocator, &self.players) });
        for (0..count) |index| self.open(index, true);
    }

    /// Whether a client has room for output.
    fn open(self: *Fixture, index: usize, room: bool) void {
        const generation: u64 = if (self.players.records[index].handle) |handle| handle.generation else 1;
        self.service.credit[index].store(generation << 32 | sessions.Service.active | (if (room) self.service.config.credit_bytes else 0), .release);
    }

    fn step(self: *Fixture) !void {
        self.players.rebuildIndexes();
        self.visibility.tick();
        try self.replication.deps.tracking.tick();
        try self.replication.tick();
        while (self.service.output.takeReady()) |packet| {
            const id = (try Client.readHeader(packet.bytes)).id;
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |recipient| {
                self.log.ids[recipient.index][@intCast(id)] += 1;
                self.log.counts[recipient.index] += 1;
            }
            try std.testing.expect(self.service.output.releaseReady(packet.page, packet.generation));
            _ = self.service.preparing.fetchSub(1, .release);
        }
    }

    fn disconnected(self: *const Fixture) bool {
        for (self.service.disconnects) |*value| if (value.load(.acquire) != 0) return true;
        return false;
    }
};

test "a departed player's slot drains before another takes it, and its removal comes first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 3);
    try fixture.step();
    for (0..3) |observer| try std.testing.expect(fixture.replication.state(2, observer).known);

    // Player 2 leaves while player 1 has no room: player 0 is told at once, player 1 not yet.
    fixture.open(1, false);
    fixture.players.records[2] = .{};
    fixture.log.clear();
    try fixture.step();
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.entity_destroy)));
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.player_remove)));
    try std.testing.expectEqual(@as(usize, 0), fixture.log.counts[1]);
    try std.testing.expect(!fixture.replication.lifecycle.drained(2));
    // The slot is held, so sessions give it to nobody.
    try std.testing.expect(fixture.service.held[2]);

    // Player 1 gets room: it is told, the row drains, and the slot is let go.
    fixture.open(1, true);
    fixture.log.clear();
    try fixture.step();
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(1, Client.packetId(.entity_destroy)));
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(1, Client.packetId(.player_remove)));
    try std.testing.expect(fixture.replication.lifecycle.drained(2));
    try std.testing.expect(!fixture.service.held[2]);

    // Only now does a new player take the slot, and everyone hears of it as someone new.
    fixture.players.records[2] = .{ .handle = .{ .index = 2, .generation = 2 }, .uuid = 99, .protocol = fixture.players.records[0].protocol, .name = @splat('b'), .name_len = 1, .stage = .ready, .loaded = true, .on_ground = true, .position = .{ .x = 8, .y = 65, .z = 8 } };
    fixture.open(2, true);
    fixture.log.clear();
    try fixture.step();
    for (0..2) |observer| {
        try std.testing.expect(fixture.log.count(observer, Client.packetId(.player_info)) >= 1);
        try std.testing.expectEqual(@as(usize, 1), fixture.log.count(observer, Client.packetId(.spawn_entity)));
        try std.testing.expectEqual(@as(usize, 0), fixture.log.count(observer, Client.packetId(.player_remove)));
    }
    try std.testing.expect(!fixture.disconnected());
}

test "a late joiner hears of everyone, and everyone hears of it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 3);
    const late = fixture.players.records[2];
    fixture.players.records[2] = .{};
    try fixture.step();
    fixture.players.records[2] = late;
    fixture.open(2, true);
    fixture.log.clear();
    try fixture.step();
    for (0..2) |observer| {
        try std.testing.expectEqual(@as(usize, 1), fixture.log.count(observer, Client.packetId(.spawn_entity)));
        try std.testing.expect(fixture.replication.state(2, observer).known);
    }
    try std.testing.expectEqual(@as(usize, 2), fixture.log.count(2, Client.packetId(.spawn_entity)));
    for (0..2) |subject| try std.testing.expect(fixture.replication.state(subject, 2).known);
}

test "hiding a player from one observer tells that observer alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 3);
    const layer = try fixture.visibility.createLayer();
    try fixture.step();
    const only_zero = [_]usize{1};
    try layer.updateMany(&.{.{ .subjects = &.{fixture.players.records[1].handle.?}, .observers = .{ .players = .{ .words = &only_zero, .capacity = 3 } }, .channels = &.{ fixture.visibility.player_entity, fixture.visibility.tab_list }, .excluded = true }});
    fixture.log.clear();
    try fixture.step();
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.entity_destroy)));
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.player_remove)));
    try std.testing.expect(!fixture.replication.state(1, 0).known);
    try std.testing.expectEqual(@as(usize, 0), fixture.log.counts[2]);
    try std.testing.expect(fixture.replication.state(1, 2).known);
}

test "game mode and chat key changes reach only the observers that know the player" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 3);
    const layer = try fixture.visibility.createLayer();
    const only_two = [_]usize{4};
    try layer.updateMany(&.{.{ .subjects = &.{fixture.players.records[1].handle.?}, .observers = .{ .players = .{ .words = &only_two, .capacity = 3 } }, .channels = &.{ fixture.visibility.player_entity, fixture.visibility.tab_list }, .excluded = true }});
    try fixture.step();
    try std.testing.expect(!fixture.replication.state(1, 2).known);

    fixture.modes[1] = .creative;
    fixture.log.clear();
    try fixture.step();
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.player_info)));
    try std.testing.expectEqual(@as(usize, 0), fixture.log.count(2, Client.packetId(.player_info)));
    try std.testing.expectEqual(minecraft.GameMode.creative, fixture.replication.state(1, 0).gamemode.?);

    fixture.players.records[1].chat_revision += 1;
    fixture.log.clear();
    try fixture.step();
    try std.testing.expectEqual(@as(usize, 1), fixture.log.count(0, Client.packetId(.player_info)));
    try std.testing.expectEqual(@as(usize, 0), fixture.log.count(2, Client.packetId(.player_info)));
    try std.testing.expect(fixture.replication.state(1, 0).chat);
}

test "a crowd meeting in one place costs nobody their connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const count = 300;
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), count);
    for (0..8) |_| {
        try fixture.step();
        fixture.log.clear();
    }
    try std.testing.expect(!fixture.disconnected());
    for (0..count) |subject| try std.testing.expectEqual(@as(usize, count), fixture.replication.lifecycle.knownBy(subject).count());
}

test "observers that fall behind catch up with relative moves, even with 512 players" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const count = 512;
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), count);
    for (0..4) |_| try fixture.step();
    for (0..count) |subject| try std.testing.expectEqual(@as(usize, count), fixture.replication.lifecycle.knownBy(subject).count());
    fixture.log.clear();
    const sync = Client.packetId(.sync_entity_position);
    // Half the clients have no room for three updates while everyone walks.
    for (0..count) |index| if (index % 2 == 1) fixture.open(index, false);
    for (0..3) |_| {
        for (fixture.players.records) |*player| player.position.x += 0.3;
        try fixture.step();
    }
    for (0..count) |index| fixture.open(index, true);
    for (0..3) |_| {
        for (fixture.players.records) |*player| player.position.x += 0.3;
        try fixture.step();
    }
    var moves: usize = 0;
    for (0..count) |client| {
        try std.testing.expectEqual(@as(usize, 0), fixture.log.count(client, sync));
        moves += fixture.log.count(client, Client.packetId(.rel_entity_move));
    }
    try std.testing.expect(moves > 0);
    try std.testing.expect(!fixture.disconnected());
}

test "a turn and a walk reach every observer whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), 2);
    for (0..4) |_| try fixture.step();
    try std.testing.expect(fixture.replication.state(0, 1).spawned);
    const alice = &fixture.players.records[0];
    alice.rotation.yaw = 90;
    for (0..12) |tick| {
        if (tick < 6) alice.position.x -= 0.1;
        try fixture.step();
    }
    const seen = fixture.replication.observed(0, 1);
    // 90 degrees as an angle byte.
    try std.testing.expectEqual(@as(i8, 64), seen.value.yaw);
    try std.testing.expectEqual(@as(?i8, 64), seen.value.head);
}
