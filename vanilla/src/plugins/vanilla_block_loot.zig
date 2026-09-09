const lightning_rod = @import("lightning_rod");
const player_store = lightning_rod.players;
const std = @import("std");
const registry = lightning_rod.registry_data;
const game_data = lightning_rod.game_data;

pub const max_stacks = 1;

pub const Result = struct {
    stacks: [max_stacks]player_store.HotbarStack = [_]player_store.HotbarStack{.{}} ** max_stacks,
    count: u8 = 0,
};

pub const BlockLoot = struct {
    pub const id = "minecraft:block_loot";
    pub const Configuration = struct {};

    pub fn init(allocator: std.mem.Allocator, _: Configuration) !*BlockLoot {
        const self = try allocator.create(BlockLoot);
        self.* = .{};
        return self;
    }

    pub fn evaluate(_: *const BlockLoot, block_state: i32, tool: player_store.HotbarStack) Result {
        if (block_state < 0 or block_state >= registry.block_state_to_block.len) return .{};
        if (!game_data.canHarvest(block_state, tool.item_id)) return .{};
        const block_id = registry.block_state_to_block[@intCast(block_state)];
        const stack = switch (block_id) {
            registry.block_clay_id => player_store.stackForItem(registry.item_clay_ball_id, 4),
            registry.block_bookshelf_id => player_store.stackForItem(registry.item_book_id, 3),
            else => player_store.dropStackForBlockState(block_state, 1) orelse return .{},
        };
        var result = stack;
        if (registry.blockStateName(block_state)) |name| {
            if (std.mem.endsWith(u8, name[0 .. std.mem.indexOfScalar(u8, name, '[') orelse name.len], "_slab") and
                std.mem.indexOf(u8, name, "[type=double,") != null)
                result.count = 2;
        }
        return .{ .stacks = .{result}, .count = 1 };
    }
};

test "representative deterministic block loot families" {
    const service = BlockLoot{};
    const diamond_pickaxe = player_store.stackForItem(registry.item_diamond_pickaxe_id, 1);
    const wooden_pickaxe = player_store.stackForItem(registry.item_wooden_pickaxe_id, 1);
    const diamond_shovel = player_store.stackForItem(registry.item_diamond_shovel_id, 1);

    const self_drop = service.evaluate(registry.block_dirt_default_state, diamond_shovel);
    try std.testing.expectEqual(@as(u8, 1), self_drop.count);
    try std.testing.expectEqual(registry.item_dirt_id, self_drop.stacks[0].item_id);

    const transformed = service.evaluate(registry.block_stone_default_state, diamond_pickaxe);
    try std.testing.expectEqual(@as(u8, 1), transformed.count);
    try std.testing.expectEqual(registry.item_cobblestone_id, transformed.stacks[0].item_id);

    try std.testing.expectEqual(
        @as(u8, 0),
        service.evaluate(registry.block_diamond_ore_default_state, wooden_pickaxe).count,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        service.evaluate(registry.block_glass_default_state, diamond_pickaxe).count,
    );

    const multi = service.evaluate(registry.block_clay_default_state, diamond_shovel);
    try std.testing.expectEqual(@as(u8, 1), multi.count);
    try std.testing.expectEqual(registry.item_clay_ball_id, multi.stacks[0].item_id);
    try std.testing.expectEqual(@as(u8, 4), multi.stacks[0].count);

    const double_slab = registry.blockStateId("minecraft:oak_slab[type=double,waterlogged=false]").?;
    const slab_drop = service.evaluate(double_slab, player_store.stackForItem(registry.item_diamond_axe_id, 1));
    try std.testing.expectEqual(@as(u8, 1), slab_drop.count);
    try std.testing.expectEqual(@as(u8, 2), slab_drop.stacks[0].count);
}
