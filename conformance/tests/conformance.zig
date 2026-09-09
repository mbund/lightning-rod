const std = @import("std");
const lightning_rod = @import("lightning_rod");
const mcc = @import("minecraft_conformance");

comptime {
    _ = @import("runtime_consumer.zig");
    _ = @import("sessions_consumer.zig");
}

test "generated play packets round trip through the in-memory conformance codec" {
    const fields = [_]mcc.Field{
        .{ .name = "x", .value = .{ .literal = "12.5" } },
        .{ .name = "y", .value = .{ .literal = "64" } },
        .{ .name = "z", .value = .{ .literal = "-3.25" } },
        .{ .name = "on_ground", .value = .{ .literal = "1" } },
    };
    var encoded: [256]u8 = undefined;
    const raw = try mcc.input_encoder.encode(&encoded, .{
        .name = "move",
        .fields = &fields,
    });
    var canonicalizer = mcc.canonicalizer.Canonicalizer.init(&.{});
    defer canonicalizer.deinit();
    const packet = (try canonicalizer.canonicalizeServerbound(raw)).?;
    try std.testing.expectEqualStrings("move", packet.name);
    try std.testing.expectEqualStrings("12.5", packet.fields[0].value.literal);
    try std.testing.expectEqualStrings("-3.25", packet.fields[2].value.literal);
}

test "public gameplay inventory consumes only the selected matching block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const events = try lightning_rod.player_lifecycle.Events.init(allocator);
    const world_key = lightning_rod.world_identity.Key{ .value = 1 };
    const worlds = try lightning_rod.worlds.Worlds.init(allocator, .{ .initial = &.{.{
        .key = world_key,
        .name = "test:overworld",
        .dimension = .{ .index = 0 },
        .generator = @enumFromInt(0),
        .seed = 1,
        .spawn_x = 0,
        .spawn_y = 64,
        .spawn_z = 0,
    }} });
    const players = try lightning_rod.players.Players.init(allocator, .{
        .events = events,
        .worlds = worlds,
    }, .{
        .initial_world = world_key,
        .maximum_connections = 1,
        .maximum_players = 1,
        .maximum_saved_players = 1,
    });
    const dirt = lightning_rod.players.stackForItem(2, 2);
    players.records[0].hotbar[0] = dirt;
    const placed = lightning_rod.players.playerPlacedBlockState(dirt.block_state);
    try std.testing.expectEqual(@as(?u4, 0), players.consumeSelectedBlock(0, placed));
    try std.testing.expectEqual(@as(u8, 1), players.records[0].hotbar[0].count);
    try std.testing.expect(players.consumeSelectedBlock(0, placed + 1) == null);
}

test "observer receives player motion, head rotation, and one remote arm swing" {
    const simulation = try std.testing.allocator.create(lightning_rod.test_support.state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 19);
    defer simulation.deinit();

    for (0..2) |slot| {
        simulation.players.beginConnection(&simulation.random, @intCast(slot));
        _ = try simulation.players.login(&simulation.random, @intCast(slot), if (slot == 0) "moving" else "observer", slot + 1);
        simulation.players.transition(@intCast(slot), .configuration);
        simulation.players.transition(@intCast(slot), .play);
    }

    var capture = OutputCapture{};
    var sessions = lightning_rod.sessions.Sessions.init(capture.protocol);
    sessions.bindRuntime(capture.runtime());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const packets = try lightning_rod.Packets.init(arena.allocator(), .{
        .inputs = &simulation.inputs,
        .blocks = &simulation.blocks,
        .players = &simulation.players,
        .containers = &simulation.containers,
        .living = &simulation.living,
        .items = &simulation.items,
        .worlds = simulation.worlds,
        .sessions = &sessions,
    }, .{});
    packets.tick(arena.allocator());
    packets.setPlayerProtocol(0, capture.protocol);
    packets.setPlayerProtocol(1, capture.protocol);

    const previous = lightning_rod.inputs.PreviousMovement{
        .position = simulation.players.records[0].position,
        .rotation = simulation.players.records[0].rotation,
        .on_ground = false,
    };
    simulation.players.records[0].position.x += 1.25;
    simulation.players.records[0].position.y += 0.5;
    simulation.players.records[0].rotation = .{ .yaw = 90, .pitch = 15 };
    simulation.players.records[0].on_ground = true;
    packets.emitPlayerPosition(0, previous);
    packets.emitArmSwing(0, 0);

    try std.testing.expectEqual(@as(usize, 3), capture.count);
    for (capture.recipients[0..capture.count]) |recipient| try std.testing.expectEqual(@as(u16, 1), recipient);
    const identities = [_]mcc.Identity{.{
        .alias = "moving",
        .entity_id = simulation.players.records[0].entity_id,
        .position = .{ previous.position.x, previous.position.y, previous.position.z },
        .position_known = true,
    }};
    var canonicalizer = mcc.canonicalizer.Canonicalizer.init(&identities);
    defer canonicalizer.deinit();
    const moved = (try canonicalizer.canonicalize(.{ .recipient = "observer", .payload = capture.packet(0) })).?;
    try std.testing.expectEqualStrings("entity_moved", moved.packet.name);
    try std.testing.expectEqualStrings("moving", moved.packet.fields[0].value.literal);
    try std.testing.expectEqualStrings("1.25,64.5,0", moved.packet.fields[1].value.literal);
    const head = (try canonicalizer.canonicalize(.{ .recipient = "observer", .payload = capture.packet(1) })).?;
    try std.testing.expectEqualStrings("entity_head_rotation", head.packet.name);
    try std.testing.expectEqualStrings("64", head.packet.fields[1].value.literal);
    const swing = (try canonicalizer.canonicalize(.{ .recipient = "observer", .payload = capture.packet(2) })).?;
    try std.testing.expectEqualStrings("arm_swing", swing.packet.name);
    try std.testing.expectEqualStrings("moving", swing.packet.fields[0].value.literal);
    try std.testing.expectEqualStrings("main_hand", swing.packet.fields[1].value.literal);
}

const OutputCapture = struct {
    const packet_capacity = 128;
    const maximum_packets = 8;

    protocol: i32 = lightning_rod.protocol_versions.all[0].protocol_number,
    bytes: [maximum_packets][packet_capacity]u8 = undefined,
    lengths: [maximum_packets]usize = @splat(0),
    recipients: [maximum_packets]u16 = @splat(0),
    count: usize = 0,

    fn runtime(self: *OutputCapture) lightning_rod.sessions.Runtime {
        return .{ .context = self, .vtable = &.{
            .player_session = playerSession,
            .player_protocol = playerProtocol,
            .output_state = outputState,
            .packet_views = packetViews,
            .claim_packet = claimPacket,
            .send_one = sendOne,
            .fanout = fanout,
        } };
    }

    fn packet(self: *const OutputCapture, index: usize) []const u8 {
        return self.bytes[index][0..self.lengths[index]];
    }

    fn from(raw: *anyopaque) *OutputCapture {
        return @ptrCast(@alignCast(raw));
    }

    fn playerSession(_: *anyopaque, slot: u16) ?lightning_rod.Session {
        return .{ .slot = slot, .generation = 1 };
    }

    fn playerProtocol(raw: *anyopaque, _: lightning_rod.Session) ?lightning_rod.Protocol {
        return .{ .value = from(raw).protocol };
    }

    fn outputState(_: *anyopaque, _: lightning_rod.Session) ?lightning_rod.sessions.OutputState {
        return .{ .credit_bytes = packet_capacity, .queued_bytes = 0, .capacity_bytes = packet_capacity };
    }

    fn packetViews(_: *const anyopaque) []const lightning_rod.core_exchange.PacketView {
        return &.{};
    }

    fn claimPacket(_: *anyopaque, _: lightning_rod.core_exchange.PacketView) lightning_rod.sessions.Claim {
        return .unavailable;
    }

    fn sendOne(raw: *anyopaque, recipient: lightning_rod.Session, encoder: lightning_rod.sessions.PacketEncoder, _: lightning_rod.sessions.DeliveryClass, _: lightning_rod.sessions.DeliveryPolicy) lightning_rod.sessions.PacketAdmission {
        const self = from(raw);
        if (self.count == maximum_packets or encoder.maximum_payload_bytes > packet_capacity) return .backpressured;
        const encoded = encoder.encode(encoder.context, .{ .value = self.protocol }, &self.bytes[self.count]) orelse return .wrong_protocol;
        self.lengths[self.count] = encoded.payload.len;
        self.recipients[self.count] = recipient.slot;
        self.count += 1;
        return .accepted;
    }

    fn fanout(raw: *anyopaque, temporary: std.mem.Allocator, recipients: []const lightning_rod.Session, encoder: lightning_rod.sessions.PacketEncoder, class: lightning_rod.sessions.DeliveryClass, policy: lightning_rod.sessions.DeliveryPolicy) std.mem.Allocator.Error!lightning_rod.sessions.FanoutResult {
        const admissions = try temporary.alloc(lightning_rod.sessions.PacketAdmission, recipients.len);
        for (recipients, admissions) |recipient, *admission| admission.* = sendOne(raw, recipient, encoder, class, policy);
        return lightning_rod.sessions.fanoutResult(temporary, recipients, admissions);
    }
};
