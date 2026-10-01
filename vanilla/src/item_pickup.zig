const std = @import("std");
const inventories = @import("inventories");
const entities = @import("entities");
const Players = @import("players.zig").Players;
const PlayerInventory = @import("player_inventory.zig").PlayerInventory;
const item = @import("item.zig");
const ItemEntities = @import("item_entities.zig").ItemEntities;
const Items = @import("items.zig").Items;

const assert = std.debug.assert;

pub const ItemPickup = struct {
    pub const id = "minecraft:item_pickup";

    pub const Configuration = struct {};

    pub const Dependencies = struct {
        players: *Players,
        menus: *PlayerInventory,
        inventories: *inventories.Inventories,
        entities: *entities.Entities,
        items: *Items,
        dropped: *ItemEntities,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*ItemPickup {
        const self = try allocator.create(ItemPickup);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *ItemPickup) !void {
        const dropped = self.deps.dropped;
        var cursor: ItemEntities.Cursor = .{};

        while (cursor.more) for (try dropped.scan(&cursor)) |row| {
            var metadata = row.metadata;
            if (!metadata.alive or metadata.pickup_delay != 0) continue;

            const body = (try self.deps.entities.get(row.id)) orelse return error.Corrupt;

            for (self.deps.players.records, 0..) |player, index| {
                if (player.handle == null or player.stage != .ready or player.world != body.world) continue;
                if (@abs(body.position[0] - player.position.x) >= 1.425 or @abs(body.position[2] - player.position.z) >= 1.425 or
                    body.position[1] + 0.25 <= player.position.y - 0.5 or body.position[1] >= player.position.y + 2.3) continue;

                const source = ItemEntities.slot(body);
                const held = (try self.deps.inventories.get(source)).stack orelse return error.Corrupt;
                const count = try self.collect(index, source, .{
                    .stack = held,
                    .maximum_stack = try self.deps.items.stackLimit(held),
                    .age = metadata.age,
                    .pickup_delay = metadata.pickup_delay,
                    .owner = metadata.owner,
                });
                if (count == 0) continue;
                metadata.collector = @intCast(index + 1);
                metadata.collected = count;
                metadata.collection += 1;
                metadata.revision += 1;
                if ((try self.deps.inventories.get(source)).stack == null) {
                    try dropped.retire(row.id, body, &metadata);
                    break;
                }

                try dropped.put(row.id, metadata);
            }
        };
    }

    /// Called on player collision. The item slot and destination slots change in one edit. The
    /// caller only removes the entity after this succeeds.
    pub fn collect(self: *ItemPickup, player_index: usize, source: inventories.Slot, state: item.State) !u16 {
        assert(player_index < self.deps.players.records.len);
        assert(state.valid());
        const player = &self.deps.players.records[player_index];
        if (player.handle == null or player.stage != .ready or player.health == 0) return 0;
        if (player.gamemode == .spectator or state.pickup_delay != 0) return 0;
        if (state.owner) |owner| if (owner != player.uuid) return 0;

        var slots: [38]inventories.Slot = undefined;

        for (slots[0..36], 0..) |*slot, index| slot.* = .{
            .owner = player.uuid,
            .index = @intCast(if (index < 9) index + 36 else index),
        };

        slots[36] = .{ .owner = player.uuid, .index = 45 };
        slots[37] = source;

        for (slots[0..37]) |slot| assert(!std.meta.eql(slot, source));
        var contents: [38]inventories.Contents = undefined;
        try self.deps.inventories.getMany(&slots, &contents);
        if (!std.meta.eql(contents[37].stack, @as(?inventories.Stack, state.stack))) return 0;

        var next: [38]?inventories.Stack = undefined;

        for (&next, contents) |*stack, value| stack.* = value.stack;
        var order: [38]usize = undefined;
        order[0] = player.selected_slot;
        order[1] = 36;

        for (order[2..], 0..) |*index, i| index.* = i;
        var remaining = state.stack.count;

        for (order) |index| {
            if (remaining == 0) break;

            const stack = next[index] orelse continue;
            if (!inventories.Stack.sameItem(stack, state.stack)) continue;

            const amount = @min(remaining, state.maximum_stack -| stack.count);
            if (amount == 0) continue;
            next[index] = .{ .item = state.stack.item, .count = stack.count + amount };
            remaining -= amount;
        }

        for (next[0..36]) |*stack| {
            if (remaining == 0) break;
            if (stack.* != null) continue;

            const amount = @min(remaining, state.maximum_stack);
            stack.* = .{ .item = state.stack.item, .count = amount };
            remaining -= amount;
        }

        const inserted = state.stack.count - remaining;
        const discarded = if (player.gamemode == .creative) remaining else @as(u16, 0);
        remaining -= discarded;
        const collected = inserted + discarded;
        if (collected == 0) return 0;
        next[37] = if (remaining == 0) null else .{ .item = state.stack.item, .count = remaining };
        var edits: [38]inventories.Edit = undefined;
        var count: usize = 0;
        var added: u32 = 0;

        for (next, contents, slots, 0..) |stack, previous, slot, index| {
            if (std.meta.eql(stack, previous.stack)) continue;
            edits[count] = .{ .slot = slot, .revision = previous.revision, .stack = stack };
            count += 1;

            if (index != 37) added += stack.?.count - (if (previous.stack) |old| old.count else @as(u16, 0));
        }

        assert(added == inserted);
        assert(added + discarded == collected);
        assert(@as(u32, collected) + remaining == state.stack.count);
        const committed = try self.deps.inventories.editMany(edits[0..count]);
        assert(committed);
        self.deps.menus.changed(player_index);
        return collected;
    }
};
