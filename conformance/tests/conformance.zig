const std = @import("std");
const lightning_rod = @import("lightning_rod");
const mcc = @import("minecraft_conformance");
const vanilla = @import("vanilla");

test "generic Minecraft conformance: block breaking progress" {
    const target = try MiningTarget.init();
    defer target.deinit();
    try mcc.suite.blockBreakingProgress(target.adapter(), std.testing.allocator);
}

test "generic Minecraft conformance: airborne block breaking progress" {
    const target = try MiningTarget.init();
    defer target.deinit();
    try mcc.suite.airborneBlockBreakingProgress(target.adapter(), std.testing.allocator);
}

test "sneaking synchronizes exact player state between clients" {
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
    simulation.players.records[0].presentation_ready = true;
    simulation.players.records[1].presentation_ready = true;

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
    var input_storage: [32]u8 = undefined;
    const Protocol = lightning_rod.protocol_versions.Protocol(lightning_rod.protocol_versions.all[0].version);
    const input_packet = try Protocol.play.toServer.write(&input_storage).player_input();
    const input_bytes = (try input_packet.inputs(.{ .shift = true, .sprint = false })).finish();
    const views = [_]lightning_rod.RawPacketView{packetView(0, capture.protocol, Protocol.play.toServer.packetId(.player_input), input_bytes)};
    var claimed = [_]bool{false};
    packets.setPacketViews(&views, &claimed);
    const decoder = try vanilla.PlayDecode.init(arena.allocator(), .{ .packets = packets }, .{});
    decoder.tick();
    packets.clearPacketViews();
    try std.testing.expect(claimed[0]);
    const player_input = try vanilla.PlayerInput.init(arena.allocator(), .{
        .worlds = simulation.worlds,
        .materialization = undefined,
        .players = &simulation.players,
        .inputs = &simulation.inputs,
        .outputs = packets,
    }, .{});
    player_input.tick(arena.allocator());

    try std.testing.expectEqual(@as(usize, 5), capture.count);
    for (capture.recipients[0..3]) |recipient| try std.testing.expectEqual(@as(u16, 1), recipient);
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
    var actor_received = false;
    var observer_received = false;
    for (3..5) |index| {
        actor_received = actor_received or capture.recipients[index] == 0;
        observer_received = observer_received or capture.recipients[index] == 1;
        const wire = try Protocol.play.toClient.read(capture.packet(index)).name();
        _, const metadata_cursor = try wire.entity_metadata.entityId();
        const metadata, const metadata_done = try metadata_cursor.metadata();
        try metadata.finish();
        try metadata_done.finish();
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x02, 0xff }, metadata.payload());
        const recipient = if (capture.recipients[index] == 0) "moving" else "observer";
        const state = (try canonicalizer.canonicalize(.{ .recipient = recipient, .payload = capture.packet(index) })).?;
        try std.testing.expectEqualStrings("entity_state", state.packet.name);
        try std.testing.expectEqualStrings(recipient, state.recipient);
        try std.testing.expectEqual(@as(usize, 4), state.packet.fields.len);
        try std.testing.expectEqualStrings("moving", state.packet.fields[0].value.literal);
        try std.testing.expectEqualStrings("on_fire", state.packet.fields[1].name);
        try std.testing.expectEqualStrings("0", state.packet.fields[1].value.literal);
        try std.testing.expectEqualStrings("sneaking", state.packet.fields[2].name);
        try std.testing.expectEqualStrings("1", state.packet.fields[2].value.literal);
        try std.testing.expectEqualStrings("sprinting", state.packet.fields[3].name);
        try std.testing.expectEqualStrings("0", state.packet.fields[3].value.literal);
    }
    try std.testing.expect(actor_received);
    try std.testing.expect(observer_received);
    try std.testing.expect(simulation.players.records[0].sneaking);
    try std.testing.expect(!simulation.players.records[0].sprinting);
}

test "placement publishes authoritative state before prediction acknowledgement" {
    const simulation = try std.testing.allocator.create(lightning_rod.test_support.state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 23);
    defer simulation.deinit();

    simulation.players.beginConnection(&simulation.random, 0);
    _ = try simulation.players.login(&simulation.random, 0, "builder", 1);
    simulation.players.transition(0, .configuration);
    simulation.players.transition(0, .play);

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
    simulation.players.records[0].presentation_ready = true;
    var input_storage: [64]u8 = undefined;
    const Protocol = lightning_rod.protocol_versions.Protocol(lightning_rod.protocol_versions.all[0].version);
    const c1 = try Protocol.play.toServer.write(&input_storage).block_place();
    const c2 = try c1.hand(0);
    const c3 = try c2.location(.{ .x = 1, .y = 63, .z = 1 });
    const c4 = try c3.direction(1);
    const c5 = try c4.cursorX(0.5);
    const c6 = try c5.cursorY(1);
    const c7 = try c6.cursorZ(0.5);
    const c8 = try c7.insideBlock(false);
    const c9 = try c8.worldBorderHit(false);
    const input_bytes = (try c9.sequence(19)).finish();
    const views = [_]lightning_rod.RawPacketView{packetView(0, capture.protocol, Protocol.play.toServer.packetId(.block_place), input_bytes)};
    var claimed = [_]bool{false};
    packets.setPacketViews(&views, &claimed);
    const decoder = try vanilla.PlayDecode.init(arena.allocator(), .{ .packets = packets }, .{});
    decoder.tick();
    packets.clearPacketViews();
    try std.testing.expect(claimed[0]);
    try std.testing.expectEqual(@as(usize, 1), simulation.inputs.block_request_count);
    packets.blockChanged(.{
        .world = simulation.players.records[0].world,
        .pos = .{ .x = 1, .y = 64, .z = 1 },
        .block_state = 1,
    });
    packets.flushAcknowledgements();

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    var canonicalizer = mcc.canonicalizer.Canonicalizer.init(&.{});
    defer canonicalizer.deinit();
    const changed = (try canonicalizer.canonicalize(.{ .recipient = "builder", .payload = capture.packet(0) })).?;
    try std.testing.expectEqualStrings("block_changed", changed.packet.name);
    const decoded = try Protocol.play.toClient.read(capture.packet(1)).name();
    try std.testing.expectEqualStrings("acknowledge_player_digging", @tagName(std.meta.activeTag(decoded)));
}

fn packetView(player: u16, protocol: i32, id: i32, packet: []const u8) lightning_rod.RawPacketView {
    var header_len: usize = 0;
    while (header_len < packet.len and header_len < 5) : (header_len += 1) {
        if (packet[header_len] & 0x80 == 0) {
            header_len += 1;
            break;
        }
    }
    std.debug.assert(header_len <= packet.len);
    return .{
        .connection = .{ .index = player, .generation = 1 },
        .protocol = protocol,
        .phase = .play,
        .id = id,
        .bytes = packet[header_len..],
        .player = player,
    };
}

const MiningTarget = struct {
    simulation: *lightning_rod.test_support.state.State,
    capture: OutputCapture,
    sessions: lightning_rod.sessions.Sessions,
    arena: std.heap.ArenaAllocator,
    packets: *lightning_rod.Packets,
    decoder: *vanilla.PlayDecode,
    collision_projection: *vanilla.CollisionProjection,
    mining: *vanilla.Mining,
    staged: [8][128]u8 = undefined,
    staged_lengths: [8]usize = @splat(0),
    staged_players: [8]u16 = @splat(0),
    staged_count: usize = 0,
    identities: [4]mcc.Identity = undefined,
    identity_count: usize = 0,
    outputs: [OutputCapture.maximum_packets]mcc.raw_packet.Clientbound = undefined,

    fn init() !*MiningTarget {
        const self = try std.testing.allocator.create(MiningTarget);
        errdefer std.testing.allocator.destroy(self);
        const simulation = try std.testing.allocator.create(lightning_rod.test_support.state.State);
        errdefer std.testing.allocator.destroy(simulation);
        try simulation.init(std.testing.allocator, 31);
        errdefer simulation.deinit();
        self.* = .{
            .simulation = simulation,
            .capture = .{},
            .sessions = lightning_rod.sessions.Sessions.init(lightning_rod.protocol_versions.all[0].protocol_number),
            .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
            .packets = undefined,
            .decoder = undefined,
            .collision_projection = undefined,
            .mining = undefined,
        };
        self.sessions.bindRuntime(self.capture.runtime());
        const allocator = self.arena.allocator();
        self.packets = try lightning_rod.Packets.init(allocator, .{
            .inputs = &simulation.inputs,
            .blocks = &simulation.blocks,
            .players = &simulation.players,
            .containers = &simulation.containers,
            .living = &simulation.living,
            .items = &simulation.items,
            .worlds = simulation.worlds,
            .sessions = &self.sessions,
        }, .{});
        self.decoder = try vanilla.PlayDecode.init(allocator, .{ .packets = self.packets }, .{});
        self.collision_projection = try vanilla.CollisionProjection.init(allocator, .{
            .clock = &simulation.clock,
            .blocks = &simulation.blocks,
            .materialization = undefined,
        }, .{});
        self.mining = try vanilla.Mining.init(allocator, .{
            .clock = &simulation.clock,
            .blocks = &simulation.blocks,
            .collision_projection = self.collision_projection,
            .players = &simulation.players,
            .inputs = &simulation.inputs,
            .containers = &simulation.containers,
            .chests = undefined,
            .furnaces = undefined,
            .destruction = undefined,
            .outputs = self.packets,
        }, .{});
        return self;
    }

    fn deinit(self: *MiningTarget) void {
        self.arena.deinit();
        self.simulation.deinit();
        std.testing.allocator.destroy(self.simulation);
        std.testing.allocator.destroy(self);
    }

    fn adapter(self: *MiningTarget) mcc.Adapter {
        return .{ .context = self, .vtable = &.{ .reset = reset, .stage = stage, .step = step } };
    }

    fn from(raw: *anyopaque) *MiningTarget {
        return @ptrCast(@alignCast(raw));
    }

    fn reset(raw: *anyopaque, fixture: mcc.adapter.Fixture) ![]const mcc.Identity {
        const self = from(raw);
        if (fixture.players.len > self.identities.len) return error.TooManyPlayers;
        for (fixture.players, 0..) |definition, slot| {
            const player_slot: u16 = @intCast(slot);
            self.simulation.players.beginConnection(&self.simulation.random, player_slot);
            _ = try self.simulation.players.login(&self.simulation.random, player_slot, definition.name, slot + 1);
            self.simulation.players.transition(player_slot, .configuration);
            self.simulation.players.transition(player_slot, .play);
            const player = &self.simulation.players.records[slot];
            player.position = .{ .x = definition.position[0], .y = definition.position[1], .z = definition.position[2] };
            player.on_ground = definition.on_ground;
            player.gamemode = switch (definition.gamemode) {
                .survival => .survival,
                .creative => .creative,
            };
            if (std.mem.eql(u8, definition.held_item, "minecraft:diamond_pickaxe"))
                player.hotbar[0] = lightning_rod.players.stackForItem(lightning_rod.registry_data.item_diamond_pickaxe_id, 1)
            else if (!std.mem.eql(u8, definition.held_item, "minecraft:air"))
                return error.UnsupportedFixtureItem;
            self.packets.setPlayerProtocol(player_slot, self.capture.protocol);
            player.presentation_ready = true;
            self.identities[slot] = .{
                .alias = definition.name,
                .entity_id = player.entity_id,
                .uuid = player.uuid,
                .position = definition.position,
                .position_known = true,
            };
        }
        for (fixture.blocks) |definition| {
            const pos = lightning_rod.geometry.BlockPos{ .x = definition.position[0], .y = @intCast(definition.position[1]), .z = definition.position[2] };
            self.simulation.blocks.ensureChunkAt(self.simulation.world, pos.x, pos.z, self.simulation.clock.tick);
            const state = if (std.mem.eql(u8, definition.state, "minecraft:stone"))
                lightning_rod.registry_data.block_stone_default_state
            else
                return error.UnsupportedFixtureBlock;
            _ = try self.simulation.blocks.setBlock(self.simulation.world, pos, state);
        }
        self.identity_count = fixture.players.len;
        return self.identities[0..self.identity_count];
    }

    fn stage(raw: *anyopaque, client: []const u8, packet: []const u8) !void {
        const self = from(raw);
        if (self.staged_count == self.staged.len or packet.len > self.staged[0].len) return error.InputCapacity;
        const player = for (self.identities[0..self.identity_count], 0..) |identity, slot| {
            if (std.mem.eql(u8, identity.alias, client)) break @as(u16, @intCast(slot));
        } else return error.UnknownClient;
        @memcpy(self.staged[self.staged_count][0..packet.len], packet);
        self.staged_lengths[self.staged_count] = packet.len;
        self.staged_players[self.staged_count] = player;
        self.staged_count += 1;
    }

    fn step(raw: *anyopaque) ![]const mcc.raw_packet.Clientbound {
        const self = from(raw);
        const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds;
        defer {
            const finished = std.Io.Clock.Timestamp.now(std.testing.io, .awake).raw.nanoseconds;
            const elapsed: u64 = @intCast(finished - started);
            if (elapsed > lightning_rod.runtime.maximum_tick_ns)
                std.debug.panic("conformance tick exceeded 50ms: {d}us", .{elapsed / std.time.ns_per_us});
        }
        self.capture.count = 0;
        self.packets.tick(self.arena.allocator());
        var views: [8]lightning_rod.RawPacketView = undefined;
        var claimed: [8]bool = @splat(false);
        for (0..self.staged_count) |index| {
            const packet = self.staged[index][0..self.staged_lengths[index]];
            const header = readVarInt(packet) orelse return error.InvalidPacket;
            views[index] = .{
                .connection = .{ .index = self.staged_players[index], .generation = 1 },
                .protocol = self.capture.protocol,
                .phase = .play,
                .id = header.value,
                .bytes = packet[header.length..],
                .player = self.staged_players[index],
                .ticket = @intCast(index),
            };
        }
        self.packets.setPacketViews(views[0..self.staged_count], claimed[0..self.staged_count]);
        self.decoder.tick();
        self.packets.clearPacketViews();
        self.staged_count = 0;
        self.mining.tick(self.arena.allocator());
        self.packets.flushAcknowledgements();
        self.simulation.clock.tick +%= 1;
        for (0..self.capture.count) |index| self.outputs[index] = .{
            .recipient = self.identities[self.capture.recipients[index]].alias,
            .payload = self.capture.packet(index),
        };
        return self.outputs[0..self.capture.count];
    }

    fn readVarInt(bytes: []const u8) ?struct { value: i32, length: usize } {
        var result: u32 = 0;
        for (bytes[0..@min(bytes.len, 5)], 0..) |byte, index| {
            result |= @as(u32, byte & 0x7f) << @intCast(index * 7);
            if (byte & 0x80 == 0) return .{ .value = @bitCast(result), .length = index + 1 };
        }
        return null;
    }
};

test "player inventory and gamemode projection preserve client contracts" {
    const simulation = try std.testing.allocator.create(lightning_rod.test_support.state.State);
    defer std.testing.allocator.destroy(simulation);
    try simulation.init(std.testing.allocator, 29);
    defer simulation.deinit();

    simulation.players.beginConnection(&simulation.random, 0);
    _ = try simulation.players.login(&simulation.random, 0, "collector", 1);
    simulation.players.transition(0, .configuration);
    simulation.players.transition(0, .play);
    simulation.players.records[0].hotbar[0] = lightning_rod.players.stackForItem(lightning_rod.registry_data.item_oak_log_id, 7);
    simulation.players.records[0].main_inventory[0] = lightning_rod.players.stackForItem(lightning_rod.registry_data.item_dirt_id, 3);

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
    simulation.players.records[0].presentation_ready = true;
    packets.emitPlayerInventory(0);
    simulation.players.records[0].gamemode = .creative;
    packets.emitPlayerGamemode(0);
    packets.emitPlayerAbilities(0);

    try std.testing.expectEqual(@as(usize, 3), capture.count);
    var canonicalizer = mcc.canonicalizer.Canonicalizer.init(&.{});
    defer canonicalizer.deinit();
    const inventory = (try canonicalizer.canonicalize(.{ .recipient = "collector", .payload = capture.packet(0) })).?;
    try std.testing.expectEqualStrings("inventory", inventory.packet.name);
    try std.testing.expectEqualStrings("player", inventory.packet.fields[1].value.literal);
    const slots = inventory.packet.fields[2].value.literal;
    try std.testing.expect(std.mem.indexOf(u8, slots, "h0=minecraft:oak_log*7") != null);
    try std.testing.expect(std.mem.indexOf(u8, slots, "m0=minecraft:dirt*3") != null);

    const Protocol = lightning_rod.protocol_versions.Protocol(lightning_rod.protocol_versions.all[0].version);
    const game_packet = try Protocol.play.toClient.read(capture.packet(1)).name();
    const reason, const game_cursor = try game_packet.game_state_change.reason();
    const gamemode, const game_done = try game_cursor.gameMode();
    try game_done.finish();
    try std.testing.expectEqual(@as(u8, 3), reason);
    try std.testing.expectEqual(@as(f32, 1), gamemode);
    const abilities_packet = try Protocol.play.toClient.read(capture.packet(2)).name();
    const flags, const speed_cursor = try abilities_packet.abilities.flags();
    _, const walk_cursor = try speed_cursor.flyingSpeed();
    _, const abilities_done = try walk_cursor.walkingSpeed();
    try abilities_done.finish();
    try std.testing.expectEqual(@as(i8, 0x0d), flags);
}

const OutputCapture = struct {
    const packet_capacity = 20 * 1024;
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
            .batch = batch,
            .fanout = fanout,
            .flush = flush,
        } };
    }

    fn flush(_: *anyopaque) void {}

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

    fn batch(raw: *anyopaque, temporary: std.mem.Allocator, items: []const lightning_rod.sessions.PacketBatchItem, class: lightning_rod.sessions.DeliveryClass, policy: lightning_rod.sessions.DeliveryPolicy) std.mem.Allocator.Error!lightning_rod.sessions.FanoutAdmissions {
        const admissions = try temporary.alloc(lightning_rod.sessions.PacketAdmission, items.len);
        for (items, admissions) |item, *admission| admission.* = sendOne(raw, item.recipient, item.encoder, class, policy);
        return .{ .values = admissions };
    }
};
