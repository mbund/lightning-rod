const Visibility = @import("visibility.zig").Visibility;
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const inventories = @import("inventories");
const entities = @import("entities");
const worlds = @import("worlds");
const chunks = @import("chunks");
const sessions = @import("sessions");
const protocols = @import("protocols");
const network = @import("networking");
const game_data = @import("game_data");
const packets = @import("minecraft_packets");
const minecraft = @import("minecraft_model");
const Mining = @import("mining.zig").Mining;
const Items = @import("items.zig").Items;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Durability = @import("item_properties.zig").Durability;
const EquipmentSlots = @import("item_properties.zig").EquipmentSlots;
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Input = @import("input.zig").Input;
const BlockActions = @import("block_actions.zig").BlockActions;
const Blocks = @import("block_sync.zig").BlockSynchronization;
const BlockLoot = @import("block_loot.zig").BlockLoot;
const Protocol = protocols.implementations[0].Protocol;
const selected_protocols = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
const position: minecraft.BlockPosition = .{ .x = 8, .y = 65, .z = 8 };

const Sink = struct {
    pub fn notify(_: *Sink, _: std.Io) void {}
    pub fn queueReceive(_: *Sink, _: std.Io, _: network.Handle, _: []u8) network.QueueError!void {
        unreachable;
    }
    pub fn queueSend(_: *Sink, _: std.Io, _: network.Handle, _: []const std.posix.iovec_const) network.QueueError!void {
        unreachable;
    }
    pub fn close(_: *Sink, _: std.Io, _: network.Handle, _: network.CloseReason) void {
        unreachable;
    }
    pub fn releaseConnection(_: *Sink, _: std.Io, _: network.Handle) void {
        unreachable;
    }
    pub fn submit(_: *Sink, _: std.Io) !void {
        unreachable;
    }
    pub fn poll(_: *Sink, _: std.Io, _: ?std.Io.Timeout, _: []network.Event) !usize {
        unreachable;
    }
};

const Client = struct { stage: i8 = -1, position: minecraft.BlockPosition = .{ .x = 0, .y = 0, .z = 0 } };
const Delivery = struct { packets: usize = 0, recipients: []usize };
const Fixture = struct {
    service: *sessions.Service,
    mining: *Mining,
    clients: []Client,
    received: []usize,
    other_world: u32,

    fn init(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry, count: usize) !Fixture {
        const sink = try allocator.create(Sink);
        sink.* = .{};
        const service = try sessions.Service.init(allocator, std.testing.io, .{ .context = sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = count, .pages = @max(1024, count * 4), .page_bytes = 32768, .buffer_bytes = 128 * 1024, .protocols = &selected_protocols });
        errdefer service.deinit();
        const input = try Input.init(allocator, .{ .sessions = service });
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const workspaces = try records.Workspaces.init(allocator, std.testing.io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 2 }, .{ .storage = try store.openSpace("worlds") });
        const dimension: worlds.Worlds.Dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 };
        const world = try dimensions.create(.{ .name = "test:first", .dimension = dimension });
        const other_world = try dimensions.create(.{ .name = "test:second", .dimension = dimension });
        const players = try Players.init(allocator, .{ .maximum = count, .world = world, .render_distance = 2 }, .{ .record_workspaces = workspaces, .sessions = service, .packets = encoding, .input = input, .storage = try store.openSpace("players"), .worlds = dimensions, .vanilla_worlds = undefined });
        for (players.records, 0..) |*player, at| player.* = .{ .handle = .{ .index = @intCast(at), .generation = 1 }, .uuid = at + 1, .world = world, .stage = .ready, .gamemode = .survival, .protocol = selected_protocols[0].number, .position = .{ .x = 8, .y = 65, .z = 6.5 }, .on_ground = true };
        players.rebuildIndexes();
        const ownership = try inventories.Inventories.init(allocator, std.testing.io, .{ .cache_slots = 1024, .cache_items = 8, .max_item_bytes = 1024 }, .{ .metrics = registry, .storage = try store.openSpace("inventory"), .record_workspaces = workspaces });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const bodies = try entities.Entities.init(allocator, std.testing.io, .{ .cache_records = 16 }, .{ .metrics = registry, .storage = try store.openSpace("entities"), .record_workspaces = workspaces });
        const dropped = try ItemEntities.init(allocator, std.testing.io, .{ .cache_records = 16, .maximum = 8 }, .{
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("drops"),
            .metrics = registry,
            .record_workspaces = workspaces,
        });
        const menus = try PlayerInventory.init(allocator, .{ .players = players, .inventories = ownership, .items = items, .equipment = try EquipmentSlots.init(allocator, .{ .items = items }), .dropped = dropped });
        const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 64, .demand_sections = 0, .cache_tiles = 8 }, .{ .metrics = registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const blocks = try Blocks.init(allocator, std.testing.io, .{ .metrics = registry, .chunks = terrain, .players = players, .streaming = undefined, .sessions = service, .packets = encoding, .worlds = dimensions }, .{ .delta_sections = 16, .queued_sections = 32 });
        const mining = try Mining.allocate(allocator, .{}, .{ .visibility = try Visibility.init(allocator, .{}, .{ .players = players }), .metrics = registry, .storage = try store.openSpace("mining"), .players = players, .input = input, .inventories = ownership, .items = items, .durability = try Durability.init(allocator, .{ .items = items, .inventories = ownership }), .worlds = dimensions, .chunks = terrain, .menus = menus, .loot = try BlockLoot.init(allocator), .dropped = dropped, .blocks = blocks, .actions = try BlockActions.init(allocator, .{}) });
        const tool: inventories.Stack = .{ .item = try items.define("minecraft:diamond_pickaxe"), .count = 1 };
        for (players.records) |player| try std.testing.expect(try ownership.set(.{ .owner = player.uuid, .index = 36 }, 0, tool));
        try terrain.setBlock(world, .{ .x = position.x, .y = position.y, .z = position.z }, game_data.registry.block_obsidian_default_state);
        try terrain.setBlock(world, .{ .x = position.x + 1, .y = position.y, .z = position.z }, game_data.registry.block_obsidian_default_state);
        const clients = try allocator.alloc(Client, count * count);
        @memset(clients, .{});
        var fixture: Fixture = .{ .service = service, .mining = mining, .clients = clients, .received = try allocator.alloc(usize, count), .other_world = other_world };
        fixture.grantAll();
        return fixture;
    }

    fn grant(self: *Fixture, index: usize, bytes: usize) void {
        const handle = self.mining.deps.players.records[index].handle.?;
        self.service.credit[index].store((@as(u64, handle.generation) << 32) | sessions.Service.active | bytes, .release);
    }

    fn grantAll(self: *Fixture) void {
        for (self.mining.deps.players.records, 0..) |player, at| if (player.handle != null) self.grant(at, self.service.config.buffer_bytes);
    }

    fn dig(self: *Fixture, index: usize, status: i32, at: minecraft.BlockPosition) !void {
        var buffer: [128]u8 = undefined;
        const packet = try Protocol.play.toServer.write(&buffer).block_dig();
        const action = try packet.status(status);
        const located = try action.location(.{ .x = at.x, .y = @intCast(at.y), .z = at.z });
        const bytes = (try (try located.face(1)).sequence(0)).finish();
        const incoming = [_][]const u8{bytes};
        const events = [_]sessions.Event{.{ .input = .{ .handle = self.mining.deps.players.records[index].handle.?, .protocol = selected_protocols[0].number, .packets = .{ .packets = &incoming } } }};
        self.service.input_events = &events;
        defer self.service.input_events = &.{};
        try self.mining.deps.input.tick(std.testing.failing_allocator);
    }

    fn tick(self: *Fixture) !Delivery {
        self.service.beginTick();
        return self.finishTick();
    }

    fn finishTick(self: *Fixture) !Delivery {
        self.mining.deps.players.ticks += 1;
        {
            errdefer self.service.endTick(false);
            self.mining.deps.visibility.tick();
            try self.mining.tick();
        }
        self.service.endTick(true);
        self.service.flush();
        @memset(self.received, 0);
        var result: Delivery = .{ .recipients = self.received };
        var batch = self.service.outputBatch();
        while (batch.next()) |packet| {
            defer self.service.recycle(std.testing.io, &.{packet});
            const header = try Protocol.play.toClient.readHeader(packet.bytes);
            if (header.id != Protocol.play.toClient.packetId(.block_break_animation)) continue;
            const reader = Protocol.play.toClient.packet_block_break_animation.read(header.body);
            const entity, const located = try reader.entityId();
            const at, const staged = try located.location();
            const stage, const done = try staged.destroyStage();
            try done.finish();
            const subject: usize = @intCast(entity - 1);
            try std.testing.expect(subject < self.mining.states.len);
            const current: minecraft.BlockPosition = .{ .x = at.x, .y = at.y, .z = at.z };
            var recipient_iterator = packet.recipients.iterator();
            while (recipient_iterator.next()) |recipient| {
                try std.testing.expect(recipient.index != subject);
                const client = &self.clients[recipient.index * self.mining.states.len + subject];
                if (stage < 0) {
                    client.stage = -1;
                } else {
                    client.* = .{ .stage = stage, .position = current };
                }
                result.recipients[recipient.index] += 1;
            }
            result.packets += 1;
        }
        return result;
    }

    fn clearClient(self: *Fixture, index: usize) void {
        const count = self.mining.states.len;
        @memset(self.clients[index * count ..][0..count], .{});
    }
};

pub fn benchmarkReplication() !void {
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(std.testing.io, &output_buffer);
    for ([_]usize{ 16, 64, 256, 513 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mining", .{temporary.sub_path});
        var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 128 });
        defer registry.deinit();
        var fixture = try Fixture.init(allocator, &store, &registry, count);
        defer fixture.service.deinit();
        failing.fail_index = failing.alloc_index;
        fixture.service.beginTick();
        for (0..count) |index| try fixture.dig(index, 0, position);
        const initial = try fixture.finishTick();
        try std.testing.expectEqual(count, initial.packets);
        for (initial.recipients[0..count]) |received| try std.testing.expectEqual(count - 1, received);
        for (0..count) |recipient| for (0..count) |subject| {
            if (recipient != subject) try std.testing.expectEqual(@as(i8, 0), fixture.clients[recipient * count + subject].stage);
        };
        const pairs = fixture.mining.pair_checks.value();
        const audience = fixture.mining.audience_checks.value();
        const observers = fixture.mining.observer_checks.value();
        const ownership = fixture.mining.deps.inventories;
        const terrain = fixture.mining.deps.chunks;
        const reads = ownership.items.metrics.reads.value() + ownership.cache.metrics.reads.value() + terrain.cache.metrics.reads.value();
        for (0..16) |_| try std.testing.expectEqual(@as(usize, 0), (try fixture.tick()).packets);
        try std.testing.expectEqual(pairs, fixture.mining.pair_checks.value());
        try std.testing.expectEqual(audience, fixture.mining.audience_checks.value());
        try std.testing.expectEqual(@as(u64, @intCast(count * 16)), fixture.mining.observer_checks.value() - observers);
        try std.testing.expectEqual(reads, ownership.items.metrics.reads.value() + ownership.cache.metrics.reads.value() + terrain.cache.metrics.reads.value());
        try output.interface.print("mining players={d} ticks=16 observer_checks={d} progress_pairs=0 changed_audience_checks=0 packets=0 storage_reads=0\n", .{ count, count * 16 });
    }
    try output.interface.flush();
}

pub fn verifyDelivery() !void {
    const count = 8;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const allocator = failing.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mining", .{temporary.sub_path});
    var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 128 });
    defer registry.deinit();
    var fixture = try Fixture.init(allocator, &store, &registry, count);
    defer fixture.service.deinit();
    const exclusion = try fixture.mining.deps.visibility.createLayer();
    failing.fail_index = failing.alloc_index;
    const players = fixture.mining.deps.players;
    fixture.service.beginTick();
    for (0..count) |index| try fixture.dig(index, 0, position);
    _ = try fixture.finishTick();
    const hidden_subject = players.records[0].handle.?;
    try exclusion.updateMany(&.{.{ .subjects = &.{hidden_subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = players.records.len } }, .channels = &.{fixture.mining.deps.visibility.player_entity}, .excluded = true }});
    const hidden = try fixture.tick();
    try std.testing.expectEqual(@as(usize, 2), hidden.recipients[1] + hidden.recipients[2]);
    try std.testing.expectEqual(@as(i8, -1), fixture.clients[count].stage);
    try std.testing.expectEqual(@as(i8, -1), fixture.clients[2 * count].stage);
    try exclusion.updateMany(&.{.{ .subjects = &.{hidden_subject}, .observers = .{ .players = .{ .words = &.{6}, .capacity = players.records.len } }, .channels = &.{fixture.mining.deps.visibility.player_entity}, .excluded = false }});
    const revealed = try fixture.tick();
    try std.testing.expectEqual(@as(usize, 2), revealed.recipients[1] + revealed.recipients[2]);
    try std.testing.expectEqual(@as(i8, 0), fixture.clients[count].stage);
    try std.testing.expectEqual(@as(i8, 0), fixture.clients[2 * count].stage);
    const block = game_data.registry.blocks[game_data.registry.block_state_to_block[game_data.registry.block_obsidian_default_state]];
    const loot = fixture.mining.deps.loot.evaluate(game_data.registry.block_obsidian_default_state, fixture.mining.states[0].tool.kind);
    const stage_ticks: u64 = @intFromFloat(@ceil(block.hardness * @as(f32, if (loot.harvest) 30 else 100) / loot.speed / 10));
    players.ticks = stage_ticks;
    _ = try fixture.tick();
    for (0..count) |recipient| for (0..count) |subject| {
        if (recipient != subject) try std.testing.expectEqual(@as(i8, 1), fixture.clients[recipient * count + subject].stage);
    };

    fixture.grant(0, 0);
    players.ticks = 2 * stage_ticks;
    _ = try fixture.tick();
    for (1..count) |subject| try std.testing.expectEqual(@as(i8, 1), fixture.clients[subject].stage);
    const pairs = fixture.mining.pair_checks.value();
    for (0..3) |_| try std.testing.expectEqual(@as(usize, 0), (try fixture.tick()).packets);
    try std.testing.expectEqual(pairs, fixture.mining.pair_checks.value());
    fixture.grantAll();
    const retry = try fixture.tick();
    try std.testing.expectEqual(count - 1, retry.packets);
    try std.testing.expectEqual(count - 1, retry.recipients[0]);
    for (retry.recipients[1..count]) |received| try std.testing.expectEqual(@as(usize, 0), received);
    for (1..count) |subject| try std.testing.expectEqual(@as(i8, 2), fixture.clients[subject].stage);

    const next: minecraft.BlockPosition = .{ .x = position.x + 1, .y = position.y, .z = position.z };
    var buffer: [128]u8 = undefined;
    const packet = try Protocol.play.toClient.write(&buffer).block_break_animation();
    const located = try (try packet.entityId(1)).location(.{ .x = position.x, .y = @intCast(position.y), .z = position.z });
    const removal = (try located.destroyStage(-1)).finish();
    fixture.grant(1, fixture.service.framedBound(removal.len));
    fixture.service.beginTick();
    try fixture.dig(0, 0, next);
    const retarget = try fixture.finishTick();
    try std.testing.expectEqual(@as(usize, 1), retarget.recipients[1]);
    try std.testing.expectEqual(@as(i8, 0), fixture.clients[count].stage);
    try std.testing.expectEqual(next, fixture.clients[count].position);
    for (2..count) |recipient| {
        try std.testing.expectEqual(@as(usize, 1), retarget.recipients[recipient]);
        try std.testing.expectEqual(@as(i8, 0), fixture.clients[recipient * count].stage);
        try std.testing.expectEqual(next, fixture.clients[recipient * count].position);
    }
    fixture.grantAll();
    const added = try fixture.tick();
    try std.testing.expectEqual(@as(usize, 0), added.packets);
    try std.testing.expectEqual(@as(usize, 0), added.recipients[1]);
    try std.testing.expectEqual(next, fixture.clients[count].position);
    fixture.service.beginTick();
    try fixture.dig(0, 1, next);
    try fixture.dig(2, 1, position);
    _ = try fixture.finishTick();
    for (0..count) |recipient| {
        try std.testing.expectEqual(@as(i8, -1), fixture.clients[recipient * count].stage);
        try std.testing.expectEqual(@as(i8, -1), fixture.clients[recipient * count + 2].stage);
    }

    const audience = fixture.mining.audience_checks.value();
    players.records[2].position.x = 256;
    players.rebuildIndexes();
    const departed = try fixture.tick();
    try std.testing.expectEqual(count - 2, departed.recipients[2]);
    try std.testing.expectEqual(@as(u64, 1), fixture.mining.audience_checks.value() - audience);
    for (fixture.clients[2 * count ..][0..count]) |client| try std.testing.expectEqual(@as(i8, -1), client.stage);
    players.records[2].position.x = 8;
    players.rebuildIndexes();
    const returned = try fixture.tick();
    try std.testing.expectEqual(count - 2, returned.recipients[2]);
    for (returned.recipients[0..count], 0..) |received, recipient| if (recipient != 2) try std.testing.expectEqual(@as(usize, 0), received);

    const home = players.records[2].world;
    players.records[2].world = fixture.other_world;
    fixture.clearClient(2);
    players.rebuildIndexes();
    try std.testing.expectEqual(@as(usize, 0), (try fixture.tick()).packets);
    players.records[2].world = home;
    fixture.clearClient(2);
    players.rebuildIndexes();
    try std.testing.expectEqual(count - 2, (try fixture.tick()).recipients[2]);

    players.records[3].handle.?.generation += 1;
    fixture.clearClient(3);
    fixture.grantAll();
    players.rebuildIndexes();
    const rejoined = try fixture.tick();
    try std.testing.expectEqual(count - 3, rejoined.recipients[3]);
    for (0..count) |recipient| try std.testing.expectEqual(@as(i8, -1), fixture.clients[recipient * count + 3].stage);

    players.records[4].life += 1;
    fixture.clearClient(4);
    const respawned = try fixture.tick();
    try std.testing.expectEqual(count - 4, respawned.recipients[4]);
    for (respawned.recipients[0..count], 0..) |received, recipient| if (recipient != 4) try std.testing.expectEqual(@as(usize, 0), received);

    fixture.service.beginTick();
    try fixture.dig(5, 1, position);
    _ = try fixture.finishTick();
    players.records[5].stage = .awaiting_teleport;
    _ = try fixture.tick();
    players.ticks = 3 * stage_ticks;
    _ = try fixture.tick();
    players.records[5].stage = .ready;
    const ready = try fixture.tick();
    try std.testing.expectEqual(count - 4, ready.recipients[5]);
    for (ready.recipients[0..count], 0..) |received, recipient| if (recipient != 5) try std.testing.expectEqual(@as(usize, 0), received);

    players.records[6].handle = null;
    players.rebuildIndexes();
    const disconnected = try fixture.tick();
    try std.testing.expectEqual(@as(usize, 0), disconnected.recipients[6]);
    for (0..count) |recipient| {
        if (recipient != 6) try std.testing.expectEqual(@as(i8, -1), fixture.clients[recipient * count + 6].stage);
    }
}

pub fn verifyReadWindow() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mining-window", .{temporary.sub_path});
    var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 128 });
    defer registry.deinit();
    var fixture = try Fixture.init(allocator, &store, &registry, 2);
    defer fixture.service.deinit();
    const Action = struct {
        terrain: *chunks.Chunks,
        calls: usize = 0,

        fn apply(self: *@This(), request: BlockActions.Request) !BlockActions.Result {
            try std.testing.expectEqual(@as(usize, 0), self.terrain.cache.pinned_entries);
            self.calls += 1;
            try self.terrain.setBlock(request.player.world, request.position, 0);
            try self.terrain.setBlock(request.player.world, .{ .x = request.position.x + 1, .y = request.position.y, .z = request.position.z }, 0);
            return .applied;
        }
    };
    var action: Action = .{ .terrain = fixture.mining.deps.chunks };
    const obsidian: u16 = @intCast(game_data.registry.block_obsidian_default_state);
    try fixture.mining.deps.actions.register(BlockActions.Handler.init(&action, obsidian, obsidian, Action.apply));
    for (fixture.mining.deps.players.records, fixture.mining.states, 0..) |*player, *state, index| {
        player.gamemode = .creative;
        state.* = .{ .generation = player.handle.?.generation, .teleport_id = player.teleport_id, .active = true, .complete = true, .position = .{ .x = position.x + @as(i32, @intCast(index)), .y = position.y, .z = position.z } };
    }
    _ = try fixture.tick();
    try std.testing.expectEqual(@as(usize, 1), action.calls);
    for (fixture.mining.states) |state| {
        try std.testing.expect(!state.active);
        try std.testing.expectEqual(@as(i8, -1), state.stage);
    }
    try std.testing.expectEqual(@as(usize, 0), action.terrain.cache.pinned_entries);
    const dropped = fixture.mining.deps.dropped;
    try std.testing.expectEqual(dropped.residents.len, dropped.free_count);

    const player = &fixture.mining.deps.players.records[0];
    player.gamemode = .survival;
    const ownership = fixture.mining.deps.inventories;
    const slot: inventories.Slot = .{ .owner = player.uuid, .index = 36 };
    const before = (try ownership.get(slot)).stack.?;
    const at: chunks.Position = .{ .x = position.x, .y = position.y, .z = position.z };
    try action.terrain.setBlock(player.world, at, game_data.registry.block_stone_default_state);
    fixture.mining.states[0] = .{ .generation = player.handle.?.generation, .teleport_id = player.teleport_id, .active = true, .complete = true, .position = position };
    _ = try fixture.tick();
    try std.testing.expectEqual(@as(u16, 0), try action.terrain.getBlock(player.world, at));
    try std.testing.expectEqual(@as(usize, 1), action.calls);
    try std.testing.expectEqual(dropped.residents.len - 1, dropped.free_count);
    const worn = (try ownership.get(slot)).stack.?;
    try std.testing.expectEqual(@as(u16, 1), worn.count);
    try std.testing.expect(!inventories.Stack.sameItem(before, worn));
    var cursor: ItemEntities.Cursor = .{};
    const rows = try dropped.scan(&cursor);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].metadata.alive);
    const body = (try dropped.deps.entities.get(rows[0].id)).?;
    const loot = (try ownership.get(ItemEntities.slot(body))).stack.?;
    try std.testing.expectEqual(@as(u16, 1), loot.count);
    try std.testing.expectEqual(@as(u32, @intCast(game_data.registry.itemId("minecraft:cobblestone").?)), try fixture.mining.deps.items.kind(loot));
}

pub fn verifyNeighborhoods() !void {
    for ([_]usize{ 16, 64, 256 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/mining-neighborhoods", .{temporary.sub_path});
        var store = try storage.Store.init(allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var registry = try metrics.Registry.init(allocator, std.testing.io, .{ .capacity = 128 });
        defer registry.deinit();
        var fixture = try Fixture.init(allocator, &store, &registry, count);
        defer fixture.service.deinit();
        const players = fixture.mining.deps.players;
        const terrain = fixture.mining.deps.chunks;
        const target: minecraft.BlockPosition = .{ .x = 16, .y = position.y, .z = position.z };
        try terrain.setBlock(players.records[0].world, .{ .x = target.x, .y = target.y, .z = target.z }, game_data.registry.block_obsidian_default_state);
        try terrain.setBlock(fixture.other_world, .{ .x = target.x, .y = target.y, .z = target.z }, game_data.registry.block_obsidian_default_state);
        for (players.records) |*player| player.position.x = 15.9;
        players.rebuildIndexes();
        const layer = try fixture.mining.deps.visibility.createLayer();
        const hidden = players.records[0].handle.?;
        const excluded = try allocator.alloc(usize, std.math.divCeil(usize, count, @bitSizeOf(usize)) catch unreachable);
        @memset(excluded, 0);
        excluded[0] = 2;
        try layer.updateMany(&.{.{ .subjects = &.{hidden}, .observers = .{ .players = .{ .words = excluded, .capacity = players.records.len } }, .channels = &.{fixture.mining.deps.visibility.player_entity}, .excluded = true }});
        failing.fail_index = failing.alloc_index;
        fixture.service.beginTick();
        for (0..count) |index| try fixture.dig(index, 0, target);
        _ = try fixture.finishTick();
        for (0..4) |step| {
            for (players.records, 0..) |*player, index| switch (step) {
                0 => player.position.x = 16.1,
                1 => {
                    if (index % 2 == 0) player.position.x += 1024;
                },
                2 => {
                    if (index % 2 == 0) player.world = fixture.other_world;
                },
                3 => {
                    player.world = players.spawn_world;
                    player.position.x = -16.1;
                },
                else => unreachable,
            };
            players.rebuildIndexes();
            _ = try fixture.tick();
            for (players.records, fixture.mining.views, 0..) |subject, view, index| {
                for (players.records, 0..) |observer, other| {
                    const expected = index != other and subject.world == observer.world and
                        @abs(@floor(subject.position.x / 16) - @floor(observer.position.x / 16)) <= @as(f64, @floatFromInt(players.config.render_distance)) and
                        @abs(@floor(subject.position.z / 16) - @floor(observer.position.z / 16)) <= @as(f64, @floatFromInt(players.config.render_distance)) and
                        fixture.mining.deps.visibility.player_entity.allows(subject.handle.?, other);
                    try std.testing.expectEqual(expected, view.interested.view().contains(other));
                }
            }
            try std.testing.expectEqual(@as(usize, 0), terrain.cache.pinned_entries);
        }
    }
}
