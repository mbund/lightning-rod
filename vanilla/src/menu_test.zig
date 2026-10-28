const std = @import("std");
const storage = @import("storage");
const metrics = @import("metrics");
const packets = @import("minecraft_packets");
const sessions = @import("sessions");
const protocols = @import("protocols");
const game_data = @import("game_data");
const inventories = @import("inventories");
const menu_click = @import("menu_click.zig");
const InventoryFixture = @import("inventory_test_fixture.zig").InventoryFixture;
const item_data = @import("item_data.zig");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const records = @import("records");
const chunks = @import("chunks");
const BlockActions = @import("block_actions.zig").BlockActions;
const Containers = @import("containers.zig").Containers;
const ContainerKey = @import("containers.zig").Key;
const furnace = @import("furnace.zig");
const conservation = @import("menu_conservation_test.zig");

test {
    _ = conservation;
}

fn kind(name: []const u8) u32 {
    return @intCast(game_data.registry.itemId(name).?);
}

test "baseline recipes include fuels remainders shaped mirrored and shapeless matches" {
    const recipes = &game_data.recipes;
    try std.testing.expectEqual(@as(u32, 1600), recipes.fuels[kind("minecraft:coal")].ticks);
    try std.testing.expectEqual(@as(u32, 20000), recipes.fuels[kind("minecraft:lava_bucket")].ticks);
    try std.testing.expectEqual(kind("minecraft:bucket"), recipes.fuels[kind("minecraft:lava_bucket")].remainder.?);
    const iron = recipes.recipes[kind("minecraft:raw_iron")].?;
    try std.testing.expectEqual(kind("minecraft:iron_ingot"), iron.output);
    try std.testing.expectEqual(@as(u32, 200), iron.ticks);
    var grid: [9]?u32 = @splat(null);
    grid[3] = kind("minecraft:oak_log");
    const planks = recipes.matches(grid[0..4], 2).?;
    try std.testing.expectEqual(kind("minecraft:oak_planks"), planks.output);
    try std.testing.expectEqual(@as(u16, 4), planks.amount);
    grid = @splat(kind("minecraft:cobblestone"));
    grid[4] = null;
    try std.testing.expectEqual(kind("minecraft:furnace"), recipes.matches(&grid, 3).?.output);
    try std.testing.expect(recipes.matches(grid[0..4], 2) == null);
    grid = .{ kind("minecraft:oak_planks"), kind("minecraft:oak_planks"), null, kind("minecraft:oak_planks"), kind("minecraft:stick"), null, null, kind("minecraft:stick"), null };
    try std.testing.expectEqual(kind("minecraft:wooden_axe"), recipes.matches(&grid, 3).?.output);
    for (0..3) |row| std.mem.swap(?u32, &grid[row * 3], &grid[row * 3 + 2]);
    try std.testing.expectEqual(kind("minecraft:wooden_axe"), recipes.matches(&grid, 3).?.output);
    grid[7] = null;
    try std.testing.expect(recipes.matches(&grid, 3) == null);
}

test "crafting consumes inputs once and cursor ownership survives durable restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/crafting", .{directory.sub_path});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    for ([_]bool{ false, true }) |reopen| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        fixture.players.records[0].gamemode = .survival;
        bounded.fail_index = bounded.alloc_index;
        if (!reopen) {
            const log: inventories.Stack = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 2 };
            const initial = try fixture.ownership.get(.{ .owner = 1, .index = 1 });
            try std.testing.expect(try fixture.ownership.set(.{ .owner = 1, .index = 1 }, initial.revision, log));
            fixture.menu.states[0] = .{ .generation = 1, .life = fixture.players.records[0].life, .close = false, .gamemode = .survival };
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            var next: [47]?inventories.Stack = undefined;
            for (contents, &next) |value, *stack| stack.* = value.stack;
            var drag: menu_click.Drag = .{};
            const menu: menu_click.Menu = .{ .inventory = fixture.menu, .kind = .player, .container_slots = 0, .stacks = &next, .drag = &drag, .creative = false };
            const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
            try std.testing.expectEqual(@as(u16, 1), next[1].?.count);
            try std.testing.expectEqual(@as(u16, 4), next[46].?.count);
            try std.testing.expectEqual(@as(u16, 4), next[0].?.count);
            try std.testing.expect(try fixture.menu.apply(0, &slots, &contents, &next, result.drops[0..result.count]));
            try std.testing.expect((try fixture.ownership.get(.{ .owner = 1, .index = 0 })).stack == null);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try store.waitDurable(try store.commit(1));
        } else {
            var slots: [47]inventories.Slot = undefined;
            var contents: [47]inventories.Contents = undefined;
            try fixture.menu.load(0, &slots, &contents);
            try std.testing.expect(contents[46].stack == null);
            var logs: u32 = 0;
            var planks: u32 = 0;
            for (contents[9..46]) |value| if (value.stack) |stack| {
                switch (try fixture.items.kind(stack)) {
                    else => |item| {
                        if (item == kind("minecraft:oak_log")) logs += stack.count;
                        if (item == kind("minecraft:oak_planks")) planks += stack.count;
                    },
                }
            };
            try std.testing.expectEqual(@as(u32, 1), logs);
            try std.testing.expectEqual(@as(u32, 4), planks);
        }
    }
}

test "default item identity matches the serialized definition" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/identity", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(arena.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    try std.testing.expectEqual(item_data.defaultId(kind("minecraft:iron_ingot")), try fixture.items.defineKind(kind("minecraft:iron_ingot")));
}

fn blockContainers(allocator: std.mem.Allocator, store: *storage.Store, registry: *metrics.Registry, fixture: InventoryFixture) !*Containers {
    const resources = try records.Workspaces.init(allocator, std.testing.io, .{});
    const terrain = try chunks.Chunks.init(allocator, std.testing.io, .{ .cache_sections = 16, .demand_sections = 4, .cache_tiles = 4 }, .{ .storage = try store.openSpace("chunks"), .metrics = registry, .record_workspaces = resources });
    return Containers.init(allocator, .{ .active_furnaces = 8 }, .{
        .players = fixture.players,
        .inventory = fixture.menu,
        .inventories = fixture.ownership,
        .chunks = terrain,
        .actions = try BlockActions.init(allocator, .{}),
        .dropped = fixture.dropped,
        .sessions = fixture.service,
        .packets = try packets.Packets.init(allocator, .{ .sessions = fixture.service }),
        .storage = try store.openSpace("containers"),
        .record_workspaces = resources,
    });
}

test "furnaces preserve exact cooking fuel and light transitions across durable restart" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/furnace", .{directory.sub_path});
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    var expected_burn: u32 = 0;
    var key: ContainerKey = undefined;
    for (0..3) |phase| {
        var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
        defer store.deinit();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
        const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
        defer fixture.service.deinit();
        const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
        bounded.fail_index = bounded.alloc_index;
        key = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const north = containers.states.furnaces[0];
        if (phase == 0) {
            const iron = try fixture.items.define("minecraft:raw_iron");
            const coal = try fixture.items.define("minecraft:coal");
            for (0..8) |index| {
                const next: ContainerKey = .{ .world = key.world, .position = .{ .x = @intCast(index + 2), .y = 1, .z = 0 } };
                try containers.deps.chunks.setBlock(next.world, next.position, north[0]);
                try std.testing.expect(try fixture.ownership.editMany(&.{
                    .{ .slot = .{ .owner = next.owner(), .index = 0 }, .revision = 0, .stack = .{ .item = iron, .count = 2 } },
                    .{ .slot = .{ .owner = next.owner(), .index = 1 }, .revision = 0, .stack = .{ .item = coal, .count = 1 } },
                }));
                try std.testing.expect(containers.activate(next));
            }
            for (0..73) |_| try furnace.tick(containers);
            const value = containers.furnaceState(key.world, key.position);
            try std.testing.expectEqual(@as(u32, 73), value.cook);
            try std.testing.expectEqual(@as(u32, 200), value.duration);
            expected_burn = value.burn_left;
            try std.testing.expectEqual(north[1], try containers.deps.chunks.getBlock(key.world, key.position));
            var encoded = key.encode();
            var bytes: [furnace.encoded_bytes]u8 = undefined;
            var lengths: [1]?usize = undefined;
            try containers.table.getBatch(&.{.{ .key = &encoded, .destination = &bytes }}, &lengths);
            try std.testing.expect(lengths[0] == null);
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(1));
        } else if (phase == 1) {
            try std.testing.expectEqual(@as(usize, 8), containers.active_count);
            const restored = containers.furnaceState(key.world, key.position);
            try std.testing.expectEqual(@as(u32, 73), restored.cook);
            try std.testing.expectEqual(expected_burn, restored.burn_left);
            for (0..127) |_| try furnace.tick(containers);
            const output = (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?;
            try std.testing.expectEqual(kind("minecraft:iron_ingot"), try fixture.items.kind(output));
            try std.testing.expectEqual(@as(u16, 1), output.count);
            try std.testing.expectEqual(@as(u16, 1), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 0 })).stack.?.count);
            for (0..200) |_| try furnace.tick(containers);
            try std.testing.expectEqual(@as(u16, 2), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?.count);
            try std.testing.expect((try fixture.ownership.get(.{ .owner = key.owner(), .index = 0 })).stack == null);
            for (0..1201) |_| try furnace.tick(containers);
            try std.testing.expectEqual(@as(usize, 0), containers.active_count);
            try std.testing.expectEqual(north[0], try containers.deps.chunks.getBlock(key.world, key.position));
            try containers.checkpoint(containers.deps.storage);
            try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
            try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
            try store.waitDurable(try store.commit(2));
        } else {
            try std.testing.expectEqual(@as(usize, 0), containers.active_count);
            try std.testing.expectEqual(@as(u16, 2), (try fixture.ownership.get(.{ .owner = key.owner(), .index = 2 })).stack.?.count);
        }
    }
}

test "container clicks enforce output fuel stack and recipe remainder rules" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/clicks", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .capacity = 512 });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const blocks = try blockContainers(bounded.allocator(), &store, &registry, fixture);
    bounded.fail_index = bounded.alloc_index;
    const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
    const ingot: inventories.Stack = .{ .item = try fixture.items.define("minecraft:iron_ingot"), .count = 1 };
    {
        var next: [41]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .kind = .furnace, .container_slots = 3, .stacks = &next, .drag = &drag, .creative = false };
        next[39] = bread;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
        try std.testing.expect(next[1] == null);
        try std.testing.expectEqual(bread, next[39].?);
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
        try std.testing.expectEqual(bread, next[0].?);
        next[39] = ingot;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 2, .button = 0, .mode = 0 });
        try std.testing.expect(next[2] == null);
        next[2] = ingot;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 2, .button = 0, .mode = 0 });
        try std.testing.expectEqual(@as(u16, 2), next[39].?.count);
        try std.testing.expect(next[2] == null);
    }
    {
        var next: [48]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .kind = .crafting, .container_slots = 10, .stacks = &next, .drag = &drag, .creative = false };
        const milk: inventories.Stack = .{ .item = try fixture.items.define("minecraft:milk_bucket"), .count = 1 };
        const sugar: inventories.Stack = .{ .item = try fixture.items.define("minecraft:sugar"), .count = 1 };
        const wheat: inventories.Stack = .{ .item = try fixture.items.define("minecraft:wheat"), .count = 1 };
        next[1] = milk;
        next[2] = milk;
        next[3] = milk;
        next[4] = sugar;
        next[5] = .{ .item = try fixture.items.define("minecraft:egg"), .count = 1 };
        next[6] = sugar;
        next[7] = wheat;
        next[8] = wheat;
        next[9] = wheat;
        _ = try menu.apply(.{ .window_id = 1, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
        try std.testing.expectEqual(kind("minecraft:cake"), try fixture.items.kind(next[46].?));
        for (next[1..4]) |stack| try std.testing.expectEqual(kind("minecraft:bucket"), try fixture.items.kind(stack.?));
        for (next[4..10]) |stack| try std.testing.expect(stack == null);
        try std.testing.expect(next[0] == null);
    }
    {
        var next: [47]?inventories.Stack = @splat(null);
        var drag: menu_click.Drag = .{};
        const menu: menu_click.Menu = .{ .inventory = fixture.menu, .kind = .player, .container_slots = 0, .stacks = &next, .drag = &drag, .creative = false };
        const planks = try fixture.items.define("minecraft:oak_planks");
        next[1] = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 1 };
        for (next[9..45]) |*stack| stack.* = .{ .item = planks, .count = 64 };
        _ = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        try std.testing.expectEqual(@as(u16, 1), next[1].?.count);
        next[44].?.count = 63;
        const result = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        try std.testing.expect(next[1] == null);
        try std.testing.expectEqual(@as(u16, 64), next[44].?.count);
        try std.testing.expectEqual(@as(usize, 1), result.count);
        try std.testing.expectEqual(@as(u16, 3), result.drops[0].count);
        @memset(&next, null);
        next[1] = .{ .item = try fixture.items.define("minecraft:oak_log"), .count = 64 };
        const definitions_before = fixture.ownership.items.metrics.acquired.value();
        const shifted = try menu.apply(.{ .window_id = 0, .state_id = 0, .slot = 0, .button = 0, .mode = 1 });
        const definitions = fixture.ownership.items.metrics.acquired.value() - definitions_before;
        try std.testing.expect(definitions > 0 and definitions < 64);
        try std.testing.expectEqual(@as(usize, 0), shifted.count);
        try std.testing.expect(next[1] == null);
        var total: u32 = 0;
        for (next[9..45]) |stack| if (stack) |value| {
            total += value.count;
        };
        try std.testing.expectEqual(@as(u32, 256), total);
    }
    {
        const first: ContainerKey = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
        const second: ContainerKey = .{ .world = first.world, .position = .{ .x = 3, .y = 1, .z = 0 } };
        for ([_]ContainerKey{ first, second }) |key| {
            try std.testing.expectEqual(BlockActions.Result.applied, try blocks.deps.actions.apply(.{ .action = .place, .player = &fixture.players.records[0], .position = key.position, .state = blocks.states.chests[0][0][0] }));
        }
        const state = try blocks.deps.chunks.getBlock(first.world, first.position);
        try std.testing.expectEqual(second.position, blocks.states.partner(state, first.position).?);
        try std.testing.expect(try fixture.ownership.set(Containers.slot(first.world, first.position, 0), 0, bread));
        try std.testing.expectEqual(BlockActions.Result.applied, try blocks.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = first.position, .state = state }));
        try std.testing.expect((try fixture.ownership.get(Containers.slot(first.world, first.position, 0))).stack == null);
        try std.testing.expectEqual(@as(u64, 0), (try fixture.ownership.get(Containers.slot(first.world, first.position, 1))).revision);
        try std.testing.expectEqual(@as(u16, 0), try blocks.deps.chunks.getBlock(first.world, first.position));
        try std.testing.expectEqual(blocks.states.chests[0][0][0], try blocks.deps.chunks.getBlock(second.world, second.position));
        var cursor: ItemEntities.Cursor = .{};
        const drops = try fixture.dropped.scan(&cursor);
        try std.testing.expectEqual(@as(usize, 1), drops.len);
        const body = (try fixture.bodies.get(drops[0].id)).?;
        const value = try fixture.ownership.get(ItemEntities.slot(body));
        try std.testing.expectEqual(bread, value.stack.?);
        const last: ContainerKey = .{ .world = first.world, .position = .{ .x = 5, .y = 1, .z = 0 } };
        const placed = try blocks.deps.actions.apply(.{ .action = .place, .player = &fixture.players.records[0], .position = last.position, .state = blocks.states.chests[0][0][0] });
        try std.testing.expectEqual(BlockActions.Result.applied, placed);
        try std.testing.expect(try fixture.ownership.set(Containers.slot(last.world, last.position, 0), 0, bread));
        const reserved = fixture.dropped.free_count;
        const denied = try blocks.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = last.position, .state = blocks.states.chests[0][0][0], .following_drops = reserved });
        try std.testing.expectEqual(BlockActions.Result.denied, denied);
        try std.testing.expectEqual(bread, (try fixture.ownership.get(Containers.slot(last.world, last.position, 0))).stack.?);
        try std.testing.expectEqual(reserved, fixture.dropped.free_count);
    }
}

test "shared chest clicks revalidate drag slots and preserve independent cursors" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/viewers", .{directory.sub_path});
    var store = try storage.Store.init(std.testing.allocator, std.testing.io, .{ .path = path });
    defer store.deinit();
    var registry = try metrics.Registry.init(std.testing.allocator, std.testing.io, .{ .enabled = false });
    defer registry.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
    defer fixture.service.deinit();
    const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
    bounded.fail_index = bounded.alloc_index;
    const key: ContainerKey = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
    const chest = containers.states.chests[0][0][0];
    try containers.deps.chunks.setBlock(key.world, key.position, chest);
    const bread: inventories.Stack = .{ .item = try fixture.items.define("minecraft:bread"), .count = 17 };
    const coal: inventories.Stack = .{ .item = try fixture.items.define("minecraft:coal"), .count = 6 };
    try std.testing.expect(try fixture.ownership.set(Containers.slot(key.world, key.position, 0), 0, bread));
    fixture.players.records[1] = fixture.players.records[0];
    fixture.players.records[1].uuid = 2;
    fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
    for (fixture.players.records) |*player| {
        player.gamemode = .survival;
        player.position = .{ .x = 2, .y = 1, .z = 3 };
        player.protocol = selected[0].number;
        try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = key.position, .state = chest }));
        containers.views[player.handle.?.index].opened = true;
    }
    const alice = fixture.players.records[0].handle.?;
    const bob = fixture.players.records[1].handle.?;
    const alice_window = containers.views[0].window;
    const bob_window = containers.views[1].window;
    try std.testing.expectEqual(@as(usize, 3), containers.watch_index.count());
    const shared = containers.watch_index.get(key.owner()).?;
    try std.testing.expectEqual(@as(usize, 2), containers.watches[shared].users);
    const coal_slot: inventories.Slot = .{ .owner = 1, .index = std.math.maxInt(u16) };
    const bread_slot: inventories.Slot = .{ .owner = 2, .index = std.math.maxInt(u16) };
    const stored = try fixture.ownership.get(coal_slot);
    try std.testing.expect(try fixture.ownership.set(coal_slot, stored.revision, coal));
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = -999, .button = 0, .mode = 5 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = 1, .button = 1, .mode = 5 });
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = -999, .button = 2, .mode = 5 });
    try std.testing.expectEqual(bread, (try fixture.ownership.get(Containers.slot(key.world, key.position, 1))).stack.?);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try containers.click(bob, .{ .window_id = bob_window, .state_id = 0, .slot = 1, .button = 0, .mode = 0 });
    try containers.click(alice, .{ .window_id = alice_window, .state_id = 0, .slot = 1, .button = 0, .mode = 1 });
    try std.testing.expectEqual(bread, (try fixture.ownership.get(bread_slot)).stack.?);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try containers.closeWindow(.{ .index = 0, .generation = 2 }, alice_window);
    try std.testing.expect(containers.opened.contains(0));
    try containers.closeWindow(alice, alice_window);
    try std.testing.expect(!containers.opened.contains(0));
    try std.testing.expect(containers.opened.contains(1));
    try std.testing.expectEqual(@as(usize, 1), containers.watches[shared].users);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
    try fixture.menu.closeMenu(0);
    try std.testing.expect((try fixture.ownership.get(coal_slot)).stack == null);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(.{ .owner = 1, .index = 36 })).stack.?);
    try std.testing.expectEqual(bread, (try fixture.ownership.get(bread_slot)).stack.?);
    try containers.closeWindow(bob, bob_window);
    try fixture.menu.closeMenu(1);
    try std.testing.expect((try fixture.ownership.get(bread_slot)).stack == null);
    try std.testing.expectEqual(bread, (try fixture.ownership.get(.{ .owner = 2, .index = 36 })).stack.?);
    try std.testing.expectEqual(@as(usize, 0), containers.watch_index.count());

    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = &fixture.players.records[1], .position = key.position, .state = chest }));
    fixture.players.records[1].handle = null;
    try containers.tick();
    try std.testing.expect(!containers.opened.contains(1));
    try std.testing.expect(!fixture.menu.states[1].external);
    try std.testing.expectEqual(@as(usize, 0), containers.watch_index.count());

    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = &fixture.players.records[0], .position = key.position, .state = chest }));
    var edits: [37]inventories.Edit = undefined;
    for (&edits, 9..) |*edit, index| {
        const destination: inventories.Slot = .{ .owner = 1, .index = @intCast(index) };
        const previous = try fixture.ownership.get(destination);
        edit.* = .{ .slot = destination, .revision = previous.revision, .stack = .{ .item = bread.item, .count = 64 } };
    }
    try std.testing.expect(try fixture.ownership.editMany(&edits));
    const carried = try fixture.ownership.get(coal_slot);
    try std.testing.expect(try fixture.ownership.set(coal_slot, carried.revision, coal));
    const destination = Containers.slot(key.world, key.position, 0);
    const previous = try fixture.ownership.get(destination);
    try std.testing.expect(try fixture.ownership.set(destination, previous.revision, bread));
    while (fixture.dropped.free_count > 2) _ = try fixture.dropped.create(key.world, .{ 2, 1, 0 }, .{ 0, 0, 0 }, bread);
    try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = key.position, .state = chest, .following_drops = 1 }));
    try std.testing.expect(!containers.opened.contains(0));
    try std.testing.expectEqual(@as(usize, 1), fixture.dropped.free_count);
    _ = try fixture.dropped.create(key.world, .{ 2, 1, 0 }, .{ 0, 0, 0 }, bread);
    try fixture.menu.closeMenu(0);
    try std.testing.expect(fixture.menu.states[0].close);
    try std.testing.expectEqual(coal, (try fixture.ownership.get(coal_slot)).stack.?);
}

fn checkpointMenus(fixture: InventoryFixture, containers: *Containers, store: *storage.Store) ![5]u64 {
    var ends: [5]u64 = undefined;
    try containers.deps.chunks.checkpoint(try store.openSpace("chunks"));
    ends[0] = store.end;
    try containers.checkpoint(containers.deps.storage);
    ends[1] = store.end;
    try fixture.bodies.checkpoint(fixture.bodies.deps.storage);
    ends[2] = store.end;
    try fixture.dropped.checkpoint(fixture.dropped.deps.storage);
    ends[3] = store.end;
    try fixture.ownership.checkpoint(fixture.ownership.deps.storage);
    ends[4] = store.end;
    return ends;
}

const conserved_names = [_][]const u8{ "minecraft:bread", "minecraft:coal", "minecraft:oak_log", "minecraft:raw_iron", "minecraft:iron_ingot" };

fn addOwned(totals: *[conserved_names.len]u64, contents: []const inventories.Contents) !void {
    for (contents) |entry| if (entry.stack) |stack| {
        try std.testing.expect(stack.count > 0 and stack.count <= 64);
        const index = for (conserved_names, 0..) |name, index| {
            const id = item_data.defaultId(kind(name));
            if (std.mem.eql(u8, &id, &stack.item)) break index;
        } else return error.UnexpectedOwnedItem;
        totals[index] += stack.count;
    };
}

fn countOwned(fixture: InventoryFixture, keys: []const ContainerKey) ![conserved_names.len]u64 {
    var totals: [conserved_names.len]u64 = @splat(0);
    var slots: [56]inventories.Slot = undefined;
    var contents: [56]inventories.Contents = undefined;
    for (fixture.players.records) |player| {
        for (&slots, 0..) |*slot, index| slot.* = .{ .owner = player.uuid, .index = if (index < 46) @intCast(index) else if (index == 46) std.math.maxInt(u16) else @intCast(PlayerInventory.table_grid_first + index - 47) };
        try fixture.ownership.getMany(&slots, &contents);
        try std.testing.expect(contents[0].stack == null);
        try addOwned(&totals, &contents);
    }
    for (keys) |key| {
        for (slots[0..27], 0..) |*slot, index| slot.* = Containers.slot(key.world, key.position, @intCast(index));
        try fixture.ownership.getMany(slots[0..27], contents[0..27]);
        try addOwned(&totals, contents[0..27]);
    }
    var cursor: ItemEntities.Cursor = .{};
    while (cursor.more) {
        const rows = try fixture.dropped.scan(&cursor);
        for (rows) |row| {
            if (!row.metadata.alive) continue;
            const body = (try fixture.bodies.get(row.id)) orelse return error.MissingDroppedBody;
            const owned = try fixture.ownership.get(ItemEntities.slot(body));
            try std.testing.expect(owned.stack != null);
            try addOwned(&totals, &.{owned});
        }
    }
    return totals;
}

test "interrupted container saves recover a complete ownership snapshot" {
    const io = std.testing.io;
    const selected = [_]sessions.Protocol{.{ .number = protocols.implementations[0].protocol_number }};
    for ([_]@FieldType(storage.Store.Options, "io_mode"){ .standard, .uring }) |backend| {
        var directory = std.testing.tmpDir(.{});
        defer directory.cleanup();
        var path_buffer: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/ownership", .{directory.sub_path});
        var wal_buffer: [272]u8 = undefined;
        const wal_path = try std.fmt.bufPrint(&wal_buffer, "{s}.wal", .{path});
        var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
        defer registry.deinit();
        var image: []u8 = undefined;
        var cuts: [9]u64 = undefined;
        var furnace_key: ContainerKey = undefined;
        var chest_key: ContainerKey = undefined;
        var saved_burn: u32 = undefined;
        {
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = backend });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
            const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
            bounded.fail_index = bounded.alloc_index;
            fixture.players.records[1] = fixture.players.records[0];
            fixture.players.records[1].uuid = 2;
            fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
            chest_key = .{ .world = fixture.players.records[0].world, .position = .{ .x = 2, .y = 1, .z = 0 } };
            furnace_key = .{ .world = chest_key.world, .position = .{ .x = 4, .y = 1, .z = 0 } };
            const chest = containers.states.chests[0][0][0];
            try containers.deps.chunks.setBlock(chest_key.world, chest_key.position, chest);
            try containers.deps.chunks.setBlock(furnace_key.world, furnace_key.position, containers.states.furnaces[0][0]);
            for (fixture.players.records) |*player| {
                player.gamemode = .survival;
                player.position = .{ .x = 2, .y = 1, .z = 3 };
                player.protocol = selected[0].number;
                try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .use, .player = player, .position = chest_key.position, .state = chest }));
                containers.views[player.handle.?.index].opened = true;
            }
            const bread: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[0]), .count = 17 };
            const coal: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[1]), .count = 6 };
            const log: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[2]), .count = 1 };
            const iron: inventories.Stack = .{ .item = try fixture.items.define(conserved_names[3]), .count = 2 };
            const initial_slots = [_]inventories.Slot{
                Containers.slot(chest_key.world, chest_key.position, 0),
                Containers.slot(furnace_key.world, furnace_key.position, 0),
                Containers.slot(furnace_key.world, furnace_key.position, 1),
                .{ .owner = 1, .index = 65535 },
                .{ .owner = 1, .index = 1 },
                .{ .owner = 1, .index = PlayerInventory.table_grid_first },
            };
            const stacks = [_]inventories.Stack{ bread, iron, .{ .item = coal.item, .count = 1 }, coal, log, .{ .item = log.item, .count = 2 } };
            var edits: [initial_slots.len]inventories.Edit = undefined;
            for (initial_slots, stacks, &edits) |slot, stack, *edit| edit.* = .{ .slot = slot, .revision = (try fixture.ownership.get(slot)).revision, .stack = stack };
            try std.testing.expect(try fixture.ownership.editMany(&edits));
            try std.testing.expect(containers.activate(furnace_key));
            for (0..73) |_| try furnace.tick(containers);
            saved_burn = containers.furnaceState(furnace_key.world, furnace_key.position).burn_left;
            _ = try checkpointMenus(fixture, containers, &store);
            try store.waitDurable(try store.commit(1));
            cuts[0] = store.end;
            const bob = fixture.players.records[1].handle.?;
            const window = containers.views[1].window;
            try containers.click(bob, .{ .window_id = window, .state_id = 0, .slot = 0, .button = 0, .mode = 0 });
            try containers.click(bob, .{ .window_id = window, .state_id = 0, .slot = -999, .button = 0, .mode = 0 });
            try containers.closeWindow(bob, window);
            try containers.closeWindow(fixture.players.records[0].handle.?, containers.views[0].window);
            try fixture.menu.closeMenu(0);
            try fixture.menu.closeMenu(1);
            try std.testing.expectEqual(BlockActions.Result.applied, try containers.deps.actions.apply(.{ .action = .remove, .player = &fixture.players.records[0], .position = chest_key.position, .state = chest }));
            for (0..127) |_| try furnace.tick(containers);
            const ends = try checkpointMenus(fixture, containers, &store);
            @memcpy(cuts[1..6], &ends);
            _ = try store.commit(2);
            cuts[6] = store.end - @sizeOf(storage.Page) / 2;
            cuts[7] = store.end - 1;
            cuts[8] = store.end;
            image = try std.testing.allocator.alloc(u8, @intCast(store.end));
            try std.testing.expectEqual(image.len, try store.wal.readPositionalAll(io, image, 0));
        }
        defer std.testing.allocator.free(image);
        for (cuts, 0..) |cut, index| {
            errdefer std.debug.print("container recovery backend={t} cut={d} bytes={d}\n", .{ backend, index, cut });
            {
                const file = try std.Io.Dir.cwd().createFile(io, wal_path, .{});
                defer file.close(io);
                try file.writePositionalAll(io, image[0..@intCast(cut)], 0);
            }
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path, .io_mode = backend });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var bounded = std.testing.FailingAllocator.init(arena.allocator(), .{});
            const fixture = try InventoryFixture.init(bounded.allocator(), &store, &registry, &selected);
            defer fixture.service.deinit();
            const containers = try blockContainers(bounded.allocator(), &store, &registry, fixture);
            fixture.players.records[1] = fixture.players.records[0];
            fixture.players.records[1].uuid = 2;
            fixture.players.records[1].handle = .{ .index = 1, .generation = 1 };
            fixture.players.records[0].gamemode = .survival;
            fixture.players.records[1].gamemode = .survival;
            bounded.fail_index = bounded.alloc_index;
            const complete = cut == image.len;
            try std.testing.expectEqual(@as(u64, if (complete) 2 else 1), store.lastTick());
            const totals = try countOwned(fixture, &.{ chest_key, furnace_key });
            try std.testing.expectEqualSlices(u64, &.{ 17, 6, 3, if (complete) 1 else 2, if (complete) 1 else 0 }, &totals);
            try std.testing.expectEqual(complete, (try containers.deps.chunks.getBlock(chest_key.world, chest_key.position)) == 0);
            try std.testing.expectEqual(@as(usize, if (complete) 7 else 8), fixture.dropped.free_count);
            const counters = containers.furnaceState(furnace_key.world, furnace_key.position);
            try std.testing.expectEqual(@as(u32, if (complete) 0 else 73), counters.cook);
            try std.testing.expectEqual(saved_burn - @as(u32, if (complete) 127 else 0), counters.burn_left);
            for (0..2) |player| {
                var slots: [47]inventories.Slot = undefined;
                var contents: [47]inventories.Contents = undefined;
                try fixture.menu.load(player, &slots, &contents);
                try std.testing.expect(contents[46].stack == null);
                for (contents[1..5]) |entry| try std.testing.expect(entry.stack == null);
            }
            const recovered = try countOwned(fixture, &.{ chest_key, furnace_key });
            try std.testing.expectEqualSlices(u64, &totals, &recovered);
        }
    }
}
