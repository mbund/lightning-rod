const game_data = @import("game_data");
const std = @import("std");
const inventories = @import("inventories");
const Loot = @import("loot_registry.zig").Loot;
const loot = @import("loot.zig");
const Items = @import("items.zig").Items;

pub const BlockLoot = struct {
    pub const id = "minecraft:block_loot";

    pub const Configuration = struct {};
    pub const Dependencies = struct { loot: *Loot };

    deps: Dependencies,

    pub const Tool = struct {
        item: ?inventories.ItemId = null,
        kind: ?u32 = null,
        enchanted: bool = false,

        pub fn resolve(self: *Tool, items: *Items, stack: ?inventories.Stack) !*const Tool {
            const item_id: ?inventories.ItemId = if (stack) |held| held.item else null;
            if (!std.meta.eql(self.item, item_id)) {
                var resolved: Tool = .{ .item = item_id };
                if (stack) |held| {
                    const prepared = try items.acquire(held);
                    defer prepared.release();
                    resolved.kind = prepared.view.kind;
                    resolved.enchanted = prepared.view.value(.enchantments) != null;
                }
                self.* = resolved;
            }
            std.debug.assert((self.item == null) == (self.kind == null));
            return self;
        }
    };

    pub const Result = struct {
        speed: f32,
        harvest: bool,
        experience: game_data.physics_data.Experience,
    };

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*BlockLoot {
        const self = try allocator.create(BlockLoot);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn table(self: *const BlockLoot, state: u16) ?*const loot.Table {
        std.debug.assert(state < game_data.registry.block_state_to_block.len);
        return self.deps.loot.tables.blocks[game_data.registry.block_state_to_block[state]];
    }
};
