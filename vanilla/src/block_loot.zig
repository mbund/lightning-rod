const game_data = @import("game_data");
const std = @import("std");
const inventories = @import("inventories");
const Enchantments = @import("enchantments.zig").Enchantments;
const Items = @import("items.zig").Items;

pub const BlockLoot = struct {
    pub const id = "minecraft:block_loot";

    pub const Configuration = struct {};

    pub const Tool = struct {
        item: ?inventories.ItemId = null,
        kind: ?u32 = null,
        silk_touch: bool = false,

        pub fn resolve(self: *Tool, items: *Items, stack: ?inventories.Stack) !*const Tool {
            const item_id: ?inventories.ItemId = if (stack) |held| held.item else null;
            if (!std.meta.eql(self.item, item_id)) {
                var resolved: Tool = .{ .item = item_id };
                if (stack) |held| {
                    const prepared = try items.acquire(held);
                    defer prepared.release();
                    resolved.kind = prepared.view.kind;
                    resolved.silk_touch = try Enchantments.level(prepared.view, @intCast(game_data.registry.enchantmentId("minecraft:silk_touch").?)) > 0;
                }
                self.* = resolved;
            }
            std.debug.assert((self.item == null) == (self.kind == null));
            return self;
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
        experience: game_data.physics_data.Experience,
    };

    pub fn init(allocator: std.mem.Allocator) !*BlockLoot {
        const self = try allocator.create(BlockLoot);
        self.* = .{};
        return self;
    }

    pub fn evaluate(_: *const BlockLoot, state: u16, tool: *const Tool) Result {
        std.debug.assert(state < game_data.registry.block_state_to_block.len);
        const block = game_data.registry.blocks[game_data.registry.block_state_to_block[state]];
        if (tool.kind) |kind| std.debug.assert(kind < game_data.registry.items.len);
        var speed: f32 = 1;
        var harvest = block.harvest_count == 0;

        if (tool.kind) |info| {
            for (game_data.registry.material_tools[block.material_offset..][0..block.material_count]) |entry| {
                if (entry.item_id == info) speed = entry.multiplier;
            }

            for (game_data.registry.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |entry| {
                harvest = harvest or entry == info;
            }
        }

        var experience: game_data.physics_data.Experience = if (harvest and block.diggable) game_data.physics.experience(game_data.registry.block_state_to_block[state]) else .{};
        const silk_drop = if (tool.silk_touch and experience.silk_touch) experience.silk_drop else -1;
        const silk_only = experience.silk_only;
        if (tool.silk_touch and experience.silk_touch) experience = .{};
        if (!harvest or !block.diggable or (block.drop_item < 0 and silk_drop < 0) or (silk_only and silk_drop < 0)) return .{ .speed = speed, .harvest = harvest, .drop = null, .experience = experience };
        if (silk_drop >= 0) return .{ .speed = speed, .harvest = harvest, .drop = .{ .kind = @intCast(silk_drop), .count = 1 }, .experience = experience };

        const name = game_data.registry.blockStateName(state).?;
        const base = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        const drop = block.drop_item;
        var count: u16 = 1;

        if (std.mem.eql(u8, base, "minecraft:clay")) count = 4;

        if (std.mem.eql(u8, base, "minecraft:bookshelf")) count = 3;

        if (std.mem.endsWith(u8, base, "_slab") and std.mem.indexOf(u8, name, "type=double") != null) count = 2;

        return .{
            .experience = experience,
            .speed = speed,
            .harvest = harvest,
            .drop = .{ .kind = @intCast(drop), .count = count },
        };
    }
};
