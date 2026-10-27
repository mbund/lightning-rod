const game_data = @import("game_data");
const std = @import("std");
const inventories = @import("inventories");
const Items = @import("items.zig").Items;

pub const BlockLoot = struct {
    pub const id = "minecraft:block_loot";

    pub const Configuration = struct {};

    pub const Tool = struct {
        item: ?inventories.ItemId = null,
        kind: ?u32 = null,

        pub fn resolve(self: *Tool, items: *Items, stack: ?inventories.Stack) !?u32 {
            const item_id: ?inventories.ItemId = if (stack) |held| held.item else null;
            if (!std.meta.eql(self.item, item_id)) {
                const kind = if (stack) |held| try items.kind(held) else null;
                self.* = .{ .item = item_id, .kind = kind };
            }
            std.debug.assert((self.item == null) == (self.kind == null));
            return self.kind;
        }
    };

    pub const Drop = struct {
        kind: u32,
        count: u16,

        pub fn materialize(self: Drop, items: *Items) !inventories.Stack {
            std.debug.assert(self.kind < game_data.registry.items.len and self.count > 0);
            return .{ .item = try items.define(game_data.registry.itemName(@intCast(self.kind)).?), .count = self.count };
        }
    };

    pub const Result = struct {
        speed: f32,
        harvest: bool,
        drop: ?Drop,
    };

    pub fn init(allocator: std.mem.Allocator) !*BlockLoot {
        const self = try allocator.create(BlockLoot);
        self.* = .{};
        return self;
    }

    pub fn evaluate(_: *const BlockLoot, state: u16, held: ?u32) Result {
        std.debug.assert(state < game_data.registry.block_state_to_block.len);
        const block = game_data.registry.blocks[game_data.registry.block_state_to_block[state]];
        if (held) |kind| std.debug.assert(kind < game_data.registry.items.len);
        var speed: f32 = 1;
        var harvest = block.harvest_count == 0;

        if (held) |info| {
            for (game_data.registry.material_tools[block.material_offset..][0..block.material_count]) |entry| {
                if (entry.item_id == info) speed = entry.multiplier;
            }

            for (game_data.registry.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |entry| {
                harvest = harvest or entry == info;
            }
        }

        if (!harvest or !block.diggable or block.drop_item < 0) return .{ .speed = speed, .harvest = harvest, .drop = null };

        const name = game_data.registry.blockStateName(state).?;
        const base = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        const drop = block.drop_item;
        var count: u16 = 1;

        if (std.mem.eql(u8, base, "minecraft:clay")) count = 4;

        if (std.mem.eql(u8, base, "minecraft:bookshelf")) count = 3;

        if (std.mem.endsWith(u8, base, "_slab") and std.mem.indexOf(u8, name, "type=double") != null) count = 2;

        return .{
            .speed = speed,
            .harvest = harvest,
            .drop = .{ .kind = @intCast(drop), .count = count },
        };
    }
};
