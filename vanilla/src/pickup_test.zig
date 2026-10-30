const vanilla_content = @import("vanilla_content.zig");
const std = @import("std");
const storage = @import("storage");
const records = @import("records");
const metrics = @import("metrics");
const entities = @import("entities");
const inventories = @import("inventories");
const worlds = @import("worlds");
const Items = @import("items.zig").Items;
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const ItemEntities = @import("item_entities.zig").ItemEntities;
const ItemPickup = @import("item_pickup.zig").ItemPickup;

const Snapshot = struct {
    slots: [2][37]?inventories.Stack = undefined,
    items: [3]?inventories.Stack = undefined,
    metadata: [3]ItemEntities.Metadata = undefined,
};

test "pickup batches preserve player priority item order and partial collection" {
    const Scenario = enum { survival, creative, owned, spectator, dead };
    for ([_]usize{ 47, 128 }) |capacity| for ([_]usize{ 2, 2049 }) |player_capacity| for (std.enums.values(Scenario)) |scenario| {
        var expected: Snapshot = undefined;
        for ([_]bool{ false, true }) |batched| {
            const io = std.testing.io;
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            var path_buffer: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/pickup", .{temporary.sub_path});
            var store = try storage.Store.init(std.testing.allocator, io, .{ .path = path });
            defer store.deinit();
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            var registry = try metrics.Registry.init(std.testing.allocator, io, .{ .enabled = false });
            defer registry.deinit();
            const workspaces = try records.Workspaces.init(allocator, io, .{});
            const ownership = try inventories.Inventories.init(allocator, io, .{ .cache_slots = capacity, .cache_items = 2, .max_item_bytes = 1024 }, .{
                .metrics = &registry,
                .storage = try store.openSpace("inventory"),
                .record_workspaces = workspaces,
            });
            const gameplay_definitions = try vanilla_content.prepare(allocator);
            const items = try Items.init(allocator, .{}, .{ .definitions = gameplay_definitions.items, .inventories = ownership, .registry_identity = undefined });
            const bread = try items.define("minecraft:bread");
            const stone = try items.define("minecraft:stone");
            const apple = try items.define("minecraft:apple");
            const bodies = try entities.Entities.init(allocator, io, .{ .cache_records = 16 }, .{ .metrics = &registry, .storage = try store.openSpace("bodies"), .record_workspaces = workspaces });
            const dimensions = try worlds.Worlds.init(allocator, .{ .maximum = 1 }, .{ .storage = try store.openSpace("worlds") });
            const world = try dimensions.create(.{ .name = "test:world", .dimension = .{ .name = "test:dimension", .minimum_section = 0, .section_count = 16 } });
            const dropped = try ItemEntities.init(allocator, io, .{ .cache_records = 32, .maximum = 8 }, .{
                .metrics = &registry,
                .record_workspaces = workspaces,
                .entities = bodies,
                .inventories = ownership,
                .items = items,
                .worlds = dimensions,
                .storage = try store.openSpace("metadata"),
            });
            const player_records = try allocator.alloc(Players.Player, player_capacity);
            @memset(player_records, .{});
            const player_indices = [_]usize{ 0, player_capacity - 1 };
            var slots: [2][37]inventories.Slot = undefined;
            for (player_indices, &slots, 0..) |player_index, *destinations, index| {
                const player = &player_records[player_index];
                player.* = .{ .handle = .{ .index = player_index, .generation = 1 }, .uuid = index + 1, .world = world, .stage = .ready, .loaded = true, .gamemode = .survival, .position = .{ .x = 0, .y = 65, .z = 0 } };
                var edits: [37]inventories.Edit = undefined;
                for (destinations, &edits, 0..) |*slot, *edit, at| {
                    slot.* = .{ .owner = player.uuid, .index = @intCast(if (at < 9) at + 36 else if (at == 36) 45 else at) };
                    edit.* = .{ .slot = slot.*, .revision = 0, .stack = .{ .item = if (at == 0) bread else if (at == 1) stone else apple, .count = if (at == 0) 63 else if (at == 1) @as(u16, if (index == 0) 63 else 62) else 64 } };
                }
                try std.testing.expect(try ownership.editMany(&edits));
            }
            switch (scenario) {
                .creative => player_records[0].gamemode = .creative,
                .spectator => player_records[0].gamemode = .spectator,
                .dead => player_records[0].health = 0,
                else => {},
            }
            var players: Players = .{ .deps = undefined, .config = .{}, .spawn_world = world, .records = player_records, .dig_handlers = &.{} };
            try players.initIndexes(allocator);
            players.rebuildIndexes();
            const menu = try PlayerInventory.init(allocator, .{}, .{
                .crafting = gameplay_definitions.crafting,
                .furnaces = gameplay_definitions.furnaces,
                    .players = &players,
                .inventories = ownership,
                .items = items,
                .equipment = undefined,
                .dropped = dropped,
            });
            const pickup = try ItemPickup.init(allocator, .{ .players = &players, .menus = menu, .inventories = ownership, .entities = bodies, .items = items, .dropped = dropped });
            var ids: [3]entities.Id = undefined;
            var item_bodies: [3]entities.State = undefined;
            for (&ids, &item_bodies, 0..) |*id, *body, index| {
                id.* = try dropped.create(world, .{ 0, 65, 0 }, @splat(0), .{ .item = if (index == 1) stone else bread, .count = if (index == 2) 1 else 2 });
                body.* = (try bodies.get(id.*)).?;
                var metadata = try dropped.get(id.*);
                metadata.pickup_delay = 0;
                if (scenario == .owned and index == 0) metadata.owner = 2;
                try dropped.put(id.*, metadata);
            }
            if (batched) {
                players.rebuildIndexes();
                try pickup.tick();
            } else {
                for (ids, item_bodies) |id, body| {
                    var metadata = try dropped.get(id);
                    for (player_indices) |player| {
                        var result: [1]ItemPickup.Result = undefined;
                        try pickup.collect(player, &.{.{ .source = ItemEntities.slot(body), .owner = metadata.owner }}, &result);
                        if (result[0].collected == 0) continue;
                        metadata.collector = @intCast(player + 1);
                        metadata.collected = result[0].collected;
                        metadata.collection += 1;
                        metadata.revision += 1;
                        if (result[0].remaining == null) {
                            try dropped.retire(id, body, &metadata);
                            break;
                        }
                        try dropped.put(id, metadata);
                    }
                }
            }
            var actual: Snapshot = undefined;
            for (slots, &actual.slots) |destinations, *stacks| {
                var contents: [37]inventories.Contents = undefined;
                try ownership.getMany(&destinations, &contents);
                for (contents, stacks) |value, *stack| stack.* = value.stack;
            }
            for (ids, item_bodies, &actual.metadata, &actual.items) |id, body, *metadata, *stack| {
                metadata.* = try dropped.get(id);
                stack.* = (try ownership.get(ItemEntities.slot(body))).stack;
            }
            if (batched) try std.testing.expectEqualDeep(expected, actual) else expected = actual;
        }
    };
}
