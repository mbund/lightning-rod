const audience_storage = @import("audience.zig");
const bit_sets = @import("lightning_rod").system.bit_sets;
const Visibility = @import("visibility.zig").Visibility;
const std = @import("std");
const block_synchronization = @import("block_sync.zig");
const terrain_background = @import("terrain.zig");
const network = @import("networking");
const protocols = @import("protocols");
const sessions = @import("sessions");
const packets = @import("minecraft_packets");
const storage = @import("storage");
const records = @import("records");
const inventories = @import("inventories");
const metrics = @import("metrics");
const game_data = @import("game_data");
const data = @import("item_data.zig");
const Items = @import("items.zig").Items;
const ItemProperties = @import("item_properties.zig").ItemProperties;
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const Bossbars = @import("bossbars.zig").Bossbars;
const Equipment = @import("equipment.zig").Equipment;
const Replication = @import("replication.zig").Replication;
const item_packets = @import("item_packets.zig");
const wire = @import("wire_1_21_5");
const ItemPickup = @import("item_pickup.zig").ItemPickup;
const chunks = @import("chunks");
const entities = @import("entities");
const worlds = @import("worlds");
const Lighting = @import("lighting.zig").Lighting;
const Streaming = @import("streaming.zig").Streaming;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const ItemReplication = @import("item_replication.zig").ItemReplication;
const SurvivalInventory = @import("survival_inventory.zig").SurvivalInventory;

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

pub fn benchmark() !void {
    const io = std.testing.io;
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &buffer);
    try output.interface.writeAll("name bytes | credit | mode                 | slot acquisitions | definition acquisitions | packets | queued bytes\n");
    for ([_]usize{ 0, 512 }) |name_bytes| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/inventory", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 2048 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        _ = try ItemProperties.init(allocator, .{ .items = items });
        var name: [515]u8 = @splat('x');
        name[0] = 8;
        std.mem.writeInt(u16, name[1..3], @intCast(name_bytes), .big);
        const item = if (name_bytes == 0) try items.define("minecraft:bread") else try data.define(ownership, @intCast(game_data.registry.itemId("minecraft:bread").?), &.{.{ .key = data.key(.custom_name), .value = name[0 .. name_bytes + 3] }});
        var edits: [37]inventories.Edit = undefined;
        for (&edits, 0..) |*edit, index| edit.* = .{ .slot = .{ .owner = 1, .index = @intCast(index + 9) }, .revision = 0, .stack = .{ .item = item, .count = 64 } };
        try std.testing.expect(try ownership.editMany(&edits));
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = 1, .pages = 4, .page_bytes = 64 * 1024, .buffer_bytes = 256 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const handle: sessions.Handle = .{ .index = 0, .generation = 1 };
        var players_buffer: [1]Players.Player = .{.{ .handle = handle, .uuid = 1, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &players_buffer, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const menu = try PlayerInventory.init(allocator, .{
            .players = &players,
            .inventories = ownership,
            .items = items,
            .equipment = undefined,
            .dropped = undefined,
        });
        var survival: SurvivalInventory = .{ .deps = .{ .inventory = menu, .players = &players, .inventories = ownership, .items = items, .packets = encoding, .sessions = service, .input = undefined } };
        const Mode = enum { survival_dirty_one, survival_dirty_many, survival_cursor, survival_full, full_direct, single_slot_direct };
        for ([_]bool{ true, false }) |available| for (std.enums.values(Mode)) |mode| {
            const player = players_buffer[0];
            menu.states[0] = .{ .generation = handle.generation, .life = player.life, .dirty = @as(u64, 1) << 36, .close = false, .gamemode = .survival, .revision = 12, .synchronized = true };
            const expected_slots: usize = switch (mode) {
                .survival_full, .full_direct => 47,
                .survival_dirty_many => 3,
                else => 1,
            };
            menu.states[0].dirty = switch (mode) {
                .survival_full => PlayerInventory.all_slots,
                .survival_dirty_many => (@as(u64, 1) << 9) | (@as(u64, 1) << 36) | (@as(u64, 1) << 45),
                .survival_cursor => @as(u64, 1) << PlayerInventory.cursor,
                else => @as(u64, 1) << 36,
            };
            const dirty_before = menu.states[0].dirty;
            const credit = if (available) service.config.buffer_bytes else 0;
            service.credit[0].store((@as(u64, handle.generation) << 32) | sessions.Service.active | credit, .release);
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try menu.load(0, &slots, &contents);
            var cursor_buffer: [32]u8 = undefined;
            const expected_cursor = try encoding.writePacket(PlayerInventory.writeCursor, player.protocol, &cursor_buffer, .{ items, @as(?inventories.Stack, null), player.uuid, @as(?Items.View, null) });
            const before = ownership.items.metrics.acquired.value();
            const slots_before = ownership.cache.metrics.acquired.value();
            service.beginTick();
            switch (mode) {
                .survival_dirty_one, .survival_dirty_many, .survival_cursor, .survival_full => try survival.tick(),
                .full_direct => {
                    try menu.load(0, &slots, &contents);
                    encoding.sendPacket(PlayerInventory.writeInventory, player.protocol, handle, .{ items, @as(i32, 12), &contents, player.uuid }, service.config.page_bytes) catch |err| {
                        if (err != error.Backpressured) return err;
                    };
                },
                .single_slot_direct => {
                    const changed = try ownership.get(.{ .owner = player.uuid, .index = 36 });
                    const prepared = try items.acquire(changed.stack.?);
                    defer prepared.release();
                    encoding.sendPacket(PlayerInventory.writeSlot, player.protocol, handle, .{ items, @as(i32, 12), @as(i16, 36), changed.stack, player.uuid, prepared.view }, service.config.page_bytes) catch |err| {
                        if (err != error.Backpressured) return err;
                    };
                },
            }
            service.endTick(true);
            service.flush();
            var batch = service.outputBatch();
            var bytes: usize = 0;
            var count: usize = 0;
            while (batch.next()) |packet| {
                if (mode == .survival_cursor) try std.testing.expectEqualSlices(u8, expected_cursor, packet.bytes);
                bytes += packet.bytes.len;
                count += 1;
                service.recycle(io, &.{packet});
            }
            try std.testing.expectEqual(@as(usize, if (available) (if (mode == .survival_dirty_many) 3 else 1) else 0), count);
            if (mode != .full_direct and mode != .single_slot_direct) {
                try std.testing.expectEqual(if (available) @as(u64, 0) else dirty_before, menu.states[0].dirty);
                try std.testing.expectEqual(if (available) expected_slots else 0, ownership.cache.metrics.acquired.value() - slots_before);
                try std.testing.expectEqual(if (available) (if (mode == .survival_full) @as(usize, 37) else if (mode == .survival_cursor) @as(usize, 0) else expected_slots) else 0, ownership.items.metrics.acquired.value() - before);
            }
            try output.interface.print("{d:10} | {d:6} | {s:20} | {d:17} | {d:23} | {d:7} | {d}\n", .{ name_bytes, credit, @tagName(mode), ownership.cache.metrics.acquired.value() - slots_before, ownership.items.metrics.acquired.value() - before, count, bytes });
        };
    }
    try output.interface.flush();
}

pub fn benchmarkEquipment() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("players | definition capacity | mode             | slot acquisitions | definition acquisitions | packets | payload bytes\n");
    for ([_]usize{ 8, 2 }) |definition_capacity| for ([_]usize{ 2, 16, 64 }) |count| {
        if (definition_capacity == 2 and count != 2) continue;
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/equipment", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 512, .cache_items = definition_capacity, .max_item_bytes = 2048 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        var stacks: [6]inventories.Stack = undefined;
        for (&stacks, [_][]const u8{ "minecraft:bread", "minecraft:bread", "minecraft:diamond_boots", "minecraft:diamond_leggings", "minecraft:diamond_chestplate", "minecraft:diamond_helmet" }) |*stack, name| {
            stack.* = .{ .item = try items.define(name), .count = 1 };
        }
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 16, .page_bytes = 64 * 1024, .buffer_bytes = 256 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        players.deps.sessions = service;
        for (player_records, service.credit, 0..) |*player, *credit, index| {
            player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number };
            credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            var edits: [6]inventories.Edit = undefined;
            for (&edits, stacks, [_]u16{ 36, 45, 8, 7, 6, 5 }) |*edit, stack, slot| edit.* = .{ .slot = .{ .owner = player.uuid, .index = slot }, .revision = 0, .stack = stack };
            try std.testing.expect(try ownership.editMany(&edits));
        }
        const replication = try Replication.init(allocator, .{}, .{ .players = &players, .visibility = try Visibility.init(allocator, .{}, .{ .players = &players }) });
        const equipment = try Equipment.init(allocator, .{}, .{
            .replication = replication,
            .menus = undefined,
            .players = &players,
            .inventories = ownership,
            .items = items,
            .sessions = service,
            .packets = encoding,
            .placement = undefined,
            .mining = undefined,
            .pickup = undefined,
        });
        const Mode = enum { unobserved_idle, initial_equipment, observed_idle, grouped_reference, blocked_equipment, after_blocked, limited_credit, inventory_edit, failed_edit, selected_slot, inventory_move, presentation, many_edits, unrelated_edits, viewer_reconnect, viewer_respawn, subject_reconnect, small_page };
        for (std.enums.values(Mode)) |mode| {
            if (mode != .unobserved_idle and count != 2) continue;
            if (definition_capacity < 6 and (mode == .grouped_reference or mode == .limited_credit)) continue;
            replication.viewer_masks.clear();
            if (mode != .unobserved_idle) replication.viewer_masks.row(0).insert(1);
            replication.viewer_revisions[0] += 1;
            service.config.page_bytes = if (mode == .small_page) 72 else 64 * 1024;
            const recipient = &player_records[1];
            if (mode == .viewer_reconnect) recipient.handle.?.generation += 1;
            if (mode == .viewer_respawn) recipient.life += 1;
            service.credit[1].store((@as(u64, recipient.handle.?.generation) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            switch (mode) {
                .inventory_edit => {
                    const old = try ownership.get(.{ .owner = 1, .index = 36 });
                    try std.testing.expect(try ownership.set(.{ .owner = 1, .index = 36 }, old.revision, .{ .item = stacks[0].item, .count = 2 }));
                },
                .failed_edit => try std.testing.expect(!try ownership.set(.{ .owner = 1, .index = 36 }, 0, null)),
                .selected_slot => player_records[0].selected_slot = 1,
                .inventory_move => {
                    player_records[0].selected_slot = 0;
                    const from = try ownership.get(.{ .owner = 1, .index = 36 });
                    const to = try ownership.get(.{ .owner = 1, .index = 45 });
                    try std.testing.expectEqual(inventories.MoveResult.moved, try ownership.move(.{
                        .from = .{ .owner = 1, .index = 36 },
                        .to = .{ .owner = 1, .index = 45 },
                        .from_revision = from.revision,
                        .to_revision = to.revision,
                        .count = 1,
                        .maximum_stack = 64,
                    }));
                },
                .presentation, .small_page, .limited_credit => items.components.changed(),
                .many_edits => {
                    const slot: inventories.Slot = .{ .owner = 1, .index = 36 };
                    const old = try ownership.get(slot);
                    for (0..1024) |index| try std.testing.expect(try ownership.set(slot, old.revision + index, old.stack));
                },
                .unrelated_edits => {
                    const slot: inventories.Slot = .{ .owner = 1 << 127, .index = 0 };
                    for (0..1024) |index| try std.testing.expect(try ownership.set(slot, index, .{ .item = stacks[0].item, .count = @intCast(1 + index % 2) }));
                },
                .subject_reconnect => player_records[0].life += 1,
                else => {},
            }
            if (mode == .blocked_equipment) {
                equipment.subjects[0].watchers.clear();
                service.credit[1].store((@as(u64, 1) << 32) | sessions.Service.active, .release);
            }
            if (mode == .limited_credit) service.credit[1].store((@as(u64, recipient.handle.?.generation) << 32) | sessions.Service.active | service.framedBound(38), .release);
            if (mode == .unobserved_idle) try equipment.tick();
            const before = ownership.items.metrics.acquired.value();
            const slots_before = ownership.cache.metrics.acquired.value();
            service.beginTick();
            if (mode == .grouped_reference) {
                var prepared: [6]Items.Prepared = undefined;
                try items.acquireMany(&stacks, &prepared);
                defer for (prepared) |held| held.release();
                var views: [6]Items.View = undefined;
                for (prepared, &views) |held, *view| view.* = held.view;
                try encoding.sendPacket(writeEquipmentGroup, catalog.values[0].number, player_records[1].handle.?, .{ items, &stacks, &views }, 512);
            } else try equipment.tick();
            service.endTick(true);
            service.flush();
            var batch = service.outputBatch();
            var packets_count: usize = 0;
            var bytes: usize = 0;
            while (batch.next()) |packet| {
                packets_count += 1;
                bytes += packet.bytes.len;
                service.recycle(io, &.{packet});
            }
            const expected: usize = switch (mode) {
                .unobserved_idle, .observed_idle, .blocked_equipment, .failed_edit, .unrelated_edits => 0,
                .small_page => 3,
                .initial_equipment, .after_blocked, .presentation, .viewer_reconnect, .viewer_respawn, .subject_reconnect => (6 + definition_capacity - 1) / definition_capacity,
                else => 1,
            };
            try std.testing.expectEqual(expected, packets_count);
            if (mode == .blocked_equipment) try std.testing.expectEqual(@as(usize, 2), equipment.subjects[0].pending.view().wordAt(0));
            if (mode == .after_blocked or mode == .viewer_reconnect or mode == .viewer_respawn)
                try std.testing.expectEqual(@as(usize, 0), equipment.subjects[0].pending.view().count());
            const acquired: usize = switch (mode) {
                .initial_equipment, .subject_reconnect => 6,
                .inventory_edit, .selected_slot, .many_edits => 1,
                .inventory_move => 2,
                else => 0,
            };
            try std.testing.expectEqual(acquired, ownership.cache.metrics.acquired.value() - slots_before);
            const definitions: usize = switch (mode) {
                .unobserved_idle, .observed_idle, .blocked_equipment, .failed_edit, .selected_slot, .unrelated_edits => 0,
                .inventory_edit, .many_edits => 1,
                .inventory_move => 2,
                else => 6,
            };
            try std.testing.expectEqual(definitions, ownership.items.metrics.acquired.value() - before);
            try output.interface.print("{d:7} | {d:19} | {s:16} | {d:17} | {d:23} | {d:7} | {d}\n", .{ count, definition_capacity, @tagName(mode), ownership.cache.metrics.acquired.value() - slots_before, ownership.items.metrics.acquired.value() - before, packets_count, bytes });
        }
    };
    try output.interface.flush();
}

fn writeEquipmentGroup(packet: wire.play.toClient.packet_entity_equipment.Writer, registry: packets.Registry, items: *Items, stacks: *const [6]inventories.Stack, views: *const [6]Items.View) ![]u8 {
    var entries = try (try packet.entityId(1)).equipments(6);
    for (stacks, views, 0..) |stack, view, slot| {
        const entry = (try entries.next()).?;
        var item = try (try entry.slot(@intCast(slot))).item();
        const done = try item_packets.writeSlot(try item.begin(), .{ .registry = registry, .items = items, .stack = stack, .recipient = 2, .view = view });
        try entries.advance(try item.advance(done));
    }
    return (try entries.finish()).finish();
}

pub fn benchmarkPickup() !void {
    const io = std.testing.io;
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("slot capacity | pickup count | mode            | slot acquisitions | cache misses | slot edits | collected\n");
    for ([_]usize{ 128, 47 }) |slot_capacity| for ([_]usize{ 1, 16, 64 }) |count| for ([_]bool{ false, true }) |batched| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/pickup", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = slot_capacity, .cache_items = 2, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .stage = .ready, .loaded = true, .gamemode = .survival }};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const menu = try PlayerInventory.init(allocator, .{
            .players = &players,
            .inventories = ownership,
            .items = items,
            .equipment = undefined,
            .dropped = undefined,
        });
        const bodies = try entities.Entities.allocate(allocator, io, .{ .cache_records = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
        const dropped = try ItemEntities.allocate(allocator, io, .{ .cache_records = 4, .maximum = 1 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        const pickup = try ItemPickup.init(allocator, .{ .players = &players, .menus = menu, .inventories = ownership, .entities = bodies, .items = items, .dropped = dropped });
        var sources: [64]inventories.Slot = undefined;
        var edits: [101]inventories.Edit = undefined;
        for (sources[0..count], edits[0..count], 0..) |*source, *edit, index| {
            source.* = .{ .owner = 100, .index = @intCast(index) };
            edit.* = .{ .slot = source.*, .revision = 0, .stack = stack };
        }
        var cursor: usize = 0;
        while (cursor < count) {
            const length = @min(count - cursor, slot_capacity);
            try std.testing.expect(try ownership.editMany(edits[cursor..][0..length]));
            cursor += length;
        }
        var slots: [101]inventories.Slot = undefined;
        for (slots[0..36], 0..) |*slot, index| slot.* = .{ .owner = 1, .index = @intCast(if (index < 9) index + 36 else index) };
        slots[36] = .{ .owner = 1, .index = 45 };
        @memcpy(slots[37..][0..count], sources[0..count]);
        var contents: [101]inventories.Contents = undefined;
        cursor = 0;
        while (cursor < 37 + count) {
            const length = @min(37 + count - cursor, slot_capacity);
            try ownership.getMany(slots[cursor..][0..length], contents[cursor..][0..length]);
            cursor += length;
        }
        const before = ownership.cache.metrics.acquired.value();
        const misses = ownership.cache.metrics.misses.value();
        var collected: usize = 0;
        var requests: [64]ItemPickup.Request = undefined;
        var results: [64]ItemPickup.Result = undefined;
        for (sources[0..count], requests[0..count]) |source, *request| request.* = .{ .source = source };
        if (batched) {
            try pickup.collect(0, requests[0..count], results[0..count]);
        } else {
            for (0..count) |index| try pickup.collect(0, requests[index..][0..1], results[index..][0..1]);
        }
        for (results[0..count]) |result| collected += result.collected;
        const acquisitions = ownership.cache.metrics.acquired.value() - before;
        const missed = ownership.cache.metrics.misses.value() - misses;
        try std.testing.expectEqual(count, collected);
        const final = try ownership.get(slots[0]);
        var changed: u64 = final.revision;
        for (sources[0..count]) |source| changed += (try ownership.get(source)).revision - 1;
        try std.testing.expectEqual(@as(u16, @intCast(count)), final.stack.?.count);
        for (slots[1..37]) |slot| try std.testing.expectEqual(null, (try ownership.get(slot)).stack);
        for (sources[0..count]) |source| try std.testing.expectEqual(null, (try ownership.get(source)).stack);
        const window = @min(64, slot_capacity - 37);
        const windows = if (batched) (count + window - 1) / window else count;
        try std.testing.expectEqual(36 + 2 * windows + 2 * count, acquisitions);
        if (slot_capacity == 128) try std.testing.expectEqual(@as(usize, 0), missed);
        try std.testing.expectEqual(count + windows, changed);
        try output.interface.print("{d:13} | {d:12} | {s:15} | {d:17} | {d:12} | {d:10} | {d}\n", .{ slot_capacity, count, if (batched) "collect_batch" else "collect_single", acquisitions, missed, changed, collected });
    };
    try output.interface.flush();
}

pub fn benchmarkItemReplication() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("dropped items | mode          | slot acquisitions | definition acquisitions | packets\n");
    for ([_]usize{ 1, 16, 64 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 128 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 64 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        var ids: [64]entities.Id = undefined;
        for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 0.5, 65, 0.5 }, @splat(0), stack);
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = 1, .pages = 512, .page_bytes = 4096, .buffer_bytes = 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        var player_records: [1]Players.Player = .{.{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number }};
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);
        const replication = try ItemReplication.init(allocator, .{}, .{ .dropped = dropped, .item_tick = undefined, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .entities = bodies, .inventories = ownership, .items = items });
        const Mode = enum { blocked_spawn, spawn, unchanged, single_move, unchanged_after_single_move, single_stack, unchanged_after_single_stack, age_only, blocked_change, change, mutation, unchanged_after_mutation, blocked_mutation, resumed_mutation, blocked_retirement, retirement, reuse, unchanged_after_reuse, leave_view, return_view, viewer_reset };
        for (std.enums.values(Mode)) |mode| {
            const blocked = mode == .blocked_spawn or mode == .blocked_change or mode == .blocked_mutation or mode == .blocked_retirement;
            if (mode == .single_move) {
                var held: [1]ItemEntities.Record = undefined;
                try dropped.acquireMany(ids[0..1], &held);
                defer held[0].release();
                const before = (try held[0].body.read()).?;
                var after = before;
                after.position[0] += 0.125;
                const spatial_revision = dropped.spatial.revision;
                try dropped.move(held[0], before, after);
                try std.testing.expectEqual(spatial_revision, dropped.spatial.revision);
                try std.testing.expectEqualSlices(f64, &.{ after.position[0], after.position[2] }, &dropped.residents[dropped.ids.get(ids[0]).?].position);
                var metadata = try held[0].read();
                metadata.revision += 1;
                held[0].write(metadata);
            }
            if (mode == .single_stack) {
                const body = (try bodies.get(ids[0])).?;
                const slot = ItemEntities.slot(body);
                const previous = try ownership.get(slot);
                try std.testing.expect(try ownership.set(slot, previous.revision, .{ .item = stack.item, .count = 2 }));
            }
            if (mode == .blocked_change) items.components.changed();
            if (mode == .mutation or mode == .blocked_mutation or mode == .blocked_retirement) for (ids[0..count]) |id| {
                const body = (try bodies.get(id)).?;
                const slot = ItemEntities.slot(body);
                const previous = try ownership.get(slot);
                try std.testing.expect(try ownership.set(slot, previous.revision, if (mode == .blocked_retirement) null else .{ .item = stack.item, .count = @as(u16, if (mode == .mutation) 2 else 3) }));
                if (mode == .blocked_retirement) {
                    var metadata = try dropped.get(id);
                    metadata.collector = 1;
                    metadata.collected = 3;
                    metadata.collection += 1;
                    try dropped.retire(id, body, &metadata);
                }
            };
            if (mode == .reuse) for (ids[0..count]) |*id| {
                id.* = try dropped.create(world, .{ 0.5, 65, 0.5 }, @splat(0), stack);
            };
            if (mode == .age_only) for (ids[0..count]) |id| {
                var held_records: [1]ItemEntities.Record = undefined;
                try dropped.acquireMany(&.{id}, &held_records);
                defer held_records[0].release();
                var metadata = try held_records[0].read();
                metadata.age += 1;
                metadata.ticks += 1;
                held_records[0].write(metadata);
            };
            if (mode == .leave_view) {
                player_records[0].position.x = 1000;
                players.rebuildIndexes();
            }
            if (mode == .return_view) {
                player_records[0].position.x = 0;
                players.rebuildIndexes();
            }
            if (mode == .viewer_reset) {
                player_records[0].life += 1;
                var publication = streaming.published.streams[0];
                publication.life = player_records[0].life;
                streaming.published.setStream(0, publication);
            }
            const metadata_before = dropped.cache.metrics.acquired.value();
            const bodies_before = bodies.cache.metrics.acquired.value();
            service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active | @as(u64, if (blocked) 0 else service.config.buffer_bytes), .release);
            const slots_before = ownership.cache.metrics.acquired.value();
            const definitions_before = ownership.items.metrics.acquired.value();
            service.beginTick();
            try replication.tick();
            service.endTick(true);
            service.flush();
            var batch = service.outputBatch();
            var queued: usize = 0;
            while (batch.next()) |packet| {
                queued += 1;
                service.recycle(io, &.{packet});
            }
            const unchanged = mode == .age_only or mode == .unchanged or mode == .unchanged_after_single_move or mode == .unchanged_after_single_stack or mode == .unchanged_after_mutation or mode == .unchanged_after_reuse;
            if (blocked or unchanged) try std.testing.expectEqual(@as(usize, 0), queued) else try std.testing.expect(queued >= (if (mode == .single_move or mode == .single_stack) @as(usize, 1) else count));
            if (unchanged) {
                try std.testing.expectEqual(metadata_before, dropped.cache.metrics.acquired.value());
                try std.testing.expectEqual(bodies_before, bodies.cache.metrics.acquired.value());
            }
            if (mode == .single_move or mode == .single_stack) {
                try std.testing.expectEqual(@as(u64, 1), dropped.cache.metrics.acquired.value() - metadata_before);
                try std.testing.expectEqual(@as(u64, 1), bodies.cache.metrics.acquired.value() - bodies_before);
                try std.testing.expectEqual(@as(usize, 1), queued);
            }
            const acquired: usize = switch (mode) {
                .single_stack => 1,
                .spawn, .mutation, .resumed_mutation, .reuse => count,
                else => 0,
            };
            const prepared: usize = if (mode == .change or mode == .return_view or mode == .viewer_reset) count else acquired;
            try std.testing.expectEqual(acquired, ownership.cache.metrics.acquired.value() - slots_before);
            try std.testing.expectEqual(prepared, ownership.items.metrics.acquired.value() - definitions_before);
            if (mode == .retirement) try std.testing.expectEqual(@as(usize, 0), replication.inventory_observer.owners.count());
            if (mode == .mutation or mode == .resumed_mutation or mode == .reuse or mode == .unchanged_after_reuse) for (ids[0..count]) |id| {
                const view = replication.views[dropped.ids.get(id).?];
                const expected: u16 = if (mode == .mutation) 2 else if (mode == .resumed_mutation) 3 else 1;
                try std.testing.expectEqual(expected, view.contents.stack.?.count);
                try std.testing.expectEqual(@as(u64, 0), view.inventory_dirty);
            };
            try output.interface.print("{d:13} | {s:13} | {d:17} | {d:23} | {d}\n", .{ count, @tagName(mode), ownership.cache.metrics.acquired.value() - slots_before, ownership.items.metrics.acquired.value() - definitions_before, queued });
        }
    }
    try output.interface.flush();
}

pub fn benchmarkBossbars() !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    var sink: Sink = .{};
    const service = try sessions.Service.init(allocator, std.testing.io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = 2, .pages = 16, .page_bytes = 4096, .buffer_bytes = 256 * 1024, .protocols = &catalog.values });
    defer service.deinit();
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    var player_records: [2]Players.Player = undefined;
    for (&player_records, 0..) |*player, index| {
        player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .stage = .ready, .protocol = catalog.values[0].number };
        service.credit[index].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    player_records[1].stage = .login;
    var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = &player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    players.rebuildIndexes();
    const bars = try Bossbars.init(allocator, .{ .players = &players, .packets = encoding }, .{ .maximum = 2 });
    const first = try bars.create(.{ .title = "", .progress = 0 });
    const second = try bars.create(.{ .title = "private", .audience = .{ .player = 2 } });
    const Drain = struct {
        fn expect(owner: *sessions.Service, expected: [2]usize) !void {
            owner.flush();
            var batch = owner.outputBatch();
            var actual: [2]usize = @splat(0);
            while (batch.next()) |packet| {
                var recipient_iterator = packet.recipients.iterator();
                while (recipient_iterator.next()) |handle| actual[handle.index] += 1;
                owner.recycle(std.testing.io, &.{packet});
            }
            try std.testing.expectEqual(expected, actual);
        }
    };
    try bars.tick();
    try Drain.expect(service, .{ 1, 0 });
    player_records[1].stage = .ready;
    try bars.tick();
    try Drain.expect(service, .{ 0, 2 });
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    try bars.update(first, .{ .title = "changed", .progress = 0 });
    try bars.tick();
    try Drain.expect(service, .{ 1, 0 });
    try bars.tick();
    try Drain.expect(service, .{ 0, 0 });
    try bars.update(first, .{ .title = "latest", .progress = 0.5 });
    try bars.tick();
    try Drain.expect(service, .{ 2, 0 });
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try bars.tick();
    try Drain.expect(service, .{ 0, 2 });
    try std.testing.expectEqual(@as(u64, 0), bars.pending);
    try bars.update(second, .{ .title = "private", .audience = .{ .player = 1 } });
    try bars.tick();
    try Drain.expect(service, .{ 1, 1 });
    service.credit[1].store(@as(u64, 1) << 32 | sessions.Service.active, .release);
    try bars.remove(first);
    try bars.tick();
    try Drain.expect(service, .{ 1, 0 });
    player_records[1].life += 1;
    try bars.tick();
    try Drain.expect(service, .{ 0, 0 });
    try std.testing.expect(bars.pending != 0);
    player_records[1].handle = null;
    try bars.tick();
    try Drain.expect(service, .{ 0, 0 });
    try std.testing.expectEqual(@as(u64, 0), bars.pending);
    player_records[1].handle = .{ .index = 1, .generation = 2 };
    service.credit[1].store(@as(u64, 2) << 32 | sessions.Service.active | service.config.buffer_bytes, .release);
    try bars.tick();
    try Drain.expect(service, .{ 0, 0 });
    const reused = try bars.create(.{ .title = "", .progress = 0 });
    try std.testing.expectEqual(first.index, reused.index);
    try std.testing.expect(reused.generation != first.generation);
    try bars.tick();
    try Drain.expect(service, .{ 1, 1 });
    for (0..64) |_| {
        try bars.tick();
        try std.testing.expectEqual(@as(u64, 0), bars.pending);
        try Drain.expect(service, .{ 0, 0 });
    }
    player_records[0].life += 1;
    try bars.tick();
    try Drain.expect(service, .{ 2, 0 });
}

pub fn benchmarkDrops() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("drops | body acquisitions | metadata acquisitions | inventory acquisitions | definition acquisitions\n");
    for ([_]usize{ 1, 16, 64 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 128, .cache_items = 2, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 128 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 64 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        const player: Players.Player = .{ .uuid = 1, .world = world, .position = .{ .x = 0, .y = 65, .z = 0 } };
        var player_records: [1]Players.Player = .{player};
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const menu = try PlayerInventory.init(allocator, .{
            .players = &players,
            .inventories = ownership,
            .items = items,
            .equipment = undefined,
            .dropped = dropped,
        });
        var stacks: [64]inventories.Stack = @splat(stack);
        const next_id = bodies.next_id;
        try std.testing.expectError(error.InvalidStack, menu.dropMany(player, &.{ stack, .{ .item = stack.item, .count = 0 } }));
        try std.testing.expectEqual(next_id, bodies.next_id);
        try std.testing.expectEqual(@as(usize, 64), dropped.free_count);
        const body_before = bodies.cache.metrics.acquired.value();
        const metadata_before = dropped.cache.metrics.acquired.value();
        const slots_before = ownership.cache.metrics.acquired.value();
        const definitions_before = ownership.items.metrics.acquired.value();
        try std.testing.expect(try menu.dropMany(player, stacks[0..count]));
        try std.testing.expectEqual(@as(u64, count), bodies.cache.metrics.acquired.value() - body_before);
        try std.testing.expectEqual(@as(u64, count), dropped.cache.metrics.acquired.value() - metadata_before);
        try std.testing.expectEqual(@as(u64, count), ownership.cache.metrics.acquired.value() - slots_before);
        try std.testing.expectEqual(@as(u64, 1), ownership.items.metrics.acquired.value() - definitions_before);
        try output.interface.print("{d:5} | {d:17} | {d:21} | {d:22} | {d}\n", .{ count, bodies.cache.metrics.acquired.value() - body_before, dropped.cache.metrics.acquired.value() - metadata_before, ownership.cache.metrics.acquired.value() - slots_before, ownership.items.metrics.acquired.value() - definitions_before });
        for (next_id..bodies.next_id) |entity| {
            const metadata = try dropped.get(entity);
            try std.testing.expectEqual(@as(u16, 40), metadata.pickup_delay);
            const body = (try bodies.get(entity)).?;
            try std.testing.expectEqual(world, body.world);
            const held = try ownership.get(ItemEntities.slot(body));
            try std.testing.expectEqual(stack, held.stack.?);
            try std.testing.expectEqual(@as(u64, 1), held.revision);
        }
        const after = bodies.next_id;
        try std.testing.expect(!try menu.dropMany(player, &stacks));
        try std.testing.expectEqual(after, bodies.next_id);
    }
    try output.interface.flush();
}

pub fn benchmarkItemMovement() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("player capacity | dropped items | viewer movement | metadata acquisitions | body acquisitions | backend record reads | packets\n");
    for ([_]usize{ 16, 256, 1024 }) |count| try verifyItemMovement(count, 1, &output.interface);
    try verifyItemMovement(16, 2049, &output.interface);
    try output.interface.flush();
}

fn verifyItemMovement(count: usize, capacity: usize, output: *std.Io.Writer) !void {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
    defer registry.deinit();
    const workspaces = try records.Workspaces.init(allocator, io, .{});
    const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 1024, .cache_items = 8, .max_item_bytes = 1024 }, .{
        .metrics = &registry,
        .storage = try store.openSpace("inventory"),
        .record_workspaces = workspaces,
    });
    const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
    const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 64 };
    const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 256 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
    const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
    const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
    const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 1024 }, .{
        .metrics = &registry,
        .record_workspaces = workspaces,
        .entities = bodies,
        .inventories = ownership,
        .items = items,
        .worlds = dimensions,
        .storage = try store.openSpace("metadata"),
    });
    var ids: [1024]entities.Id = undefined;
    for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 0.5, 65, 0.5 }, @splat(0), stack);
    var catalog = try protocols.Default.init(allocator);
    defer catalog.deinit(allocator);
    var sink: Sink = .{};
    const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
    const service = try sessions.Service.init(allocator, io, transport, .{ .connections = capacity, .pages = if (capacity == 1) 8192 else 128, .page_bytes = 4096, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
    defer service.deinit();
    const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
    const connection = capacity - 1;
    const player_records = try allocator.alloc(Players.Player, capacity);
    @memset(player_records, .{});
    player_records[connection] = .{ .handle = .{ .index = connection, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number };
    var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
    try players.initIndexes(allocator);
    player_records[connection].position.x = 1;
    player_records[connection].position.z = 1;
    players.rebuildIndexes();
    const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
    const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
    defer service.unsubscribeOutput(streaming.changed);
    defer terrain.unsubscribeReady(streaming.changed);
    streaming.published.setStream(connection, .{ .generation = 1, .life = player_records[connection].life, .setup = .streaming });
    @memset(streaming.published.sent, std.math.maxInt(u64));
    streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);
    const replication = try ItemReplication.init(allocator, .{}, .{ .dropped = dropped, .item_tick = undefined, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .entities = bodies, .inventories = ownership, .items = items });

    const Step = struct { position: [2]f64, visible: bool = true, unchanged: bool = false };
    const steps = [_]Step{
        .{ .position = .{ 1, 1 } },
        .{ .position = .{ 1, 1 }, .unchanged = true },
        .{ .position = .{ 1.125, 1 }, .unchanged = true },
        .{ .position = .{ 1.125, 1.125 }, .unchanged = true },
        .{ .position = .{ 1, 1 }, .unchanged = true },
        .{ .position = .{ 96.5, 0 } },
        .{ .position = .{ 96.625, 0 }, .visible = false },
        .{ .position = .{ 96.5, 0 } },
        .{ .position = .{ 0, 96.5 } },
        .{ .position = .{ 0, 96.625 }, .visible = false },
        .{ .position = .{ 0, 96.5 } },
        .{ .position = .{ 96.5, 96.5 } },
        .{ .position = .{ 96.625, 96.625 }, .visible = false },
        .{ .position = .{ 96.5, 96.5 } },
        .{ .position = .{ -95.5, 0 } },
        .{ .position = .{ -95.625, 0 }, .visible = false },
        .{ .position = .{ -95.5, 0 } },
        .{ .position = .{ 0, -95.5 } },
        .{ .position = .{ 0, -95.625 }, .visible = false },
        .{ .position = .{ 0, -95.5 } },
    };
    var was_visible = false;
    for (steps, 0..) |step, index| {
        player_records[connection].position.x = step.position[0];
        player_records[connection].position.z = step.position[1];
        players.rebuildIndexes();
        const metadata_before = dropped.cache.metrics.acquired.value();
        const bodies_before = bodies.cache.metrics.acquired.value();
        const reads_before = dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value();
        service.credit[connection].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        service.beginTick();
        try replication.tick();
        service.endTick(true);
        service.flush();
        var batch = service.outputBatch();
        var queued: usize = 0;
        while (batch.next()) |packet| {
            queued += 1;
            service.recycle(io, &.{packet});
        }
        const metadata_acquired = dropped.cache.metrics.acquired.value() - metadata_before;
        const bodies_acquired = bodies.cache.metrics.acquired.value() - bodies_before;
        const reads = dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value() - reads_before;
        if (step.unchanged) {
            try std.testing.expectEqual(@as(u64, 0), metadata_acquired);
            try std.testing.expectEqual(@as(u64, 0), bodies_acquired);
            try std.testing.expectEqual(@as(u64, 0), reads);
        }
        if (was_visible == step.visible) try std.testing.expectEqual(@as(usize, 0), queued) else try std.testing.expect(queued > 0);
        for (ids[0..count]) |id| {
            const view = replication.views[dropped.ids.get(id).?];
            try std.testing.expectEqual(@as(usize, if (step.visible) 1 else 0), view.spawned.view().count());
            try std.testing.expectEqual(@as(usize, 0), view.pending.view().count());
        }
        was_visible = step.visible;
        try output.print("{d:15} | {d:13} | {d:15} | {d:21} | {d:17} | {d:20} | {d}\n", .{ capacity, count, index, metadata_acquired, bodies_acquired, reads, queued });
    }
}

pub fn benchmarkItemVisibility() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Item visibility changes\n");
    for ([_]usize{ 64, 256, 1024 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 1024, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 64 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 256 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 1024 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        var ids: [1024]entities.Id = undefined;
        for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 0.5, 65, 0.5 }, @splat(0), stack);
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = 2, .pages = 8192, .page_bytes = 4096, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        var player_records: [2]Players.Player = .{ .{ .handle = .{ .index = 0, .generation = 1 }, .uuid = 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number }, .{ .handle = .{ .index = 1, .generation = 1 }, .uuid = 2, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number, .position = .{ .x = 10000, .y = 65, .z = 10000 } } };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = &player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        player_records[0].position.x = 1;
        player_records[0].position.z = 1;
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        streaming.published.setStream(1, .{ .generation = 1, .life = player_records[1].life, .setup = .streaming, .center = .{ .x = 625, .z = 625 } });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);
        const replication = try ItemReplication.init(allocator, .{}, .{ .dropped = dropped, .item_tick = undefined, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .entities = bodies, .inventories = ownership, .items = items });

        for (0..9) |mode| {
            if (mode == 2) {
                const word = streaming.words_per_player;
                streaming.published.sent[word] ^= 1;
                streaming.published.dirty_words.set(word);
            }
            if (mode == 3 or mode == 4) {
                if (mode == 3) streaming.published.sent[0] &= ~@as(u64, 1) else streaming.published.sent[0] |= 1;
                streaming.published.dirty_words.set(0);
            }
            if (mode == 6) {
                var publication = streaming.published.streams[1];
                publication.center = .{ .x = 666, .z = 666 };
                streaming.published.setStream(1, publication);
            }
            if (mode == 7) {
                var publication = streaming.published.streams[0];
                publication.setup = .terrain;
                streaming.published.setStream(0, publication);
            }
            if (mode == 8) {
                var publication = streaming.published.streams[0];
                publication.setup = .streaming;
                streaming.published.setStream(0, publication);
            }
            const metadata_before = dropped.cache.metrics.acquired.value();
            const bodies_before = bodies.cache.metrics.acquired.value();
            const reads_before = dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value();
            for (0..2) |i| service.credit[i].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            service.beginTick();
            try replication.tick();
            service.endTick(true);
            service.flush();
            var batch = service.outputBatch();
            var queued: usize = 0;
            while (batch.next()) |packet| {
                queued += 1;
                service.recycle(io, &.{packet});
            }
            const unchanged = mode == 1 or mode == 2 or mode == 5 or mode == 6;
            if (unchanged) {
                try std.testing.expectEqual(@as(usize, 0), queued);
                try std.testing.expectEqual(metadata_before, dropped.cache.metrics.acquired.value());
                try std.testing.expectEqual(bodies_before, bodies.cache.metrics.acquired.value());
                try std.testing.expectEqual(reads_before, dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value());
            } else try std.testing.expect(queued > 0);
            for (ids[0..count]) |id| try std.testing.expectEqual(@as(usize, if (mode == 3 or mode == 7) 0 else 1), replication.views[dropped.ids.get(id).?].spawned.view().count());
            try output.interface.print("VISIBILITY items={d} mode={d} metadata={d} bodies={d} backend_records={d} packets={d}\n", .{ count, mode, dropped.cache.metrics.acquired.value() - metadata_before, bodies.cache.metrics.acquired.value() - bodies_before, dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value() - reads_before, queued });
        }
    }
    try output.interface.flush();
}

pub fn benchmarkPickupAdmission() !void {
    const io = std.testing.io;
    var output_buffer: [1024]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Pickup admission with full inventories\n");
    for ([_]usize{256}) |slot_capacity| for ([_]usize{ 1, 64 }) |count| for ([_]usize{ 1, 8, 32 }) |player_count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/pickup", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = slot_capacity, .cache_items = 2, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        var player_records: [32]Players.Player = undefined;
        for (player_records[0..player_count], 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .stage = .ready, .loaded = true, .gamemode = .survival };
        var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = 0, .records = player_records[0..player_count], .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const menu = try PlayerInventory.init(allocator, .{
            .players = &players,
            .inventories = ownership,
            .items = items,
            .equipment = undefined,
            .dropped = undefined,
        });
        const bodies = try entities.Entities.allocate(allocator, io, .{ .cache_records = 2 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.allocate(allocator, .{ .maximum = 1 });
        const dropped = try ItemEntities.allocate(allocator, io, .{ .cache_records = 4, .maximum = 1 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        const pickup = try ItemPickup.init(allocator, .{ .players = &players, .menus = menu, .inventories = ownership, .entities = bodies, .items = items, .dropped = dropped });
        var sources: [64]inventories.Slot = undefined;
        var edits: [101]inventories.Edit = undefined;
        for (sources[0..count], edits[0..count], 0..) |*source, *edit, index| {
            source.* = .{ .owner = 100, .index = @intCast(index) };
            edit.* = .{ .slot = source.*, .revision = 0, .stack = stack };
        }
        var cursor: usize = 0;
        while (cursor < count) {
            const length = @min(count - cursor, slot_capacity);
            try std.testing.expect(try ownership.editMany(edits[cursor..][0..length]));
            cursor += length;
        }
        var slots: [101]inventories.Slot = undefined;
        for (slots[0..36], 0..) |*slot, index| slot.* = .{ .owner = 1, .index = @intCast(if (index < 9) index + 36 else index) };
        slots[36] = .{ .owner = 1, .index = 45 };
        @memcpy(slots[37..][0..count], sources[0..count]);
        var contents: [101]inventories.Contents = undefined;
        cursor = 0;
        while (cursor < 37 + count) {
            const length = @min(37 + count - cursor, slot_capacity);
            try ownership.getMany(slots[cursor..][0..length], contents[cursor..][0..length]);
            cursor += length;
        }

        var fills: [37]inventories.Edit = undefined;
        for (slots[0..37], contents[0..37], &fills) |slot, previous, *edit| edit.* = .{ .slot = slot, .revision = previous.revision, .stack = .{ .item = stack.item, .count = 64 } };
        for (0..player_count) |player| {
            for (&fills) |*edit| edit.slot.owner = player + 1;
            try std.testing.expect(try ownership.editMany(&fills));
        }

        const before = ownership.cache.metrics.acquired.value();
        const definitions = ownership.items.metrics.acquired.value();
        const reads = ownership.cache.metrics.reads.value();
        var requests: [64]ItemPickup.Request = undefined;
        var results: [64]ItemPickup.Result = undefined;
        for (sources[0..count], requests[0..count]) |source, *request| request.* = .{ .source = source };
        for (0..20) |_| for (0..player_count) |player| {
            var at: usize = 0;
            while (at < count) {
                const n = @min(16, count - at);
                try pickup.collect(player, requests[at..][0..n], results[at..][0..n]);
                at += n;
            }
            for (results[0..count]) |result| try std.testing.expectEqual(@as(u16, 0), result.collected);
        };
        try std.testing.expectEqual(37 * player_count, ownership.cache.metrics.acquired.value() - before);
        try std.testing.expectEqual(player_count, ownership.items.metrics.acquired.value() - definitions);
        try output.interface.print("FULL_PICKUP players={d} items={d} ticks=20 inventory_acquisitions={d} definition_acquisitions={d} backend_records={d} collected=0\n", .{ player_count, count, ownership.cache.metrics.acquired.value() - before, ownership.items.metrics.acquired.value() - definitions, ownership.cache.metrics.reads.value() - reads });
        if (count == 64) {
            const destination = slots[0];
            var previous = try ownership.get(destination);
            try std.testing.expect(try ownership.set(destination, previous.revision, .{ .item = stack.item, .count = 63 }));
            try pickup.collect(0, requests[0..1], results[0..1]);
            try std.testing.expectEqual(@as(u16, 1), results[0].collected);
            previous = try ownership.get(slots[36]);
            try std.testing.expect(try ownership.set(slots[36], previous.revision, null));
            try pickup.collect(0, requests[1..2], results[1..2]);
            try std.testing.expectEqual(@as(u16, 0), results[1].collected);
            player_records[0].gamemode = .creative;
            try pickup.collect(0, requests[1..2], results[1..2]);
            try std.testing.expectEqual(@as(u16, 1), results[1].collected);
            player_records[0].gamemode = .survival;
            previous = try ownership.get(destination);
            try std.testing.expect(try ownership.set(destination, previous.revision, null));
            var restricted = requests[2];
            restricted.pickup_delay = 1;
            try pickup.collect(0, &.{restricted}, results[2..3]);
            try std.testing.expectEqual(@as(u16, 0), results[2].collected);
            restricted.pickup_delay = 0;
            restricted.owner = 999;
            try pickup.collect(0, &.{restricted}, results[2..3]);
            try std.testing.expectEqual(@as(u16, 0), results[2].collected);
            try pickup.collect(0, requests[2..3], results[2..3]);
            try std.testing.expectEqual(@as(u16, 1), results[2].collected);
            if (player_count > 1) {
                player_records[1].handle = null;
                player_records[0].uuid = 2;
                try pickup.collect(0, requests[3..4], results[3..4]);
                try std.testing.expectEqual(@as(u16, 0), results[3].collected);
            }
        }
    };
    try output.interface.flush();
}

pub fn benchmarkIdleTerrain() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Idle terrain work\n");
    for ([_]usize{ 1, 32, 256 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
        var background: terrain_background.Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        for (streaming.streams, player_records, 0..) |*stream, player, index| {
            stream.* = .{ .generation = 1, .life = player.life, .setup = .streaming, .cursor = side * side, .delivered = side * side };
            streaming.published.setStream(index, stream.*);
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        @memset(streaming.sent, std.math.maxInt(u64));
        terrain.ready().reset();
        try background.poll();
        terrain.ready().reset();
        var wakes: usize = 0;
        var outgoing: usize = 0;
        const reads = terrain.cache.metrics.reads.value();
        for (0..64) |_| {
            service.beginTick();
            streaming.endTick(true);
            blocks.endTick(true);
            service.endTick(true);
            streaming.publish();
            blocks.publish();
            if (terrain.ready().isSet()) {
                wakes += 1;
                terrain.ready().reset();
                try background.poll();
            }
            var batch = service.outputBatch();
            while (batch.next()) |packet| {
                outgoing += 1;
                service.recycle(io, &.{packet});
            }
        }
        try std.testing.expectEqual(@as(usize, 0), outgoing);
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        try std.testing.expectEqual(@as(usize, 0), wakes);
        try output.interface.print("idle terrain players={d} ticks=64 background_passes={d} packets=0 storage_reads=0\n", .{ count, wakes });
        player_records[0].position.x += 16;
        service.beginTick();
        streaming.endTick(true);
        blocks.endTick(true);
        try background.poll();
        try std.testing.expect(service.background_retry.load(.acquire));
        service.endTick(true);
        try std.testing.expect(terrain.ready().isSet());
        terrain.ready().reset();
        streaming.publish();
        blocks.publish();
        try std.testing.expect(terrain.ready().isSet());
    }
    try output.interface.flush();
}

pub fn benchmarkItemBroadcast() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("moving items | viewers | shared audiences | credit reservations | movement packets\n");
    for ([_]usize{ 64, 256 }) |count| for ([_]usize{ 1, 16, 64 }) |viewers| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 512, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 1 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 512 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 512, .maximum = 256 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        var ids: [256]entities.Id = undefined;
        for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 0.5, 65, 0.5 }, @splat(0), stack);
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = viewers, .pages = @max(2048, count * 5 * @min(viewers, catalog.values.len)), .page_bytes = 4096, .buffer_bytes = 1024 * 1024, .metrics = &registry, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        var player_records: [64]Players.Player = undefined;
        for (player_records[0..viewers], 0..) |*player, index| player.* = .{
            .handle = .{ .index = @intCast(index), .generation = 1 },
            .uuid = 10000 + index,
            .world = world,
            .stage = .ready,
            .loaded = true,
            .gamemode = .survival,
            .protocol = catalog.values[index % catalog.values.len].number,
        };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 2 }, .spawn_world = world, .records = player_records[0..viewers], .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        for (0..streaming.published.streams.len) |index| streaming.published.setStream(index, .{ .generation = 1, .life = 1, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);
        const replication = try ItemReplication.init(allocator, .{}, .{ .dropped = dropped, .item_tick = undefined, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .entities = bodies, .inventories = ownership, .items = items });

        const expected_viewers = viewers;
        for (0..2) |_| {
            for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            service.beginTick();
            try replication.tick();
            service.endTick(true);
            service.flush();
            var initial = service.outputBatch();
            while (initial.next()) |packet| service.recycle(io, &.{packet});
        }
        failing.fail_index = failing.alloc_index;
        for (ids[0..count]) |id| {
            const view = replication.views[dropped.ids.get(id).?];
            try std.testing.expectEqual(expected_viewers, view.spawned.view().count());
            try std.testing.expectEqual(@as(usize, 0), view.pending.view().count());
        }
        for ([_]bool{ false, true }) |limited| {
            for (ids[0..count]) |id| {
                var held: [1]ItemEntities.Record = undefined;
                try dropped.acquireMany(&.{id}, &held);
                defer held[0].release();
                const before = (try held[0].body.read()).?;
                var after = before;
                after.position[0] += 0.125;
                try dropped.move(held[0], before, after);
                var metadata = try held[0].read();
                metadata.revision += 1;
                held[0].write(metadata);
            }
            for (service.credit, 0..) |*credit, index| {
                const bytes = if (limited and index == 0) service.framedBound(128) * 2 else service.config.buffer_bytes;
                credit.store((@as(u64, 1) << 32) | sessions.Service.active | bytes, .release);
            }
            const reservations = service.instruments.broadcast_reservations.value();
            service.beginTick();
            try replication.tick();
            service.endTick(true);
            service.flush();
            const audiences = service.output.pool.audiences.len - service.output.pool.free_audiences.count();
            var received: [64][256]bool = @splat(@splat(false));
            var previous: [64]i32 = @splat(std.math.maxInt(i32));
            var sent: [64]usize = @splat(0);
            var queued: usize = 0;
            var batch = service.outputBatch();
            while (batch.next()) |packet| {
                const header = try wire.play.toClient.readHeader(packet.bytes);
                const protocol = player_records[packet.recipients.first().?.index].protocol;
                var expected_id: ?i32 = null;
                inline for (protocols.implementations) |Version| {
                    if (protocol == Version.protocol_number) expected_id = Version.Protocol.play.toClient.packetId(.sync_entity_position);
                }
                try std.testing.expectEqual(expected_id.?, header.id);
                const reader: wire.play.toClient.packet_sync_entity_position.Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body } };
                const id, const next = try reader.entityId();
                const x, _ = try next.x();
                try std.testing.expectEqual(@as(f64, if (limited) 0.75 else 0.625), x);
                const at: usize = @intCast(ItemEntities.networkId(ids[0]) - id);
                try std.testing.expect(at < count);
                var recipient_iterator = packet.recipients.iterator();
                while (recipient_iterator.next()) |handle| {
                    try std.testing.expectEqual(protocol, player_records[handle.index].protocol);
                    try std.testing.expectEqual(@as(u32, 1), handle.generation);
                    try std.testing.expect(id < previous[handle.index]);
                    previous[handle.index] = id;
                    received[handle.index][at] = true;
                    sent[handle.index] += 1;
                }
                queued += 1;
                service.recycle(io, &.{packet});
            }
            if (!limited) {
                const batches = (count + sessions.Service.batch_max - 1) / sessions.Service.batch_max;
                try std.testing.expectEqual(count * @min(viewers, catalog.values.len), queued);
                try std.testing.expectEqual(batches, audiences);
                try std.testing.expectEqual(batches * viewers, service.instruments.broadcast_reservations.value() - reservations);
                try output.interface.print("{d:12} | {d:7} | {d:16} | {d:19} | {d}\n", .{ count, viewers, audiences, service.instruments.broadcast_reservations.value() - reservations, queued });
            } else {
                try std.testing.expect(sent[0] > 0 and sent[0] < count);
            }
            for (0..viewers) |viewer| {
                if (!limited or viewer != 0) try std.testing.expectEqual(count, sent[viewer]);
                for (ids[0..count], 0..) |id, at| {
                    const view = replication.views[dropped.ids.get(id).?];
                    try std.testing.expectEqual(!received[viewer][at], view.dirty.view().contains(viewer));
                }
            }
            if (limited) {
                for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
                service.beginTick();
                try replication.tick();
                service.endTick(true);
                service.flush();
                var retry = service.outputBatch();
                while (retry.next()) |packet| {
                    const header = try wire.play.toClient.readHeader(packet.bytes);
                    const reader: wire.play.toClient.packet_sync_entity_position.Reader = .{ ._cursor = .{ .buffer = header.body, .rest = header.body } };
                    const id, _ = try reader.entityId();
                    const at: usize = @intCast(ItemEntities.networkId(ids[0]) - id);
                    try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
                    try std.testing.expectEqual(@as(u16, 0), packet.recipients.first().?.index);
                    try std.testing.expect(!received[0][at]);
                    received[0][at] = true;
                    service.recycle(io, &.{packet});
                }
                try std.testing.expect(std.mem.allEqual(bool, received[0][0..count], true));
                for (ids[0..count]) |id| try std.testing.expectEqual(@as(usize, 0), replication.views[dropped.ids.get(id).?].pending.view().count());
            }
        }
    };
    try output.interface.flush();
}

pub fn benchmarkBlockPlanning() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Block delivery planning\n");
    for ([_]i32{ 8, 32 }) |radius| for ([_]usize{ 1, 16, 64, 256 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{ .delta_sections = if (count == 1) 1 else (block_synchronization.BlockSynchronization.Configuration{}).delta_sections });
        var background: terrain_background.Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        for (streaming.streams, player_records, 0..) |*stream, player, index| {
            stream.* = .{ .generation = 1, .life = player.life, .setup = .streaming, .cursor = side * side, .delivered = side * side };
            streaming.published.setStream(index, stream.*);
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        @memset(streaming.sent, std.math.maxInt(u64));
        for (0..3) |pass| {
            service.beginTick();
            try terrain.setBlock(world, .{ .x = 0, .y = 65, .z = 0 }, @intCast(pass + 1));
            blocks.endTick(true);
            service.endTick(true);
            const before = blocks.planning_words.value();
            try std.testing.expect(try blocks.poll(io));
            const examined = blocks.planning_words.value() - before;
            try std.testing.expectEqual(@as(u64, 1), examined);
            var batch = service.outputBatch();
            var outgoing: usize = 0;
            var recipients: usize = 0;
            while (batch.next()) |packet| {
                outgoing += 1;
                recipients += packet.recipients.len;
                service.recycle(io, &.{packet});
            }
            try std.testing.expectEqual(@as(usize, 1), outgoing);
            try std.testing.expectEqual(count, recipients);
            for (blocks.observers) |observer| {
                try std.testing.expectEqual(@as(usize, 0), observer.pending);
                try std.testing.expectEqual(null, observer.nonempty.findFirstSet());
            }
            try output.interface.print("block delivery players={d} radius={d} pass={d} pending_words={d} packets={d} recipients={d}\n", .{ count, radius, pass, examined, outgoing, recipients });
        }
        service.beginTick();
        blocks.correct(world, .{ .x = 0, .y = 65, .z = 0 });
        blocks.endTick(true);
        service.endTick(true);
        for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active, .release);
        try std.testing.expect(!try blocks.poll(io));
        for (blocks.observers) |observer| try std.testing.expectEqual(@as(usize, 1), observer.pending);
        service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        try std.testing.expect(try blocks.poll(io));
        var retry = service.outputBatch();
        const packet = retry.next().?;
        try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
        try std.testing.expectEqual(@as(u16, 0), packet.recipients.first().?.index);
        service.recycle(io, &.{packet});
        try std.testing.expectEqual(null, retry.next());
        for (blocks.observers, 0..) |observer, index| try std.testing.expectEqual(@as(usize, @intFromBool(index != 0)), observer.pending);
        for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        if (count > 1) {
            try std.testing.expect(try blocks.poll(io));
            var rest = service.outputBatch();
            const remaining = rest.next().?;
            try std.testing.expectEqual(count - 1, remaining.recipients.len);
            var recipient_iterator = remaining.recipients.iterator();
            while (recipient_iterator.next()) |handle| try std.testing.expect(handle.index != 0);
            service.recycle(io, &.{remaining});
            try std.testing.expectEqual(null, rest.next());
        }
        for (blocks.observers) |observer| try std.testing.expectEqual(@as(usize, 0), observer.pending);

        service.beginTick();
        const evictions_before = blocks.evictions.load(.monotonic);
        const full_before = blocks.full_sections.load(.monotonic);
        for (0..8) |section| try terrain.setBlock(world, .{ .x = @as(i32, @intCast(section)) * 16, .y = 65, .z = 0 }, 4);
        blocks.endTick(true);
        service.endTick(true);
        const before = blocks.planning_words.value();
        try std.testing.expect(try blocks.poll(io));
        try std.testing.expect(blocks.planning_words.value() - before <= 64);
        var batch = service.outputBatch();
        var outgoing: usize = 0;
        while (batch.next()) |entry| {
            outgoing += 1;
            try std.testing.expectEqual(count, entry.recipients.len);
            service.recycle(io, &.{entry});
        }
        try std.testing.expectEqual(@as(usize, 8), outgoing);
        try std.testing.expectEqual(@as(u32, 0), blocks.delta_index.count());
        for (blocks.deltas) |delta| try std.testing.expect(!delta.live);
        if (count == 1) {
            try std.testing.expectEqual(@as(u64, 7), blocks.evictions.load(.monotonic) - evictions_before);
            try std.testing.expectEqual(@as(u64, 7), blocks.full_sections.load(.monotonic) - full_before);
            try std.testing.expectEqual(@as(?usize, 0), blocks.free_delta);
        }
        for (blocks.observers) |observer| {
            try std.testing.expectEqual(@as(usize, 0), observer.pending);
            try std.testing.expectEqual(null, observer.nonempty.findFirstSet());
        }
    };
    try output.interface.flush();
}

pub fn benchmarkItemBoundaries() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("dropped items | viewer movement | metadata acquisitions | body acquisitions | backend record reads | packets\n");
    for ([_]usize{ 1, 16, 64, 256 }) |viewers| for ([_]usize{ 16, 256, 1024 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = 1024, .cache_items = 8, .max_item_bytes = 1024 }, .{
            .metrics = &registry,
            .storage = try store.openSpace("inventory"),
            .record_workspaces = workspaces,
        });
        const items = try Items.init(allocator, .{}, .{ .inventories = ownership, .registry_identity = undefined });
        const stack: inventories.Stack = .{ .item = try items.define("minecraft:bread"), .count = 64 };
        const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 256 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 256, .maximum = 1024 }, .{
            .metrics = &registry,
            .record_workspaces = workspaces,
            .entities = bodies,
            .inventories = ownership,
            .items = items,
            .worlds = dimensions,
            .storage = try store.openSpace("metadata"),
        });
        var ids: [1024]entities.Id = undefined;
        for (ids[0..count]) |*id| id.* = try dropped.create(world, .{ 96.5, 65, 0.5 }, @splat(0), stack);
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = viewers, .pages = 8192, .page_bytes = 4096, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, viewers);
        for (player_records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .protocol = catalog.values[0].number, .position = .{ .x = 1, .y = 65, .z = 1 } };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        for (0..streaming.published.streams.len) |index| streaming.published.setStream(index, .{ .generation = 1, .life = 1, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);
        const replication = try ItemReplication.init(allocator, .{}, .{ .dropped = dropped, .item_tick = undefined, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .entities = bodies, .inventories = ownership, .items = items });

        failing.fail_index = failing.alloc_index;
        const Step = struct { position: [2]f64, visible: bool = true, unchanged: bool = false };
        const steps = [_]Step{ .{ .position = .{ 1, 1 } }, .{ .position = .{ 1.125, 1 }, .unchanged = true }, .{ .position = .{ 1.25, 1 }, .unchanged = true }, .{ .position = .{ 0.375, 1 }, .visible = false }, .{ .position = .{ 0.5, 1 } }, .{ .position = .{ 1, 1 } } };
        var was_visible = false;
        for (steps, 0..) |step, index| {
            for (player_records) |*player| {
                player.position.x = step.position[0] + @as(f64, @floatFromInt(player.handle.?.index)) / @as(f64, @floatFromInt(viewers * 16));
                player.position.z = step.position[1];
            }
            const candidates_before = replication.selection_candidates.value();
            const nodes_before = replication.selection_nodes.value();
            players.rebuildIndexes();
            const metadata_before = dropped.cache.metrics.acquired.value();
            const bodies_before = bodies.cache.metrics.acquired.value();
            const reads_before = dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value();
            for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            service.beginTick();
            try replication.tick();
            service.endTick(true);
            service.flush();
            var batch = service.outputBatch();
            var queued: usize = 0;
            while (batch.next()) |packet| {
                queued += 1;
                service.recycle(io, &.{packet});
            }
            const metadata_acquired = dropped.cache.metrics.acquired.value() - metadata_before;
            const bodies_acquired = bodies.cache.metrics.acquired.value() - bodies_before;
            const reads = dropped.cache.metrics.reads.value() + bodies.cache.metrics.reads.value() - reads_before;
            if (step.unchanged) {
                try std.testing.expectEqual(@as(u64, @intCast(count)), replication.selection_candidates.value() - candidates_before);
                try std.testing.expect(replication.selection_nodes.value() - nodes_before <= (viewers * 4 + count) * 32);
                try std.testing.expectEqual(@as(u64, 0), metadata_acquired);
                try std.testing.expectEqual(@as(u64, 0), bodies_acquired);
                try std.testing.expectEqual(@as(u64, 0), reads);
            }
            if (was_visible == step.visible) try std.testing.expectEqual(@as(usize, 0), queued) else try std.testing.expect(queued > 0);
            for (ids[0..count]) |id| {
                const view = replication.views[dropped.ids.get(id).?];
                try std.testing.expectEqual(@as(usize, if (step.visible) viewers else 0), view.spawned.view().count());
                try std.testing.expectEqual(@as(usize, 0), view.pending.view().count());
            }
            was_visible = step.visible;
            try output.interface.print("BOUNDARY viewers={d} items={d} step={d} spatial_candidates={d} coverage_nodes={d} metadata={d} bodies={d} backend_records={d} packets={d}\n", .{ viewers, count, index, replication.selection_candidates.value() - candidates_before, replication.selection_nodes.value() - nodes_before, metadata_acquired, bodies_acquired, reads, queued });
        }
    };
    try output.interface.flush();
}

pub fn benchmarkTerrainBackpressure() !void {
    const Source = struct {
        fn read(_: *@This(), _: std.Io, batch: chunks.Source.Batch) void {
            for (batch.requests) |*request| request.result = chunks.uniform(0, request.output);
        }
    };
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Terrain packet-pool backpressure\n");
    const Mode = enum { streaming, blocks };
    for ([_]Mode{ .streaming, .blocks }) |mode| for ([_]usize{ 1, 32, 256 }) |count| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const allocator = failing.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 128, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
        const generating = count == 1;
        var source: Source = .{};
        if (generating) terrain.setSource(chunks.Source.init(&source, Source.read));
        terrain.attach();
        defer terrain.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        for (streaming.streams, player_records, 0..) |*stream, player, index| {
            stream.* = .{ .generation = 1, .life = player.life, .setup = .streaming, .cursor = if (mode == .blocks) side * side else 0 };
            streaming.published.setStream(index, stream.*);
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        @memset(streaming.sent, if (mode == .blocks) std.math.maxInt(u64) else 0);
        @memcpy(streaming.published.sent, streaming.sent);
        if (mode == .blocks) {
            service.beginTick();
            for (0..8) |section| {
                const position: chunks.Position = .{ .x = @as(i32, @intCast(section)) * 16, .y = 65, .z = 0 };
                if (generating) blocks.correct(world, position) else try terrain.setBlock(world, position, 1);
            }
            blocks.endTick(true);
            service.endTick(true);
        }
        failing.fail_index = failing.alloc_index;
        const handle = player_records[0].handle.?;
        for (0..service.config.pages) |_| {
            var packet = try service.reserve(service.config.page_bytes);
            @memset(packet.bytes, 0);
            try packet.publish(packet.bytes.len, &.{handle});
        }
        service.flush();
        try std.testing.expect(service.outputCredit(handle) > 0);
        const acquired = terrain.cache.metrics.acquired.value();
        const reads = terrain.cache.metrics.reads.value();
        for (0..64) |_| {
            if (mode == .streaming) streaming.pending = true;
            try std.testing.expect(!try if (mode == .streaming) streaming.poll(io) else blocks.poll(io));
        }
        try std.testing.expectEqual(acquired, terrain.cache.metrics.acquired.value());
        try std.testing.expectEqual(reads, terrain.cache.metrics.reads.value());
        var retained: [128]sessions.RawPacket = undefined;
        var held: usize = 0;
        var batch = service.outputBatch();
        while (batch.next()) |packet| {
            if (held == 0) service.recycle(io, &.{packet});
            retained[held] = packet;
            held += 1;
        }
        try std.testing.expectEqual(service.config.pages, held);
        const ready_acquired = terrain.cache.metrics.acquired.value();
        var progressed = false;
        for (0..256) |_| {
            if (mode == .streaming) streaming.pending = true;
            progressed = try if (mode == .streaming) streaming.poll(io) else blocks.poll(io);
            if (progressed) break;
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            var unused = try service.reserve(service.config.page_bytes);
            unused.cancel();
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
        }
        try std.testing.expect(progressed);
        const sections = terrain.cache.metrics.acquired.value() - ready_acquired;
        if (mode == .blocks) try std.testing.expectEqual(@as(u64, if (generating) 2 else 1), sections);
        var delivered = service.outputBatch();
        const packet = delivered.next().?;
        try std.testing.expectEqual(count, packet.recipients.len);
        service.recycle(io, &.{packet});
        try std.testing.expectEqual(null, delivered.next());
        service.recycle(io, retained[1..held]);
        progressed = false;
        for (0..256) |_| {
            if (mode == .streaming) streaming.pending = true;
            progressed = try if (mode == .streaming) streaming.poll(io) else blocks.poll(io);
            if (progressed) break;
            try std.testing.expectEqual(@as(usize, 0), terrain.borrowed_count);
            while (try terrain.generation.processOne(io)) {}
            try terrain.poll();
        }
        try std.testing.expect(progressed);
        var remaining = service.outputBatch();
        while (remaining.next()) |pending| service.recycle(io, &.{pending});
        var reclaimed: [128]sessions.Service.Packet = undefined;
        for (&reclaimed) |*reservation| reservation.* = try service.reserve(service.config.page_bytes);
        try std.testing.expectError(error.Backpressured, service.reserve(service.config.page_bytes));
        for (&reclaimed) |*reservation| reservation.cancel();
        try output.interface.print("terrain mode={s} players={d} blocked_passes=64 section_acquisitions=0 backend_reads=0 partial_capacity_sections={d}\n", .{ @tagName(mode), count, sections });
    };
    try output.interface.flush();
}

test "operation counts for audience overflow preserve unrelated connections" {
    const capacity = std.atomic.cache_line * 8 + 1;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var sink: Sink = .{};
    const protocols_selected = [_]sessions.Protocol{.{ .number = 1 }};
    const service = try sessions.Service.init(allocator, std.testing.io, .{ .context = &sink, .vtable = network.Transport.adapter(Sink) }, .{ .connections = capacity, .pages = 2, .page_bytes = 64, .buffer_bytes = 1024, .protocols = &protocols_selected });
    defer service.deinit();
    const player_records = try allocator.alloc(Players.Player, capacity);
    @memset(player_records, .{});
    for ([_]usize{ 0, 64, 100 }) |index| {
        player_records[index].handle = .{ .index = index, .generation = 1 };
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    var players: Players = .{ .deps = .{ .sessions = service, .packets = undefined, .input = undefined, .storage = undefined, .worlds = undefined, .vanilla_worlds = undefined, .record_workspaces = undefined }, .config = .{}, .spawn_world = 0, .records = player_records, .dig_handlers = &.{} };
    const matrix = try audience_storage.Matrix.init(allocator, &players, 101, 0, .recipients);
    const selected = try bit_sets.Matrix.init(allocator, 1, capacity);
    selected.row(0).insert(0);
    selected.row(0).insert(64);
    matrix.row(0).copy(selected.row(0).view());
    try std.testing.expect(!matrix.row(0).view().any());
    try std.testing.expectEqual(@as(u32, 1), service.disconnects[0].load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), service.disconnects[64].load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), service.disconnects[100].load(.acquire));
    for ([_]usize{ 0, 64, 100 }) |index| {
        service.disconnects[index].store(0, .release);
        service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
    }
    const owned = try audience_storage.Matrix.init(allocator, &players, 101, 0, .{ .subjects = 1 });
    owned.row(100).copy(selected.row(0).view());
    try std.testing.expect(!owned.row(100).view().any());
    try std.testing.expectEqual(@as(u32, 0), service.disconnects[0].load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), service.disconnects[64].load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), service.disconnects[100].load(.acquire));
}

pub fn benchmarkSparseTerrainStreaming() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Sparse terrain cursor updates\n");
    for ([_]usize{ 32, 512, 4096 }) |count| for ([_]bool{ false, true }) |populated| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        @memset(player_records, .{});
        for (player_records, 0..) |*player, index| {
            if (!populated and index != 0) continue;
            player.* = .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number, .position = .{ .x = @floatFromInt(index * 1024), .y = 65, .z = 0 } };
        }
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = 8 }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
        var background: terrain_background.Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        if (populated) for (streaming.streams, 0..) |*stream, index| {
            stream.* = .{ .generation = 1, .life = player_records[index].life, .setup = .streaming, .cursor = side * side, .delivered = side * side, .center = .{ .x = @intCast(index * 64), .z = 0 }, .target = .{ .x = @intCast(index * 64), .z = 0 } };
            streaming.published.setStream(index, stream.*);
        };
        streaming.streams[0] = .{ .generation = 1, .life = player_records[0].life, .setup = .streaming, .cursor = 0, .delivered = side * side - 1 };
        @memset(streaming.sent, std.math.maxInt(u64));
        streaming.sent[0] &= ~@as(u64, 1);
        service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        service.beginTick();
        streaming.endTick(true);
        service.endTick(true);
        streaming.publish();
        try background.poll();
        var packets_sent: usize = 0;
        var batch = service.outputBatch();
        while (batch.next()) |packet| {
            packets_sent += 1;
            try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
            try std.testing.expectEqual(@as(usize, 0), packet.recipients.first().?.index);
            service.recycle(io, &.{packet});
        }
        try std.testing.expectEqual(@as(usize, 1), packets_sent);
        try std.testing.expectEqual(side * side, streaming.streams[0].cursor);
        for (streaming.streams[1..]) |stream| try std.testing.expectEqual(if (populated) side * side else 0, stream.cursor);
        var query = streaming.observers_index.query(.{ .world = world, .x = 0, .z = 0 }, 8);
        try std.testing.expectEqual(@as(usize, 0), query.next().?);
        try std.testing.expectEqual(null, query.next());
        try std.testing.expect(query.visited <= 16);
        try output.interface.print("terrain slots={d} active={d} chunk_packets={d} cursor_updates=1 recipient_candidates={d}\n", .{ count, if (populated) count else 1, packets_sent, query.visited });
        player_records[0].position.x += 1024;
        players.rebuildIndexes();
        service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active, .release);
        service.beginTick();
        streaming.endTick(true);
        service.endTick(true);
        streaming.publish();
        try std.testing.expect(!try streaming.poll(io));
        var delivered = streaming.visibleObservers(streaming.views, world, 0, 0);
        try std.testing.expectEqual(@as(usize, 0), delivered.next().?);
        try std.testing.expectEqual(null, delivered.next());
        var destination = streaming.visibleObservers(streaming.views, world, 64, 0);
        while (destination.next()) |index| try std.testing.expect(index != 0);
        if (!populated and count == 32) {
            service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active | service.framedBound(64), .release);
            try std.testing.expect(try streaming.poll(io));
            try std.testing.expectEqual(.unloading, streaming.streams[0].setup);
            delivered = streaming.visibleObservers(streaming.views, world, 0, 0);
            try std.testing.expectEqual(@as(usize, 0), delivered.next().?);
            try std.testing.expectEqual(null, delivered.next());
            var unloads = service.outputBatch();
            var count_unloads: usize = 0;
            while (unloads.next()) |packet| {
                count_unloads += 1;
                service.recycle(io, &.{packet});
            }
            try std.testing.expect(count_unloads > 0 and count_unloads < side * side);
        }
    };
    try output.interface.flush();
}

pub fn benchmarkSparseBlockPlanning() !void {
    const io = std.testing.io;
    var output_buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(io, &output_buffer);
    try output.interface.writeAll("Block delivery planning\n");
    const radius: i32 = 8;
    for ([_]usize{ 32, 512, 4096 }) |count| for ([_]bool{ false, true }) |populated| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| player.* = if (populated or index == 0) .{ .handle = .{ .index = index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[0].number, .position = .{ .x = @floatFromInt(index * 1024), .y = 65, .z = 0 } } else .{};
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{});
        var background: terrain_background.Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        for (streaming.streams, player_records, 0..) |*stream, player, index| {
            stream.* = .{ .generation = 1, .life = player.life, .setup = .streaming, .cursor = side * side, .delivered = side * side, .center = .{ .x = @intCast(index * 64), .z = 0 }, .target = .{ .x = @intCast(index * 64), .z = 0 } };
            streaming.published.setStream(index, stream.*);
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        @memset(streaming.sent, std.math.maxInt(u64));

        service.beginTick();
        try terrain.setBlock(world, .{ .x = 0, .y = 65, .z = 0 }, 1);
        blocks.endTick(true);
        service.endTick(true);
        for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active, .release);
        try std.testing.expect(!try blocks.poll(io));
        for (0..64) |_| {
            try std.testing.expect(!try blocks.poll(io));
            try std.testing.expectEqual(@as(usize, 1), blocks.selections.row(0).view().count());
        }
        service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        try std.testing.expect(try blocks.poll(io));
        var batch = service.outputBatch();
        const packet = batch.next().?;
        try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
        try std.testing.expectEqual(@as(usize, 0), packet.recipients.first().?.index);
        try std.testing.expectEqual(null, batch.next());
        service.recycle(io, &.{packet});
        try std.testing.expect(!blocks.selections.row(0).view().any());
        var watchers = streaming.visibleObservers(blocks.views, world, 0, 0);
        try std.testing.expectEqual(@as(usize, 0), watchers.next().?);
        try std.testing.expectEqual(null, watchers.next());
        try std.testing.expect(watchers.query.visited <= 16);
        service.beginTick();
        blocks.correct(world, .{ .x = 0, .y = 65, .z = 0 });
        blocks.endTick(true);
        service.endTick(true);
        service.credit[0].store((@as(u64, 1) << 32) | sessions.Service.active, .release);
        try std.testing.expect(!try blocks.poll(io));
        player_records[0].handle = null;
        players.rebuildIndexes();
        service.beginTick();
        blocks.endTick(true);
        service.endTick(true);
        try std.testing.expect(!try blocks.poll(io));
        try std.testing.expect(!blocks.selections.row(0).view().any());
        try std.testing.expectEqual(@as(usize, 0), blocks.observers[0].pending);
        player_records[0].handle = .{ .index = 0, .generation = 2 };
        players.rebuildIndexes();
        service.beginTick();
        blocks.correct(world, .{ .x = 0, .y = 65, .z = 0 });
        blocks.endTick(true);
        service.endTick(true);
        try std.testing.expect(!try blocks.poll(io));
        try std.testing.expect(!blocks.selections.row(0).view().any());
        try std.testing.expectEqual(@as(u32, 2), blocks.observers[0].generation);
        try output.interface.print("block delivery slots={d} active={d} blocked_passes=64 packets=1 recipients=1 spatial_candidates={d}\n", .{ count, if (populated) count else 1, watchers.query.visited });
    };
    try output.interface.flush();
}

pub fn verifyBlockBatchRetirement() !void {
    const io = std.testing.io;
    const Mode = enum { full_and_delta, protocols };
    const count = 2;
    const radius = 2;
    for (std.enums.values(Mode)) |mode| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/replication", .{temporary.sub_path});
        var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .capacity = 256 });
        defer registry.deinit();
        const workspaces = try records.Workspaces.init(allocator, io, .{});
        const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
        const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
        var catalog = try protocols.Default.init(allocator);
        defer catalog.deinit(allocator);
        if (mode == .protocols and catalog.values.len < 2) continue;
        var sink: Sink = .{};
        const transport: network.Transport = .{ .context = &sink, .vtable = network.Transport.adapter(Sink) };
        const service = try sessions.Service.init(allocator, io, transport, .{ .connections = count, .pages = 128, .page_bytes = 32768, .buffer_bytes = 16 * 1024 * 1024, .protocols = &catalog.values });
        defer service.deinit();
        const encoding = try packets.Packets.init(allocator, .{ .sessions = service });
        const player_records = try allocator.alloc(Players.Player, count);
        for (player_records, 0..) |*player, index| player.* = .{ .handle = .{ .index = @intCast(index), .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .protocol = catalog.values[if (mode == .protocols) index % catalog.values.len else 0].number };
        var players: Players = .{ .deps = undefined, .config = .{ .render_distance = radius }, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
        try players.initIndexes(allocator);
        players.rebuildIndexes();
        const terrain = try chunks.Chunks.init(allocator, io, .{ .cache_sections = 64, .demand_sections = 24, .cache_tiles = 4 }, .{ .metrics = &registry, .storage = try store.openSpace("chunks"), .record_workspaces = workspaces });
        const streaming = try Streaming.init(allocator, io, .{}, .{ .metrics = &registry, .players = &players, .chunks = terrain, .sessions = service, .packets = encoding, .worlds = dimensions, .lighting = try Lighting.init(allocator, .{}, .{ .chunks = terrain, .worlds = dimensions }) });
        defer service.unsubscribeOutput(streaming.changed);
        defer terrain.unsubscribeReady(streaming.changed);
        streaming.published.setStream(0, .{ .generation = 1, .life = player_records[0].life, .setup = .streaming });
        @memset(streaming.published.sent, std.math.maxInt(u64));
        streaming.published.dirty_words.setRangeValue(.{ .start = 0, .end = streaming.published.sent.len }, true);

        const blocks = try block_synchronization.BlockSynchronization.init(allocator, io, .{ .metrics = &registry, .chunks = terrain, .players = &players, .streaming = streaming, .sessions = service, .packets = encoding, .worlds = dimensions }, .{ .delta_sections = 1 });
        var background: terrain_background.Terrain = .{ .chunks = terrain, .streaming = streaming, .blocks = blocks, .io = io };
        background.start();
        defer background.stop();
        const side: usize = @intCast(players.config.render_distance * 2 + 1);
        for (streaming.streams, player_records, 0..) |*stream, player, index| {
            stream.* = .{ .generation = 1, .life = player.life, .setup = .streaming, .cursor = side * side, .delivered = side * side };
            streaming.published.setStream(index, stream.*);
            service.credit[index].store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
        }
        @memset(streaming.sent, std.math.maxInt(u64));

        const section = chunks.sectionAt(world, .{ .x = 0, .y = 65, .z = 0 });
        for (0..3) |round| {
            for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active, .release);
            service.beginTick();
            try terrain.setBlock(world, .{ .x = 0, .y = 65, .z = 0 }, @intCast(round + 1));
            blocks.endTick(true);
            service.endTick(true);
            try std.testing.expect(!try blocks.poll(io));
            try std.testing.expectEqual(@as(usize, 1), blocks.delta_index.count());
            const slot = blocks.delta_index.get(section).?;
            if (mode == .full_and_delta) {
                const observer = &blocks.observers[1];
                var words = observer.nonempty.iterator(.{});
                while (words.next()) |word| observer.full_bits[word] |= observer.pending_bits[word];
            }
            for (service.credit) |*credit| credit.store((@as(u64, 1) << 32) | sessions.Service.active | service.config.buffer_bytes, .release);
            try std.testing.expect(try blocks.poll(io));
            var batch = service.outputBatch();
            var delivered: usize = 0;
            var packets_sent: usize = 0;
            while (batch.next()) |packet| {
                try std.testing.expectEqual(@as(usize, 1), packet.recipients.len);
                const bit = @as(usize, 1) << @intCast(packet.recipients.first().?.index);
                try std.testing.expect(delivered & bit == 0);
                delivered |= bit;
                packets_sent += 1;
                service.recycle(io, &.{packet});
            }
            try std.testing.expectEqual(@as(usize, 2), packets_sent);
            try std.testing.expectEqual(@as(usize, 3), delivered);
            try std.testing.expectEqual(@as(usize, 0), blocks.delta_index.count());
            try std.testing.expect(!blocks.deltas[slot].live);
            try std.testing.expectEqual(@as(?usize, slot), blocks.free_delta);
            try std.testing.expectEqual(null, blocks.deltas[slot].next_free);
            for (blocks.observers) |observer| {
                try std.testing.expectEqual(@as(usize, 0), observer.pending);
                try std.testing.expectEqual(null, observer.nonempty.findFirstSet());
            }
        }
    }
}
