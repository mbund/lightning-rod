const std = @import("std");
const vanilla = @import("lib.zig");
const definitions = @import("vanilla_definitions").defaults;
const commands = @import("commands");
const Packets = @import("minecraft_packets").Packets;
const Worlds = @import("worlds").Worlds;
const Players = @import("players").players.Players;
const sessions = @import("sessions");
const protocols = @import("minecraft_packets").protocols;

const Protocol = protocols.implementations[0].Protocol;
const WorldBorder = vanilla.WorldBorder;

/// What one client was told.
const Told = struct {
    initialize: usize = 0,
    center: usize = 0,
    lerp: usize = 0,
    size: usize = 0,
    warning_time: usize = 0,
    warning_blocks: usize = 0,
    /// The last whole border it was told: center, size and the size it moves to.
    border: [4]f64 = @splat(0),
};

const Fixture = struct {
    service: *sessions.Service,
    records: [2]Players.Player,
    players: Players,
    worlds: *Worlds,
    overworld: u32,
    nether: u32,
    world_border: *WorldBorder,

    fn init(self: *Fixture, allocator: std.mem.Allocator, config: WorldBorder.Configuration) !void {
        const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
        const service = try sessions.Service.init(allocator, std.testing.io, undefined, .{ .connections = 2, .pages = 128, .page_bytes = 4096, .credit_bytes = 32768, .protocols = try allocator.dupe(sessions.Protocol, &selected) });
        const packets = try Packets.init(allocator, .{ .sessions = service });
        const prepared = try definitions.prepare(allocator);
        const worlds = try Worlds.allocate(allocator, .{ .maximum = 2 });
        const overworld = try worlds.create(.{ .name = "minecraft:overworld", .dimension = try prepared.dimensions.dimension("minecraft:overworld") });
        const nether = try worlds.create(.{ .name = "minecraft:the_nether", .dimension = try prepared.dimensions.dimension("minecraft:the_nether") });
        self.* = .{ .service = service, .records = undefined, .players = undefined, .worlds = worlds, .overworld = overworld, .nether = nether, .world_border = undefined };
        for (&self.records, 0..) |*player, at| {
            player.* = .{ .handle = .{ .index = @intCast(at), .generation = 1 }, .uuid = at + 1, .world = overworld, .protocol = selected[0].number, .name = @splat('a'), .name_len = 1, .stage = .ready, .arrivals = 1, .position = .{ .x = 8, .y = 65, .z = 6.5 } };
            service.credit[at].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.credit_bytes, .release);
        }
        self.players = .{ .deps = .{ .entities = undefined, .sessions = service, .packets = packets, .input = undefined, .storage = undefined, .worlds = worlds, .record_workspaces = undefined }, .config = .{ .maximum = 2 }, .spawn_world = overworld, .records = &self.records, .dig_handlers = &.{} };
        try self.players.initIndexes(allocator);
        try self.players.rebuildIndexes();
        self.world_border = try WorldBorder.allocate(allocator, config, .{ .storage = undefined, .worlds = worlds, .dimensions = prepared.dimensions, .players = &self.players });
    }

    fn tick(self: *Fixture, told: *[2]Told) !void {
        try self.world_border.tick();
        while (self.service.output.takeReady()) |packet| {
            defer {
                std.debug.assert(self.service.output.releaseReady(packet.page, packet.generation));
                _ = self.service.preparing.fetchSub(1, .release);
            }
            const header = try Protocol.play.toClient.readHeader(packet.bytes);
            var recipients = packet.recipients.iterator();
            while (recipients.next()) |recipient| {
                const client = &told[recipient.index];
                if (header.id == Protocol.play.toClient.packetId(.initialize_world_border)) {
                    client.initialize += 1;
                    const x, const a = try Protocol.play.toClient.packet_initialize_world_border.read(header.body).x();
                    const z, const b = try a.z();
                    const old, const c = try b.oldDiameter();
                    const new, const d = try c.newDiameter();
                    _, const e = try d.speed();
                    const boundary, const f = try e.portalTeleportBoundary();
                    try std.testing.expectEqual(@as(i32, 29_999_984), boundary);
                    const blocks, const g = try f.warningBlocks();
                    try std.testing.expectEqual(self.world_border.warning_blocks, blocks);
                    _, const done = try g.warningTime();
                    try done.finish();
                    client.border = .{ x, z, old, new };
                } else if (header.id == Protocol.play.toClient.packetId(.world_border_center)) {
                    client.center += 1;
                } else if (header.id == Protocol.play.toClient.packetId(.world_border_lerp_size)) {
                    client.lerp += 1;
                } else if (header.id == Protocol.play.toClient.packetId(.world_border_size)) {
                    client.size += 1;
                } else if (header.id == Protocol.play.toClient.packetId(.world_border_warning_delay)) {
                    client.warning_time += 1;
                } else if (header.id == Protocol.play.toClient.packetId(.world_border_warning_reach)) {
                    client.warning_blocks += 1;
                } else return error.UnexpectedPacket;
            }
        }
    }
};

test "clients hear the whole border as they arrive and each change after, and a blocked one catches up" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture: Fixture = undefined;
    try fixture.init(arena.allocator(), .{ .center_x = 8, .size = 64 });
    const border = fixture.world_border;
    var told: [2]Told = @splat(.{});

    try fixture.tick(&told);
    for (told) |client| {
        try std.testing.expectEqual(@as(usize, 1), client.initialize);
        try std.testing.expectEqual([4]f64{ 8, 0, 64, 64 }, client.border);
    }
    // The nether's border has the center divided by its coordinate scale, the size the same.
    try std.testing.expectEqual(vanilla.world_border.Bounds.around(1, 0, 64), border.bounds(fixture.nether));
    try std.testing.expectEqual(vanilla.world_border.Bounds.around(8, 0, 64), border.bounds(fixture.overworld));

    // Nothing changed, nothing is sent.
    try fixture.tick(&told);
    try std.testing.expectEqual(@as(usize, 1), told[0].initialize);

    border.setCenter(16, 0);
    border.lerpSize(64, 32, 40);
    try fixture.tick(&told);
    for (told) |client| {
        try std.testing.expectEqual(@as(usize, 1), client.center);
        try std.testing.expectEqual(@as(usize, 1), client.lerp);
        try std.testing.expectEqual(@as(usize, 0), client.size);
    }
    // Clients move the border themselves.
    for (0..39) |_| try fixture.tick(&told);
    try std.testing.expectEqual(@as(f64, 32), border.size());
    try std.testing.expectEqual(@as(usize, 1), told[0].lerp);

    // A respawn makes a new level on the client, which has to hear the whole border again.
    fixture.records[1].life += 1;
    fixture.records[1].arrivals += 1;
    try fixture.tick(&told);
    try std.testing.expectEqual(@as(usize, 1), told[0].initialize);
    try std.testing.expectEqual(@as(usize, 2), told[1].initialize);
    try std.testing.expectEqual([4]f64{ 16, 0, 32, 32 }, told[1].border);

    // A client with no room for output hears the change once it has room.
    fixture.service.credit[0].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    border.setWarningBlocks(9);
    border.setWarningTime(30);
    try fixture.tick(&told);
    try std.testing.expectEqual(@as(usize, 0), told[0].warning_blocks);
    try std.testing.expectEqual(@as(usize, 1), told[1].warning_blocks);
    try std.testing.expectEqual(@as(usize, 1), told[1].warning_time);
    fixture.service.credit[0].store(@as(u64, 1) << 32 | sessions.Service.active | fixture.service.config.credit_bytes, .release);
    try fixture.tick(&told);
    try std.testing.expectEqual(@as(usize, 1), told[0].warning_blocks);
    try std.testing.expectEqual(@as(usize, 1), told[0].warning_time);
    try std.testing.expectEqual(@as(usize, 1), told[1].warning_blocks);
}

test "the worldborder command checks and changes the border as vanilla's does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator, .{});
    const Operator = struct {
        reply: [256]u8 = undefined,
        len: usize = 0,

        /// Only the sender may use it, so nobody else hears of it.
        fn allows(_: *@This(), uuid: u128, _: *const commands.Permission) bool {
            return uuid == 1;
        }

        fn write(self: *@This(), text: []const u8) void {
            @memcpy(self.reply[0..text.len], text);
            self.len = text.len;
        }

        fn run(self: *@This(), tree: *commands.Commands, input: []const u8) ![]const u8 {
            try tree.execute(.{ .sender = 1, .output = commands.Reply.init(self, write) }, input);
            return self.reply[0..self.len];
        }
    };
    var operator: Operator = .{};
    const tree = try commands.Commands.init(allocator, .{ .maximum_nodes = 64, .permission_policy = commands.Policy.init(&operator, Operator.allows) });
    _ = try vanilla.WorldBorderCommands.init(allocator, .{ .commands = tree, .world_border = fixture.world_border, .players = &fixture.players, .chat = undefined });
    const border = fixture.world_border;

    try std.testing.expectEqualStrings("Set the world border to 10.0 block(s) wide", try operator.run(tree, "worldborder set 10"));
    try std.testing.expectEqual(@as(f64, 10), border.size());
    try std.testing.expectEqualStrings("Nothing changed. The world border is already that size", try operator.run(tree, "worldborder set 10"));
    try std.testing.expectEqualStrings("World border cannot be smaller than 1 block wide", try operator.run(tree, "worldborder set 0.5"));
    try std.testing.expectEqualStrings("World border cannot be bigger than 5.9999968E7 blocks wide", try operator.run(tree, "worldborder add 59999960"));
    try std.testing.expectEqualStrings("Growing the world border to 20.0 blocks wide over 5 seconds", try operator.run(tree, "worldborder add 10 5"));
    try std.testing.expectEqual(@as(i64, 100), border.remainingTicks());
    // More time on a moving border adds to what it had left.
    try std.testing.expectEqualStrings("Shrinking the world border to 4.0 block(s) wide over 7 second(s)", try operator.run(tree, "worldborder add -6 2"));
    try std.testing.expectEqual(@as(i64, 140), border.remainingTicks());
    try std.testing.expectEqualStrings("The world border is currently 10 block(s) wide", try operator.run(tree, "worldborder get"));

    // Whole numbers are the middles of their blocks, and ~ counts from the sender.
    try std.testing.expectEqualStrings("Set the center of the world border to 3.50, 6.50", try operator.run(tree, "worldborder center 3 ~"));
    try std.testing.expectEqual(@as(f64, 3.5), border.centerX());
    try std.testing.expectEqualStrings("Nothing changed. The world border is already centered there", try operator.run(tree, "worldborder center 3.5 6.5"));
    try std.testing.expectEqualStrings("World border cannot be further out than 2.9999984E7 blocks", try operator.run(tree, "worldborder center 30000000 0"));

    try std.testing.expectEqualStrings("Set the world border damage to 1.50 per block each second", try operator.run(tree, "worldborder damage amount 1.5"));
    try std.testing.expectEqual(@as(f64, 1.5), border.damage_per_block);
    try std.testing.expectEqualStrings("Invalid argument. Use /help for usage.", try operator.run(tree, "worldborder damage amount -1"));
    try std.testing.expectEqualStrings("Set the world border damage buffer to 2.00 block(s)", try operator.run(tree, "worldborder damage buffer 2"));
    try std.testing.expectEqualStrings("Set the world border warning distance to 9 block(s)", try operator.run(tree, "worldborder warning distance 9"));
    try std.testing.expectEqualStrings("Nothing changed. The world border warning is already that amount of time", try operator.run(tree, "worldborder warning time 15"));
    try std.testing.expectEqualStrings("Set the world border warning time to 30 second(s)", try operator.run(tree, "worldborder warning time 30"));
    try std.testing.expectEqual(@as(i32, 30), border.warning_time);
}
