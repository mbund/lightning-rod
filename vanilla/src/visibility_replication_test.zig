const Chat = @import("chat.zig").Chat;
const JoinLeaveMessages = @import("join_leave_messages.zig").JoinLeaveMessages;
const std = @import("std");
const sessions = @import("sessions");
const protocols = @import("protocols");
const support = @import("protocol_support");
const packets = @import("minecraft_packets");
const Players = @import("players.zig").Players;
const Replication = @import("replication.zig").Replication;
const Visibility = @import("visibility.zig").Visibility;
const Protocol = protocols.implementations[0].Protocol;

const View = struct { known: bool = false, listed: bool = false, spawned: bool = false };
const Wire = struct {
    clients: [3][3]View = @splat(@splat(.{})),
    packets: usize = 0,

    fn tick(self: *Wire, replication: *Replication) !void {
        replication.deps.visibility.tick();
        replication.tick();
        self.packets = 0;
        const service = replication.deps.players.deps.sessions;
        while (service.output.takeReady()) |packet| {
            defer {
                std.debug.assert(service.output.releaseReady(packet.page, packet.generation));
                _ = service.preparing.fetchSub(1, .release);
            }
            self.packets += 1;
            const header = try Protocol.play.toClient.readHeader(packet.bytes);
            if (header.id == Protocol.play.toClient.packetId(.player_info)) {
                const action, const data = try Protocol.play.toClient.packet_player_info.read(header.body).action();
                var entries = try data.data();
                while (try entries.next()) |entry| {
                    const uuid, const named = try entry.uuid();
                    const subject: usize = @intCast(uuid - 1);
                    var profile = try named.player();
                    _, const profiled = try profile.encoded();
                    var chat = try profiled.chatSession();
                    _, const chatted = try chat.encoded();
                    var mode = try chatted.gamemode();
                    _, const moded = try mode.encoded();
                    var listed = try moded.listed();
                    const value, const listing = try listed.encoded();
                    var recipient_iterator = packet.recipients.iterator();
                    while (recipient_iterator.next()) |recipient| {
                        const view = &self.clients[recipient.index][subject];
                        if (action.add_player) view.known = true;
                        if (action.update_listed) {
                            try std.testing.expectEqual(@as(usize, 1), value.len);
                            view.listed = value[0] != 0;
                        }
                    }
                    var latency = try listing.latency();
                    _, const timed = try latency.encoded();
                    var display = try timed.displayName();
                    _, const displayed = try display.encoded();
                    var order = try displayed.listPriority();
                    _, const ordered = try order.encoded();
                    var hat = try ordered.showHat();
                    _, const done = try hat.encoded();
                    try entries.advance(done);
                }
                try (try entries.finish()).finish();
            } else if (header.id == Protocol.play.toClient.packetId(.spawn_entity)) {
                const entity, _ = try support.read_varint(header.body);
                const subject: usize = @intCast(entity - 1);
                var recipient_iterator = packet.recipients.iterator();
                while (recipient_iterator.next()) |recipient| {
                    const view = &self.clients[recipient.index][subject];
                    try std.testing.expect(view.known and !view.spawned);
                    view.spawned = true;
                }
            } else if (header.id == Protocol.play.toClient.packetId(.entity_destroy)) {
                const count, const entities = try support.read_varint(header.body);
                try std.testing.expectEqual(@as(i32, 1), count);
                const entity, _ = try support.read_varint(entities);
                var recipient_iterator = packet.recipients.iterator();
                while (recipient_iterator.next()) |recipient| self.clients[recipient.index][@intCast(entity - 1)].spawned = false;
            } else if (header.id == Protocol.play.toClient.packetId(.player_remove)) {
                const count, const uuids = try support.read_varint(header.body);
                try std.testing.expectEqual(@as(i32, 1), count);
                const subject: usize = @intCast(std.mem.readInt(u128, uuids[0..16], .big) - 1);
                var recipient_iterator = packet.recipients.iterator();
                while (recipient_iterator.next()) |recipient| {
                    const view = &self.clients[recipient.index][subject];
                    try std.testing.expect(!view.spawned);
                    view.* = .{};
                }
            }
        }
    }
};

test "visibility independently reconciles profiles tab listing and entities under backpressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 3, .pages = 128, .page_bytes = 4096, .buffer_bytes = 32768, .protocols = &selected });
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, index| {
        player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .name_len = 1, .stage = .ready, .protocol = selected[0].number };
        player.name[0] = @intCast('a' + index);
        service.credit[index].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = .{ .sessions = service, .packets = encoding, .input = undefined, .storage = undefined, .worlds = undefined, .vanilla_worlds = undefined, .record_workspaces = undefined }, .config = .{ .maximum = 3, .render_distance = 2 }, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{}, .{ .players = &players });
    const vanish = try visibility.createLayer();
    const minigame = try visibility.createLayer();
    const replication = try Replication.init(allocator, .{}, .{ .players = &players, .visibility = visibility });
    failing.fail_index = failing.alloc_index;
    var wire: Wire = .{};
    for (0..3) |index| wire.clients[index][index] = .{ .known = true, .listed = true };
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .listed = true, .spawned = true }, wire.clients[1][0]);
    const subject = records[0].handle.?;
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.tab_list}, .excluded = true }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .spawned = true }, wire.clients[1][0]);
    try std.testing.expectEqual(@as(usize, 6), replication.viewers(0).words[0]);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.tab_list}, .excluded = false }});
    try minigame.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = true }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .listed = true }, wire.clients[1][0]);
    try std.testing.expectEqual(@as(usize, 0), replication.viewers(0).words[0]);
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{ visibility.player_entity, visibility.tab_list }, .excluded = true }});
    try wire.tick(replication);
    try std.testing.expect(wire.clients[1][0].known);
    try std.testing.expectEqual(View{}, wire.clients[2][0]);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{ visibility.player_entity, visibility.tab_list }, .excluded = false }});
    try wire.tick(replication);
    try std.testing.expect(!wire.clients[2][0].spawned and wire.clients[2][0].listed);
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try minigame.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = false }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .listed = true, .spawned = true }, wire.clients[1][0]);
    try std.testing.expectEqual(wire.clients[1][0], wire.clients[2][0]);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{ visibility.player_entity, visibility.tab_list }, .excluded = true }});
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    try wire.tick(replication);
    try std.testing.expect(wire.clients[1][0].spawned);
    try std.testing.expectEqual(@as(usize, 0), replication.viewers(0).words[0]);
    records[0].position.x += 1;
    players.rebuildIndexes();
    try wire.tick(replication);
    try std.testing.expectEqual(@as(usize, 0), wire.packets);
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try wire.tick(replication);
    try std.testing.expectEqual(View{}, wire.clients[1][0]);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.tab_list}, .excluded = false }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .listed = true }, wire.clients[1][0]);
    for (0..16) |_| {
        try wire.tick(replication);
        try std.testing.expectEqual(@as(usize, 0), wire.packets);
    }
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.tab_list}, .excluded = true }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{}, wire.clients[1][0]);
    try vanish.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = records.len } }, .channels = &.{visibility.player_entity}, .excluded = false }});
    try wire.tick(replication);
    try std.testing.expectEqual(View{ .known = true, .spawned = true }, wire.clients[1][0]);
}

fn expectAnnouncement(service: *sessions.Service, text: ?[]const u8, audience: usize) !void {
    var count: usize = 0;
    while (service.output.takeReady()) |packet| {
        defer {
            std.debug.assert(service.output.releaseReady(packet.page, packet.generation));
            _ = service.preparing.fetchSub(1, .release);
        }
        const expected = text orelse return error.UnexpectedAnnouncement;
        const header = try Protocol.play.toClient.readHeader(packet.bytes);
        try std.testing.expectEqual(Protocol.play.toClient.packetId(.system_chat), header.id);
        try std.testing.expectEqual(@as(u8, 8), header.body[0]);
        const length = std.mem.readInt(u16, header.body[1..3], .big);
        try std.testing.expectEqualStrings(expected, header.body[3..][0..length]);
        var actual: usize = 0;
        var recipient_iterator = packet.recipients.iterator();
        while (recipient_iterator.next()) |recipient| actual |= @as(usize, 1) << @intCast(recipient.index);
        try std.testing.expectEqual(audience, actual);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, @intFromBool(text != null)), count);
}

test "announcements capture independent audiences and do not fabricate events on visibility changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 3, .pages = 32, .page_bytes = 4096, .buffer_bytes = 32768, .protocols = &selected });
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    var records: [3]Players.Player = undefined;
    for (&records, 0..) |*player, index| {
        player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .name_len = 1, .stage = .ready, .protocol = selected[0].number };
        player.name[0] = @intCast('a' + index);
        service.credit[index].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const visibility = try Visibility.init(allocator, .{}, .{ .players = &players });
    const layer = try visibility.createLayer();
    const chat = try Chat.init(allocator, .{ .players = &players, .sessions = service, .packets = encoding }, .{});
    const messages = try JoinLeaveMessages.init(allocator, .{ .visibility = visibility, .players = &players, .chat = chat, .sessions = service });
    const subject = records[0].handle.?;
    try layer.updateMany(&.{.{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.announcements}, .excluded = true }});
    const joined = [_]sessions.Event{.{ .joined = .{ .handle = subject, .uuid = 1, .protocol = selected[0].number, .name = records[0].name, .name_len = 1 } }};
    service.input_events = &joined;
    visibility.tick();
    try messages.tick();
    try expectAnnouncement(service, "a joined the game", 3);
    service.input_events = &.{};
    try layer.updateMany(&.{
        .{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{4}, .capacity = records.len } }, .channels = &.{visibility.announcements}, .excluded = false },
        .{ .subjects = &.{subject}, .observers = .{ .players = .{ .words = &.{2}, .capacity = records.len } }, .channels = &.{visibility.announcements}, .excluded = true },
    });
    visibility.tick();
    try messages.tick();
    try expectAnnouncement(service, null, 0);
    records[0].handle = null;
    const left = [_]sessions.Event{.{ .left = subject }};
    service.input_events = &left;
    visibility.tick();
    try messages.tick();
    try expectAnnouncement(service, "a left the game", 4);
}
