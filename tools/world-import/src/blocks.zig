const std = @import("std");
const game_data = @import("game_data");
const nbt = @import("nbt");
const vanilla = @import("vanilla");
const inventories = @import("inventories");
const fields = @import("nbt.zig");
const items = @import("items.zig");
const world_import = @import("import.zig");

pub fn column(owner: *world_import.Import, scratch: std.mem.Allocator, doc: nbt.Document, world: u32) !void {
    const list = doc.childNamed("block_entities") orelse return;
    _ = try list.expectTag(.list);
    var iterator = list.childIterator(doc.nodes);
    while (iterator.next()) |node| {
        const name = try (try fields.field(doc, node, "id")).string();
        const chest = std.mem.eql(u8, name, "minecraft:chest");
        const furnace = std.mem.eql(u8, name, "minecraft:furnace");
        if (!chest and !furnace) {
            try owner.unsupported("block entity", name);
            continue;
        }
        const key: vanilla.container_storage.Key = .{ .world = world, .position = .{
            .x = try (try fields.field(doc, node, "x")).int(),
            .y = try (try fields.field(doc, node, "y")).int(),
            .z = try (try fields.field(doc, node, "z")).int(),
        } };
        if (@divFloor(key.position.x, 16) != try doc.childNamed("xPos").?.int() or @divFloor(key.position.z, 16) != try doc.childNamed("zPos").?.int()) return error.BlockEntityOutsideChunk;
        const dimension = owner.worlds.get(world).?.dimension;
        const section = @divFloor(key.position.y, 16);
        if (section < dimension.minimum_section or section >= dimension.minimum_section + dimension.section_count) return error.BlockEntityOutsideDimension;
        const block = try owner.chunks.getBlock(world, key.position);
        const expected: usize = @intCast(if (chest) game_data.registry.block_chest_default_state else game_data.registry.block_furnace_default_state);
        if (game_data.registry.block_state_to_block[block] != game_data.registry.block_state_to_block[expected]) return error.BlockEntityMismatch;
        for ([_][]const u8{ "LootTable", "CustomName", "Lock", "lock" }) |unsupported| if (node.childNamed(doc.nodes, unsupported) != null) try owner.unsupported("container field", unsupported);
        if (node.childNamed(doc.nodes, "Items")) |inventory| try items.inventory(owner, scratch, doc, inventory, key.owner(), false, if (chest) 27 else 3);
        if (chest) owner.counts.chests += 1 else {
            try importFurnace(owner, scratch, doc, node, key);
            owner.counts.furnaces += 1;
        }
    }
}

fn counter(doc: nbt.Document, node: nbt.Node, current: []const u8, legacy: []const u8, default: u32) !u32 {
    const field = node.childNamed(doc.nodes, current) orelse node.childNamed(doc.nodes, legacy) orelse return default;
    return std.math.cast(u32, try fields.integer(field)) orelse error.InvalidFurnace;
}

fn importFurnace(owner: *world_import.Import, scratch: std.mem.Allocator, doc: nbt.Document, node: nbt.Node, key: vanilla.container_storage.Key) !void {
    var state: vanilla.furnace_state.State = .{
        .burn_left = try counter(doc, node, "lit_time_remaining", "BurnTime", 0),
        .burn_total = try counter(doc, node, "lit_total_time", "BurnTime", 0),
        .cook = try counter(doc, node, "cooking_time_spent", "CookTime", 0),
        .duration = try counter(doc, node, "cooking_total_time", "CookTimeTotal", 200),
        .active = true,
    };
    if (state.burn_left > state.burn_total or state.cook > state.duration) return error.InvalidFurnace;
    var stacks: [3]?inventories.Stack = undefined;
    var slots: [3]inventories.Slot = undefined;
    var contents: [3]inventories.Contents = undefined;
    for (&slots, 0..) |*slot, index| slot.* = .{ .owner = key.owner(), .index = @intCast(index) };
    try owner.inventories.getMany(&slots, &contents);
    for (&stacks, contents) |*stack, content| stack.* = content.stack;
    var recipe_scratch = std.heap.FixedBufferAllocator.init(try scratch.alloc(u8, 256 * 1024));
    const selected = try owner.content.furnaces.prepareSmelting(owner.items, .{ .world = key.world, .position = .{ .x = key.position.x, .y = key.position.y, .z = key.position.z } }, stacks, &recipe_scratch);
    defer selected.release();
    if (selected.input_kind) |kind| state.input = @intCast(kind);
    if (selected.recipe) |recipe| {
        if (state.cook != 0 and state.duration != recipe.plan.ticks) {
            try owner.unsupported("furnace", "changed cooking duration");
            state.cook = 0;
        }
        state.duration = recipe.plan.ticks;
        std.crypto.hash.Blake3.hash(owner.content.furnaces.table.cooking_names[recipe.index], &state.recipe, .{});
        if (recipe.dynamic) state.source = stacks[0].?.item;
    } else if (state.cook != 0) {
        try owner.unsupported("furnace", "missing smelting recipe");
        state.cook = 0;
    }
    var bytes: [vanilla.furnace_state.encoded_bytes]u8 = undefined;
    state.encode(&bytes);
    if (state.burn_left != 0 or state.cook != 0 or (selected.recipe != null and stacks[1] != null)) try owner.containers.states.put(&key.encode(), &bytes);
    if (node.childNamed(doc.nodes, "RecipesUsed")) |recipes| {
        var iterator = recipes.childIterator(doc.nodes);
        while (iterator.next()) |recipe| {
            const known = for (owner.content.furnaces.table.cooking_names) |name| {
                if (std.mem.eql(u8, name, recipe.name)) break true;
            } else false;
            if (!known) {
                try owner.unsupported("furnace recipe", recipe.name);
                continue;
            }
            var reward_key: [48]u8 = undefined;
            @memcpy(reward_key[0..16], &key.encode());
            std.crypto.hash.Blake3.hash(recipe.name, reward_key[16..48], .{});
            const count = std.math.cast(u32, try fields.integer(recipe)) orelse return error.InvalidFurnaceRewards;
            if (count > std.math.maxInt(i32)) return error.InvalidFurnaceRewards;
            var reward: [16]u8 = @splat(0);
            std.mem.writeInt(u32, reward[0..4], count, .little);
            std.mem.writeInt(u32, reward[4..8], count, .little);
            try owner.containers.rewards.put(&reward_key, &reward);
        }
    }
}
