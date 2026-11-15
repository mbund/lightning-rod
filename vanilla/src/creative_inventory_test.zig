const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const ItemEntities = @import("vanilla_item_entities").item_entities.ItemEntities;
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const protocols = @import("minecraft_packets").protocols;
const packets = @import("minecraft_packets");
const inventories = @import("inventories");
const sessions = @import("sessions");
const minecraft = @import("minecraft_model");
const item_data = @import("vanilla_items").item_data;
const ItemProperties = @import("vanilla_items").item_properties.ItemProperties;
const item_packets = @import("vanilla_items").item_packets;
const PlayerInventory = @import("vanilla_inventory").player_inventory.PlayerInventory;
const CreativeInventory = @import("vanilla_inventory").creative_inventory.CreativeInventory;

test "creative replacements persist exact packet prefixes without inventing a cursor" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for ([_]bool{ false, true }) |reverse| for (0..4) |received| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/creative", .{directory.sub_path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
            const stone: inventories.Stack = .{ .item = try fixture.items.define("minecraft:stone"), .count = 9 };
            try std.testing.expect(try fixture.ownership.editMany(&.{
                .{ .slot = .{ .owner = 1, .index = 36 }, .revision = 0, .stack = bread },
                .{ .slot = .{ .owner = 1, .index = 45 }, .revision = 0, .stack = stone },
            }));
            const actions = [_]CreativeInventory.Action{
                .{ .creative_slot = .{ .slot = 36, .item = .{ .count = stone.count, .kind = try fixture.items.kind(stone), .components = &.{}, .encoded_bytes = 10 } } },
                .{ .creative_slot = .{ .slot = 45, .item = .{ .count = bread.count, .kind = try fixture.items.kind(bread), .components = &.{}, .encoded_bytes = 10 } } },
            };
            for (0..@min(received, 2)) |index| {
                try fixture.creative.apply(0, actions[index ^ @intFromBool(reverse)]);
                try fixture.creative.tick();
            }
            if (received == 3) {
                try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 36, .item = null } });
                try fixture.menu.closeMenu(0);
                try std.testing.expect((try fixture.ownership.get(.{ .owner = 1, .index = 36 })).stack == null);
            }
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            _ = try store.commit(1);
            try store.waitDurable(store.lastCommit());
        }
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            const source_changed = received >= 2 or (received == 1 and !reverse);
            const offhand_changed = received >= 2 or (received == 1 and reverse);
            if (received == 3) {
                try std.testing.expect(contents[36].stack == null);
            } else {
                try std.testing.expectEqualStrings(if (source_changed) "minecraft:stone" else "minecraft:bread", protocols.registry.itemName(@intCast(try fixture.items.kind(contents[36].stack.?))).?);
                try std.testing.expectEqual(@as(u16, if (source_changed) 9 else 17), contents[36].stack.?.count);
            }
            try std.testing.expectEqualStrings(if (offhand_changed) "minecraft:bread" else "minecraft:stone", protocols.registry.itemName(@intCast(try fixture.items.kind(contents[45].stack.?))).?);
            try std.testing.expectEqual(@as(u16, if (offhand_changed) 17 else 9), contents[45].stack.?.count);
            try std.testing.expect(contents[PlayerInventory.cursor].stack == null);
            const once = contents;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expectEqualDeep(once, contents);
        }
    };
}

test "survival cursor placements drops and close preserve ownership across restart" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const Cut = enum { picked, placed, dropped, closed };
    for (std.enums.values(Cut)) |cut| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/cursor", .{directory.sub_path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            fixture.player_states.records[0].gamemode = .survival;
            const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
            try std.testing.expect(try fixture.ownership.set(.{ .owner = 1, .index = 36 }, 0, bread));
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            var next: [47]?inventories.Stack = undefined;
            for (&next, contents) |*stack, entry| stack.* = entry.stack;
            next[36] = null;
            next[PlayerInventory.cursor] = bread;
            try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{}));
            try std.testing.expect((try fixture.ownership.get(slots[36])).stack == null);
            try std.testing.expectEqual(bread, (try fixture.ownership.get(slots[PlayerInventory.cursor])).stack.?);
            if (cut != .picked) {
                next[38] = .{ .item = bread.item, .count = 1 };
                next[PlayerInventory.cursor].?.count = 16;
                try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{}));
                try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(slots[38])).stack.?.count);
            }
            if (cut == .dropped or cut == .closed) {
                next[PlayerInventory.cursor].?.count = 15;
                try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, &.{.{ .item = bread.item, .count = 1 }}));
                try std.testing.expectEqual(@as(usize, 7), fixture.dropped.free_count);
            }
            if (cut == .closed) {
                var buffer: [16]u8 = undefined;
                const packet = try protocols.implementations[0].Protocol.play.toServer.write(&buffer).close_window();
                const incoming = [_][]const u8{(try packet.windowId(0)).finish()};
                const events = [_]sessions.Event{.{ .input = .{ .handle = fixture.players.records[0].handle.?, .protocol = selected[0].number, .packets = .{ .packets = &incoming } } }};
                fixture.service.input_events = &events;
                try fixture.input.tick(std.testing.failing_allocator);
                fixture.service.input_events = &.{};
                try std.testing.expect((try fixture.ownership.get(slots[PlayerInventory.cursor])).stack == null);
            }
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try fixture.bodies.checkpoint(fixture.bodies.deps.storage);
            try fixture.dropped.checkpoint(fixture.dropped.deps.storage);
            _ = try store.commit(1);
            try store.waitDurable(store.lastCommit());
        }
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expect(contents[PlayerInventory.cursor].stack == null);
            if (cut == .picked) {
                try std.testing.expectEqual(@as(u16, 17), contents[36].stack.?.count);
                try std.testing.expect(contents[38].stack == null);
            } else {
                try std.testing.expect(contents[36].stack == null);
                try std.testing.expectEqual(@as(u16, if (cut == .placed) 17 else 16), contents[38].stack.?.count);
            }
            var total: u32 = 0;
            for (contents) |entry| if (entry.stack) |stack| {
                total += stack.count;
            };
            for (fixture.dropped.residents) |resident| {
                if (resident.id == 0 or !resident.alive) continue;
                const body = (try fixture.bodies.get(resident.id)).?;
                const stack = (try fixture.ownership.get(ItemEntities.slot(body))).stack.?;
                try std.testing.expectEqual(@as(u16, 1), stack.count);
                total += stack.count;
            }
            try std.testing.expectEqual(@as(u32, 17), total);
        }
    }
}

test "creative proposals only echo computed corrections" {
    const io = std.testing.io;
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/creative", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
    defer registry.deinit();
    var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    _ = try ItemProperties.init(arena.allocator(), .{ .items = fixture.items });
    const diamond = try fixture.items.kind(.{ .item = try fixture.items.define("minecraft:diamond"), .count = 1 });
    var slots: [47]inventories.Slot = undefined;
    var contents: [47]inventories.Contents = undefined;
    try fixture.menu.load(0, &slots, &contents);
    const mask = @as(u64, 1) << 9;
    for ([_]?item_packets.Incoming{
        .{ .count = 13, .kind = diamond, .components = &.{}, .encoded_bytes = 10 },
        null,
        .{ .count = 1, .kind = diamond, .components = &.{.{ .key = item_data.key(.max_stack_size), .value = &.{3} }}, .encoded_bytes = 12 },
    }) |proposal| {
        fixture.menu.states[0].dirty = 0;
        try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 9, .item = proposal } });
        try std.testing.expectEqual(@as(u64, 0), fixture.menu.states[0].dirty & mask);
    }
    try fixture.definitions.items.addDefinitions(.{ .items = &.{.{ .name = "minecraft:diamond", .stack_size = 32 }} });
    fixture.menu.states[0].dirty = 0;
    try fixture.creative.apply(0, .{ .creative_slot = .{ .slot = 9, .item = .{ .count = 1, .kind = diamond, .components = &.{}, .encoded_bytes = 10 } } });
    try std.testing.expectEqual(mask, fixture.menu.states[0].dirty & mask);
}
