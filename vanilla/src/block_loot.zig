const std = @import("std");
const inventories = @import("inventories");
const registry = @import("protocols").registry;
const Items = @import("items.zig").Items;

pub const BlockLoot = struct {
    pub const id = "minecraft:block_loot";

    pub const Configuration = struct {};

    pub const Dependencies = struct { items: *Items };

    pub const Result = struct {
        speed: f32,
        harvest: bool,
        stack: ?inventories.Stack,
    };

    deps: Dependencies,

    pub fn init(allocator: std.mem.Allocator, deps: Dependencies) !*BlockLoot {
        const self = try allocator.create(BlockLoot);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn evaluate(self: *BlockLoot, state: u16, tool: ?inventories.Stack) !Result {
        std.debug.assert(state < registry.block_state_to_block.len);
        const block = registry.blocks[registry.block_state_to_block[state]];
        const held = if (tool) |stack| try self.deps.items.describe(stack) else null;
        var speed: f32 = 1;
        var harvest = block.harvest_count == 0;

        if (held) |info| {
            for (registry.material_tools[block.material_offset..][0..block.material_count]) |entry| {
                if (entry.item_id == info.kind) speed = entry.multiplier;
            }

            for (registry.harvest_tools[block.harvest_offset..][0..block.harvest_count]) |entry| {
                harvest = harvest or entry == info.kind;
            }

            if (speed > 1 and info.efficiency > 0) speed += @floatFromInt(info.efficiency * info.efficiency + 1);
        }

        if (!harvest or !block.diggable or block.drop_item < 0) return .{ .speed = speed, .harvest = harvest, .stack = null };

        const name = registry.blockStateName(state).?;
        const base = name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len];
        var drop = block.drop_item;
        var count: u16 = 1;

        if (std.mem.eql(u8, base, "minecraft:clay")) count = 4;

        if (std.mem.eql(u8, base, "minecraft:bookshelf")) count = 3;

        if (std.mem.endsWith(u8, base, "_slab") and std.mem.indexOf(u8, name, "type=double") != null) count = 2;

        if (held) |info| if (info.silk_touch) {
            if (registry.itemId(base)) |silk| {
                drop = silk;
                count = 1;
            }
        };

        return .{
            .speed = speed,
            .harvest = harvest,
            .stack = .{ .item = try self.deps.items.define(registry.itemName(drop).?), .count = count },
        };
    }
};
